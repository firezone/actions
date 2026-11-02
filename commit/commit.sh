#!/usr/bin/env bash
#
# Commits what the job changed under `PATHS` onto `BRANCH` with the GraphQL
# `createCommitOnBranch` mutation, so that GitHub signs the commit.
#
# The job's changes are the difference between the checked-out commit and the
# working tree. They are applied file by file on top of the branch's current
# head, like a rebase: a file the branch changed since the checkout is a
# conflict, unless the branch already holds the content the job wants.
set -euo pipefail
export LC_ALL=C

: "${GH_TOKEN:?}" "${BRANCH:?}" "${MESSAGE:?}" "${PATHS:?}"
BASE=${BASE:-}
RESET=${RESET:-false}
OUTPUT=${COMMIT_OUTPUT:-$GITHUB_OUTPUT}
# GitHub documents no request size limit for GraphQL mutations. Splitting the
# base64-encoded contents at 10 MiB per commit stays well clear of the sizes at
# which large API requests start to fail.
MAX_BYTES=${COMMIT_MAX_PAYLOAD_BYTES:-10485760}
MAX_ATTEMPTS=5

repo=$GITHUB_REPOSITORY
server=${GITHUB_SERVER_URL:-https://github.com}

cd "$(git rev-parse --show-toplevel)"
work=$(mktemp -d)
tmp_branch=""
# shellcheck disable=SC2329 # invoked by the trap
cleanup() {
    if [ -n "$tmp_branch" ]; then
        gh api -X DELETE "repos/$repo/git/refs/heads/$tmp_branch" >/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

emit() {
    echo "sha=$1" >>"$OUTPUT"
    echo "up-to-date=$2" >>"$OUTPUT"
}

# Prints the commit a branch points to, or nothing if it does not exist.
read_ref() {
    # shellcheck disable=SC2016
    gh api graphql \
        -f query='query($owner: String!, $name: String!, $ref: String!) {
            repository(owner: $owner, name: $name) { ref(qualifiedName: $ref) { target { oid } } }
        }' \
        -f owner="${repo%/*}" -f name="${repo#*/}" -f ref="refs/heads/$1" \
        --jq '.data.repository.ref.target.oid // empty'
}

ensure_local() {
    if git cat-file -e "$1^{commit}" 2>/dev/null; then
        return
    fi

    local auth depth=()
    auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
    echo "::add-mask::$auth"
    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
        depth=(--depth=1)
    fi
    # The empty value drops the credentials actions/checkout may have configured.
    git -c "http.$server/.extraheader=" \
        -c "http.$server/.extraheader=AUTHORIZATION: basic $auth" \
        fetch -q --no-tags --no-write-fetch-head "${depth[@]}" "$server/$repo" "$1"
}

# Reads `git diff-tree -r -z` raw output and prints `<dst mode> <dst oid> <path>`
# records, NUL-separated, in the format of `git update-index --index-info`.
raw_to_index_info() {
    local meta path dst_mode dst_oid
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        read -r _ dst_mode _ dst_oid _ <<<"${meta#:}"
        printf '%s %s\t%s\0' "$dst_mode" "$dst_oid" "$path"
    done
}

# The tree the job wants: the checked-out commit plus the working tree under PATHS.
head=$(git rev-parse HEAD)
index=$(git rev-parse --path-format=absolute --git-path index)
if [ -f "$index" ]; then
    cp "$index" "$work/index"
fi
GIT_INDEX_FILE="$work/index" git read-tree -m "$head"
while IFS= read -r spec; do
    spec=${spec#"${spec%%[![:space:]]*}"}
    spec=${spec%"${spec##*[![:space:]]}"}
    if [ -z "$spec" ]; then
        continue
    fi
    if ! err=$(GIT_INDEX_FILE="$work/index" git add -A -- "$spec" 2>&1); then
        if [[ $err == *"did not match any files"* ]]; then
            continue
        fi
        echo "$err" >&2
        exit 1
    fi
done <<<"$PATHS"
wanted=$(GIT_INDEX_FILE="$work/index" git write-tree)

git diff-tree -r -z --no-renames "$head" "$wanted" >"$work/changes"
if [ ! -s "$work/changes" ]; then
    echo "Nothing changed under the given paths."
    emit "" false
    exit 0
fi
raw_to_index_info <"$work/changes" >"$work/changes.info"
if tr '\0' '\n' <"$work/changes.info" | grep -qE '^(120000|160000) '; then
    echo "Symbolic links and submodules cannot be committed through the API." >&2
    exit 1
fi
git diff-tree -r -z --no-renames --name-only "$head" "$wanted" | sort -z >"$work/paths"

# Computes the tree that applies the job's changes on top of commit $1 into
# `$planned`, and the diff from $1 to it into "$work/send".
plan() {
    local start=$1

    git diff-tree -r -z --no-renames --name-only "$head" "$start" | sort -z >"$work/moved.all"
    comm -z -12 "$work/paths" "$work/moved.all" >"$work/moved"
    git diff-tree -r -z --no-renames --name-only "$start" "$wanted" | sort -z >"$work/differ"
    comm -z -12 "$work/moved" "$work/differ" >"$work/conflicts"
    if [ -s "$work/conflicts" ]; then
        echo "$BRANCH changed these files since $head was checked out:" >&2
        tr '\0' '\n' <"$work/conflicts" >&2
        exit 1
    fi

    rm -f "$work/plan.index"
    GIT_INDEX_FILE="$work/plan.index" git read-tree "$start"
    GIT_INDEX_FILE="$work/plan.index" git update-index -z --index-info <"$work/changes.info"
    planned=$(GIT_INDEX_FILE="$work/plan.index" git write-tree)
    git diff-tree -r -z --no-renames "$start" "$planned" >"$work/send"
}

# Splits "$work/send" into chunks of at most MAX_BYTES of base64 contents, as
# "$work/chunk.<n>.additions" and "$work/chunk.<n>.deletions" (JSON lines).
split_chunks() {
    rm -f "$work"/chunk.*
    chunks=1
    local bytes=0 meta path dst_mode dst_oid size encoded
    : >"$work/chunk.1.additions"
    : >"$work/chunk.1.deletions"
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        read -r _ dst_mode _ dst_oid _ <<<"${meta#:}"
        if [ "$dst_mode" = 000000 ]; then
            encoded=${#path}
        else
            size=$(git cat-file -s "$dst_oid")
            encoded=$((4 * ((size + 2) / 3)))
        fi
        if [ "$bytes" -gt 0 ] && [ $((bytes + encoded)) -gt "$MAX_BYTES" ]; then
            chunks=$((chunks + 1))
            bytes=0
            : >"$work/chunk.$chunks.additions"
            : >"$work/chunk.$chunks.deletions"
        fi
        bytes=$((bytes + encoded))
        if [ "$dst_mode" = 000000 ]; then
            jq -cn --arg path "$path" '{path: $path}' >>"$work/chunk.$chunks.deletions"
        else
            jq -cn --arg path "$path" --rawfile contents <(git cat-file blob "$dst_oid" | base64 -w0) \
                '{path: $path, contents: $contents}' >>"$work/chunk.$chunks.additions"
        fi
    done <"$work/send"
}

headline=$(printf '%s\n' "$MESSAGE" | head -n1)
body=$(printf '%s\n' "$MESSAGE" | tail -n +2 | sed '/./,$!d')

# Commits the chunks onto branch $1, whose head must be $2. Sets `committed` to
# the last commit. Fails if a mutation fails.
commit_chunks() {
    local target=$1 i oid suffix=""
    committed=$2
    for ((i = 1; i <= chunks; i++)); do
        if [ "$chunks" -gt 1 ]; then
            suffix=" ($i/$chunks)"
        fi
        # shellcheck disable=SC2016
        jq -n \
            --arg repo "$repo" --arg branch "$target" --arg expected "$committed" \
            --arg headline "$headline$suffix" --arg body "$body" \
            --slurpfile additions "$work/chunk.$i.additions" \
            --slurpfile deletions "$work/chunk.$i.deletions" \
            '{
                query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
                variables: { input: {
                    branch: { repositoryNameWithOwner: $repo, branchName: $branch },
                    expectedHeadOid: $expected,
                    message: { headline: $headline, body: $body },
                    fileChanges: { additions: $additions, deletions: $deletions }
                } }
            }' >"$work/payload.json"
        if ! oid=$(gh api graphql --input "$work/payload.json" --jq '.data.createCommitOnBranch.commit.oid') || [ -z "$oid" ]; then
            return 1
        fi
        committed=$oid
        echo "Committed $committed to $target$suffix."
    done
}

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    current=$(read_ref "$BRANCH")
    if [ "$RESET" = true ] || [ -z "$current" ]; then
        if [ -z "$BASE" ]; then
            echo "$BRANCH does not exist and no base was given." >&2
            exit 1
        fi
        start=$(read_ref "$BASE")
        if [ -z "$start" ]; then
            echo "The base branch $BASE does not exist." >&2
            exit 1
        fi
    else
        start=$current
    fi

    ensure_local "$start"
    plan "$start"
    if [ ! -s "$work/send" ]; then
        echo "Nothing to commit on top of $start."
        emit "" false
        exit 0
    fi

    if [ "$RESET" = true ] && [ -n "$current" ] && [ "$current" != "$start" ]; then
        # The branch is up to date if it changes what the new commit would change,
        # in the same way, even if the base moved on elsewhere in the meantime.
        ensure_local "$current"
        merge_base=$(gh api "repos/$repo/compare/$start...$current" --jq .merge_base_commit.sha)
        ensure_local "$merge_base"
        {
            git diff-tree -r -z --no-renames --name-only "$merge_base" "$current"
            git diff-tree -r -z --no-renames --name-only "$start" "$planned"
        } | sort -zu >"$work/proposed"
        git diff-tree -r -z --no-renames --name-only "$current" "$planned" | sort -z >"$work/stale"
        comm -z -12 "$work/proposed" "$work/stale" >"$work/outdated"
        if [ ! -s "$work/outdated" ]; then
            echo "$BRANCH is up to date."
            emit "" true
            exit 0
        fi
    fi

    split_chunks

    if [ -z "$current" ]; then
        gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$start" >/dev/null
        current=$start
    fi

    if [ "$current" != "$start" ]; then
        # Resetting the branch to the base first would make an open pull request
        # look merged, so build the commits elsewhere and move the branch once.
        tmp_branch="$BRANCH-commit-$GITHUB_RUN_ID-$RANDOM"
        gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$tmp_branch" -f sha="$start" >/dev/null
        commit_chunks "$tmp_branch" "$start"
        gh api -X PATCH "repos/$repo/git/refs/heads/$BRANCH" -f sha="$committed" -F force=true >/dev/null
        emit "$committed" false
        exit 0
    fi

    if commit_chunks "$BRANCH" "$start"; then
        emit "$committed" false
        exit 0
    fi
    if [ "$(read_ref "$BRANCH")" = "$committed" ]; then
        echo "Could not commit to $BRANCH." >&2
        exit 1
    fi
    echo "$BRANCH moved while committing; retrying."
done

echo "$BRANCH kept moving; gave up after $MAX_ATTEMPTS attempts." >&2
exit 1

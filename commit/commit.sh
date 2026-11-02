#!/usr/bin/env bash
#
# Commits what the job changed under `PATHS` onto `BRANCH` with the GraphQL
# `createCommitOnBranch` mutation, so that GitHub signs the commit.
#
# The job's changes are the difference between the checked-out commit (or
# nothing, in a repository without commits) and the working tree. They are
# applied file by file on top of the branch's current head, like a rebase: a
# file the branch changed since the checkout is a conflict, unless the branch
# already holds the content the job wants. Only the changed paths are looked up
# on GitHub, so the target repository never has to be fetched.
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

repo=${REPOSITORY:-$GITHUB_REPOSITORY}
zero=0000000000000000000000000000000000000000

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

# Prints the blob each of the given paths has in commit $1, one per line, or an
# empty line where there is none.
lookup() {
    local commit=$1
    shift
    # shellcheck disable=SC2016
    jq -n --arg owner "${repo%/*}" --arg name "${repo#*/}" --arg commit "$commit" '
        $ARGS.positional as $paths | [range(0; $paths | length)] as $i | {
            query: ("query($owner: String!, $name: String!"
                + ($i | map(", $p\(.): String!") | join(""))
                + ") { repository(owner: $owner, name: $name) { "
                + ($i | map("p\(.): object(expression: $p\(.)) { oid }") | join(" "))
                + " } }"),
            variables: ({owner: $owner, name: $name}
                + ($i | map({key: "p\(.)", value: "\($commit):\($paths[.])"}) | from_entries))
        }' --args "$@" >"$work/lookup.json"
    gh api graphql --input "$work/lookup.json" \
        --jq ".data.repository as \$r | range(0; $#) | \$r[\"p\(.)\"].oid // \"\""
}

# Prints the blobs of the NUL-separated paths in file $2 at commit $1, as `lookup`.
remote_blobs() {
    local batch=() path
    while IFS= read -r -d '' path; do
        batch+=("$path")
        if [ ${#batch[@]} -eq 100 ]; then
            lookup "$1" "${batch[@]}"
            batch=()
        fi
    done <"$2"
    if [ ${#batch[@]} -gt 0 ]; then
        lookup "$1" "${batch[@]}"
    fi
}

# The tree the job wants: the checked-out commit plus the working tree under PATHS.
if head=$(git rev-parse -q --verify 'HEAD^{commit}'); then
    index=$(git rev-parse --path-format=absolute --git-path index)
    if [ -f "$index" ]; then
        cp "$index" "$work/index"
    fi
    GIT_INDEX_FILE="$work/index" git read-tree -m "$head"
else
    head=$(git hash-object -t tree /dev/null)
    GIT_INDEX_FILE="$work/index" git read-tree --empty
fi
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

# The changed paths, with their blobs before and after the job's changes. A
# missing file has an empty blob.
paths=()
before=()
after=()
: >"$work/paths"
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r _ dst_mode src_oid dst_oid _ <<<"${meta#:}"
    if [ "$dst_mode" = 120000 ] || [ "$dst_mode" = 160000 ]; then
        echo "$path: symbolic links and submodules cannot be committed through the API." >&2
        exit 1
    fi
    paths+=("$path")
    before+=("${src_oid/#$zero/}")
    after+=("${dst_oid/#$zero/}")
    printf '%s\0' "$path" >>"$work/paths"
done < <(git diff-tree -r -z --no-renames "$head" "$wanted")
if [ ${#paths[@]} -eq 0 ]; then
    echo "Nothing changed under the given paths."
    emit "" false
    exit 0
fi

# Sets `send` to the indices of the changes commit $1 does not have yet.
plan() {
    local i remote conflicts=()
    mapfile -t remote < <(remote_blobs "$1" "$work/paths")
    if [ ${#remote[@]} -ne ${#paths[@]} ]; then
        echo "Could not look up the changed files in $1." >&2
        exit 1
    fi
    send=()
    for i in "${!paths[@]}"; do
        if [ "${remote[i]}" = "${after[i]}" ]; then
            continue
        fi
        if [ "${remote[i]}" != "${before[i]}" ]; then
            conflicts+=("${paths[i]}")
            continue
        fi
        send+=("$i")
    done
    if [ ${#conflicts[@]} -gt 0 ]; then
        echo "$BRANCH changed these files since the checked-out commit:" >&2
        printf '%s\n' "${conflicts[@]}" >&2
        exit 1
    fi
}

# Whether branch head $1 already proposes exactly the changes in `send` on top
# of $2, even if $2 moved on elsewhere since.
proposes_the_same() {
    local i proposed
    gh api "repos/$repo/compare/$2...$1" \
        --jq '[.files[] | .filename, (.previous_filename // empty)] | unique | .[]' >"$work/proposed"
    for i in "${send[@]}"; do
        printf '%s\n' "${paths[i]}"
    done | sort -u >"$work/sending"
    if ! cmp -s "$work/proposed" "$work/sending"; then
        return 1
    fi
    : >"$work/sending"
    for i in "${send[@]}"; do
        printf '%s\0' "${paths[i]}" >>"$work/sending"
    done
    mapfile -t proposed < <(remote_blobs "$1" "$work/sending")
    for i in "${!send[@]}"; do
        if [ "${proposed[i]-}" != "${after[${send[i]}]}" ]; then
            return 1
        fi
    done
}

# Splits `send` into chunks of at most MAX_BYTES of base64 contents, as
# "$work/chunk.<n>.additions" and "$work/chunk.<n>.deletions" (JSON lines).
split_chunks() {
    rm -f "$work"/chunk.*
    chunks=1
    local bytes=0 i path oid encoded
    : >"$work/chunk.1.additions"
    : >"$work/chunk.1.deletions"
    for i in "${send[@]}"; do
        path=${paths[i]}
        oid=${after[i]}
        if [ -z "$oid" ]; then
            encoded=${#path}
        else
            encoded=$((4 * (($(git cat-file -s "$oid") + 2) / 3)))
        fi
        if [ "$bytes" -gt 0 ] && [ $((bytes + encoded)) -gt "$MAX_BYTES" ]; then
            chunks=$((chunks + 1))
            bytes=0
            : >"$work/chunk.$chunks.additions"
            : >"$work/chunk.$chunks.deletions"
        fi
        bytes=$((bytes + encoded))
        if [ -z "$oid" ]; then
            jq -cn --arg path "$path" '{path: $path}' >>"$work/chunk.$chunks.deletions"
        else
            jq -cn --arg path "$path" --rawfile contents <(git cat-file blob "$oid" | base64 -w0) \
                '{path: $path, contents: $contents}' >>"$work/chunk.$chunks.additions"
        fi
    done
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
        echo "Committed $committed to $repo@$target$suffix."
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

    plan "$start"
    if [ ${#send[@]} -eq 0 ]; then
        echo "Nothing to commit on top of $start."
        emit "" false
        exit 0
    fi

    if [ "$RESET" = true ] && [ -n "$current" ] && [ "$current" != "$start" ] &&
        proposes_the_same "$current" "$start"; then
        echo "$BRANCH is up to date."
        emit "" true
        exit 0
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

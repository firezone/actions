#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?}" "${BRANCH:?}" "${TITLE:?}" "${PATHS:?}"
BODY=${BODY:-}
repo=$GITHUB_REPOSITORY
BASE=${BASE:-$(gh api "repos/$repo" --jq .default_branch)}

# Prints the comma- or newline-separated items of $1 as a JSON array.
list() {
    jq -nc --arg items "$1" \
        '$items | split(",") | map(split("\n")) | flatten | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))'
}

result=$(mktemp)
COMMIT_OUTPUT=$result BASE=$BASE RESET=true MESSAGE=${COMMIT_MESSAGE:-$TITLE} \
    bash "$GITHUB_ACTION_PATH/../commit/commit.sh"
sha=$(sed -n 's/^sha=//p' "$result")
up_to_date=$(sed -n 's/^up-to-date=//p' "$result")

number=""
url=""
pr=$(gh api -X GET "repos/$repo/pulls" \
    -f state=open -f head="${repo%/*}:$BRANCH" -f base="$BASE" \
    --jq '.[0] | select(.) | "\(.number) \(.html_url)"')
if [ -n "$pr" ]; then
    read -r number url <<<"$pr"
fi

changed=false
if [ -n "$sha" ]; then
    changed=true
fi

if [ -n "$number" ]; then
    if [ "$changed" = true ]; then
        gh api -X PATCH "repos/$repo/pulls/$number" -f title="$TITLE" -f body="$BODY" >/dev/null
        echo "Updated $url."
    fi
elif [ "$changed" = true ] || [ "$up_to_date" = true ]; then
    pr=$(gh api -X POST "repos/$repo/pulls" \
        -f title="$TITLE" -f body="$BODY" -f head="$BRANCH" -f base="$BASE" \
        --jq '"\(.number) \(.html_url)"')
    read -r number url <<<"$pr"
    changed=true
    echo "Opened $url."

    reviewers=$(list "${REVIEWERS:-}")
    if [ "$reviewers" != "[]" ]; then
        jq -n --argjson all "$reviewers" '{
            reviewers: $all | map(select(contains("/") | not)),
            team_reviewers: $all | map(select(contains("/")) | sub("^[^/]*/"; ""))
        }' | gh api -X POST "repos/$repo/pulls/$number/requested_reviewers" --input - >/dev/null ||
            echo "::warning::Could not request reviews from $reviewers on $url."
    fi

    labels=$(list "${LABELS:-}")
    if [ "$labels" != "[]" ]; then
        jq -n --argjson labels "$labels" '{labels: $labels}' |
            gh api -X POST "repos/$repo/issues/$number/labels" --input - >/dev/null ||
            echo "::warning::Could not add the labels $labels to $url."
    fi
else
    echo "Nothing to propose."
fi

{
    echo "changed=$changed"
    echo "sha=$sha"
    echo "pull-request-number=$number"
    echo "pull-request-url=$url"
} >>"$GITHUB_OUTPUT"

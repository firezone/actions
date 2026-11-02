# firezone/actions

Composite actions shared by Firezone's repositories.

Both actions create commits through GitHub's GraphQL `createCommitOnBranch` mutation instead of `git push`, so GitHub signs them and they show as "Verified" without a GPG key.
Commits made with a GitHub App token start workflows like any push; commits made with `GITHUB_TOKEN` do not.

Pin them by full commit SHA:

```yaml
uses: firezone/actions/create-pull-request@<sha> # main
```

## `commit`

Commits the changes under `paths` onto `branch`, on top of its current head.

The changes are the difference between the checked-out commit and the working tree, including untracked and deleted files.
In a repository without commits, such as one made with `git init` to hold generated files for another repository, every file under `paths` is a change.
They are applied file by file onto the branch's head, so the branch may have moved since the checkout; a file the branch changed in the meantime fails the action, unless the branch already holds the wanted content.
If the branch moves while committing, the action re-reads it and tries again.

| Input        | Required | Description                                                                                  |
| ------------ | -------- | -------------------------------------------------------------------------------------------- |
| `token`      | yes      | A token with `contents: write`.                                                              |
| `branch`     | yes      | The branch to commit to.                                                                     |
| `repository` | no       | The repository to commit to, as `owner/name`. Defaults to the current repository.            |
| `message`    | yes      | The commit message. The first line is the headline.                                          |
| `paths`      | yes      | Newline-separated pathspecs, relative to the repository root, such as `docs` or `src/*.png`. |
| `base`       | no       | The branch to create `branch` from if it does not exist, or to reset it to.                  |
| `reset`      | no       | If `true`, the commit replaces whatever `branch` holds on top of `base`.                     |

| Output | Description                              |
| ------ | ---------------------------------------- |
| `sha`  | The commit, or empty if nothing changed. |

Changes with more than 10 MiB of base64-encoded contents are split into several chained commits, whose headlines end in `(1/n)`.
The API cannot record file modes: new files are committed as regular, non-executable files, and symbolic links and submodules are rejected.

## `create-pull-request`

Resets `branch` to `base`, commits the changes under `paths` onto it with `commit`, and opens a pull request, or updates the title and body of the one already open.
It leaves an open pull request alone if its branch already holds the same changes.

| Input            | Required | Description                                                                                          |
| ---------------- | -------- | ---------------------------------------------------------------------------------------------------- |
| `token`          | yes      | A token with `contents: write` and `pull-requests: write`.                                           |
| `branch`         | yes      | The pull request's branch.                                                                           |
| `base`           | no       | The branch to merge into. Defaults to the repository's default branch.                               |
| `title`          | yes      | The pull request title.                                                                              |
| `body`           | no       | The pull request body.                                                                               |
| `paths`          | yes      | As for `commit`.                                                                                     |
| `commit-message` | no       | The commit message. Defaults to the title.                                                           |
| `reviewers`      | no       | Comma- or newline-separated users or `org/team` slugs to request reviews from when the PR is opened. |
| `labels`         | no       | Comma- or newline-separated labels to add when the PR is opened.                                     |

| Output                | Description                                           |
| --------------------- | ----------------------------------------------------- |
| `changed`             | `true` if a commit was made or a pull request opened. |
| `sha`                 | The commit, or empty if nothing changed.              |
| `pull-request-number` | The open pull request's number, if there is one.      |
| `pull-request-url`    | The open pull request's URL, if there is one.         |

## Usage

Firezone's automation acts as the `firezone-ci` GitHub App.
Its client ID is the organization variable `BOT_CLIENT_ID` and its private key the organization secret `BOT_PRIVATE_KEY`.
Mint a token per job, scoped to the repository and permissions the job needs:

```yaml
jobs:
  bump:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: ./scripts/bump-version.sh
      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
        id: app-token
        with:
          client-id: ${{ vars.BOT_CLIENT_ID }}
          private-key: ${{ secrets.BOT_PRIVATE_KEY }}
          repositories: ${{ github.repository }}
          permission-contents: write
          permission-pull-requests: write
      - uses: firezone/actions/create-pull-request@<sha> # main
        with:
          token: ${{ steps.app-token.outputs.token }}
          branch: chore/bump-version
          title: "chore: bump the version"
          paths: |
            Cargo.toml
            Cargo.lock
          reviewers: firezone/engineering
```

# github-graph

A tool to duplicate files across multiple GitHub repositories.
An upstream _source_ repository serves as the single source of truth for a collection of files.
Changes to the content of the _source_ are automatically applied to each of a series of downstream _target_ respositories.
This is by means of an automatic pull request that is opened in each,
and can be chained across multiple steps as an arbitrary [directed acyclic graph](https://en.wikipedia.org/wiki/Directed_acyclic_graph).

## Use Cases

The typical use case might involve an organisation with a canonical license, style rulebook, [linter](https://en.wikipedia.org/wiki/Lint_(software)) configuration, set of IDE plugin recommendations, contributer information, code of conduct, [gitignore](https://github.com/github/gitignore), etc.
With multiple projects, this information is duplicated unnecessarily.
When updating something, one is forced to either go through the tedious process of updating each project individually,
or accept that things will get out of sync.
But no longer! With `git-graph`, all of this and more can be defined once, and used everywhere.

## Installation

Installation is done for the _source_ repository,
this being the repository that you want to sync files _from_.
No separate installation is needed for the _target_ repositories.

### 1. Add the synchronisation workflow

In your source repository, create a workflow definition file `.github/workflows/sync.yml`:

```yaml
name: Sync

on:
  push:
  workflow_dispatch:

jobs:
  sync:
    uses: SgtSwagrid/github-graph/workflows/sync.yml@main
    secrets: inherit
```

As written, this will trigger the synchronisation procedure when (any branch of) the source repository is pushed to.
It doesn't matter now if you only want to sync from one branch (e.g. `main`), this is configured later.
Nevertheless, feel free to modify the above to suit your needs.

### 2. Add a configuration file

Create the configuration file `.github/graph.json` in your source repository.
This is where you can list all downstream targets that depend on this repository.
See [configuration](#configuration) below for details.

### 3. Create a Personal Access Token

In order for GitHub Actions to automatically create pull requests in the target repositories,
you'll need a [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) (PAT) with appropriate permissions in each:
- Push to unprotected branches
- Open pull requests

Once created, add it to your source repository's secrets under **Settings → Secrets and variables → Actions → New repository secret**.
By default, `github-graph` expects the token to be called `GH_TOKEN`.
Don't worry if you need to use a different token for each target repository,
that situation is covered in [configuration](#configuration).

## Architecture

### Push-based updates

Follows a push-based model.
This is true both in the [git](https://git-scm.com/docs/git-push) sense and in the [reactive programming](https://www.baeldung.com/cs/reactive-programming) sense.
Changes _pushed_ to the source are _eagerly_ propagated (i.e. _pushed_) downstream.
A [GitHub Actions](https://github.com/features/actions) workflow in the source repository listens for pushes to a designated branch and directory,
in response to which pull requests are automatically opened.

### Circular dependencies

You needn't worry about circular dependencies creating a runaway robot takeover,
as (a) the process stops if there are no changes, and (b) each propagation step still requires manual review.

## Configuration

All fields except `target.owner` and `target.name` are optional. Fields set at the top level are inherited by all children but can be overridden per-child.

### `children`

A list of target repositories to sync files into.

```json
{
  "children": [
    { "target": { "owner": "my-org", "name": "repo-a" } },
    { "target": { "owner": "my-org", "name": "repo-b" } }
  ]
}
```

### `ignore`

Glob patterns for files to exclude from syncing, relative to the source root. Patterns follow `*`, `**`, `?`, and `[...]` syntax. Top-level patterns are merged with any per-child patterns.

```json
{
  "ignore": ["README.md", ".github/*", "docs/**"]
}
```

### `source`

| Field    | Description                                            | Default              |
|----------|--------------------------------------------------------|----------------------|
| `branch` | Branch to sync from.                                   | Repository default   |
| `root`   | Directory within the source repository to copy from.   | `"."`                |

### `target`

| Field        | Description                                                | Default              |
|--------------|------------------------------------------------------------|----------------------|
| `owner`      | Owner of the target repository. **Required.**              |                      |
| `name`       | Name of the target repository. **Required.**               |                      |
| `branch`     | Branch to sync into.                                       | Repository default   |
| `root`       | Directory within the target repository to copy files into. | `"."`                |
| `syncBranch` | Staging branch used to open pull requests.                 | Auto-generated       |

### `token`

The name of the GitHub Actions secret containing the access token.

```json
{ "token": "MY_CUSTOM_TOKEN" }
```

### `pullRequest`

| Field   | Description                          |
|---------|--------------------------------------|
| `title` | Template string for the PR title.    |
| `body`  | Template string for the PR body.     |

The following variables are available in templates:

| Variable             | Description                                      |
|----------------------|--------------------------------------------------|
| `$SOURCE_OWNER`      | Owner of the source repository.                  |
| `$SOURCE_NAME`       | Name of the source repository.                   |
| `$SOURCE_REPOSITORY` | Full name of the source repository (`owner/name`). |
| `$SOURCE_URL`        | URL of the source repository.                    |
| `$SOURCE_BRANCH`     | Branch being synced from.                        |
| `$SOURCE_BRANCH_URL` | URL of the source branch.                        |
| `$SOURCE_ROOT`       | Source root directory.                           |
| `$SOURCE_COMMIT`     | SHA of the commit that triggered the sync.       |
| `$SOURCE_COMMIT_URL` | URL of the triggering commit.                    |
| `$SOURCE_CONFIG_URL` | URL of the `graph.json` config file.             |
| `$TARGET_OWNER`      | Owner of the target repository.                  |
| `$TARGET_NAME`       | Name of the target repository.                   |
| `$TARGET_REPOSITORY` | Full name of the target repository (`owner/name`). |
| `$TARGET_URL`        | URL of the target repository.                    |
| `$TARGET_BRANCH`     | Branch being synced into.                        |
| `$TARGET_ROOT`       | Target root directory.                           |

### Example

Sync a shared CI configuration from a template repository into several projects, excluding per-project files:

```json
{
  "$schema": "https://raw.githubusercontent.com/SgtSwagrid/github-graph/main/graph.schema.json",
  "ignore": ["README.md", "LICENSE.md", ".github/*"],
  "source": {
    "root": "template"
  },
  "children": [
    {
      "target": { "owner": "my-org", "name": "project-a" }
    },
    {
      "target": { "owner": "my-org", "name": "project-b" },
      "ignore": ["config/local.yml"]
    }
  ]
}
```

## Alternatives

### What's wrong with Git [Submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules)?

Git submodules is a similar, in-built solution whereby repositories can be nested as subdirectories of other repositories.
If this meets your use case, then great.
However, a key limitation is that nested repositories have to be fully contained within isolated directories.
In practice, and in fact for most of the example [use cases](#use-cases) listed, you'll instead want this content to be mixed in with everything else.

### What's wrong with external references?

Instead of [inlining](https://en.wikipedia.org/wiki/Inline_expansion) the concerned files straight into each repository,
why not just link to them and direct users or build tools straight to the source?
The computer-sciency answer is that sometimes, especially for small things, inlines are more efficient despite the extra duplication.
But the real reason is that many tools don't support indirection.
You can't tell GitHub "I don't have a `.gitignore`, but look over there at that other project, I'd like to use theirs".
Additionally, the use of external references can violate the principle of [hermeticity](https://bazel.build/basics/hermeticity).

## Limitations

The following limitations apply.
Relaxation of any of these is considered out-of-scope and won't be addressed.
That being said, if you wanted to tackle these yourself, I'd be a very grateful PR recipient.

### Merge semantics

Updated files are never "merged", but simply overwrite whatever exists downstream.
`github-graph` is only intended for use when the responsibility for each file can be unambiguously associated with a single source repository,
with the understanding that copies shouldn't be modified.

### Platform support

This approach is heavily coupled with the GitHub ecosystem.
We assume GitHub URL formats, the availability of GitHub Actions, with GitHub-provided environment variables.
No support is offered for other platforms
(I'm very sorry to [GitLab](https://gitlab.com), [Bitbucket](https://bitbucket.org), etc.).

### No pull-based syncing

There is currently no option to sync in a pull-based manner,
i.e. with the dependency registered in the target rather than in the source, and with periodic polling for updates.
Unlike the other limitations, I will consider supporting this in the future.

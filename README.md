<div align="center">
  <h1>🕸️ GitHub Graph</h1>
  <p>A tool to duplicate files across multiple GitHub repositories.</p>
</div>

## 📌 Overview 

An upstream _source_ repository serves as the single source of truth for a collection of files.
Changes to the content of the _source_ are automatically applied to each of a series of downstream _target_ respositories.
This is by means of an automatic pull request that is opened in each,
and can be chained across multiple steps as an arbitrary [directed acyclic graph](https://en.wikipedia.org/wiki/Directed_acyclic_graph).

## 💡 Use Cases

The typical use case might involve an organisation with a canonical license, style rulebook, [linter](https://en.wikipedia.org/wiki/Lint_(software)) configuration, set of IDE plugin recommendations, contributer information, code of conduct, [gitignore](https://github.com/github/gitignore), etc.
With multiple projects, this information is duplicated unnecessarily.
When updating something, one is forced to either go through the tedious process of updating each project individually,
or accept that things will get out of sync.
But no longer! With `github-graph`, all of this and more can be defined once, and used everywhere.

## ⬇️ Installation

Installation is done for the _source_ repository,
that being the repository that you want to sync files _from_.
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
    uses: SgtSwagrid/github-graph/.github/workflows/sync.yml@main
    secrets: inherit
```

As written, this will trigger the synchronisation procedure when (any branch of) the source repository is pushed to.
It doesn't matter now if you only want to sync from one branch (e.g. `main`), this is configured later.
Nevertheless, feel free to modify the trigger to suit your needs.

### 2. Add a configuration file

Create the configuration file `.github/graph.json` in your source repository.
This is where you can enumerate all downstream targets that depend on this repository.
See [configuration](#configuration) below for details.

### 3. Create a Personal Access Token

In order for GitHub Actions to automatically create pull requests in the target repositories,
you'll need a [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) (PAT) with at least the following permissions in each repository:
- `Contents` with access `Read and write`.
- `Pull requests` with access `Read and write`.

You can manage your tokens [here](https://github.com/settings/personal-access-tokens).
Once created, add it to your source repository's secrets under:
> **Settings → Secrets and variables → Actions → New repository secret**

By default, `github-graph` expects the token to be called `GH_TOKEN`.
Don't worry if you need to use a different token for each target repository,
that situation is covered [here](#token).

## 🏯 Architecture

### Push-based updates

Follows a push-based model.
This is true both in the [git](https://git-scm.com/docs/git-push) sense and in the [reactive programming](https://www.baeldung.com/cs/reactive-programming) sense.
Changes _pushed_ to the source are _eagerly_ propagated (i.e. _pushed_) downstream.
A [GitHub Actions](https://github.com/features/actions) workflow in the source repository listens for pushes to a designated branch and directory,
in response to which pull requests are automatically opened.

### Circular dependencies

You needn't worry about circular dependencies creating a runaway robot takeover,
as (a) the process stops if there are no changes, and (b) each propagation step still requires manual review.

## ⚙️ Configuration

All configuration is defined in `.github/graph.json`, and can be done _globally_ or _per-target_.
When a target-specific setting conflicts with a global one, the target-specific setting takes precedence.

### `children`

A list of target repositories to sync files into.
Defined once at the top-level.

```json
{
  "children": [
    {
      "target": {
        "owner": "my-org",
        "name": "repo-a"
      }
    },
    {
      "target": {
        "owner": "my-org",
        "name": "repo-b"
      }
    }
  ]
}
```

Each child corresonds to a single synchronisation task.
For every child, the keys `target.owner` and `target.name` are mandatory.
Everything else is optional.

### `target`

Details about the downstream target repository to sync files into.
Can be defined for a child, or globally at the top-level.
The following sub-fields are available:

| Field        | Description                                                | Default                                            |
|--------------|------------------------------------------------------------|----------------------------------------------------|
| `owner`      | Owner of the target repository.                            | **Required**                                       |
| `name`       | Name of the target repository.                             | **Required**                                       |
| `branch`     | Branch to sync into.                                       | Repository default (e.g. often `main` or `master`) |
| `syncBranch` | Staging branch used to open pull requests.                 | Automatically generated                            |
| `root`       | Directory within the target repository to copy files into. | Repository root (i.e. "`.`")                       |

### `source`

Details about the upstream source repository to sync files from.
Can be defined for a child, or globally at the top-level.
The following sub-fields are available:

| Field    | Description                                                | Default                                            |
|----------|------------------------------------------------------------|----------------------------------------------------|
| `branch` | Branch to sync from.                                       | Repository default (e.g. often `main` or `master`) |
| `root`   | Directory within the source repository to copy files from. | Repository root (i.e. "`.`")                       |

### `ignore`

A list of files to exclude from syncing, relative to `source.root`.
Patterns can use [glob](https://en.wikipedia.org/wiki/Glob_(programming)) syntax,
including `*`, `?`, and `[...]`, to match multiple files.
Can be defined for a child or globally at the top-level, with both lists being concatenated.
Defaults to `[]`, i.e. an empty list.

```json
{
  "ignore": [
    "README.md",
    ".github/*"
  ]
}
```

Generally, you'll at least want to ignore the `github-graph` setup itself,
i.e. `.github/workflows/sync.yml` and `.github/graph.json`,
as these aren't excluded automatically.
It is not necessary to ignore files which lie outside of `source.root`.

### `token`

The name of the GitHub Actions secret containing the access token for the target repository.
Can be defined for a child, or globally at the top-level.
Note that this is NOT for the token itself, just its name.
If you accidentally commit a token to a public repository, you should deactivate that token immediately.
Defaults to `GH_TOKEN`.

```json
{
  "token": "MY_CUSTOM_TOKEN"
}
```

### `pullRequest`

Cosmetic details for the pull requests that are automatically opened.
Can be defined for a child, or globally at the top-level.
The following sub-fields are available:

| Field   | Description                       | Default                                         |
|---------|-----------------------------------|-------------------------------------------------|
| `title` | Template string for the PR title. | [github-graph]: Synced files from %SOURCE_NAME. |
| `body`  | Template string for the PR body.  | See [here](templates/pull-request-body.md)      |

The following variables are available in the templates,
and can be substituted as strings by prepending `%` to their names:

| Variable            | Description                                        |
|---------------------|----------------------------------------------------|
| `SOURCE_OWNER`      | Owner of the source repository.                    |
| `SOURCE_NAME`       | Name of the source repository.                     |
| `SOURCE_REPOSITORY` | Full name of the source repository (`owner/name`). |
| `SOURCE_BRANCH`     | Branch being synced from.                          |
| `SOURCE_ROOT`       | Directory being synced from.                       |
| `SOURCE_COMMIT`     | SHA of the commit that triggered the sync.         |
| `SOURCE_URL`        | URL of the source repository.                      |
| `SOURCE_BRANCH_URL` | URL of the source branch.                          |
| `SOURCE_COMMIT_URL` | URL of the triggering commit.                      |
| `SOURCE_CONFIG_URL` | URL of the `graph.json` config file.               |
| `TARGET_OWNER`      | Owner of the target repository.                    |
| `TARGET_NAME`       | Name of the target repository.                     |
| `TARGET_REPOSITORY` | Full name of the target repository (`owner/name`). |
| `TARGET_BRANCH`     | Branch being synced into.                          |
| `TARGET_ROOT`       | Directory being synced into.                       |
| `TARGET_URL`        | URL of the target repository.                      |

## ⏪ Alternatives

### What's wrong with Git [Submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules)?

Git Submodules is a similar, in-built solution whereby repositories can be nested as subdirectories of other repositories.
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

### What's wrong with [multi-gitter](https://github.com/lindell/multi-gitter)?

`multi-gitter` is a tool that allows you to perform an update on multiple repositories at once.
This serves a different use case than having a unique source of truth for certain files.

## ❓ Limitations

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

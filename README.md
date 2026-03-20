# github-graph

A tool to duplicate files across multiple GitHub repositories.
An upstream _source_ repository serves as the single source of truth for a collection of files.
Changes to the content of the _source_ are automatically applied to each of a series of downstream _target_ respositories.
This is by means of an automatic pull request that is opened in each,
and can be chained across multiple steps as an arbitrary [directed acyclic graph](https://en.wikipedia.org/wiki/Directed_acyclic_graph).

## Use Cases

The typical use case might involve an organisation with a canonical license, style rulebook, [linter](https://en.wikipedia.org/wiki/Lint_(software)) configuration, set of IDE plugin recommendations, contributer information, code of conduct, gitignore, etc.
With multiple projects, this information is duplicated unnecessarily.
When updating something, one is forced to either go through the tedious process of updating each project individually,
or accept that things will get out of sync.
But no longer! With `git-graph`, all of this and more can be defined once, and used everywhere.

## Alternatives

### What's wrong with Git [Submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules)?

Git submodules is a similar, in-built solution whereby repositories can be nested as subdirectories of other repositories.
If this meets your use case, then great.
However, a key limitation is that nested repositories have to be fully contained within isolated directories.
In practice, and in fact for most of the examples listed, you'll instead want this content to be mixed in with everything else.

### What's wrong with extenal references?

Instead of [inlining](https://en.wikipedia.org/wiki/Inline_expansion) the concerned files straight into each repository,
why not just link to them and direct users or build tools straight to the source?
The computer-sciency answer is that sometimes, especially for small things, inlines are more efficient despite the extra duplication.
But the real reason is that many tools don't support indirection.
You can't tell GitHub "I don't have a `.gitignore`, but look over there at that other project, I'd like to use theirs".
Additionally, the use of external references can violate the principle of [hermeticity](https://bazel.build/basics/hermeticity).

## Architecture

### Push-based updates

Follows a push-based model.
This is true both in the [git](https://git-scm.com/docs/git-push) sense and in the [reactive programming](https://www.baeldung.com/cs/reactive-programming) sense.
A [GitHub Actions](https://github.com/features/actions) workflow in the source repository listens for pushes to a designated branch and directory,
in response to which pull requests are opened.

### Circular dependencies

You needn't worry about circular dependencies creating a runaway robot takeover,
as (a) the process stops if there are no changes, and (b) each propagation step still requires manual review.

## Limitations

Updated files are never "merged", but simply overwrite whatever exists downstream.
This is only intended for use when the responsibility for each file can be unambiguously associated with a single source repository,
with the understanding that copies shouldn't be modified.
There are no plans to relax this limitation.

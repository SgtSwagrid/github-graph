#github-graph

A tool to duplicate files across multiple GitHub repositories.
An upstream _source_ repository serves as the single source of truth for a collection of files.
Changes to the content of _source_ are automatically applied to each of a series of downstream _target_ respositories.
This is by means of an automatic pull request that is opened in each.
Can be chained across multiple steps as an arbitrary [directed acyclic graph](https://en.wikipedia.org/wiki/Directed_acyclic_graph).

## Architecture

Follows a push-based model.
This is true both in the [git](https://git-scm.com/docs/git-push) sense and in the [reactive programming](https://www.baeldung.com/cs/reactive-programming) sense.
A [GitHub Actions](https://github.com/features/actions) workflow in the source repository listens for pushes to a designated branch and directory,
in response to which pull requests are opened.
You needn't worry about circular dependencies creating a runaway robot takeover,
as (a) the process stops if there are no changes, and (b) each propagation step still requires manual review.

## Limitations

Updated files are never "merged", but simply overwrite whatever exists downstream.
This is only intended for use when the responsibility for each file can be unambiguously associated with a single source repository,
with the understanding that copies shouldn't be modified.
There are no plans to relax this limitation.

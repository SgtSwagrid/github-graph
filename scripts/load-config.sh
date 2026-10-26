#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Loads the configuration for a single downstream target from JSON into environment variables.
#
# Command-line arguments:
#   - $1 CHILD: The JSON object for the downstream target, as produced by `parse-config.sh`.
# =================================================================================================


CHILD="$1"

jq -r '
  "SOURCE_OWNER=\(.source.owner)",
  "SOURCE_NAME=\(.source.name)",
  "SOURCE_REPOSITORY=\(.source.repository)",
  "SOURCE_BRANCH=\(.source.branch)",
  "SOURCE_ROOT=\(.source.root)",
  "SOURCE_COMMIT=\(.source.commit)",
  "SOURCE_URL=\(.source.url)",
  "SOURCE_COMMIT_URL=\(.source.commitUrl)",
  "SOURCE_BRANCH_URL=\(.source.branchUrl)",
  "SOURCE_CONFIG_URL=\(.source.configUrl)",
  "TARGET_OWNER=\(.target.owner)",
  "TARGET_NAME=\(.target.name)",
  "TARGET_REPOSITORY=\(.target.repository)",
  "TARGET_BRANCH=\(.target.branch)",
  "TARGET_LEGACY_SYNC_BRANCH=\(.target.legacySyncBranch)",
  "TARGET_ROOT=\(.target.root)",
  "TARGET_URL=\(.target.url)",
  "IGNORE=\(.ignore | tojson)",
  "PR_TITLE=\(.pullRequest.title)"
' <<< "$CHILD" >> "$GITHUB_ENV"

# TARGET_BRANCH requires a runtime fallback to the target repository's default branch.
TARGET_BRANCH=$(jq -r '.target.branch' <<< "$CHILD")
DEFAULT_BRANCH=$(git -C target ls-remote --symref origin HEAD | sed -n 's|^ref: refs/heads/\(.*\)\tHEAD|\1|p')
TARGET_BRANCH="${TARGET_BRANCH:-$DEFAULT_BRANCH}"
echo "TARGET_BRANCH=$TARGET_BRANCH" >> "$GITHUB_ENV"

# TARGET_SYNC_BRANCH defaults to one per target branch, shared by every source which syncs into it.
TARGET_SYNC_BRANCH=$(jq -r '.target.syncBranch' <<< "$CHILD")
echo "TARGET_SYNC_BRANCH=${TARGET_SYNC_BRANCH:-sync/github-graph/$TARGET_BRANCH}" >> "$GITHUB_ENV"

# PR_BODY may contain newlines, so it requires the GitHub Actions multiline format.
PR_BODY=$(jq -r '.pullRequest.body' <<< "$CHILD")
delimiter="$(openssl rand -hex 8)"
{ echo "PR_BODY<<$delimiter"; echo "$PR_BODY"; echo "$delimiter"; } >> "$GITHUB_ENV"

# Each commit on the sync branch names the source directory it came from in a trailer, SYNC_TRAILER.
# This is a key rather than a name, as the source may be private while the target is public.
# The key is "<source>/<directory>", where the first half is shared by every directory synced from
# the same branch of the same source repository.
# A second trailer, SOURCE_TRAILER, names the source commit which the changes were taken from.
SOURCE_ID="${GITHUB_REPOSITORY_ID:-$(jq -r '.source.repository' <<< "$CHILD")}"
SOURCE_BRANCH=$(jq -r '.source.branch' <<< "$CHILD")
SOURCE_ROOT=$(jq -r '.source.root' <<< "$CHILD")
TARGET_ROOT=$(jq -r '.target.root' <<< "$CHILD")
digest() { printf '%s\n' "$@" | sha256sum | cut -c1-12; }
{
  echo "SYNC_TRAILER=GitHub-Graph-Sync"
  echo "SYNC_KEY=$(digest "$SOURCE_ID" "$SOURCE_BRANCH")/$(digest "$SOURCE_ID" "$SOURCE_BRANCH" "$SOURCE_ROOT" "$TARGET_ROOT")"
  echo "SOURCE_TRAILER=GitHub-Graph-Source"
} >> "$GITHUB_ENV"

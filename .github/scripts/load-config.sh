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
  "TARGET_SYNC_BRANCH=\(.target.syncBranch)",
  "TARGET_ROOT=\(.target.root)",
  "TARGET_URL=\(.target.url)",
  "IGNORE=\(.ignore | tojson)",
  "PR_TITLE=\(.pullRequest.title)"
' <<< "$CHILD" >> "$GITHUB_ENV"

# TARGET_BRANCH requires a runtime fallback to the target repository's default branch.
TARGET_BRANCH=$(jq -r '.target.branch' <<< "$CHILD")
DEFAULT_BRANCH=$(git -C target ls-remote --symref origin HEAD | sed -n 's|^ref: refs/heads/\(.*\)\tHEAD|\1|p')
echo "TARGET_BRANCH=${TARGET_BRANCH:-$DEFAULT_BRANCH}" >> "$GITHUB_ENV"

# PR_BODY may contain newlines, so it requires the GitHub Actions multiline format.
PR_BODY=$(jq -r '.pullRequest.body' <<< "$CHILD")
delimiter="$(openssl rand -hex 8)"
{ echo "PR_BODY<<$delimiter"; echo "$PR_BODY"; echo "$delimiter"; } >> "$GITHUB_ENV"

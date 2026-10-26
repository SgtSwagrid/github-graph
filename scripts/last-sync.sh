#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Finds the source commit from which the target last merged a sync of this source directory,
# so that `merge-files.sh` deletes the files which the source has deleted since.
#
# That commit is named by the SOURCE_TRAILER of this source directory's commit in the most recently
# merged pull request from the sync branch, which GitHub keeps after a merge however it was done.
# Until the target has merged one, as at the first sync, it falls back to the commit before the push
# which triggered this sync, if there is one, so that the deletions made by that push are synced.
#
# Environment variables:
#   - GH_TOKEN:           A token which can read the target repository's pull requests.
#   - TARGET_REPOSITORY:  The name of the target GitHub repository as 'Username/Repository'.
#   - TARGET_BRANCH:      The branch into which the sync branch is merged.
#   - TARGET_SYNC_BRANCH: The name of the branch used to stage the pull request.
#   - SYNC_TRAILER:       The trailer naming the source directory of a commit on the sync branch.
#   - SYNC_KEY:           The value of SYNC_TRAILER for this source directory.
#   - SOURCE_TRAILER:     The trailer naming the source commit which a commit was taken from.
#   - SOURCE_BEFORE:      The commit before the push which triggered this sync, if any.
#
# Output:
#   - SOURCE_SYNCED: The commit, or nothing if there is none, sent to GITHUB_ENV.
# =================================================================================================


# The message of this source directory's commit in each merged pull request, most recent first,
# and in it, the source commit it was taken from.
synced=$(
  gh pr list \
    --repo "$TARGET_REPOSITORY" \
    --head "$TARGET_SYNC_BRANCH" \
    --base "$TARGET_BRANCH" \
    --state merged \
    --limit 20 \
    --json mergedAt,isCrossRepository,commits \
    --jq "
      map(select(.isCrossRepository | not)) | sort_by(.mergedAt) | reverse |
      [.[].commits[].messageBody | select(contains(\"$SYNC_TRAILER: $SYNC_KEY\"))] |
      .[0] // \"\"
    " |
  sed -n "s/^$SOURCE_TRAILER: \([0-9a-f]*\)$/\1/p" | head -n 1
)

# The commit before a push which created its branch is all zeros.
before="${SOURCE_BEFORE:-}"
if [[ "$before" =~ ^0*$ ]]; then before=""; fi

if [[ -n "$synced" ]]; then
  echo "Syncing deletions since $synced, the source commit of the last sync which $TARGET_REPOSITORY merged."
elif [[ -n "$before" ]]; then
  synced="$before"
  echo "Syncing deletions since $synced, the commit before this push," \
    "as no sync which $TARGET_REPOSITORY merged names its source commit."
else
  echo "Syncing no deletions, as no sync which $TARGET_REPOSITORY merged names its source commit," \
    "and there is no commit before this push to compare with."
fi
echo "SOURCE_SYNCED=$synced" >> "$GITHUB_ENV"

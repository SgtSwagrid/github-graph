#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Locally applies updates from the source repository into the target repository.
#
# Environment variables:
#   - IGNORE: A JSON-formatted list of file paths to exclude from syncing.
#   - SOURCE_ROOT: The root directory within the source repository to copy files from.
#   - TARGET_ROOT: The root directory within the target repository to copy files into.
#   - SOURCE_SYNCED: The source commit from which the target last merged a sync, or nothing.
#
# Requirements:
#   - source/ should already contain the source repository at the correct branch, with full history.
#   - target/ should already contain the target repository at the correct branch.
# =================================================================================================


# =================================================================================================
# Setup
# =================================================================================================

shopt -s globstar

# Load ignore list into an array of glob patterns.
# shellcheck disable=SC2153
mapfile -t IGNORED < <(jq -r '.[]?' <<< "$IGNORE")

# Determine whether a file matches any pattern in the ignore list.
is_ignored() {
  local file="$1" pattern
  for pattern in "${IGNORED[@]}"; do
    # shellcheck disable=SC2053
    if [[ "$file" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# Convert a file name that is relative to SOURCE_ROOT to an absolute path in the target repository.
target_path() {
  local prefix="$SOURCE_ROOT/"
  echo "target/$TARGET_ROOT/${1#"$prefix"}"
}

# =================================================================================================
# 1. Copy all files in the SOURCE_ROOT directory of the source repository
#    to the TARGET_ROOT directory of the target repository.
#    Files in the ignore list or outside of SOURCE_ROOT are skipped.
#    Files which already exist in the target repository are replaced.
# =================================================================================================

while IFS= read -r -d '' file; do
  if is_ignored "${file#"$SOURCE_ROOT/"}"; then
    echo "Skipped: $file"
  else
    dest=$(target_path "$file")
    mkdir -p "$(dirname "$dest")"
    cp "source/$file" "$dest"
    echo "Copied: $file"
  fi
done < <(git -C source ls-files -z -- "$SOURCE_ROOT")

# =================================================================================================
# 2. Delete from the target repository the files which the source has deleted since SOURCE_SYNCED,
#    the commit from which the target last merged a sync, so that each deletion is synced once.
#    A sync which is skipped or fails is made up for by the next, as it covers everything since.
#    Files in the ignore list or outside of SOURCE_ROOT are skipped.
# =================================================================================================

if [[ -z "${SOURCE_SYNCED:-}" ]]; then
  exit 0
fi
if ! git -C source cat-file -e "$SOURCE_SYNCED^{commit}" 2> /dev/null; then
  echo "::warning::Skipped deletions, as $SOURCE_SYNCED isn't in the history of the source."
  exit 0
fi

while IFS= read -r -d '' file; do
  if is_ignored "${file#"$SOURCE_ROOT/"}"; then continue; fi
  dest=$(target_path "$file")
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm "$dest"
    echo "Deleted: $file"
  fi
done < <(git -C source diff -z --name-only --no-renames --diff-filter=D "$SOURCE_SYNCED" HEAD -- "$SOURCE_ROOT")

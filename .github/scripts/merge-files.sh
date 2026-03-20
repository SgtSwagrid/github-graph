#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Locally applies updates from the source repository into the target repository.
#
# Environment variables:
#   - IGNORE: A JSON-formatted list of file paths to exclude from syncing.
#   - SOURCE_ROOT: The root directory within the source repository to copy files from.
#   - TARGET_ROOT: The root directory within the target repository to copy files into.
#
# Requirements:
#   - source/ should already contain the source repository at the correct branch.
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

# A set of names of all files which lie in the SOURCE_ROOT directory of the source repository.
declare -A SOURCE_FILES
while IFS= read -r line; do
  SOURCE_FILES["$line"]=1;
done < <(git -C source ls-files -- "$SOURCE_ROOT")

# Copy every tracked file from the source to the target repository.
for file in "${!SOURCE_FILES[@]}"; do
  if is_ignored "$file"; then
    echo "Skipped: $file"
  else
    dest=$(target_path "$file")
    mkdir -p "$(dirname "$dest")"
    cp "source/$file" "$dest"
    echo "Copied: $file"
  fi
done

# =================================================================================================
# 2. Delete from the target repository all files which once existed in the source repository,
#    but which have since been deleted from the source repository.
#    Files in the ignore list or outside of SOURCE_ROOT are skipped.
# =================================================================================================

# A list of names of all files which have been deleted from the source repository.
mapfile -t SOURCE_DELETED < <(
  git -C source log --diff-filter=D --name-only --pretty=format: | sort -u
)

for file in "${SOURCE_DELETED[@]}"; do
  # Ignore because file name is empty.
  if [[ -z "$file" ]]; then :
  # Ignore because file is outside SOURCE_ROOT.
  elif [[ "$SOURCE_ROOT" != "." && "$file" != "$SOURCE_ROOT"/* ]]; then :
  # Ignore because file is in ignore list.
  elif is_ignored "$file"; then :
  # Ignore because file was re-added.
  elif [[ -n "${SOURCE_FILES[$file]+_}" ]]; then :
  # Delete the file if none of the exclusions apply.
  else
    dest=$(target_path "$file")
    if [[ -e "$dest" ]]; then
      rm "$dest"
      echo "Deleted: $file"
    fi
  fi
done

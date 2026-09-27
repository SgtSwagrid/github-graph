#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Locally applies updates from the source repository into the target repository.
#
# Environment variables:
#   - IGNORE: A JSON-formatted list of file paths to exclude from syncing.
#   - SOURCE_ROOT: The root directory within the source repository to copy files from.
#   - TARGET_ROOT: The root directory within the target repository to copy files into.
#   - SYNC_DELETIONS: Whether to delete files from the target which were deleted from the source.
#
# Requirements:
#   - source/ should already contain the source repository at the correct branch, with full history.
#   - target/ should already contain the target repository at the correct branch, with full history.
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

# Convert a file name that is relative to SOURCE_ROOT to a normalised path relative to the target repository.
target_relative_path() {
  realpath -ms --relative-to=target "$(target_path "$1")"
}

# Output the first-parent history of a branch, as NUL-separated records of the form:
#   <commit time> <blob> <status> <file>
# There is one record for each file changed by each commit, with renames treated as a deletion plus an addition.
# Following only the first parent means that each change is dated by when it actually landed on the branch.
#   - $1: The repository directory.
#   - $@: Any further arguments are passed to `git log`.
file_history() {
  local repo="$1" token timestamp="" blob status file
  shift
  while IFS= read -r -d '' token; do
    if [[ "$token" =~ ^[[:space:]]*:(.*)$ ]]; then
      read -r _ _ _ blob status <<< "${BASH_REMATCH[1]}"
      IFS= read -r -d '' file
      printf '%s\0' "$timestamp" "$blob" "$status" "$file"
    elif [[ "$token" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      timestamp="${BASH_REMATCH[1]}"
    fi
  done < <(
    git -C "$repo" log --first-parent --diff-merges=first-parent --no-renames --raw --no-abbrev -z --format='%ct' "$@"
  )
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
  relative="${file#"$SOURCE_ROOT/"}"
  if is_ignored "$relative"; then
    echo "Skipped: $file"
  else
    dest=$(target_path "$file")
    mkdir -p "$(dirname "$dest")"
    cp "source/$file" "$dest"
    echo "Copied: $file"
  fi
done

# =================================================================================================
# 2. Delete from the target repository all files which were synced from the source repository,
#    but which have since been deleted from the source repository.
#    Files in the ignore list or outside of SOURCE_ROOT are skipped.
#    As the target may have files of its own with the same names, a file is only deleted if:
#      a) It originated from the source.
#         i.e. When it was last added to the target, it matched a version which the source once had.
#      b) It hasn't been re-added to the target since being deleted from the source.
#         i.e. It was last added to the target before it was deleted from the source.
#      c) It hasn't been modified in the target.
#         i.e. It currently matches a version which the source once had.
# =================================================================================================

if [[ "$SYNC_DELETIONS" != "true" ]]; then
  echo "Skipped deletions, as syncDeletions is disabled."
  exit 0
fi

# Provenance can't be determined without the full history of both repositories.
if [[ "$(git -C source rev-parse --is-shallow-repository)" == "true" ||
      "$(git -C target rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "::warning::Skipped deletions, as they require the full history of both repositories."
  exit 0
fi

# For every file in SOURCE_ROOT which was ever in the source repository:
#   - DELETED_AT: The time at which it was deleted from the source, or empty if it still exists.
#   - SOURCE_VERSIONS: The set of versions it has had in the source, keyed by "<blob>:<file>".
declare -A DELETED_AT SOURCE_VERSIONS
while IFS= read -r -d '' timestamp && IFS= read -r -d '' blob && IFS= read -r -d '' status && IFS= read -r -d '' file; do
  if [[ "$status" == "D" ]]; then
    DELETED_AT["$file"]="$timestamp"
  else
    DELETED_AT["$file"]=""
    SOURCE_VERSIONS["$blob:$file"]=1
  fi
done < <(file_history source --reverse -- "$SOURCE_ROOT")

for file in "${!DELETED_AT[@]}"; do
  deleted_at="${DELETED_AT[$file]}"

  # Ignore because file still exists in the source.
  if [[ -z "$deleted_at" ]]; then continue; fi
  # Ignore because file is in ignore list.
  if is_ignored "${file#"$SOURCE_ROOT/"}"; then continue; fi

  # Ignore because file doesn't exist in the target.
  dest=$(target_relative_path "$file")
  current=$(git -C target rev-parse -q --verify "HEAD:$dest") || continue

  # Find when the file was last added to the target, and with which version.
  added_at="" added_blob=""
  while IFS= read -r -d '' timestamp && IFS= read -r -d '' blob && IFS= read -r -d '' status && IFS= read -r -d '' path; do
    if [[ "$path" == "$dest" ]]; then
      added_at="$timestamp" added_blob="$blob"
      break
    fi
  done < <(file_history target --diff-filter=A -- ":(literal)$dest")

  if [[ -z "$added_at" || -z "${SOURCE_VERSIONS["$added_blob:$file"]+_}" ]]; then
    echo "Kept: $file (didn't originate from the source)"
  elif (( added_at >= deleted_at )); then
    echo "Kept: $file (re-added after being deleted from the source)"
  elif [[ -z "${SOURCE_VERSIONS["$current:$file"]+_}" ]]; then
    echo "Kept: $file (modified after being synced from the source)"
  else
    rm "target/$dest"
    echo "Deleted: $file"
  fi
done

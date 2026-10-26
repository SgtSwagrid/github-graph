#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Locally applies the changes from the source repository to the target repository.
#
# Every file which the source has ever had in SOURCE_ROOT is given the state it now has in the
# source: its current version, or none if it was deleted. But the target may change a file itself,
# or have a file of its own with the same name, so the source's state is only given to a file
# whose last change in the target came from the source:
#   a) Its state in the target is one which the source had before the target last changed it.
#      A file's absence counts as a state which the source had once the source deleted it.
#   b) The source has changed it since the target last changed it.
# A file which the target never had is given the source's state.
# So a file which the target has modified, deleted or re-added is left alone from then on,
# as is one which the target had of its own before the source added it.
#
# Environment variables:
#   - IGNORE: A JSON-formatted list of file paths to exclude from syncing.
#   - SOURCE_ROOT: The root directory within the source repository to copy files from.
#   - TARGET_ROOT: The root directory within the target repository to copy files into.
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
# The blob of a deleted file is ABSENT.
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

# The state of a file which doesn't exist: the blob which git gives a deleted file, all zeros.
ABSENT=$(git -C source hash-object --stdin < /dev/null | tr '0-9a-f' '0')

# Whose change was whose can't be told without the full history of both repositories.
if [[ "$(git -C source rev-parse --is-shallow-repository)" == "true" ||
      "$(git -C target rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "::error::Syncing requires the full history of both repositories."
  exit 1
fi

# =================================================================================================
# 1. Read the history of every file which the source has ever had in SOURCE_ROOT:
#      - STATE: Its state now, i.e. its current blob, or ABSENT if it has been deleted.
#      - CHANGED: When the source last changed it.
#      - SINCE: When the source first had each of its states, keyed by "<state>:<file>".
# =================================================================================================

declare -A STATE CHANGED SINCE
while IFS= read -r -d '' timestamp && IFS= read -r -d '' blob && IFS= read -r -d '' status && IFS= read -r -d '' file; do
  STATE["$file"]="$blob"
  CHANGED["$file"]="$timestamp"
  if [[ -z "${SINCE["$blob:$file"]+_}" ]]; then SINCE["$blob:$file"]="$timestamp"; fi
done < <(file_history source --reverse -- "$SOURCE_ROOT")

# =================================================================================================
# 2. Give each file in the target the state it has in the source, if the file is the source's.
#    Files in the ignore list are skipped.
# =================================================================================================

for file in "${!STATE[@]}"; do
  if is_ignored "${file#"$SOURCE_ROOT/"}"; then
    echo "Skipped: $file"
    continue
  fi

  wanted="${STATE[$file]}"
  dest=$(target_relative_path "$file")
  current=$(git -C target rev-parse -q --verify "HEAD:$dest") || current="$ABSENT"
  if [[ "$current" == "$wanted" ]]; then continue; fi

  # When the target last changed the file, dated by when the change landed on its branch,
  # or nothing if it never had the file.
  changed_at=$(git -C target log -1 --first-parent --format=%ct -- ":(literal)$dest")
  if [[ -n "$changed_at" ]]; then
    since="${SINCE["$current:$file"]:-}"
    source_changed_at="${CHANGED[$file]}"
    if [[ -z "$since" ]] || (( since > changed_at )); then
      echo "Kept: $file (changed in the target)"
      continue
    elif (( source_changed_at <= changed_at )); then
      echo "Kept: $file (changed in the target since the source last changed it)"
      continue
    fi
  fi

  if [[ "$wanted" == "$ABSENT" ]]; then
    rm "target/$dest"
    echo "Deleted: $file"
  else
    mkdir -p "$(dirname "target/$dest")"
    cp "source/$file" "target/$dest"
    if [[ "$current" == "$ABSENT" ]]; then echo "Added: $file"; else echo "Updated: $file"; fi
  fi
done

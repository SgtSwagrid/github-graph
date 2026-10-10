#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

# =================================================================================================
# Adds the changes to the sync branch of the target repository, and opens or updates its pull request.
#
# Every sync into the same branch of the target shares one sync branch, and so one pull request.
# The sync branch holds one commit for each source directory with changes, on top of TARGET_BRANCH.
# Each sync rebuilds it on the latest TARGET_BRANCH, keeping the commits of every other source
# directory as they are, and replacing its own with the changes which have just been merged.
#
# Environment variables:
#   - PR_TITLE:                  The template string used to generate pull request titles.
#   - PR_BODY:                   The template string used to generate pull request descriptions.
#   - SOURCE_REPOSITORY:         The name of the source GitHub repository as 'Username/Repository'.
#   - SOURCE_BRANCH:             The branch of the source repository being synced from.
#   - SOURCE_ROOT:               The directory within the source repository being synced from.
#   - TARGET_REPOSITORY:         The name of the target GitHub repository as 'Username/Repository'.
#   - TARGET_BRANCH:             The branch into which we wish to merge.
#   - TARGET_ROOT:               The directory within the target repository being synced into.
#   - TARGET_SYNC_BRANCH:        The name of the branch used to stage the pull request.
#   - TARGET_LEGACY_SYNC_BRANCH: The branch which older versions staged these changes on, if any.
#   - GITHUB_REPOSITORY_ID:      The ID of the source repository, as provided by GitHub Actions.
#
# Requirements:
#   - target/ should contain the target repository at TARGET_BRANCH, with full history,
#     and with the changes from the source directory already having been merged.
# =================================================================================================


# =================================================================================================
# Setup
# =================================================================================================

# Substitute environment variables in user-defined strings.
SAFE_VARS="\$SOURCE_REPOSITORY \$SOURCE_OWNER \$SOURCE_NAME \$SOURCE_URL \$SOURCE_BRANCH \$SOURCE_BRANCH_URL
           \$SOURCE_ROOT \$SOURCE_COMMIT \$SOURCE_COMMIT_URL \$SOURCE_CONFIG_URL \$TARGET_REPOSITORY \$TARGET_OWNER
           \$TARGET_NAME \$TARGET_URL \$TARGET_BRANCH \$TARGET_ROOT"
PR_TITLE=$(envsubst "$SAFE_VARS" <<< "$PR_TITLE")
PR_BODY=$(envsubst  "$SAFE_VARS" <<< "$PR_BODY")

cd target

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git remote set-url origin "${TARGET_URL/https:\/\//https://x-access-token:${GH_TOKEN}@}.git"

# Each commit on the sync branch names the source directory it came from in a trailer.
# This is a key rather than a name, as the source may be private while the target is public.
# The key is "<source>/<directory>", where the first half is shared by every directory synced from
# the same branch of the same source repository.
TRAILER="GitHub-Graph-Sync"
SOURCE_ID="${GITHUB_REPOSITORY_ID:-$SOURCE_REPOSITORY}"
digest() { printf '%s\n' "$@" | sha256sum | cut -c1-12; }
KEY="$(digest "$SOURCE_ID" "$SOURCE_BRANCH")/$(digest "$SOURCE_ID" "$SOURCE_BRANCH" "$SOURCE_ROOT" "$TARGET_ROOT")"

# The pull request title once it holds the changes from sources with different titles,
# and what separates the descriptions from each source.
COMBINED_TITLE="[github-graph] Synced files from several repositories."
SEPARATOR=$'\n\n---\n\n'

# Private refs for the latest fetched TARGET_BRANCH and TARGET_SYNC_BRANCH.
TARGET_REF="refs/github-graph/target"
SYNC_REF="refs/github-graph/sync"

# How many times to try updating the sync branch, as this fails if another sync updates it meanwhile.
ATTEMPTS=10

# Wait for a random while before trying again, so that concurrent syncs don't keep colliding.
#   - $1: The number of attempts so far.
backoff() {
  sleep $(( RANDOM % (5 * $1) + 1 ))
}

# Output the commit at the tip of a branch of the target repository, or nothing if it doesn't exist.
#   - $1: The name of the branch.
remote_tip() {
  git ls-remote origin "refs/heads/$1" | awk -v ref="refs/heads/$1" '$2 == ref { print $1 }'
}

# Fetch the sync branch into SYNC_REF, and output its commit, or nothing if it doesn't exist.
fetch_sync_branch() {
  local tip
  tip=$(remote_tip "$TARGET_SYNC_BRANCH")
  if [[ -n "$tip" ]]; then
    git fetch -q origin "+refs/heads/$TARGET_SYNC_BRANCH:$SYNC_REF"
    git rev-parse "$SYNC_REF"
  fi
}

# Output the number of the open pull request from a branch into TARGET_BRANCH, or nothing if there isn't one.
#   - $1: The name of the branch.
open_pull_request() {
  gh pr list \
    --repo "$TARGET_REPOSITORY" \
    --head "$1" \
    --base "$TARGET_BRANCH" \
    --state open \
    --json number,isCrossRepository \
    --jq 'map(select(.isCrossRepository | not)) | .[0].number // empty'
}

# Output the latest pull request from the sync branch into TARGET_BRANCH, whether open or not,
# as "<number> <state> <head commit>", or nothing if there has never been one.
latest_pull_request() {
  gh pr list \
    --repo "$TARGET_REPOSITORY" \
    --head "$TARGET_SYNC_BRANCH" \
    --base "$TARGET_BRANCH" \
    --state all \
    --json number,state,headRefOid,isCrossRepository \
    --jq 'map(select(.isCrossRepository | not)) | .[0] // empty | "\(.number) \(.state) \(.headRefOid)"'
}

# Output the key in the trailer of a commit, or nothing if it isn't a commit from a source directory.
#   - $1: The commit.
key_of() {
  git log -1 --format="%(trailers:key=$TRAILER,valueonly)" "$1" | sed -n 1p
}

# Apply the changes made by a commit on top of another, as whole files, and output the new commit,
# or nothing if there are no changes left to make.
# As in `merge-files.sh`, a deletion is skipped if the file has been modified since.
#   - $1: The commit to apply the changes on top of.
#   - $2: The commit which made the changes.
replay() {
  local onto="$1" commit="$2" index tree meta path new_mode old_blob new_blob status current
  index="$(git rev-parse --git-dir)/github-graph-index"
  rm -f "$index"
  GIT_INDEX_FILE="$index" git read-tree "$onto"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r _ new_mode old_blob new_blob status <<< "$meta"
    if [[ "$status" != "D" ]]; then
      printf '%s %s\t%s\0' "$new_mode" "$new_blob" "$path"
      continue
    fi
    current=$(git rev-parse -q --verify "$onto:$path") || continue
    if [[ "$current" == "$old_blob" ]]; then
      # Mode 0 removes the file.
      printf '0 %s\t%s\0' "$old_blob" "$path"
    else
      echo "Kept: $path (modified in $TARGET_BRANCH since its deletion was synced)" >&2
    fi
  done < <(git diff-tree -r -z --no-renames "$commit^" "$commit") |
    GIT_INDEX_FILE="$index" git update-index -z --index-info
  tree=$(GIT_INDEX_FILE="$index" git write-tree)
  rm -f "$index"
  if [[ "$tree" != "$(git rev-parse "$onto^{tree}")" ]]; then
    git cat-file commit "$commit" | sed '1,/^$/d' | git commit-tree "$tree" -p "$onto"
  fi
}

# Set TITLE and BODY for the pull request, from the commits on the sync branch.
# Each source contributes the title and body of its latest commit, and identical bodies are shown once.
# If the titles differ, COMBINED_TITLE is used instead.
#   - $1: The tip of the sync branch.
render() {
  local commit key source title body
  local -A latest=() seen=()
  local -a sources=() titles=() bodies=()
  while IFS= read -r commit; do
    key=$(key_of "$commit")
    source="${key%%/*}"
    if [[ -z "$key" ]]; then continue; fi
    if [[ -z "${latest[$source]+_}" ]]; then sources+=("$source"); fi
    latest["$source"]="$commit"
  done < <(git rev-list --reverse "$TARGET_REF..$1")

  for source in "${sources[@]}"; do
    title=$(git log -1 --format=%s "${latest[$source]}")
    body=$(git log -1 --format=%b "${latest[$source]}")
    body="${body%"$TRAILER: "*}"
    body="${body%"${body##*[![:space:]]}"}"
    if [[ -z "${seen["title:$title"]+_}" ]]; then titles+=("$title"); seen["title:$title"]=1; fi
    if [[ -n "$body" && -z "${seen["body:$body"]+_}" ]]; then bodies+=("$body"); seen["body:$body"]=1; fi
  done

  case "${#titles[@]}" in
    0) TITLE="$PR_TITLE" ;;
    1) TITLE="${titles[0]}" ;;
    *) TITLE="$COMBINED_TITLE" ;;
  esac
  if (( ${#titles[@]} == 0 )); then
    BODY="$PR_BODY"
  else
    BODY=""
    for body in "${bodies[@]}"; do
      BODY+="${BODY:+$SEPARATOR}$body"
    done
  fi
}

# Open a pull request from the sync branch, or bring the open one up to date with the branch.
# If another sync changes the branch meanwhile, the pull request is updated again,
# in case this update is the one which arrives last.
update_pull_request() {
  local attempt tip file current now
  file=$(mktemp)
  for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    tip=$(fetch_sync_branch)
    if [[ -z "$tip" ]]; then break; fi
    render "$tip"
    printf '%s\n' "$BODY" > "$file"
    PR=$(open_pull_request "$TARGET_SYNC_BRANCH")

    if [[ -z "$PR" ]]; then
      # Another sync may open the same pull request at the same time, in which case this fails.
      if ! gh pr create \
        --repo "$TARGET_REPOSITORY" \
        --head "$TARGET_SYNC_BRANCH" \
        --base "$TARGET_BRANCH" \
        --title "$TITLE" \
        --body-file "$file"
      then
        backoff "$attempt"
        continue
      fi
      PR=$(open_pull_request "$TARGET_SYNC_BRANCH")
      echo "Opened pull request #$PR to merge synced changes into $TARGET_REPOSITORY."
    else
      current=$(gh pr view "$PR" --repo "$TARGET_REPOSITORY" --json title,body --jq '.title + "\n" + .body' | tr -d '\r')
      if [[ "$current" != "$TITLE"$'\n'"$BODY" ]]; then
        gh pr edit "$PR" --repo "$TARGET_REPOSITORY" --title "$TITLE" --body-file "$file" > /dev/null
        echo "Updated the title and description of pull request #$PR."
      fi
    fi

    now=$(remote_tip "$TARGET_SYNC_BRANCH")
    if [[ "$now" == "$tip" ]]; then break; fi
  done
  rm -f "$file"
}

# =================================================================================================
# 1. Commit the changes from the source directory, on top of the TARGET_BRANCH they were merged into.
# =================================================================================================

git add -A
tree=$(git write-tree)
CHANGES=""
if [[ "$tree" != "$(git rev-parse "HEAD^{tree}")" ]]; then
  CHANGES=$(printf '%s\n\n%s\n\n%s: %s\n' "$PR_TITLE" "$PR_BODY" "$TRAILER" "$KEY" | git commit-tree "$tree" -p HEAD)
else
  echo "No changes to sync from $SOURCE_REPOSITORY."
fi

# =================================================================================================
# 2. Rebuild the sync branch on top of the latest TARGET_BRANCH.
#    The commits of other source directories are kept, unless the branch is exactly as it was
#    when its last pull request was merged or closed, in which case the branch starts afresh.
#    (A branch pushed since then is kept, as the sync which pushed it may not have opened its pull
#    request yet.)
#    The branch is only pushed if nothing else has pushed to it since it was fetched,
#    and otherwise it's fetched and rebuilt again.
# =================================================================================================

PR=""
for (( attempt = 1; ; attempt++ )); do
  git fetch -q origin "+refs/heads/$TARGET_BRANCH:$TARGET_REF"
  old=$(fetch_sync_branch)
  latest=$(latest_pull_request)
  read -r number state head <<< "$latest"
  PR=""
  if [[ "$state" == "OPEN" ]]; then PR="$number"; fi

  commits=()
  building=false
  if [[ -n "$old" && ( -n "$PR" || "$old" != "$head" ) ]]; then
    building=true
    while IFS= read -r commit; do
      key=$(key_of "$commit")
      if [[ -n "$key" && "$key" != "$KEY" ]]; then commits+=("$commit"); fi
    done < <(git rev-list --reverse --no-merges "$TARGET_REF..$old")
    if (( ${#commits[@]} > 0 )); then
      echo "Keeping ${#commits[@]} commit(s) from other source directories on $TARGET_SYNC_BRANCH."
    fi
  fi
  if [[ -n "$CHANGES" ]]; then commits+=("$CHANGES"); fi

  base=$(git rev-parse "$TARGET_REF")
  tip="$base"
  for commit in "${commits[@]}"; do
    next=$(replay "$tip" "$commit")
    if [[ -n "$next" ]]; then
      tip="$next"
    else
      echo "Dropped changes already in $TARGET_BRANCH: $(git log -1 --format=%s "$commit")"
    fi
  done

  # ===============================================================================================
  # 3. If there is nothing left to merge, close any open pull request.
  #    Otherwise, push the rebuilt branch, and open or update the pull request.
  # ===============================================================================================

  if [[ "$tip" == "$base" ]]; then
    echo "No changes to merge into $TARGET_REPOSITORY."
    if [[ -n "$PR" ]]; then
      gh pr close "$PR" --repo "$TARGET_REPOSITORY" --comment "Closed, as there are no longer any changes to merge."
      echo "Closed pull request #$PR as there are no longer any changes to merge."
      # If another sync pushed to the branch meanwhile, its changes still need the pull request.
      now=$(remote_tip "$TARGET_SYNC_BRANCH")
      if [[ "$now" != "$old" ]] && gh pr reopen "$PR" --repo "$TARGET_REPOSITORY"; then
        echo "Reopened pull request #$PR, as another sync has since pushed changes to it."
      fi
      PR=""
    fi
    break
  fi

  if [[ "$building" == "true" && "$(git rev-parse "$tip^{tree}")" == "$(git rev-parse "$old^{tree}")" ]] &&
     git merge-base --is-ancestor "$base" "$old"; then
    echo "$TARGET_SYNC_BRANCH is already up to date."
  elif ! git push -q --force-with-lease="refs/heads/$TARGET_SYNC_BRANCH:$old" origin "$tip:refs/heads/$TARGET_SYNC_BRANCH"; then
    if (( attempt >= ATTEMPTS )); then
      echo "::error::Failed to push $TARGET_SYNC_BRANCH after $attempt attempts."
      exit 1
    fi
    echo "Failed to push $TARGET_SYNC_BRANCH, perhaps as another sync pushed to it meanwhile. Trying again..."
    backoff "$attempt"
    continue
  fi

  update_pull_request
  break
done

# =================================================================================================
# 4. Close the pull request which older versions opened for these changes alone, if it's still open.
#    Any changes which are still needed are now in the shared pull request instead.
# =================================================================================================

LEGACY_SYNC_BRANCH="${TARGET_LEGACY_SYNC_BRANCH:-}"
if [[ -n "$LEGACY_SYNC_BRANCH" && "$LEGACY_SYNC_BRANCH" != "$TARGET_SYNC_BRANCH" ]]; then
  legacy=$(open_pull_request "$LEGACY_SYNC_BRANCH")
  if [[ -n "$legacy" ]]; then
    if [[ -n "$PR" ]]; then
      comment="Superseded by #$PR, which holds the changes from every source synced into \`$TARGET_BRANCH\`."
    else
      comment="Closed, as there are no longer any changes to merge."
    fi
    if gh pr close "$legacy" --repo "$TARGET_REPOSITORY" --delete-branch --comment "$comment"; then
      echo "Closed pull request #$legacy from $LEGACY_SYNC_BRANCH, which older versions synced into."
    else
      echo "::warning::Failed to close pull request #$legacy from $LEGACY_SYNC_BRANCH, or to delete its branch."
    fi
  fi
fi

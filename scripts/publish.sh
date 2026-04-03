#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Commits the changes locally and opens a pull request if there is anything to merge.
#
# Environment variables:
#   - PR_TITLE:           The template string used to generate pull request titles.
#   - PR_BODY:            The template string used to generate pull request descriptions.
#   - SOURCE_REPOSITORY:  The name of the source GitHub repository as 'Username/Repository'.
#   - TARGET_REPOSITORY:  The name of the target GitHub repository as 'Username/Repository'.
#   - TARGET_BRANCH:      The branch into which we wish to merge.
#   - TARGET_SYNC_BRANCH: The name of the temporary branch used to stage the pull request.
#
# Requirements:
#   - target/ should contain the target repository at the correct branch,
#     with the changes from the source directory already having been merged.
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

# =================================================================================================
# 1. Reset the PR branch to the contents of TARGET_BRANCH, then stage the merged result.
# =================================================================================================

git fetch origin "$TARGET_BRANCH"
git checkout -B "$TARGET_SYNC_BRANCH" "origin/$TARGET_BRANCH"
git add -A

# =================================================================================================
# 2. If something has changed, commit and push the changes to TARGET_SYNC_BRANCH.
#    Otherwise, push the reset branch and close any open PR.
# =================================================================================================

if git diff --cached --quiet; then

  git push --force origin "$TARGET_SYNC_BRANCH"
  echo "No changes to commit for $TARGET_REPOSITORY."

  # Close any open PR for this sync branch, since there is nothing left to merge.
  pr_number=$(gh pr list \
    --repo "$TARGET_REPOSITORY" \
    --head "$TARGET_SYNC_BRANCH" \
    --state open \
    --json number \
    --jq '.[0].number // empty')

  if [[ -n "$pr_number" ]]; then
    gh pr close "$pr_number" --repo "$TARGET_REPOSITORY"
    echo "Closed pull request #$pr_number as there are no longer any changes to merge."
  fi

else

  git commit -m "$PR_TITLE"
  git push --force origin "$TARGET_SYNC_BRANCH"

  # =================================================================================================
  # 3. Open a new pull request if there isn't one already.
  #    If the last pull request from us hasn't yet been merged,
  #    no action is required as we use the same branch.
  # =================================================================================================

  # Determine whether there already exists a PR.
  pr_exists=$(gh pr list \
    --repo "$TARGET_REPOSITORY" \
    --head "$TARGET_SYNC_BRANCH" \
    --state open \
    --json number \
    --jq 'length > 0')

  # If not, create one.
  if [[ "$pr_exists" == "false" ]]; then
    gh pr create \
      --repo "$TARGET_REPOSITORY" \
      --head "$TARGET_SYNC_BRANCH" \
      --base "$TARGET_BRANCH" \
      --title "$PR_TITLE" \
      --body "$PR_BODY"
    echo "Opened a new pull request to merge changes from $SOURCE_REPOSITORY into $TARGET_REPOSITORY."
  else
    echo "A pull request is already open to merge changes from $SOURCE_REPOSITORY into $TARGET_REPOSITORY."
  fi
fi

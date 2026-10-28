#!/usr/bin/env bash
set -euo pipefail

# =================================================================================================
# Reads the configuration file `.github/graph.json`, inserting defaults and derived fields.
#
# Environment variables:
#   - CONFIG_PATH:       Path to the configuration file (default: `.github/graph.json`).
#   - DEFAULT_BRANCH:    The default branch of the source repository.
#   - GITHUB_REPOSITORY: The source repository in the form owner/name.
#   - GITHUB_REF_NAME:   The name of the branch that was pushed to.
#   - GITHUB_SHA:        The commit SHA that triggered the workflow.
#   - GITHUB_EVENT_NAME: The event that triggered the workflow.
#   - SOURCE_BEFORE:     The commit before the push which triggered this sync, if any.
#
# Output:
#   - children: A JSON list of downstream repositories to be updated, sent to GITHUB_OUTPUT.
# =================================================================================================


CONFIG_PATH="${CONFIG_PATH:-.github/graph.json}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The files which the push changed, or null to sync every child. A sync which a push skips is made
# up for by the next, so a child need only sync when the push changed its source directory. Any
# other run syncs every child: one started by hand, or a push which created its branch, or whose
# earlier commit can't be fetched to compare with.
CHANGED=null
BEFORE="${SOURCE_BEFORE:-}"
if [[ "${GITHUB_EVENT_NAME:-}" == "push" && ! "$BEFORE" =~ ^0*$ ]] \
  && git fetch --quiet --no-tags --depth=1 origin "$BEFORE"; then
  CHANGED=$(git diff --name-only --no-renames "$BEFORE" "$GITHUB_SHA" | jq -R . | jq -s -c .)
fi

CHILDREN=$(jq \
  -c \
  --rawfile default_pr_body "$SCRIPT_DIR/../templates/pull-request-body.md" \
  --arg config_path "$CONFIG_PATH" \
  --argjson changed "$CHANGED" \
  '
    (. | del(.children)) as $global |
    (.children // []) |

    # Adopt the global config for each child, but allow the child to override it.
    map(
      . as $child |
      ($global * $child) |
      .ignore = (($global.ignore // []) + ($child.ignore // []) | unique)
    ) |

    # Add default and derived fields.
    map(
      ($ENV.GITHUB_REPOSITORY / "/") as [$owner, $name] |
      ("https://github.com/" + $ENV.GITHUB_REPOSITORY) as $url |
      ($url + "/tree/" + $ENV.DEFAULT_BRANCH) as $branchUrl |
      .source.owner = $owner |
      .source.name = $name |
      .source.repository = $ENV.GITHUB_REPOSITORY |
      .source.commit = $ENV.GITHUB_SHA |
      .source.branch //= $ENV.DEFAULT_BRANCH |
      .source.root //= "." |
      .source.url = $url |
      .source.commitUrl = $url + "/commit/" + $ENV.GITHUB_SHA |
      .source.branchUrl = $url + "/tree/" + $ENV.DEFAULT_BRANCH |
      .source.configUrl = $branchUrl + "/" + $config_path
    ) |
    map(
      (.target.owner + "/" + .target.name) as $repository |
      ("https://github.com/" + $repository) as $url |
      .target.repository = $repository |
      .target.branch //= "" |
      # Older versions staged each source directory on a sync branch of its own.
      .target.legacySyncBranch = (if (.target.syncBranch // "") != "" then "" else
        "sync/" + .source.repository + "_" + .source.branch + "_" + .source.root +
        "--" + (.target.root // ".") + ";" end) |
      # The default is shared by every source, but depends on the target branch, so is resolved later.
      .target.syncBranch //= "" |
      .target.root //= "." |
      .target.url = $url
    ) |
    map(
      .pullRequest.title //= "[github-graph] Synced files from `$SOURCE_NAME`." |
      .pullRequest.body //= $default_pr_body
    ) |
    map(
      .token //= "GH_TOKEN"
    ) |

    # Filter to only children that are triggered by the current branch.
    map(select(.source.branch == $ENV.GITHUB_REF_NAME)) |

    # And to those whose source directory the push changed, unless it changed this file,
    # which may change what any child syncs.
    if $changed == null or any($changed[]; . == $config_path) then . else
      map(select(
        (.source.root | ltrimstr("./") | rtrimstr("/")) as $root |
        $root == "" or $root == "." or any($changed[]; startswith($root + "/"))
      ))
    end
  ' \
  "$CONFIG_PATH" \
)

echo "children=$CHILDREN" >> "$GITHUB_OUTPUT"

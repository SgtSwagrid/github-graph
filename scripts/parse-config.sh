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
#
# Output:
#   - children: A JSON list of downstream repositories to be updated, sent to GITHUB_OUTPUT.
# =================================================================================================


CONFIG_PATH="${CONFIG_PATH:-.github/graph.json}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CHILDREN=$(jq \
  -c \
  --rawfile default_pr_body "$SCRIPT_DIR/../templates/pull-request-body.md" \
  --arg config_path "$CONFIG_PATH" \
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
      .target.syncBranch //= "sync#" + .source.repository + "_" + .source.branch + "_" + .source.root +
        "->" + (.target.root // ".") + ";" |
      .target.root //= "." |
      .target.url = $url
    ) |
    map(
      .pullRequest.title //= "[github-graph]: Synced files from $SOURCE_NAME." |
      .pullRequest.body //= $default_pr_body
    ) |
    map(
      .token //= "GH_TOKEN"
    ) |

    # Filter to only children that are triggered by the current branch.
    map(select(.source.branch == $ENV.GITHUB_REF_NAME))
  ' \
  "$CONFIG_PATH" \
)

echo "children=$CHILDREN" >> "$GITHUB_OUTPUT"

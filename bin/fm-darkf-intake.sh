#!/usr/bin/env bash
# darkf-intake: validate GitHub issue against dark-factory task template
# and create a Firstmate backlog item on success.
# Usage: fm-darkf-intake.sh <issue-url>
# Exits 0 on success (backlog item created), 1 on validation failure,
# 2 on usage/config error, 3 on GitHub auth/permission error.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<'EOF'
Usage: fm-darkf-intake.sh <issue-url>

Validates a GitHub issue labeled 'darkf-todo' against the dark-factory
task template (problem, impact, proposed-solution, acceptance-criteria).
On success: creates a Firstmate backlog ship task, adds 'darkf-wip' label.
On failure: adds 'darkf-failed' label, removes 'darkf-todo', comments missing sections.

Requires: gh CLI authenticated with repo scope (Contents R/W, Issues R/W, PRs R/W)
EOF
}

if [ "$#" -ne 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 2
fi

ISSUE_URL="$1"

# Parse owner/repo/number from URL
if ! [[ "$ISSUE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
  echo "error: not a valid GitHub issue URL: $ISSUE_URL" >&2
  exit 2
fi
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"
REPO_FULL="$OWNER/$REPO"

# Check gh auth
if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found on PATH" >&2
  exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh not authenticated; run 'gh auth login'" >&2
  exit 3
fi

# Fetch issue data
ISSUE_JSON=$(gh issue view "$ISSUE_URL" --json body,comments,labels,number,title,state --repo "$REPO_FULL" 2>/dev/null) || {
  echo "error: failed to fetch issue (permission denied or not found)" >&2
  exit 3
}

TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r .title)
BODY=$(printf '%s' "$ISSUE_JSON" | jq -r .body // "")
STATE=$(printf '%s' "$ISSUE_JSON" | jq -r .state)
LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '.labels[].name' | tr '\n' ' ')

# Check darkf-todo label present
if ! printf '%s' "$LABELS" | grep -qw 'darkf-todo'; then
  echo "error: issue does not have 'darkf-todo' label" >&2
  exit 1
fi

# Concatenate body + all comment bodies for scanning
COMMENTS=$(printf '%s' "$ISSUE_JSON" | jq -r '.comments[].body // ""' | tr '\n' ' ')
FULL_TEXT="$BODY $COMMENTS"

# Required sections (case-insensitive, flexible header formats)
REQUIRED=("problem" "impact" "proposed-solution" "acceptance-criteria")
MISSING=()

for section in "${REQUIRED[@]}"; do
  # Match ### section-name (with optional dash/space variants)
  PATTERN="^###[[:space:]]*${section//-/-?}[[:space:]]"
  if ! printf '%s' "$FULL_TEXT" | grep -qiE "$PATTERN"; then
    # Also try without ### (some users just write "Problem:")
    ALT_PATTERN="^${section^^}:"
    if ! printf '%s' "$FULL_TEXT" | grep -qiE "$ALT_PATTERN"; then
      MISSING+=("$section")
    fi
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  # Validation failed
  MISSING_LIST=$(IFS=', '; printf '%s' "${MISSING[*]}")
  COMMENT="Intake validation failed: missing required section(s): $MISSING_LIST

Required sections (case-insensitive):
- ### Problem
- ### Impact  
- ### Proposed Solution (or Proposed-Solution)
- ### Acceptance Criteria (or Acceptance-Criteria)

Add these to the issue body or a comment, then the next intake run will pick it up."

  gh issue edit "$NUMBER" --repo "$REPO_FULL" --remove-label darkf-todo --add-label darkf-failed >/dev/null
  gh issue comment "$NUMBER" --repo "$REPO_FULL" --body "$COMMENT" >/dev/null
  echo "failed: $MISSING_LIST"
  exit 1
fi

# Validation passed — create backlog item
# Find project name from data/projects.md matching this repo
PROJECT_NAME=$(grep -E "^\s*- ${REPO//\//\\/}\s" "$FM_ROOT/data/projects.md" 2>/dev/null | head -1 | sed -E 's/^\s*-\s+([^[]+).*/\1/' | xargs)
if [ -z "$PROJECT_NAME" ]; then
  # Try matching by repo name only
  PROJECT_NAME=$(grep -i "$REPO" "$FM_ROOT/data/projects.md" 2>/dev/null | head -1 | sed -E 's/^\s*-\s+([^[]+).*/\1/' | xargs)
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "error: repo $REPO_FULL not registered in data/projects.md; run project-management add first" >&2
  exit 2
fi

# Create backlog task
TASK_TITLE="darkf: $TITLE"
TASK_ID=$(bin/fm-tasks-axi.sh add "$TASK_TITLE" --kind ship --repo "$PROJECT_NAME" --format json 2>/dev/null | jq -r .id) || {
  echo "error: failed to create backlog task" >&2
  exit 2
}

# Record dark-factory metadata in task meta
META="$FM_ROOT/state/$TASK_ID.meta"
mkdir -p "$FM_ROOT/state/$TASK_ID"
{
  echo "darkf_issue=$ISSUE_URL"
  echo "darkf_number=$NUMBER"
  echo "darkf_repo=$REPO_FULL"
} >> "$META"

# Add darkf-wip label
gh issue edit "$NUMBER" --repo "$REPO_FULL" --add-label darkf-wip >/dev/null

echo "success: created task $TASK_ID for $REPO_FULL#$NUMBER"
exit 0
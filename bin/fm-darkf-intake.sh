#!/usr/bin/env bash
# darkf-intake: validate GitHub issue against dark-factory task template
# and create a Firstmate backlog item on success.
# Phase-aware: only processes Phase 1 initially; higher phases wait for prior phase completion.
# Usage: fm-darkf-intake.sh <issue-url>
# Exits 0 on success (backlog item created), 1 on validation failure,
# 2 on usage/config error, 3 on GitHub auth/permission error.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  cat <<'EOF'
Usage: fm-darkf-intake.sh <issue-url>

Validates a GitHub issue labeled 'darkf-todo' against the dark-factory
task template (problem, impact, proposed-solution, acceptance-criteria).
On success: creates a Firstmate backlog ship task, adds 'darkf-wip' label.
On failure: adds 'darkf-failed' label, removes 'darkf-todo', comments missing sections.

Phase-aware behavior:
- Standalone issues (no parent epic): processed normally
- Phase 1 issues (label phase:1): processed immediately
- Phase N>1 issues: only processed if prior phase is complete (darkf-done or PR merged)
- Auto-advance: when Phase N PR merges, promotes Phase N+1 if AUTO_ADVANCE_PHASES=true

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

# ---------------------------------------------------------------------------
# PHASE-AWARE LOGIC
# ---------------------------------------------------------------------------
# Extract phase number from labels (phase:N)
PHASE_LABEL=$(printf '%s' "$LABELS" | grep -oE 'phase:[0-9]+' | head -1 || true)
PHASE_NUM=0
if [ -n "$PHASE_LABEL" ]; then
  PHASE_NUM="${PHASE_LABEL#phase:}"
fi

# Check if issue has a parent epic (darkf-epic label or sub-issue relationship)
HAS_PARENT_EPIC=0
if printf '%s' "$LABELS" | grep -qw 'darkf-epic'; then
  # This IS the epic, not a phase
  HAS_PARENT_EPIC=0
else
  # Check if it's a sub-issue of an epic via GraphQL
  PARENT_EPIC=$(gh api graphql -f query="
    query {
      node(id: \"$(gh api graphql -f query='query { repository(owner: \"'$OWNER'\", name: \"'$REPO'\") { issue(number: '$NUMBER') { id } } }' --jq .data.repository.issue.id)\") {
        ... on Issue {
          parentIssue: timelineItems(first: 10, itemTypes: [CONNECTED_EVENT]) {
            nodes {
              ... on ConnectedEvent {
                subject { ... on Issue { id number title labels(first: 10) { nodes { name } } } }
              }
            }
          }
        }
      }
    }" --jq '.data.node.parentIssue.nodes[]?.subject | select(.labels.nodes[].name == "darkf-epic") | .number' 2>/dev/null || true)
  if [ -n "$PARENT_EPIC" ]; then
    HAS_PARENT_EPIC=1
  fi
fi

# Phase gating logic
if [ "$HAS_PARENT_EPIC" -eq 1 ] && [ "$PHASE_NUM" -gt 0 ]; then
  if [ "$PHASE_NUM" -eq 1 ]; then
    # Phase 1: always process
    echo "Phase 1 of epic #$PARENT_EPIC → processing"
  else
    # Phase N>1: check if prior phase is complete
    PRIOR_PHASE=$((PHASE_NUM - 1))
    echo "Phase $PHASE_NUM of epic #$PARENT_EPIC → checking if Phase $PRIOR_PHASE is complete"

    # Find prior phase issue number (sub-issue of same epic with phase:PRIOR_PHASE)
    PRIOR_ISSUE=$(gh api graphql -f query="
      query {
        repository(owner: \"$OWNER\", name: \"$REPO\") {
          issue(number: $PARENT_EPIC) {
            subIssues(first: 20) {
              nodes {
                number
                labels(first: 10) { nodes { name } }
                state
              }
            }
          }
        }
      }" --jq ".data.repository.issue.subIssues.nodes[] | select(.labels.nodes[].name == \"phase:$PRIOR_PHASE\") | .number" 2>/dev/null || true)

    if [ -z "$PRIOR_ISSUE" ]; then
      echo "error: could not find Phase $PRIOR_PHASE issue for epic #$PARENT_EPIC" >&2
      exit 1
    fi

    # Check prior phase status
    PRIOR_JSON=$(gh issue view "$PRIOR_ISSUE" --json state,labels --repo "$REPO_FULL" 2>/dev/null) || {
      echo "error: failed to fetch prior phase issue #$PRIOR_ISSUE" >&2
      exit 3
    }
    PRIOR_STATE=$(printf '%s' "$PRIOR_JSON" | jq -r .state)
    PRIOR_LABELS=$(printf '%s' "$PRIOR_JSON" | jq -r '.labels[].name' | tr '\n' ' ')

    PRIOR_DONE=0
    if [ "$PRIOR_STATE" = "CLOSED" ] || printf '%s' "$PRIOR_LABELS" | grep -qw 'darkf-done'; then
      PRIOR_DONE=1
    fi

    # Also check if prior phase PR was merged (via merge poll in main firstmate)
    # This is a best-effort check; the main firstmate's merge poll will handle promotion
    if [ "$PRIOR_DONE" -eq 0 ]; then
      # Check if there's a merged PR for the prior phase
      MERGED_PR=$(gh api graphql -f query="
        query {
          repository(owner: \"$OWNER\", name: \"$REPO\") {
            issue(number: $PRIOR_ISSUE) {
              timelineItems(first: 20, itemTypes: [CROSS_REFERENCED_EVENT]) {
                nodes {
                  ... on CrossReferencedEvent {
                    source { ... on PullRequest { state merged mergedAt } }
                  }
                }
              }
            }
          }
        }" --jq ".data.repository.issue.timelineItems.nodes[]?.source | select(.state == \"MERGED\") | .mergedAt" 2>/dev/null | head -1 || true)
      if [ -n "$MERGED_PR" ]; then
        PRIOR_DONE=1
      fi
    fi

    if [ "$PRIOR_DONE" -eq 0 ]; then
      # Prior phase not done → skip this intake run, leave darkf-todo for later
      echo "paused: Phase $PHASE_NUM waiting for Phase $PRIOR_PHASE (issue #$PRIOR_ISSUE) to complete"
      exit 0
    fi

    echo "Phase $PRIOR_PHASE complete → processing Phase $PHASE_NUM"
  fi
else
  # Standalone issue (no parent epic) or epic itself → process normally
  if [ "$PHASE_NUM" -gt 0 ]; then
    echo "Standalone phase:$PHASE_NUM issue → processing"
  fi
fi

# ---------------------------------------------------------------------------
# TEMPLATE VALIDATION (unchanged)
# ---------------------------------------------------------------------------
COMMENTS=$(printf '%s' "$ISSUE_JSON" | jq -r '.comments[].body // ""' | tr '\n' ' ')
FULL_TEXT="$BODY $COMMENTS"

REQUIRED=("problem" "impact" "proposed-solution" "acceptance-criteria")
MISSING=()

for section in "${REQUIRED[@]}"; do
  PATTERN="^###[[:space:]]*${section//-/-?}[[:space:]]"
  if ! printf '%s' "$FULL_TEXT" | grep -qiE "$PATTERN"; then
    ALT_PATTERN="^${section^^}:"
    if ! printf '%s' "$FULL_TEXT" | grep -qiE "$ALT_PATTERN"; then
      MISSING+=("$section")
    fi
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
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

# ---------------------------------------------------------------------------
# CREATE BACKLOG TASK
# ---------------------------------------------------------------------------
PROJECT_NAME=$(grep -E "^\s*- ${REPO//\//\\/}\s" "$FM_ROOT/data/projects.md" 2>/dev/null | head -1 | sed -E 's/^\s*-\s+([^[]+).*/\1/' | xargs)
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME=$(grep -i "$REPO" "$FM_ROOT/data/projects.md" 2>/dev/null | head -1 | sed -E 's/^\s*-\s+([^[]+).*/\1/' | xargs)
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "error: repo $REPO_FULL not registered in data/projects.md; run project-management add first" >&2
  exit 2
fi

TASK_TITLE="darkf: $TITLE"
TASK_ID=$(bin/fm-tasks-axi.sh add "$TASK_TITLE" --kind ship --repo "$PROJECT_NAME" --format json 2>/dev/null | jq -r .id) || {
  echo "error: failed to create backlog task" >&2
  exit 2
}

META="$FM_ROOT/state/$TASK_ID.meta"
mkdir -p "$FM_ROOT/state/$TASK_ID"
{
  echo "darkf_issue=$ISSUE_URL"
  echo "darkf_number=$NUMBER"
  echo "darkf_repo=$REPO_FULL"
  [ "$HAS_PARENT_EPIC" -eq 1 ] && echo "darkf_epic=$PARENT_EPIC"
  [ "$PHASE_NUM" -gt 0 ] && echo "darkf_phase=$PHASE_NUM"
} >> "$META"

# Add darkf-wip label
gh issue edit "$NUMBER" --repo "$REPO_FULL" --add-label darkf-wip >/dev/null

echo "success: created task $TASK_ID for $REPO_FULL#$NUMBER"
exit 0
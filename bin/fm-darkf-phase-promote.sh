#!/usr/bin/env bash
# darkf-phase-promote: promote next phase when current phase PR merges
# Called by main firstmate merge flow or manually
# Usage: fm-darkf-phase-promote.sh <repo> <epic-number> <completed-phase-number>

set -eu

if [ "$#" -ne 3 ]; then
  echo "Usage: fm-darkf-phase-promote.sh <owner/repo> <epic-number> <completed-phase-number>"
  exit 2
fi

REPO="$1"
EPIC_NUM="$2"
COMPLETED_PHASE="$3"
NEXT_PHASE=$((COMPLETED_PHASE + 1))

# Check AUTO_ADVANCE_PHASES config
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
SCHEDULE="$FM_HOME/config/darkf-schedule"
AUTO_ADVANCE=$(grep '^AUTO_ADVANCE_PHASES=' "$SCHEDULE" 2>/dev/null | cut -d= -f2 || echo "false")

if [ "$AUTO_ADVANCE" != "true" ]; then
  echo "AUTO_ADVANCE_PHASES=false (set true in config/darkf-schedule to enable)"
  exit 0
fi

# Find next phase issue (sub-issue of epic with phase:NEXT_PHASE label)
NEXT_ISSUE=$(gh api graphql -f query="
  query {
    repository(owner: \"${REPO%/*}\", name: \"${REPO#*/}\") {
      issue(number: $EPIC_NUM) {
        subIssues(first: 20) {
          nodes {
            number
            labels(first: 10) { nodes { name } }
            state
          }
        }
      }
    }
  }" --jq ".data.repository.issue.subIssues.nodes[] | select(.labels.nodes[].name == \"phase:$NEXT_PHASE\") | .number" 2>/dev/null || true)

if [ -z "$NEXT_ISSUE" ]; then
  echo "No Phase $NEXT_PHASE found for epic #$EPIC_NUM"
  exit 0
fi

# Check if next phase already has darkf-todo (already promoted) or is done
NEXT_JSON=$(gh issue view "$NEXT_ISSUE" --json labels,state --repo "$REPO" 2>/dev/null) || {
  echo "error: failed to fetch next phase issue #$NEXT_ISSUE"
  exit 3
}
NEXT_LABELS=$(printf '%s' "$NEXT_JSON" | jq -r '.labels[].name' | tr '\n' ' ')
NEXT_STATE=$(printf '%s' "$NEXT_JSON" | jq -r .state)

if printf '%s' "$NEXT_LABELS" | grep -qw 'darkf-todo'; then
  echo "Phase $NEXT_PHASE (issue #$NEXT_ISSUE) already has darkf-todo"
  exit 0
fi

if [ "$NEXT_STATE" = "CLOSED" ] || printf '%s' "$NEXT_LABELS" | grep -qw 'darkf-done'; then
  echo "Phase $NEXT_PHASE (issue #$NEXT_ISSUE) already complete"
  exit 0
fi

# Promote: remove any blocking label, add darkf-todo
echo "Promoting Phase $NEXT_PHASE (issue #$NEXT_ISSUE) → adding darkf-todo"
gh issue edit "$NEXT_ISSUE" --repo "$REPO" --add-label darkf-todo >/dev/null

# Optionally remove darkf-wip if stuck from previous attempt
gh issue edit "$NEXT_ISSUE" --repo "$REPO" --remove-label darkf-wip >/dev/null 2>&1 || true

# Find completed phase issue (sub-issue of epic with phase:COMPLETED_PHASE label)
COMPLETED_ISSUE=$(gh api graphql -f query="
  query {
    repository(owner: \"${REPO%/*}\", name: \"${REPO#*/}\") {
      issue(number: $EPIC_NUM) {
        subIssues(first: 20) {
          nodes {
            number
            labels(first: 10) { nodes { name } }
            state
          }
        }
      }
    }
  }" --jq ".data.repository.issue.subIssues.nodes[] | select(.labels.nodes[].name == \"phase:$COMPLETED_PHASE\") | .number" 2>/dev/null || true)

# Mark completed phase as darkf-done
if [ -n "$COMPLETED_ISSUE" ]; then
  gh issue edit "$COMPLETED_ISSUE" --repo "$REPO" --add-label darkf-done --remove-label darkf-todo >/dev/null 2>&1 || true
else
  echo "warning: could not resolve issue number for Phase $COMPLETED_PHASE; skipping darkf-done label" >&2
fi

echo "Promoted: Phase $NEXT_PHASE (issue #$NEXT_ISSUE) now labeled darkf-todo"
exit 0
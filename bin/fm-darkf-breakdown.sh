#!/usr/bin/env bash
# darkf-feature-breakdown: decompose a feature plan into GitHub epic + phased sub-issues
# for dark-factory overnight processing.
# Usage: fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo [--phases N] [--interactive] [--from-lavish ID]

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<'EOF'
Usage: fm-darkf-breakdown.sh [options] --repo OWNER/REPO

Decompose a feature into GitHub epic + phased sub-issues labeled for dark-factory.

Options:
  --plan FILE          Plan/spec markdown file (phases extracted from headings)
  --from-lavish ID     Lavish board ID/URL to extract phases from
  --interactive        Prompt for feature description interactively
  --repo OWNER/REPO    Target GitHub repository (required)
  --phases N           Hint: number of phases to create (default: auto-detect)
  --dry-run            Show what would be created without creating issues
  -h, --help           Show this help

Input sources (choose one):
  --plan SPEC.md           Structured spec with ## Phase N headings
  --from-lavish board-123  Lavish board with phased design
  --interactive            Captain describes feature interactively

Each sub-issue gets the dark-factory 4-section template:
  ### Problem
  ### Impact
  ### Proposed Solution
  ### Acceptance Criteria

Labels applied:
  Epic: darkf-epic
  Phases: darkf-todo, phase:1, phase:2, ...

Sub-issue relationships created via GitHub GraphQL API.
EOF
}

PLAN_FILE=""
LAVISH_ID=""
INTERACTIVE=0
REPO=""
PHASES_HINT=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) PLAN_FILE="$2"; shift 2 ;;
    --from-lavish) LAVISH_ID="$2"; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --phases) PHASES_HINT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option $1" >&2; usage; exit 2 ;;
  esac
done

# Validate input source
SRC_COUNT=0
[ -n "$PLAN_FILE" ] && SRC_COUNT=$((SRC_COUNT + 1))
[ -n "$LAVISH_ID" ] && SRC_COUNT=$((SRC_COUNT + 1))
[ "$INTERACTIVE" -eq 1 ] && SRC_COUNT=$((SRC_COUNT + 1))
[ "$SRC_COUNT" -eq 1 ] || { echo "error: choose exactly one of --plan, --from-lavish, --interactive" >&2; exit 2; }

[ -n "$REPO" ] || { echo "error: --repo OWNER/REPO required" >&2; exit 2; }

# Check gh auth
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "error: gh CLI not authenticated; run 'gh auth login'" >&2
  exit 3
fi

# Check jq
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found on PATH" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Phase extraction from plan file
# ---------------------------------------------------------------------------
extract_phases_from_plan() {
  local file="$1"
  # Expect ## Phase 1: Name or ### Phase 1: Name headings
  awk '
    /^##?# Phase [0-9]+/ {
      phase_num = $0
      sub(/^##?# Phase [0-9]+:?[[:space:]]*/, "", phase_num)
      gsub(/[[:space:]]+$/, "", phase_num)
      print "PHASE|" NR "|" phase_num
      next
    }
    /^### (Problem|Impact|Proposed Solution|Acceptance Criteria)/ {
      section = $0
      sub(/^###[[:space:]]*/, "", section)
      gsub(/[[:space:]]+$/, "", section)
      print "SECTION|" section
      next
    }
    /^##/ && !/^##?# Phase/ {
      # Other top-level heading, treat as context
      print "CONTEXT|" $0
    }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Build issue body from extracted content
# ---------------------------------------------------------------------------
build_phase_body() {
  local phase_num="$1"
  local phase_name="$2"
  local content="$3"  # newline-separated sections

  cat <<EOF
### Problem
$content

### Impact


### Proposed Solution


### Acceptance Criteria


---
*Phase $phase_num of epic: $EPIC_TITLE*
*Depends on: $DEPENDS_ON*
EOF
}

# ---------------------------------------------------------------------------
# Main decomposition logic
# ---------------------------------------------------------------------------
main() {
  local phases_data=""
  local epic_title="Feature"

  if [ -n "$PLAN_FILE" ]; then
    [ -f "$PLAN_FILE" ] || { echo "error: plan file not found: $PLAN_FILE" >&2; exit 2; }
    phases_data=$(extract_phases_from_plan "$PLAN_FILE")
    epic_title=$(head -20 "$PLAN_FILE" | grep -E '^# ' | head -1 | sed 's/^# //')
    [ -z "$epic_title" ] && epic_title=$(basename "$PLAN_FILE" .md)
  elif [ -n "$LAVISH_ID" ]; then
    echo "error: Lavish integration not yet implemented; use --plan or --interactive" >&2
    exit 2
  elif [ "$INTERACTIVE" -eq 1 ]; then
    echo "Interactive feature breakdown"
    echo "Describe the feature (one paragraph):"
    read -r FEATURE_DESC
    echo "Number of phases (3-6):"
    read -r PHASES_HINT
    PHASES_HINT=${PHASES_HINT:-4}
    # Generate phases via simple prompt (could call LLM here)
    for i in $(seq 1 "$PHASES_HINT"); do
      echo "Phase $i name:"
      read -r PNAME
      echo "Phase $i brief description:"
      read -r PDESC
      phases_data+="PHASE|$i|$PNAME|$PDESC
"
    done
    epic_title=$(echo "$FEATURE_DESC" | cut -c1-50)
  fi

  # Parse phases
  local phases=()
  local phase_names=()
  local phase_descs=()
  while IFS='|' read -r type num name desc; do
    case "$type" in
      PHASE) phases+=("$num"); phase_names+=("$name"); phase_descs+=("$desc") ;;
    esac
  done <<< "$phases_data"

  if [ "${#phases[@]}" -eq 0 ]; then
    echo "error: no phases found in input" >&2
    exit 2
  fi

  echo "=== Dark-Factory Feature Breakdown ==="
  echo "Repo: $REPO"
  echo "Epic: $epic_title"
  echo "Phases: ${#phases[@]}"
  for i in "${!phases[@]}"; do
    echo "  Phase ${phases[i]}: ${phase_names[i]}"
  done
  echo

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN - no issues created"
    exit 0
  fi

  echo "Create these issues? [y/N]"
  read -r CONFIRM
  [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "aborted"; exit 0; }

  # Create epic
  local epic_body="Epic: $epic_title

This epic tracks the overall feature. Sub-issues represent phased implementation.

## Phases
"
  for i in "${!phases[@]}"; do
    local dep=""
    [ "$i" -gt 0 ] && dep=" (depends on Phase ${phases[$((i-1))]})"
    epic_body+="- Phase ${phases[i]}: ${phase_names[i]}$dep
"
  done
  epic_body+="
---
*Managed by dark-factory pipeline. Phases execute sequentially overnight.*"

  if [ "$DRY_RUN" -eq 0 ]; then
    echo "Creating epic..."
    EPIC_JSON=$(gh issue create --repo "$REPO" --title "Epic: $epic_title" --label darkf-epic --body "$epic_body" --json id,number)
    EPIC_NUMBER=$(echo "$EPIC_JSON" | jq -r .number)
    EPIC_ID=$(echo "$EPIC_JSON" | jq -r .id)
    echo "Created epic #$EPIC_NUMBER (id: $EPIC_ID)"
  else
    EPIC_NUMBER=999
    EPIC_ID="dummy"
  fi

  # Create phases
  local prev_issue_id=""
  for i in "${!phases[@]}"; do
    local phase_num="${phases[i]}"
    local phase_name="${phase_names[i]}"
    local phase_desc="${phase_descs[i]}"
    local title="Phase $phase_num: $phase_name"
    local depends_on=""
    [ "$i" -gt 0 ] && depends_on="#$((EPIC_NUMBER + i))"  # approximate; will update after create

    local body=$(build_phase_body "$phase_num" "$phase_name" "$phase_desc")

    if [ "$DRY_RUN" -eq 0 ]; then
      echo "Creating $title..."
      ISSUE_JSON=$(gh issue create --repo "$REPO" --title "$title" --label "darkf-todo,phase:$phase_num" --body "$body" --json id,number)
      ISSUE_NUMBER=$(echo "$ISSUE_JSON" | jq -r .number)
      ISSUE_ID=$(echo "$ISSUE_JSON" | jq -r .id)
      echo "  Created #$ISSUE_NUMBER (id: $ISSUE_ID)"

      # Add as sub-issue of epic via GraphQL
      gh api graphql -f query="
        mutation {
          addSubIssue(input: {issueId: \"$EPIC_ID\", subIssueId: \"$ISSUE_ID\"}) {
            clientMutationId
          }
        }
      " >/dev/null

      # Update depends-on reference in epic body (optional, for visibility)
      prev_issue_id="$ISSUE_ID"
    else
      echo "DRY RUN: would create $title"
    fi
  done

  echo
  echo "=== Done ==="
  echo "Epic: #$EPIC_NUMBER"
  for i in "${!phases[@]}"; do
    echo "  Phase ${phases[i]}: #$((EPIC_NUMBER + i + 1))"
  done
  echo
  echo "Dark-factory will pick up Phase 1 on next hourly scan (00:00-06:00 UTC)."
  echo "Subsequent phases auto-advance when prior phase PR merges (if AUTO_ADVANCE_PHASES=true)."
}

main
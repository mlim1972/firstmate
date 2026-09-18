#!/usr/bin/env bash
# darkf-feature-breakdown: decompose a feature plan/spec into a GitHub epic +
# phased sub-issues for dark-factory overnight processing.
# Uses gh-axi only.
#
# MODEL: the parent epic is the source of truth. Its body carries the full
# functionality and the ordered phase list. Each child sub-issue is:
#   - titled "  <Theme> - Phase <N>: <description>"   (Theme = epic title, so
#     every child of a parent shares the theme; the title carries phase+theme,
#     never the phase:N label)
#   - labeled darkf-todo (ALL children are eligible from the start)
#   - labeled phase:N (display/feed aid only, NOT identity or ordering)
#   - assigned to the current gh-axi user
#   - linked as a sub-issue of the epic, in creation order (this ordering is
#     what /darkfactory walks: 1, 2, 3 ... one PR at a time, merge before next)
#   - carrying the dark-factory 4-section template, referencing the spec by
#     path (content stays in the spec) or inline (interactive).
#
# Usage: fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo [--phases N]
#        fm-darkf-breakdown.sh --interactive --repo owner/repo [--phases N]
# Flags: --assignee <login>  override the assignee (default: current gh-axi user)
#        --dry-run           print what would be created, create nothing

set -eu

usage() {
  cat <<'EOF'
Usage: fm-darkf-breakdown.sh --plan SPEC.md --repo OWNER/REPO [--phases N]
       fm-darkf-breakdown.sh --interactive --repo OWNER/REPO [--phases N]

Decompose a feature into a GitHub epic (labeled darkf-epic) plus phased
sub-issues. Each child carries the dark-factory 4-section template, the
darkf-todo label (all eligible), a phase:N label (display only), is assigned to
the current gh-axi user, and is linked as a sub-issue of the epic in order.

Child titles: "<Theme> - Phase <N>: <description>", where <Theme> is the epic
title (all children of a parent share it). The phase:N label is NEVER identity
or ordering; the parent's sub-issue list order is.

Input sources (choose exactly one):
  --plan SPEC.md      A spec whose "## Phase N" headings define the phases.
                      Children reference the spec by path; content stays in the
                      spec.
  --interactive       The captain describes the feature and each phase inline;
                      the created issues carry that inline content.

Flags:
  --repo OWNER/REPO   Target GitHub repository (required)
  --phases N          Interactive hint for number of phases
  --assignee <login>  Assignee for the created issues (default: current user)
  --dry-run           Print what would be created; create nothing
  --from-lavish ID    Not implemented (use --plan or --interactive)
  -h, --help          Show this help

Uses gh-axi only.
EOF
}

PLAN_FILE=""
LAVISH_ID=""
INTERACTIVE=0
REPO=""
PHASES_HINT=""
ASSIGNEE=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) PLAN_FILE="$2"; shift 2 ;;
    --from-lavish) LAVISH_ID="$2"; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --phases) PHASES_HINT="$2"; shift 2 ;;
    --assignee) ASSIGNEE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option $1" >&2; usage; exit 2 ;;
  esac
done

SRC_COUNT=0
[ -n "$PLAN_FILE" ] && SRC_COUNT=$((SRC_COUNT + 1))
[ -n "$LAVISH_ID" ] && SRC_COUNT=$((SRC_COUNT + 1))
[ "$INTERACTIVE" -eq 1 ] && SRC_COUNT=$((SRC_COUNT + 1))
[ "$SRC_COUNT" -eq 1 ] || { echo "error: choose exactly one of --plan, --from-lavish, --interactive" >&2; exit 2; }

[ -n "$REPO" ] || { echo "error: --repo OWNER/REPO required" >&2; exit 2; }

# gh-axi present and authenticated; resolve the current user once.
if ! command -v gh-axi >/dev/null 2>&1; then
  echo "error: gh-axi CLI not found on PATH" >&2
  exit 3
fi
CURRENT_USER=$(gh-axi api user 2>/dev/null | sed -n 's/^login:[[:space:]]*//p' | head -1 || true)
if [ -z "$CURRENT_USER" ]; then
  echo "error: gh-axi not authenticated; log in first" >&2
  exit 3
fi
ASSIGNEE=${ASSIGNEE:-$CURRENT_USER}

# ---------------------------------------------------------------------------
# Phase extraction
# ---------------------------------------------------------------------------
build_phase_body() {
  local phase_num="$1" phase_name="$2" src_note="$3" desc="$4" epic="$5"
  cat <<EOF
### Problem
${phase_name}

### Impact
${desc}

### Proposed Solution
${src_note}

### Acceptance Criteria
See the referenced material. The phase is done when its described behavior
works and the relevant tests pass.

---
*Phase ${phase_num} of epic: ${epic}*
EOF
}

main() {
  local epic_title="Feature"
  local phases_data=""
  local -a phase_nums=() phase_names=() phase_bodies=() phase_ids=()

  if [ -n "$PLAN_FILE" ]; then
    [ -f "$PLAN_FILE" ] || { echo "error: plan file not found: $PLAN_FILE" >&2; exit 2; }
    PLAN_ABS=$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")
    epic_title=$(head -30 "$PLAN_FILE" | grep -E '^# ' | head -1 | sed 's/^# //')
    [ -z "$epic_title" ] && epic_title=$(basename "$PLAN_FILE" .md)
    SRC_NOTE="See $PLAN_ABS for the full detail (the proposed change lives in the spec, not this issue)."
    phases_data=$(awk '
      /^##?# Phase [0-9]+/ {
        line = $0
        if (match(line, /[0-9]+/)) num = substr(line, RSTART, RLENGTH)
        name = line
        sub(/^#+[[:space:]]*/, "", name)
        sub(/^Phase[[:space:]]*[0-9]+[[:space:]]*:?[[:space:]]*/, "", name)
        gsub(/[[:space:]]+$/, "", name)
        print num "|" name "|"
      }
    ' "$PLAN_FILE")
    if [ -z "$phases_data" ]; then
      echo "error: no '## Phase N' headings found in $PLAN_FILE" >&2
      exit 2
    fi
  elif [ -n "$LAVISH_ID" ]; then
    echo "error: Lavish integration not yet implemented; use --plan or --interactive" >&2
    exit 2
  elif [ "$INTERACTIVE" -eq 1 ]; then
    echo "Interactive feature breakdown"
    printf 'Feature description (one paragraph): '
    read -r FEATURE_DESC
    printf 'Number of phases (3-6) [%s]: ' "${PHASES_HINT:-4}"
    read -r NPHASES
    [ -n "$NPHASES" ] || NPHASES=${PHASES_HINT:-4}
    epic_title=${FEATURE_DESC:0:50}
    SRC_NOTE="Content provided inline by the captain during breakdown."
    for i in $(seq 1 "$NPHASES"); do
      printf 'Phase %s name: ' "$i"; read -r PNAME
      printf 'Phase %s description (what does it implement/ship?): ' "$i"; read -r PDESC
      phases_data+="${i}|${PNAME}|${PDESC}"$'\n'
    done
  fi

  while IFS='|' read -r num name desc; do
    [ -n "$num" ] || continue
    phase_nums+=("$num")
    phase_names+=("$name")
    if [ "$INTERACTIVE" -eq 1 ]; then
      phase_bodies+=("$(build_phase_body "$num" "$name" "$SRC_NOTE" "$desc" "$epic_title")")
    else
      phase_bodies+=("$(build_phase_body "$num" "$name" "$SRC_NOTE" "" "$epic_title")")
    fi
  done <<< "$phases_data"

  if [ "${#phase_nums[@]}" -eq 0 ]; then
    echo "error: no phases produced from input" >&2
    exit 2
  fi

  echo "=== Dark-Factory Feature Breakdown ==="
  echo "Repo: $REPO"
  echo "Epic (theme): $epic_title"
  echo "Assignee: $ASSIGNEE"
  echo "Phases: ${#phase_nums[@]} (all-eligible)"
  for i in "${!phase_nums[@]}"; do
    echo "  ${epic_title} - Phase ${phase_nums[i]}: ${phase_names[i]}"
  done
  echo

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN - no issues created."
    for i in "${!phase_nums[@]}"; do
      echo "  would create: ${epic_title} - Phase ${phase_nums[i]}: ${phase_names[i]}  (darkf-todo, phase:${phase_nums[i]}, assignee $ASSIGNEE)"
    done
    exit 0
  fi

  printf 'Create these issues in %s? [y/N] ' "$REPO"
  read -r CONFIRM
  [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "aborted"; exit 0; }

  # --- ensure the dark-factory labels exist (idempotent) ---
  echo "Ensuring dark-factory labels in $REPO..."
  for spec in "darkf-epic:a2eeef" "darkf-todo:1d76db" "darkf-wip:1d76db" "darkf-failed:d73a4a"; do
    name="${spec%%:*}"; color="${spec##*:}"
    if ! label_out=$(gh-axi label create -R "$REPO" --name "$name" --color "$color" --description "Dark-factory:$name" 2>&1); then
      printf '%s' "$label_out" | grep -qi "already_exists\|already exists" || echo "  warn: could not ensure label $name"
    fi
  done
  for num in "${phase_nums[@]}"; do
    gh-axi label create -R "$REPO" --name "phase:$num" --color 5319e7 --description "Dark-factory phase (display only; ordering is the parent's sub-issue list)" >/dev/null 2>&1 || true
  done

  # --- epic body: full functionality + ordered phase list ---
  local epic_body="Epic: $epic_title

This epic carries the full functionality. Its sub-issues are the work units,
processed in order, one PR at a time (serial dark-factory run).

## Phases (execution order)
"
  for i in "${!phase_nums[@]}"; do
    epic_body+="- ${epic_title} - Phase ${phase_nums[i]}: ${phase_names[i]}"$'\n'
  done
  epic_body+=$'\n'"---
Managed by the dark-factory pipeline (run with /darkfactory)."

  # --- create epic ---
  echo "Creating epic..."
  OUT=$(gh-axi issue create -R "$REPO" --title "Epic: $epic_title" --label darkf-epic --body-file <(printf '%s' "$epic_body") 2>&1)
  EPIC_NUMBER=$(printf '%s' "$OUT" | sed -n 's/^[[:space:]]*number:[[:space:]]*//p' | head -1)
  if [ -z "$EPIC_NUMBER" ]; then
    echo "error: failed to create epic:" >&2; printf '%s\n' "$OUT" >&2; exit 3
  fi
  echo "  created epic #$EPIC_NUMBER"

  # --- create children: all-eligible, sequential order via sub-issue links ---
  for i in "${!phase_nums[@]}"; do
    local num="${phase_nums[i]}" name="${phase_names[i]}" body="${phase_bodies[i]}"
    local title="${epic_title} - Phase ${num}: ${name}"
    local body_file
    body_file=$(mktemp) || exit 2
    printf '%s\n' "$body" > "$body_file"
    echo "Creating: $title"
    OUT=$(gh-axi issue create -R "$REPO" --title "$title" \
      --label "darkf-todo" --label "phase:$num" \
      --assignee "$ASSIGNEE" --body-file "$body_file" 2>&1)
    rm -f "$body_file"
    ISSUE_NUMBER=$(printf '%s' "$OUT" | sed -n 's/^[[:space:]]*number:[[:space:]]*//p' | head -1)
    if [ -z "$ISSUE_NUMBER" ]; then
      echo "error: failed to create Phase $num:" >&2; printf '%s\n' "$OUT" >&2; exit 3
    fi
    echo "  created #$ISSUE_NUMBER (phase:$num, darkf-todo, assignee $ASSIGNEE)"
    gh-axi issue subissue add "$EPIC_NUMBER" "$ISSUE_NUMBER" -R "$REPO" >/dev/null 2>&1 \
      || echo "  warn: could not link #$ISSUE_NUMBER under epic #$EPIC_NUMBER (sub-issue API may be unavailable); it will still run"
    phase_ids+=("$ISSUE_NUMBER")
  done

  echo
  echo "=== Done ==="
  echo "Epic/theme: $epic_title  #$EPIC_NUMBER ($REPO)"
  for i in "${!phase_nums[@]}"; do
    echo "  Phase ${phase_nums[i]}: #${phase_ids[i]}  ${epic_title} - Phase ${phase_nums[i]}: ${phase_names[i]}"
  done
  echo
  echo "All children are darkf-todo. Run /darkfactory to process them in order."
}

main
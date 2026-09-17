#!/usr/bin/env bash
# darkf-intake: validate a GitHub issue against the dark-factory task template
# and create a Firstmate backlog ship task on success.
# Uses gh-axi only. The current user is read from gh-axi, never hardcoded.
# Gates (in order, each fail exits before creating anything):
#   1. issue must be OPEN and carry the 'darkf-todo' label
#   2. ASSIGNEE GATE: the issue must be assigned to the current gh-axi user
#   3. DEPENDENCY GATE (option A): if the issue has sub-issues (dependents),
#      every dependent must also carry 'darkf-todo'; otherwise the parent is
#      skipped because a PR for it alone has no point.
#   4. TEMPLATE GATE: body or comments must contain all four required
#      section headers (### Problem, ### Impact, ### Proposed Solution,
#      ### Acceptance Criteria).
# On total success: creates the backlog ship task, records darkf_* in task
# meta, and adds the 'darkf-wip' label.
# On failure: labels the issue 'darkf-failed', removes 'darkf-todo', comments
# the missing sections. The dependency gate SKIPS without labeling (not ready).
# The assignee gate STOPS (exit 5): dark factory halts because a child not
# assigned to the current user means the serial chain cannot proceed. That
# distinct code lets the /darkfactory skill distinguish "stop the run" from
# "skip this one and continue".
#
# Usage: fm-darkf-intake.sh <issue-url>
# Env: DRY_RUN=1  print the gate decisions and the task that would be created,
#                 mutating nothing (no backlog task, no label change).
# Exits: 0 success (or clean skip), 1 validation failure, 2 usage/config,
#        3 gh-axi auth/permission/dependency error, 5 assignee STOP (not mine).

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  cat <<'EOF'
Usage: fm-darkf-intake.sh <issue-url>

Validates a GitHub issue against the dark-factory task template and creates a
Firstmate backlog ship task on success. Uses gh-axi only; the current user is
read from gh-axi, never hardcoded.

Gates (in order):
  1. OPEN + has the 'darkf-todo' label
  2. assigned to the current gh-axi user (otherwise STOP, exit 5 - dark factory
     halts: a child not assigned to the operator cannot be part of the serial
     chain)
  3. if the issue has sub-issues, every dependent also carries 'darkf-todo'
     (otherwise SKIP, no change)
  4. body or comments contain all four required section headers

On success: creates a backlog ship task, records darkf_* in its meta, adds
'darkf-wip'. On template failure: labels 'darkf-failed', removes 'darkf-todo',
comments the missing sections.

Env: DRY_RUN=1 prints the gate decisions and would-be task, mutating nothing.
EOF
}

if [ "$#" -ne 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 2
fi

ISSUE_URL="$1"

# ---- resolve the issue identity -----------------------------------------------
if ! [[ "$ISSUE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
  echo "error: not a valid GitHub issue URL: $ISSUE_URL" >&2
  exit 2
fi
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"
REPO_FULL="$OWNER/$REPO"

# ---- gh-axi present and authenticated, read the current user ------------------
if ! command -v gh-axi >/dev/null 2>&1; then
  echo "error: gh-axi CLI not found on PATH" >&2
  exit 3
fi
CURRENT_USER=$(gh-axi api user 2>/dev/null | sed -n 's/^login:[[:space:]]*//p' | head -1 || true)
if [ -z "$CURRENT_USER" ]; then
  echo "error: gh-axi not authenticated; log in first" >&2
  exit 3
fi

# ---- fetch the issue body (full, unescaped) + state ---------------------------
# gh-axi api renders YAML-ish output. The body is one quoted scalar with
# escaped \n, so strip the quotes and unescape it for header scanning.
BODY_ESC=$(gh-axi api "/repos/$REPO_FULL/issues/$NUMBER" --full 2>/dev/null \
  | sed -n 's/^body:[[:space:]]*//p' | head -1 || true)
if [ -z "${BODY_ESC:-}" ]; then
  echo "error: failed to fetch issue (permission denied or not found)" >&2
  exit 3
fi
BODY=$(printf '%b' "${BODY_ESC//\"/}")

STATE=$(gh-axi api "/repos/$REPO_FULL/issues/$NUMBER" --full 2>/dev/null \
  | sed -n 's/^state:[[:space:]]*//p' | head -1 || true)

# labels: fetch WITHOUT --full (clean id,name,color rows; --full injects a
# comma-filled node_id/url column that breaks field-2 parsing). Rows appear
# between a "^labels[N]{" header and the next top-level key (^state:); name is
# field 2.
LABELS=$(gh-axi api "/repos/$REPO_FULL/issues/$NUMBER" 2>/dev/null \
  | sed -n '/^labels\[/,$p' | sed '/^state:/,$d' \
  | sed -n 's/^[[:space:]]*[0-9]*,[[:space:]]*//p' \
  | sed 's/,.*//; s/"//g; s/[[:space:]]*$//')

# assignees: fetch WITHOUT --full. Rows "login,id,type" between a
# "^assignees[" header and the next top-level key (assignee/state); login is
# field 1. Keep only rows that look like login,id,type.
ASSIGNEES=$(gh-axi api "/repos/$REPO_FULL/issues/$NUMBER" 2>/dev/null \
  | sed -n '/^assignees\[/,$p' | sed '/^assignee:/,$d' \
  | sed -n 's/^[[:space:]]*//p' \
  | grep -E '^[^[:space:]]+,[0-9]+,(User|Bot)$' | sed 's/,.*//' || true)

# ---- gate 1: state + darkf-todo label -----------------------------------------
if [ "$STATE" != "open" ]; then
  echo "skip: issue #$NUMBER is $STATE, not open"
  exit 0
fi
if ! printf '%s\n' "$LABELS" | grep -qw 'darkf-todo'; then
  echo "skip: issue #$NUMBER does not carry 'darkf-todo'"
  exit 0
fi

# ---- gate 2: assignee must be the current user; NOT assigned => STOP -------
if ! printf '%s\n' "$ASSIGNEES" | grep -qx "$CURRENT_USER"; then
  echo "stop: issue #$NUMBER is not assigned to $CURRENT_USER (darkf-todo, not mine); halting the serial chain"
  exit 5
fi

# ---- gate 3: dependency gate - every sub-issue must also carry darkf-todo ------
# Option A: a parent is only dispatchable when its whole dependent set is tagged.
SUBISSUES=$(gh-axi issue subissue list "$NUMBER" -R "$REPO_FULL" 2>/dev/null \
  | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' || true)
if [ -n "$SUBISSUES" ]; then
  # set of all darkf-todo-tagged open issue numbers in this repo (any assignee)
  DARKF_SET=$(gh-axi issue list -R "$REPO_FULL" --state open --label darkf-todo --fields number --limit 100 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' || true)
  MISSING_DEP=""
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if ! printf '%s\n' "$DARKF_SET" | grep -qx "$dep"; then
      MISSING_DEP="$MISSING_DEP $dep"
    fi
  done <<< "$SUBISSUES"
  if [ -n "$MISSING_DEP" ]; then
    echo "skip: issue #$NUMBER depends on sub-issue(s) not carrying darkf-todo:$MISSING_DEP"
    exit 0
  fi
  echo "dependency gate: all dependents carry darkf-todo"
fi

# ---- gate 4: template validation (body or comments) ----------------------------
COMMENTS=$(gh-axi api "/repos/$REPO_FULL/issues/$NUMBER/comments" --full 2>/dev/null \
  | sed -n 's/^[[:space:]]*body:[[:space:]]*//p' | sed 's/^"//; s/"$//' || true)
COMMENTS_UNESC=""
if [ -n "$COMMENTS" ]; then
  COMMENTS_UNESC=$(printf '%b' "$COMMENTS")
fi
FULL_TEXT="$BODY"$'\n'"$COMMENTS_UNESC"

REQUIRED=("problem" "impact" "proposed-solution" "acceptance-criteria")
MISSING=()
for section in "${REQUIRED[@]}"; do
  # words joined by a space or hyphen (Proposed Solution / Proposed-Solution);
  # section may be followed by a space or end-of-line (### Problem\n)
  PATTERN_SECTION=${section//-/[-[:space:]]?}
  PATTERN="^###[[:space:]]*${PATTERN_SECTION}([[:space:]]|$)"
  if ! printf '%s' "$FULL_TEXT" | grep -qiE "$PATTERN"; then
    ALT_PATTERN="^$(printf '%s' "$section" | tr '[:lower:]' '[:upper:]'):"
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
  if [ "${DRY_RUN:-0}" != "1" ]; then
    gh-axi issue edit "$NUMBER" -R "$REPO_FULL" --remove-label darkf-todo --add-label darkf-failed >/dev/null
    gh-axi issue comment "$NUMBER" -R "$REPO_FULL" --body "$COMMENT" >/dev/null
  else
    echo "[dry-run] would label issues/$NUMBER darkf-failed and comment missing sections"
  fi
  echo "failed: $MISSING_LIST"
  exit 1
fi

# ---- create the backlog task ---------------------------------------------------
TITLE=$(gh-axi api "/repos/$REPO_FULL/issues/$NUMBER" --full 2>/dev/null \
  | sed -n 's/^title:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//' || true)
TITLE=${TITLE:-"issue #$NUMBER"}

PROJECT_NAME=""
REPO_NAME="${REPO#*/}"
# registry stores the repo NAME (brainiac), not owner/name; match the name part.
line=$(grep -E "^[[:space:]]*-[[:space:]]+${REPO_NAME}([[:space:]]|\[)" "$FM_ROOT/data/projects.md" 2>/dev/null | head -1)
if [ -z "$line" ]; then
  line=$(grep -i "$REPO_NAME" "$FM_ROOT/data/projects.md" 2>/dev/null | head -1)
fi
if [ -n "$line" ]; then
  PROJECT_NAME=$(printf '%s\n' "$line" | sed -E 's/^ *- *([^[]+).*/\1/' | awk '{$1=$1};1')
fi
if [ -z "$PROJECT_NAME" ]; then
  echo "error: repo $REPO_FULL not registered in data/projects.md; run project-management add first" >&2
  exit 2
fi

TASK_TITLE="darkf: $TITLE"
TASKS="$FM_ROOT/bin/fm-tasks-axi.sh"
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] would create task: $TASK_TITLE (repo=$PROJECT_NAME, issue=$ISSUE_URL, assignee=$CURRENT_USER)"
  exit 0
fi

TASK_JSON=$("$TASKS" add "$TASK_TITLE" --kind ship --repo "$PROJECT_NAME" --json 2>/dev/null) || {
  echo "error: failed to create backlog task" >&2
  exit 2
}
TASK_ID=$(printf '%s' "$TASK_JSON" | sed -n 's/^[[:space:]]*id:[[:space:]]*//p' | head -1 | tr -d '"')
if [ -z "$TASK_ID" ]; then
  echo "error: could not read task id from tasks-axi output" >&2
  exit 2
fi

{
  echo "darkf_issue=$ISSUE_URL"
  echo "darkf_number=$NUMBER"
  echo "darkf_repo=$REPO_FULL"
  echo "darkf_assignee=$CURRENT_USER"
} >> "$FM_ROOT/state/$TASK_ID.meta"

[ "${DRY_RUN:-0}" = "1" ] || gh-axi issue edit "$NUMBER" -R "$REPO_FULL" --add-label darkf-wip >/dev/null

echo "success: created task $TASK_ID for $REPO_FULL#$NUMBER (assignee $CURRENT_USER)"
exit 0
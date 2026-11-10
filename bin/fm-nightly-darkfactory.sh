#!/usr/bin/env bash
# nightly-darkfactory: scriptable dark-factory pipeline with optional secondmate correlation.
# Usage: fm-nightly-darkfactory.sh [--corr <corr_id>] [project...]
# Env: FM_HOME (required), FM_ROOT_OVERRIDE (optional)

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

CORR_ID=""
TARGET_PROJECTS=()

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: fm-nightly-darkfactory.sh [--corr <corr_id>] [project...]

Runs the dark-factory overnight PR pipeline.

Options:
  --corr <corr_id>    Explicit correlation ID (for secondmate context)
  project...          Limit to specific project(s) from data/projects.md

Environment:
  FM_HOME             Required: firstmate home directory
  FM_ROOT_OVERRIDE    Optional: override code root

On main firstmate: prints summary to stdout.
On secondmate: writes correlated done status line to resolve parent's
                 pending-reply expectation.
EOF
      exit 0
      ;;
    --corr)
      [ $# -ge 2 ] || { echo "error: --corr requires a correlation id" >&2; exit 2; }
      CORR_ID="$2"
      shift 2
      ;;
    --corr=*)
      CORR_ID="${1#--corr=}"
      shift
      ;;
    *)
      TARGET_PROJECTS+=("$1")
      shift
      ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

log() { printf '[nightly-darkfactory] %s\n' "$*" >&2; }

is_secondmate_home() {
  [ -f "$FM_HOME/.fm-secondmate-home" ]
}

get_secondmate_task_id() {
  # Read task id from metadata
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    if grep -qE '^kind=secondmate$' "$meta" 2>/dev/null; then
      basename "$meta" .meta
      return 0
    fi
  done
  return 1
}

extract_corr_from_inbox() {
  local task_id="$1"
  local inbox_dir="$STATE/$task_id.inbox"
  [ -d "$inbox_dir" ] || return 1
  # Find the latest handled or unhandled inbox record
  local latest_record=""
  local record
  for record in "$inbox_dir"/*; do
    [ -e "$record" ] || continue
    record=$(basename "$record")
    case "$record" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ -z "$latest_record" ] || [ "$record" -gt "$latest_record" ]; then
      latest_record="$record"
    fi
  done
  [ -n "$latest_record" ] || return 1
  local msg
  msg=$(cat "$inbox_dir/$latest_record" 2>/dev/null || true)
  # Extract corr=<16hex>
  printf '%s' "$msg" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2
}

run_darkfactory_pipeline() {
  local projects_arg=()
  if [ ${#TARGET_PROJECTS[@]} -gt 0 ]; then
    projects_arg=("${TARGET_PROJECTS[@]}")
  fi

  # Source the darkfactory skill logic - we replicate the core flow here
  # since the skill is designed for interactive invocation.

  local mode yolo
  local phases_landed=0
  local phases_open=0
  local stopped_reason=""

  # 1. Resolve target projects from registry
  local all_projects=()
  if [ -f "$DATA/projects.md" ]; then
    if [ ${#projects_arg[@]} -gt 0 ]; then
      for p in "${projects_arg[@]}"; do
        if grep -qE "^[[:space:]]*-[[:space:]]+${p}([[:space:]]|\[)" "$DATA/projects.md"; then
          all_projects+=("$p")
        else
          log "warn: project '$p' not in registry, skipping"
        fi
      done
    else
      # All projects
      while IFS= read -r line; do
        local name
        name=$(printf '%s\n' "$line" | sed -E 's/^ *- *([^[]+).*/\1/' | awk '{$1=$1};1')
        [ -n "$name" ] && all_projects+=("$name")
      done < <(grep -E '^ *- ' "$DATA/projects.md" || true)
    fi
  fi

  [ ${#all_projects[@]} -gt 0 ] || {
    log "no projects to scan"
    return 0
  }

  # 2. For each project, find darkf-epic issues and process children
  for project in "${all_projects[@]}"; do
    log "scanning project: $project"

    # Get repo from clone origin
    local repo_dir="$FM_ROOT/projects/$project"
    if [ ! -d "$repo_dir/.git" ]; then
      log "warn: project '$project' not cloned at $repo_dir, skipping"
      continue
    fi

    local origin_url
    origin_url=$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null || true)
    [ -n "$origin_url" ] || { log "warn: no origin for $project, skipping"; continue; }

    # Parse owner/repo from origin
    local repo_full
    if [[ "$origin_url" =~ github\.com[:/](.+)/(.+)\.git$ ]]; then
      repo_full="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    elif [[ "$origin_url" =~ github\.com[:/](.+)/(.+)$ ]]; then
      repo_full="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
      log "warn: cannot parse origin '$origin_url' for $project, skipping"
      continue
    fi

    log "  repo: $repo_full"

    # 3. Find parent epics (darkf-epic label)
    local epics
    epics=$(gh-axi issue list -R "$repo_full" --state open --label darkf-epic --limit 50 2>/dev/null \
      | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' || true)

    [ -n "$epics" ] || { log "  no darkf-epic issues"; continue; }

    while IFS= read -r epic_num; do
      [ -n "$epic_num" ] || continue
      log "  processing epic #$epic_num"

      # 4. List sub-issues in order
      local children
      children=$(gh-axi issue subissue list "$epic_num" -R "$repo_full" 2>/dev/null \
        | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' || true)

      [ -n "$children" ] || { log "    no sub-issues"; continue; }

      # 5. Process each child in order
      while IFS= read -r child_num; do
        [ -n "$child_num" ] || continue
        local issue_url="https://github.com/$repo_full/issues/$child_num"

        log "    intake: $issue_url"

        # Run intake gate
        local intake_out
        intake_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
          "$FM_ROOT/bin/fm-darkf-intake.sh" "$issue_url" 2>&1) || {
          local rc=$?
          case $rc in
            5)
              log "      STOP: $intake_out"
              stopped_reason="child #$child_num not assigned to captain"
              break 2
              ;;
            1)
              log "      failed: $intake_out"
              phases_open=$((phases_open + 1))
              continue
              ;;
            *) log "      error (exit $rc): $intake_out"; return 1 ;;
          esac
          continue
        }

        log "      $intake_out"

        # Extract task ID from intake output
        local task_id
        task_id=$(printf '%s\n' "$intake_out" | sed -n 's/.*created task \(fm-[a-z0-9-]*\).*/\1/p')
        [ -n "$task_id" ] || {
          log "      warn: could not extract task id from: $intake_out"
          continue
        }

        # 6. Resolve mode and yolo from project posture
        local mode_yolo
        mode_yolo=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
          "$FM_ROOT/bin/fm-project-mode.sh" "$project" 2>/dev/null || echo "no-mistakes off")
        mode=${mode_yolo%% *}
        yolo=${mode_yolo##* }

        log "      dispatching $task_id (mode=$mode, yolo=$yolo)"

        # 7. Brief and spawn
        FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
          "$FM_ROOT/bin/fm-brief.sh" "$task_id" "$project" --mode "$mode" >/dev/null || {
          log "      error: brief failed"
          return 1
        }

        FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
          "$FM_ROOT/bin/fm-spawn.sh" "$task_id" "$project" --mode "$mode" --yolo "$yolo" >/dev/null || {
          log "      error: spawn failed"
          return 1
        }

        # 8. Wait for PR merge (merge-before-next)
        log "      waiting for PR merge..."
        local pr_merged=0
        local attempts=0
        while [ $attempts -lt 60 ]; do # ~30 min max wait
          sleep 30
          attempts=$((attempts + 1))

          # Check task status for PR merge
          local task_status
          task_status=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
            "$FM_ROOT/bin/fm-crew-state.sh" "$task_id" 2>/dev/null | head -5 || true)

          if printf '%s\n' "$task_status" | grep -q "done.*PR.*checks green"; then
            pr_merged=1
            break
          fi
          if printf '%s\n' "$task_status" | grep -q "done.*PR"; then
            # PR opened but not merged (yolo off)
            log "      PR opened, waiting for merge (yolo=$yolo)"
            if [ "$yolo" = "off" ]; then
              log "      yolo=off: waiting for captain merge"
              # Keep waiting
            fi
          fi
        done

        if [ $pr_merged -eq 1 ]; then
          log "      phase landed: $task_id"
          phases_landed=$((phases_landed + 1))
        else
          log "      timeout or not merged: $task_id"
          phases_open=$((phases_open + 1))
        fi

      done <<< "$children"

      [ -z "$stopped_reason" ] || break

    done <<< "$epics"

    [ -z "$stopped_reason" ] || break
  done

  # Build summary
  local summary
  if [ $phases_landed -eq 0 ] && [ $phases_open -eq 0 ] && [ -z "$stopped_reason" ]; then
    summary="no eligible darkf-todo children found"
  else
    summary="landed $phases_landed, open $phases_open"
    [ -n "$stopped_reason" ] && summary="$summary; stopped: $stopped_reason"
  fi

  log "summary: $summary"
  printf '%s\n' "$summary"
}

# ---- main -------------------------------------------------------------------

if is_secondmate_home; then
  log "running on secondmate home"
  TASK_ID=$(get_secondmate_task_id) || true
  if [ -z "$TASK_ID" ]; then
    log "error: no secondmate task id found in $STATE"
    exit 1
  fi
  log "secondmate task: $TASK_ID"

  # Auto-detect correlation ID if not provided
  if [ -z "$CORR_ID" ]; then
    CORR_ID=$(extract_corr_from_inbox "$TASK_ID" || true)
  fi

  if [ -n "$CORR_ID" ]; then
    log "using correlation: $CORR_ID"
  else
    log "warn: no correlation ID found; parent will not auto-resolve"
  fi

  # Run pipeline and capture summary
  RC=0
  SUMMARY=$(run_darkfactory_pipeline) || RC=$?

  # Write correlated done status line
  if [ -n "$CORR_ID" ]; then
    if [ "$RC" -eq 0 ]; then
      done_line="done [corr=$CORR_ID]: nightly darkfactory complete - $SUMMARY"
    else
      done_line="done [corr=$CORR_ID]: nightly darkfactory failed (exit $RC)"
    fi
    # Use fm-wake-lib to append to status file
    . "$FM_ROOT/bin/fm-wake-lib.sh"
    fm_wake_status_append_self_announced "$STATE" "$STATE/$TASK_ID.status" "$done_line" || true
    log "wrote correlated done status"
  fi

  exit $RC
else
  log "running on main firstmate"
  run_darkfactory_pipeline
  exit $?
fi
#!/usr/bin/env bash
# Behavior tests for the gh-axi-only dark-factory intake/breakdown rewrite,
# targeting the two review-round-1 regressions the captain asked to fix:
#
#   1. fm-darkf-intake.sh: the rewrite dropped the `mkdir -p` that used to be
#      a side effect of creating the task's state subdirectory, so appending
#      to state/<id>.meta could fail under `set -eu` the very first time a
#      home's state/ directory does not exist yet (this fresh worktree has
#      none). The fix restores an explicit `mkdir -p "$FM_ROOT/state"` before
#      that append. This test drives the full success path against a home
#      whose state/ directory is absent beforehand.
#   2. fm-darkf-breakdown.sh: label provisioning treated ANY non-zero exit
#      from `gh-axi label create` as a warning, so a second run against a
#      repo that already has the dark-factory labels printed a false
#      "warn: could not ensure label" for every label. The fix only warns
#      when the failure is not an "already exists" response.
#
# Both scripts talk to GitHub exclusively through `gh-axi`; a fake `gh-axi` on
# PATH stands in for the real CLI so the suite never touches a live repo.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-darkf-intake.sh"
BREAKDOWN="$ROOT/bin/fm-darkf-breakdown.sh"

TMP=$(fm_test_tmproot fm-darkf-pipeline)

# ---------------------------------------------------------------------------
# fm-darkf-intake.sh: success path with no pre-existing state/ directory
# ---------------------------------------------------------------------------

make_intake_home() {  # <name> -> echoes the FM_ROOT to use
  local dir="$TMP/$1"
  mkdir -p "$dir/bin" "$dir/data" "$dir/fakebin"
  # Registered project so the title -> project-name lookup succeeds.
  printf -- '- myrepo [github]\n' > "$dir/data/projects.md"

  # Fake fm-tasks-axi.sh: only `add ... --json` is exercised by the intake
  # script; echo back a fixed task id as the JSON shape it expects.
  cat > "$dir/bin/fm-tasks-axi.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--json*) printf '{"task":{"id":"T1"}}\n' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$dir/bin/fm-tasks-axi.sh"

  # Fake gh-axi answering exactly the calls fm-darkf-intake.sh makes for a
  # fully-valid, unassigned-dependency, template-complete issue.
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "api user")
    printf 'login: testuser\n' ;;
  "api /repos/owner/myrepo/issues/7 --full")
    printf 'state: open\n'
    printf 'title: "Test issue"\n'
    printf 'body: "### Problem\\nx\\n\\n### Impact\\nx\\n\\n### Proposed Solution\\nx\\n\\n### Acceptance Criteria\\nx"\n' ;;
  "api /repos/owner/myrepo/issues/7")
    printf 'labels[2]{id,name,color}\n'
    printf '  0, darkf-todo, 1d76db\n'
    printf 'assignees[1]{login,id,type}\n'
    printf '  testuser,1,User\n'
    printf 'state: open\n' ;;
  "api /repos/owner/myrepo/issues/7/comments --full")
    ;;
  "issue subissue list 7 -R owner/myrepo")
    ;;
  "issue edit 7 -R owner/myrepo --add-label darkf-wip")
    ;;
  *)
    echo "fake gh-axi: unhandled: $*" >&2; exit 9 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"

  printf '%s\n' "$dir"
}

test_intake_creates_state_dir_and_meta() {
  local home out rc
  home=$(make_intake_home intake-ok)

  assert_absent "$home/state" "intake: fixture must start with no state/ dir (that's the regression)"

  out=$(FM_ROOT_OVERRIDE="$home" PATH="$home/fakebin:$PATH" \
    "$INTAKE" "https://github.com/owner/myrepo/issues/7" 2>&1)
  rc=$?

  expect_code 0 "$rc" "intake: full success path must exit 0"
  assert_contains "$out" "success: created task T1" "intake: success message names the created task"
  assert_present "$home/state/T1.meta" "intake: meta file must exist even though state/ did not pre-exist"
  assert_grep "darkf_issue=https://github.com/owner/myrepo/issues/7" "$home/state/T1.meta" \
    "intake: meta records the source issue"
  assert_grep "darkf_assignee=testuser" "$home/state/T1.meta" "intake: meta records the assignee"

  pass "fm-darkf-intake: success path creates state/ on demand and records darkf_* meta"
}

# ---------------------------------------------------------------------------
# fm-darkf-breakdown.sh: idempotent label provisioning
# ---------------------------------------------------------------------------

make_breakdown_fakebin() {  # <name> <label_create_behavior: exists|denied> -> echoes fakebin dir
  local dir="$TMP/$1" behavior="$2"
  mkdir -p "$dir"
  cat > "$dir/gh-axi" <<SH
#!/usr/bin/env bash
case "\$1 \$2" in
  "api user")
    printf 'login: testuser\n'; exit 0 ;;
esac
case "\$1 \$2" in
  "label create")
    if [ "$behavior" = exists ]; then
      echo 'HTTP 422: Validation Failed (already_exists) for label "'"\$4"'"' >&2
      exit 1
    else
      echo 'HTTP 403: Resource not accessible by integration' >&2
      exit 1
    fi
    ;;
  "issue create")
    printf 'number: 42\n'; exit 0 ;;
  "issue subissue")
    exit 0 ;;
esac
echo "fake gh-axi: unhandled: \$*" >&2; exit 9
SH
  chmod +x "$dir/gh-axi"
  printf '%s\n' "$dir"
}

make_plan_file() {
  local f="$TMP/plan.md"
  cat > "$f" <<'EOF'
# Sample Feature

## Phase 1
First phase.
EOF
  printf '%s\n' "$f"
}

test_breakdown_already_exists_label_is_quiet() {
  local fakebin plan out rc
  fakebin=$(make_breakdown_fakebin breakdown-exists exists)
  plan=$(make_plan_file)

  out=$(printf 'y\n' | PATH="$fakebin:$PATH" \
    "$BREAKDOWN" --plan "$plan" --repo owner/myrepo 2>&1)
  rc=$?

  expect_code 0 "$rc" "breakdown: an already-exists label response must not fail the run"
  assert_not_contains "$out" "warn: could not ensure label" \
    "breakdown: a label that already exists must not print a false warning"

  pass "fm-darkf-breakdown: idempotent re-run against already-labeled repo prints no false warnings"
}

test_breakdown_genuine_label_error_still_warns() {
  local fakebin plan out rc
  fakebin=$(make_breakdown_fakebin breakdown-denied denied)
  plan=$(make_plan_file)

  out=$(printf 'y\n' | PATH="$fakebin:$PATH" \
    "$BREAKDOWN" --plan "$plan" --repo owner/myrepo 2>&1)
  rc=$?

  expect_code 0 "$rc" "breakdown: a label-provisioning warning must not abort the run"
  assert_contains "$out" "warn: could not ensure label" \
    "breakdown: a genuine (non already-exists) label failure must still warn"

  pass "fm-darkf-breakdown: a genuine label-create error still surfaces its warning"
}

test_intake_creates_state_dir_and_meta
test_breakdown_already_exists_label_is_quiet
test_breakdown_genuine_label_error_still_warns

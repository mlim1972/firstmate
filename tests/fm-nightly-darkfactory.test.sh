#!/usr/bin/env bash
# tests/fm-nightly-darkfactory.test.sh - behavior coverage for the secondmate
# correlated-status contract of bin/fm-nightly-darkfactory.sh, targeting the
# review-round regressions the captain asked fixed:
#
#   review-1/review-2: under `set -eu`, an unguarded `local done_line=...` at
#     top-level scope (not inside a function) and an unguarded
#     `SUMMARY=$(run_darkfactory_pipeline)` both aborted the script before the
#     correlated `done [corr=...]` status line was ever written - on success
#     AND on pipeline failure. This suite drives the script for real (not a
#     source-text check) and asserts the status line actually lands in both
#     cases.
#   review-3: `log()` wrote to stdout, so it leaked into `$SUMMARY` (captured
#     via command substitution) alongside the real one-line summary. This
#     suite asserts the written status line is exactly the expected single
#     line with no embedded log/progress transcript.
#   review-4: `TASK_ID=$(get_secondmate_task_id)` was unguarded, so a home with
#     no matching task metadata aborted under `set -e` before the friendlier
#     "no secondmate task id found" diagnostic ever printed.
#   review-5: the done_line template was unconditional ("... complete - " even
#     on failure), misleading a pending-reply consumer into believing an
#     overnight run succeeded when it exited non-zero. This suite asserts the
#     failure line says "failed (exit N)", never "complete".
#
# Talks to GitHub exclusively through `gh-axi`; a fake `gh-axi` and a faked
# fm-darkf-intake.sh stand in so the suite never touches a live repo or spawns
# a real ship.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-nightly-darkfactory.sh"

TMP=$(fm_test_tmproot fm-nightly-darkfactory)

# A fake code root whose bin/ mirrors the real repo's bin/ (so the script's
# `$FM_ROOT/bin/fm-wake-lib.sh` sourcing and its other `$FM_ROOT/bin/*` calls
# resolve normally) except for fm-darkf-intake.sh, which each test overrides
# to force a specific run_darkfactory_pipeline outcome.
make_fake_root() {  # <name> -> echoes the FM_ROOT_OVERRIDE to use
  local dir="$TMP/$1" f base
  mkdir -p "$dir/bin"
  for f in "$ROOT"/bin/*; do
    base=$(basename "$f")
    ln -s "$f" "$dir/bin/$base"
  done
  printf '%s\n' "$dir"
}

# A secondmate FM_HOME with a task meta (kind=secondmate), an inbox record
# carrying a corr=<16hex> steer marker, and an empty state/<id>.status file.
make_secondmate_home() {  # <name> <corr> -> echoes "<home> <task_id>"
  local dir="$TMP/$1" corr="$2" task_id="fm-nightlytest"
  mkdir -p "$dir/state/$task_id.inbox" "$dir/data"
  : > "$dir/.fm-secondmate-home"
  fm_write_meta "$dir/state/$task_id.meta" "kind=secondmate"
  printf 'steer: run nightly darkfactory corr=%s\n' "$corr" > "$dir/state/$task_id.inbox/1"
  : > "$dir/state/$task_id.status"
  printf '%s %s\n' "$dir" "$task_id"
}

CORR="ab12ab12ab12ab12"

# ---------------------------------------------------------------------------
# Success path: registered project whose repo is not cloned locally, so the
# pipeline finds nothing to do and reports "no eligible darkf-todo children
# found" with exit 0. Exercises review-1/2/3/5's success branch.
# ---------------------------------------------------------------------------

test_success_writes_clean_correlated_done_line() {
  local fakeroot home task_id out rc status_file
  fakeroot=$(make_fake_root fakeroot-success)
  read -r home task_id < <(make_secondmate_home home-success "$CORR")
  printf -- '- myrepo [github]\n' > "$home/data/projects.md"
  status_file="$home/state/$task_id.status"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$fakeroot" "$SCRIPT" 2>/dev/null)
  rc=$?

  expect_code 0 "$rc" "success path: exit 0 when the pipeline finds nothing to do"
  # fm_wake_status_append_self_announced stamps each line with "[at=<epoch>]"
  # between the corr tag and the message body, so the two fixed substrings are
  # asserted separately rather than as one contiguous string.
  assert_grep "done [corr=$CORR]" "$status_file" \
    "success path: status file gets a done line carrying the correlation id"
  assert_grep "nightly darkfactory complete - no eligible darkf-todo children found" \
    "$status_file" "success path: status file gets the exact success summary text"

  # review-3 regression: log() output (routed to stderr) must never leak into
  # the captured SUMMARY, so the appended line must be a single clean record -
  # no embedded "[nightly-darkfactory] ..." progress transcript.
  assert_no_grep "[nightly-darkfactory] scanning project" "$status_file" \
    "success path: progress log lines must not leak into the status file"

  pass "fm-nightly-darkfactory: secondmate success path writes exactly one clean correlated done line"
}

# ---------------------------------------------------------------------------
# Failure path: fm-darkf-intake.sh fails with an unexpected exit code, driving
# run_darkfactory_pipeline's `return 1`. Exercises review-2 (assignment must
# not abort under set -eu) and review-5 (must not claim "complete").
# ---------------------------------------------------------------------------

test_failure_writes_failed_correlated_done_line() {
  local fakeroot home task_id out rc status_file repo_dir

  fakeroot=$(make_fake_root fakeroot-failure)
  read -r home task_id < <(make_secondmate_home home-failure "$CORR")
  printf -- '- myrepo [github]\n' > "$home/data/projects.md"
  status_file="$home/state/$task_id.status"

  # A cloned project repo with a parseable GitHub origin.
  repo_dir="$fakeroot/projects/myrepo"
  fm_git_init_commit "$repo_dir"
  git -C "$repo_dir" remote add origin "git@github.com:owner/myrepo.git"

  # Fake gh-axi: one open darkf-epic with one sub-issue.
  rm -f "$fakeroot/bin/gh-axi"
  cat > "$fakeroot/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "issue list -R owner/myrepo --state open --label darkf-epic --limit 50")
    printf '10,epic\n' ;;
  "issue subissue list 10 -R owner/myrepo")
    printf '11,child\n' ;;
  *) echo "fake gh-axi: unhandled: $*" >&2; exit 9 ;;
esac
SH
  chmod +x "$fakeroot/bin/gh-axi"

  # Fake fm-darkf-intake.sh: fails with an exit code that is neither the
  # "assignee gate stop" (5) nor the "soft failure, keep going" (1) case, so
  # run_darkfactory_pipeline takes its `return 1` path.
  rm -f "$fakeroot/bin/fm-darkf-intake.sh"
  cat > "$fakeroot/bin/fm-darkf-intake.sh" <<'SH'
#!/usr/bin/env bash
echo "simulated intake crash" >&2
exit 9
SH
  chmod +x "$fakeroot/bin/fm-darkf-intake.sh"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$fakeroot" PATH="$fakeroot/bin:$PATH" "$SCRIPT" 2>/dev/null)
  rc=$?

  expect_code 1 "$rc" "failure path: script must exit non-zero when the pipeline fails"
  assert_grep "done [corr=$CORR]" "$status_file" \
    "failure path: status file gets a done line carrying the correlation id"
  assert_grep "nightly darkfactory failed (exit 1)" "$status_file" \
    "failure path: status file gets the failed-exit summary text"
  assert_no_grep "nightly darkfactory complete" "$status_file" \
    "failure path: must never claim completion when the pipeline actually failed"

  pass "fm-nightly-darkfactory: secondmate failure path writes a failed (not misleading complete) correlated done line"
}

# ---------------------------------------------------------------------------
# Missing task id: no state/*.meta carries kind=secondmate. Exercises
# review-4: the diagnostic must actually print (not be skipped by an
# unguarded `set -e` abort) and the script must exit 1 cleanly.
# ---------------------------------------------------------------------------

test_missing_task_id_prints_diagnostic_and_exits_1() {
  local fakeroot home out rc
  fakeroot=$(make_fake_root fakeroot-notask)
  home="$TMP/home-notask"
  mkdir -p "$home/state" "$home/data"
  : > "$home/.fm-secondmate-home"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$fakeroot" "$SCRIPT" 2>&1)
  rc=$?

  expect_code 1 "$rc" "missing task id: script must exit 1, not crash with a bash 'local' error"
  assert_contains "$out" "error: no secondmate task id found" \
    "missing task id: the friendly diagnostic must actually print"
  assert_not_contains "$out" "can only be used in a function" \
    "missing task id: must never surface bash's 'local: can only be used in a function' error"

  pass "fm-nightly-darkfactory: missing secondmate task id prints its diagnostic and exits 1 cleanly"
}

test_success_writes_clean_correlated_done_line
test_failure_writes_failed_correlated_done_line
test_missing_task_id_prints_diagnostic_and_exits_1

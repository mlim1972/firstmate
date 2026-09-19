#!/usr/bin/env bash
# Behavior test for the review-round-1 regression in fm-darkf-phase-promote.sh:
# the completed phase's darkf-done label was being applied via
# `gh issue edit "$COMPLETED_PHASE" ...`, where $COMPLETED_PHASE is the phase
# NUMBER (e.g. "1"), not the completed phase's actual GitHub issue number. The
# fix resolves that issue number via a GraphQL sub-issue lookup by phase
# label, the same way $NEXT_ISSUE is already resolved. This test drives the
# full promote path against a fake `gh` and asserts the darkf-done label
# lands on the resolved issue number, never on the raw phase number.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-darkf-phase-promote.sh"

TMP=$(fm_test_tmproot fm-darkf-phase-promote)

make_promote_home() {  # <name> -> echoes FM_HOME to use
  local dir="$TMP/$1"
  mkdir -p "$dir/config" "$dir/fakebin"
  printf 'AUTO_ADVANCE_PHASES=true\n' > "$dir/config/darkf-schedule"

  # Fake `gh`: epic #100 has sub-issue #7 labeled phase:1 (the just-completed
  # phase) and sub-issue #8 labeled phase:2 (the next phase to promote). The
  # completed phase's raw NUMBER (1) never matches either real issue number,
  # so any call misusing it as an issue id is easy to catch.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FAKE_GH_LOG:?}"
{
  printf 'gh'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

case "$1 $2" in
  "api graphql")
    args="$*"
    if printf '%s' "$args" | grep -q 'phase:2'; then
      echo 8
    elif printf '%s' "$args" | grep -q 'phase:1'; then
      echo 7
    fi
    exit 0
    ;;
  "issue view")
    printf '{"labels":[],"state":"OPEN"}\n'
    exit 0
    ;;
  "issue edit")
    exit 0
    ;;
esac
echo "fake gh: unhandled: $*" >&2
exit 9
SH
  chmod +x "$dir/fakebin/gh"

  printf '%s\n' "$dir"
}

test_promote_labels_resolved_completed_issue_not_raw_phase_number() {
  local home log out rc calls
  home=$(make_promote_home promote-ok)
  log="$TMP/gh.log"
  : > "$log"

  out=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FAKE_GH_LOG="$log" \
    PATH="$home/fakebin:$PATH" \
    "$PROMOTE" owner/myrepo 100 1 2>&1 )
  rc=$?

  expect_code 0 "$rc" "phase-promote: full success path must exit 0"
  assert_contains "$out" "Promoted: Phase 2 (issue #8) now labeled darkf-todo" \
    "phase-promote: reports the next phase promoted"

  calls=$(cat "$log")
  assert_contains "$calls" $'gh\x1f''issue'$'\x1f''edit'$'\x1f''7'$'\x1f''--repo'$'\x1f''owner/myrepo'$'\x1f''--add-label'$'\x1f''darkf-done'$'\x1f''--remove-label'$'\x1f''darkf-todo' \
    "phase-promote: darkf-done must land on the resolved completed-phase issue (#7), not the raw phase number (1)"
  assert_not_contains "$calls" $'gh\x1f''issue'$'\x1f''edit'$'\x1f''1'$'\x1f''--repo' \
    "phase-promote: must never call gh issue edit using the raw phase number as an issue id"

  pass "fm-darkf-phase-promote: darkf-done label targets the GraphQL-resolved completed-phase issue, not the raw phase number"
}

test_promote_labels_resolved_completed_issue_not_raw_phase_number

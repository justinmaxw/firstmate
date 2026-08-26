#!/usr/bin/env bash
# AC-7 of the captain-approved Gemini (Antigravity) pool spec declares its
# mapped test at this exact path
# (tests/fm-busy-lib.test.sh::test_agy_unverified_source_classifies_unknown,
# "existing file, new case"). The real, single existing test file for
# bin/fm-busy-lib.sh's general contract is tests/fm-busy-state.test.sh (see its
# own header) - this file's name is a clerical mismatch in the spec, not a
# deliberate second owner. Rather than editing the spec (off-limits to this
# task) or duplicating that file's coverage, this file exists narrowly to
# satisfy the spec's literal declared path with exactly the one new agy case;
# a future harness-unverified-gate case should land in fm-busy-state.test.sh
# instead now that this narrow file exists only for this one mapping.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-lib)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# AC-7: agy has no live-verified, trusted busy-state record - bin/fm-busy-lib.sh
# registers no per-harness source for it at all (unlike kimi's dedicated
# verification gate, agy is not in fm_busy_sources_for_harness's case
# statement, so it falls to the empty catch-all and trusts nothing). When
# fm_busy_classify runs for an agy task it must report unknown, never idle, in
# every shape: no record at all, and a record some other adapter's writer
# left behind (source-mismatch).
test_agy_unverified_source_classifies_unknown() {
  local state gen out
  state=$(new_state_dir agy-gate)

  out=$(fm_busy_classify tmux w1 agy t1 "$state")
  [ "$out" = "unknown missing" ] || fail "an agy task with no record must classify unknown, got '$out'"

  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  "$EV" apply "$state" t1 busy --gen "$gen" --source fm-spawn --event launch-brief
  out=$(fm_busy_classify tmux w1 agy t1 "$state")
  [ "$out" = "unknown source-mismatch" ] \
    || fail "agy must trust no semantic source, including fm-spawn's own seed, got '$out'"

  out=$(fm_busy_classify tmux w1 agy t1 "$state" 'esc to cancel')
  [ "$out" = "unknown source-mismatch" ] \
    || fail "agy must not classify from its own rendered busy footer, got '$out'"

  [ -z "$(fm_busy_sources_for_harness agy)" ] \
    || fail "agy must trust no busy record source until one is live-verified"

  pass "agy classifies unknown - never idle - with no record, an untrusted record, and its own rendered footer"
}

test_agy_unverified_source_classifies_unknown

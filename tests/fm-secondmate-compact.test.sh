#!/usr/bin/env bash
# Portable regression for bin/fm-secondmate-compact.sh.
#
# Drives the real script through its public CLI with a fake tmux endpoint and a
# fake send command, and pins the two properties that make the sequence safe:
# every refusal over an unsafe target happens BEFORE anything reaches the agent,
# and neither the stow nor the compaction is ever reported as done without its
# own positive evidence. A refusal that can only happen after the stow landed
# says so, and a confirmed compaction whose follow-up failed has its own code.
#
# Each "did not send" assertion reads the send log, so a check that passes
# because nothing ran at all would still fail its ordering assertion.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUT="$ROOT/bin/fm-secondmate-compact.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-compact)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export PATH="$FAKEBIN:$PATH"

# A tmux stand-in whose display-message answers for any target listed in
# FM_FAKE_LIVE_TARGETS and fails for everything else, so endpoint liveness is a
# per-case fixture rather than a global assumption.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = display-message ]; then
  for arg in "$@"; do
    case " ${FM_FAKE_LIVE_TARGETS:-} " in
      *" $arg "*) printf 'pane0\n'; exit 0 ;;
    esac
  done
  exit 1
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux"

# The fake send command. It records every delivery, and emulates exactly the
# parts of bin/fm-send.sh this script depends on: a marked secondmate request
# commits its pending-reply delivery, and the agent's scripted reactions are
# driven by per-case env vars rather than by timing.
#
#   FM_FAKE_SEND_LOG        appended "<target>\t<text>" per delivery
#   FM_FAKE_STOW_REPLY      1 = append a correlated line to the parent status
#   FM_FAKE_STOW_TRANSCRIPT 1 = the stow turn appends to the transcript
#   FM_FAKE_COMPACT_RESULT  new | old | none - what the /compact turn records
#   FM_FAKE_SEND_FAIL       substring of a message this send must refuse
#   FM_FAKE_BUSY_AFTER_STOW stuck = stay busy after reporting; settles = go busy
#                           and then idle again, the real shape where the agent
#                           appends its status line mid-turn
cat > "$FAKEBIN/fake-send" <<'SH'
#!/usr/bin/env bash
set -u
target=$1
shift
text=$*
printf '%s\t%s\n' "$target" "$text" >> "$FM_FAKE_SEND_LOG"

if [ -n "${FM_FAKE_SEND_FAIL:-}" ]; then
  case "$text" in
    *"$FM_FAKE_SEND_FAIL"*) echo "fake-send: refused" >&2; exit 1 ;;
  esac
fi

. "$FM_FAKE_ROOT/bin/fm-pending-reply-lib.sh"

case "$text" in
  *"stow sweep"*)
    corr=${FM_PENDING_REPLY_EXISTING_CORR:-}
    [ -n "$corr" ] || { echo "fake-send: marked request carried no corr" >&2; exit 1; }
    fm_pending_reply_confirm_delivery "$FM_FAKE_STATE" "$corr" || exit 1
    if [ "${FM_FAKE_STOW_TRANSCRIPT:-0}" = 1 ]; then
      printf '{"type":"user","cwd":"%s","timestamp":"%s"}\n' \
        "$FM_FAKE_CWD" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$FM_FAKE_TRANSCRIPT"
    fi
    if [ "${FM_FAKE_STOW_REPLY:-0}" = 1 ]; then
      printf 'working: stow complete corr=%s\n' "$corr" >> "$FM_FAKE_STATUS"
    fi
    case "${FM_FAKE_BUSY_AFTER_STOW:-}" in
      stuck)
        "$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply "$FM_FAKE_STATE" "$FM_FAKE_ID" busy \
          --current-gen --source claude-hook --event user-prompt-submit
        ;;
      settles)
        "$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply "$FM_FAKE_STATE" "$FM_FAKE_ID" busy \
          --current-gen --source claude-hook --event user-prompt-submit
        ( sleep 2
          "$FM_FAKE_ROOT/bin/fm-busy-event.sh" apply "$FM_FAKE_STATE" "$FM_FAKE_ID" idle \
            --current-gen --source claude-hook --event stop
        ) >/dev/null 2>&1 &
        ;;
    esac
    ;;
  /compact)
    case "${FM_FAKE_COMPACT_RESULT:-none}" in
      new) ts=$(date -u -v+1M +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%S.000Z) ;;
      old) ts=2020-01-01T00:00:00.000Z ;;
      # A record written moments BEFORE the send, in the same wall-clock second
      # the second-truncated send timestamp records. Freshness alone cannot
      # rule this out.
      presend) ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z) ;;
      *) ts= ;;
    esac
    if [ -n "$ts" ]; then
      printf '{"type":"user","isCompactSummary":true,"cwd":"%s","timestamp":"%s"}\n' \
        "$FM_FAKE_CWD" "$ts" >> "$FM_FAKE_TRANSCRIPT"
    fi
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/fake-send"

CASE_N=0

# new_case <name> - build a fresh, fully valid fixture and export everything the
# script and the fake send need. Individual cases then break exactly one thing.
new_case() {
  CASE_N=$((CASE_N + 1))
  CASE="$TMP_ROOT/case$CASE_N"
  ID=sm$CASE_N
  SENDER="$CASE/sender"
  SECOND="$CASE/second"
  CLAUDE_DIR="$CASE/claude"
  mkdir -p "$SENDER/state" "$SENDER/data" "$SECOND/state" "$CLAUDE_DIR/projects"

  SECOND_REAL=$(cd "$SECOND" && pwd -P)
  SLUG=$(printf '%s' "$SECOND_REAL" | sed 's/[^A-Za-z0-9]/-/g')
  TDIR="$CLAUDE_DIR/projects/$SLUG"
  mkdir -p "$TDIR"
  TRANSCRIPT="$TDIR/session.jsonl"
  printf '{"type":"user","cwd":"%s","timestamp":"2026-01-01T00:00:00.000Z"}\n' "$SECOND_REAL" > "$TRANSCRIPT"

  META="$SENDER/state/$ID.meta"
  fm_write_secondmate_meta "$META" "$SECOND_REAL" "firstmate:fm-$ID" '' claude
  printf -- '- %s - lab route (home: %s; scope: nothing; projects: ; added 2026-01-01)\n' \
    "$ID" "$SECOND_REAL" > "$SENDER/data/secondmates.md"

  SEND_LOG="$CASE/sent.log"
  : > "$SEND_LOG"

  export FM_HOME="$SENDER"
  export CLAUDE_CONFIG_DIR="$CLAUDE_DIR"
  export FM_FAKE_LIVE_TARGETS="firstmate:fm-$ID"
  export FM_FAKE_SEND_LOG="$SEND_LOG"
  export FM_FAKE_ROOT="$ROOT"
  export FM_FAKE_STATE="$SENDER/state"
  export FM_FAKE_ID="$ID"
  export FM_FAKE_STATUS="$SENDER/state/$ID.status"
  export FM_FAKE_TRANSCRIPT="$TRANSCRIPT"
  export FM_FAKE_CWD="$SECOND_REAL"
  export FM_SECONDMATE_COMPACT_SEND="$FAKEBIN/fake-send"
  export FM_FAKE_STOW_REPLY=1
  export FM_FAKE_STOW_TRANSCRIPT=1
  export FM_FAKE_COMPACT_RESULT=new
  unset FM_FAKE_SEND_FAIL
  unset FM_FAKE_BUSY_AFTER_STOW
}

run_sut() {
  RC=0
  OUT=$("$SUT" "$ID" --poll-seconds 1 --stow-timeout 3 --compact-timeout 3 2>&1) || RC=$?
}

sent_count() { wc -l < "$SEND_LOG" | tr -d ' '; }
sent_nth() { sed -n "${1}p" "$SEND_LOG"; }

assert_nothing_sent() {  # <msg>
  [ "$(sent_count)" = 0 ] || fail "$1 (send log is not empty)"$'\n'"$(cat "$SEND_LOG")"
}

# --- usage -------------------------------------------------------------------

RC=0
OUT=$("$SUT" --help 2>&1) || RC=$?
expect_code 0 "$RC" "--help"
assert_contains "$OUT" 'Stow, then compact' "--help prints the header"

RC=0
OUT=$("$SUT" 2>&1) || RC=$?
expect_code 2 "$RC" "no id"

new_case
RC=0
OUT=$("$SUT" "$ID" extra 2>&1) || RC=$?
expect_code 2 "$RC" "two ids"
pass "usage errors are refused with exit 2"

# --- refusals, none of which may reach the agent -----------------------------

new_case
rm -f "$META"
run_sut
expect_code 1 "$RC" "unknown id"
assert_contains "$OUT" 'no metadata' "unknown id names the missing record"
assert_nothing_sent "unknown id"

new_case
fm_write_meta "$META" "window=firstmate:fm-$ID" "harness=claude" "kind=ship" "worktree=$SECOND_REAL"
run_sut
expect_code 1 "$RC" "kind=ship"
assert_contains "$OUT" 'not a persistent secondmate' "a crewmate is refused by kind"
assert_nothing_sent "kind=ship"

new_case
: > "$SENDER/data/secondmates.md"
run_sut
expect_code 1 "$RC" "unregistered"
assert_contains "$OUT" 'not a single unambiguous route' "an unregistered secondmate is refused"
assert_nothing_sent "unregistered"

new_case
printf 'remote_host=box\n' >> "$META"
run_sut
expect_code 1 "$RC" "remote route"
assert_contains "$OUT" 'remote secondmate route' "a remote route is refused"
assert_nothing_sent "remote route"

new_case
fm_write_secondmate_meta "$META" "$SECOND_REAL" "firstmate:fm-$ID" '' codex
run_sut
expect_code 1 "$RC" "unverified harness"
assert_contains "$OUT" "harness 'codex' has no verified compaction command" "an unverified harness is named"
assert_contains "$OUT" 'refusing to guess' "an unverified harness is not guessed at"
assert_nothing_sent "unverified harness"

new_case
export FM_FAKE_LIVE_TARGETS=''
run_sut
expect_code 1 "$RC" "dead endpoint"
assert_contains "$OUT" 'no live endpoint' "a dead endpoint is refused"
assert_nothing_sent "dead endpoint"

new_case
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$SENDER/state" "$ID")
"$ROOT/bin/fm-busy-event.sh" apply "$SENDER/state" "$ID" busy --gen "$GEN" \
  --source claude-hook --event user-prompt-submit
run_sut
expect_code 1 "$RC" "busy target"
assert_contains "$OUT" 'is mid-turn' "a busy secondmate is refused"
assert_nothing_sent "busy target"

new_case
fm_write_meta "$SECOND/state/childtask.meta" "window=firstmate:fm-childtask" "kind=ship"
run_sut
expect_code 1 "$RC" "live crew in the home"
assert_contains "$OUT" 'still has recorded work' "recorded crew work blocks compaction"
assert_contains "$OUT" 'childtask' "the blocking work is named"
assert_nothing_sent "live crew in the home"

new_case
OPEN_CORR=$(FM_HOME="$SENDER" bash -c '. "$1"; fm_pending_reply_create "$2" "$3" "$4" "earlier question"' \
  _ "$ROOT/bin/fm-pending-reply-lib.sh" "$SENDER" "$SENDER/state" "$ID")
[ -n "$OPEN_CORR" ] || fail "fixture could not open a pending reply"
run_sut
expect_code 1 "$RC" "open pending reply"
assert_contains "$OUT" 'still owes an answer' "an unanswered request blocks compaction"
assert_nothing_sent "open pending reply"

new_case
rm -rf "$TDIR"
run_sut
expect_code 1 "$RC" "no transcript dir"
assert_contains "$OUT" 'no Claude session transcript directory' "an unlocatable transcript refuses"
assert_nothing_sent "no transcript dir"

new_case
rm -f "$TRANSCRIPT"
run_sut
expect_code 1 "$RC" "empty transcript dir"
assert_contains "$OUT" 'holds no session transcript' "an empty transcript dir refuses"
assert_nothing_sent "empty transcript dir"
pass "every unsafe target is refused before anything reaches the agent"

# --- the stow must be confirmed before the compaction command is sent --------

new_case
export FM_FAKE_STOW_REPLY=0
run_sut
expect_code 3 "$RC" "unconfirmed stow"
assert_contains "$OUT" 'did not report its stow' "an unconfirmed stow is named"
[ "$(sent_count)" = 1 ] || fail "unconfirmed stow sent more than the stow request"$'\n'"$(cat "$SEND_LOG")"
assert_contains "$(sent_nth 1)" 'stow sweep' "the one delivery was the stow request"
pass "an unreported stow stops the sequence with no compaction command sent"

new_case
export FM_FAKE_SEND_FAIL='stow sweep'
run_sut
expect_code 1 "$RC" "undelivered stow"
assert_contains "$OUT" 'was not delivered' "a failed stow delivery is named"
[ "$(sent_count)" = 1 ] || fail "a failed stow delivery still sent something else"
pass "a failed stow delivery stops the sequence"

# The stow turn completing without touching the transcript proves the
# confirmation channel is dead, so the compaction is refused rather than sent
# into a silence that would look identical to a failed compaction.
new_case
export FM_FAKE_STOW_TRANSCRIPT=0
run_sut
expect_code 1 "$RC" "dead confirmation channel"
assert_contains "$OUT" 'not recording transcripts' "a silent transcript refuses the compaction"
[ "$(sent_count)" = 1 ] || fail "a dead confirmation channel still sent the compaction command"$'\n'"$(cat "$SEND_LOG")"
pass "a session that is not writing transcripts never receives a compaction command"

# --- the stow turn must be allowed to finish, but not to run forever ---------

# The real shape: the agent appends its correlated status line partway through
# the turn and keeps working. That must not be read as "still busy, refuse".
new_case
# arm seeds a busy/fm-spawn launch turn, so settle it first: this case is about
# what happens AFTER the stow report, not at intake.
"$ROOT/bin/fm-busy-event.sh" arm "$SENDER/state" "$ID" >/dev/null
"$ROOT/bin/fm-busy-event.sh" apply "$SENDER/state" "$ID" idle \
  --current-gen --source claude-hook --event stop
export FM_FAKE_BUSY_AFTER_STOW=settles
run_sut
expect_code 0 "$RC" "busy-then-idle stow turn"$'\n'"$OUT"
[ "$(sent_count)" = 3 ] || fail "busy-then-idle case did not complete the sequence"$'\n'"$(cat "$SEND_LOG")"
pass "a stow turn that reports partway through is waited out, not refused"

new_case
"$ROOT/bin/fm-busy-event.sh" arm "$SENDER/state" "$ID" >/dev/null
"$ROOT/bin/fm-busy-event.sh" apply "$SENDER/state" "$ID" idle \
  --current-gen --source claude-hook --event stop
export FM_FAKE_BUSY_AFTER_STOW=stuck
run_sut
expect_code 1 "$RC" "stow turn that never ends"
assert_contains "$OUT" 'still mid-turn' "an agent that never settles is refused"
[ "$(sent_count)" = 1 ] || fail "a never-settling agent still received the compaction command"$'\n'"$(cat "$SEND_LOG")"
pass "an agent still working after its stow report never receives the compaction command"

# --- the compaction itself must be confirmed ---------------------------------

new_case
export FM_FAKE_COMPACT_RESULT=none
run_sut
expect_code 4 "$RC" "unconfirmed compaction"
assert_contains "$OUT" 'no compaction was recorded' "an unconfirmed compaction is named"
[ "$(sent_count)" = 2 ] || fail "unconfirmed compaction did not send exactly stow + /compact"$'\n'"$(cat "$SEND_LOG")"
assert_contains "$(sent_nth 2)" '/compact' "the compaction command was really sent"
pass "a compaction that leaves no record is reported as unconfirmed, not as success"

# Negative control for the freshness gate: a compaction record that predates the
# send must not be accepted. Without the timestamp comparison this case would
# pass as success.
new_case
export FM_FAKE_COMPACT_RESULT=old
run_sut
expect_code 4 "$RC" "stale compaction record"
[ "$(sent_count)" = 2 ] || fail "stale-record case did not send exactly stow + /compact"
pass "a compaction record older than the send never counts as confirmation"

# A compaction record that already existed before the command was sent must
# never confirm it, even when its own timestamp falls inside the same second the
# send timestamp truncates to. Written into the transcript BEFORE the run, so
# only the pre-send comparison can reject it.
new_case
export FM_FAKE_COMPACT_RESULT=none
printf '{"type":"user","isCompactSummary":true,"cwd":"%s","timestamp":"%s"}\n' \
  "$SECOND_REAL" "$(date -u -v+1M +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%S.000Z)" \
  >> "$TRANSCRIPT"
run_sut
expect_code 4 "$RC" "a compaction record that predates the send"
assert_contains "$OUT" 'no compaction was recorded' "a pre-existing record is not confirmation"
[ "$(sent_count)" = 2 ] || fail "the pre-existing-record case did not send exactly stow + /compact"
pass "a compaction record that already existed before the send never confirms the new one"

# --- happy path --------------------------------------------------------------

new_case
run_sut
expect_code 0 "$RC" "happy path"$'\n'"$OUT"
assert_contains "$OUT" 'compaction confirmed' "success names the confirmation"
[ "$(sent_count)" = 3 ] || fail "happy path did not send stow + /compact + re-orientation"$'\n'"$(cat "$SEND_LOG")"
assert_contains "$(sent_nth 1)" 'stow sweep' "delivery 1 is the stow request"
assert_contains "$(sent_nth 1)" "$ID"$'\t' "the stow request goes to the task id so it is marked"
assert_contains "$(sent_nth 2)" "firstmate:fm-$ID"$'\t/compact' "delivery 2 is an unmarked /compact to the endpoint"
assert_contains "$(sent_nth 3)" 'Re-read this home' "delivery 3 re-orients the compacted agent"
assert_contains "$(sent_nth 3)" "firstmate:fm-$ID"$'\t' "the re-orientation is unmarked too"
pass "the confirmed sequence is stow, compact, re-orient, in that order"

# --- a compacted-and-then-failed follow-up is still reported ------------------

new_case
export FM_FAKE_SEND_FAIL='Re-read this home'
run_sut
expect_code 5 "$RC" "re-orientation failure"
assert_contains "$OUT" 'was not delivered' "a failed re-orientation is reported"
assert_contains "$OUT" 'compacted at' "a failed re-orientation still reports the compaction"
assert_contains "$OUT" 'the compaction is confirmed' "the operator is told the context really was compacted"
pass "a failed re-orientation after a real compaction gets its own exit code, not the pre-send refusal code"

# The refusals that happen AFTER the stow request landed keep exit 1, but must
# not read as "nothing reached the agent": each one says what did land.
new_case
export FM_FAKE_STOW_TRANSCRIPT=0
run_sut
expect_code 1 "$RC" "post-stow refusal on a dead confirmation channel"
assert_contains "$OUT" 'The stow already landed and nothing was compacted' "a post-stow refusal states what landed"

new_case
"$ROOT/bin/fm-busy-event.sh" arm "$SENDER/state" "$ID" >/dev/null
"$ROOT/bin/fm-busy-event.sh" apply "$SENDER/state" "$ID" idle \
  --current-gen --source claude-hook --event stop
export FM_FAKE_BUSY_AFTER_STOW=stuck
run_sut
expect_code 1 "$RC" "post-stow refusal on an agent that never settles"
assert_contains "$OUT" 'the stow already landed; nothing was compacted' "an unsettled agent's refusal states what landed"
pass "every post-stow exit 1 names what already reached the agent"

#!/usr/bin/env bash
# Behavior tests for bin/fm-night-check.sh - the overnight queue-running night
# check and night ledger.
#
# The property that matters most here is EDGE-TRIGGERING. A level-triggered
# backlog check reproduces the 2026-07-29 incident recorded in
# data/learnings.md, where a stable fleet state burned roughly one turn per
# iteration all night against an explicit instruction to conserve quota. These
# cases pin that property directly, plus the two independent limits that bound a
# night even when the signature legitimately keeps moving:
#   (a) an unchanged (ready-set, running-count) signature is silent on repeat
#   (b) a changed ready set prints exactly one line
#   (c) a changed running count prints exactly one line
#   (d) the fleet at its concurrency cap is silent
#   (e) the dispatch budget silences the check at zero regardless of the queue
#   (f) two failed dispatches in a row stop dispatching; a landing resets the run
#   (g) the generated check satisfies the AGENTS.md section 7 check contract:
#       an ordinary single-link mode-0700 file that registers cleanly, runs
#       through the watcher's own hash-validated snapshot path, and finishes
#       inside FM_CHECK_TIMEOUT
#   (h) an unarmed home is silent and refuses accounting
#   (i) the ledger reports dispatched, landed, parked with the reason, and
#       failed work plus the bedtime-versus-wake quota delta
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-check-lib.sh"

NIGHT="$ROOT/bin/fm-night-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-night-check)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A throwaway home with a real backlog, a fake tmux whose exit code decides
# whether a recorded endpoint reads alive, and a fake quota-axi so the bedtime
# and wake readings are deterministic.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  # Endpoint liveness is decided by this file's exit code, flipped per case.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  set_quota "$home" 10
  printf '%s\n' "$home"
}

# A fake quota-axi reporting one provider window at <percent> used.
set_quota() {  # <home> <percent>
  local home=$1 percent=$2
  cat > "$home/fakebin/quota-axi" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = --json ] || exit 1
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","percentUsed":$percent}]}]}
JSON
EOF
  chmod +x "$home/fakebin/quota-axi"
}

set_endpoints_alive() {  # <home> <0|1>
  local home=$1 alive=$2 code=1
  [ "$alive" = 0 ] || code=0
  printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
}

night() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$NIGHT" "$@"
}

queue() {  # <home> <id>...
  local home=$1 id
  shift
  for id in "$@"; do
    (cd "$home" && tasks-axi add "$id" "Item $id" --kind ship --repo demo >/dev/null) || return 1
  done
}

running_task() {  # <home> <id>
  local home=$1 id=$2
  printf 'window=firstmate:fm-%s\nkind=ship\nbackend=tmux\nendpoint_task_id=%s\n' "$id" "$id" \
    > "$home/state/$id.meta"
}

# --- (a) edge-triggering: an unchanged signature is silent on repeat ---------

HOME_A=$(make_home edge)
queue "$HOME_A" alpha beta
night "$HOME_A" arm --budget 5 --cap 3 >/dev/null || fail "arm failed"

first=$(night "$HOME_A" poll)
assert_contains "$first" "night: 2 ready, 0 running, 5 dispatches left" \
  "first poll on a fresh ready queue announces the queue"

for attempt in 1 2 3; do
  repeat=$(night "$HOME_A" poll)
  [ -z "$repeat" ] || fail "poll $attempt re-fired on an unchanged signature: $repeat"
done
pass "an unchanged ready-set and running-count signature stays silent on repeated polls"

# --- (b) a changed ready set prints exactly one line -------------------------

queue "$HOME_A" gamma
changed=$(night "$HOME_A" poll)
assert_contains "$changed" "night: 3 ready, 0 running" "a new ready item re-fires the check"
[ "$(printf '%s\n' "$changed" | grep -c .)" = 1 ] || fail "poll printed more than one line: $changed"
silent=$(night "$HOME_A" poll)
[ -z "$silent" ] || fail "poll re-fired after the changed signature was surfaced: $silent"
pass "a changed ready set prints exactly one line, then goes quiet again"

# --- (c) a changed running count re-fires ------------------------------------

running_task "$HOME_A" alpha
moved=$(night "$HOME_A" poll)
assert_contains "$moved" "night: 3 ready, 1 running" "a changed running count re-fires the check"
[ -z "$(night "$HOME_A" poll)" ] || fail "poll re-fired on an unchanged running count"
pass "a changed running count re-fires exactly once"

# A dead endpoint does not occupy capacity, and that is itself a signature move.
set_endpoints_alive "$HOME_A" 0
reopened=$(night "$HOME_A" poll)
assert_contains "$reopened" "night: 3 ready, 0 running" "a dead endpoint frees capacity"
set_endpoints_alive "$HOME_A" 1

# --- (d) the fleet at its concurrency cap is silent ---------------------------

HOME_CAP=$(make_home cap)
queue "$HOME_CAP" alpha beta
night "$HOME_CAP" arm --budget 5 --cap 2 >/dev/null || fail "arm failed"
running_task "$HOME_CAP" one
running_task "$HOME_CAP" two
[ -z "$(night "$HOME_CAP" poll)" ] || fail "poll fired with the fleet at its cap"
pass "a fleet at its concurrency cap keeps the check silent"

rm -f "$HOME_CAP/state/two.meta"
assert_contains "$(night "$HOME_CAP" poll)" "night: 2 ready, 1 running" \
  "capacity opening up re-fires the check"

# --- (e) the dispatch budget silences the check at zero ----------------------

HOME_B=$(make_home budget)
queue "$HOME_B" alpha beta gamma
night "$HOME_B" arm --budget 2 --cap 5 >/dev/null || fail "arm failed"
assert_contains "$(night "$HOME_B" poll)" "night: 3 ready, 0 running, 2 dispatches left" \
  "budget is reported before it is spent"

dispatch() {  # <home> <id>
  (cd "$1" && tasks-axi start "$2" >/dev/null) || return 1
  night "$1" record dispatched "$2" >/dev/null
}

dispatch "$HOME_B" alpha || fail "dispatch failed"
assert_contains "$(night "$HOME_B" poll)" "night: 2 ready, 0 running, 1 dispatches left" \
  "a spent dispatch is reflected"
dispatch "$HOME_B" beta || fail "dispatch failed"
assert_contains "$(night "$HOME_B" status)" "dispatches_left=0" "the budget is exhausted"

# The queue still has ready work and the fleet is empty, so only the budget can
# be keeping the check quiet. The ready set also keeps moving, which proves the
# budget gate is independent of the edge-trigger suppression.
queue "$HOME_B" delta epsilon
for attempt in 1 2 3; do
  [ -z "$(night "$HOME_B" poll)" ] || fail "poll fired at zero budget on attempt $attempt"
  queue "$HOME_B" "extra$attempt"
done
pass "an exhausted dispatch budget silences the check regardless of queue state"

# --- (f) two consecutive failed dispatches stop the night --------------------

HOME_C=$(make_home failures)
queue "$HOME_C" alpha beta gamma delta
night "$HOME_C" arm --budget 20 --cap 5 >/dev/null || fail "arm failed"
night "$HOME_C" record dispatched alpha >/dev/null
night "$HOME_C" record failed alpha --reason "spawn refused" >/dev/null
assert_contains "$(night "$HOME_C" status)" "consecutive_failures=1" "one failure is recorded"
assert_contains "$(night "$HOME_C" status)" "stopped=-" "one failure does not stop the night"
[ -n "$(night "$HOME_C" poll)" ] || fail "poll went silent after a single failure"

# A landing between failures resets the run, so only genuinely consecutive
# failures can reach the stop.
night "$HOME_C" record dispatched beta >/dev/null
night "$HOME_C" record landed beta >/dev/null
assert_contains "$(night "$HOME_C" status)" "consecutive_failures=0" "a landing resets the failure run"
night "$HOME_C" record dispatched gamma >/dev/null
night "$HOME_C" record failed gamma --reason "worker reported failure" >/dev/null
assert_contains "$(night "$HOME_C" status)" "stopped=-" "a failure after a landing does not stop the night"

night "$HOME_C" record dispatched delta >/dev/null
stop_output=$(night "$HOME_C" record failed delta --reason "worker reported failure")
assert_contains "$stop_output" "dispatching stopped" "the second failure in a row reports the stop"
assert_contains "$(night "$HOME_C" status)" "stopped=2 dispatches failed in a row" \
  "the stop is durable in the night record"

queue "$HOME_C" zeta
for attempt in 1 2 3; do
  [ -z "$(night "$HOME_C" poll)" ] || fail "poll fired after the failure stop on attempt $attempt"
done
pass "two failed dispatches in a row end dispatching for the night"

# --- (g) the AGENTS.md section 7 check contract -------------------------------

HOME_D=$(make_home contract)
queue "$HOME_D" alpha
night "$HOME_D" arm --budget 5 --cap 3 >/dev/null || fail "arm failed"
CHECK="$HOME_D/state/night-run.check.sh"

[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || fail "the night check is not an ordinary file"
[ "$(fm_pr_file_mode "$CHECK")" = 700 ] || fail "the night check is not mode 0700"
[ "$(fm_pr_file_link_count "$CHECK")" = 1 ] || fail "the night check is not single-link"
fm_custom_check_registered "$HOME_D/state" night-run \
  || fail "the night check did not register cleanly through fm-check-register.sh"
pass "the generated night check is an ordinary single-link mode-0700 registered file"

# Editing the check must break its binding, so the watcher refuses to run bytes
# that were never registered.
printf '\n# tampered\n' >> "$CHECK"
fm_custom_check_registered "$HOME_D/state" night-run \
  && fail "a tampered night check still passed registration"
pass "tampering with the night check breaks its registration"
night "$HOME_D" arm --budget 5 --cap 3 >/dev/null || fail "re-arm failed"

# Run it exactly the way the watcher does: through the hash-validated snapshot,
# with `bash <snapshot>`, and inside FM_CHECK_TIMEOUT.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
fm_custom_check_snapshot_prepare "$HOME_D/state" night-run \
  || fail "the watcher could not prepare a validated snapshot of the night check"
started=$(date +%s)
snapshot_out=$(PATH="$HOME_D/fakebin:$PATH" bash "$FM_CUSTOM_CHECK_SNAPSHOT" 2>/dev/null || true)
elapsed=$(( $(date +%s) - started ))
fm_custom_check_snapshot_cleanup
assert_contains "$snapshot_out" "night: 1 ready" "the watcher's snapshot path produces the wake line"
[ "$elapsed" -lt "$CHECK_TIMEOUT" ] \
  || fail "the night check took ${elapsed}s, at or past FM_CHECK_TIMEOUT ${CHECK_TIMEOUT}s"
pass "the night check runs through the watcher's snapshot path in ${elapsed}s, inside FM_CHECK_TIMEOUT"

# An armed night must keep supervision required even with an EMPTY fleet. That
# is the whole 02:00 case: every worker has finished, the queue still has ready
# work, and a home that reads as "nothing to supervise" would end the night blind
# and never run this check at all.
rm -f "$HOME_D"/state/*.meta
( . "$ROOT/bin/fm-supervision-lib.sh"
  fm_supervision_status "$HOME_D/state"
  [ "$FM_SUP_IN_FLIGHT" = 0 ] || exit 1
  [ "$FM_SUP_NEEDED" = true ] || exit 1
) || fail "an armed night with an empty fleet did not require supervision"
pass "an armed night keeps supervision required even with an empty fleet"

# The bootstrap's non-executing legacy-check migration sweeps every
# state/*.check.sh and quarantines any it cannot account for. A registered night
# check must survive that sweep, or a night would be silently disarmed at the
# next session start.
PATH="$HOME_D/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_D" \
  FM_STATE_OVERRIDE="$HOME_D/state" "$ROOT/bin/fm-pr-check-migrate.sh" >/dev/null 2>&1 || true
assert_present "$CHECK" "the legacy-check migration quarantined the armed night check"
fm_custom_check_registered "$HOME_D/state" night-run \
  || fail "the legacy-check migration broke the night check registration"
pass "an armed night check survives the bootstrap's legacy-check migration sweep"

# Disarming leaves the record readable for the morning ledger.
night "$HOME_D" disarm >/dev/null || fail "disarm failed"
assert_absent "$CHECK" "disarm removes the night check"
assert_absent "$HOME_D/state/night-run.check-trust" "disarm removes the check binding"
night "$HOME_D" status >/dev/null || fail "the night record must survive disarm for the ledger"
pass "disarm removes the check and its binding while keeping the night record"

# --- (h) an unarmed home is silent and refuses accounting --------------------

HOME_E=$(make_home unarmed)
queue "$HOME_E" alpha
[ -z "$(night "$HOME_E" poll)" ] || fail "poll fired in a home with no armed night"
night "$HOME_E" record dispatched alpha >/dev/null 2>&1
expect_code 1 "$?" "accounting against an unarmed home"
night "$HOME_E" arm --budget 3 >/dev/null || fail "arm failed"
night "$HOME_E" record bogus alpha >/dev/null 2>&1
expect_code 1 "$?" "an unknown night event"
night "$HOME_E" record dispatched 'not a slug' >/dev/null 2>&1
expect_code 1 "$?" "an unsafe task id"
pass "an unarmed home stays silent and refuses night accounting"

# --- (j) away-mode parking closes the loop -----------------------------------
#
# The night must not stall on one question firstmate has no authority to answer.
# Parking is composed entirely from machinery that already exists: a structured
# captain hold drops the origin out of `tasks-axi ready` on its own, so the
# selector needs no new logic and the next item stays reachable.

HOME_G=$(make_home parking)
queue "$HOME_G" alpha beta
night "$HOME_G" arm --budget 5 --cap 3 >/dev/null || fail "arm failed"
assert_contains "$(night "$HOME_G" poll)" "night: 2 ready" "both items start out ready"

# alpha's worker raised a decision only the captain can answer. Parking it is a
# structured captain hold plus the dependency edge that keeps alpha out of the
# selector until the captain answers, which is the same edge `fm-decision-hold.sh
# resolve` clears in the morning.
printf 'window=firstmate:fm-alpha\nkind=ship\nbackend=tmux\nproject=demo\n' > "$HOME_G/state/alpha.meta"
hold_id=$(PATH="$HOME_G/fakebin:$PATH" FM_HOME="$HOME_G" FM_STATE_OVERRIDE="$HOME_G/state" \
  FM_DATA_OVERRIDE="$HOME_G/data" "$ROOT/bin/fm-decision-hold.sh" hold alpha retry-policy \
  --title "Which retry policy should the wrapper use" \
  --reason "product choice the captain has not made") \
  || { echo "skip: tasks-axi does not expose the captain-hold contract"; exit 0; }
(cd "$HOME_G" && tasks-axi block alpha --by "$hold_id" >/dev/null) || fail "could not park alpha"
night "$HOME_G" record parked alpha --reason "product choice the captain has not made" >/dev/null \
  || fail "record parked failed"

assert_contains "$( (cd "$HOME_G" && tasks-axi ready --include-held) )" "$hold_id" \
  "the captain hold is not present as held work"

still_ready=$( (cd "$HOME_G" && tasks-axi ready) )
assert_not_contains "$still_ready" "alpha," "the parked item did not leave the ready queue"
assert_contains "$still_ready" "beta," "the next ready item is no longer reachable"
pass "a parked decision leaves the ready queue while the next item stays reachable"

# The fleet is empty again and beta is still queued, so the night continues.
rm -f "$HOME_G/state/alpha.meta"
assert_contains "$(night "$HOME_G" poll)" "night: 1 ready, 0 running" \
  "the night did not continue to the next ready item after parking"
assert_contains "$(night "$HOME_G" ledger)" \
  "Parked for the captain: 1 - alpha (product choice the captain has not made)" \
  "the parked decision is not carried into the morning ledger"
pass "the night continues to the next ready item and the parked decision reaches the morning ledger"

# --- (i) the morning ledger --------------------------------------------------

HOME_F=$(make_home ledger)
queue "$HOME_F" alpha beta gamma
set_quota "$HOME_F" 10
night "$HOME_F" arm --budget 6 --cap 3 >/dev/null || fail "arm failed"
night "$HOME_F" record dispatched alpha >/dev/null
night "$HOME_F" record landed alpha >/dev/null
night "$HOME_F" record dispatched beta >/dev/null
night "$HOME_F" record parked beta --reason "product choice: which retry policy" >/dev/null
night "$HOME_F" record dispatched gamma >/dev/null
night "$HOME_F" record failed gamma --reason "worker reported failure" >/dev/null
set_quota "$HOME_F" 47
ledger=$(night "$HOME_F" ledger)

assert_contains "$ledger" "Dispatched: 3 of 6 budgeted - alpha, beta, gamma" "the ledger lists dispatched work"
assert_contains "$ledger" "Landed: 1 - alpha" "the ledger lists landed work"
assert_contains "$ledger" "Parked for the captain: 1 - beta (product choice: which retry policy)" \
  "the ledger lists parked work with its reason"
assert_contains "$ledger" "Failed: 1 - gamma (worker reported failure)" "the ledger lists failed work"
assert_contains "$ledger" "Quota at bedtime: claude/five_hour=10" "the ledger carries the bedtime reading"
assert_contains "$ledger" "Quota at wake: claude/five_hour=47" "the ledger carries the wake reading"
assert_contains "$ledger" "Quota delta: claude/five_hour +37pp" "the ledger reports the quota delta"
pass "the morning ledger reports dispatched, landed, parked, failed, and the quota delta"

# The ledger is read-only: bearings composes the morning report from it.
before=$(cat "$HOME_F/state/.night-run")
night "$HOME_F" ledger >/dev/null
[ "$before" = "$(cat "$HOME_F/state/.night-run")" ] || fail "the ledger mutated the night record"
pass "the ledger is read-only"

# An unmeasurable quota reading is reported as unavailable, never fabricated.
rm -f "$HOME_F/fakebin/quota-axi"
printf '#!/usr/bin/env bash\nexit 1\n' > "$HOME_F/fakebin/quota-axi"
chmod +x "$HOME_F/fakebin/quota-axi"
assert_contains "$(night "$HOME_F" ledger)" "Quota at wake: unavailable" \
  "an unreadable quota is reported as unavailable"
assert_contains "$(night "$HOME_F" ledger)" "Quota delta: not comparable" \
  "an unreadable quota yields no fabricated delta"
pass "an unmeasurable quota reading is reported honestly"

echo "ALL PASS: fm-night-check"

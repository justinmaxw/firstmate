#!/usr/bin/env bash
# Portable regression for bin/fm-metrics.sh.
#
# The two properties worth pinning are the ones a wrong implementation would
# still look right for: a duplicate or malformed row must be refused rather than
# appended, and `summarize` must distinguish a home with no metrics file from a
# home that did no work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUT="$ROOT/bin/fm-metrics.sh"
TMP_ROOT=$(fm_test_tmproot fm-metrics)
HEADER='date,project,task_id,kind,dispatched,pr_opened,merged,captain_msgs,escalations,escalation_types,rework_48h'

MAIN="$TMP_ROOT/main"
SM_PRESENT="$TMP_ROOT/sm-present"
SM_EMPTY="$TMP_ROOT/sm-empty"
mkdir -p "$MAIN/data" "$SM_PRESENT/data" "$SM_EMPTY/data"
METRICS="$MAIN/data/metrics.csv"

{
  printf -- '- present - lab (home: %s; scope: x; projects: ; added 2026-01-01)\n' "$SM_PRESENT"
  printf -- '- absent - lab (home: %s; scope: x; projects: ; added 2026-01-01)\n' "$TMP_ROOT/sm-never-seeded"
  printf -- '- faraway - lab (host: box; root: /srv/fm; home: /srv/home; scope: x; projects: ; added 2026-01-01)\n'
} > "$MAIN/data/secondmates.md"

main_run() {  # <args...>
  RC=0
  OUT=$(FM_HOME="$MAIN" "$SUT" "$@" 2>&1) || RC=$?
}

home_run() {  # <home> <args...>
  local home=$1
  shift
  RC=0
  OUT=$(FM_HOME="$home" "$SUT" "$@" 2>&1) || RC=$?
}

# --- append ------------------------------------------------------------------

main_run append --project vending --task-id t1 --kind ship \
  --dispatched 2026-08-01T00:00:00Z --merged 2026-08-01T06:00:00Z \
  --captain-msgs 4 --escalations 2 --escalation-types 'decision;merge' --date 2026-08-01
expect_code 0 "$RC" "first append"$'\n'"$OUT"
[ "$(head -1 "$METRICS")" = "$HEADER" ] || fail "append did not create the exact header"$'\n'"$(head -1 "$METRICS")"

main_run append --project vending --task-id t2 --kind ship \
  --dispatched 2026-08-02T00:00:00Z --merged 2026-08-02T10:00:00Z \
  --captain-msgs 2 --escalations 1 --escalation-types blocker --date 2026-08-02
expect_code 0 "$RC" "second append"$'\n'"$OUT"
[ "$(grep -c . "$METRICS")" = 3 ] || fail "expected a header plus two rows"$'\n'"$(cat "$METRICS")"
pass "append creates the file with its exact header and writes one row per task"

main_run append --project vending --task-id t1 --kind ship --dispatched 2026-08-03T00:00:00Z
expect_code 1 "$RC" "duplicate task id"
assert_contains "$OUT" "task_id 't1' already has a row" "the duplicate is named"
[ "$(grep -c . "$METRICS")" = 3 ] || fail "a refused duplicate still changed the file"

main_run append --project vending --task-id t9 --kind ship \
  --dispatched 2026-08-03T00:00:00Z --escalation-types 'decision;bogus'
expect_code 1 "$RC" "malformed escalation type"
assert_contains "$OUT" "escalation_types entry 'bogus' is not one of" "the bad type is named"
assert_contains "$OUT" 'decision,blocker,credential,merge,destructive,other' "the allowed set is printed"
[ "$(grep -c . "$METRICS")" = 3 ] || fail "a refused malformed row was still appended"

main_run append --project vending --task-id t9 --kind ship --dispatched 'yesterday'
expect_code 1 "$RC" "malformed timestamp"
assert_contains "$OUT" 'must be ISO-8601 UTC' "a bad timestamp is refused"

main_run append --project vending --task-id t9 --kind chore --dispatched 2026-08-03T00:00:00Z
expect_code 1 "$RC" "unknown kind"
assert_contains "$OUT" 'must be ship or scout' "an unknown kind is refused"

main_run append --project 'a,b' --task-id t9 --kind ship --dispatched 2026-08-03T00:00:00Z
expect_code 1 "$RC" "a comma in a field"
assert_contains "$OUT" 'must not contain a comma' "a comma that would corrupt the CSV is refused"
[ "$(grep -c . "$METRICS")" = 3 ] || fail "a refused row reached the file"
pass "append refuses a duplicate task id, a malformed escalation type, and malformed fields"

# --- rework ------------------------------------------------------------------

main_run rework t2
expect_code 0 "$RC" "rework an existing row"$'\n'"$OUT"
[ "$(awk -F, '$3 == "t2" { print $11 }' "$METRICS")" = 1 ] \
  || fail "rework did not set rework_48h on t2"$'\n'"$(cat "$METRICS")"
[ "$(awk -F, '$3 == "t1" { print $11 }' "$METRICS")" = 0 ] \
  || fail "rework changed a row it was not asked about"$'\n'"$(cat "$METRICS")"

main_run rework nosuchtask
expect_code 1 "$RC" "rework an unknown task id"
assert_contains "$OUT" "no row for task_id 'nosuchtask'" "an unknown task id is named"
assert_contains "$OUT" 'never creates one' "rework refuses to invent a row"
pass "rework corrects exactly the named existing row and refuses to create one"

# --- summarize ---------------------------------------------------------------

home_run "$SM_PRESENT" append --project panhel --task-id p1 --kind ship \
  --dispatched 2026-08-01T00:00:00Z --merged 2026-08-01T02:00:00Z \
  --captain-msgs 1 --escalations 1 --escalation-types decision --date 2026-08-01
expect_code 0 "$RC" "second mate home appends to its own file"$'\n'"$OUT"
[ -f "$SM_PRESENT/data/metrics.csv" ] || fail "the second mate's row did not land in its own home"
[ "$(grep -c . "$METRICS")" = 3 ] || fail "a second mate append reached the main home's file"

main_run summarize
expect_code 0 "$RC" "summarize"$'\n'"$OUT"
assert_contains "$OUT" "main ($MAIN): tasks=2" "the main home's own rows are reported"
assert_contains "$OUT" "present ($SM_PRESENT): tasks=1" "a registered second mate's rows are read"
assert_contains "$OUT" 'absent' "a second mate with no file is still listed"
assert_contains "$OUT" 'no rows' "a missing file is reported as no rows"
assert_not_contains "$OUT" 'absent: tasks=0' "a missing file is never reported as zero work"
assert_contains "$OUT" 'faraway: not readable from here (remote route on box)' "a remote route is reported, not silently skipped"

# Medians are computed from rows, not by averaging per-home medians: main is
# 6h and 10h, the second mate is 2h, so the fleet median is the middle value 6.
assert_contains "$OUT" 'main ('"$MAIN"'): tasks=2 median_hours_dispatch_to_merge=8.0' "the main median is the middle of its own rows"
assert_contains "$OUT" 'FLEET TOTAL: tasks=3 median_hours_dispatch_to_merge=6.0' "the fleet median comes from every row"
assert_contains "$OUT" 'captain_msgs_per_task=2.3' "captain messages per task are reported for the fleet"

# The histogram is the number the captain actually wants.
assert_contains "$OUT" 'escalation decision: 2' "decisions are counted across homes"
assert_contains "$OUT" 'escalation merge: 1' "each escalation type is counted separately"
assert_contains "$OUT" 'escalation blocker: 1' "every type in the set appears"
pass "summarize reads this home plus every registered second mate and separates no-rows from zero work"

main_run summarize --since 2026-08-02
expect_code 0 "$RC" "summarize --since"$'\n'"$OUT"
assert_contains "$OUT" "main ($MAIN): tasks=1" "--since filters the main home's rows"
assert_contains "$OUT" "present ($SM_PRESENT): no rows" "--since can empty a home that has a file"
assert_contains "$OUT" 'FLEET TOTAL: tasks=1' "--since filters the fleet total too"

main_run summarize --since notadate
expect_code 1 "$RC" "malformed --since"
assert_contains "$OUT" 'must be YYYY-MM-DD' "a malformed --since is refused"
pass "summarize honors --since across every home and refuses a malformed date"

# --- a home with no rows at all ----------------------------------------------

home_run "$SM_EMPTY" summarize
expect_code 0 "$RC" "summarize in a home with nothing recorded"$'\n'"$OUT"
assert_contains "$OUT" 'FLEET TOTAL: no rows' "an empty fleet reports no rows rather than fabricating zeros"
pass "a home with nothing recorded summarizes cleanly"

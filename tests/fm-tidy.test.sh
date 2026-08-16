#!/usr/bin/env bash
# Behavior tests for bin/fm-tidy.sh.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIDY="$ROOT/bin/fm-tidy.sh"
TMP_ROOT=$(fm_test_tmproot fm-tidy)

# A real treehouse on PATH would let tidy inspect (and clean) real pool slots
# mid-test, so every invocation gets a no-op stub unless a test supplies its own.
STUBBIN="$TMP_ROOT/stubbin"
mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/treehouse"
chmod +x "$STUBBIN/treehouse"

make_home() {
  local home="$TMP_ROOT/home-$RANDOM"
  mkdir -p "$home/state/pending-replies" "$home/state/procevent-inbox" "$home/data"
  printf '%s\n' "$home"
}
old() { touch -t 202601010000 "$1"; }
recent() { touch -t 202605200000 "$1"; }
run_tidy() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_TIDY_NOW=1780000000 PATH="$STUBBIN:$PATH" "$TIDY" "${@:2}"; }

seed_records() {
  local home=$1 state="$1/state"
  printf 'window=main:fm-live\nworktree=/live\n' > "$state/live.meta"
  printf 'window=main:fm live\n' > "$state/live2.meta"
  : > "$state/.hash-main_fm-live"
  : > "$state/.hash-main_fm live"
  : > "$state/.hash-main_fm-dead"
  : > "$state/.seen-live_turn-ended"
  : > "$state/.seen-gone_turn-ended"
  : > "$state/.stale-since-dead"
  : > "$state/.seen-procevent-abcdef"
  printf 'phase=resolved\nresolved_epoch=1700000000\n' > "$state/pending-replies/old"
  printf 'phase=resolved\nresolved_epoch=1779999999\n' > "$state/pending-replies/recent"
  printf 'phase=awaiting_report\nresolved_epoch=1700000000\n' > "$state/pending-replies/open"
  printf 'phase=resolved\nresolved_epoch=1700000000\ntask_id=live\n' > "$state/pending-replies/live-task"
  printf result > "$state/procevent-inbox/old.1.result"
  printf adapter > "$state/procevent-inbox/old.1.adapter"
  : > "$state/procevent-inbox/old.1.handled"
  old "$state/procevent-inbox/old.1.handled"
  printf result > "$state/procevent-inbox/open.1.result"
  printf adapter > "$state/procevent-inbox/open.1.adapter"
}

test_dry_run_matches_safe_record_cleanup() {
  local home out n
  home=$(make_home)
  seed_records "$home"
  out=$(run_tidy "$home" --dry-run 2>/dev/null)
  assert_contains "$out" "remove: $home/state/.hash-main_fm-dead" "dry run did not list dead watcher marker"
  assert_contains "$out" "remove: $home/state/.seen-gone_turn-ended" "dry run did not list dead turn-ended marker"
  n=$(printf '%s\n' "$out" | grep -cF "remove: $home/state/.stale-since-dead")
  [ "$n" -eq 1 ] || fail "dry run listed .stale-since-dead $n times instead of once"
  assert_contains "$out" "remove: $home/state/pending-replies/old" "dry run did not list old resolved reply"
  assert_contains "$out" "remove: $home/state/procevent-inbox/old.1.result" "dry run did not list handled result"
  assert_present "$home/state/.hash-main_fm-dead" "dry run removed watcher marker"
  assert_present "$home/state/pending-replies/old" "dry run removed reply"
  run_tidy "$home" >/dev/null 2>&1
  assert_absent "$home/state/.hash-main_fm-dead" "real run retained dead watcher marker"
  assert_absent "$home/state/.seen-gone_turn-ended" "real run retained dead turn-ended marker"
  assert_absent "$home/state/.stale-since-dead" "real run retained dead stale-since marker"
  assert_absent "$home/state/pending-replies/old" "real run retained old resolved reply"
  assert_absent "$home/state/procevent-inbox/old.1.result" "real run retained handled result"
  assert_present "$home/state/.hash-main_fm-live" "live watcher marker was removed"
  assert_present "$home/state/.hash-main_fm live" "live space-window marker was removed"
  assert_present "$home/state/.seen-live_turn-ended" "live turn-ended marker was removed"
  assert_present "$home/state/.seen-procevent-abcdef" "ambiguous procevent marker was removed"
  assert_present "$home/state/pending-replies/recent" "recent resolved reply was removed"
  assert_present "$home/state/pending-replies/open" "unresolved reply was removed"
  assert_present "$home/state/pending-replies/live-task" "live-task reply was removed"
  assert_present "$home/state/procevent-inbox/open.1.result" "unhandled result was removed"
  pass "fm-tidy: dry run and safe record boundaries"
}

test_report_archiving_boundaries_and_reference_rewrite() {
  local home data out
  home=$(make_home); data="$home/data"
  mkdir -p "$data/archive" "$data/old-report" "$data/open-report" "$data/secondmate" \
    "$data/request-requests" "$data/fresh-report/notes" "$data/noted-report" \
    "$data/closed-report" "$data/bad(report"
  printf report > "$data/old-report/report.md"
  printf report > "$data/open-report/report.md"
  printf report > "$data/secondmate/report.md"
  printf report > "$data/request-requests/report.md"
  printf report > "$data/fresh-report/report.md"
  printf update > "$data/fresh-report/notes/update.md"
  printf report > "$data/noted-report/report.md"
  printf report > "$data/closed-report/report.md"
  printf report > "$data/bad(report/report.md"
  old "$data/old-report/report.md"; old "$data/open-report/report.md"; old "$data/secondmate/report.md"
  old "$data/request-requests/report.md"; old "$data/fresh-report/report.md"; old "$data/noted-report/report.md"
  old "$data/closed-report/report.md"; old "$data/bad(report/report.md"
  recent "$data/fresh-report/notes/update.md"
  printf '%s\n' '- [ ] open-report - open item (repo: x)' '- [x] closed-report - finished item' > "$data/backlog.md"
  printf '%s\n' '- secondmate - charter (home: /tmp/secondmate; scope: work; projects: x; added 2026-01-01)' > "$data/secondmates.md"
  printf '%s\n' 'design context lives in data/noted-report/report.md' > "$data/notes.md"
  printf '%s\n' '- [x] old-report - report data/old-report/report.md' > "$data/done-archive.md"
  out=$(run_tidy "$home" --dry-run 2>/dev/null)
  assert_contains "$out" "move: $data/old-report -> $data/archive/old-report" "dry run did not list old report"
  assert_present "$data/old-report" "dry run moved report"
  run_tidy "$home" >/dev/null 2>&1
  assert_present "$data/archive/old-report/report.md" "old report was not archived"
  assert_contains "$(<"$data/done-archive.md")" 'data/archive/old-report/report.md' "archive reference was not rewritten"
  assert_present "$data/archive/closed-report/report.md" "closed-backlog report was not archived"
  assert_present "$data/open-report/report.md" "open-backlog report was moved"
  assert_present "$data/secondmate/report.md" "secondmate charter report was moved"
  assert_present "$data/request-requests/report.md" "request report was moved"
  assert_present "$data/fresh-report/report.md" "recently updated report was moved"
  assert_present "$data/noted-report/report.md" "note-referenced report was moved"
  assert_present "$data/bad(report/report.md" "unvalidated-id report was moved"
  pass "fm-tidy: archives only eligible report directories"
}

test_quiet_noop_run_is_silent() {
  local home repo out
  home=$(make_home); repo="$TMP_ROOT/root-$RANDOM"
  git init -q "$repo"
  : > "$home/state/.seen-procevent-abc123"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_TIDY_NOW=1780000000 PATH="$STUBBIN:$PATH" "$TIDY" --quiet 2>&1)
  [ -z "$out" ] || fail "quiet no-op run produced output: $out"
  assert_present "$home/state/.seen-procevent-abc123" "retained procevent marker was removed"
  pass "fm-tidy: quiet no-op run is silent"
}

test_only_unleased_unreferenced_treehouse_scratch_is_removed() {
  local home pool fakebin json
  home=$(make_home); pool="$TMP_ROOT/pool-$RANDOM"; fakebin="$TMP_ROOT/fakebin-$RANDOM"
  mkdir -p "$pool/available" "$pool/leased" "$fakebin"
  git -C "$pool/available" init -q; git -C "$pool/leased" init -q
  printf scratch > "$pool/available/scratch.txt"
  printf scratch > "$pool/leased/keep.txt"
  json=$(printf '[{"path":"%s","status":"available","processes":[]},{"path":"%s","status":"leased","processes":[]}]' "$pool/available" "$pool/leased")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "$1" = status ] && [ "$2" = --json ] && printf '%s\n' "$FM_TIDY_TREEHOUSE_JSON"
SH
  chmod +x "$fakebin/treehouse"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TIDY_NOW=1780000000 FM_TIDY_TREEHOUSE_JSON="$json" PATH="$fakebin:$PATH" "$TIDY" >/dev/null 2>&1
  assert_absent "$pool/available/scratch.txt" "available unreferenced scratch was retained"
  assert_present "$pool/leased/keep.txt" "leased scratch was removed"
  printf scratch > "$pool/available/referenced.txt"
  printf 'worktree=%s\n' "$pool/available" > "$home/state/live.meta"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TIDY_NOW=1780000000 FM_TIDY_TREEHOUSE_JSON="$json" PATH="$fakebin:$PATH" "$TIDY" >/dev/null 2>&1
  assert_present "$pool/available/referenced.txt" "live task scratch was removed"
  pass "fm-tidy: treehouse cleanup excludes leased and live-task slots"
}

test_bootstrap_only_runs_tidy_for_locked_session() {
  local home state
  home=$(make_home); state="$home/state"
  : > "$state/.hash-dead-window"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY=0 FM_BOOTSTRAP_LOCKED=0 PATH="$STUBBIN:$PATH" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 || true
  assert_present "$state/.hash-dead-window" "unlocked bootstrap ran tidy"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    FM_BOOTSTRAP_DETECT_ONLY=0 FM_BOOTSTRAP_LOCKED=1 PATH="$STUBBIN:$PATH" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 || true
  assert_absent "$state/.hash-dead-window" "locked bootstrap did not run tidy"
  pass "fm-tidy: bootstrap integration is lock-gated"
}

test_dry_run_matches_safe_record_cleanup
test_report_archiving_boundaries_and_reference_rewrite
test_quiet_noop_run_is_silent
test_only_unleased_unreferenced_treehouse_scratch_is_removed
test_bootstrap_only_runs_tidy_for_locked_session

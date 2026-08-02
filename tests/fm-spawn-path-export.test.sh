#!/usr/bin/env bash
# tests/fm-spawn-path-export.test.sh - Regression test for PATH export to crewmate panes.
# Validates that fm-spawn.sh exports firstmate's own $PATH into the spawned crewmate's
# shell environment, ensuring tools like gh-axi are available even when the pane's
# inherited PATH is incomplete (observed on herdr with nix home-manager).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }

export FM_GATE_REFUSE_BYPASS=1

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-spawn-path-export-test)
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-spawn-path-export-test-h7) || {
  rm -rf "$TMP_ROOT"
  fail "could not generate an isolated Herdr lab session name"
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
ID="pathexporttest1"
WT=

cleanup_all() {
  local cleanup_status=0
  [ -n "$WT" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT" >/dev/null 2>&1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_status=$?
  rm -rf "$TMP_ROOT"
  return "$cleanup_status"
}

on_exit() {
  local status=$?
  cleanup_all || status=$?
  trap - EXIT
  exit "$status"
}

trap on_exit EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

# Create a fake tool directory to test PATH export
FAKE_BIN_DIR="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN_DIR"
cat > "$FAKE_BIN_DIR/test-tool" <<'EOF'
#!/usr/bin/env bash
echo "test-tool-found"
EOF
chmod +x "$FAKE_BIN_DIR/test-tool"

STATE="$TMP_ROOT/state"; DATA="$TMP_ROOT/data"; CONFIG="$TMP_ROOT/config"
mkdir -p "$STATE" "$DATA/$ID" "$CONFIG"
cat > "$DATA/$ID/brief.md" <<'BRIEF'
# Test PATH Export Brief

Run a simple test to verify the exported PATH includes directories from firstmate's environment.
Command: test-tool

BRIEF

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

# Spawn with PATH including the fake bin dir
OUT_FILE="$TMP_ROOT/spawn.out"; ERR_FILE="$TMP_ROOT/spawn.err"
# Prepend the fake bin to PATH so the export will include it
TEST_PATH="$FAKE_BIN_DIR:$PATH"
env -u TMUX -u FM_BACKEND PATH="$TEST_PATH" HERDR_ENV=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
  FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" "sh -c 'echo path-export-ok'" \
  >"$OUT_FILE" 2>"$ERR_FILE"
status=$?
[ "$status" -eq 0 ] || fail "fm-spawn.sh failed"$'\n'"--- stderr ---"$'\n'"$(cat "$ERR_FILE")"

META="$STATE/$ID.meta"
[ -f "$META" ] || fail "fm-spawn.sh did not write a meta file for $ID"

PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] || fail "spawn meta is missing herdr_pane_id"

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  fail "spawn did not report a real worktree path"
fi

# Wait briefly for the pane to settle after launch
sleep 1

# Verify PATH export: inject a command that uses the exported PATH to find test-tool
TEST_CHECK_CMD='echo "Checking PATH export:" && which test-tool && test-tool'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send "$PANE" --text "$TEST_CHECK_CMD" --key Enter || true

sleep 1

# Read the pane to see if test-tool was found
PANE_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 100) || \
  fail "pane read failed"

case "$PANE_OUT" in
  *"test-tool-found"*) pass "PATH export: crewmate pane can resolve tools from firstmate's PATH" ;;
  *)
    fail "PATH export test failed - test-tool not found in pane PATH"$'\n'"Pane output:"$'\n'"$PANE_OUT"
    ;;
esac

if ! cleanup_all; then
  trap - EXIT
  fail "isolated Herdr lab teardown failed or the default fleet session changed"
fi
trap - EXIT
pass "PATH export: cleanup successful"

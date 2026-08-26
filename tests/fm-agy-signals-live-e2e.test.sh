#!/usr/bin/env bash
# Opt-in live guard for the agy (Antigravity CLI) crewmate adapter, gated and
# self-skipping the same way tests/fm-muse-signals-live-e2e.test.sh and
# tests/fm-grok-stop-live-e2e.test.sh already are. Run after every Antigravity
# CLI upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md
# (.agents/skills/firstmate-coding-guidelines/SKILL.md "Harness-dependent
# checks").
#
# Unlike Muse's --provider echo, agy has no free/mock inference mode: every
# real invocation here spends the captain's own Google AI Pro/Ultra
# subscription quota. This is why the guard is opt-in rather than part of
# standard CI, and why every prompt below is kept short and --effort low.
#
# Exercises, against the REAL installed binary and the captain's own real
# authenticated session (never read, only relied upon):
#   - the credential preflight's file-existence fact is genuinely true
#   - the interactive launch shape (-i, --model, --effort,
#     --dangerously-skip-permissions) produces a real supervised turn
#   - the verified delivery-confirmation footer ("esc to cancel" busy,
#     "? for shortcuts" idle) against real rendered output, through the
#     shared structural composer classifier
#   - a real Escape interrupt cleanly cancels a turn with an empty composer
#     and no restored text, matching the "no clear key" control-plane fact
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${FM_AGY_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SIGNALS_LIVE=1 to run the real Antigravity CLI signal drift guard (spends real subscription quota)"
  exit 0
fi

[ -x "$AGY_BIN" ] || fail "FM_AGY_SIGNALS_LIVE=1 but no real agy executable is installed on PATH"
[ -x "$REAL_TMUX" ] || fail "FM_AGY_SIGNALS_LIVE=1 but tmux is not installed"

CRED_FILE="${HOME:-}/.gemini/antigravity-cli/jetski_state.pbtxt"
[ -s "$CRED_FILE" ] || fail "FM_AGY_SIGNALS_LIVE=1 but no worker-reachable Antigravity credential is present at '$CRED_FILE' - sign in once with 'agy' first"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated agy workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated agy workspace"

cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" -x 220 -y 50 \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n agy -c "$WORKSPACE" -- \
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
  -u GEMINI_API_KEY \
  AGY_CLI_DISABLE_AUTO_UPDATE=true \
  "$AGY_BIN" --dangerously-skip-permissions --model gemini-3.7-flash --effort low \
  -i 'reply with the exact single word: firstmatelivetest' \
  || fail "could not launch agy with a real interactive turn"

# A fresh worktree needs a trust dialog accepted before the turn starts.
TRUSTED=0
for _ in $(seq 1 100); do
  if "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null | grep -q 'trust the contents'; then
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
    TRUSTED=1
    break
  fi
  # --dangerously-skip-permissions does not suppress the trust dialog, but a
  # pane that is already past it (or never showed one) still counts as ready.
  if "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null | grep -qE 'shortcuts|esc to cancel'; then
    TRUSTED=1
    break
  fi
  sleep 0.3
done
[ "$TRUSTED" = 1 ] || fail "agy never reached a trusted, ready pane"

BUSY_SEEN=0
for _ in $(seq 1 100); do
  CAP=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null)
  if printf '%s' "$CAP" | fm_busy_lines_match agy; then
    BUSY_SEEN=1
    break
  fi
  sleep 0.2
done
[ "$BUSY_SEEN" = 1 ] || fail "the verified agy busy footer ('esc to cancel') never appeared during a real turn"
pass "agy's real busy footer matches the verified delivery-confirmation regex"

IDLE_SEEN=0
REPLY_SEEN=0
for _ in $(seq 1 150); do
  CAP=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null)
  if ! printf '%s' "$CAP" | fm_busy_lines_match agy; then
    IDLE_SEEN=1
    printf '%s' "$CAP" | grep -q 'firstmatelivetest' && REPLY_SEEN=1
    [ "$REPLY_SEEN" = 1 ] && break
  fi
  sleep 0.2
done
[ "$IDLE_SEEN" = 1 ] || fail "agy's busy footer never cleared after a real turn completed"
[ "$REPLY_SEEN" = 1 ] || fail "agy's real reply never echoed the requested exact word"
pass "agy's real turn completes, clears its busy footer, and echoes the requested reply"

# KNOWN LIMITATION, disclosed rather than hidden (see the agy section of
# .agents/skills/harness-adapters/SKILL.md and
# docs/verification/runtime-backends.md "Composer classification"): agy's
# idle composer box uses a bare `─` rule both above and below its prompt, with
# no corner glyphs. The shared structural scanner's existing Pi-pair detector
# (_fm_composer_pi_separator_row) matches that same bare-rule shape - it
# exists to recognize Pi's own composer, which is drawn the same way - and
# resolving a pi-pair candidate requires proving Pi identity, which agy
# correctly fails. The safe, honest result is `unknown`, never a wrong `empty`
# or `pending`; this assertion pins that current, disclosed behavior rather
# than asserting the more precise `empty` a future fix could earn once the
# shared scanner is taught to disambiguate a non-Pi bare-rule box, which is
# real follow-up work, not a Task 1 requirement.
COMPOSER_STATE=$(fm_tmux_composer_state "$TARGET")
[ "$COMPOSER_STATE" = unknown ] \
  || fail "agy's real idle composer classified as '$COMPOSER_STATE'; expected the disclosed 'unknown' (if this now reads 'empty', the shared scanner's Pi-pair ambiguity has been fixed - update this assertion and the disclosed-limitation docs together)"
pass "agy's real idle composer classifies as the disclosed, safe 'unknown' rather than a wrong empty/pending verdict"

# Real Escape interrupt on a real, deliberately slow turn.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  'count slowly from 1 to 100, one number per line, thinking carefully about each one'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
BUSY_SEEN=0
for _ in $(seq 1 50); do
  CAP=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null)
  if printf '%s' "$CAP" | fm_busy_lines_match agy; then
    BUSY_SEEN=1
    break
  fi
  sleep 0.2
done
[ "$BUSY_SEEN" = 1 ] || fail "the slow counting turn never registered busy before the interrupt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape

INTERRUPTED=0
for _ in $(seq 1 100); do
  CAP=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null)
  if printf '%s' "$CAP" | grep -qi 'Interrupted'; then
    INTERRUPTED=1
    break
  fi
  sleep 0.2
done
[ "$INTERRUPTED" = 1 ] || fail "a real Escape never produced agy's interrupted acknowledgement"

# The shared structural classifier cannot yet prove agy's composer empty (see
# the disclosed limitation above), so this checks the fact fm_control_lib.sh's
# "no clear key needed" contract actually depends on directly: the interrupted
# prompt text must NOT be restored into the composer's own LIVE prompt row
# (unlike muse, which needs a C-u clear for exactly this reason). The
# interrupted prompt legitimately still appears higher up, in the scrolled-back
# transcript echo of the turn that was cancelled - that is not the composer and
# must not fail this check, so only the last non-blank row (the live composer)
# is inspected.
COMPOSER_ROW=
for _ in $(seq 1 30); do
  COMPOSER_ROW=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null | grep '^>' | tail -1)
  [ "$COMPOSER_ROW" = '>' ] && break
  sleep 0.2
done
[ "$COMPOSER_ROW" = '>' ] \
  || fail "agy's live composer row after a real interrupt read '$COMPOSER_ROW', expected a bare empty '>'; the 'no clear key needed' control-plane fact is wrong"
pass "a real Escape interrupt cleanly cancels the turn and never restores the interrupted prompt into the live composer row"

cleanup
trap - EXIT

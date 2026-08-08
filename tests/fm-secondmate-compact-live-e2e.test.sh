#!/usr/bin/env bash
# Real Claude/Herdr guard for bin/fm-secondmate-compact.sh.
#
# Opt-in because it launches a real interactive Claude Code process in a real
# isolated Herdr lab session and spends tokens. It is the live half of the
# harness-dependent-check contract in
# .agents/skills/firstmate-coding-guidelines/SKILL.md: the portable regression
# pins the logic, this one proves the vendor facts the logic rests on are still
# true - that `/compact` typed into a firstmate-launched Claude pane really
# compacts, and that Claude Code still records the completion as an
# "isCompactSummary":true transcript entry.
#
# It fails naming the Claude version rather than skipping quietly, and it
# asserts the pre-state so a pass cannot be vacuous: the transcript must hold
# NO compaction record before the run and exactly one more afterwards.
#
# Every Herdr call, including calls made inside the production backend adapter,
# is routed through bin/fm-herdr-lab.sh via a PATH shim, so the captain's
# default session is never touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SECONDMATE_COMPACT_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SECONDMATE_COMPACT_LIVE_E2E=1 to run the real Claude/Herdr secondmate compaction guard"
  exit 0
fi

for tool in git herdr jq claude; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
echo "evidence: claude=$CLAUDE_VERSION herdr=$(herdr --version 2>/dev/null | head -1)"

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-sm-compact-live)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-sm-compact-live.XXXXXX")
SENDER="$TMP_ROOT/sender"
SECOND="$TMP_ROOT/second"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
ID=compactlive

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$SENDER/state" "$SENDER/data" "$SENDER/config" "$SENDER/projects" "$FAKEBIN"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
  for arg in "\${args[@]}"; do
    case "\$arg" in
      --session|--session=*) echo "wrapper refused non-trailing session flag" >&2; exit 99 ;;
    esac
  done
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

FM_SECONDMATE_CHARTER='Lab-only throwaway second mate used to guard the context-compaction path. Never run bin/fm-session-start.sh, never spawn crewmates, and never start project work. Answer marked requests from the main firstmate, then go straight back to idle.' \
FM_SECONDMATE_SCOPE='Nothing. Compaction guard only.' \
FM_HOME="$SENDER" "$ROOT/bin/fm-home-seed.sh" "$ID" "$SECOND" --no-projects >/dev/null \
  || fail "could not seed the throwaway secondmate home"

# Claude Code turns transcript saving OFF when it inherits a
# CLAUDE_CODE_CHILD_SESSION marker, and this suite often runs inside a nested
# Claude session. The worker pane inherits its environment from the lab's own
# Herdr server process, not from this script, so the correction has to be
# applied at provision time. The real captain's primary is a top-level session
# whose secondmates do record transcripts (that is production), so this
# reproduces production conditions rather than papering over the signal this
# guard exists to check.
env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 \
  "$LAB_HELPER" provision "$SESSION" >/dev/null \
  || fail "could not provision the isolated Herdr lab session"

PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$SENDER" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND" --secondmate --harness claude --backend herdr >/dev/null \
  || fail "could not spawn the real Claude secondmate"

META="$SENDER/state/$ID.meta"
[ "$(grep -c '^kind=secondmate$' "$META")" = 1 ] || fail "spawn did not record kind=secondmate"
PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
TARGET="$SESSION:$PANE"

peek() { PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$SENDER" "$ROOT/bin/fm-peek.sh" "$ID" 2>&1; }
send() { PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$SENDER" "$ROOT/bin/fm-send.sh" "$@" >/dev/null; }

SECOND_REAL=$(cd "$SECOND" && pwd -P)
TDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$SECOND_REAL" | sed 's/[^A-Za-z0-9]/-/g')"
compact_records() {
  cat "$TDIR"/*.jsonl 2>/dev/null | grep -c '"isCompactSummary":[[:space:]]*true' || true
}

# Claude asks for folder trust on a first launch in a fresh directory
# (.agents/skills/harness-adapters/SKILL.md, claude section). Accept it the way
# firstmate does, then wait for the banner.
READY=0
for _ in $(seq 1 180); do
  PANE_TEXT=$(peek)
  case "$PANE_TEXT" in
    *'Claude Code v'*) READY=1; break ;;
    *'I trust this folder'*|*'Do you trust'*)
      PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$SENDER" \
        "$ROOT/bin/fm-send.sh" "$TARGET" --key Enter >/dev/null 2>&1 || true
      sleep 3
      continue
      ;;
  esac
  sleep 2
done
[ "$READY" = 1 ] \
  || fail "the real Claude TUI never appeared in the lab pane (claude $CLAUDE_VERSION)"$'\n'"$(peek | tail -30)"

# Claude answers "Not enough messages to compact." on a short conversation, so
# give it a real conversation to compact before asserting anything. These turns
# are also what makes the transcript check below meaningful: a session that has
# said nothing yet has no transcript file either.
n=0
for msg in \
  "Summarise your charter in one sentence." \
  "List three risks you would watch for when supervising client work, one line each." \
  "Explain in three sentences how you decide whether a task belongs to your domain." \
  "Write four short bullets on why durable notes beat chat memory."
do
  send "$TARGET" "$msg" || fail "could not steer the real Claude secondmate"
  n=$((n + 1))
  sleep 45
done

[ -n "$(ls "$TDIR"/*.jsonl 2>/dev/null)" ] \
  || fail "claude $CLAUDE_VERSION answered $n turns but wrote no session transcript under $TDIR, so the compaction completion signal is unavailable"$'\n'"$(peek | tail -15)"

BEFORE=$(compact_records)
[ "$BEFORE" = 0 ] \
  || fail "fixture is not a clean control: $TDIR already holds $BEFORE compaction record(s) before the run"
echo "evidence: control - $n conversation turns, 0 compaction records before the run"

RC=0
OUT=$(env PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$SENDER" \
  "$ROOT/bin/fm-secondmate-compact.sh" "$ID" \
  --stow-timeout 600 --compact-timeout 600 --poll-seconds 5 2>&1) || RC=$?
printf '%s\n' "$OUT"
[ "$RC" = 0 ] || fail "fm-secondmate-compact refused or failed against a real idle Claude secondmate (exit $RC, claude $CLAUDE_VERSION)"$'\n'"$OUT"$'\n'"--- pane ---"$'\n'"$(peek | tail -30)"

AFTER=$(compact_records)
[ "$AFTER" -gt "$BEFORE" ] \
  || fail "claude $CLAUDE_VERSION reported success but recorded no new compaction in $TDIR ($BEFORE -> $AFTER)"
echo "evidence: compaction records $BEFORE -> $AFTER"

assert_contains "$OUT" 'reported its stow complete' "the stow was confirmed before the compaction"
assert_contains "$OUT" 'compaction confirmed' "the compaction was confirmed from the transcript"

STOWED=$(ls "$SECOND/data" 2>/dev/null)
echo "evidence: secondmate data/ after the stow: $(printf '%s' "$STOWED" | tr '\n' ' ')"

pass "real claude $CLAUDE_VERSION: an idle secondmate stows, compacts, and the compaction is confirmed on disk"

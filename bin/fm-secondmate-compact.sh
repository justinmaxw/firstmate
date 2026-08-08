#!/usr/bin/env bash
# Stow, then compact, one idle persistent secondmate's conversation context.
# Usage: fm-secondmate-compact.sh <secondmate-id> [options]
#
# WHY: a persistent secondmate supervises task after task in one long-lived
# agent session, so its conversation accumulates torn-down crews, landed PRs,
# and resolved decisions forever. AGENTS.md section 7 owns WHEN firstmate runs
# this (after a PR from that secondmate's domain lands and its work is cleaned
# up). This script owns HOW, and is the single owner of the sequence, the
# refusal set, and the confirmation contract below. It is operator-initiated:
# there is no daemon, no timer, and no registered check.
#
# SEQUENCE (each step must succeed before the next one runs):
#   1. Resolve and validate the target as a local, registered, live secondmate
#      whose harness has a verified compaction command.
#   2. Refuse unless the domain is genuinely at rest.
#   3. Ask the secondmate to stow, through the ordinary marked from-firstmate
#      request channel, and WAIT for its correlated parent report. Compaction
#      discards conversation, so durable knowledge must reach that home's data/
#      first; a fixed sleep is not confirmation, and neither is a successful
#      send (bin/fm-pending-reply-lib.sh owns that distinction).
#   4. Wait for that stow turn to finish, prove the completion channel is live
#      (see CONFIRMATION below), re-check the rest gates, then send the
#      harness's compaction command as unmarked literal text through the
#      recorded backend target.
#   5. Confirm the compaction actually happened, then re-orient the agent.
#
# REFUSALS (each one exits before anything is sent to the agent):
#   - not a resolvable task id in this home, or its metadata is not kind=secondmate
#   - not a single registered route in data/secondmates.md
#   - a remote route: this confirmation reads local session state only
#   - a harness with no verified compaction command (never guessed)
#   - a dead or unreadable backend endpoint
#   - a busy agent at intake, or one still working when its own stow turn's
#     budget runs out (a mid-turn secondmate must not lose its grip on live crew)
#   - any state/*.meta in the secondmate's own home, which means crew work is
#     still recorded there; teardown removes that metadata when work lands, so
#     its presence is exactly "the domain is not cleaned up yet"
#   - an already-open pending-reply expectation for this secondmate, whose
#     answer compaction would destroy
#   - an unlocatable or provably not-writing session transcript, because the
#     compaction could then never be confirmed
#
# MARKING: the stow request goes through bin/fm-send.sh with the task id, so it
# carries the from-firstmate marker and a correlation id and the secondmate
# answers on the parent status path. The compaction command and the follow-up
# re-orientation go through the recorded backend target instead, deliberately
# UNMARKED: the marker and its corr= token are prepended to the message body,
# which would turn "/compact" into ordinary text rather than a slash command,
# and a compaction request has no answer for a pending-reply record to collect.
#
# CONFIRMATION (claude): Claude Code records a completed compaction as a
# transcript entry carrying "isCompactSummary":true with the compaction's own
# timestamp, under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<slugified cwd>/.
# That on-disk record is the verdict; the rendered pane is never read for it.
# Two gates keep the check honest rather than vacuously passing:
#   - the transcript directory must already exist for this home, and the stow
#     turn (step 3) must have appended to a transcript in it. Claude Code
#     silently disables transcript saving in some environments (observed with
#     an inherited nested-session marker), and without this probe an absent
#     signal would be indistinguishable from a failed compaction.
#   - a record counts only when it is newer than the moment the command was sent
#     AND newer than the newest record that already existed before it, so
#     neither an older compaction nor one written earlier in the same
#     second-truncated timestamp can be mistaken for this one.
# Claude answers "Not enough messages to compact." on a short conversation and
# no record is written; that is reported as an unconfirmed compaction (exit 4)
# with the pane tail attached, not silently treated as success.
# See .agents/skills/harness-adapters/SKILL.md for the per-harness facts and
# docs/verification/supervision.md for the dated live evidence.
#
# Options:
#   --stow-timeout <secs>     wait for the correlated stow report (default 900)
#   --compact-timeout <secs>  wait for the compaction record (default 600)
#   --poll-seconds <secs>     poll interval for both waits (default 5)
#   -h, --help                print this header
#
# Exit status:
#   0  compacted and confirmed
#   1  refused before anything was sent, or the send itself failed
#   2  usage error
#   3  the stow was never confirmed; no compaction command was sent
#   4  the compaction command was sent but never confirmed
#
# Environment:
#   FM_HOME              active firstmate home (required)
#   FM_ROOT_OVERRIDE     firstmate repo root
#   FM_STATE_OVERRIDE    state dir
#   FM_DATA_OVERRIDE     data dir
#   CLAUDE_CONFIG_DIR    Claude Code config root (transcript lookup)
#   FM_SECONDMATE_COMPACT_SEND
#                        command prefix used instead of bin/fm-send.sh; it
#                        receives the same "<target> <text>" arguments. Test
#                        seam only, never a production path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

# Refuse loudly and stop. The code is validated so a malformed call can never
# leave `exit` failing and execution falling through into the next step.
die() {  # <exit-code> <message...>
  local code=$1
  shift
  case "$code" in
    ''|*[!0-9]*) printf 'fm-secondmate-compact: internal error: non-numeric exit code\n' >&2; code=1 ;;
  esac
  printf 'fm-secondmate-compact: %s\n' "$*" >&2
  exit "$code"
}

say() {
  printf 'fm-secondmate-compact: %s\n' "$*"
}

ID=
STOW_TIMEOUT=900
COMPACT_TIMEOUT=600
POLL_SECONDS=5

require_positive_int() {  # <value> <flag>
  case "$1" in
    ''|*[!0-9]*) die 2 "$2 needs a whole number of seconds, got '$1'" ;;
  esac
  [ "$1" -gt 0 ] || die 2 "$2 needs a positive number of seconds, got '$1'"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --stow-timeout) [ $# -ge 2 ] || die 2 "--stow-timeout needs a value"; require_positive_int "$2" --stow-timeout; STOW_TIMEOUT=$2; shift 2 ;;
    --compact-timeout) [ $# -ge 2 ] || die 2 "--compact-timeout needs a value"; require_positive_int "$2" --compact-timeout; COMPACT_TIMEOUT=$2; shift 2 ;;
    --poll-seconds) [ $# -ge 2 ] || die 2 "--poll-seconds needs a value"; require_positive_int "$2" --poll-seconds; POLL_SECONDS=$2; shift 2 ;;
    -*) die 2 "unknown option '$1' (see --help)" ;;
    *)
      [ -z "$ID" ] || die 2 "expected exactly one secondmate id, also got '$1'"
      ID=$1
      shift
      ;;
  esac
done

[ -n "$ID" ] || { usage; exit 2; }
case "$ID" in
  *[!A-Za-z0-9._-]*) die 2 "'$ID' is not a valid secondmate id" ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  die 2 "FM_HOME is not set; refusing to resolve a secondmate without an explicit firstmate home"
fi
[ -d "$FM_HOME" ] || die 2 "FM_HOME '$FM_HOME' is not a directory"

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || die 2 "state dir '$STATE' is missing"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

# --- per-harness compaction facts -------------------------------------------
#
# One case arm per VERIFIED harness. A harness needs BOTH a compaction command
# and a completion signal this script can read before it belongs here; adding a
# command alone would let the script send something it can never confirm.
# .agents/skills/harness-adapters/SKILL.md owns the verified facts themselves.

compaction_command_for_harness() {  # <harness>
  case "$1" in
    claude|claude-*) printf '/compact' ;;
    *) return 1 ;;
  esac
}

# --- validation -------------------------------------------------------------

META="$STATE/$ID.meta"
[ -f "$META" ] || die 1 "no metadata for '$ID' in $STATE; this home has no such direct report"

KIND=$(fm_meta_get "$META" kind)
[ "$KIND" = secondmate ] \
  || die 1 "'$ID' is recorded as kind='${KIND:-unset}', not a persistent secondmate; refusing to compact a crewmate or scout"

if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die 1 "'$ID' is a remote secondmate route; this path confirms compaction from local session state only, so it refuses rather than sending a command it cannot verify"
fi

REGISTRY="$DATA/secondmates.md"
secondmate_registry_line_for_id "$REGISTRY" "$ID" \
  || die 1 "'$ID' is not a single unambiguous route in $REGISTRY; refusing to compact an unregistered secondmate"
if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
  die 1 "'$ID' is registered as a remote route in $REGISTRY; refusing to compact a home this process cannot read"
fi

HOME_DIR=$(fm_meta_get "$META" home)
[ -n "$HOME_DIR" ] || HOME_DIR=$SECONDMATE_REGISTRY_HOME
[ -n "$HOME_DIR" ] || die 1 "no secondmate home recorded for '$ID' in $META or $REGISTRY"
HOME_REAL=$(cd "$HOME_DIR" 2>/dev/null && pwd -P) \
  || die 1 "secondmate home '$HOME_DIR' for '$ID' is not a readable directory"

HARNESS=$(fm_meta_get "$META" harness)
COMPACT_CMD=$(compaction_command_for_harness "$HARNESS") \
  || die 1 "harness '${HARNESS:-unset}' has no verified compaction command; refusing to guess one (see .agents/skills/harness-adapters/SKILL.md)"

BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
[ -n "$TARGET" ] || die 1 "no backend endpoint recorded for '$ID' in $META"
fm_backend_validate "$BACKEND" || die 1 "backend '$BACKEND' for '$ID' is not usable here"
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$ID" "$STATE" 2>/dev/null || true)
fm_backend_target_exists "$BACKEND" "$TARGET" "$EXPECTED_LABEL" \
  || die 1 "'$ID' has no live endpoint at $TARGET; recover the secondmate before compacting it"

# --- rest gates -------------------------------------------------------------

busy_verdict() {
  fm_busy_classify_live "$BACKEND" "$TARGET" "$HARNESS" "$ID" "$STATE" "$EXPECTED_LABEL"
}

# A secondmate has no armed semantic busy source (bin/fm-spawn.sh deliberately
# skips the arm for kind=secondmate), so `unknown` is the ordinary reading and
# cannot be treated as a refusal without making this path unusable. What the
# classifier still gives us is a POSITIVE busy verdict - herdr's native
# streaming state - and that is the one this gate acts on. The completed stow
# round-trip below is the real evidence that the agent is responsive and has
# finished its turn.
refuse_if_busy() {  # <phase>
  local verdict
  verdict=$(busy_verdict)
  case "${verdict%% *}" in
    busy) die 1 "'$ID' is mid-turn ($verdict) $1; refusing to compact a working secondmate" ;;
    dead) die 1 "'$ID' endpoint is gone ($verdict) $1" ;;
  esac
}

# The correlated stow report can land while the agent is still finishing that
# same turn - it appends the status line and then keeps working - so an
# immediate busy read after the report is expected rather than a reason to
# refuse. Give the turn the same budget the stow itself had to settle, and
# refuse only if it is STILL running at the end of it.
wait_until_settled() {  # <seconds> <phase>
  local deadline verdict
  deadline=$(( $(date -u +%s) + $1 ))
  while :; do
    verdict=$(busy_verdict)
    case "${verdict%% *}" in
      busy) ;;
      dead) die 1 "'$ID' endpoint is gone ($verdict) $2" ;;
      *) return 0 ;;
    esac
    [ "$(date -u +%s)" -lt "$deadline" ] || break
    sleep "$POLL_SECONDS"
  done
  die 1 "'$ID' was still mid-turn ($(busy_verdict)) after ${1}s $2; refusing to compact a working secondmate"
}

refuse_if_home_has_crew() {  # <phase>
  local m base ids=''
  for m in "$HOME_REAL"/state/*.meta; do
    [ -e "$m" ] || continue
    base=${m##*/}
    ids="$ids ${base%.meta}"
  done
  [ -z "$ids" ] || die 1 "the '$ID' domain still has recorded work in $HOME_REAL/state ($(printf '%s' "$ids" | sed 's/^ //')) $1; clean that work up before compacting"
}

refuse_if_busy "before the stow request"
refuse_if_home_has_crew "before the stow request"

if fm_pending_reply_task_has_open "$STATE" "$ID"; then
  die 1 "'$ID' still owes an answer to an earlier request from this home; compaction would destroy it. Reconcile that request first"
fi

# --- completion-signal location ---------------------------------------------
#
# Resolved before anything is sent: a compaction we could never confirm must
# never be requested. The slugified-cwd directory is Claude Code's own layout;
# when it does not resolve, fall back to matching a transcript's recorded cwd
# rather than hard-coding a second slug rule.

claude_projects_root() {
  printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

transcript_dir_for_cwd() {  # <absolute-real-cwd>
  local cwd=$1 root slug dir hit
  root=$(claude_projects_root)
  [ -d "$root" ] || return 1
  slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
  if [ -d "$root/$slug" ]; then
    printf '%s' "$root/$slug"
    return 0
  fi
  hit=$(grep -rlF --include='*.jsonl' "\"cwd\":\"$cwd\"" "$root" 2>/dev/null | head -1) || true
  [ -n "$hit" ] || return 1
  dir=${hit%/*}
  printf '%s' "$dir"
}

TDIR=$(transcript_dir_for_cwd "$HOME_REAL") \
  || die 1 "no Claude session transcript directory resolves for $HOME_REAL under $(claude_projects_root); refusing to send a compaction command whose completion could not be confirmed"

# File count plus total bytes across this home's transcripts. Append-only JSONL
# makes this a precise "was anything written" signature, unlike an mtime read
# whose resolution can be coarser than the turn we are measuring.
transcript_signature() {
  local f n=0 bytes=0 size
  for f in "$TDIR"/*.jsonl; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    size=$(wc -c < "$f" 2>/dev/null) || size=0
    bytes=$((bytes + size))
  done
  printf '%s:%s' "$n" "$bytes"
}

NO_TRANSCRIPT_FIX="Claude Code turns transcript saving off when it inherits a CLAUDE_CODE_CHILD_SESSION marker; relaunch that secondmate from a session without it, or with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"

TRANSCRIPT_BEFORE=$(transcript_signature)
[ "${TRANSCRIPT_BEFORE%%:*}" -gt 0 ] \
  || die 1 "$TDIR holds no session transcript for '$ID', so a compaction could not be confirmed. $NO_TRANSCRIPT_FIX"

# --- step 3: stow, and wait for the correlated report ------------------------

send_to() {  # <target> <text>
  if [ -n "${FM_SECONDMATE_COMPACT_SEND:-}" ]; then
    # shellcheck disable=SC2086 # a caller-supplied command prefix is word-split on purpose.
    $FM_SECONDMATE_COMPACT_SEND "$@"
  else
    "$SCRIPT_DIR/fm-send.sh" "$@"
  fi
}

STOW_REQUEST="Your conversation context is about to be compacted by the main firstmate, so everything only in this chat is about to be lost. Run your /stow sweep now and file every durable fact from this session into this home's data/ (captain preferences, learnings, backlog notes, unfinished threads, anything a future session would need). Do not start any other work. When the sweep has landed on disk, append one status line that includes this request's corr token and the words 'stow complete'."

STOW_CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$ID" "$STOW_REQUEST") \
  || die 1 "could not record the parent-side expectation for the stow request to '$ID'; nothing was sent"

# Re-read immediately before the request so the signature the stow turn is
# measured against cannot include anything that turn itself wrote.
TRANSCRIPT_BEFORE=$(transcript_signature)

say "asked '$ID' to stow (corr=$STOW_CORR); waiting for its report"
if ! FM_PENDING_REPLY_EXISTING_CORR="$STOW_CORR" send_to "$ID" "$STOW_REQUEST"; then
  fm_pending_reply_discard_undelivered "$STATE" "$STOW_CORR" || true
  die 1 "the stow request to '$ID' was not delivered; nothing was compacted"
fi

deadline_from() {  # <seconds>
  printf '%s' "$(( $(date -u +%s) + $1 ))"
}

STOW_DEADLINE=$(deadline_from "$STOW_TIMEOUT")
STOW_CONFIRMED=0
while :; do
  if fm_pending_reply_try_resolve "$STATE" "$STOW_CORR"; then
    STOW_CONFIRMED=1
    break
  fi
  [ "$(date -u +%s)" -lt "$STOW_DEADLINE" ] || break
  sleep "$POLL_SECONDS"
done

if [ "$STOW_CONFIRMED" != 1 ]; then
  die 3 "'$ID' did not report its stow within ${STOW_TIMEOUT}s (corr=$STOW_CORR); no compaction command was sent, and the open request stays recorded for ordinary reconciliation"
fi
say "'$ID' reported its stow complete"

# --- completion-channel proof ------------------------------------------------
#
# The stow was a real agent turn. If Claude Code were recording this session,
# that turn appended to a transcript here. An untouched transcript directory
# therefore proves the confirmation channel is dead BEFORE we send a command we
# could not verify, instead of after a full timeout that looks like a failed
# compaction.

if [ "$(transcript_signature)" = "$TRANSCRIPT_BEFORE" ]; then
  die 1 "'$ID' completed a turn but nothing was written to $TDIR (still $TRANSCRIPT_BEFORE), so this session is not recording transcripts; refusing to send a compaction command whose completion could not be confirmed. $NO_TRANSCRIPT_FIX"
fi

# --- step 4: compact ---------------------------------------------------------

wait_until_settled "$STOW_TIMEOUT" "after reporting its stow"
refuse_if_home_has_crew "before the compaction command"

newest_compaction_ts() {
  local f
  {
    for f in "$TDIR"/*.jsonl; do
      [ -e "$f" ] || continue
      grep -h '"isCompactSummary":[[:space:]]*true' "$f" 2>/dev/null || true
    done
  } | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p' | LC_ALL=C sort | tail -1
}

BASELINE_TS=$(newest_compaction_ts)
SEND_TS=$(date -u +%Y-%m-%dT%H:%M:%S)

say "sending '$COMPACT_CMD' to '$ID'"
if ! send_to "$TARGET" "$COMPACT_CMD"; then
  die 1 "'$COMPACT_CMD' was not confirmed submitted to '$ID' at $TARGET; nothing was compacted"
fi

COMPACT_DEADLINE=$(deadline_from "$COMPACT_TIMEOUT")
CONFIRMED_TS=
while :; do
  ts=$(newest_compaction_ts)
  # Two conditions, because either alone is defeatable. Newer than the send
  # keeps an old compaction from counting; different from the pre-send newest
  # keeps a record written EARLIER in the same wall-clock second from counting,
  # which the second-truncated SEND_TS cannot rule out on its own (transcript
  # timestamps carry milliseconds).
  if [ -n "$ts" ] && [ "$ts" \> "$SEND_TS" ] \
    && { [ -z "$BASELINE_TS" ] || [ "$ts" \> "$BASELINE_TS" ]; }; then
    CONFIRMED_TS=$ts
    break
  fi
  [ "$(date -u +%s)" -lt "$COMPACT_DEADLINE" ] || break
  sleep "$POLL_SECONDS"
done

if [ -z "$CONFIRMED_TS" ]; then
  printf 'fm-secondmate-compact: %s\n' \
    "'$COMPACT_CMD' reached '$ID' but no compaction was recorded in $TDIR within ${COMPACT_TIMEOUT}s (newest before the send: ${BASELINE_TS:-none}). The stow already landed, so nothing was lost; inspect the agent before retrying. Claude reports 'Not enough messages to compact.' when the conversation is too short to compact." >&2
  if [ -x "$SCRIPT_DIR/fm-peek.sh" ]; then
    printf -- '--- pane tail ---\n' >&2
    "$SCRIPT_DIR/fm-peek.sh" "$ID" 2>&1 | tail -20 >&2 || true
  fi
  exit 4
fi

say "compaction confirmed for '$ID' at $CONFIRMED_TS"

# --- step 5: re-orient -------------------------------------------------------
#
# Claude Code's SessionStart hook does not fire on `compact`, so nothing
# re-injects this home's operating instructions afterwards. Unmarked on
# purpose: this is a pointer, not a request, and it needs no correlated answer.

REORIENT="Your conversation context was just compacted by the main firstmate. Re-read this home's AGENTS.md and data/charter.md now, then go back to waiting silently for routed work. Do not start anything new."
if ! send_to "$TARGET" "$REORIENT"; then
  die 1 "'$ID' was compacted at $CONFIRMED_TS but the follow-up instruction to re-read its own AGENTS.md and charter was not delivered; steer it by hand"
fi

say "'$ID' compacted and re-oriented"

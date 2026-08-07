#!/usr/bin/env bash
# fm-night-check.sh - the overnight queue-running night check and night ledger.
#
# Firstmate's supervision is event-driven off worker status writes, and the
# backlog is not an event source. When the fleet empties overnight with items
# still queued, nothing generates an event and the night ends quietly. This
# script is the one primitive that closes that gap: a registered watcher check
# that converts "the queue has ready work and the fleet has room" into a wake.
# Everything downstream of that wake - selection, dispatch, supervision,
# parking, landing, reporting - is machinery that already runs every day. This
# script adds no scheduler, no orchestrator, and no dispatch path of its own.
#
# `tasks-axi ready` is the selector; this script never reimplements selection.
#
# EDGE-TRIGGERED, not level-triggered. The poll prints only when the
# (ready-set, running-count) signature CHANGED since the last print, using the
# same suppression-marker discipline the watcher already applies to `.seen-*`.
# A level-triggered version reproduces the 2026-07-29 incident, where a stable
# fleet state burned roughly one turn per iteration all night. If firstmate
# wakes and decides NOT to dispatch, the signature is unchanged and the check
# stays silent until reality moves.
#
# Two further limits bound the night independently of that suppression:
#   - a hard per-night dispatch budget that silences the poll at zero,
#     regardless of queue state;
#   - a consecutive-failure stop that ends dispatching after two failed
#     dispatches in a row.
#
# This script decides nothing about authority. It never merges, never spawns,
# never answers a finding, and never relaxes any boundary in AGENTS.md
# section 7. Away-mode parking of a decision firstmate cannot answer is owned
# by the `afk` skill.
#
# Usage:
#   fm-night-check.sh arm --budget <n> [--cap <n>]
#   fm-night-check.sh poll
#   fm-night-check.sh record dispatched|failed|landed|parked <task-id> [--reason <text>]
#   fm-night-check.sh status
#   fm-night-check.sh ledger
#   fm-night-check.sh disarm
#   fm-night-check.sh -h | --help
#
# arm      starts a fresh night in the active FM_HOME: it records the budget and
#          the concurrency cap, takes the bedtime `quota-axi --json` reading,
#          writes state/night-run.check.sh, and binds it with
#          bin/fm-check-register.sh. Re-arming replaces any prior night record.
# poll     is what the watcher runs. It prints at most one line and is otherwise
#          silent. It never mutates the budget or the counters.
# record   is how firstmate accounts for the night. `dispatched` is recorded for
#          every dispatch ATTEMPT, including a spawn that refused, because the
#          budget bounds attempts. `failed` and `landed` are outcomes: `failed`
#          advances the consecutive-failure counter, `landed` resets it.
#          `parked` records an item held for the captain and does not consume
#          budget.
# status   is a cheap read-only counter view with no network call.
# ledger   is the read-only morning ledger: items dispatched, landed, parked
#          with the reason, and failed, plus the bedtime-versus-wake quota
#          delta. It takes the wake quota reading live and records nothing, so
#          the read-only `/bearings file` report can include it verbatim.
# disarm   removes the check and its binding and leaves the night record in
#          place so the morning ledger is still readable.
#
# Exact state files are listed in AGENTS.md section 2 under state/.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The check id is a fixed, path-safe, non-task identity: a night is a property
# of the home, not of any one work item, so it never collides with a task id.
NIGHT_ID=night-run
CHECK="$STATE/$NIGHT_ID.check.sh"
TRUST="$STATE/$NIGHT_ID.check-trust"
RECORD="$STATE/.night-run"
SIGNATURE="$STATE/.night-run-signature"
LOG="$STATE/.night-run-log"
RECORD_VERSION=fm-night-run-v1

# Two failed dispatches in a row ends dispatching for the night. A firstmate
# task is expensive enough that a third attempt is not worth the quota.
MAX_CONSECUTIVE_FAILURES=2
DEFAULT_CAP=3

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-night-check: %s\n' "$*" >&2
  exit 1
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

positive_int() {  # <value>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] ;;
  esac
}

nonnegative_int() {  # <value>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

one_line() {  # <value>
  case "${1:-}" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# --- night record -----------------------------------------------------------

record_get() {  # <key>
  [ -f "$RECORD" ] || return 0
  grep "^$1=" "$RECORD" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

record_get_int() {  # <key>
  local v
  v=$(record_get "$1")
  nonnegative_int "$v" || v=0
  printf '%s' "$v"
}

record_exists() {
  [ -f "$RECORD" ] && [ "$(record_get version)" = "$RECORD_VERSION" ]
}

# Rewrite the whole record atomically. Keys are supplied as key=value pairs and
# override the current value; every other key is carried forward unchanged.
record_write() {  # <key=value>...
  local tmp kv key seen='' line existing
  umask 077
  tmp=$(mktemp "$STATE/.fm-night-run.XXXXXX") || return 1
  printf 'version=%s\n' "$RECORD_VERSION" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  for kv in "$@"; do
    key=${kv%%=*}
    printf '%s\n' "$kv" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    seen="$seen $key"
  done
  if [ -f "$RECORD" ]; then
    while IFS= read -r line; do
      key=${line%%=*}
      [ "$key" != version ] || continue
      case " $seen " in *" $key "*) continue ;; esac
      printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
      seen="$seen $key"
    done < "$RECORD"
  fi
  # Defaults for a record that predates a counter, so reads never see a gap.
  for kv in dispatched=0 failures=0 consecutive_failures=0 landed=0 parked=0 stopped=; do
    key=${kv%%=*}
    case " $seen " in *" $key "*) continue ;; esac
    printf '%s\n' "$kv" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  existing=$tmp
  chmod 0600 "$existing" || { rm -f -- "$existing"; return 1; }
  mv -f -- "$existing" "$RECORD" || { rm -f -- "$existing"; return 1; }
}

log_append() {  # <event> <task-id> <reason>
  umask 077
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$1" "$2" "$3" >> "$LOG"
}

# --- quota ------------------------------------------------------------------

# A compact one-line digest of every provider window, e.g.
# "claude/five_hour=7 claude/seven_day=6". Absent tooling yields "unavailable"
# rather than a fabricated number: the ledger reports what it could measure.
quota_digest() {
  local json digest
  command -v quota-axi >/dev/null 2>&1 || { printf 'unavailable'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unavailable'; return 0; }
  json=$(quota-axi --json 2>/dev/null </dev/null) || { printf 'unavailable'; return 0; }
  digest=$(printf '%s' "$json" | jq -r '
    [ .providers[]? as $p | $p.windows[]? | "\($p.provider)/\(.id)=\(.percentUsed)" ]
    | join(" ")
  ' 2>/dev/null) || digest=
  [ -n "$digest" ] || { printf 'unavailable'; return 0; }
  one_line "$digest" || { printf 'unavailable'; return 0; }
  printf '%s' "$digest"
}

# Per-window percentage-point movement between two digests, for the windows
# present in both. Anything not comparable is simply omitted.
quota_delta() {  # <bedtime-digest> <wake-digest>
  local bedtime=$1 wake=$2
  [ "$bedtime" != unavailable ] && [ "$wake" != unavailable ] || { printf 'not comparable'; return 0; }
  awk -v bedtime="$bedtime" -v wake="$wake" '
    BEGIN {
      n = split(bedtime, b, " ")
      for (i = 1; i <= n; i++) {
        split(b[i], kv, "=")
        before[kv[1]] = kv[2]
      }
      m = split(wake, w, " ")
      out = ""
      for (i = 1; i <= m; i++) {
        split(w[i], kv, "=")
        if (!(kv[1] in before)) continue
        d = kv[2] - before[kv[1]]
        sign = (d >= 0) ? "+" : ""
        out = out (out == "" ? "" : " ") kv[1] " " sign d "pp"
      }
      print (out == "" ? "not comparable" : out)
    }
  '
}

# --- fleet reads ------------------------------------------------------------

# The ready set, one id per line, straight from the selector. Rows belong to the
# `ready[...]` group only; the id shape guard keeps a wrapped title line from
# being mistaken for an id.
ready_ids() {
  (cd "$FM_HOME" && tasks-axi ready 2>/dev/null) | awk '
    /^ready\[[0-9]+\]\{/ { inblock = 1; next }
    inblock && /^[^ ]/ { inblock = 0 }
    inblock && /^  / {
      line = $0
      sub(/^  +/, "", line)
      sub(/,.*/, "", line)
      if (line ~ /^[A-Za-z0-9._-]+$/) print line
    }
  '
}

# Live ship/scout endpoints recorded in this home. Counting stops at the cap
# because the poll goes silent at or above it either way, which bounds the
# number of backend queries this check makes inside FM_CHECK_TIMEOUT.
running_count() {  # <cap>
  local cap=$1 meta id kind window target backend count=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    case "${kind:-ship}" in
      ship|scout) ;;
      *) continue ;;
    esac
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    id=$(basename "$meta" .meta)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      count=$((count + 1))
      [ "$count" -lt "$cap" ] || break
    fi
  done
  printf '%s' "$count"
}

# --- commands ---------------------------------------------------------------

write_check_shim() {
  local tmp
  umask 077
  tmp=$(mktemp "$STATE/.fm-night-check.XXXXXX") || return 1
  cat > "$tmp" <<EOF || { rm -f -- "$tmp"; return 1; }
#!/usr/bin/env bash
# Generated by fm-night-check.sh arm. Re-arm to change it; editing this file
# breaks its registration and the watcher will refuse to run it.
FM_HOME=$(printf '%q' "$FM_HOME") exec $(printf '%q' "$SCRIPT_DIR/fm-night-check.sh") poll
EOF
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CHECK" || { rm -f -- "$tmp"; return 1; }
}

command_arm() {
  local budget='' cap=$DEFAULT_CAP quota
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --budget) shift; budget=${1:-} ;;
      --cap) shift; cap=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  positive_int "$budget" || fail "--budget must be a positive integer"
  positive_int "$cap" || fail "--cap must be a positive integer"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable: $STATE"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required to read the ready queue"

  quota=$(quota_digest)
  rm -f -- "$SIGNATURE"
  rm -f -- "$RECORD"
  record_write \
    "armed_at=$(now_iso)" \
    "budget=$budget" \
    "cap=$cap" \
    dispatched=0 \
    failures=0 \
    consecutive_failures=0 \
    landed=0 \
    parked=0 \
    stopped= \
    "quota_bedtime=$quota" \
    || fail "could not write the night record"
  write_check_shim || fail "could not write the night check"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$NIGHT_ID" >/dev/null \
    || { rm -f -- "$CHECK"; fail "could not register the night check"; }
  log_append armed '' "budget=$budget cap=$cap"
  printf 'armed: night budget %s, cap %s, quota at bedtime %s\n' "$budget" "$cap" "$quota"
}

# The one line the watcher turns into a wake. Silence is the default and the
# safe direction: it means "nothing for firstmate to do about the queue".
command_poll() {
  local cap budget dispatched left ready ready_count running signature previous
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  record_exists || return 0
  [ -z "$(record_get stopped)" ] || return 0

  budget=$(record_get_int budget)
  dispatched=$(record_get_int dispatched)
  left=$((budget - dispatched))
  [ "$left" -gt 0 ] || return 0

  cap=$(record_get_int cap)
  [ "$cap" -gt 0 ] || cap=$DEFAULT_CAP

  if ! command -v tasks-axi >/dev/null 2>&1; then
    record_write "stopped=tasks-axi is unavailable, so the ready queue cannot be read" || return 0
    printf 'night: stopped - the ready queue cannot be read\n'
    return 0
  fi

  running=$(running_count "$cap")
  [ "$running" -lt "$cap" ] || return 0

  ready=$(ready_ids | LC_ALL=C sort -u)
  [ -n "$ready" ] || return 0
  ready_count=$(printf '%s\n' "$ready" | grep -c '')

  signature=$(sha256_text "$(printf '%s\n---\n%s' "$ready" "$running")") || return 0
  previous=$(cat "$SIGNATURE" 2>/dev/null || true)
  [ "$signature" != "$previous" ] || return 0

  umask 077
  printf '%s\n' "$signature" > "$SIGNATURE" || return 0
  printf 'night: %s ready, %s running, %s dispatches left\n' "$ready_count" "$running" "$left"
}

command_record() {
  local event=${1:-} task=${2:-} reason=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$event" in
    dispatched|failed|landed|parked) ;;
    *) fail "event must be one of dispatched, failed, landed, parked" ;;
  esac
  case "$task" in
    ''|*[!A-Za-z0-9._-]*) fail "task id must be a privacy-safe slug: $task" ;;
  esac
  one_line "$reason" || fail "--reason must be one line"
  record_exists || fail "no night is armed in $FM_HOME"

  local dispatched failures consecutive landed parked stopped
  dispatched=$(record_get_int dispatched)
  failures=$(record_get_int failures)
  consecutive=$(record_get_int consecutive_failures)
  landed=$(record_get_int landed)
  parked=$(record_get_int parked)
  stopped=$(record_get stopped)

  case "$event" in
    dispatched) dispatched=$((dispatched + 1)) ;;
    failed)
      failures=$((failures + 1))
      consecutive=$((consecutive + 1))
      if [ "$consecutive" -ge "$MAX_CONSECUTIVE_FAILURES" ] && [ -z "$stopped" ]; then
        stopped="$MAX_CONSECUTIVE_FAILURES dispatches failed in a row"
      fi
      ;;
    landed) landed=$((landed + 1)); consecutive=0 ;;
    parked) parked=$((parked + 1)) ;;
  esac

  record_write \
    "dispatched=$dispatched" \
    "failures=$failures" \
    "consecutive_failures=$consecutive" \
    "landed=$landed" \
    "parked=$parked" \
    "stopped=$stopped" \
    || fail "could not update the night record"
  log_append "$event" "$task" "$reason"
  if [ -n "$stopped" ]; then
    printf 'recorded: %s %s (dispatching stopped: %s)\n' "$event" "$task" "$stopped"
  else
    printf 'recorded: %s %s\n' "$event" "$task"
  fi
}

command_status() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  record_exists || fail "no night is armed in $FM_HOME"
  local budget dispatched stopped armed=absent
  budget=$(record_get_int budget)
  dispatched=$(record_get_int dispatched)
  stopped=$(record_get stopped)
  [ ! -f "$CHECK" ] || armed=present
  printf 'armed_at=%s\n' "$(record_get armed_at)"
  printf 'check=%s\n' "$armed"
  printf 'budget=%s\n' "$budget"
  printf 'dispatched=%s\n' "$dispatched"
  printf 'dispatches_left=%s\n' "$((budget - dispatched))"
  printf 'cap=%s\n' "$(record_get_int cap)"
  printf 'landed=%s\n' "$(record_get_int landed)"
  printf 'parked=%s\n' "$(record_get_int parked)"
  printf 'failed=%s\n' "$(record_get_int failures)"
  printf 'consecutive_failures=%s\n' "$(record_get_int consecutive_failures)"
  printf 'stopped=%s\n' "${stopped:--}"
}

# One event class rendered as "- id (reason)" entries, or "none".
ledger_items() {  # <event>
  local event=$1 out
  out=$(awk -F'\t' -v want="$event" '
    $2 == want && $3 != "" {
      if ($4 == "") printf "%s%s", (n++ ? ", " : ""), $3
      else printf "%s%s (%s)", (n++ ? ", " : ""), $3, $4
    }
    END { if (!n) printf "none" }
  ' "$LOG" 2>/dev/null) || out=
  printf '%s' "${out:-none}"
}

command_ledger() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  record_exists || fail "no night is armed in $FM_HOME"
  local bedtime wake stopped
  bedtime=$(record_get quota_bedtime)
  [ -n "$bedtime" ] || bedtime=unavailable
  wake=$(quota_digest)
  stopped=$(record_get stopped)
  printf '### Night ledger - armed %s\n\n' "$(record_get armed_at)"
  printf -- '- Dispatched: %s of %s budgeted - %s\n' \
    "$(record_get_int dispatched)" "$(record_get_int budget)" "$(ledger_items dispatched)"
  printf -- '- Landed: %s - %s\n' "$(record_get_int landed)" "$(ledger_items landed)"
  printf -- '- Parked for the captain: %s - %s\n' "$(record_get_int parked)" "$(ledger_items parked)"
  printf -- '- Failed: %s - %s\n' "$(record_get_int failures)" "$(ledger_items failed)"
  printf -- '- Dispatching stopped early: %s\n' "${stopped:-no}"
  printf -- '- Quota at bedtime: %s\n' "$bedtime"
  printf -- '- Quota at wake: %s\n' "$wake"
  printf -- '- Quota delta: %s\n' "$(quota_delta "$bedtime" "$wake")"
}

command_disarm() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  rm -f -- "$CHECK" "$TRUST" "$SIGNATURE"
  if record_exists; then
    log_append disarmed '' ''
  fi
  printf 'disarmed: the night check is removed; the night record remains for the ledger\n'
}

case "${1:-}" in
  arm) shift; command_arm "$@" ;;
  poll)
    shift
    # Sourced lazily so `arm`, `record`, and `ledger` do not pay for the backend
    # library, and so a poll in a half-updated tree stays silent rather than
    # erroring into the watcher.
    # shellcheck source=bin/fm-backend.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-backend.sh" || exit 0
    command_poll "$@"
    ;;
  record) shift; command_record "$@" ;;
  status) shift; command_status "$@" ;;
  ledger) shift; command_ledger "$@" ;;
  disarm) shift; command_disarm "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

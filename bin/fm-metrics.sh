#!/usr/bin/env bash
# fm-metrics.sh - the delivery metrics log and the fleet-level read of it.
# Usage:
#   fm-metrics.sh append --project <name> --task-id <id> --kind <ship|scout>
#                        --dispatched <ts> [--pr-opened <ts>] [--merged <ts>]
#                        [--captain-msgs <n>] [--escalations <n>]
#                        [--escalation-types <a;b>] [--rework <0|1>] [--date <YYYY-MM-DD>]
#   fm-metrics.sh rework <task-id>
#   fm-metrics.sh summarize [--since <YYYY-MM-DD>]
#   fm-metrics.sh -h | --help
#
# WHY: the captain's time is the scarce resource, and today nobody can see where
# it goes. This log exists to answer one question - which interruptions should be
# automated away next - so the escalation-type histogram is the number that
# matters, not the row count. [`docs/spec-workflow.md`](../docs/spec-workflow.md)
# Section E owns the convention; this header owns the exact commands, flags, and
# file format.
#
# FILE: `data/metrics.csv` under the active FM_HOME. `data/` is gitignored as a
# whole, so this file is never committed. This script never reads or writes
# anything under `projects/`.
#
# Header, exactly:
#   date,project,task_id,kind,dispatched,pr_opened,merged,captain_msgs,escalations,escalation_types,rework_48h
#
# ONE HOME WRITES ONE FILE. Every home - this one and each second mate - appends
# only to its own file. That keeps writes local and needs no cross-home locking.
# Reading is the opposite: `summarize` in the MAIN home is the only fleet-level
# read, because a per-home summarize would report one home's numbers as the
# fleet's, and a wrong number that looks right is worse than no number.
#
# append     writes one row for a completed task. It creates the file with its
#            header when absent, refuses a second row for a task id already
#            present, and refuses a malformed escalation type. Timestamps are
#            ISO-8601 UTC (`YYYY-MM-DDTHH:MM:SSZ`); `pr_opened` and `merged` may
#            be empty, because a local-only task never has a PR.
#            escalation_types is semicolon-joined from exactly:
#            decision, blocker, credential, merge, destructive, other.
# rework     sets rework_48h to 1 on an existing row. Whether a follow-up fix
#            landed within 48h is only knowable after the fact, so it is
#            corrected retroactively rather than guessed at append time.
# summarize  reads this home's file plus every second mate home's file resolved
#            from `data/secondmates.md`, and reports per home AND in total:
#            tasks completed, median hours from dispatch to merge, captain
#            messages per task, and the escalation-type histogram.
#            A home whose file is missing is reported as "no rows" - never
#            silently skipped, and never counted as zero work, because those
#            mean different things. A remote second mate's file lives on another
#            host and is reported as "not readable from here (remote route)" for
#            the same reason.
#
# Exit status:
#   0  success
#   1  refused: duplicate task id, unknown task id, malformed field, or an
#      unreadable metrics file
#   2  usage error
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

SELF=fm-metrics
HEADER='date,project,task_id,kind,dispatched,pr_opened,merged,captain_msgs,escalations,escalation_types,rework_48h'
ESCALATION_TYPES='decision blocker credential merge destructive other'

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message...>
  local code=$1
  shift
  case "$code" in
    ''|*[!0-9]*) code=2 ;;
  esac
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

metrics_file_for_home() {  # <home>
  printf '%s/data/metrics.csv' "$1"
}

METRICS="${FM_METRICS_FILE_OVERRIDE:-$DATA/metrics.csv}"

# --- field validation --------------------------------------------------------

require_plain() {  # <value> <field>
  case "$1" in
    *,*) die 1 "$2 must not contain a comma; this file is plain CSV with no quoting (got '$1')" ;;
    *$'\n'*|*$'\r'*) die 1 "$2 must be a single line (got '$1')" ;;
  esac
}

require_date() {  # <value> <field>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die 1 "$2 must be YYYY-MM-DD (got '$1')" ;;
  esac
}

require_timestamp() {  # <value> <field> <required|optional>
  if [ -z "$1" ]; then
    [ "$3" = optional ] || die 1 "$2 is required"
    return 0
  fi
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) die 1 "$2 must be ISO-8601 UTC like 2026-08-07T14:03:00Z (got '$1')" ;;
  esac
}

require_count() {  # <value> <field>
  case "$1" in
    ''|*[!0-9]*) die 1 "$2 must be a whole number (got '$1')" ;;
  esac
}

require_escalation_types() {  # <value>
  local field known
  [ -n "$1" ] || return 0
  IFS=';' read -r -a _types <<< "$1"
  for field in "${_types[@]}"; do
    [ -n "$field" ] || die 1 "escalation_types has an empty entry; join them with a single ';' (got '$1')"
    known=0
    for t in $ESCALATION_TYPES; do
      [ "$field" = "$t" ] && { known=1; break; }
    done
    [ "$known" -eq 1 ] \
      || die 1 "escalation_types entry '$field' is not one of: $(printf '%s' "$ESCALATION_TYPES" | tr ' ' ',')"
  done
}

# --- append ------------------------------------------------------------------

command_append() {
  local project='' task_id='' kind='' dispatched='' pr_opened='' merged=''
  local captain_msgs=0 escalations=0 escalation_types='' rework=0 row_date=''

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) [ "$#" -ge 2 ] || die 2 "--project needs a value"; project=$2; shift 2 ;;
      --task-id) [ "$#" -ge 2 ] || die 2 "--task-id needs a value"; task_id=$2; shift 2 ;;
      --kind) [ "$#" -ge 2 ] || die 2 "--kind needs a value"; kind=$2; shift 2 ;;
      --dispatched) [ "$#" -ge 2 ] || die 2 "--dispatched needs a value"; dispatched=$2; shift 2 ;;
      --pr-opened) [ "$#" -ge 2 ] || die 2 "--pr-opened needs a value"; pr_opened=$2; shift 2 ;;
      --merged) [ "$#" -ge 2 ] || die 2 "--merged needs a value"; merged=$2; shift 2 ;;
      --captain-msgs) [ "$#" -ge 2 ] || die 2 "--captain-msgs needs a value"; captain_msgs=$2; shift 2 ;;
      --escalations) [ "$#" -ge 2 ] || die 2 "--escalations needs a value"; escalations=$2; shift 2 ;;
      --escalation-types) [ "$#" -ge 2 ] || die 2 "--escalation-types needs a value"; escalation_types=$2; shift 2 ;;
      --rework) [ "$#" -ge 2 ] || die 2 "--rework needs a value"; rework=$2; shift 2 ;;
      --date) [ "$#" -ge 2 ] || die 2 "--date needs a value"; row_date=$2; shift 2 ;;
      *) die 2 "unknown argument '$1' for append (see --help)" ;;
    esac
  done

  [ -n "$project" ] || die 2 "--project is required"
  [ -n "$task_id" ] || die 2 "--task-id is required"
  [ -n "$kind" ] || die 2 "--kind is required"
  case "$kind" in
    ship|scout) ;;
    *) die 1 "--kind must be ship or scout (got '$kind')" ;;
  esac
  [ -n "$row_date" ] || row_date=$(date -u +%Y-%m-%d)

  require_plain "$project" project
  require_plain "$task_id" task_id
  require_plain "$escalation_types" escalation_types
  require_date "$row_date" date
  require_timestamp "$dispatched" dispatched required
  require_timestamp "$pr_opened" pr_opened optional
  require_timestamp "$merged" merged optional
  require_count "$captain_msgs" captain_msgs
  require_count "$escalations" escalations
  require_escalation_types "$escalation_types"
  case "$rework" in
    0|1) ;;
    *) die 1 "--rework must be 0 or 1 (got '$rework')" ;;
  esac

  ensure_file
  if row_for_task "$task_id" >/dev/null; then
    die 1 "task_id '$task_id' already has a row in $METRICS; one completed task is one row. Use 'rework $task_id' to correct it"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$row_date" "$project" "$task_id" "$kind" "$dispatched" "$pr_opened" \
    "$merged" "$captain_msgs" "$escalations" "$escalation_types" "$rework" \
    >> "$METRICS" \
    || die 1 "could not append to $METRICS"
  printf '%s: recorded %s in %s\n' "$SELF" "$task_id" "$METRICS"
}

ensure_file() {
  local dir
  dir=$(dirname "$METRICS")
  mkdir -p "$dir" || die 1 "could not create $dir"
  if [ ! -e "$METRICS" ]; then
    printf '%s\n' "$HEADER" > "$METRICS" || die 1 "could not create $METRICS"
    return 0
  fi
  [ -r "$METRICS" ] && [ -w "$METRICS" ] || die 1 "$METRICS is not readable and writable"
  head -1 "$METRICS" | grep -qxF "$HEADER" \
    || die 1 "$METRICS does not start with the expected header; refusing to append to a file this script did not write"
}

row_for_task() {  # <task-id>; prints the row when present
  [ -f "$METRICS" ] || return 1
  awk -F, -v id="$1" 'NR > 1 && $3 == id { print; found = 1 } END { exit !found }' "$METRICS"
}

# --- rework ------------------------------------------------------------------

command_rework() {
  local task_id=${1:-}
  shift || true
  [ -n "$task_id" ] || die 2 "rework needs a task id"
  [ "$#" -eq 0 ] || die 2 "rework takes only a task id"
  [ -f "$METRICS" ] || die 1 "no metrics file at $METRICS"
  row_for_task "$task_id" >/dev/null \
    || die 1 "no row for task_id '$task_id' in $METRICS; rework corrects an existing row, it never creates one"

  local tmp
  tmp="$METRICS.tmp.$$"
  awk -F, -v OFS=, -v id="$task_id" '
    NR == 1 { print; next }
    $3 == id { $11 = 1 }
    { print }
  ' "$METRICS" > "$tmp" || { rm -f "$tmp"; die 1 "could not rewrite $METRICS"; }
  mv -f "$tmp" "$METRICS" || { rm -f "$tmp"; die 1 "could not replace $METRICS"; }
  printf '%s: marked %s as reworked within 48h\n' "$SELF" "$task_id"
}

# --- summarize ---------------------------------------------------------------

# One awk program shared by every home so the per-home and total numbers are
# computed identically. Emits "key<TAB>value" lines.
summarize_awk() {  # <since> ; reads CSV on stdin
  awk -F, -v since="$1" '
    function days_from_civil(y, m, d,   era, yoe, doy, doe) {
      y -= (m <= 2)
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return era * 146097 + doe - 719468
    }
    function iso_epoch(ts,   y, m, d, hh, mm, ss) {
      if (ts !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/) return -1
      y = substr(ts, 1, 4) + 0; m = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
      hh = substr(ts, 12, 2) + 0; mm = substr(ts, 15, 2) + 0; ss = substr(ts, 18, 2) + 0
      return days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss
    }
    NR == 1 { next }
    $0 ~ /^[[:space:]]*$/ { next }
    {
      if (since != "" && $1 < since) next
      tasks++
      msgs += $8
      if ($5 != "" && $7 != "") {
        a = iso_epoch($5); b = iso_epoch($7)
        if (a >= 0 && b >= 0 && b >= a) durations[++n] = (b - a) / 3600.0
      }
      if ($10 != "") {
        split($10, parts, ";")
        for (i in parts) if (parts[i] != "") hist[parts[i]]++
      }
      if ($11 == 1) rework++
    }
    END {
      printf "tasks\t%d\n", tasks
      printf "captain_msgs\t%d\n", msgs
      printf "rework\t%d\n", rework
      if (n > 0) {
        for (i = 1; i <= n; i++)
          for (j = i + 1; j <= n; j++)
            if (durations[j] < durations[i]) { t = durations[i]; durations[i] = durations[j]; durations[j] = t }
        if (n % 2) med = durations[(n + 1) / 2]
        else med = (durations[n / 2] + durations[n / 2 + 1]) / 2
        printf "median_hours\t%.1f\n", med
      } else {
        printf "median_hours\t-\n"
      }
      for (k in hist) printf "esc\t%s\t%d\n", k, hist[k]
    }
  '
}

report_home() {  # <label> <metrics-file> <since> <accumulator-file>
  local label=$1 file=$2 since=$3 accum=$4 out
  if [ ! -e "$file" ]; then
    printf '%s: no rows (no %s)\n' "$label" "$file"
    return 0
  fi
  if [ ! -r "$file" ]; then
    printf '%s: not readable (%s)\n' "$label" "$file"
    return 0
  fi
  out=$(summarize_awk "$since" < "$file")
  print_block "$label" "$out"
  # Feed the same rows into the fleet accumulator so the total is computed from
  # rows, never by adding medians together.
  tail -n +2 "$file" >> "$accum"
}

print_block() {  # <label> <awk-output>
  local label=$1 out=$2 tasks msgs median rework per
  tasks=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "tasks" { print $2 }')
  msgs=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "captain_msgs" { print $2 }')
  median=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "median_hours" { print $2 }')
  rework=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "rework" { print $2 }')
  if [ "${tasks:-0}" -eq 0 ]; then
    printf '%s: no rows\n' "$label"
    return 0
  fi
  per=$(awk -v m="${msgs:-0}" -v t="$tasks" 'BEGIN { printf "%.1f", m / t }')
  printf '%s: tasks=%s median_hours_dispatch_to_merge=%s captain_msgs_per_task=%s rework_48h=%s\n' \
    "$label" "$tasks" "$median" "$per" "${rework:-0}"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "esc" { printf "  escalation %s: %s\n", $2, $3 }' | LC_ALL=C sort
}

command_summarize() {
  local since=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) [ "$#" -ge 2 ] || die 2 "--since needs a value"; since=$2; shift 2 ;;
      --since=*) since=${1#--since=}; shift ;;
      *) die 2 "unknown argument '$1' for summarize (see --help)" ;;
    esac
  done
  [ -z "$since" ] || require_date "$since" --since

  local accum
  accum=$(mktemp "${TMPDIR:-/tmp}/fm-metrics-accum.XXXXXX") || die 1 "could not create a temporary file"
  # shellcheck disable=SC2064 # expand the path now: it is the file to clean up.
  trap "rm -f '$accum'" EXIT

  printf '%s\n' "metrics${since:+ since $since}"
  report_home "main ($FM_HOME)" "$METRICS" "$since" "$accum"

  local registry line id home
  registry="$DATA/secondmates.md"
  if [ -f "$registry" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '- '*) ;;
        *) continue ;;
      esac
      secondmate_registry_parse_line "$line" || continue
      id=$SECONDMATE_REGISTRY_ID
      [ -n "$id" ] || continue
      if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
        printf '%s: not readable from here (remote route on %s)\n' \
          "$id" "$SECONDMATE_REGISTRY_HOST"
        continue
      fi
      home=$SECONDMATE_REGISTRY_HOME
      [ -n "$home" ] || continue
      report_home "$id ($home)" "$(metrics_file_for_home "$home")" "$since" "$accum"
    done < "$registry"
  fi

  if [ -s "$accum" ]; then
    print_block "FLEET TOTAL" "$( { printf '%s\n' "$HEADER"; cat "$accum"; } | summarize_awk "$since")"
  else
    printf 'FLEET TOTAL: no rows\n'
  fi
}

case "${1:-}" in
  append) shift; command_append "$@" ;;
  rework) shift; command_rework "$@" ;;
  summarize) shift; command_summarize "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

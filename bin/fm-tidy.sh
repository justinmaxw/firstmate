#!/usr/bin/env bash
# Remove expired private operational records for one Firstmate home.
# Usage: fm-tidy.sh [--dry-run] [--quiet]
#
# --dry-run prints the same removal and move records a real run would perform.
# --quiet suppresses per-path records and prints one BOOTSTRAP_INFO summary when
# work was performed.  Bootstrap uses it only while the fleet lock is held.
# This script never touches projects/, live task records, unresolved pending
# replies, unhandled process results, leased treehouse slots, or symlink targets.
# Stderr diagnostics (printed even with --quiet, never counted as work):
#   "TIDY: skipped ambiguous <path>" - an input it could not classify safely,
#     left in place until someone resolves it by hand;
#   "TIDY: orphaned treehouse pool: <detail>" and
#   "TIDY: stale git worktree registration: <detail>" - diagnosis only, never
#     removed here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DRY_RUN=0
QUIET=0
NOW="${FM_TIDY_NOW:-$(date +%s)}"

case "$NOW" in ''|*[!0-9]*) echo 'error: FM_TIDY_NOW must be an epoch' >&2; exit 2 ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --quiet) QUIET=1 ;;
    --help) head -9 "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

removed_watcher=0
removed_pending=0
removed_results=0
moved_reports=0
removed_scratch=0
skipped=0

say_action() {
  [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"
}
skip() {
  skipped=$((skipped + 1))
  printf 'TIDY: skipped ambiguous %s\n' "$1" >&2
}
path_is_safe_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}
if [ "$(uname)" = Darwin ]; then
  mtime() { stat -f %m "$1" 2>/dev/null; }
else
  mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
older_than() { # path seconds
  local when age
  when=$(mtime "$1") || return 1
  case "$when" in ''|*[!0-9]*) return 1 ;; esac
  age=$((NOW - when))
  [ "$age" -gt "$2" ]
}
meta_has_worktree() { # exact path or child path is owned by a live task
  local slot=$1 meta wt
  for meta in "$STATE"/*.meta; do
    path_is_safe_file "$meta" || continue
    wt=$(grep '^worktree=' "$meta" 2>/dev/null | head -1 | cut -d= -f2-)
    case "$wt" in "$slot"|"$slot"/*) return 0 ;; esac
  done
  return 1
}

# Live ids and normalized window keys are the only identities this cleanup may
# recognize. Unknown marker shapes are deliberately left alone.
is_live_watcher_marker() { # basename
  local name=$1 meta id window key seen_status seen_turn
  for meta in "$STATE"/*.meta; do
    path_is_safe_file "$meta" || continue
    id=$(basename "$meta" .meta)
    window=$(grep '^window=' "$meta" 2>/dev/null | head -1 | cut -d= -f2-)
    key=$(printf '%s' "$window" | tr ':/.' '___')
    seen_status=$(printf '%s.status' "$id" | tr '.' '_')
    seen_turn=$(printf '%s.turn-ended' "$id" | tr '.' '_')
    case "$name" in
      .hb-surfaced-"$id"|.seen-"$seen_status"|.seen-"$seen_turn") return 0 ;;
      .hash-"$key"|.count-"$key"|.stale-since-"$key"|.stale-"$key"|.seen-"$key"|.paused-"$key"|.wedge-escalations-"$key") return 0 ;;
      *-"$id"|*-"$key") return 0 ;;
    esac
  done
  return 1
}
watcher_marker_identity_is_known() { # basename
  case "$1" in
    .hash-*|.count-*|.stale-since-*|.stale-*|.seen-*|.hb-surfaced-*|.paused-*|.wedge-escalations-*) return 0 ;;
    *) return 1 ;;
  esac
}
remove_file() { # category path display
  local category=$1 path=$2 display=$3
  say_action "remove: $display"
  [ "$DRY_RUN" -eq 1 ] || rm -f -- "$path"
  case "$category" in
    watcher) removed_watcher=$((removed_watcher + 1)) ;;
    pending) removed_pending=$((removed_pending + 1)) ;;
    result) removed_results=$((removed_results + 1)) ;;
  esac
}

# 1. Watcher records.
for rec in "$STATE"/.hash-* "$STATE"/.count-* "$STATE"/.stale-* \
  "$STATE"/.seen-* "$STATE"/.hb-surfaced-* "$STATE"/.paused-* "$STATE"/.wedge-escalations-*; do
  [ -e "$rec" ] || continue
  path_is_safe_file "$rec" || { skip "$rec"; continue; }
  name=$(basename "$rec")
  is_live_watcher_marker "$name" && continue
  watcher_marker_identity_is_known "$name" || { skip "$rec"; continue; }
  # procevent uses .seen-procevent-<hex>, which does not identify a task/window.
  case "$name" in .seen-procevent-*) continue ;; esac
  remove_file watcher "$rec" "$rec"
done

# 2. Resolved secondmate replies, with the record's own resolution timestamp.
for rec in "$STATE"/pending-replies/*; do
  [ -e "$rec" ] || continue
  path_is_safe_file "$rec" || { skip "$rec"; continue; }
  phase=$(grep '^phase=' "$rec" 2>/dev/null | head -1 | cut -d= -f2-)
  [ "$phase" = resolved ] || continue
  task_id=$(grep '^task_id=' "$rec" 2>/dev/null | head -1 | cut -d= -f2-)
  [ -z "$task_id" ] || [ ! -e "$STATE/$task_id.meta" ] || continue
  resolved=$(grep '^resolved_epoch=' "$rec" 2>/dev/null | head -1 | cut -d= -f2-)
  case "$resolved" in ''|*[!0-9]*) skip "$rec"; continue ;; esac
  [ $((NOW - resolved)) -gt $((7 * 86400)) ] || continue
  remove_file pending "$rec" "$rec"
done

# 3. Process results are removable only with their old handled acknowledgement.
for marker in "$STATE"/procevent-inbox/*.handled; do
  [ -e "$marker" ] || continue
  path_is_safe_file "$marker" || { skip "$marker"; continue; }
  older_than "$marker" $((30 * 86400)) || continue
  result=${marker%.handled}.result
  adapter=${marker%.handled}.adapter
  if ! path_is_safe_file "$result" || ! path_is_safe_file "$adapter"; then
    skip "$marker"
    continue
  fi
  say_action "remove: $result"
  [ "$DRY_RUN" -eq 1 ] || rm -f -- "$result" "$adapter" "$marker"
  removed_results=$((removed_results + 1))
done

# 4. Archive old reports that are not live, referenced, or request data.
# A report is protected while any current data note references it: backlog.md
# through its open items, every other data/*.md through any mention. Only
# done-archive.md references never protect and are rewritten after the move.
report_is_referenced() {
  local id=$1 note
  for note in "$DATA"/*.md; do
    path_is_safe_file "$note" || continue
    case "$(basename "$note")" in
      done-archive.md) continue ;;
      backlog.md)
        grep -Eq "^- \[ \].*(^|[^[:alnum:]_-])$id([^[:alnum:]_-]|$)" "$note" 2>/dev/null && return 0 ;;
      *)
        grep -Eq "(^|[^[:alnum:]_-])$id([^[:alnum:]_-]|$)" "$note" 2>/dev/null && return 0 ;;
    esac
  done
  return 1
}
report_is_stale() { # newest non-symlink file inside is older than 30 days
  local dir=$1 newest=0 when f
  while IFS= read -r -d '' f; do
    when=$(mtime "$f")
    case "$when" in ''|*[!0-9]*) return 1 ;; esac
    [ "$when" -le "$newest" ] || newest=$when
  done < <(find "$dir" -type f -print0 2>/dev/null)
  [ "$newest" -gt 0 ] || return 1
  [ $((NOW - newest)) -gt $((30 * 86400)) ]
}
archive_report() {
  local dir=$1 id=$2 dest tmp
  dest="$DATA/archive/$id"
  [ ! -e "$dest" ] || { skip "$dir (archive destination exists)"; return; }
  [ ! -L "$DATA/done-archive.md" ] || { skip "$DATA/done-archive.md"; return; }
  [ -d "$DATA/archive" ] && [ ! -L "$DATA/archive" ] || {
    if [ -e "$DATA/archive" ]; then skip "$DATA/archive"; return; fi
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$DATA/archive" || { skip "$DATA/archive"; return; }
  }
  say_action "move: $dir -> $dest"
  if [ "$DRY_RUN" -eq 0 ]; then
    mv -- "$dir" "$dest" || { skip "$dir"; return; }
    if [ -f "$DATA/done-archive.md" ] && [ ! -L "$DATA/done-archive.md" ]; then
      tmp=$(mktemp "$DATA/.done-archive.XXXXXX") || { skip "$DATA/done-archive.md"; return; }
      if ! awk -v old="data/""$id""/" -v new="data/archive/""$id""/" '{ gsub(old, new); print }' "$DATA/done-archive.md" > "$tmp"; then
        rm -f "$tmp"
      elif ! mv -- "$tmp" "$DATA/done-archive.md"; then
        rm -f "$tmp"
      fi
    fi
  fi
  moved_reports=$((moved_reports + 1))
}
for dir in "$DATA"/*; do
  [ -d "$dir" ] || continue
  [ ! -L "$dir" ] || { skip "$dir"; continue; }
  id=$(basename "$dir")
  case "$id" in archive|*-requests) continue ;; esac
  [ -f "$dir/report.md" ] && [ ! -L "$dir/report.md" ] || continue
  case "$id" in *[!A-Za-z0-9._-]*) skip "$dir"; continue ;; esac
  [ ! -e "$STATE/$id.meta" ] || continue
  report_is_referenced "$id" && continue
  report_is_stale "$dir" || continue
  archive_report "$dir" "$id"
done

# 5. Treehouse may describe the slot authoritatively. Only available (unleased
# and process-free) slots are considered, and git itself selects untracked files.
if command -v treehouse >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  slots=$(treehouse status --json 2>/dev/null) || slots=
  if [ -n "$slots" ] && printf '%s' "$slots" | jq -e 'type == "array"' >/dev/null 2>&1; then
    while IFS= read -r slot; do
      [ -d "$slot" ] && [ ! -L "$slot" ] || { skip "$slot"; continue; }
      meta_has_worktree "$slot" && continue
      scratch=$(git -C "$slot" clean -fdn 2>/dev/null | sed -n 's/^Would remove //p') || { skip "$slot"; continue; }
      [ -n "$scratch" ] || continue
      if [ "$DRY_RUN" -eq 0 ]; then
        git -C "$slot" clean -fd >/dev/null 2>&1 || { skip "$slot"; continue; }
      fi
      while IFS= read -r item; do
        [ -n "$item" ] || continue
        say_action "remove: $slot/$item"
        removed_scratch=$((removed_scratch + 1))
      done <<EOF
$scratch
EOF
    done < <(printf '%s' "$slots" | jq -r '.[] | select(.status == "available" and (.processes | length) == 0) | .path' 2>/dev/null)
  elif [ -n "$slots" ]; then
    skip 'treehouse status'
  fi
fi

# 6. Diagnostics only. Neither command changes a pool or registration.
if command -v treehouse >/dev/null 2>&1; then
  orphan=$(cd "$FM_ROOT" && treehouse prune 2>/dev/null | grep -i orphan || true)
  [ -z "$orphan" ] || printf 'TIDY: orphaned treehouse pool: %s\n' "$orphan" >&2
fi
stale=$(git -C "$FM_ROOT" worktree prune -n 2>&1 || true)
[ -z "$stale" ] || printf 'TIDY: stale git worktree registration: %s\n' "$stale" >&2

changed=$((removed_watcher + removed_pending + removed_results + moved_reports + removed_scratch))
if [ "$QUIET" -eq 1 ] && [ "$changed" -gt 0 ]; then
  printf 'BOOTSTRAP_INFO: tidy watcher=%s pending-replies=%s procevent-results=%s reports=%s scratch=%s\n' \
    "$removed_watcher" "$removed_pending" "$removed_results" "$moved_reports" "$removed_scratch"
fi

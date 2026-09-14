#!/usr/bin/env bash
# Drives bin/fm-control.sh relaunch against a REAL isolated tmux server
# (TMUX_TMPDIR) whose task window runs a live process named `agy`, and asserts
# a disallowed/conflicting/legacy relaunch refuses while that agent stays alive.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
REAL_AGY=$(command -v agy); REAL_HOME=$HOME
T=$(mktemp -d /tmp/agy-rl.XXXX)
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
mkdir -p "$T/bin" "$T/uh/.gemini/antigravity-cli"
printf 'x\n' > "$T/uh/.gemini/antigravity-cli/jetski_state.pbtxt"
cat > "$T/bin/agy" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = models ] && HOME="$REAL_HOME" exec "$REAL_AGY" models
exec -a agy sleep 3600
SH
chmod +x "$T/bin/agy"
run_case() {  # <id> <recorded-model> <recorded-effort> <relaunch args...>
  local id=$1 model=$2 effort=$3; shift 3
  local home="$T/$id/home" proj="$T/$id/proj" wt="$T/$id/wt"
  mkdir -p "$home/state" "$home/data/$id"
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null 2>&1
  printf '# Task\n## Captain'"'"'s intent\nx\n\n## Firstmate spec\ny\n' > "$home/data/$id/brief.md"
  cp "$(command -v bash)" "$T/agy-engine-$id"; 
  tmux has-session -t fmses 2>/dev/null || tmux new-session -d -s fmses -n idle -x 200 -y 50
  tmux new-window -d -t fmses -n "fm-$id" -c "$wt" "exec -a agy $T/bin/agy"
  sleep 1
  printf 'window=fmses:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=agy\nkind=ship\nmode=no-mistakes\nyolo=off\ntasktmp=/tmp/fm-%s\nmodel=%s\neffort=%s\n' \
    "$id" "$id" "$wt" "$proj" "$id" "$model" "$effort" > "$home/state/$id.meta"
  local before_pid after_pid before_meta out rc
  before_pid=$(tmux display-message -p -t "fmses:fm-$id" '#{pane_pid} #{pane_current_command}')
  before_meta=$(cat "$home/state/$id.meta")
  out=$(env PATH="$T/bin:$PATH" FM_HOME="$home" HOME="$T/uh" FM_SPAWN_NO_GUARD=1 \
        FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=1 \
        "$ROOT/bin/fm-control.sh" "$id" relaunch "$@" --note "live refusal check" 2>&1); rc=$?
  after_pid=$(tmux display-message -p -t "fmses:fm-$id" '#{pane_pid} #{pane_current_command}' 2>&1)
  echo "=== relaunch $id (recorded model=$model effort=$effort) args: $* -> exit $rc"
  printf '%s\n' "$out" | sed 's/^/  | /'
  echo "  pane before: $before_pid   pane after: $after_pid"
  [ "$before_pid" = "$after_pid" ] && echo "  RESULT: running agent untouched" || echo "  RESULT: AGENT CHANGED"
  [ "$(cat "$home/state/$id.meta")" = "$before_meta" ] && echo "  RESULT: task meta unchanged" || echo "  RESULT: META CHANGED"
  [ -e "$home/state/$id.control-relaunch" ] && echo "  RESULT: JOURNAL LEFT" || echo "  RESULT: no relaunch journal"
}
run_case rl38 gemini-3.7-flash-medium medium --model gemini-3.8-flash-high
run_case rlpro gemini-3.7-flash-medium medium --model gemini-3.1-pro-high
run_case rlconf gemini-3.7-flash-medium medium --model gemini-3.7-flash-low --effort high
run_case rllegacy gemini-3.7-flash medium
run_case rlxhigh gemini-3.7-flash-medium medium --effort xhigh
tmux kill-server 2>/dev/null; rm -rf "$T"

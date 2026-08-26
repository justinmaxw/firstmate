#!/usr/bin/env bash
# tests/agy-helpers.sh - shared fixtures for the agy (Antigravity CLI) adapter
# suites (fm-agy-harness, fm-spawn-agy-credential-preflight, and
# fm-spawn-agy-model-allowlist).
#
# The fake tmux stub, the fake `agy` on PATH, and the isolated $HOME that
# carries agy's credential and settings files all have to move in lockstep with
# fm-spawn's agy launch path, so they live here instead of being restated once
# per suite. The generic git/fakebin/meta primitives come from tests/lib.sh,
# which this file pulls in.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry, and agy's own
# ANTIGRAVITY_AGENT=1 is one of them. Drop every ambient marker so the verdicts
# these suites assert do not depend on which harness launched them - an agy
# crewmate runs them through a shell tool that carries ANTIGRAVITY_AGENT=1, and
# the ancestry cases would then assert the inherited marker instead.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS ANTIGRAVITY_AGENT

AGY_SPAWN="$ROOT/bin/fm-spawn.sh"
AGY_HARNESS_PROBE="$ROOT/bin/fm-harness.sh"

# The paths fm-spawn's AC-1 preflight reads, relative to the worker's $HOME.
AGY_CREDENTIAL_RELPATH='.gemini/antigravity-cli/jetski_state.pbtxt'
AGY_SETTINGS_RELPATH='.gemini/antigravity-cli/settings.json'

agy_credential_path() {  # <agyhome>
  printf '%s/%s\n' "$1" "$AGY_CREDENTIAL_RELPATH"
}

agy_settings_path() {  # <agyhome>
  printf '%s/%s\n' "$1" "$AGY_SETTINGS_RELPATH"
}

# agy_seed_credential <agyhome>: the opaque session state a completed
# interactive `agy` login persists. fm-spawn only ever tests presence and
# non-emptiness, never the contents.
agy_seed_credential() {  # <agyhome>
  printf 'opaque-session-state\n' > "$(agy_credential_path "$1")"
}

# make_agy_fakebin <dir>: a fake tmux that appends every literal `send-keys -l`
# payload to $FM_FAKE_LAUNCH_LOG and, when FM_FAKE_EXECUTE_AGY_LAUNCH=1, runs
# the agy launch payload in the pane's worktree, plus a fake `agy` on PATH.
#
# The fake `agy` is a wrapper script rather than a renamed shell because the
# generated launch hands it agy's own flags, which a bare shell rejects before
# running anything. When FM_FAKE_HARNESS_RESULT is set the wrapper re-execs
# FM_FAKE_AGY_ENGINE - a copy of bash named `agy`, so the ancestry walk sees
# agy's real process name - and records the verdict bin/fm-harness.sh reports
# from a child of it. The command substitution around the probe is
# load-bearing: a bare `-c` would let the probe exec in place and replace the
# `agy` process name the walk has to find, which is how a real agy pane looks
# (its TUI stays alive and runs tools as children).
make_agy_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        if [ "${FM_FAKE_EXECUTE_AGY_LAUNCH:-}" = 1 ]; then
          case "$arg" in
            *"$FM_FAKE_AGY_EXECUTABLE"*) (cd "$FM_FAKE_PANE_PATH" && bash -c "$arg") ;;
          esac
        fi
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  mkdir -p "$dir/engine"
  cp "$(command -v bash)" "$dir/engine/agy"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec "$FM_FAKE_AGY_ENGINE" -c 'result=$("$FM_FAKE_HARNESS_PROBE"); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
  chmod +x "$fakebin/agy"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# make_agy_case <tmproot> <name> [absent]: an isolated firstmate home, project
# worktree, fakebin, and worker $HOME carrying agy's credential directory.
# A third argument of "absent" leaves the credential file unwritten so the AC-1
# refusal cases can assert on a genuinely unauthenticated worker home.
# Echoes "<case_dir>|<home>|<proj>|<wt>|<fakebin>|<id>|<agyhome>".
make_agy_case() {  # <tmproot> <name> [absent]
  local tmproot=$1 name=$2 credential=${3:-present}
  local case_dir home proj wt fakebin id agyhome
  case_dir="$tmproot/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  agyhome="$case_dir/agyhome"
  fakebin=$(make_agy_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$agyhome/$(dirname "$AGY_CREDENTIAL_RELPATH")"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  [ "$credential" = absent ] || agy_seed_credential "$agyhome"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id|$agyhome"
}

# run_agy_spawn <home> <proj> <wt> <fakebin> <id> <agyhome> [extra args...]
# Spawns a ship on harness=agy. --mode/--yolo are supplied first so a caller
# that needs different values can override them by passing its own; every other
# extra argument is appended verbatim.
run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 agyhome=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_AGY_EXECUTABLE="$fakebin/agy" \
    FM_FAKE_AGY_ENGINE="$(dirname "$fakebin")/engine/agy" \
    FM_FAKE_HARNESS_PROBE="$AGY_HARNESS_PROBE" \
    FM_FAKE_EXECUTE_AGY_LAUNCH="${FM_FAKE_EXECUTE_AGY_LAUNCH:-}" \
    FM_FAKE_HARNESS_RESULT="${FM_FAKE_HARNESS_RESULT:-}" \
    HOME="$agyhome" \
    PATH="$fakebin:$PATH" \
    "$AGY_SPAWN" "$id" "$proj" agy --mode no-mistakes --yolo off "$@" 2>&1
}

#!/usr/bin/env bash
# Manual end-to-end demonstration of the agy (Antigravity CLI) adapter's
# raw-launch refusal and the verified launch path, driven exactly as an
# operator drives it: bin/fm-spawn.sh from a shell.
#
# The only fakes are the terminal backend (tmux) and the `agy` binary itself,
# both from tests/agy-helpers.sh - fm-spawn.sh, its refusals, its launch
# template rendering and its task metadata are the real production code.
#
# Usage: bash agy-raw-launch-e2e-demo.sh <path-to-firstmate-worktree>
set -u

REPO=${1:?usage: agy-raw-launch-e2e-demo.sh <repo-root>}
# shellcheck source=/dev/null
. "$REPO/tests/agy-helpers.sh"
TMP_ROOT=$(fm_test_tmproot agy-evidence)

hr() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
say() { printf '\n$ %s\n' "$1"; }
show_state() { # <home> <id>
  local home=$1 id=$2
  printf '\n  state/%s.meta:   ' "$id"
  if [ -f "$home/state/$id.meta" ]; then printf '\n'; sed 's/^/    /' "$home/state/$id.meta"
  else printf '(absent - no task was published)\n'; fi
  printf '  command typed into the pane: '
  if [ -s "$home/launch.log" ]; then printf '\n'; sed 's/^/    /' "$home/launch.log"
  else printf '(none - no endpoint was created)\n'; fi
}

# ---------------------------------------------------------------------------
hr 'SCENARIO 1 - raw launch command carrying a DISALLOWED model (the reported gap)'
rec=$(make_agy_case "$TMP_ROOT" raw-disallowed-model)
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
cmd="bin/fm-spawn.sh $id <project> \"agy --model gemini-3.5-pro -i 'raw brief'\" --mode no-mistakes --yolo off"
say "$cmd"
FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
  TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
  FM_FAKE_AGY_EXECUTABLE="$fakebin/agy" HOME="$agyhome" PATH="$fakebin:$PATH" \
  "$AGY_SPAWN" "$id" "$proj" "agy --model gemini-3.5-pro -i 'raw brief'" \
  --mode no-mistakes --yolo off
printf '  exit status: %s\n' "$?"
show_state "$home" "$id"

# ---------------------------------------------------------------------------
hr 'SCENARIO 2 - raw launch used to bypass the credential preflight and the GEMINI_API_KEY billing refusal'
rec=$(make_agy_case "$TMP_ROOT" raw-bypass absent)   # NO credential file on the worker host
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
printf '\n  worker $HOME credential file: %s\n' "$([ -s "$(agy_credential_path "$agyhome")" ] && echo present || echo ABSENT)"
printf '  GEMINI_API_KEY in the caller environment: set (pay-as-you-go billing)\n'
say "GEMINI_API_KEY=leaked bin/fm-spawn.sh $id <project> \"agy --model gemini-3.7-flash --effort medium -i 'raw brief'\" --mode no-mistakes --yolo off"
env GEMINI_API_KEY=leaked-key FM_ROOT_OVERRIDE='' FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
  FM_FAKE_LAUNCH_LOG="$home/launch.log" FM_FAKE_AGY_EXECUTABLE="$fakebin/agy" \
  HOME="$agyhome" PATH="$fakebin:$PATH" \
  "$AGY_SPAWN" "$id" "$proj" "agy --model gemini-3.7-flash --effort medium -i 'raw brief'" \
  --mode no-mistakes --yolo off
printf '  exit status: %s\n' "$?"
show_state "$home" "$id"

# ---------------------------------------------------------------------------
hr 'SCENARIO 3 - raw agy launch as a SECONDMATE (AC-9 still refuses first, unchanged)'
case_dir="$TMP_ROOT/raw-secondmate"; home="$case_dir/home"; agyhome="$case_dir/agyhome"
fakebin=$(make_agy_fakebin "$case_dir/fake"); id="agy-raw-secondmate-x1"
mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
  "$agyhome/$(dirname "$AGY_CREDENTIAL_RELPATH")"
printf 'charter\n' > "$home/data/$id/brief.md"; agy_seed_credential "$agyhome"
say "bin/fm-spawn.sh $id \"agy --model gemini-3.7-flash --effort medium -i 'raw charter'\" --secondmate"
FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
  HOME="$agyhome" PATH="$fakebin:$PATH" \
  "$AGY_SPAWN" "$id" "agy --model gemini-3.7-flash --effort medium -i 'raw charter'" --secondmate
printf '  exit status: %s\n' "$?"
printf '  state/%s.meta: %s\n' "$id" \
  "$([ -f "$home/state/$id.meta" ] && echo PUBLISHED || echo '(absent - no task was published)')"

# ---------------------------------------------------------------------------
hr 'SCENARIO 4 - the supported path an operator is directed to still works'
rec=$(make_agy_case "$TMP_ROOT" supported-path)
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
say "bin/fm-spawn.sh $id <project> agy --mode no-mistakes --yolo off"
run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome"
printf '  exit status: %s\n' "$?"
show_state "$home" "$id"

# ---------------------------------------------------------------------------
hr 'SCENARIO 4b - the other form the refusal names: --harness agy'
rec=$(make_agy_case "$TMP_ROOT" harness-flag)
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
say "bin/fm-spawn.sh $id <project> --harness agy --mode no-mistakes --yolo off"
FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
  TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
  FM_FAKE_AGY_EXECUTABLE="$fakebin/agy" HOME="$agyhome" PATH="$fakebin:$PATH" \
  "$AGY_SPAWN" "$id" "$proj" --harness agy --mode no-mistakes --yolo off 2>&1 \
  | grep -v '^warning:'
printf '  exit status: %s\n' "${PIPESTATUS[0]}"
show_state "$home" "$id"

# ---------------------------------------------------------------------------
hr 'SCENARIO 5 - GEMINI_API_KEY exported by the long-lived worker host, invisible to fm-spawn'
rec=$(make_agy_case "$TMP_ROOT" worker-host-key)
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
seen="$case_dir/agy-child-saw-gemini-api-key"
printf '\n  GEMINI_API_KEY in fm-spawn'"'"'s own environment: (unset - the caller-side refusal sees nothing)\n'
printf '  GEMINI_API_KEY exported by the pane-creating daemon shell: worker-host-key\n'
say "bin/fm-spawn.sh $id <project> agy --mode no-mistakes --yolo off   # launch really executed in the pane"
FM_FAKE_EXECUTE_AGY_LAUNCH=1 FM_FAKE_AGY_ENV_RESULT="$seen" \
  FM_FAKE_WORKER_GEMINI_API_KEY=worker-host-key \
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome"
printf '  exit status: %s\n' "$?"
show_state "$home" "$id"
printf "\n  GEMINI_API_KEY as the launched \`agy\` child itself saw it: '%s'\n" "$(cat "$seen" 2>/dev/null)"
[ -f "$seen" ] || printf '  (the launch never executed)\n'

# ---------------------------------------------------------------------------
hr 'SCENARIO 6 - the raw escape hatch is untouched for a genuinely UNVERIFIED adapter'
rec=$(make_agy_case "$TMP_ROOT" raw-unverified)
IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/frobnicate"; chmod +x "$fakebin/frobnicate"
say "bin/fm-spawn.sh $id <project> \"frobnicate --model anything-at-all -i 'raw brief'\" --mode no-mistakes --yolo off"
FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
  TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
  FM_FAKE_AGY_EXECUTABLE="$fakebin/agy" HOME="$agyhome" PATH="$fakebin:$PATH" \
  "$AGY_SPAWN" "$id" "$proj" "frobnicate --model anything-at-all -i 'raw brief'" \
  --mode no-mistakes --yolo off
printf '  exit status: %s\n' "$?"
show_state "$home" "$id"

printf '\n'

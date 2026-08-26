#!/usr/bin/env bash
# Before/after reproduction of the reported gap: the same two operator
# commands, run against whatever bin/fm-spawn.sh is currently checked out.
# Run once with the pre-fix script in place and once with the fixed script to
# see the bypass close.
#
# Usage: bash agy-raw-launch-before-after.sh <repo-root> <label>
set -u

REPO=${1:?usage: agy-raw-launch-before-after.sh <repo-root> <label>}
LABEL=${2:?usage: agy-raw-launch-before-after.sh <repo-root> <label>}
# shellcheck source=/dev/null
. "$REPO/tests/agy-helpers.sh"
TMP_ROOT=$(fm_test_tmproot agy-before-after)

printf '\n############ %s ############\n' "$LABEL"

spawn_raw() {  # <case-name> <raw-command> [env=val ...]
  local name=$1 raw=$2; shift 2
  local rec case_dir home proj wt fakebin id agyhome
  rec=$(make_agy_case "$TMP_ROOT" "$name")
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf '\n$ %s bin/fm-spawn.sh %s <project> "%s" --mode no-mistakes --yolo off\n' "$*" "$id" "$raw"
  env "$@" FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    TMUX="fake,1,0" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    FM_FAKE_AGY_EXECUTABLE="$fakebin/agy" HOME="$agyhome" PATH="$fakebin:$PATH" \
    "$REPO/bin/fm-spawn.sh" "$id" "$proj" "$raw" --mode no-mistakes --yolo off 2>&1 \
    | sed 's/^/  /'
  printf '  exit status: %s\n' "${PIPESTATUS[0]}"
  printf '  model recorded in state/%s.meta: %s\n' "$id" \
    "$(sed -n 's/^model=//p' "$home/state/$id.meta" 2>/dev/null || true)"
  printf '  command typed into the pane: %s\n' \
    "$(cat "$home/launch.log" 2>/dev/null || echo '(none - no endpoint was created)')"
}

spawn_raw raw-disallowed-model "agy --model gemini-3.5-pro -i 'raw brief'"
spawn_raw raw-billing "agy --model gemini-3.7-flash --effort medium -i 'raw brief'" GEMINI_API_KEY=leaked-key
printf '\n'

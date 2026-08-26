#!/usr/bin/env bash
# AC-1: harness=agy refuses before any endpoint is created when no
# worker-reachable Antigravity credential is present, rather than launching
# into an unattended interactive Google sign-in prompt. Also covers the
# captain-approved refinement that refuses a launch whose effective settings
# would permit API-key/Vertex billing or personal-credit top-ups instead of
# the Google AI Pro/Ultra subscription this pool exists to use.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agy-credential-preflight)

make_fakebin() {
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
  cp "$(command -v bash)" "$fakebin/agy"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_case() {  # <name>
  local name=$1 case_dir home proj wt fakebin id agyhome
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  agyhome="$case_dir/agyhome"
  fakebin=$(make_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$agyhome/.gemini/antigravity-cli"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id|$agyhome"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> <agyhome> [env=val...] -- [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 agyhome=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    HOME="$agyhome" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" agy --mode no-mistakes --yolo off "$@" 2>&1
}

# An unauthenticated agy pane does not exit: it sits on a browser sign-in flow
# waiting for a human who is not there, which supervision would read as a
# wedged worker rather than a missing credential. The spawn must refuse before
# an endpoint exists.
test_refuses_without_credential_file() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_case no-cred)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with no credential file present"
  assert_contains "$out" "no worker-reachable Antigravity credential" \
    "agy spawn did not name the missing credential"
  assert_absent "$home/state/$id.meta" "refused agy spawn still published task metadata"
  assert_absent "$home/launch.log" "refused agy spawn still created an endpoint"
  pass "agy spawn refuses when no credential file is present"
}

test_refuses_empty_credential_file() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_case empty-cred)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  : > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with an empty credential file"
  assert_contains "$out" "no worker-reachable Antigravity credential" \
    "agy spawn did not name the missing credential for an empty file"
  pass "agy spawn refuses when the credential file exists but is empty"
}

test_accepts_present_credential() {
  local rec case_dir home proj wt fakebin id agyhome status
  rec=$(make_case present-cred)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept a present, non-empty credential file"
  pass "agy spawn accepts a present credential file"
}

test_refuses_gemini_api_key_env() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_case api-key-env)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  out=$(GEMINI_API_KEY=leaked-key run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with GEMINI_API_KEY set"
  assert_contains "$out" "API-key/Vertex billing" \
    "agy spawn did not explain the API-key billing refusal"
  assert_not_contains "$out" "leaked-key" "agy spawn refusal leaked the API key value"
  assert_absent "$home/launch.log" "GEMINI_API_KEY refusal still created an endpoint"
  pass "agy spawn refuses when GEMINI_API_KEY is set in the launch environment"
}

test_refuses_settings_model_provider() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_case settings-provider)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  printf '{"modelProvider":"gemini"}\n' > "$agyhome/.gemini/antigravity-cli/settings.json"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with a settings.json modelProvider set"
  assert_contains "$out" "API-key/Vertex billing" \
    "agy spawn did not explain the modelProvider refusal"
  pass "agy spawn refuses when settings.json sets modelProvider"
}

test_refuses_use_g1_credits() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_case g1-credits)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  printf '{"useG1Credits":true}\n' > "$agyhome/.gemini/antigravity-cli/settings.json"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with useG1Credits=true"
  assert_contains "$out" "personal-credit top-ups" \
    "agy spawn did not explain the useG1Credits refusal"
  pass "agy spawn refuses when settings.json sets useG1Credits to true"
}

test_accepts_clean_settings_file() {
  local rec case_dir home proj wt fakebin id agyhome status
  rec=$(make_case clean-settings)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  printf '{"trustedWorkspaces":["/some/path"]}\n' > "$agyhome/.gemini/antigravity-cli/settings.json"
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept a settings.json with neither modelProvider nor useG1Credits true"
  pass "agy spawn accepts a settings.json that carries neither refused key"
}

test_refuses_unreadable_settings_file() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_case malformed-settings)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  printf 'not valid json{{{\n' > "$agyhome/.gemini/antigravity-cli/settings.json"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded against a malformed settings.json instead of failing closed"
  assert_contains "$out" "API-key/Vertex billing" \
    "agy spawn did not report the settings refusal for malformed JSON"
  pass "agy spawn fails closed rather than silently permitting an unparseable settings file"
}

test_refuses_without_credential_file
test_refuses_empty_credential_file
test_accepts_present_credential
test_refuses_gemini_api_key_env
test_refuses_settings_model_provider
test_refuses_use_g1_credits
test_accepts_clean_settings_file
test_refuses_unreadable_settings_file

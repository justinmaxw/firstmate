#!/usr/bin/env bash
# AC-1: harness=agy refuses before any endpoint is created when no
# worker-reachable Antigravity credential is present, rather than launching
# into an unattended interactive Google sign-in prompt. Also covers the
# captain-approved refinement that refuses a launch whose effective settings
# would permit API-key/Vertex billing or personal-credit top-ups instead of
# the Google AI Pro/Ultra subscription this pool exists to use.
set -u

# shellcheck source=tests/agy-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/agy-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-agy-credential-preflight)

# An unauthenticated agy pane does not exit: it sits on a browser sign-in flow
# waiting for a human who is not there, which supervision would read as a
# wedged worker rather than a missing credential. The spawn must refuse before
# an endpoint exists.
test_refuses_without_credential_file() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" no-cred absent)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
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
  rec=$(make_agy_case "$TMP_ROOT" empty-cred)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  : > "$(agy_credential_path "$agyhome")"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with an empty credential file"
  assert_contains "$out" "no worker-reachable Antigravity credential" \
    "agy spawn did not name the missing credential for an empty file"
  pass "agy spawn refuses when the credential file exists but is empty"
}

test_accepts_present_credential() {
  local rec case_dir home proj wt fakebin id agyhome status
  rec=$(make_agy_case "$TMP_ROOT" present-cred)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept a present, non-empty credential file"
  pass "agy spawn accepts a present credential file"
}

test_refuses_gemini_api_key_env() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" api-key-env)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(GEMINI_API_KEY=leaked-key run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with GEMINI_API_KEY set"
  assert_contains "$out" "API-key/Vertex billing" \
    "agy spawn did not explain the API-key billing refusal"
  assert_not_contains "$out" "leaked-key" "agy spawn refusal leaked the API key value"
  assert_absent "$home/launch.log" "GEMINI_API_KEY refusal still created an endpoint"
  pass "agy spawn refuses when GEMINI_API_KEY is set in the launch environment"
}

# The refusal above reads fm-spawn's OWN process environment, which is not
# the environment the pane runs in: crewmate panes are created by a
# long-lived tmux/herdr daemon whose shell can export GEMINI_API_KEY from an
# rc file firstmate never read, so the caller-side check passes while agy
# still lands on pay-as-you-go API billing. The generated launch has to
# strip the key from the actual child environment. This drives the real
# launch and asks the launched `agy` what it could see, because asserting
# only that the spawn exited 0 would pass with the strip deleted.
test_launch_strips_worker_host_gemini_api_key() {
  local rec case_dir home proj wt fakebin id agyhome seen out status
  rec=$(make_agy_case "$TMP_ROOT" worker-host-api-key)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  seen="$case_dir/agy-child-gemini-key"
  out=$(FM_FAKE_EXECUTE_AGY_LAUNCH=1 FM_FAKE_AGY_ENV_RESULT="$seen" \
    FM_FAKE_WORKER_GEMINI_API_KEY=worker-host-key \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  expect_code 0 "$status" \
    "agy spawn should succeed when GEMINI_API_KEY is absent from fm-spawn's own environment: $out"
  [ -f "$seen" ] \
    || fail "the generated agy launch never executed, so the child's view of GEMINI_API_KEY was never recorded"
  [ -z "$(cat "$seen")" ] \
    || fail "the launched agy child inherited GEMINI_API_KEY from the worker host: $(cat "$seen")"
  pass "the generated agy launch strips a worker-host GEMINI_API_KEY the caller-side refusal cannot see"
}

test_refuses_settings_model_provider() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" settings-provider)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf '{"modelProvider":"gemini"}\n' > "$(agy_settings_path "$agyhome")"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with a settings.json modelProvider set"
  assert_contains "$out" "API-key/Vertex billing" \
    "agy spawn did not explain the modelProvider refusal"
  pass "agy spawn refuses when settings.json sets modelProvider"
}

test_refuses_use_g1_credits() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" g1-credits)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf '{"useG1Credits":true}\n' > "$(agy_settings_path "$agyhome")"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn succeeded with useG1Credits=true"
  assert_contains "$out" "personal-credit top-ups" \
    "agy spawn did not explain the useG1Credits refusal"
  pass "agy spawn refuses when settings.json sets useG1Credits to true"
}

test_accepts_clean_settings_file() {
  local rec case_dir home proj wt fakebin id agyhome status
  rec=$(make_agy_case "$TMP_ROOT" clean-settings)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf '{"trustedWorkspaces":["/some/path"]}\n' > "$(agy_settings_path "$agyhome")"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept a settings.json with neither modelProvider nor useG1Credits true"
  pass "agy spawn accepts a settings.json that carries neither refused key"
}

test_refuses_unreadable_settings_file() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" malformed-settings)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  printf 'not valid json{{{\n' > "$(agy_settings_path "$agyhome")"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
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
test_launch_strips_worker_host_gemini_api_key
test_refuses_settings_model_provider
test_refuses_use_g1_credits
test_accepts_clean_settings_file
test_refuses_unreadable_settings_file

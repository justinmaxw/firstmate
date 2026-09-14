#!/usr/bin/env bash
# AC-2: harness=agy only ever launches Gemini 3.7 Flash. On agy 1.2.x every
# model id carries its effort as a suffix, so the allowlist is exactly
# gemini-3.7-flash-low, gemini-3.7-flash-medium, and gemini-3.7-flash-high. An
# empty/default model resolves to gemini-3.7-flash-medium rather than falling
# through to whatever agy would pick on its own. The effort recorded in task
# metadata is the model id's suffix, no separate --effort flag reaches the
# launch, and an explicit --effort that disagrees with the suffix refuses.
# Enforced in the launch path itself (bin/fm-spawn.sh), not only in dispatch
# configuration, so a hand-typed --model override or a stale dispatch profile
# can never bypass it.
set -u

# shellcheck source=tests/agy-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/agy-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-agy-model-allowlist)

test_refuses_non_allowlisted_model() {
  local rec case_dir home proj wt fakebin id agyhome out status model
  for model in gemini-3.8-flash-high gemini-3.1-pro-high gemini-3.6-flash-medium gemini-3.7-flash; do
    rec=$(make_agy_case "$TMP_ROOT" "reject-$model")
    IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
    out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model "$model")
    status=$?
    [ "$status" -ne 0 ] || fail "agy spawn accepted disallowed model '$model'"
    assert_contains "$out" "gemini-3.7-flash-low, gemini-3.7-flash-medium, or gemini-3.7-flash-high" \
      "agy spawn refusal for '$model' did not name the three allowed ids"
    assert_absent "$home/state/$id.meta" "refused agy model spawn still published task metadata"
    assert_absent "$home/launch.log" "refused agy model spawn still created an endpoint"
  done
  pass "agy spawn refuses every model outside the Gemini 3.7 Flash allowlist"
}

test_accepts_each_allowlisted_model() {
  local rec case_dir home proj wt fakebin id agyhome status launch level
  for level in low medium high; do
    rec=$(make_agy_case "$TMP_ROOT" "accept-$level")
    IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model "gemini-3.7-flash-$level" >/dev/null
    status=$?
    expect_code 0 "$status" "agy spawn should accept gemini-3.7-flash-$level"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "--model 'gemini-3.7-flash-$level'" \
      "agy launch did not carry gemini-3.7-flash-$level"
    assert_not_contains "$launch" "--effort" \
      "agy launch for gemini-3.7-flash-$level passed a separate effort flag"
    assert_grep "model=gemini-3.7-flash-$level" "$home/state/$id.meta" \
      "agy accepted model gemini-3.7-flash-$level was not recorded in meta"
    assert_grep "effort=$level" "$home/state/$id.meta" \
      "agy meta did not record the effort gemini-3.7-flash-$level encodes"
  done
  pass "agy spawn accepts each Gemini 3.7 Flash id and records its suffix as the effort"
}

test_defaults_unset_model_to_medium() {
  local rec case_dir home proj wt fakebin id agyhome status launch name
  for name in empty token; do
    rec=$(make_agy_case "$TMP_ROOT" "default-$name")
    IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
    if [ "$name" = token ]; then
      run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model default >/dev/null
    else
      run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
    fi
    status=$?
    expect_code 0 "$status" "agy spawn with a $name default model should resolve rather than refuse"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "--model 'gemini-3.7-flash-medium'" \
      "agy spawn with a $name default model did not resolve to gemini-3.7-flash-medium"
    assert_grep 'model=gemini-3.7-flash-medium' "$home/state/$id.meta" \
      "agy defaulted model was not recorded in meta"
    assert_grep 'effort=medium' "$home/state/$id.meta" \
      "agy defaulted model did not record its medium effort"
  done
  pass "agy spawn resolves an unset or 'default' model to gemini-3.7-flash-medium"
}

test_refuses_effort_that_disagrees_with_model_suffix() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" effort-mismatch)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    --model gemini-3.7-flash-low --effort high)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn accepted --effort high with gemini-3.7-flash-low"
  assert_contains "$out" "disagrees with model 'gemini-3.7-flash-low'" \
    "agy effort mismatch refusal did not explain the conflict"
  assert_absent "$home/state/$id.meta" "refused agy effort mismatch still published task metadata"
  assert_absent "$home/launch.log" "refused agy effort mismatch still created an endpoint"
  pass "agy spawn refuses an explicit --effort that disagrees with the model id's suffix"
}

test_accepts_effort_matching_model_suffix() {
  local rec case_dir home proj wt fakebin id agyhome status
  rec=$(make_agy_case "$TMP_ROOT" effort-match)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    --model gemini-3.7-flash-high --effort high >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept an --effort matching the model suffix"
  assert_not_contains "$(cat "$home/launch.log")" "--effort" \
    "agy launch passed a separate effort flag for a matching --effort"
  assert_grep 'effort=high' "$home/state/$id.meta" "agy matching effort was not recorded in meta"
  pass "agy spawn accepts an --effort that matches the model id's suffix"
}

test_refuses_non_allowlisted_model
test_accepts_each_allowlisted_model
test_defaults_unset_model_to_medium
test_refuses_effort_that_disagrees_with_model_suffix
test_accepts_effort_matching_model_suffix

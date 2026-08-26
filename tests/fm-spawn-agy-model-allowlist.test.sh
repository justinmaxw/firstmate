#!/usr/bin/env bash
# AC-2: harness=agy refuses the launch when the resolved or explicitly
# requested model is anything other than the literal gemini-3.7-flash. An
# empty/default model defaults to that literal rather than falling through to
# whatever agy would pick on its own. Enforced in the launch path itself
# (bin/fm-spawn.sh), not only in dispatch configuration, so a hand-typed
# --model override or a stale dispatch profile can never bypass it.
set -u

# shellcheck source=tests/agy-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/agy-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-agy-model-allowlist)

test_refuses_non_allowlisted_model() {
  local rec case_dir home proj wt fakebin id agyhome out status model
  for model in gemini-3.7-flash-high gemini-3.5-flash-medium claude-sonnet-4-6 gemini-3.7; do
    rec=$(make_agy_case "$TMP_ROOT" "reject-$model")
    IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
    out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model "$model")
    status=$?
    [ "$status" -ne 0 ] || fail "agy spawn accepted disallowed model '$model'"
    assert_contains "$out" "literal model 'gemini-3.7-flash'" \
      "agy spawn refusal for '$model' did not name the allowlisted literal"
    assert_absent "$home/state/$id.meta" "refused agy model spawn still published task metadata"
    assert_absent "$home/launch.log" "refused agy model spawn still created an endpoint"
  done
  pass "agy spawn refuses every model other than the literal gemini-3.7-flash"
}

test_accepts_exact_allowlisted_model() {
  local rec case_dir home proj wt fakebin id agyhome status launch
  rec=$(make_agy_case "$TMP_ROOT" accept-exact)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model gemini-3.7-flash >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept the exact literal allowlisted model"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--model 'gemini-3.7-flash'" "agy launch did not carry the accepted model flag"
  assert_grep 'model=gemini-3.7-flash' "$home/state/$id.meta" "agy accepted model was not recorded in meta"
  pass "agy spawn accepts the exact literal allowlisted model"
}

test_defaults_empty_model_to_allowlisted_literal() {
  local rec case_dir home proj wt fakebin id agyhome status launch
  rec=$(make_agy_case "$TMP_ROOT" default-empty)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn with no --model should default rather than refuse"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--model 'gemini-3.7-flash'" \
    "agy spawn with no --model did not default to the allowlisted literal"
  assert_grep 'model=gemini-3.7-flash' "$home/state/$id.meta" \
    "agy defaulted model was not recorded in meta"
  pass "agy spawn defaults an unset model to the literal gemini-3.7-flash rather than agy's own choice"
}

test_defaults_explicit_default_token_to_allowlisted_literal() {
  local rec case_dir home proj wt fakebin id agyhome status launch
  rec=$(make_agy_case "$TMP_ROOT" default-token)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model default >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn with --model default should default rather than refuse"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--model 'gemini-3.7-flash'" \
    "agy spawn with --model default did not resolve to the allowlisted literal"
  pass "agy spawn treats the literal token 'default' the same as an unset model"
}

test_refuses_non_allowlisted_model
test_accepts_exact_allowlisted_model
test_defaults_empty_model_to_allowlisted_literal
test_defaults_explicit_default_token_to_allowlisted_literal

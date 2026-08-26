#!/usr/bin/env bash
# AC-2: harness=agy refuses the launch when the resolved or explicitly
# requested model is anything other than the literal gemini-3.7-flash. An
# empty/default model defaults to that literal rather than falling through to
# whatever agy would pick on its own. Enforced in the launch path itself
# (bin/fm-spawn.sh), not only in dispatch configuration, so a hand-typed
# --model override or a stale dispatch profile can never bypass it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agy-model-allowlist)

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
  printf 'opaque-session-state\n' > "$agyhome/.gemini/antigravity-cli/jetski_state.pbtxt"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id|$agyhome"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> <agyhome> [extra args...]
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

test_refuses_non_allowlisted_model() {
  local rec case_dir home proj wt fakebin id agyhome out status model
  for model in gemini-3.7-flash-high gemini-3.5-flash-medium claude-sonnet-4-6 gemini-3.7; do
    rec=$(make_case "reject-$model")
    IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
    out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model "$model")
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
  rec=$(make_case accept-exact)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model gemini-3.7-flash >/dev/null
  status=$?
  expect_code 0 "$status" "agy spawn should accept the exact literal allowlisted model"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--model 'gemini-3.7-flash'" "agy launch did not carry the accepted model flag"
  assert_grep 'model=gemini-3.7-flash' "$home/state/$id.meta" "agy accepted model was not recorded in meta"
  pass "agy spawn accepts the exact literal allowlisted model"
}

test_defaults_empty_model_to_allowlisted_literal() {
  local rec case_dir home proj wt fakebin id agyhome status launch
  rec=$(make_case default-empty)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" >/dev/null
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
  rec=$(make_case default-token)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" --model default >/dev/null
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

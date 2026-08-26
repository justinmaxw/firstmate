#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) crewmate/scout adapter: harness
# detection, spawn launch shape, effort/model mapping, the secondmate refusal
# (AC-9), the control-plane lifecycle tables, and the delivery-confirmation
# footer. AC-1's credential preflight lives in its own dedicated file
# (tests/fm-spawn-agy-credential-preflight.test.sh) and AC-2's model allowlist
# lives in its own dedicated file (tests/fm-spawn-agy-model-allowlist.test.sh),
# matching the captain-approved spec's test plan (section 8).
set -u

# shellcheck source=tests/agy-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/agy-helpers.sh"

HARNESS=$AGY_HARNESS_PROBE
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# --- detection ----------------------------------------------------------

# agy's live process name is the exact installed binary name with no version
# suffix and no wrapper exec (verified, agy 1.1.20), unlike muse's versioned
# muse-bin-<version> launcher. A plain renamed executable is enough to
# reproduce that shape.
test_detects_process_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/agy"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ANTIGRAVITY_AGENT \
    "$dir/agy" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "fm-harness.sh under process 'agy' reported '$out', expected agy"
  pass "agy is detected through its own process ancestor"
}

# agy sets ANTIGRAVITY_AGENT=1 for its child/tool processes (verified live,
# agy 1.1.20), unambiguous when present, the same fast-path-before-ancestry
# precedent as grok's GROK_AGENT.
test_detects_via_env_marker() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 "$HARNESS")
  [ "$out" = agy ] || fail "fm-harness.sh with ANTIGRAVITY_AGENT=1 reported '$out', expected agy"
  pass "agy is detected through its ANTIGRAVITY_AGENT=1 environment marker"
}

# The match must be anchored: an unrelated command whose name merely CONTAINS
# agy is a different program and must not be claimed by this adapter.
test_detection_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in notagy agy-fake myagy magyar; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != agy ] || fail "fm-harness.sh misdetected unrelated process '$bin' as agy"
  done
  pass "agy detection does not claim unrelated agy-containing commands"
}

# The generated launch is actually executed here, and the launched process
# reports what bin/fm-harness.sh makes of it. Asserting only that the spawn
# exited 0 would pass with every `env -u` deleted from the template, because a
# worker that misreports its own harness still launches fine.
test_spawn_clears_inherited_foreign_harness_markers() {
  local rec case_dir home proj wt fakebin id agyhome result out status
  rec=$(make_agy_case "$TMP_ROOT" inherited-markers)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  result="$case_dir/harness-result"
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 FM_PI_HARNESS=pi-signed \
    CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    FM_FAKE_EXECUTE_AGY_LAUNCH=1 FM_FAKE_HARNESS_RESULT="$result" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  expect_code 0 "$status" "agy spawn from a marked backend should succeed: $out"
  [ -f "$result" ] || fail "the generated agy launch never executed its harness probe"
  [ "$(cat "$result")" = agy ] \
    || fail "agy worker inherited a foreign harness identity: $(cat "$result")"
  pass "agy launch clears foreign harness markers before ancestry detection"
}

# --- spawn launch shape -------------------------------------------------

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id agyhome out status launch
  rec=$(make_agy_case "$TMP_ROOT" launch)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome")
  status=$?
  expect_code 0 "$status" "agy spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  launch=$(cat "$home/launch.log")
  assert_contains "$launch" ' --dangerously-skip-permissions ' \
    "agy launch omitted --dangerously-skip-permissions"
  assert_contains "$launch" 'AGY_CLI_DISABLE_AUTO_UPDATE=true' \
    "agy launch omitted the auto-update disable, risking updater lock contention"
  assert_contains "$launch" ' -i "' "agy launch did not deliver the brief through -i"
  assert_contains "$launch" 'encode launch-brief' "agy launch did not encode the brief"
  assert_contains "$launch" "--model 'gemini-3.7-flash'" \
    "agy launch did not default the model to the literal allowlisted value"
  assert_contains "$launch" "--effort 'medium'" \
    "agy launch did not default the effort to medium"
  assert_grep 'harness=agy' "$home/state/$id.meta" "agy harness was not recorded in meta"
  assert_grep 'model=gemini-3.7-flash' "$home/state/$id.meta" "agy model was not recorded in meta"
  # agy has no flagless mode, so `effort=default` would describe a launch that
  # never happened. Metadata has to name the value the pane really launched.
  assert_grep 'effort=medium' "$home/state/$id.meta" \
    "agy meta recorded a default effort while the pane launched --effort 'medium'"
  pass "agy spawn launches with autonomy, the interactive-prompt flag, and a defaulted model/effort"
}

test_spawn_maps_effort() {
  local rec case_dir home proj wt fakebin id agyhome launch
  local -a cases=(
    "low|--effort 'low'"
    "medium|--effort 'medium'"
    "high|--effort 'high'"
  )
  local entry effort expect
  for entry in "${cases[@]}"; do
    effort=${entry%%|*}
    expect=${entry#*|}
    rec=$(make_agy_case "$TMP_ROOT" "effort-$effort")
    IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
      --effort "$effort" >/dev/null \
      || fail "agy spawn with effort $effort failed"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "$expect" "agy effort $effort did not map to '$expect'"
    assert_grep "effort=$effort" "$home/state/$id.meta" \
      "agy meta did not record the effort the pane launched with"
  done

  # agy's own CLI rejects --model gemini-3.7-flash with no --effort at all, so
  # unlike every other adapter's "omit an unsupported value" rule, an
  # unsupported class must still fall back to a value agy accepts rather than
  # being omitted outright.
  rec=$(make_agy_case "$TMP_ROOT" effort-xhigh-falls-back)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    --effort xhigh >/dev/null \
    || fail "agy spawn with an unsupported effort class failed"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--effort 'medium'" \
    "agy spawn did not fall back an unsupported effort class to medium"
  assert_grep 'effort=medium' "$home/state/$id.meta" \
    "agy meta recorded the requested xhigh while the pane launched the medium it fell back to"
  pass "agy maps low/medium/high directly and falls unsupported classes back to medium rather than omitting the flag"
}

# The raw launch command is the documented unverified-adapter escape hatch,
# and it carries none of a verified adapter's placeholders (__MODELFLAG__,
# __AGYBIN__), so nothing fm-spawn resolves can reach the command that
# actually runs or gate it. For agy that would silently bypass AC-1's
# credential preflight, AC-2's model allowlist, AC-9's secondmate refusal, and
# the subscription-only billing refusal all at once - a raw command's argv is
# never inspected by any of them. fm-spawn refuses every raw command whose
# first word resolves to agy outright, regardless of what the caller embedded
# in it, rather than trying to parse or restrict an arbitrary shell command
# safely.
run_raw_agy_spawn() {  # <home> <proj> <wt> <fakebin> <id> <agyhome> <raw-command> [extra env=val ...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 agyhome=$6 raw=$7
  shift 7
  env "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    HOME="$agyhome" PATH="$fakebin:$PATH" \
    "$AGY_SPAWN" "$id" "$proj" "$raw" --mode no-mistakes --yolo off 2>&1
}

test_raw_launch_refused_even_with_allowlisted_model() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" raw-allowlisted)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_raw_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    "agy --model gemini-3.7-flash --effort medium -i 'raw brief'")
  status=$?
  [ "$status" -ne 0 ] || fail "a raw agy launch spawned even with an allowlisted embedded model"
  assert_contains "$out" "raw launch command is refused for harness=agy" \
    "raw agy refusal did not name the reason"
  assert_absent "$home/state/$id.meta" "refused raw agy spawn still published task metadata"
  assert_absent "$home/launch.log" "refused raw agy spawn still created an endpoint"
  pass "a raw agy launch is refused even when the embedded model is the allowlisted literal"
}

test_raw_launch_cannot_bypass_model_allowlist() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" raw-model-bypass)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_raw_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    "agy --model gemini-3.5-pro -i 'raw brief'")
  status=$?
  [ "$status" -ne 0 ] || fail "a raw agy launch bypassed AC-2 with a disallowed embedded model"
  assert_not_contains "$(cat "$home/launch.log" 2>/dev/null || true)" "gemini-3.5-pro" \
    "a disallowed embedded model reached an endpoint"
  pass "a raw agy launch cannot use an embedded --model to bypass the AC-2 allowlist"
}

test_raw_launch_cannot_bypass_credential_preflight() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" raw-no-credential absent)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_raw_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    "agy --model gemini-3.7-flash --effort medium -i 'raw brief'")
  status=$?
  [ "$status" -ne 0 ] || fail "a raw agy launch spawned with no worker-reachable credential"
  assert_absent "$home/launch.log" "a raw agy launch with no credential still created an endpoint"
  pass "a raw agy launch is refused before AC-1's credential preflight could even run"
}

test_raw_launch_cannot_bypass_billing_refusal() {
  local rec case_dir home proj wt fakebin id agyhome out status
  rec=$(make_agy_case "$TMP_ROOT" raw-billing-bypass)
  IFS='|' read -r case_dir home proj wt fakebin id agyhome <<EOF
$rec
EOF
  out=$(run_raw_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$agyhome" \
    "agy --model gemini-3.7-flash --effort medium -i 'raw brief'" GEMINI_API_KEY=leaked-key)
  status=$?
  [ "$status" -ne 0 ] || fail "a raw agy launch spawned with GEMINI_API_KEY set, bypassing the billing refusal"
  assert_absent "$home/launch.log" "a raw agy launch with GEMINI_API_KEY set still created an endpoint"
  pass "a raw agy launch is refused before the subscription-only billing refusal could even run"
}

test_raw_launch_secondmate_still_refused_for_agy() {
  local case_dir home fakebin id agyhome out status
  case_dir="$TMP_ROOT/raw-secondmate"
  home="$case_dir/home"
  agyhome="$case_dir/agyhome"
  fakebin=$(make_agy_fakebin "$case_dir/fake")
  id="agy-raw-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$agyhome/$(dirname "$AGY_CREDENTIAL_RELPATH")"
  printf 'charter\n' > "$home/data/$id/brief.md"
  agy_seed_credential "$agyhome"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HOME="$agyhome" \
    PATH="$fakebin:$PATH" \
    "$AGY_SPAWN" "$id" "agy --model gemini-3.7-flash --effort medium -i 'raw charter'" --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a raw agy launch was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" \
    "raw-launch agy secondmate refusal did not explain the boundary (AC-9 must apply before harness resolution matters)"
  assert_absent "$home/state/$id.meta" "refused raw agy secondmate spawn still published task metadata"
  pass "AC-9's secondmate refusal still applies to a raw agy launch command"
}

# --- secondmate refusal (AC-9) ------------------------------------------

# agy has no primary supervision protocol, matching muse's own refusal
# reasoning, so a secondmate on it could never arm a supervision cycle.
test_secondmate_spawn_refused() {
  local case_dir home fakebin id agyhome out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  agyhome="$case_dir/agyhome"
  fakebin=$(make_agy_fakebin "$case_dir/fake")
  id="agy-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$agyhome/$(dirname "$AGY_CREDENTIAL_RELPATH")"
  printf 'charter\n' > "$home/data/$id/brief.md"
  agy_seed_credential "$agyhome"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HOME="$agyhome" \
    PATH="$fakebin:$PATH" \
    "$AGY_SPAWN" "$id" agy --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "agy secondmate refusal did not explain the boundary"
  assert_absent "$home/state/$id.meta" "refused agy secondmate spawn still published task metadata"
  pass "agy is refused as a secondmate harness"
}

# --- control-plane lifecycle tables --------------------------------------

test_control_lib_lifecycle_tables() {
  (
    # shellcheck source=bin/fm-control-lib.sh
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_harness_supported agy || fail "agy is not a recognized control-plane harness"
    fm_control_harness_supports_kind agy ship || fail "agy should support kind=ship"
    fm_control_harness_supports_kind agy scout || fail "agy should support kind=scout"
    if fm_control_harness_supports_kind agy secondmate; then
      fail "agy should not support kind=secondmate"
    fi
    [ "$(fm_control_harness_family agy)" = agy ] || fail "agy family resolution failed"
    [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy interrupt key should be Escape"
    [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy interrupt should be a single press"
    [ -z "$(fm_control_interrupt_clear_key agy)" ] \
      || fail "agy should need no composer clear key after interrupt"
    [ "$(fm_control_interrupt_ack_source agy)" = none ] \
      || fail "agy should carry no adapter-owned cancellation acknowledgement"
    [ "$(fm_control_exit_command agy)" = /exit ] || fail "agy exit command should be /exit"
  ) || fail "agy control-plane lifecycle table check failed"
  pass "agy's control-plane lifecycle tables (interrupt, exit, kind support) are correctly registered"
}

# --- delivery-confirmation footer ----------------------------------------

test_delivery_regex_matches_agy_busy_footer() {
  (
    # shellcheck source=bin/fm-composer-lib.sh
    . "$ROOT/bin/fm-composer-lib.sh"
    printf 'esc to cancel                                          Gemini 3.7 Flash · medium' \
      | fm_busy_lines_match agy \
      || fail "the agy delivery regex did not match its verified busy footer"
    if printf '? for shortcuts                                     Gemini 3.7 Flash · medium' \
      | fm_busy_lines_match agy; then
      fail "the agy delivery regex matched its idle footer"
    fi
    # The submit cores read a pane they have no recorded harness for, so the
    # harness-less union is the matcher that actually runs on a delivery. agy
    # depends on it more than any other adapter: its composer verdict is
    # permanently unknown, leaving the footer as the only confirmation signal.
    printf 'esc to cancel                                          Gemini 3.7 Flash · medium' \
      | fm_busy_lines_match \
      || fail "the harness-less delivery union did not match agy's verified busy footer"
    if printf '? for shortcuts                                     Gemini 3.7 Flash · medium' \
      | fm_busy_lines_match; then
      fail "the harness-less delivery union matched agy's idle footer"
    fi
  ) || fail "agy delivery-confirmation regex check failed"
  pass "the agy delivery-confirmation regex matches its verified busy footer and not its idle footer"
}

test_detects_process_ancestor
test_detects_via_env_marker
test_detection_is_anchored
test_spawn_clears_inherited_foreign_harness_markers
test_spawn_launch_shape
test_spawn_maps_effort
test_raw_launch_refused_even_with_allowlisted_model
test_raw_launch_cannot_bypass_model_allowlist
test_raw_launch_cannot_bypass_credential_preflight
test_raw_launch_cannot_bypass_billing_refusal
test_raw_launch_secondmate_still_refused_for_agy
test_secondmate_spawn_refused
test_control_lib_lifecycle_tables
test_delivery_regex_matches_agy_busy_footer

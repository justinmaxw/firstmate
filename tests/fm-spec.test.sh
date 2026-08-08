#!/usr/bin/env bash
# Portable regression for bin/fm-spec.sh.
#
# The point of this script is that a spec convention nothing checks quietly
# stops happening, so every failing case here is paired with a passing case
# built from the same fixture with one thing changed. A check that could not
# have failed proves nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUT="$ROOT/bin/fm-spec.sh"
TMP_ROOT=$(fm_test_tmproot fm-spec)

run() {  # <args...>
  RC=0
  OUT=$("$SUT" "$@" 2>&1) || RC=$?
}

# A complete, valid FULL spec. Cases copy it and break exactly one thing.
write_good_spec() {  # <path> [test-target]
  local path=$1 target=${2:-tests/target.test.sh}
  cat > "$path" <<EOF
# Spec: Refill alerting          ID: vending-3    Tier: FULL
Status: CAPTAIN-APPROVED

## 1. Problem statement
Route drivers restock blind.

## 2. User-facing behavior
A refill list per machine.

## 3. Existing-system touchpoints
\`src/refill.ts\` and everything under \`src/views/\`.

## 4. Interfaces & contracts
None new.

## 5. Data model
No migration.

## 6. Edge cases & failure behavior
An empty machine list renders the empty state.

## 7. Acceptance criteria
AC-1 Given a machine below threshold, when the list renders, then it appears.
AC-2 Given no machines, when the list renders, then the empty state appears.
AC-3 The printed driver sheet is legible at arm's length. manual-check: needs a human holding paper.

## 8. Test plan
| AC | Test | Type | New |
|---|---|---|---|
| AC-1 | $target::test_ac_1_below_threshold | unit | new |
| AC-2 | $target | unit | new |

## 9. Out of scope
\`src/billing.ts\`

## 10. Open questions
- Which threshold counts as low? Answer: 20 percent.

## 11. Risk & rollout
Low blast radius.

## 12. Task decomposition
1. Build the list. ACs owned: AC-1, AC-2. Files it may touch: \`src/refill.ts\`
EOF
}

GOOD="$TMP_ROOT/good.md"
write_good_spec "$GOOD"

# --- check: the passing baseline --------------------------------------------

run check "$GOOD"
expect_code 0 "$RC" "a complete spec passes check"$'\n'"$OUT"
assert_contains "$OUT" 'passes structural validation (tier FULL)' "check names the resolved tier"

run check
expect_code 2 "$RC" "check with no spec file"
run check /nonexistent/spec.md
expect_code 2 "$RC" "check with a missing spec file"
pass "check accepts a complete spec and refuses a missing one"

# --- check: a missing required section --------------------------------------

MISSING="$TMP_ROOT/missing-section.md"
grep -v '^## 5\.' "$GOOD" | grep -v '^No migration\.$' > "$MISSING"
run check "$MISSING"
expect_code 1 "$RC" "a FULL spec missing section 5"
assert_contains "$OUT" 'tier FULL requires section 5, which is missing' "the missing section is named"

# The same omission is fine at LIGHT tier, which proves the tier line is really
# what drives the requirement rather than a fixed list.
LIGHT="$TMP_ROOT/light.md"
sed 's/Tier: FULL/Tier: LIGHT/' "$MISSING" > "$LIGHT"
run check "$LIGHT"
expect_code 0 "$RC" "a LIGHT spec without section 5"$'\n'"$OUT"
assert_contains "$OUT" 'tier LIGHT' "the LIGHT tier is reported"
pass "check enforces the sections the declared tier requires, and only those"

# --- check: the tier line itself --------------------------------------------

UNCHOSEN="$TMP_ROOT/unchosen-tier.md"
sed 's/Tier: FULL/Tier: FULL | LIGHT/' "$GOOD" > "$UNCHOSEN"
run check "$UNCHOSEN"
expect_code 1 "$RC" "an unfilled template tier line"
assert_contains "$OUT" 'no resolved tier line' "an unchosen tier is refused"
pass "an unfilled 'Tier: FULL | LIGHT' template line is not a tier"

# --- check: an unanswered open question -------------------------------------

UNANSWERED="$TMP_ROOT/unanswered.md"
sed 's/- Which threshold counts as low? Answer: 20 percent./- Which threshold counts as low? Recommended default: 20 percent./' "$GOOD" > "$UNANSWERED"
run check "$UNANSWERED"
expect_code 1 "$RC" "an unanswered section 10 item"
assert_contains "$OUT" 'section 10 still has an unanswered item' "the unanswered item is reported"
assert_contains "$OUT" 'Which threshold counts as low?' "the offending question is quoted"

# Answered on a continuation line still counts as answered.
CONTINUED="$TMP_ROOT/answered-continuation.md"
sed 's/- Which threshold counts as low? Answer: 20 percent./- Which threshold counts as low?\
  Answer: 20 percent./' "$GOOD" > "$CONTINUED"
run check "$CONTINUED"
expect_code 0 "$RC" "an answer on a continuation line"$'\n'"$OUT"
# A rationale nested under an answered question must not reopen it. Before the
# fix the indented bullet started a fresh item with no Answer:, so a fully
# answered section 10 failed here and blocked approval.
NESTED="$TMP_ROOT/answered-nested.md"
sed 's/- Which threshold counts as low? Answer: 20 percent./- Which threshold counts as low? Answer: 20 percent.\
  - Rationale: matches the route sheet./' "$GOOD" > "$NESTED"
run check "$NESTED"
expect_code 0 "$RC" "an answered question with a nested sub-bullet"$'\n'"$OUT"
pass "check blocks on an unanswered open question and accepts an answered one, nested detail included"

# --- check: section 12 referencing a criterion that does not exist -----------

GHOST="$TMP_ROOT/ghost-ac.md"
sed 's/ACs owned: AC-1, AC-2./ACs owned: AC-1, AC-7./' "$GOOD" > "$GHOST"
run check "$GHOST"
expect_code 1 "$RC" "section 12 referencing a nonexistent criterion"
assert_contains "$OUT" 'section 12 references AC-7, which section 7 does not declare' "the ghost reference is named"
pass "check catches a task decomposition pointing at a criterion that does not exist"

# --- check: criterion hygiene ------------------------------------------------

GAP="$TMP_ROOT/gap.md"
sed 's/^AC-2 Given no machines/AC-4 Given no machines/' "$GOOD" \
  | sed 's/ACs owned: AC-1, AC-2./ACs owned: AC-1, AC-4./' \
  | sed 's/| AC-2 |/| AC-4 |/' > "$GAP"
run check "$GAP"
expect_code 1 "$RC" "non-contiguous criterion ids"
assert_contains "$OUT" 'expected AC-2 where the spec has AC-4' "the numbering gap is named"

NOREASON="$TMP_ROOT/manual-no-reason.md"
sed "s/manual-check: needs a human holding paper./manual-check./" "$GOOD" > "$NOREASON"
run check "$NOREASON"
expect_code 1 "$RC" "manual-check with no reason"
assert_contains "$OUT" 'marked manual-check with no stated reason' "an unreasoned manual-check is refused"
pass "check refuses a numbering gap and an unreasoned manual-check"

# --- scope -------------------------------------------------------------------

REPO="$TMP_ROOT/repo"
fm_git_identity
mkdir -p "$REPO/src/views" "$REPO/tests"
fm_git_init_commit "$REPO"
git -C "$REPO" checkout -q -b feature
SPEC_IN_REPO="$TMP_ROOT/repo-spec.md"
write_good_spec "$SPEC_IN_REPO"

scope_in_repo() {
  RC=0
  OUT=$(cd "$REPO" && "$SUT" scope "$@" 2>&1) || RC=$?
}

printf 'export const refill = 1;\n' > "$REPO/src/refill.ts"
printf 'view\n' > "$REPO/src/views/list.tsx"
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 0 "$RC" "a diff entirely inside the allowed set"$'\n'"$OUT"
assert_contains "$OUT" 'inside' "a clean diff is reported as in scope"

# The ordering gap that hid the scope/ac conflict: scope used to be exercised
# only BEFORE the mapped test file existed, so a spec could satisfy `ac` and
# fail `scope` on the very file `ac` demanded. Create the mapped test now, up
# front, and keep it present for every scope case below. Section 3 and 12 of
# the fixture deliberately do NOT list tests/, so this case fails unless
# section 8's mapped paths are treated as declared.
printf 'test_ac_1_below_threshold() { :; }\n' > "$REPO/tests/target.test.sh"
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 0 "$RC" "a mapped test file that sections 3 and 12 do not list"$'\n'"$OUT"
assert_not_contains "$OUT" 'is outside the allowed set' "a test section 8 already maps must not be reported out of scope"
ac_in_repo_early() {
  RC=0
  OUT=$(cd "$REPO" && "$SUT" ac "$@" 2>&1) || RC=$?
}
ac_in_repo_early "$SPEC_IN_REPO"
expect_code 0 "$RC" "ac with the mapped test present"$'\n'"$OUT"
pass "scope and ac agree on the same tree: a spec that satisfies one cannot trap the worker on the other"

# The spec file itself, when it lives inside the repo it governs, is the spec -
# not an undeclared change.
cp "$SPEC_IN_REPO" "$REPO/inrepo-spec.md"
scope_in_repo "$REPO/inrepo-spec.md" --base main
expect_code 0 "$RC" "a spec stored inside the repo it governs"$'\n'"$OUT"
assert_not_contains "$OUT" 'is outside the allowed set' "the spec file must not report itself out of scope"
rm -f "$REPO/inrepo-spec.md"

printf 'stray\n' > "$REPO/src/unrelated.ts"
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 1 "$RC" "a file outside the allowed set"
assert_contains "$OUT" 'src/unrelated.ts is outside the allowed set' "the stray path is named"
rm -f "$REPO/src/unrelated.ts"

printf 'billing\n' > "$REPO/src/billing.ts"
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 1 "$RC" "a file matching section 9"
assert_contains "$OUT" "src/billing.ts is out of scope: section 9 excludes 'src/billing.ts'" "the out-of-scope rule is quoted"
rm -f "$REPO/src/billing.ts"

# Committed changes count too, not just the working tree.
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'allowed work'
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 0 "$RC" "committed allowed work"$'\n'"$OUT"
printf 'stray\n' > "$REPO/src/unrelated.ts"
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'stray work'
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 1 "$RC" "committed stray work"
assert_contains "$OUT" 'src/unrelated.ts is outside the allowed set' "a committed stray file is caught too"
git -C "$REPO" rm -q "src/unrelated.ts" && git -C "$REPO" commit -qm 'drop stray'
pass "scope passes a clean diff and fails on both a stray path and a section 9 path"

# Section 9 is the captain's own boundary and still wins over the implicit
# allowance, so an explicit non-goal cannot be smuggled back in through a
# section 8 mapping.
DENIED_TEST="$TMP_ROOT/denied-test-spec.md"
BT=$(printf '\140')
sed "s|${BT}src/billing.ts${BT}|${BT}src/billing.ts${BT}\
${BT}tests/${BT}|" "$SPEC_IN_REPO" > "$DENIED_TEST"
scope_in_repo "$DENIED_TEST" --base main
expect_code 1 "$RC" "section 9 excluding a path section 8 maps"
assert_contains "$OUT" 'tests/target.test.sh is out of scope' "an explicit non-goal still wins over a section 8 mapping"
pass "section 9 still overrides the paths scope treats as implicitly declared"

# A backtick-quoted token is ONE pattern even when it holds a space. Section 3's
# template invites CI commands in backticks, and word-splitting one would put an
# unrelated tree in scope under the word `test`.
mkdir -p "$REPO/test"
printf 'scratch\n' > "$REPO/test/scratch.ts"

QUOTED_CMD="$TMP_ROOT/quoted-command-spec.md"
sed "s|under ${BT}src/views/${BT}\.|under ${BT}src/views/${BT}. Tests run with ${BT}pnpm run test${BT}.|" \
  "$SPEC_IN_REPO" > "$QUOTED_CMD"
scope_in_repo "$QUOTED_CMD" --base main
expect_code 1 "$RC" "a quoted multi-word CI command in section 3"
assert_contains "$OUT" 'test/scratch.ts is outside the allowed set' "a quoted command never widens the allowed set to one of its words"

# The counterpart: the same sentence quoting a token that really is a path. Only
# the space between the words differs, so the case above could have failed.
QUOTED_PATH="$TMP_ROOT/quoted-path-spec.md"
sed "s|under ${BT}src/views/${BT}\.|under ${BT}src/views/${BT}. Tests run with ${BT}test${BT}.|" \
  "$SPEC_IN_REPO" > "$QUOTED_PATH"
scope_in_repo "$QUOTED_PATH" --base main
expect_code 0 "$RC" "a single quoted token that really is a path"$'\n'"$OUT"
rm -rf "$REPO/test"

# The same, in the direction that matters most: section 9 is the captain's own
# boundary, so it has to keep applying to a path whose name holds a space. Both
# sections name this directory, so only section 9 can reject it.
mkdir -p "$REPO/src/legacy code"
printf 'legacy\n' > "$REPO/src/legacy code/x.ts"

SPACED_DENY="$TMP_ROOT/spaced-nongoal-spec.md"
sed -e "s|under ${BT}src/views/${BT}\.|under ${BT}src/views/${BT} and ${BT}src/legacy code/${BT}.|" \
    -e "s|^${BT}src/billing.ts${BT}\$|${BT}src/billing.ts${BT} and ${BT}src/legacy code/${BT}|" \
  "$SPEC_IN_REPO" > "$SPACED_DENY"
scope_in_repo "$SPACED_DENY" --base main
expect_code 1 "$RC" "a section 9 non-goal whose path holds a space"
assert_contains "$OUT" "src/legacy code/x.ts is out of scope: section 9 excludes 'src/legacy code/'" "a non-goal with a space still excludes its own path"

# The counterpart: the same tree and the same section 3, with only the section 9
# entry dropped, is in scope - so the refusal above really came from section 9.
SPACED_ALLOW="$TMP_ROOT/spaced-allowed-spec.md"
sed "s|under ${BT}src/views/${BT}\.|under ${BT}src/views/${BT} and ${BT}src/legacy code/${BT}.|" \
  "$SPEC_IN_REPO" > "$SPACED_ALLOW"
scope_in_repo "$SPACED_ALLOW" --base main
expect_code 0 "$RC" "an allowed directory whose name holds a space"$'\n'"$OUT"
rm -rf "$REPO/src/legacy code"
pass "a backtick-quoted path containing a space stays one pattern in both sections"

# A rename reported as its destination alone would hide that a section 9 file
# was removed, so `git mv <non-goal> <allowed path>` has to fail scope. The
# source has to exist on the base for the removal to be real.
git -C "$REPO" checkout -q main
mkdir -p "$REPO/src"
printf 'billing\n' > "$REPO/src/billing.ts"
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'billing exists on main'
git -C "$REPO" checkout -q feature
git -C "$REPO" merge -q --no-edit main

scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 0 "$RC" "the tree before the rename"$'\n'"$OUT"

git -C "$REPO" mv "src/billing.ts" "src/views/moved.tsx"
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 1 "$RC" "an uncommitted rename out of a section 9 path"
assert_contains "$OUT" 'src/billing.ts is out of scope' "a staged rename still reports the path it moved away from"

git -C "$REPO" commit -qm 'move billing into views'
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 1 "$RC" "a committed rename out of a section 9 path"
assert_contains "$OUT" 'src/billing.ts is out of scope' "a committed rename still reports the path it moved away from"

# The counterpart: a rename between two allowed paths is in scope, so the two
# cases above failed on the source path rather than on renames as such.
git -C "$REPO" checkout -q main -- src/billing.ts
git -C "$REPO" mv "src/views/moved.tsx" "src/views/moved-again.tsx"
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'rename inside the allowed set'
scope_in_repo "$SPEC_IN_REPO" --base main
expect_code 0 "$RC" "a rename between two allowed paths"$'\n'"$OUT"
pass "a rename cannot smuggle a section 9 path out of the tree"

# --- ac ----------------------------------------------------------------------

ac_in_repo() {
  RC=0
  OUT=$(cd "$REPO" && "$SUT" ac "$@" 2>&1) || RC=$?
}

# A mapping whose file is absent is still a failure; remove it to prove that,
# then restore it for the cases that follow.
mv "$REPO/tests/target.test.sh" "$REPO/tests/target.test.sh.hidden"
ac_in_repo "$SPEC_IN_REPO"
expect_code 1 "$RC" "a mapping pointing at a test file that does not exist"
assert_contains "$OUT" 'AC-1 maps to' "the unmapped criterion is named"
assert_contains "$OUT" 'does not exist in this tree' "the missing test file is reported"
mv "$REPO/tests/target.test.sh.hidden" "$REPO/tests/target.test.sh"

ac_in_repo "$SPEC_IN_REPO"
expect_code 0 "$RC" "a fully mapped spec"$'\n'"$OUT"
assert_contains "$OUT" 'maps to a test that exists' "a mapped spec passes"

# A named test that is not in the file is a failure, not a warning: this is the
# case that separates "a file exists" from "the claimed test exists".
printf 'something_else() { :; }\n' > "$REPO/tests/target.test.sh"
ac_in_repo "$SPEC_IN_REPO"
expect_code 1 "$RC" "a mapping naming a test the file does not contain"
assert_contains "$OUT" "contains no 'test_ac_1_below_threshold'" "the missing test name is reported"
printf 'test_ac_1_below_threshold() { :; }\n' > "$REPO/tests/target.test.sh"

UNMAPPED="$TMP_ROOT/unmapped.md"
write_good_spec "$UNMAPPED"
sed -i.bak '/| AC-2 | tests\/target.test.sh | unit | new |/d' "$UNMAPPED" && rm -f "$UNMAPPED.bak"
ac_in_repo "$UNMAPPED"
expect_code 1 "$RC" "an unmapped criterion"
assert_contains "$OUT" 'AC-2 has no test mapped in section 8' "the unmapped criterion is named"
assert_not_contains "$OUT" 'AC-3' "a manual-check criterion is not reported as unmapped"

NOPLAN="$TMP_ROOT/noplan.md"
sed 's/Tier: FULL/Tier: LIGHT/' "$GOOD" | awk '/^## 8\./ { skip = 1 } /^## 9\./ { skip = 0 } !skip' > "$NOPLAN"
ac_in_repo "$NOPLAN"
expect_code 1 "$RC" "a spec with no section 8"
assert_contains "$OUT" 'no section 8 test plan' "a spec with no test plan fails ac rather than passing"
pass "ac fails an unmapped criterion, a missing test file, and a missing test name, and passes a real mapping"

# --- criteria ----------------------------------------------------------------

run criteria "$GOOD"
expect_code 0 "$RC" "criteria on a good spec"
assert_contains "$OUT" 'AC-1 Given a machine below threshold, when the list renders, then it appears.' "criteria prints the spec's own line"
assert_contains "$OUT" 'AC-3' "criteria includes manual-check criteria"

run criteria "$GOOD" --only 'AC-2,AC-1'
expect_code 0 "$RC" "criteria with a subset"
assert_contains "$OUT" 'AC-1 Given a machine' "the subset includes AC-1"
assert_not_contains "$OUT" 'AC-3' "the subset excludes what was not asked for"
[ "$(printf '%s\n' "$OUT" | sed -n '1p' | cut -c1-4)" = 'AC-1' ] \
  || fail "criteria should print in spec order, not argument order"$'\n'"$OUT"

run criteria "$GOOD" --only 'AC-9'
expect_code 1 "$RC" "criteria with an undeclared id"
assert_contains "$OUT" 'AC-9 is not declared' "an undeclared id is refused rather than dropped"
pass "criteria prints spec-order criteria verbatim and refuses an id the spec does not declare"

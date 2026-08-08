#!/usr/bin/env bash
# fm-spec.sh - mechanical enforcement of the spec-driven delivery workflow.
# Usage:
#   fm-spec.sh check <spec-file>
#   fm-spec.sh scope <spec-file> [--base <ref>]
#   fm-spec.sh ac <spec-file>
#   fm-spec.sh criteria <spec-file> [--only <ids>]
#   fm-spec.sh -h | --help
#
# [`docs/spec-workflow.md`](../docs/spec-workflow.md) owns the workflow and the
# spec template; this header is the single owner of the exact commands, flags,
# and the machine-readable conventions below. The script reads a spec file and
# the current git repository only. It never reads or writes anything under a
# firstmate home's projects/, and it works against a spec file in any repo.
#
# WHY MECHANICAL: a convention nothing checks is a convention that quietly stops
# happening. These three commands are the checks - there is no reviewer role.
# `check` runs before the captain is asked to approve a spec, `scope` and `ac`
# run in the worker before it reports done and again inside validation.
#
# check   structural validation of a spec, so an incomplete spec fails here
#         rather than reaching the captain.
# scope   the branch's changed files against the spec's allowed paths, which
#         include section 8's mapped tests and the spec file itself.
# ac      every acceptance criterion against the test the spec claims for it.
# criteria
#         prints section 7's criterion lines exactly as the spec writes them, so
#         bin/fm-brief.sh can copy a task's criteria into its brief without a
#         second copy of this spec parser living over there. `--only` takes a
#         comma- or space-separated id list (the subset section 12 gives that
#         task) and refuses an id the spec does not declare, because a brief
#         quietly missing a criterion is a worker held to the wrong contract.
#
# All three exit non-zero on failure and print every offending item by name,
# never a bare count.
#
# MACHINE-READABLE CONVENTIONS (a spec is prose for humans and data for this
# script, so the few load-bearing parts have an exact shape):
#
#   Tier line     a line ending in `Tier: FULL` or `Tier: LIGHT`, exactly one.
#                 The template's unfilled `Tier: FULL | LIGHT` is rejected,
#                 because an unchosen tier is not a tier.
#   Sections      `## <n>. <title>` at the start of a line. A section runs until
#                 the next `## <n>.` or any `# ` heading, so `### ` subheadings
#                 stay inside. FULL requires 1-12; LIGHT requires 1, 3, 7, 9.
#   Criteria      in section 7, lines whose first token is `AC-<n>` (a leading
#                 `-` or `*` bullet is fine). Ids must be unique and contiguous
#                 from AC-1. A criterion that cannot be tested is written
#                 `AC-<n> <text> manual-check: <reason>`; the reason is required
#                 because "manual-check" with no reason is just an untested
#                 criterion with a label on it.
#   Open items    in section 10, every top-level list item must carry `Answer:`
#                 somewhere in its block. Top-level means the bullet starts at
#                 column 0; an indented sub-bullet is part of its parent item and
#                 never starts a new one, so a rationale nested under an answered
#                 question does not reopen it. A section 10 whose body is empty
#                 or `None` passes. Unanswered means not approvable.
#   Paths         in sections 3, 9, and 12, a path is a backtick-quoted token:
#                 `path/to/file`, `path/to/dir/` for a whole subtree, or a glob
#                 like `src/**/*.ts`. Sections 3 and 12 are the allowed set;
#                 section 9 is out of scope and wins over everything below.
#                 `scope` also treats two things as already declared, so a spec
#                 never has to name the same path twice: the test paths section
#                 8 maps acceptance criteria to, and the spec file itself when
#                 it lives inside the repo it governs. Requiring those to be
#                 repeated in section 3 or 12 is bookkeeping authors forget, and
#                 each forgotten one would be a false escalation - `ac` demanding
#                 a test file that `scope` then rejects, with no in-scope way out
#                 for the worker.
#   Test map      in section 8, a table row whose first cell is an AC id and
#                 whose second cell is `path/to/test` or `path/to/test::name`.
#                 Section 8 is not required by LIGHT, but `ac` needs it: a spec
#                 with no section 8 fails `ac` naming that, rather than passing
#                 an unmapped spec.
#
# HONEST LIMIT: "each criterion is a single testable statement" is not
# mechanically decidable. `check` enforces what a machine can actually see -
# present, unique, contiguous, single-line, non-empty, and a stated reason on
# every manual-check - and the captain's approval remains the judgement that a
# criterion is genuinely testable. In the same spirit, `ac` proves a mapped test
# EXISTS; it cannot prove the test is strong. docs/spec-workflow.md Section D
# keeps both limits in front of the reader.
#
# Exit status:
#   0  the check passed
#   1  the check failed; every offending item is printed
#   2  usage error, or a spec file that cannot be read
set -u

SELF=fm-spec

# A backtick-quoted token. Built rather than written inline so the pattern is a
# plain string to the shell instead of something that reads like a command
# substitution.
FM_SPEC_BACKTICK=$(printf '\140')
FM_SPEC_BACKTICK_TOKEN_RE="${FM_SPEC_BACKTICK}[^${FM_SPEC_BACKTICK}]*${FM_SPEC_BACKTICK}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <exit-code> <message...>
  local code=$1
  shift
  case "$code" in
    ''|*[!0-9]*) code=2 ;;
  esac
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

problem() {  # <message...>; records one concrete offending item
  printf '%s: %s\n' "$SELF" "$*" >&2
  FAILED=1
}

ok() {  # <message...>
  printf '%s: %s\n' "$SELF" "$*"
}

read_spec() {  # <spec-file>
  SPEC=$1
  [ -n "$SPEC" ] || die 2 "a spec file is required (see --help)"
  [ -f "$SPEC" ] || die 2 "no spec file at '$SPEC'"
  [ -r "$SPEC" ] || die 2 "spec file '$SPEC' is not readable"
}

# --- spec parsing ------------------------------------------------------------

# Body of one numbered section, without its heading. A `## <n>.` heading or any
# `# ` heading ends the section, so `### ` subheadings stay inside it.
section_body() {  # <spec> <section-number>
  awk -v want="$2" '
    /^##[ \t]+[0-9]+\./ {
      hdr = $0
      sub(/^##[ \t]+/, "", hdr)
      num = hdr
      sub(/\..*$/, "", num)
      inside = (num == want)
      next
    }
    /^#[ \t]/ { inside = 0 }
    inside { print }
  ' "$1"
}

section_present() {  # <spec> <section-number>
  grep -Eq "^##[[:space:]]+$2\." "$1"
}

spec_tier() {  # <spec>; prints FULL or LIGHT, or nothing
  grep -Eo 'Tier:[[:space:]]*(FULL|LIGHT)[[:space:]]*$' "$1" \
    | sed -E 's/Tier:[[:space:]]*//; s/[[:space:]]*$//' \
    | head -1
}

spec_tier_declarations() {  # <spec>; how many lines declare a resolved tier
  grep -Ec 'Tier:[[:space:]]*(FULL|LIGHT)[[:space:]]*$' "$1" || true
}

required_sections_for_tier() {  # <tier>
  case "$1" in
    LIGHT) printf '1 3 7 9' ;;
    *) printf '1 2 3 4 5 6 7 8 9 10 11 12' ;;
  esac
}

# Acceptance-criteria ids declared in section 7, in file order.
ac_ids() {  # <spec>
  section_body "$1" 7 \
    | sed -nE 's/^[[:space:]]*[-*]?[[:space:]]*(AC-[0-9]+).*$/\1/p'
}

ac_line_for() {  # <spec> <ac-id>
  section_body "$1" 7 \
    | grep -E "^[[:space:]]*[-*]?[[:space:]]*$2([^0-9]|$)" \
    | head -1
}

ac_is_manual_check() {  # <ac-line>
  case "$1" in
    *manual-check*) return 0 ;;
  esac
  return 1
}

# Backtick-quoted path tokens in a section.
#
# Extracted per line rather than by splitting the whole section on backticks:
# a newline between two quoted tokens produces two separators, which shifts the
# even/odd parity a whole-stream split relies on and silently drops every token
# after the first one that sits on its own line. Silently losing a path here
# narrows the allowed set and turns into a false out-of-scope failure.
section_paths() {  # <spec> <section-number>
  section_body "$1" "$2" \
    | grep -o "$FM_SPEC_BACKTICK_TOKEN_RE" \
    | tr -d '`' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -v '^$' \
    | LC_ALL=C sort -u
}

# --- check -------------------------------------------------------------------

command_check() {
  read_spec "${1:-}"
  shift || true
  [ "$#" -eq 0 ] || die 2 "check takes only a spec file"
  FAILED=0

  local declarations tier required n
  declarations=$(spec_tier_declarations "$SPEC")
  tier=$(spec_tier "$SPEC")
  if [ -z "$tier" ]; then
    problem "no resolved tier line: the spec needs a line ending in 'Tier: FULL' or 'Tier: LIGHT' (an unfilled 'Tier: FULL | LIGHT' does not choose one)"
    tier=FULL
  elif [ "$declarations" -gt 1 ]; then
    problem "$declarations lines declare a tier; exactly one is allowed"
  fi

  required=$(required_sections_for_tier "$tier")
  for n in $required; do
    section_present "$SPEC" "$n" \
      || problem "tier $tier requires section $n, which is missing"
  done

  check_acceptance_criteria
  check_open_questions
  check_allowed_paths
  check_task_references

  if [ "$FAILED" -ne 0 ]; then
    die 1 "$SPEC is not ready for approval; fix the items above"
  fi
  ok "$SPEC passes structural validation (tier $tier)"
}

check_acceptance_criteria() {
  local ids count expected id line body seen
  ids=$(ac_ids "$SPEC")
  if [ -z "$ids" ]; then
    problem "section 7 declares no acceptance criteria; at least one AC-<n> is required"
    return
  fi

  seen=''
  count=0
  for id in $ids; do
    case " $seen " in
      *" $id "*) problem "acceptance criterion $id is declared more than once" ;;
      *) seen="$seen $id" ;;
    esac
    count=$((count + 1))
  done

  expected=1
  for id in $ids; do
    if [ "$id" != "AC-$expected" ]; then
      problem "acceptance criteria must run contiguously from AC-1; expected AC-$expected where the spec has $id"
      break
    fi
    expected=$((expected + 1))
  done

  for id in $ids; do
    line=$(ac_line_for "$SPEC" "$id")
    body=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*[-*]?[[:space:]]*${id}[[:space:]]*[.):]?[[:space:]]*//")
    if [ -z "$body" ]; then
      problem "acceptance criterion $id has no statement after its id"
      continue
    fi
    if ac_is_manual_check "$line"; then
      case "$line" in
        *manual-check:*[!\ ]*) ;;
        *) problem "acceptance criterion $id is marked manual-check with no stated reason; write 'manual-check: <reason>'" ;;
      esac
    fi
  done
}

check_open_questions() {
  section_present "$SPEC" 10 || return 0
  local body item_lines
  body=$(section_body "$SPEC" 10 | sed -E 's/^\[.*\][[:space:]]*$//' | grep -v '^[[:space:]]*$' || true)
  [ -n "$body" ] || return 0
  case "$body" in
    None|None.|none|none.) return 0 ;;
  esac
  # Each top-level list item must carry an Answer: somewhere in its own block.
  item_lines=$(section_body "$SPEC" 10 | awk '
    /^([-*]|[0-9]+\.)[[:space:]]+/ {
      if (item != "" && answered == 0) print item
      item = $0
      answered = ($0 ~ /Answer:/)
      next
    }
    { if ($0 ~ /Answer:/) answered = 1 }
    END { if (item != "" && answered == 0) print item }
  ')
  if [ -n "$item_lines" ]; then
    printf '%s\n' "$item_lines" | while IFS= read -r item; do
      printf '%s: section 10 still has an unanswered item: %s\n' "$SELF" "$item" >&2
    done
    FAILED=1
  fi
}

check_allowed_paths() {
  local paths
  paths=$( { section_paths "$SPEC" 3; section_paths "$SPEC" 12; } | LC_ALL=C sort -u)
  [ -n "$paths" ] \
    || problem "sections 3 and 12 declare no backtick-quoted paths, so 'fm-spec.sh scope' could never allow any change"
}

check_task_references() {
  section_present "$SPEC" 12 || return 0
  local known ref
  known=$(ac_ids "$SPEC" | tr '\n' ' ')
  for ref in $(section_body "$SPEC" 12 | grep -Eo 'AC-[0-9]+' | LC_ALL=C sort -u); do
    case " $known " in
      *" $ref "*) ;;
      *) problem "section 12 references $ref, which section 7 does not declare" ;;
    esac
  done
}

# --- scope -------------------------------------------------------------------

path_matches() {  # <changed-path> <pattern>
  local path=$1 pattern=$2
  case "$pattern" in
    */)
      case "$path" in "$pattern"*) return 0 ;; esac
      ;;
    *[*?[]*)
      # shellcheck disable=SC2254 # a spec glob is intentionally a pattern here.
      case "$path" in $pattern) return 0 ;; esac
      # `**/` is written for humans; treat it as "any depth" rather than failing.
      case "$pattern" in
        *'**/'*)
          local flattened=${pattern//\*\*\//}
          # shellcheck disable=SC2254
          case "$path" in $flattened) return 0 ;; esac
          ;;
      esac
      ;;
    *)
      [ "$path" = "$pattern" ] && return 0
      case "$path" in "$pattern"/*) return 0 ;; esac
      ;;
  esac
  return 1
}

# Does any pattern in a newline-separated list match this path?
#
# One pattern per line, never word-split: a backtick-quoted token may contain a
# space. Splitting on IFS would both widen the allowed set (a quoted CI command
# such as `pnpm run test` would become three unrelated patterns, one of which
# matches the whole test tree) and narrow section 9 (a non-goal written as
# `src/legacy code/` would become two patterns matching neither half of it).
# Sets the matching pattern in MATCHED_PATTERN so a refusal can quote it.
matches_any() {  # <changed-path> <newline-separated-patterns>
  local path=$1 patterns=$2 pattern
  MATCHED_PATTERN=
  [ -n "$patterns" ] || return 1
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if path_matches "$path" "$pattern"; then
      MATCHED_PATTERN=$pattern
      return 0
    fi
  done <<EOF
$patterns
EOF
  return 1
}

# The test paths section 8 already maps acceptance criteria to. `scope` treats
# these as declared, so a spec never has to name the same path twice.
section_test_paths() {  # <spec>
  section_body "$1" 8 \
    | grep -E '^[[:space:]]*\|[[:space:]]*AC-[0-9]+[[:space:]]*\|' \
    | awk -F'|' '{ print $3 }' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | tr -d '`' \
    | sed -E 's/::.*$//' \
    | grep -v '^$' \
    | LC_ALL=C sort -u
}

# The spec's own path, relative to this repository, when it lives inside it.
# A spec written into the repo it governs is not a change the spec forgot to
# declare; it is the spec.
spec_path_in_repo() {  # <spec>
  local root spec_real
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  root=$(cd "$root" 2>/dev/null && pwd -P) || return 0
  spec_real=$(cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")") || return 0
  case "$spec_real" in
    "$root"/*) printf '%s' "${spec_real#"$root"/}" ;;
  esac
}

# Every uncommitted path, one per line, both sides of a rename included.
#
# `-z` rather than the human format on purpose: without it git C-quotes any path
# holding a space, so `src/legacy code/x.ts` arrives as `"src/legacy code/x.ts"`
# and matches neither an allowed nor a section 9 pattern - the one file the
# captain excluded would slip through as merely unrecognised. With `-z` the
# rename source is a second NUL-terminated record after its entry rather than
# the far side of an arrow, so it is read here rather than parsed out.
status_paths() {
  local entry source
  while IFS= read -r -d '' entry; do
    printf '%s\n' "${entry:3}"
    case "${entry:0:2}" in
      *[RC]*)
        IFS= read -r -d '' source || break
        printf '%s\n' "$source"
        ;;
    esac
  done < <(git status --porcelain -z --untracked-files=all)
}

changed_files() {  # <base-ref>
  local base=$1 merge_base
  git rev-parse --git-dir >/dev/null 2>&1 \
    || die 2 "scope must run inside a git repository"
  if git rev-parse --verify --quiet "$base" >/dev/null; then
    merge_base=$(git merge-base "$base" HEAD 2>/dev/null || true)
  fi
  {
    # --no-renames on purpose: a rename reported as its destination alone hides
    # that a source path was removed, so `git mv <section 9 path> <allowed path>`
    # would pass the very check that exists to catch it.
    if [ -n "${merge_base:-}" ]; then
      git diff --name-only --no-renames -z "$merge_base" HEAD | tr '\0' '\n'
    fi
    # Uncommitted work counts: the worker runs this before it reports done.
    status_paths
  } | grep -v '^$' | LC_ALL=C sort -u
}

resolve_base() {  # <requested-base>
  local requested=$1 candidate
  if [ -n "$requested" ]; then
    git rev-parse --verify --quiet "$requested" >/dev/null \
      || die 2 "base ref '$requested' does not resolve in this repository"
    printf '%s' "$requested"
    return 0
  fi
  for candidate in origin/main main origin/master master; do
    if git rev-parse --verify --quiet "$candidate" >/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die 2 "no default base ref found (tried origin/main, main, origin/master, master); pass --base <ref>"
}

command_scope() {
  read_spec "${1:-}"
  shift || true
  local base='' allowed denied file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -ge 2 ] || die 2 "--base needs a value"; base=$2; shift 2 ;;
      --base=*) base=${1#--base=}; shift ;;
      *) die 2 "unknown argument '$1' for scope (see --help)" ;;
    esac
  done
  FAILED=0

  # `die` inside a command substitution exits only that subshell, so both of
  # these have to propagate the refusal themselves. Without it an unresolvable
  # base or a non-repository would fall through to an empty file list and
  # report every change in scope - the one wrong answer this command must
  # never give.
  base=$(resolve_base "$base") || exit $?
  # Sections 3 and 12 are what the spec declares. Section 8's mapped test paths
  # and the spec file itself are added because requiring the same path in two
  # places is bookkeeping people forget, and every forgotten one is a false
  # escalation for the captain to answer. Section 9 still wins over all of it:
  # an explicit non-goal is the captain's own boundary.
  allowed=$( {
    section_paths "$SPEC" 3
    section_paths "$SPEC" 12
    section_test_paths "$SPEC"
    spec_path_in_repo "$SPEC"
  } | grep -v '^$' | LC_ALL=C sort -u)
  denied=$(section_paths "$SPEC" 9)
  [ -n "$allowed" ] \
    || die 1 "$SPEC declares no allowed paths in sections 3 or 12, so no change can be in scope"

  local files
  files=$(changed_files "$base") || exit $?
  if [ -z "$files" ]; then
    ok "no files changed against $base; nothing to scope-check"
    return 0
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if matches_any "$file" "$denied"; then
      problem "$file is out of scope: section 9 excludes '$MATCHED_PATTERN'"
      continue
    fi
    matches_any "$file" "$allowed" \
      || problem "$file is outside the allowed set declared in sections 3 and 12"
  done <<EOF
$files
EOF

  if [ "$FAILED" -ne 0 ]; then
    die 1 "the branch changes files this spec does not allow (base $base)"
  fi
  ok "every file changed against $base is inside $SPEC's allowed set"
}

# --- ac ----------------------------------------------------------------------

# The mapped location for one AC from the section 8 table: the second cell of
# the row whose first cell is that id.
ac_mapping() {  # <spec> <ac-id>
  section_body "$1" 8 \
    | grep -E "^[[:space:]]*\|[[:space:]]*$2[[:space:]]*\|" \
    | head -1 \
    | awk -F'|' '{ print $3 }' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | tr -d '`'
}

command_ac() {
  read_spec "${1:-}"
  shift || true
  [ "$#" -eq 0 ] || die 2 "ac takes only a spec file"
  FAILED=0

  local ids id line mapping file name
  ids=$(ac_ids "$SPEC")
  [ -n "$ids" ] || die 1 "$SPEC declares no acceptance criteria in section 7"

  if ! section_present "$SPEC" 8; then
    die 1 "$SPEC has no section 8 test plan, so no acceptance criterion can be mapped to a test; add section 8 or mark each criterion manual-check with a reason"
  fi

  for id in $ids; do
    line=$(ac_line_for "$SPEC" "$id")
    if ac_is_manual_check "$line"; then
      continue
    fi
    mapping=$(ac_mapping "$SPEC" "$id")
    if [ -z "$mapping" ]; then
      problem "$id has no test mapped in section 8, and is not marked manual-check"
      continue
    fi
    file=${mapping%%::*}
    name=''
    case "$mapping" in
      *::*) name=${mapping#*::} ;;
    esac
    if [ ! -f "$file" ]; then
      problem "$id maps to '$mapping' but $file does not exist in this tree"
      continue
    fi
    if [ -n "$name" ] && ! grep -Fq "$name" "$file"; then
      problem "$id maps to '$mapping' but $file contains no '$name'"
    fi
  done

  if [ "$FAILED" -ne 0 ]; then
    die 1 "$SPEC has acceptance criteria without a real mapped test"
  fi
  ok "every acceptance criterion in $SPEC maps to a test that exists"
}

command_criteria() {
  read_spec "${1:-}"
  shift || true
  local only='' id line found
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --only) [ "$#" -ge 2 ] || die 2 "--only needs a value"; only=$2; shift 2 ;;
      --only=*) only=${1#--only=}; shift ;;
      *) die 2 "unknown argument '$1' for criteria (see --help)" ;;
    esac
  done

  local ids
  ids=$(ac_ids "$SPEC")
  [ -n "$ids" ] || die 1 "$SPEC declares no acceptance criteria in section 7"

  if [ -z "$only" ]; then
    for id in $ids; do
      ac_line_for "$SPEC" "$id"
    done
    return 0
  fi

  FAILED=0
  local wanted
  wanted=$(printf '%s' "$only" | tr ',' ' ')
  for id in $wanted; do
    [ -n "$id" ] || continue
    found=0
    case " $(printf '%s' "$ids" | tr '\n' ' ') " in
      *" $id "*) found=1 ;;
    esac
    [ "$found" -eq 1 ] || problem "$id is not declared in section 7 of $SPEC"
  done
  [ "$FAILED" -eq 0 ] || die 1 "refusing to select acceptance criteria this spec does not declare"

  # Spec order, not argument order: the brief should read the way the spec does.
  for id in $ids; do
    case " $(printf '%s' "$wanted" | tr '\n' ' ') " in
      *" $id "*) line=$(ac_line_for "$SPEC" "$id"); printf '%s\n' "$line" ;;
    esac
  done
}

case "${1:-}" in
  check) shift; command_check "$@" ;;
  scope) shift; command_scope "$@" ;;
  ac) shift; command_ac "$@" ;;
  criteria) shift; command_criteria "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

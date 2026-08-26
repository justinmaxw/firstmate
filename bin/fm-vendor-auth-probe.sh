#!/usr/bin/env bash
# fm-vendor-auth-probe.sh - one hard-bounded, non-destructive authentication
# probe of a named vendor CLI.
#
# This script collects a FACT and renders no verdict. It takes no harness, model,
# or provider, reads no quota, and never decides whether a dispatch candidate is
# eligible. The dispatching first mate owns that judgment from `quota-axi`'s data
# plus each harness's authoritative model catalog; the decision procedure is
# owned once by .agents/skills/quota-array-dispatch/SKILL.md.
#
# Why it exists rather than the agent running the vendor CLI itself: the
# captain's 2026-07-30 `firstmate-grok-auth-preflight` decision approved exactly
# one bounded, non-interactive probe, and that safety envelope must not depend on
# agent memory. It is enforced here deterministically:
#   - the argv is fixed in this file and never composed from input, so no caller
#     can turn the probe into a login, logout, or interactive TUI launch;
#   - stdin is closed, so caller input can never reach the vendor CLI;
#   - a hard positive timeout bounds every command, so a hung CLI cannot wedge an
#     intake;
#   - raw vendor output is classified here and never printed, logged, or passed
#     in an argument.
#
# The probe registry is a fixed-argv safety allowlist, not a routing table. It
# carries no harness, model, provider, credential-store, or provider-family
# relationship, and asking for a probe is always the caller's own explicit
# decision. A probe is registered only after its non-destructive discovery
# command and its output discriminators are verified first-hand and recorded in
# docs/verification/dispatch-auth.md.
#
# Registered probes:
#   grok   `grok models` - the standalone Grok Build CLI. Verified on grok
#          0.2.117: the command exits 0 in BOTH the authenticated and the
#          unauthenticated case, so only the literal first stdout line
#          discriminates and the exit status is never a verdict.
#   agy    Antigravity CLI. Deliberately NOT a live agy invocation: every agy
#          subcommand this scout could find that runs with no side effect
#          either performs real subscription-backed inference (`-p`/--print,
#          which this envelope must never do - it is not a login/logout/TUI
#          launch, but it is also not a bounded discovery command) or has no
#          confirmed authenticated-vs-unauthenticated discriminator that could
#          be verified without forcing the captain's own live session to sign
#          out, which this probe must never do either. The discriminator is
#          instead the same worker-reachable-credential fact
#          bin/fm-spawn.sh's AC-1 preflight already establishes and records in
#          docs/verification/runtime-backends.md: whether
#          ~/.gemini/antigravity-cli/jetski_state.pbtxt exists and is
#          non-empty. Its content is never read. version= still comes from the
#          real, side-effect-free `agy --version`. A future pass that finds a
#          genuinely bounded, side-effect-free, both-branches-verifiable CLI
#          discriminator should record it in docs/verification/dispatch-auth.md
#          and switch this probe onto it, matching the grok probe's shape.
#
# Output: exactly one sanitized `key=value` line on stdout. No token, refresh
# token, header, path, length, prefix, hash, or raw vendor output is ever
# printed, logged, or passed in an argument.
#
#   probe=            the requested probe name
#   status=           authenticated | unauthenticated | indeterminate |
#                     timeout | unavailable
#   version=          the probed CLI's version, or none
#   versionVerified=  yes | no | none - whether the running CLI matches the
#                     version whose discriminator strings were verified
#
# `status` is evidence, never eligibility. Only `authenticated` and
# `unauthenticated` are ground truth. `indeterminate`, `timeout`, and
# `unavailable` mean the probe established nothing and must never be read as
# either outcome; unrecognized output is `indeterminate`, never authenticated.
#
# Exit status: 0 whenever the line is printed, 2 on a usage error. The exit
# status deliberately does not encode the probe result, because this script
# renders no verdict for a caller to branch on.
#
# Usage:
#   fm-vendor-auth-probe.sh <probe>
#
# Environment:
#   FM_VENDOR_AUTH_PROBE_TIMEOUT   hard per-command bound in seconds; must be a
#                                  positive integer, otherwise the default 20 is
#                                  used. Zero is rejected because `timeout 0` and
#                                  `alarm 0` both mean "no deadline".
set -u

VERIFIED_GROK_VERSION=0.2.117
VERIFIED_AGY_VERSION=1.1.20

usage() {
  cat <<'EOF'
fm-vendor-auth-probe.sh - one hard-bounded, non-destructive authentication probe
of a named vendor CLI. It collects a fact and renders no verdict: it takes no
harness, model, or provider, reads no quota, and never decides dispatch
eligibility. The dispatching first mate owns that judgment.

Usage:
  fm-vendor-auth-probe.sh <probe>

Registered probes:
  grok   `grok models` on the standalone Grok Build CLI
  agy    Antigravity CLI; a worker-reachable-credential file check, never a
         live agy invocation - see this file's header for why

Prints one sanitized key=value line: probe, status, version, versionVerified.

status is evidence, never eligibility:
  authenticated    the vendor CLI reports an authenticated session
  unauthenticated  the vendor CLI reports no authenticated session
  indeterminate    output the verified discriminators do not cover
  timeout          the hard bound was hit
  unavailable      the vendor CLI is not on PATH
Only authenticated and unauthenticated are ground truth; the other three
establish nothing and must never be read as either outcome.

The argv is fixed in the script, stdin is closed, and raw vendor output is never
printed. Login, logout, and the interactive TUI are never invoked.

Exit status: 0 whenever the line is printed, 2 on a usage error.

Environment:
  FM_VENDOR_AUTH_PROBE_TIMEOUT   hard per-command bound in seconds (default 20);
                                 a non-positive or non-numeric value is rejected
                                 in favor of the default
EOF
}

die_usage() {
  printf 'fm-vendor-auth-probe: %s\n' "$1" >&2
  printf 'usage: fm-vendor-auth-probe.sh <probe>   (registered probes: grok, agy)\n' >&2
  exit 2
}

PROBE=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      [ -z "$PROBE" ] || die_usage "only one probe may be requested at a time"
      PROBE=$1
      shift
      ;;
  esac
done

[ -n "$PROBE" ] || die_usage "a probe name is required"

# A non-positive bound is not a bound: `timeout 0` and the Perl fallback's
# `alarm 0` both disable the deadline, so a hung vendor CLI would run unbounded.
TIMEOUT=${FM_VENDOR_AUTH_PROBE_TIMEOUT:-20}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=20 ;;
esac

# Bounded execution is owned by bin/fm-timeout-lib.sh, so a macOS host without
# coreutils still gets a hard bound instead of an unbounded vendor CLI call.
# Exit 124 means the bound was hit.
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

STATUS=unavailable
VERSION=none
VERSION_VERIFIED=none

emit() {
  printf 'probe=%s status=%s version=%s versionVerified=%s\n' \
    "$PROBE" "$STATUS" "$VERSION" "$VERSION_VERIFIED"
  exit 0
}

# The two argv forms below are literals in this file. Nothing the caller supplies
# reaches the vendor CLI's argv or stdin.
grok_version() {
  local output
  output=$(fm_run_timed "$TIMEOUT" grok --version 2>/dev/null </dev/null) || { printf 'none\n'; return 0; }
  printf '%s\n' "$output" | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 | grep . || printf 'none\n'
}

probe_grok() {
  local output first rc=0
  output=$(fm_run_timed "$TIMEOUT" grok models 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'timeout\n'
    return 0
  fi
  # The exit status is deliberately ignored: grok 0.2.117 exits 0 in both the
  # authenticated and unauthenticated cases, so only the first stdout line
  # discriminates. Raw output is classified here and never printed.
  first=$(printf '%s\n' "$output" | head -n 1)
  case "$first" in
    "You are logged in with "*) printf 'authenticated\n' ;;
    "You are not authenticated."*) printf 'unauthenticated\n' ;;
    *) printf 'indeterminate\n' ;;
  esac
}

agy_version() {
  local output
  output=$(fm_run_timed "$TIMEOUT" agy --version 2>/dev/null </dev/null) || { printf 'none\n'; return 0; }
  # Anchored at the start rather than requiring a preceding non-digit byte
  # (grok's pattern above): agy 1.1.20's `--version` output is the bare
  # version string with no prefix, so a run of digits can start at byte 0.
  printf '%s\n' "$output" | sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 | grep . || printf 'none\n'
}

# probe_agy: a file-existence check, never a live agy invocation - see this
# file's header for why no bounded, side-effect-free, both-branches-verifiable
# CLI discriminator is used here. The credential file path is never printed.
probe_agy() {
  local cred="${HOME:-}/.gemini/antigravity-cli/jetski_state.pbtxt"
  if [ -s "$cred" ]; then
    printf 'authenticated\n'
  else
    printf 'unauthenticated\n'
  fi
}

case "$PROBE" in
  grok)
    command -v grok >/dev/null 2>&1 || emit
    VERSION=$(grok_version)
    if [ "$VERSION" = "$VERIFIED_GROK_VERSION" ]; then
      VERSION_VERIFIED=yes
    else
      VERSION_VERIFIED=no
    fi
    STATUS=$(probe_grok)
    emit
    ;;
  agy)
    command -v agy >/dev/null 2>&1 || emit
    VERSION=$(agy_version)
    if [ "$VERSION" = "$VERIFIED_AGY_VERSION" ]; then
      VERSION_VERIFIED=yes
    else
      VERSION_VERIFIED=no
    fi
    STATUS=$(probe_agy)
    emit
    ;;
  *)
    die_usage "no probe is registered for '$PROBE'"
    ;;
esac

#!/usr/bin/env bash
# Opt-in regression against the real installed Pi binary: verifies the tracked
# project-local .pi/extensions/fm-quota.ts is actually discovered and registers
# /quota, using Pi's own RPC get_commands rather than a synthetic pi.registerCommand
# stub. This is the layer the synthetic fm-pi-quota-menu.test.sh cannot cover:
# real extension discovery, real jiti module resolution, and real project-local
# trust handling.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the real-Pi quota menu discovery regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v node >/dev/null 2>&1 || fail "node not found"

TMP_ROOT=$(fm_test_tmproot fm-pi-quota-menu-live-e2e)
PROJECT="$TMP_ROOT/project"
AGENT_DIR="$TMP_ROOT/agent"
mkdir -p "$PROJECT/.pi/extensions/lib" "$AGENT_DIR"
cp "$ROOT/.pi/extensions/fm-quota.ts" "$PROJECT/.pi/extensions/fm-quota.ts"
cp "$ROOT/.pi/extensions/lib/fm-quota-menu.ts" "$PROJECT/.pi/extensions/lib/fm-quota-menu.ts"

OUT="$TMP_ROOT/rpc.log"
(
  cd "$PROJECT" || exit 1
  printf '%s\n' '{"type":"get_commands","id":"quota-check"}' \
    | PI_CODING_AGENT_DIR="$AGENT_DIR" pi --mode rpc --no-session --offline --approve
) >"$OUT" 2>&1
status=$?
expect_code 0 "$status" "pi --mode rpc exited cleanly while checking quota command discovery"

RESPONSE=$(grep '"id":"quota-check"' "$OUT" || true)
[ -n "$RESPONSE" ] || fail "no get_commands response from pi: $(cat "$OUT")"

printf '%s' "$RESPONSE" | node -e '
let input = "";
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  const response = JSON.parse(input);
  const commands = response?.data?.commands ?? [];
  const quota = commands.find((command) => command.name === "quota");
  if (!quota) {
    console.error("quota command not registered:", JSON.stringify(commands.map((c) => c.name)));
    process.exit(1);
  }
  if (!quota.description || !quota.description.includes("press r to refresh")) {
    console.error("quota command description missing manual-refresh guidance:", JSON.stringify(quota));
    process.exit(1);
  }
  if (quota.source !== "extension") {
    console.error("quota command was not sourced from an extension:", JSON.stringify(quota));
    process.exit(1);
  }
});
' || fail "real Pi did not discover and register /quota from the tracked project-local extension"

pass "the real installed Pi binary discovers and registers /quota from the tracked project-local .pi/extensions/fm-quota.ts"

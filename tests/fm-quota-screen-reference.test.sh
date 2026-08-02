#!/usr/bin/env bash
# Focused behavior checks for the non-runtime Baby Menu quota-screen reference.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-screen-reference.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
REFERENCE_ROOT="$ROOT/reference/baby-menu"

make_ts_fixture() {
  local fixture=$1
  mkdir -p "$fixture/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  cp "$REFERENCE_ROOT/quota-display-model.ts" "$fixture/quota-display-model.ts"
  cp "$REFERENCE_ROOT/quota-screen-reference.ts" "$fixture/quota-screen-reference.ts"
  printf '%s\n' '{"type":"module"}' > "$fixture/package.json"
  cat > "$fixture/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$fixture/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export const Key = {
  escape: "escape",
  ctrl: (key) => `ctrl+${key}`,
};
export function matchesKey(data, key) {
  return data === key;
}
export function truncateToWidth(text, width) {
  return text.slice(0, Math.max(0, width));
}
export function visibleWidth(text) {
  return text.length;
}
JS
  cat > "$fixture/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  printf '%s\n' 'export {};' > "$fixture/node_modules/@earendil-works/pi-coding-agent/index.js"
}

test_formatter_and_screen_states() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for quota-screen reference tests"
    return 0
  fi

  fixture="$TMP_ROOT/reference"
  make_ts_fixture "$fixture"
  out=$(cd "$fixture" && NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
const { formatQuotaError, formatQuotaResponse } = await import("./quota-display-model.ts");
const { QuotaScreenReference, formatQuotaPercent } = await import("./quota-screen-reference.ts");

const fresh = formatQuotaResponse({
  generatedAt: "2026-07-31T12:00:00.000Z",
  providers: [
    {
      provider: "claude",
      source: "oauth",
      plan: "pro",
      state: { status: "fresh", stale: false, refreshedAt: "2026-07-31T11:59:00.000Z" },
      windows: [
        { id: "five_hour", label: "Session", percentRemaining: 82.5, resetsAt: "2026-07-31T17:00:00.000Z", pace: { status: "on_pace" } },
        { id: "seven_day", label: "Week", percentRemaining: 64, resetsAt: "2026-08-06T12:00:00.000Z", pace: { status: "behind" } },
      ],
      quotaSemantics: {
        effectiveAvailability: [
          { scope: "all_models", status: "known", effectivePercentRemaining: 64 },
        ],
      },
      account: { email: "secret@example.invalid" },
    },
    {
      provider: "codex",
      source: "oauth",
      plan: "plus",
      state: { status: "fresh", stale: false },
      windows: [],
      quotaSemantics: { effectiveAvailability: [] },
    },
  ],
});
if (fresh.kind !== "data") throw new Error("fresh response was not data");
const claude = fresh.providers.find((provider) => provider.id === "claude");
if (claude?.currentRemaining !== 64 || claude.currentScope !== "all_models") throw new Error("fresh effective headroom was wrong");
if (claude.windows[0]?.pace !== "on pace" || claude.windows[1]?.pace !== "behind") throw new Error("window rows lost pace labels");
if (JSON.stringify(fresh).includes("secret@example.invalid")) throw new Error("formatter exposed account identity");

const stale = formatQuotaResponse({
  providers: [{
    provider: "claude",
    source: "cache",
    plan: "pro",
    state: { status: "stale", stale: true, remedyCommand: "quota-axi --allow-keychain-prompt", untrustedWindowIds: ["five_hour"] },
    windows: [{ id: "five_hour", label: "Session", percentRemaining: 40, resetText: "tomorrow", pace: { status: "unknown" } }],
    quotaSemantics: { effectiveAvailability: [{ scope: "all_models", status: "known", effectivePercentRemaining: 40 }] },
  }],
});
if (stale.kind !== "data") throw new Error("stale response was not data");
const staleClaude = stale.providers.find((provider) => provider.id === "claude");
if (staleClaude?.currentRemaining !== null || !staleClaude.windows[0]?.diagnostic) throw new Error("stale data was presented as current");
if (!staleClaude.message?.includes("press r to refresh")) throw new Error("manual refresh affordance was lost");

const malformed = formatQuotaResponse({ providers: "not-an-array" });
if (malformed.kind !== "error" || malformed.errorKind !== "invalid") throw new Error("invalid response was not an error display");
if (formatQuotaPercent(82.5) !== "82.5" || formatQuotaPercent(64) !== "64") throw new Error("percentage formatting changed");

let renders = 0;
let closed = 0;
let resolveRefresh;
const refreshResult = new Promise((resolve) => { resolveRefresh = resolve; });
const theme = {
  fg(_tone, text) { return text; },
  bold(text) { return text; },
};
const screen = new QuotaScreenReference(
  { requestRender() { renders += 1; } },
  theme,
  () => refreshResult,
  () => { closed += 1; },
);
const idle = screen.render(60);
if (!idle.some((line) => line.includes("No quota read yet"))) throw new Error("idle state was lost");
if (idle.some((line) => line.length !== 60)) throw new Error("overlay rows did not fill the requested width");
const narrow = screen.render(4);
if (narrow.length !== 1 || narrow[0].length > 4) throw new Error("narrow-width fallback was lost");

screen.handleInput("r");
if (!screen.render(60).some((line) => line.includes("Reading quota-axi"))) throw new Error("loading state was lost");
resolveRefresh(fresh);
await new Promise((resolve) => setTimeout(resolve, 0));
const result = screen.render(90);
for (const expected of ["Anthropic / Claude", "Current headroom: 64%", "Session: 82.5% reported", "Windows: none reported", "r refresh manually"]) {
  if (!result.some((line) => line.includes(expected))) throw new Error(`result screen omitted ${expected}`);
}
if (renders < 2) throw new Error("refresh did not request loading and result renders");
screen.handleInput("escape");
if (closed !== 1) throw new Error("close affordance was lost");

const errorScreen = new QuotaScreenReference(
  { requestRender() {} },
  theme,
  async () => formatQuotaError("failed"),
  () => {},
);
errorScreen.handleInput("r");
await new Promise((resolve) => setTimeout(resolve, 0));
if (!errorScreen.render(60).some((line) => line.includes("Quota read unavailable"))) throw new Error("error state was lost");
JS
)
  status=$?
  expect_code 0 "$status" "quota-screen reference formatter and visual states"
  [ -z "$out" ] || fail "quota-screen reference test printed output: $out"
  pass "quota-screen reference preserves formatting, visual states, refresh, and narrow-width behavior"
}

test_formatter_and_screen_states

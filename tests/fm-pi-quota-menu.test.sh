#!/usr/bin/env bash
# Focused quota-menu formatter and registration checks for the project-local Pi extension.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-quota-menu.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
EXT="$ROOT/.pi/extensions/fm-quota.ts"
FORMATTER="$ROOT/.pi/extensions/lib/fm-quota-menu.ts"

make_ts_fixture() {
  local fixture=$1
  mkdir -p "$fixture/lib" "$fixture/fake-node-bin" "$fixture/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  cat > "$fixture/fake-node-bin/quota-axi" <<'SH'
#!/usr/bin/env node
process.stdout.write('{}\n');
SH
  chmod +x "$fixture/fake-node-bin/quota-axi"
  cp "$FORMATTER" "$fixture/lib/fm-quota-menu.ts"
  cp "$EXT" "$fixture/fm-quota.ts"
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

test_formatter_cases() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for Pi quota formatter tests"
    return 0
  fi

  fixture="$TMP_ROOT/formatter"
  make_ts_fixture "$fixture"
  out=$(cd "$fixture" && NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
const { formatQuotaError, formatQuotaResponse } = await import("./lib/fm-quota-menu.ts");

const fresh = formatQuotaResponse({
  generatedAt: "2026-07-31T12:00:00.000Z",
  providers: [
    {
      provider: "claude",
      label: "Claude",
      source: "oauth",
      plan: "pro",
      state: { status: "fresh", stale: false, refreshedAt: "2026-07-31T11:59:00.000Z" },
      windows: [
        { id: "five_hour", label: "Session", percentRemaining: 82, resetsAt: "2026-07-31T17:00:00.000Z", pace: { status: "on_pace" } },
        { id: "seven_day", label: "Week", percentRemaining: 64, resetsAt: "2026-08-06T12:00:00.000Z", pace: { status: "behind" } },
      ],
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [
          { scope: "all_models", status: "known", effectivePercentRemaining: 64, boundedBy: ["five_hour", "seven_day"], pace: { status: "behind" } },
        ],
      },
      account: { email: "secret@example.invalid" },
    },
    {
      provider: "codex",
      label: "Codex",
      source: "oauth",
      plan: "plus",
      state: { status: "fresh", stale: false },
      windows: [
        { id: "weekly", label: "Week", percentRemaining: 100, resetText: "Friday", pace: { status: "ahead" } },
      ],
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [
          { scope: "all_models", status: "known", effectivePercentRemaining: 100, boundedBy: ["weekly"] },
        ],
      },
    },
  ],
});
if (fresh.kind !== "data") throw new Error("fresh response was not data");
const claude = fresh.providers.find((provider) => provider.id === "claude");
if (claude?.currentRemaining !== 64 || claude.currentScope !== "all_models") throw new Error(`fresh effective headroom was wrong: ${JSON.stringify(claude)}`);
if (claude.message !== null) throw new Error(`fresh known headroom had a contradictory message: ${claude.message}`);
if (claude.windows.length !== 2 || claude.windows[0]?.reset !== "2026-07-31T17:00:00.000Z" || claude.windows[1]?.pace !== "behind") throw new Error("fresh window details were not preserved");
if (JSON.stringify(fresh).includes("secret@example.invalid")) throw new Error("formatter exposed account identity");

const stale = formatQuotaResponse({
  generatedAt: "2026-07-31T12:00:00.000Z",
  providers: [
    {
      provider: "claude",
      label: "Claude",
      source: "cache",
      plan: "pro",
      state: {
        status: "stale",
        stale: true,
        reason: "keychain_access_required",
        remedyCommand: "quota-axi --allow-keychain-prompt",
        untrustedWindowIds: ["five_hour"],
      },
      windows: [{ id: "five_hour", label: "Session", percentRemaining: 40, resetsAt: "tomorrow", pace: { status: "unknown", reason: "stale" } }],
      quotaSemantics: {
        status: "known",
        effectiveAvailability: [{ scope: "all_models", status: "known", effectivePercentRemaining: 40, boundedBy: ["five_hour"] }],
      },
    },
  ],
});
if (stale.kind !== "data") throw new Error("stale response was not data");
const staleClaude = stale.providers.find((provider) => provider.id === "claude");
if (staleClaude?.currentRemaining !== null) throw new Error("stale effective headroom was presented as current");
if (!staleClaude?.windows[0]?.diagnostic || staleClaude.windows[0].reportedRemaining !== 40) throw new Error("stale diagnostic window was lost");
if (!staleClaude.message?.includes("quota-axi --allow-keychain-prompt")) throw new Error("stale remediation advice was lost");

const missing = formatQuotaResponse({
  generatedAt: "2026-07-31T12:00:00.000Z",
  providers: [{ provider: "codex", label: "Codex", source: "unavailable", state: { status: "fresh", stale: false }, windows: [], quotaSemantics: { status: "unknown", effectiveAvailability: [] } }],
});
if (missing.kind !== "data") throw new Error("missing-window response was not data");
const missingCodex = missing.providers.find((provider) => provider.id === "codex");
if (missingCodex?.currentRemaining !== null || missingCodex.windows.length !== 0 || !missingCodex.message?.includes("No quota windows")) throw new Error("missing-window state was not unknown");

const commandError = formatQuotaError("failed");
if (commandError.kind !== "error" || !commandError.message.includes("could not read")) throw new Error("command error display was not actionable");
const notFound = formatQuotaError("not-found");
if (!notFound.message.includes("PATH") || !notFound.message.includes("local Node")) throw new Error("not-found display omitted resolution guidance");
const malformed = formatQuotaResponse({ providers: "not-an-array" });
if (malformed.kind !== "error" || malformed.errorKind !== "invalid") throw new Error("invalid response was not an error display");
JS
)
  status=$?
  expect_code 0 "$status" "quota formatter fresh, stale, missing-window, and command-error cases"
  [ -z "$out" ] || fail "quota formatter test printed output: $out"
  pass "quota formatter keeps fresh headroom, stale diagnostics, missing windows, and command errors distinct"
}

test_extension_registration() {
  local fixture out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for Pi quota extension registration test"
    return 0
  fi

  fixture="$TMP_ROOT/registration"
  make_ts_fixture "$fixture"
  out=$(cd "$fixture" && NODE_NO_WARNINGS=1 node --input-type=module 2>&1 <<'JS'
const commands = new Map();
const shortcuts = new Map();
const pi = {
  registerCommand(name, definition) { commands.set(name, definition); },
  registerShortcut(key, definition) { shortcuts.set(key, definition); },
};
const { default: install, resolveQuotaAxiCommand } = await import("./fm-quota.ts");
install(pi);
const originalPath = process.env.PATH;
const originalNvmBin = process.env.NVM_BIN;
process.env.PATH = "";
process.env.NVM_BIN = `${process.cwd()}/fake-node-bin`;
const resolved = resolveQuotaAxiCommand(process.cwd());
process.env.PATH = originalPath;
process.env.NVM_BIN = originalNvmBin;
if (resolved?.executable !== `${process.cwd()}/fake-node-bin/quota-axi`) throw new Error(`local Node quota-axi resolution failed: ${JSON.stringify(resolved)}`);
if (!commands.has("quota")) throw new Error("/quota was not registered");
if (!shortcuts.has("ctrl+shift+q")) throw new Error("Ctrl+Shift+Q was not registered");
if (!commands.get("quota").description.includes("press r")) throw new Error("manual refresh was not documented");
if (!shortcuts.get("ctrl+shift+q").description.includes("/quota")) throw new Error("shortcut description did not point to /quota");

let overlay;
const theme = {
  fg(_tone, text) { return text; },
  bold(text) { return text; },
};
await commands.get("quota").handler("", {
  mode: "tui",
  cwd: process.cwd(),
  ui: {
    custom(factory) {
      overlay = factory({ requestRender() {} }, theme, {}, () => {});
      return Promise.resolve();
    },
  },
});
const idleLines = overlay.render(60);
if (idleLines.some((line) => line.length !== 60)) {
  throw new Error(`overlay lines did not fill the requested width: ${JSON.stringify(idleLines)}`);
}
JS
)
  status=$?
  expect_code 0 "$status" "quota extension command and shortcut registration"
  [ -z "$out" ] || fail "quota registration test printed output: $out"
  pass "quota extension registers /quota and the documented Ctrl+Shift+Q shortcut"
}

test_formatter_cases
test_extension_registration

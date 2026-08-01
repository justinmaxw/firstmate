// Firstmate's project-local read-only Pi quota menu.
//
// Open it with /quota or Ctrl+Shift+Q, then press r for a manual refresh.
// The menu runs quota-axi directly with stdin closed and never starts a model CLI.
import { spawn, type ChildProcess } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { dirname, delimiter, isAbsolute, join, resolve } from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
  Theme,
} from "@earendil-works/pi-coding-agent";
import {
  Key,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  type Component,
  type TUI,
} from "@earendil-works/pi-tui";
import {
  formatQuotaError,
  formatQuotaResponse,
  type QuotaDisplay,
  type QuotaDisplayModel,
  type QuotaProviderDisplay,
  type QuotaWindowDisplay,
} from "./lib/fm-quota-menu.ts";

const QUOTA_ARGS = ["--provider", "claude,codex", "--json"];
const MAX_OUTPUT_BYTES = 1_000_000;

type QuotaCommand = {
  executable: string;
  args: string[];
};

type OverlayState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "result"; result: QuotaDisplay };

export default function (pi: ExtensionAPI) {
  const openQuota = async (ctx: ExtensionContext): Promise<void> => {
    if (ctx.mode !== "tui") {
      ctx.ui.notify("The quota menu requires interactive Pi mode.", "warning");
      return;
    }

    await ctx.ui.custom<void>(
      (tui, theme, _keybindings, done) =>
        new QuotaOverlay(tui, theme, ctx.cwd, done),
      {
        overlay: true,
        overlayOptions: {
          anchor: "center",
          width: "92%",
          minWidth: 24,
          maxHeight: "90%",
          margin: 1,
        },
      },
    );
  };

  pi.registerCommand("quota", {
    description:
      "Open the read-only Claude and Codex quota menu; press r to refresh.",
    handler: async (_args, ctx) => openQuota(ctx),
  });
  pi.registerShortcut("ctrl+shift+q", {
    description: "Open the read-only quota menu (the same view as /quota).",
    handler: async (ctx) => openQuota(ctx),
  });
}

class QuotaOverlay implements Component {
  private state: OverlayState = { kind: "idle" };
  private requestController: AbortController | undefined;
  private requestNumber = 0;
  private closed = false;
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly cwd: string;
  private readonly done: () => void;

  constructor(tui: TUI, theme: Theme, cwd: string, done: () => void) {
    this.tui = tui;
    this.theme = theme;
    this.cwd = cwd;
    this.done = done;
  }

  handleInput(data: string): void {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
      this.close();
      return;
    }
    if (matchesKey(data, "r") || matchesKey(data, Key.ctrl("r"))) {
      this.refresh();
    }
  }

  render(width: number): string[] {
    if (width < 5)
      return [
        truncateToWidth("Quota: r refresh, Esc close", Math.max(1, width), ""),
      ];

    const innerWidth = width - 2;
    const lines = this.contentLines();
    const title = truncateToWidth(" Quota - Claude + Codex ", innerWidth, "");
    const titleWidth = visibleWidth(title);
    const leftBorder = Math.max(0, Math.floor((innerWidth - titleWidth) / 2));
    const rightBorder = Math.max(0, innerWidth - titleWidth - leftBorder);
    const output = [
      this.theme.fg("border", `╭${"─".repeat(leftBorder)}`) +
        this.theme.fg("accent", title) +
        this.theme.fg("border", `${"─".repeat(rightBorder)}╮`),
    ];

    for (const line of lines) {
      const body = truncateToWidth(` ${line}`, innerWidth, "...");
      const padding = " ".repeat(Math.max(0, innerWidth - visibleWidth(body)));
      output.push(
        this.theme.fg("border", "│") +
          body +
          padding +
          this.theme.fg("border", "│"),
      );
    }
    output.push(this.theme.fg("border", `╰${"─".repeat(innerWidth)}╯`));
    return output;
  }

  invalidate(): void {}

  dispose(): void {
    this.closed = true;
    this.requestController?.abort();
    this.requestController = undefined;
  }

  private contentLines(): string[] {
    if (this.state.kind === "idle") {
      return [
        this.theme.fg("muted", "No quota read yet."),
        "",
        this.theme.fg("dim", "Press r to refresh manually."),
        this.theme.fg("dim", "Esc or Ctrl+C closes this menu."),
      ];
    }
    if (this.state.kind === "loading") {
      return [
        this.theme.fg("warning", "Reading quota-axi..."),
        "",
        this.theme.fg("dim", "Esc or Ctrl+C cancels the read."),
      ];
    }
    if (this.state.result.kind === "error") {
      return [
        this.theme.fg("error", "Quota read unavailable"),
        this.theme.fg("muted", this.state.result.message),
        "",
        this.theme.fg("dim", "Press r to retry, or Esc to close."),
      ];
    }
    return this.renderData(this.state.result);
  }

  private renderData(data: QuotaDisplayModel): string[] {
    const lines: string[] = [];
    if (data.generatedAt)
      lines.push(this.theme.fg("dim", `Generated: ${data.generatedAt}`));
    lines.push(
      this.theme.fg("dim", "OpenAI subscription quota is shown through Codex."),
      "",
    );

    data.providers.forEach((provider, index) => {
      lines.push(...this.renderProvider(provider));
      if (index < data.providers.length - 1)
        lines.push(
          this.theme.fg("borderMuted", "────────────────────────────────"),
        );
    });

    lines.push(
      "",
      this.theme.fg("dim", "r refresh manually  •  Esc/Ctrl+C close"),
    );
    return lines;
  }

  private renderProvider(provider: QuotaProviderDisplay): string[] {
    const status = this.color(provider.statusTone, provider.status);
    const lines = [
      `${this.theme.bold(provider.title)}  ${status}`,
      ` Plan: ${this.theme.fg("muted", provider.plan)}  Source: ${this.theme.fg("muted", provider.source)}`,
    ];

    const current =
      provider.currentRemaining === null
        ? this.theme.fg("warning", "unknown")
        : this.theme.fg(
            "success",
            `${formatPercent(provider.currentRemaining)}%`,
          );
    const scope = provider.currentScope ? ` (${provider.currentScope})` : "";
    lines.push(` Current headroom: ${current}${scope}`);

    if (provider.refreshedAt)
      lines.push(` Refreshed: ${this.theme.fg("muted", provider.refreshedAt)}`);
    if (provider.windows.length === 0) {
      lines.push(` Windows: ${this.theme.fg("warning", "none reported")}`);
    } else {
      lines.push(this.theme.fg("dim", " Reported windows:"));
      for (const window of provider.windows)
        lines.push(...this.renderWindow(window));
    }
    if (provider.message)
      lines.push(
        this.theme.fg(
          provider.statusTone === "success" ? "muted" : "warning",
          ` ! ${provider.message}`,
        ),
      );
    return lines;
  }

  private renderWindow(window: QuotaWindowDisplay): string[] {
    const reported =
      window.reportedRemaining === null
        ? "unknown"
        : `${formatPercent(window.reportedRemaining)}%`;
    const diagnostic = window.diagnostic
      ? this.theme.fg("warning", " diagnostic")
      : "";
    return [
      `  ${window.label}: ${reported} reported${diagnostic}`,
      `    reset: ${this.theme.fg("muted", window.reset)}  pace: ${this.theme.fg("muted", window.pace)}`,
    ];
  }

  private color(
    tone: QuotaProviderDisplay["statusTone"],
    text: string,
  ): string {
    return this.theme.fg(tone, `[${text}]`);
  }

  private refresh(): void {
    if (this.closed) return;
    this.requestController?.abort();
    const controller = new AbortController();
    const requestNumber = ++this.requestNumber;
    this.requestController = controller;
    this.state = { kind: "loading" };
    this.tui.requestRender();

    readQuota(this.cwd, controller.signal)
      .then((result) => {
        if (this.closed || requestNumber !== this.requestNumber) return;
        this.state = { kind: "result", result };
        this.requestController = undefined;
        this.tui.requestRender();
      })
      .catch(() => {
        if (
          this.closed ||
          requestNumber !== this.requestNumber ||
          controller.signal.aborted
        )
          return;
        this.state = { kind: "result", result: formatQuotaError("failed") };
        this.requestController = undefined;
        this.tui.requestRender();
      });
  }

  private close(): void {
    if (this.closed) return;
    this.closed = true;
    this.requestController?.abort();
    this.requestController = undefined;
    this.done();
  }
}

async function readQuota(
  cwd: string,
  signal: AbortSignal,
): Promise<QuotaDisplay> {
  const command = resolveQuotaAxiCommand(cwd);
  if (!command) return formatQuotaError("not-found");

  try {
    const stdout = await executeQuotaCommand(command, signal, cwd);
    let parsed: unknown;
    try {
      parsed = JSON.parse(stdout);
    } catch {
      return formatQuotaError("invalid");
    }
    return formatQuotaResponse(parsed);
  } catch (error) {
    if (signal.aborted) throw error;
    return formatQuotaError("failed");
  }
}

function executeQuotaCommand(
  command: QuotaCommand,
  signal: AbortSignal,
  cwd: string,
): Promise<string> {
  return new Promise((resolveOutput, rejectOutput) => {
    let stdout = "";
    let settled = false;
    let child: ChildProcess;
    try {
      child = spawn(command.executable, [...command.args, ...QUOTA_ARGS], {
        cwd,
        stdio: ["ignore", "pipe", "ignore"],
        signal,
      });
    } catch (error) {
      rejectOutput(error);
      return;
    }

    const settle = (callback: () => void): void => {
      if (settled) return;
      settled = true;
      callback();
    };
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (stdout.length < MAX_OUTPUT_BYTES) stdout += chunk;
      if (stdout.length > MAX_OUTPUT_BYTES)
        stdout = stdout.slice(0, MAX_OUTPUT_BYTES);
    });
    child.once("error", (error) => settle(() => rejectOutput(error)));
    child.once("close", (code) =>
      settle(() => {
        if (code === 0) resolveOutput(stdout);
        else rejectOutput(new Error("quota-axi exited unsuccessfully"));
      }),
    );
  });
}

export function resolveQuotaAxiCommand(cwd: string): QuotaCommand | undefined {
  const candidates: string[] = [];
  const add = (candidate: string): void => {
    if (!candidate || candidates.includes(candidate)) return;
    candidates.push(candidate);
  };

  for (const pathEntry of (process.env.PATH ?? "").split(delimiter)) {
    add(join(pathEntry || ".", "quota-axi"));
  }
  add(join(process.env.NVM_BIN ?? "", "quota-axi"));
  add(join(dirname(process.execPath), "quota-axi"));

  const nodeDir = dirname(process.execPath);
  const prefixes = new Set<string>([
    dirname(nodeDir),
    process.env.npm_config_prefix ?? "",
    process.env.NPM_CONFIG_PREFIX ?? "",
  ]);
  for (const prefix of prefixes) {
    if (!prefix) continue;
    add(join(prefix, "bin", "quota-axi"));
    add(
      join(
        prefix,
        "lib",
        "node_modules",
        "quota-axi",
        "dist",
        "bin",
        "quota-axi.js",
      ),
    );
    add(
      join(prefix, "lib", "node_modules", "quota-axi", "bin", "quota-axi.js"),
    );
  }

  let directory = resolve(cwd);
  while (true) {
    add(join(directory, "node_modules", ".bin", "quota-axi"));
    add(
      join(
        directory,
        "node_modules",
        "quota-axi",
        "dist",
        "bin",
        "quota-axi.js",
      ),
    );
    add(join(directory, "node_modules", "quota-axi", "bin", "quota-axi.js"));
    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }

  for (const candidate of candidates) {
    const command = executableCommand(candidate, cwd);
    if (command) return command;
  }
  return undefined;
}

function executableCommand(
  candidate: string,
  cwd: string,
): QuotaCommand | undefined {
  const normalized = isAbsolute(candidate)
    ? candidate
    : resolve(cwd, candidate);
  try {
    const stat = statSync(normalized);
    if (!stat.isFile()) return undefined;
    if (normalized.endsWith(".js")) {
      return { executable: process.execPath, args: [normalized] };
    }
    accessSync(normalized, constants.X_OK);
    return { executable: normalized, args: [] };
  } catch {
    return undefined;
  }
}

function formatPercent(value: number): string {
  return Number.isInteger(value)
    ? String(value)
    : value.toFixed(1).replace(/\.0$/, "");
}

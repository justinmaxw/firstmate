// Non-runtime reference for a future Baby Menu quota screen port.
//
// This file deliberately lives outside every auto-discovered extension directory.
// It preserves the former Pi overlay's visual design and interaction model without
// registering a command, shortcut, or executable quota reader.
import type { Theme } from "@earendil-works/pi-coding-agent";
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
  type QuotaDisplay,
  type QuotaDisplayModel,
  type QuotaProviderDisplay,
  type QuotaWindowDisplay,
} from "./quota-display-model.ts";

export type QuotaScreenState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "result"; result: QuotaDisplay };

export type QuotaScreenRefresh = (signal: AbortSignal) => Promise<QuotaDisplay>;

export class QuotaScreenReference implements Component {
  private state: QuotaScreenState = { kind: "idle" };
  private requestController: AbortController | undefined;
  private requestNumber = 0;
  private closed = false;
  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly refreshData: QuotaScreenRefresh;
  private readonly done: () => void;

  constructor(
    tui: TUI,
    theme: Theme,
    refreshData: QuotaScreenRefresh,
    done: () => void,
  ) {
    this.tui = tui;
    this.theme = theme;
    this.refreshData = refreshData;
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
    if (width < 5) {
      return [
        truncateToWidth("Quota: r refresh, Esc close", Math.max(1, width), ""),
      ];
    }

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
    if (data.generatedAt) {
      lines.push(this.theme.fg("dim", `Generated: ${data.generatedAt}`));
    }
    lines.push(
      this.theme.fg("dim", "OpenAI subscription quota is shown through Codex."),
      "",
    );

    data.providers.forEach((provider, index) => {
      lines.push(...this.renderProvider(provider));
      if (index < data.providers.length - 1) {
        lines.push(
          this.theme.fg("borderMuted", "────────────────────────────────"),
        );
      }
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
            `${formatQuotaPercent(provider.currentRemaining)}%`,
          );
    const scope = provider.currentScope ? ` (${provider.currentScope})` : "";
    lines.push(` Current headroom: ${current}${scope}`);

    if (provider.refreshedAt) {
      lines.push(` Refreshed: ${this.theme.fg("muted", provider.refreshedAt)}`);
    }
    if (provider.windows.length === 0) {
      lines.push(` Windows: ${this.theme.fg("warning", "none reported")}`);
    } else {
      lines.push(this.theme.fg("dim", " Reported windows:"));
      for (const window of provider.windows) {
        lines.push(...this.renderWindow(window));
      }
    }
    if (provider.message) {
      lines.push(
        this.theme.fg(
          provider.statusTone === "success" ? "muted" : "warning",
          ` ! ${provider.message}`,
        ),
      );
    }
    return lines;
  }

  private renderWindow(window: QuotaWindowDisplay): string[] {
    const reported =
      window.reportedRemaining === null
        ? "unknown"
        : `${formatQuotaPercent(window.reportedRemaining)}%`;
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

    this.refreshData(controller.signal)
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
        ) {
          return;
        }
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

export function formatQuotaPercent(value: number): string {
  return Number.isInteger(value)
    ? String(value)
    : value.toFixed(1).replace(/\.0$/, "");
}

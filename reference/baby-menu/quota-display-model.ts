export type QuotaPaceLabel = "ahead" | "on pace" | "behind" | "unknown";

export type QuotaWindowDisplay = {
  id: string;
  label: string;
  reportedRemaining: number | null;
  reset: string;
  pace: QuotaPaceLabel;
  diagnostic: boolean;
};

export type QuotaProviderDisplay = {
  id: "claude" | "codex";
  title: string;
  status: string;
  statusTone: "success" | "warning" | "error" | "muted";
  plan: string;
  source: string;
  currentRemaining: number | null;
  currentScope: string | null;
  windows: QuotaWindowDisplay[];
  refreshedAt: string | null;
  message: string | null;
  remedyCommand: string | null;
};

export type QuotaDisplayModel = {
  kind: "data";
  generatedAt: string | null;
  providers: QuotaProviderDisplay[];
};

export type QuotaErrorKind = "not-found" | "failed" | "invalid";

export type QuotaErrorDisplay = {
  kind: "error";
  errorKind: QuotaErrorKind;
  message: string;
};

export type QuotaDisplay = QuotaDisplayModel | QuotaErrorDisplay;

type RecordValue = Record<string, unknown>;

type ProviderId = "claude" | "codex";

const PROVIDER_META: Record<ProviderId, { title: string }> = {
  claude: { title: "Anthropic / Claude" },
  codex: { title: "OpenAI / Codex" },
};

const PROVIDER_ORDER: ProviderId[] = ["claude", "codex"];

export function formatQuotaResponse(input: unknown): QuotaDisplay {
  const response = asRecord(input);
  const rawProviders = response?.providers;
  if (!response || !Array.isArray(rawProviders)) {
    return {
      kind: "error",
      errorKind: "invalid",
      message: "quota-axi returned data in an unexpected format.",
    };
  }

  const providers = new Map<ProviderId, RecordValue>();
  for (const rawProvider of rawProviders) {
    const provider = asRecord(rawProvider);
    const id = provider?.provider;
    if ((id === "claude" || id === "codex") && provider) {
      providers.set(id, provider);
    }
  }

  return {
    kind: "data",
    generatedAt: stringValue(response.generatedAt) ?? null,
    providers: PROVIDER_ORDER.map((id) =>
      formatProvider(id, providers.get(id)),
    ),
  };
}

export function formatQuotaError(errorKind: QuotaErrorKind): QuotaErrorDisplay {
  const messages: Record<QuotaErrorKind, string> = {
    "not-found":
      "quota-axi was not found on PATH or in the local Node installation.",
    failed: "quota-axi could not read the provider quota.",
    invalid: "quota-axi returned data in an unexpected format.",
  };
  return { kind: "error", errorKind, message: messages[errorKind] };
}

function formatProvider(
  id: ProviderId,
  provider: RecordValue | undefined,
): QuotaProviderDisplay {
  if (!provider) {
    return {
      id,
      title: PROVIDER_META[id].title,
      status: "Not reported",
      statusTone: "muted",
      plan: "unknown",
      source: "unknown",
      currentRemaining: null,
      currentScope: null,
      windows: [],
      refreshedAt: null,
      message: "This provider was not returned by quota-axi.",
      remedyCommand: null,
    };
  }

  const state = asRecord(provider.state) ?? {};
  const status = stringValue(state.status) ?? "unknown";
  const windows = Array.isArray(provider.windows) ? provider.windows : [];
  const untrustedWindowIds = stringArray(state.untrustedWindowIds);
  const stale =
    status === "stale" || state.stale === true || untrustedWindowIds.length > 0;
  const displayStatus = stale ? "Stale" : statusLabel(status);
  const semantics = asRecord(provider.quotaSemantics);
  const availability = selectAvailability(semantics?.effectiveAvailability);
  const availabilityStatus = stringValue(availability?.status);
  const availabilityRemaining = numberValue(
    availability?.effectivePercentRemaining,
  );
  const currentRemaining =
    !stale && availabilityStatus === "known" && availabilityRemaining !== null
      ? availabilityRemaining
      : null;
  const currentScope = availability
    ? (stringValue(availability.scope) ?? null)
    : null;
  const displayWindows = windows.map((window) =>
    formatWindow(window, stale, untrustedWindowIds),
  );
  const remedyCommand = stringValue(state.remedyCommand) ?? null;

  return {
    id,
    title: PROVIDER_META[id].title,
    status: displayStatus,
    statusTone: statusTone(displayStatus),
    plan: stringValue(provider.plan) ?? "unknown",
    source: sourceLabel(stringValue(provider.source)),
    currentRemaining,
    currentScope,
    windows: displayWindows,
    refreshedAt: stringValue(state.refreshedAt) ?? null,
    message: providerMessage({
      status,
      stale,
      currentRemainingKnown: currentRemaining !== null,
      hasWindows: displayWindows.length > 0,
      remedyCommand,
      reason: stringValue(state.reason),
    }),
    remedyCommand,
  };
}

function formatWindow(
  input: unknown,
  providerStale: boolean,
  untrustedWindowIds: string[],
): QuotaWindowDisplay {
  const window = asRecord(input) ?? {};
  const id = stringValue(window.id) ?? "unknown";
  const label = stringValue(window.label) ?? id;
  const reportedRemaining = numberValue(window.percentRemaining);
  const reset =
    stringValue(window.resetsAt) ??
    stringValue(window.resetText) ??
    "not reported";
  const paceRecord = asRecord(window.pace);
  const pace = paceLabel(stringValue(paceRecord?.status));

  return {
    id,
    label,
    reportedRemaining,
    reset,
    pace,
    diagnostic: providerStale || untrustedWindowIds.includes(id),
  };
}

function selectAvailability(input: unknown): RecordValue | undefined {
  if (!Array.isArray(input)) return undefined;
  const entries = input
    .map(asRecord)
    .filter((entry): entry is RecordValue => Boolean(entry));
  return (
    entries.find(
      (entry) => entry.scope === "all_models" || entry.scope === "all_products",
    ) ??
    entries.find((entry) => entry.status === "known") ??
    entries[0]
  );
}

function providerMessage(options: {
  status: string;
  stale: boolean;
  currentRemainingKnown: boolean;
  hasWindows: boolean;
  remedyCommand: string | null;
  reason: string | undefined;
}): string | null {
  if (options.remedyCommand) {
    return options.stale
      ? `Live quota is stale. Run ${options.remedyCommand} once, then press r to refresh.`
      : `Run ${options.remedyCommand} once, then press r to refresh.`;
  }
  if (options.stale) {
    return "Reported windows are diagnostic only; current headroom is unknown until a fresh read succeeds.";
  }
  if (options.status === "auth_required") {
    return "Authentication is required for this subscription before quota can be read.";
  }
  if (["unavailable", "error", "rate_limited"].includes(options.status)) {
    return "The provider quota is unavailable. Check provider login and press r to retry.";
  }
  if (options.currentRemainingKnown) {
    return null;
  }
  if (!options.hasWindows) {
    return "No quota windows were reported; current headroom is unknown.";
  }
  if (options.reason) {
    return `quota-axi reported ${options.reason}; press r to retry.`;
  }
  return "Effective current headroom is unknown; quota-axi reported no usable bound.";
}

function statusLabel(status: string): string {
  switch (status) {
    case "fresh":
      return "Fresh";
    case "auth_required":
      return "Auth required";
    case "rate_limited":
      return "Rate limited";
    case "unavailable":
      return "Unavailable";
    case "error":
      return "Error";
    default:
      return status === "unknown" ? "Unknown" : status;
  }
}

function statusTone(status: string): QuotaProviderDisplay["statusTone"] {
  if (status === "Fresh") return "success";
  if (status === "Stale" || status === "Rate limited") return "warning";
  if (
    status === "Error" ||
    status === "Auth required" ||
    status === "Unavailable"
  ) {
    return "error";
  }
  return "muted";
}

function sourceLabel(source: string | undefined): string {
  switch (source) {
    case "oauth":
      return "OAuth";
    case "cli-rpc":
      return "CLI RPC";
    case "api":
      return "API";
    case "web":
      return "Web";
    case "cache":
      return "Cache";
    case "unavailable":
      return "Unavailable";
    default:
      return source ?? "unknown";
  }
}

function paceLabel(status: string | undefined): QuotaPaceLabel {
  switch (status) {
    case "ahead":
      return "ahead";
    case "on_pace":
      return "on pace";
    case "behind":
      return "behind";
    default:
      return "unknown";
  }
}

function asRecord(value: unknown): RecordValue | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as RecordValue)
    : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

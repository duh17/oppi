/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { ProviderQuota, ProviderQuotasStatus } from "../../provider-quota.js";
import { createLocalApiCommandContext } from "../command-support.js";
import type { LocalApiConnection } from "../local-api-client.js";
import { formatQuotaRemaining } from "../quota.js";
import { setCapturedCliExitCode, writeHumanLine, writeJsonEnvelope } from "../output.js";
import { apiStatus } from "../resources.js";

type ModelListRow = {
  id: string;
  name: string;
  provider: string;
  contextWindow?: number;
  authKind?: string;
};

type ModelProviderGroup = {
  provider: string;
  display_name: string;
  quota: ProviderQuota | null;
  local: boolean;
  models: ModelListRow[];
};

export async function cmdModels(
  storage: LocalApiConnection,
  positional: string[],
  flags: Record<string, string>,
  signal?: AbortSignal,
): Promise<void> {
  const jsonOutput = flags.json === "true";
  const query = (flags.query?.trim() || positional.join(" ").trim() || "").trim();
  const { call, output } = createLocalApiCommandContext(storage, jsonOutput, signal);

  try {
    const [catalog, quotas] = await Promise.all([
      call<{ models?: unknown[] }>("/models"),
      call<ProviderQuotasStatus>("/server/provider-quotas"),
    ]);
    const models = (Array.isArray(catalog.models) ? catalog.models : [])
      .map(asModelRow)
      .filter((model): model is ModelListRow => model !== undefined);
    assertProviderQuotasStatus(quotas);
    const providers = groupModelsByProvider(models, quotas, query);
    output(
      {
        ...(query ? { query } : { query: null }),
        fetched_at: quotas.fetchedAt,
        providers,
        model_count: providers.reduce((sum, group) => sum + group.models.length, 0),
      },
      () => renderModelGroups(providers, query, quotas.fetchedAt),
    );
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    if (jsonOutput) {
      writeJsonEnvelope({
        ok: false,
        error: { message, ...(apiStatus(error) ? { status: apiStatus(error) } : {}) },
      });
      setCapturedCliExitCode(1);
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

function groupModelsByProvider(
  models: ModelListRow[],
  quotas: ProviderQuotasStatus,
  query: string,
): ModelProviderGroup[] {
  const filtered = query ? models.filter((model) => modelMatchesQuery(model, query)) : models;
  const quotaByProvider = new Map(
    quotas.providers.map((provider) => [provider.providerId.toLowerCase(), provider]),
  );
  const grouped = new Map<string, ModelListRow[]>();
  for (const model of filtered) {
    const key = model.provider;
    const rows = grouped.get(key) ?? [];
    rows.push(model);
    grouped.set(key, rows);
  }

  return [...grouped.entries()]
    .map(([provider, rows]) => {
      const quota = quotaByProvider.get(provider.toLowerCase()) ?? null;
      return {
        provider,
        display_name: quota?.displayName || provider,
        quota,
        local: isLocalProvider(rows),
        models: [...rows].sort((left, right) => left.name.localeCompare(right.name)),
      };
    })
    .sort((left, right) => {
      const leftAuth = left.quota?.authenticated === true ? 0 : 1;
      const rightAuth = right.quota?.authenticated === true ? 0 : 1;
      if (leftAuth !== rightAuth) return leftAuth - rightAuth;
      return left.display_name.localeCompare(right.display_name);
    });
}

function renderModelGroups(
  providers: ModelProviderGroup[],
  query: string,
  fetchedAt: number,
): void {
  const title = query ? `Models matching ${query}` : "Models";
  writeHumanLine(`  ${c.bold(title)}`);
  writeHumanLine(`  ${c.dim("─".repeat(48))}`);

  if (providers.length === 0) {
    writeHumanLine(`  ${c.dim(query ? "No models matched." : "No models available.")}`);
    writeHumanLine("");
    return;
  }

  for (const group of providers) {
    writeHumanLine("");
    const plan = group.quota?.planType ? `  ${c.dim(group.quota.planType)}` : "";
    writeHumanLine(`  ${c.bold(group.display_name)}${plan}`);
    renderProviderStatus(group.quota, group.local);

    const nameWidth = Math.max(12, ...group.models.map((model) => model.name.length));
    const idWidth = Math.max(18, ...group.models.map((model) => model.id.length));
    for (const model of group.models) {
      writeHumanLine(
        `    ${model.name.padEnd(nameWidth)}  ${c.cyan(model.id.padEnd(idWidth))}  ${c.dim(formatContextWindow(model.contextWindow))}`,
      );
    }
  }

  writeHumanLine("");
  writeHumanLine(`  ${c.dim(`Fetched ${new Date(fetchedAt).toLocaleString()}`)}`);
  writeHumanLine("");
}

function isLocalProvider(models: readonly ModelListRow[]): boolean {
  return models.length > 0 && models.every((model) => model.authKind === "local");
}

function renderProviderStatus(quota: ProviderQuota | null, local: boolean): void {
  if (local) {
    writeHumanLine(`    ${c.dim("Local")}`);
    return;
  }
  if (!quota) {
    writeHumanLine(`    ${c.dim("No quota reported")}`);
    return;
  }
  if (!quota.authenticated) {
    writeHumanLine(`    ${c.dim("Not configured")}`);
    return;
  }
  if (quota.error) writeHumanLine(`    ${c.red(quota.error)}`);
  if (quota.windows.length === 0 && !quota.error) {
    writeHumanLine(`    ${c.dim("No usage windows reported")}`);
    return;
  }
  const width = Math.max(0, ...quota.windows.map((window) => window.title.length));
  for (const window of quota.windows) {
    const used = `${Math.round(window.usedPercent)}% used`;
    writeHumanLine(
      `    ${window.title.padEnd(width)}  ${formatQuotaRemaining(window.remainingPercent)} ${c.dim(`· ${used}`)}`,
    );
  }
}

function modelMatchesQuery(model: ModelListRow, query: string): boolean {
  const needle = query.toLowerCase();
  return (
    model.id.toLowerCase().includes(needle) ||
    model.name.toLowerCase().includes(needle) ||
    model.provider.toLowerCase().includes(needle)
  );
}

export function formatContextWindow(value: number | undefined): string {
  if (!value || value <= 0) return "—";
  if (value >= 1_000_000) {
    const millions = value / 1_000_000;
    return `${trimDecimal(millions)}M`;
  }
  if (value >= 1000) {
    return `${trimDecimal(value / 1000)}K`;
  }
  return String(value);
}

function trimDecimal(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  return Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(1);
}

function asModelRow(value: unknown): ModelListRow | undefined {
  if (!isRecord(value) || typeof value.id !== "string" || !value.id.trim()) return undefined;
  const id = value.id.trim();
  const slash = id.indexOf("/");
  const providerFromId = slash > 0 ? id.slice(0, slash) : "";
  return {
    id,
    name: typeof value.name === "string" && value.name.trim() ? value.name.trim() : id,
    provider:
      typeof value.provider === "string" && value.provider.trim()
        ? value.provider.trim()
        : providerFromId || "unknown",
    ...(typeof value.contextWindow === "number" && Number.isFinite(value.contextWindow)
      ? { contextWindow: value.contextWindow }
      : {}),
    ...(typeof value.authKind === "string" ? { authKind: value.authKind } : {}),
  };
}

function assertProviderQuotasStatus(value: unknown): asserts value is ProviderQuotasStatus {
  if (
    !isRecord(value) ||
    !Array.isArray(value.providers) ||
    !isFiniteNumber(value.fetchedAt) ||
    !value.providers.every(isProviderQuota)
  ) {
    throw new Error("Invalid provider quota response from local API");
  }
}

function isProviderQuota(value: unknown): value is ProviderQuota {
  if (!isRecord(value)) return false;
  return (
    typeof value.providerId === "string" &&
    typeof value.displayName === "string" &&
    typeof value.authenticated === "boolean" &&
    (value.planType === null || typeof value.planType === "string") &&
    Array.isArray(value.windows) &&
    isFiniteNumber(value.fetchedAt)
  );
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

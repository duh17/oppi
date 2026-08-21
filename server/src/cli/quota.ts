/* eslint-disable no-console */
import * as c from "../ansi.js";
import type {
  ProviderQuota,
  ProviderQuotaPacing,
  ProviderQuotaWindow,
  ProviderQuotasStatus,
} from "../provider-quota.js";
import { createLocalApiCommandContext } from "./command-support.js";
import type { LocalApiConnection } from "./local-api-client.js";
import { setCapturedCliExitCode, writeHumanLine, writeJsonEnvelope } from "./output.js";
import { apiStatus } from "./resources.js";

export async function cmdQuota(
  storage: LocalApiConnection,
  jsonOutput = false,
  signal?: AbortSignal,
): Promise<void> {
  const { call, output } = createLocalApiCommandContext(storage, jsonOutput, signal);

  try {
    const status = await call<ProviderQuotasStatus>("/server/provider-quotas");
    assertProviderQuotasStatus(status);
    output({ ...status }, () => renderProviderQuotas(status));
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

function renderProviderQuotas(status: ProviderQuotasStatus): void {
  writeHumanLine(`  ${c.bold("Provider quotas")}`);
  writeHumanLine(`  ${c.dim("─".repeat(48))}`);

  if (status.providers.length === 0) {
    writeHumanLine(`  ${c.dim("No quota providers reported.")}`);
    writeHumanLine("");
    return;
  }

  for (const provider of status.providers) renderProviderQuota(provider);
  writeHumanLine(`  ${c.dim(`Fetched ${new Date(status.fetchedAt).toLocaleString()}`)}`);
  writeHumanLine("");
}

function renderProviderQuota(provider: ProviderQuota): void {
  const plan = provider.planType ? `  ${c.dim(provider.planType)}` : "";
  writeHumanLine("");
  writeHumanLine(`  ${c.bold(provider.displayName)}${plan}`);

  if (!provider.authenticated) {
    writeHumanLine(`    ${c.dim("Not configured")}`);
    return;
  }
  if (provider.error) {
    writeHumanLine(`    ${c.red(provider.error)}`);
  }
  if (provider.windows.length === 0 && !provider.error) {
    writeHumanLine(`    ${c.dim("No usage windows reported")}`);
  }

  const width = Math.max(0, ...provider.windows.map((window) => window.title.length));
  for (const window of provider.windows) {
    const remaining = `${formatPercent(window.remainingPercent)} left`;
    const used = `${formatPercent(window.usedPercent)} used`;
    const reset = window.resetAt
      ? ` · resets ${new Date(window.resetAt * 1000).toLocaleString()}`
      : "";
    writeHumanLine(
      `    ${window.title.padEnd(width)}  ${quotaColor(window.remainingPercent, remaining)} ${c.dim(`· ${used}${reset}`)}`,
    );
    writeHumanLine(`      ${c.dim(formatQuotaPacing(window))}`);
  }

  if (provider.credits?.unlimited) {
    writeHumanLine(`    ${c.dim("Credits")}  unlimited`);
  } else if (provider.credits?.balance !== null && provider.credits?.balance !== undefined) {
    writeHumanLine(`    ${c.dim("Credits")}  ${provider.credits.balance}`);
  }
  if (provider.prepaidBalanceCents !== null) {
    writeHumanLine(
      `    ${c.dim("Prepaid balance")}  $${(provider.prepaidBalanceCents / 100).toFixed(2)}`,
    );
  }
}

export function quotaHeadroomState(
  remainingPercent: number,
): "healthy" | "constrained" | "critical" {
  if (remainingPercent > 50) return "healthy";
  if (remainingPercent > 20) return "constrained";
  return "critical";
}

export function formatQuotaRemaining(remainingPercent: number): string {
  return quotaColor(remainingPercent, `${formatPercent(remainingPercent)} left`);
}

export function formatQuotaPacing(window: ProviderQuotaWindow): string {
  const pacing = window.pacing;
  const status = pacingStatusLabel(pacing?.status);
  if (status === "Pace unknown") return status;

  const supplyRatio = pacing?.supplyRatio;
  const ratio =
    supplyRatio !== null && supplyRatio !== undefined && Number.isFinite(supplyRatio)
      ? ` · supply ${formatRatio(supplyRatio)}x`
      : "";
  const timeRemainingSeconds = pacing?.timeRemainingSeconds;
  const reset =
    timeRemainingSeconds !== null &&
    timeRemainingSeconds !== undefined &&
    Number.isFinite(timeRemainingSeconds) &&
    timeRemainingSeconds > 0
      ? ` · resets in ${formatDuration(timeRemainingSeconds)}`
      : window.resetAt
        ? ` · resets ${new Date(window.resetAt * 1000).toLocaleString()}`
        : "";
  return `Pace: ${status}${ratio}${reset}`;
}

function pacingStatusLabel(status: ProviderQuotaPacing["status"] | undefined): string {
  switch (status) {
    case "plenty":
      return "Plenty";
    case "on_pace":
      return "On pace";
    case "conserve":
      return "Conserve";
    default:
      return "Pace unknown";
  }
}

function formatRatio(value: number): string {
  const rounded = Math.round(value * 100) / 100;
  return Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(2);
}

function formatDuration(seconds: number): string {
  const totalSeconds = Math.max(0, Math.floor(seconds));
  const days = Math.floor(totalSeconds / 86_400);
  const hours = Math.floor((totalSeconds % 86_400) / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  if (days > 0) return hours > 0 ? `${days}d ${hours}h` : `${days}d`;
  if (hours > 0) return minutes > 0 ? `${hours}h ${minutes}m` : `${hours}h`;
  if (minutes > 0) return `${minutes}m`;
  return `${totalSeconds}s`;
}

function quotaColor(remainingPercent: number, text: string): string {
  switch (quotaHeadroomState(remainingPercent)) {
    case "healthy":
      return c.green(text);
    case "constrained":
      return c.yellow(text);
    case "critical":
      return c.red(text);
  }
}

function formatPercent(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  return `${Number.isInteger(rounded) ? rounded.toFixed(0) : rounded.toFixed(1)}%`;
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
    isNullableString(value.planType) &&
    Array.isArray(value.windows) &&
    value.windows.every(isProviderQuotaWindow) &&
    isProviderQuotaCredits(value.credits) &&
    isNullableFiniteNumber(value.prepaidBalanceCents) &&
    isFiniteNumber(value.fetchedAt) &&
    (value.error === undefined || typeof value.error === "string")
  );
}

function isProviderQuotaWindow(value: unknown): value is ProviderQuotaWindow {
  if (!isRecord(value)) return false;
  return (
    typeof value.key === "string" &&
    typeof value.shortLabel === "string" &&
    typeof value.title === "string" &&
    isFiniteNumber(value.usedPercent) &&
    isFiniteNumber(value.remainingPercent) &&
    isNullableFiniteNumber(value.limitWindowSeconds) &&
    isNullableFiniteNumber(value.resetAt) &&
    typeof value.includeWeekdayInReset === "boolean" &&
    (value.pacing === undefined || isProviderQuotaPacing(value.pacing))
  );
}

export function isProviderQuotaPacing(value: unknown): value is ProviderQuotaPacing {
  if (!isRecord(value)) return false;
  return (
    (value.source === "snapshot" || value.source === "observed" || value.source === "unknown") &&
    (value.status === "plenty" ||
      value.status === "on_pace" ||
      value.status === "conserve" ||
      value.status === "unknown") &&
    isNullableFiniteNumber(value.timeRemainingSeconds) &&
    isNullableFiniteNumber(value.supplyRatio) &&
    isNullableFiniteNumber(value.targetBurnPercentPerHour) &&
    isNullableFiniteNumber(value.recentBurnPercentPerHour) &&
    isNullableFiniteNumber(value.paceRatio) &&
    isNullableFiniteNumber(value.projectedExhaustionAt) &&
    isNullableFiniteNumber(value.projectedRemainingPercent)
  );
}

function isProviderQuotaCredits(value: unknown): boolean {
  if (value === null) return true;
  if (!isRecord(value)) return false;
  return (
    typeof value.hasCredits === "boolean" &&
    typeof value.unlimited === "boolean" &&
    isNullableString(value.balance)
  );
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === "string";
}

function isNullableFiniteNumber(value: unknown): value is number | null {
  return value === null || isFiniteNumber(value);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

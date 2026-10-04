/** Session stats helpers shared by the SDK and durable backends. */

import { toRecord } from "./session-command-parse.js";

export interface SessionModelUsageSnapshot {
  provider?: string;
  model: string;
  tokens: number;
  cost: number;
}

/** Bucket for usage without model identity: tool results and summaries. */
export const TOOLS_SUMMARIES_USAGE_KEY = "tools-summaries";
export const TOOLS_SUMMARIES_USAGE_LABEL = "Tools & summaries";

export function estimateTokensFromChars(chars: number): number {
  if (chars <= 0) {
    return 0;
  }
  return Math.max(1, Math.ceil(chars / 4));
}

function finiteNonNegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
}

export function addUsageToModelBreakdown(
  byModel: Map<string, SessionModelUsageSnapshot>,
  key: string,
  model: string,
  provider: string | undefined,
  value: unknown,
): void {
  const usage = toRecord(value);
  const cost = toRecord(usage.cost);
  const current = byModel.get(key) ?? {
    ...(provider ? { provider } : {}),
    model,
    tokens: 0,
    cost: 0,
  };
  current.tokens +=
    finiteNonNegative(usage.input) +
    finiteNonNegative(usage.output) +
    finiteNonNegative(usage.cacheRead) +
    finiteNonNegative(usage.cacheWrite);
  current.cost += finiteNonNegative(cost.total);
  byModel.set(key, current);
}

/** Non-empty buckets, most expensive first. */
export function sortedModelUsage(
  byModel: ReadonlyMap<string, SessionModelUsageSnapshot>,
): SessionModelUsageSnapshot[] {
  return [...byModel.values()]
    .filter((entry) => entry.tokens > 0 || entry.cost > 0)
    .sort((left, right) => right.cost - left.cost);
}

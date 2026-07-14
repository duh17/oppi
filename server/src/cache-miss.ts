/**
 * Experimental live-only projection of Pi's opt-in cache-miss notice.
 *
 * Tracking starts with the first assistant response observed by the current
 * runtime; notices are neither persisted nor reconstructed from history. Keep
 * this detector aligned with Pi until Pi exposes the notice through its SDK.
 */

/** Anthropic's default prompt-cache TTL, matching Pi's transcript notice. */
export const CACHE_MISS_TTL_MS = 5 * 60 * 1000;
const CACHE_MISS_NOISE_FLOOR_TOKENS = 1024;
const CACHE_MISS_NOTICE_TOKENS = 20_000;
const CACHE_MISS_NOTICE_COST = 0.1;

export type CacheMissReason = "model_switch" | "idle" | "other";

export interface CacheMissNotice {
  id: string;
  missedTokens: number;
  missedCost: number;
  idleMs: number;
  reason: CacheMissReason;
}

export interface CacheMissTrackerState {
  previous?: {
    promptTokens: number;
    modelKey: string;
    timestamp: number;
    reportedCache: boolean;
  };
}

export interface CacheMissModelPriceSource {
  find(
    provider: string,
    modelId: string,
  ):
    | {
        cost: {
          cacheRead: number;
        };
      }
    | undefined;
}

interface CacheUsage {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  cost: {
    input: number;
    cacheRead: number;
    cacheWrite: number;
  };
}

export interface CacheMissAssistantMessage {
  role: "assistant";
  provider: string;
  model: string;
  timestamp: number;
  stopReason?: string;
  usage: CacheUsage;
}

function finiteNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function asCacheMissAssistantMessage(value: unknown): CacheMissAssistantMessage | undefined {
  if (!value || typeof value !== "object") return undefined;
  const message = value as Record<string, unknown>;
  if (message.role !== "assistant") return undefined;
  if (typeof message.provider !== "string" || typeof message.model !== "string") return undefined;
  if (typeof message.timestamp !== "number" || !Number.isFinite(message.timestamp))
    return undefined;
  if (!message.usage || typeof message.usage !== "object") return undefined;

  const usage = message.usage as Record<string, unknown>;
  const cost =
    usage.cost && typeof usage.cost === "object" ? (usage.cost as Record<string, unknown>) : {};

  return {
    role: "assistant",
    provider: message.provider,
    model: message.model,
    timestamp: message.timestamp,
    ...(typeof message.stopReason === "string" ? { stopReason: message.stopReason } : {}),
    usage: {
      input: finiteNumber(usage.input),
      cacheRead: finiteNumber(usage.cacheRead),
      cacheWrite: finiteNumber(usage.cacheWrite),
      cost: {
        input: finiteNumber(cost.input),
        cacheRead: finiteNumber(cost.cacheRead),
        cacheWrite: finiteNumber(cost.cacheWrite),
      },
    },
  };
}

function previousRequest(
  message: CacheMissAssistantMessage,
  reportedCache: boolean,
): CacheMissTrackerState["previous"] {
  const { usage } = message;
  const promptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
  if (promptTokens <= 0) return undefined;
  return {
    promptTokens,
    modelKey: `${message.provider}/${message.model}`,
    timestamp: message.timestamp,
    reportedCache: reportedCache || usage.cacheRead + usage.cacheWrite > 0,
  };
}

export function observeCacheMiss(
  tracker: CacheMissTrackerState,
  message: CacheMissAssistantMessage,
  models?: CacheMissModelPriceSource,
): CacheMissNotice | undefined {
  const previous = tracker.previous;
  const { usage } = message;
  const promptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
  let notice: CacheMissNotice | undefined;

  if (
    previous &&
    promptTokens > 0 &&
    (usage.cacheRead + usage.cacheWrite > 0 || previous.reportedCache)
  ) {
    const missedTokens = Math.min(previous.promptTokens, promptTokens) - usage.cacheRead;
    if (missedTokens > CACHE_MISS_NOISE_FLOOR_TOKENS) {
      const paidTokens = usage.input + usage.cacheWrite;
      const paidPerToken =
        paidTokens > 0 ? (usage.cost.input + usage.cost.cacheWrite) / paidTokens : 0;
      const readPerToken =
        usage.cacheRead > 0
          ? usage.cost.cacheRead / usage.cacheRead
          : (models?.find(message.provider, message.model)?.cost.cacheRead ?? 0) / 1_000_000;
      const missedCost = missedTokens * Math.max(0, paidPerToken - readPerToken);

      if (missedTokens >= CACHE_MISS_NOTICE_TOKENS || missedCost >= CACHE_MISS_NOTICE_COST) {
        const idleMs = Math.max(0, message.timestamp - previous.timestamp);
        const modelChanged = `${message.provider}/${message.model}` !== previous.modelKey;
        notice = {
          id: `cache-miss:${message.timestamp}:${message.provider}/${message.model}`,
          missedTokens,
          missedCost,
          idleMs,
          reason: modelChanged ? "model_switch" : idleMs >= CACHE_MISS_TTL_MS ? "idle" : "other",
        };
      }
    }
  }

  tracker.previous = previousRequest(message, previous?.reportedCache ?? false) ?? previous;
  return notice;
}

export function resetCacheMissTracker(tracker: CacheMissTrackerState): void {
  tracker.previous = undefined;
}

export function shouldDisplayCacheMissForMessage(message: CacheMissAssistantMessage): boolean {
  return message.stopReason !== "aborted" && message.stopReason !== "error";
}

export function formatCacheMissNotice(notice: CacheMissNotice): string {
  const tokens =
    notice.missedTokens < 10_000
      ? `${(notice.missedTokens / 1_000).toFixed(1)}k`
      : `${Math.round(notice.missedTokens / 1_000)}k`;
  const cost = notice.missedCost >= 0.01 ? ` (~$${notice.missedCost.toFixed(2)})` : "";
  const detail = `${tokens} tokens re-billed${cost}`;
  if (notice.reason === "model_switch") return `Cache miss after model switch: ${detail}`;
  if (notice.reason === "idle") {
    return `Cache miss after ${Math.round(notice.idleMs / 60_000)}m idle: ${detail}`;
  }
  return `Cache miss: ${detail}`;
}

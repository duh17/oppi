/**
 * Maps the error text of a failed turn to the closed `error_kind` vocabulary of `server.turn`.
 *
 * The text is read here and never leaves: only the returned enum value becomes a tag. Order
 * matters. A crashed worker and a request too large to ever succeed win over the provider's HTTP
 * status, a specific status wins over wording (an abort included), and wording wins over a bare
 * status class.
 *
 * Error text can be a whole provider HTML page, so every pattern here must stay linear: no
 * unbounded gap (`.*`) between two terms and no two adjacent quantifiers over the same class.
 */

import type { EventTags } from "./catalog.js";

export type TurnErrorKind = NonNullable<EventTags<"server.turn">["error_kind"]>;

/**
 * The status a provider error leads with (`529 {"type":"error",...}`, `429: ...`) or names
 * (`status 503`, `"status": 503`, `HTTP 502`). A number elsewhere in the text, such as a token
 * count, is not a status.
 */
const STATUS_PATTERNS = [
  /^\s*(?:error:?\s*)?([45]\d\d)\b/,
  /\bstatus(?:\s*code)?["']?\s*(?:[:=]\s*)?([45]\d\d)\b/,
  /\bhttp\s*([45]\d\d)\b/,
];

function httpStatus(message: string): number | undefined {
  for (const pattern of STATUS_PATTERNS) {
    const match = pattern.exec(message);
    if (match?.[1]) return Number(match[1]);
  }
  return undefined;
}

function specificStatusKind(status: number): TurnErrorKind | undefined {
  switch (status) {
    case 401:
    case 403:
      return "auth";
    case 408:
    case 504:
      return "timeout";
    case 413:
      return "request_too_large";
    case 429:
      return "rate_limit";
    case 503:
    case 529:
      return "overloaded";
    default:
      return undefined;
  }
}

function includesAny(message: string, needles: readonly string[]): boolean {
  return needles.some((needle) => message.includes(needle));
}

function kindFromWording(message: string): TurnErrorKind {
  if (
    includesAny(message, [
      "overloaded",
      "service_unavailable",
      "service unavailable",
      "temporarily unavailable",
      "server is busy",
      "at capacity",
    ])
  ) {
    return "overloaded";
  }
  if (
    includesAny(message, ["rate_limit", "rate limit", "resource_exhausted", "quota", "usage limit"])
  ) {
    return "rate_limit";
  }
  if (
    includesAny(message, [
      "unauthorized",
      "authentication",
      "invalid api key",
      "no api key",
      "forbidden",
    ])
  ) {
    return "auth";
  }
  if (includesAny(message, ["timed out", "timeout", "etimedout"])) return "timeout";
  if (/\babort(?:ed|error)?\b|\bcancel(?:l)?ed\b/.test(message)) return "cancelled";
  if (
    includesAny(message, [
      "connection",
      "econn",
      "enotfound",
      "eai_again",
      "fetch failed",
      "network",
      "socket",
    ])
  ) {
    return "network";
  }
  if (message.includes("json") && message.includes("parse")) return "json_parse";
  if (message.includes("terminated")) return "terminated";
  return "other";
}

/**
 * The agent runtime process behind the turn died or never started; no provider was involved.
 * Matches the runtime's own messages (`worker exited early`, `worker failed`), at most two words
 * apart, and a signal kill.
 */
const RUNTIME_CRASH =
  /\bworker(?:\s+\w+){0,2}?\s+(?:exited|failed|crash(?:ed)?|died)\b|exited early|\bsig(?:kill|segv|abrt)\b/;

const CONTEXT_OVERFLOW = [
  "request_too_large",
  "context_length",
  "context length",
  "context window",
  "prompt is too long",
  "maximum context",
  "too many tokens",
];

export function classifyTurnError(errorMessage: unknown): TurnErrorKind {
  if (typeof errorMessage !== "string") return "other";
  const message = errorMessage.toLowerCase();

  if (RUNTIME_CRASH.test(message)) return "runtime_crash";
  if (includesAny(message, CONTEXT_OVERFLOW)) return "request_too_large";

  const status = httpStatus(message);
  const fromStatus = status === undefined ? undefined : specificStatusKind(status);
  if (fromStatus) return fromStatus;

  const fromWording = kindFromWording(message);
  if (fromWording !== "other" || status === undefined) return fromWording;
  return status >= 500 ? "http_5xx" : "http_4xx";
}

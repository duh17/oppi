/**
 * Dictation pipeline types.
 *
 * Defines the WS protocol messages (client/server) and server-side
 * configuration for dictation routed through the server ASR stream.
 */

// ─── Config ───

export type AsrProviderId = "http" | "openai-codex" | "xai";

export interface DictationConfig {
  /** Explicit backend. Omitted with a non-empty sttEndpoint means "http". */
  backend?: "http";
  /** STT vendor. Omitted means infer from sttEndpoint, else Yuwp/http. */
  provider?: AsrProviderId;
  /** STT backend endpoint for the HTTP backend. */
  sttEndpoint?: string;

  /** Model to request from the STT backend. */
  sttModel: string;
}

/** Resolve the STT vendor from explicit asr.provider or well-known API hosts. */
export function resolveAsrProvider(
  asr:
    | {
        provider?: string;
        sttEndpoint?: string;
      }
    | undefined,
): AsrProviderId {
  if (asr?.provider === "openai-codex" || asr?.provider === "openai") {
    return "openai-codex";
  }
  if (asr?.provider === "xai" || asr?.provider === "http") {
    return asr.provider;
  }
  const endpoint = asr?.sttEndpoint?.trim();
  if (!endpoint) return "http";
  try {
    const host = new URL(endpoint).hostname.toLowerCase();
    if (host === "api.openai.com") return "openai-codex";
    if (host === "api.x.ai") return "xai";
  } catch {
    return "http";
  }
  return "http";
}

/** True when server dictation has a configured STT backend. */
export function isDictationStreamEnabled(
  asr:
    | {
        backend?: string;
        extension?: string;
        provider?: string;
        sttEndpoint?: string;
      }
    | undefined,
): boolean {
  const provider = resolveAsrProvider(asr);
  if (provider === "openai-codex" || provider === "xai") return true;
  return typeof asr?.sttEndpoint === "string" && asr.sttEndpoint.trim().length > 0;
}

export const DEFAULT_DICTATION_CONFIG: DictationConfig = {
  sttEndpoint: "http://localhost:7936",
  sttModel: "mlx-community/Qwen3-ASR-1.7B-bf16",
};

/** Max vocabulary phrases on dictation_start / HTTP stream_config. */
export const DICTATION_CONTEXT_MAX_PHRASES = 100;
/** Max UTF-8 bytes per phrase. */
export const DICTATION_CONTEXT_MAX_PHRASE_BYTES = 256;
/** Max UTF-8 bytes across all phrases. */
export const DICTATION_CONTEXT_MAX_TOTAL_BYTES = 8192;

export type DictationContextualStringsResult =
  | { ok: true; contextualStrings?: string[] }
  | { ok: false; error: string };

/** Cc: U+0000–001F and U+007F–009F. Rejected on the raw supplied string. */
function isDictationContextControlCodePoint(code: number): boolean {
  return code <= 0x1f || (code >= 0x7f && code <= 0x9f);
}

/**
 * Unicode White_Space plus U+200B and U+FEFF.
 * A raw string consisting only of these is empty vocabulary.
 */
function isDictationContextBlankCodePoint(code: number): boolean {
  switch (code) {
    case 0x09:
    case 0x0a:
    case 0x0b:
    case 0x0c:
    case 0x0d:
    case 0x20:
    case 0x85:
    case 0xa0:
    case 0x1680:
    case 0x2000:
    case 0x2001:
    case 0x2002:
    case 0x2003:
    case 0x2004:
    case 0x2005:
    case 0x2006:
    case 0x2007:
    case 0x2008:
    case 0x2009:
    case 0x200a:
    case 0x2028:
    case 0x2029:
    case 0x202f:
    case 0x205f:
    case 0x3000:
    case 0x200b:
    case 0xfeff:
      return true;
    default:
      return false;
  }
}

function hasControlChar(phrase: string): boolean {
  for (const char of phrase) {
    const code = char.codePointAt(0);
    if (code === undefined) continue;
    if (isDictationContextControlCodePoint(code)) return true;
  }
  return false;
}

function isBlankOnly(phrase: string): boolean {
  if (phrase.length === 0) return true;
  for (const char of phrase) {
    const code = char.codePointAt(0);
    if (code === undefined || !isDictationContextBlankCodePoint(code)) return false;
  }
  return true;
}

/** Strip leading/trailing blank code points using the shared dictation blank policy. */
export function trimDictationContextBlanks(phrase: string): string {
  const chars = [...phrase];
  while (chars.length > 0) {
    const code = chars[0]?.codePointAt(0);
    if (code === undefined || !isDictationContextBlankCodePoint(code)) break;
    chars.shift();
  }
  while (chars.length > 0) {
    const code = chars[chars.length - 1]?.codePointAt(0);
    if (code === undefined || !isDictationContextBlankCodePoint(code)) break;
    chars.pop();
  }
  return chars.join("");
}

/**
 * Validate optional per-take vocabulary. Missing or empty arrays omit the field.
 * Control characters and UTF-8 byte limits apply to the supplied string before any trim.
 * Accepted phrases are preserved exactly. Errors never include the supplied phrases.
 */
export function parseDictationContextualStrings(value: unknown): DictationContextualStringsResult {
  if (value === undefined) {
    return { ok: true };
  }
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    return { ok: false, error: "dictation contextualStrings must be an array of strings" };
  }
  if (value.length === 0) {
    return { ok: true };
  }
  if (value.length > DICTATION_CONTEXT_MAX_PHRASES) {
    return { ok: false, error: "dictation contextualStrings allows at most 100 phrases" };
  }

  const contextualStrings: string[] = [];
  let totalBytes = 0;
  for (const raw of value) {
    if (hasControlChar(raw)) {
      return {
        ok: false,
        error: "dictation contextualStrings cannot include control characters",
      };
    }
    const bytes = Buffer.byteLength(raw, "utf8");
    if (bytes > DICTATION_CONTEXT_MAX_PHRASE_BYTES) {
      return { ok: false, error: "dictation contextualStrings phrase exceeds 256 UTF-8 bytes" };
    }
    if (isBlankOnly(raw)) {
      return { ok: false, error: "dictation contextualStrings cannot include empty phrases" };
    }
    totalBytes += bytes;
    if (totalBytes > DICTATION_CONTEXT_MAX_TOTAL_BYTES) {
      return { ok: false, error: "dictation contextualStrings total exceeds 8192 UTF-8 bytes" };
    }
    contextualStrings.push(raw);
  }
  return { ok: true, contextualStrings };
}

export function parseDictationClientMessage(
  record: Record<string, unknown>,
): { ok: true; message: DictationClientMessage } | { ok: false; error: string } {
  const type = record.type;
  if (typeof type !== "string" || type.trim().length === 0) {
    return { ok: false, error: "Message type is required" };
  }

  if (type === "dictation_start") {
    const parsed = parseDictationContextualStrings(record.contextualStrings);
    if (!parsed.ok) {
      return parsed;
    }
    if (parsed.contextualStrings && parsed.contextualStrings.length > 0) {
      return {
        ok: true,
        message: { type: "dictation_start", contextualStrings: parsed.contextualStrings },
      };
    }
    return { ok: true, message: { type: "dictation_start" } };
  }

  if (type === "dictation_stop") {
    return { ok: true, message: { type: "dictation_stop" } };
  }
  if (type === "dictation_cancel") {
    return { ok: true, message: { type: "dictation_cancel" } };
  }

  return { ok: true, message: { type } as DictationClientMessage };
}

// ─── Client -> Server messages ───

export interface DictationStartMessage {
  type: "dictation_start";
  /** Per-take vocabulary hints. Never raw assistant text or instructions. */
  contextualStrings?: string[];
}

export interface DictationStopMessage {
  type: "dictation_stop";
}

export interface DictationCancelMessage {
  type: "dictation_cancel";
}

export type DictationClientMessage =
  | DictationStartMessage
  | DictationStopMessage
  | DictationCancelMessage;

// ─── Server -> Client messages ───

export interface DictationReadyMessage {
  type: "dictation_ready";
  /** STT provider identifier reported by the backend (e.g. "streaming-localhost"). */
  sttProvider?: string;
  /** STT model identifier. */
  sttModel?: string;
  /** True when this take's vocabulary hints were consumed. Not an accuracy guarantee. */
  contextApplied?: boolean;
}

export interface DictationResultMessage {
  type: "dictation_result";
  text: string;
  /** STT-settled prefix already committed by the backend. */
  committedText?: string;
  /** In-flight tail still subject to correction. */
  activeText?: string;
  /** When true, the text is a batch-corrected replacement. Client should snap (no animation). */
  snap?: boolean;
}

export interface DictationFinalMessage {
  type: "dictation_final";
  text: string;
  /** Final committed transcript from the backend, if provided. */
  committedText?: string;
  /** Final active tail from the backend, usually empty on completion. */
  activeText?: string;
}

export interface DictationErrorMessage {
  type: "dictation_error";
  error: string;
  fatal: boolean;
}

export type DictationServerMessage =
  | DictationReadyMessage
  | DictationResultMessage
  | DictationFinalMessage
  | DictationErrorMessage;

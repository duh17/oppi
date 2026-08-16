/**
 * Shared head-of-file reader for Pi session JSONL metadata.
 *
 * local-sessions, session-lifecycle-service, and pi-tui-mirror-runtime each
 * used to parse the same JSONL prefix with slightly different helpers. This
 * module is the one reader; callers keep their own extras (message-count
 * heuristics, path canonicalization, display-name policy).
 */

import { closeSync, openSync, readSync } from "node:fs";

import { extractQueuedUserText } from "./session-queue-utils.js";

/** Default head budget for catalog/import. Mirror uses a larger caller budget. */
export const DEFAULT_SESSION_JSONL_META_READ_BYTES = 16_384;

export interface SessionJsonlMeta {
  name?: string;
  firstMessage?: string;
  model?: string;
  messageCount: number;
  scannedLineCount: number;
  scannedBytes: number;
}

export type SessionJsonlMetaStopField = "name" | "firstMessage" | "model";

export interface ParseSessionJsonlHeadOptions {
  /**
   * Truncation is a caller policy, not a file-format rule.
   * Catalog/mirror pass 200; import reads the raw first message and slices later.
   */
  firstMessageMaxChars?: number;
  /**
   * Optional early stop after requested fields are populated. The already-read
   * head is still fully split so callers can use scannedLineCount for heuristics.
   */
  stopWhen?: SessionJsonlMetaStopField[];
}

export interface ReadSessionJsonlMetaOptions extends ParseSessionJsonlHeadOptions {
  /** Read budget in bytes. Callers choose 16KB vs 1MB; this helper never reads past it. */
  maxBytes: number;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function maybeTruncate(text: string, maxChars: number | undefined): string {
  return maxChars === undefined ? text : text.slice(0, maxChars);
}

function hasRequestedFields(
  meta: SessionJsonlMeta,
  stopWhen: SessionJsonlMetaStopField[] | undefined,
): boolean {
  if (!stopWhen || stopWhen.length === 0) return false;
  return stopWhen.every((field) => Boolean(meta[field]));
}

/**
 * Parse an already-read JSONL head.
 *
 * Text extraction uses extractQueuedUserText so string content, text-part
 * arrays, and queued input_text/output_text shapes share one reader. Wrapped
 * `message` records and top-level user records are both accepted. The preview
 * is trimmed; whitespace-only content is not a first message.
 *
 * Malformed lines are skipped. Aborting the scan would hide later
 * session_info / first-user-message records after a truncated or corrupt line.
 */
export function parseSessionJsonlHead(
  chunk: string,
  options: ParseSessionJsonlHeadOptions = {},
): SessionJsonlMeta {
  const lines = chunk.split("\n");
  const meta: SessionJsonlMeta = {
    messageCount: 0,
    scannedLineCount: lines.length,
    scannedBytes: Buffer.byteLength(chunk),
  };

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      continue;
    }

    const record = asRecord(parsed);
    if (!record) continue;

    if (record.type === "session_info" && !meta.name) {
      const name = record.name;
      if (typeof name === "string" && name.trim()) {
        meta.name = name.trim();
      }
    }

    if (record.type === "model_change" && !meta.model) {
      const provider = record.provider;
      const modelId = record.modelId;
      if (typeof provider === "string" && typeof modelId === "string") {
        meta.model = modelId.startsWith(`${provider}/`) ? modelId : `${provider}/${modelId}`;
      }
    }

    // Mirror files sometimes store the user record at the top level.
    const message = asRecord(record.message) ?? record;
    if (typeof message.role === "string") {
      if (record.type === "message" && (message.role === "user" || message.role === "assistant")) {
        meta.messageCount += 1;
      }
      if (!meta.firstMessage && message.role === "user") {
        const text = extractQueuedUserText(message).trim();
        if (text) {
          meta.firstMessage = maybeTruncate(text, options.firstMessageMaxChars);
        }
      }
    }

    if (hasRequestedFields(meta, options.stopWhen)) break;
  }

  return meta;
}

/** Read only the caller-specified head of a session JSONL file. */
export function readSessionJsonlMeta(
  filePath: string,
  options: ReadSessionJsonlMetaOptions,
): SessionJsonlMeta {
  let fd: number | undefined;
  try {
    fd = openSync(filePath, "r");
    const maxBytes = Math.max(0, Math.floor(options.maxBytes));
    const buffer = Buffer.alloc(maxBytes);
    const bytesRead = maxBytes > 0 ? readSync(fd, buffer, 0, maxBytes, 0) : 0;
    const chunk = buffer.toString("utf8", 0, bytesRead);
    return { ...parseSessionJsonlHead(chunk, options), scannedBytes: bytesRead };
  } catch {
    return { messageCount: 0, scannedLineCount: 0, scannedBytes: 0 };
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

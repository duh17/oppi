import { closeSync, existsSync, fstatSync, openSync, readSync } from "node:fs";

import { estimateUsageCostFromModel, normalizePiUsage } from "../token-usage.js";
import type { Session } from "../types.js";

const TRACE_TAIL_INITIAL_BYTES = 256 * 1024;
const TRACE_TAIL_MAX_BYTES = 2 * 1024 * 1024;

export function normalizeSessionTokens(tokens: Session["tokens"] | undefined): Session["tokens"] {
  return {
    input: tokens?.input ?? 0,
    output: tokens?.output ?? 0,
    cacheRead: tokens?.cacheRead ?? 0,
    cacheWrite: tokens?.cacheWrite ?? 0,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function totalTokenUsage(tokens: Session["tokens"]): number {
  return tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite;
}

/**
 * Recover the last non-zero context snapshot from the pi JSONL trace.
 *
 * Some stopped sessions end with a synthetic aborted assistant message whose
 * usage is all zeros. Keep the previous real context usage instead.
 */
function recoverContextTokensFromTrace(tracePath: string): number | undefined {
  if (!existsSync(tracePath)) {
    return undefined;
  }

  let fd: number | undefined;
  try {
    fd = openSync(tracePath, "r");
    const size = fstatSync(fd).size;
    if (size <= 0) {
      return undefined;
    }

    let bytesToRead = Math.min(size, TRACE_TAIL_INITIAL_BYTES);
    while (bytesToRead > 0) {
      const start = Math.max(0, size - bytesToRead);
      const length = size - start;
      const buffer = Buffer.alloc(length);
      const bytesRead = readSync(fd, buffer, 0, length, start);
      let chunk = buffer.subarray(0, bytesRead).toString("utf8");

      if (start > 0) {
        const firstNewline = chunk.indexOf("\n");
        if (firstNewline === -1) {
          if (bytesToRead >= size || bytesToRead >= TRACE_TAIL_MAX_BYTES) {
            break;
          }
          bytesToRead = Math.min(size, bytesToRead * 2, TRACE_TAIL_MAX_BYTES);
          continue;
        }
        chunk = chunk.slice(firstNewline + 1);
      }

      const lines = chunk.split("\n");
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const line = lines[index]?.trim();
        if (!line) {
          continue;
        }

        let entry: unknown;
        try {
          entry = JSON.parse(line);
        } catch {
          continue;
        }

        if (!isRecord(entry) || entry.type !== "message") {
          continue;
        }

        const message = isRecord(entry.message) ? entry.message : null;
        if (!message || message.role !== "assistant") {
          continue;
        }

        const usage = normalizePiUsage(message.usage);
        if (!usage) {
          continue;
        }

        const contextTokens = totalTokenUsage(usage);
        if (contextTokens > 0) {
          return contextTokens;
        }
      }

      if (bytesToRead >= size || bytesToRead >= TRACE_TAIL_MAX_BYTES) {
        break;
      }
      bytesToRead = Math.min(size, bytesToRead * 2, TRACE_TAIL_MAX_BYTES);
    }
  } catch {
    return undefined;
  } finally {
    if (fd !== undefined) {
      closeSync(fd);
    }
  }

  return undefined;
}

export function backfillContextTokensFromTrace(session: Session): void {
  if ((session.contextTokens ?? 0) > 0) {
    return;
  }

  if (totalTokenUsage(session.tokens) <= 0) {
    return;
  }

  const candidates: string[] = [];
  const pushCandidate = (path: string | undefined): void => {
    if (!path || candidates.includes(path)) {
      return;
    }
    candidates.push(path);
  };

  pushCandidate(session.piSessionFile);
  for (const path of [...(session.piSessionFiles ?? [])].reverse()) {
    pushCandidate(path);
  }

  for (const tracePath of candidates) {
    const recovered = recoverContextTokensFromTrace(tracePath);
    if (recovered && recovered > 0) {
      session.contextTokens = recovered;
      return;
    }
  }
}

export function backfillCostFromTokens(session: Session): void {
  if ((session.cost ?? 0) > 0) {
    return;
  }

  if (totalTokenUsage(session.tokens) <= 0) {
    return;
  }

  const recovered = estimateUsageCostFromModel(session.model, session.tokens);
  if (recovered > 0) {
    session.cost = recovered;
  }
}

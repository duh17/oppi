import {
  closeSync,
  existsSync,
  fstatSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { estimateUsageCostFromModel, normalizePiUsage } from "../token-usage.js";
import type { Session } from "../types.js";
import type { ConfigStore } from "./config-store.js";

const log = createLogger({ base: { component: "session_store" } });

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Backfill cache token fields for sessions persisted before cacheRead/cacheWrite existed. */
function backfillTokens(session: Session): void {
  if (session.tokens && !("cacheRead" in session.tokens)) {
    (session.tokens as Record<string, number>).cacheRead = 0;
    (session.tokens as Record<string, number>).cacheWrite = 0;
  }
}

const TRACE_TAIL_INITIAL_BYTES = 256 * 1024;
const TRACE_TAIL_MAX_BYTES = 2 * 1024 * 1024;

function totalTokenUsage(tokens: {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}): number {
  return tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite;
}

/**
 * Recover the last non-zero context snapshot from the pi JSONL trace.
 *
 * Some stopped sessions end with a synthetic aborted assistant message whose
 * usage is all zeros. Older servers persisted that zero snapshot, clobbering
 * the previous real context usage. Scan backward through the trace tail and
 * keep the last non-zero assistant usage instead.
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

function backfillContextTokensFromTrace(session: Session): void {
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

function backfillCostFromTokens(session: Session): void {
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

function compareSessionsByActivity(a: Session, b: Session): number {
  if (b.lastActivity !== a.lastActivity) {
    return b.lastActivity - a.lastActivity;
  }
  return a.id.localeCompare(b.id);
}

function loadLegacySessionFromPath(path: string): Session | undefined {
  const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
  if (!isRecord(raw)) {
    log.error("session_store.session_file.invalid", {
      sessionFilePath: path,
      reason: "top_level_not_object",
    });
    return undefined;
  }

  const session = raw.session as Session | undefined;
  if (!session) {
    log.error("session_store.session_file.invalid", {
      sessionFilePath: path,
      reason: "missing_session_payload",
    });
    return undefined;
  }

  backfillTokens(session);
  backfillCostFromTokens(session);
  backfillContextTokensFromTrace(session);
  return session;
}

export interface LegacySessionImportResult {
  sessions: Session[];
  failures: string[];
}

/**
 * Read legacy JSON session sidecars from disk so they can be imported into
 * SQLite on startup. This path is intentionally read-only.
 */
export function loadLegacySessions(configStore: ConfigStore): LegacySessionImportResult {
  const sessions: Session[] = [];
  const failures: string[] = [];
  const baseDir = configStore.getSessionsDir();

  if (!existsSync(baseDir)) {
    return { sessions, failures };
  }

  for (const file of readdirSync(baseDir)) {
    // Only load <sessionId>.json — skip auxiliary files like *.annotations.json
    if (!file.endsWith(".json")) continue;
    if (file.indexOf(".") !== file.length - 5) continue;

    const path = join(baseDir, file);
    try {
      const session = loadLegacySessionFromPath(path);
      if (session) {
        sessions.push(session);
      } else {
        failures.push(path);
      }
    } catch (err: unknown) {
      log.error("session_store.session_file_parse.failed", {
        sessionFilePath: path,
        error: safeErrorMessage(err),
      });
      failures.push(path);
    }
  }

  sessions.sort(compareSessionsByActivity);
  return { sessions, failures };
}

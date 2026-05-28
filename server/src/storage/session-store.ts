import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { Session } from "../types.js";
import type { ConfigStore } from "./config-store.js";
import {
  backfillContextTokensFromTrace,
  backfillCostFromTokens,
  backfillLegacyTokenFields,
} from "./session-repair.js";

const log = createLogger({ base: { component: "session_store" } });

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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

  backfillLegacyTokenFields(session);
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

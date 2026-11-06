import { randomBytes } from "node:crypto";
import {
  chmodSync,
  constants,
  copyFileSync,
  mkdirSync,
  rmdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";

import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { copySessionAttachments } from "./session-attachments.js";
import type { SessionLifecycleService } from "./session-lifecycle-service.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "classic_control_sessions" } });

/** Migration-ledger key: the one-time removal below runs once per data directory. */
const CLASSIC_CONTROL_SESSIONS_MIGRATION_KEY = "classic_pi_control_sessions_deleted_v1";

type Lifecycle = Pick<SessionLifecycleService, "deleteSession" | "localPiTraceFiles">;

/**
 * Removes the classic Pi Control sessions: workspace-less rows with `control_json`, created
 * before Oppi Control moved to the durable engine. The server can no longer run them, so they
 * leave the list rather than stay as rows that cannot resume. Nothing is lost:
 *
 * 1. Each row's Pi trace files (the ones the session delete would unlink), its stored
 *    attachments, and the row itself with its `control` metadata are copied to
 *    `$dataDir/backups/pi-control-sessions-pre-<key>-<time>-<random>/<sessionId>/` as
 *    `traces/`, `attachments/`, and `session.json`.
 * 2. Only then does the ordinary session delete remove the row, its search index entry, and the
 *    originals. Copy-then-delete is the move: it works across file systems, and the delete keeps
 *    the local-session catalog in step.
 *
 * Runs once per data directory. A row whose backup fails keeps its row and files and loses its
 * partial backup; a row whose delete fails keeps its backup. Either way the key stays unrecorded
 * and the next start retries only the rows still stored, into a new folder, so a retry never
 * overwrites or removes an earlier backup. Never throws: it runs during startup.
 */
export async function deleteClassicControlSessions(
  storage: Pick<
    Storage,
    "getDataDir" | "getSession" | "listClassicControlSessions" | "runMigrationOnce"
  >,
  lifecycle: Lifecycle,
): Promise<void> {
  try {
    await storage.runMigrationOnce(CLASSIC_CONTROL_SESSIONS_MIGRATION_KEY, async () => {
      const rows = storage.listClassicControlSessions();
      if (rows.length === 0) return;
      const dataDir = storage.getDataDir();
      const backupDir = join(
        dataDir,
        "backups",
        `pi-control-sessions-pre-${CLASSIC_CONTROL_SESSIONS_MIGRATION_KEY}-${Date.now()}-${randomBytes(4).toString("hex")}`,
      );
      let removed = 0;
      let failed = 0;
      for (const { id, controlJson } of rows) {
        const session = storage.getSession(id);
        if (!session) continue;
        const sessionBackup = join(backupDir, id);
        try {
          await backUpSession(session, controlJson, sessionBackup, dataDir, lifecycle);
        } catch (error: unknown) {
          failed += 1;
          rmSync(sessionBackup, { recursive: true, force: true });
          log.error("classic_control_sessions.backup_failed", {
            sessionId: id,
            error: safeErrorMessage(error),
          });
          continue;
        }
        try {
          await lifecycle.deleteSession(session);
          removed += 1;
        } catch (error: unknown) {
          failed += 1;
          log.error("classic_control_sessions.delete_failed", {
            sessionId: id,
            backupDir: sessionBackup,
            error: safeErrorMessage(error),
          });
        }
      }
      removeIfEmpty(backupDir);
      log.info("classic_control_sessions.removed", { removed, failed, backupDir });
      if (failed > 0) throw new Error(`${failed} classic control sessions were not removed`);
    });
  } catch (error: unknown) {
    log.warn("classic_control_sessions.retry_next_start", { error: safeErrorMessage(error) });
  }
}

/** Copies one row's traces, attachments, and metadata into `dir`, which must not exist yet. */
async function backUpSession(
  session: Session,
  controlJson: string,
  dir: string,
  dataDir: string,
  lifecycle: Lifecycle,
): Promise<void> {
  const traces = await lifecycle.localPiTraceFiles(session);
  mkdirSync(join(dir, "traces"), { recursive: true, mode: 0o700 });
  const names = new Set<string>();
  for (const [index, trace] of traces.entries()) {
    // Pi names trace files uniquely; the index only guards two directories' same name.
    const name = names.has(basename(trace)) ? `${index}-${basename(trace)}` : basename(trace);
    names.add(name);
    const target = join(dir, "traces", name);
    copyFileSync(trace, target, constants.COPYFILE_EXCL);
    chmodSync(target, 0o600);
  }
  copySessionAttachments(dataDir, session.id, join(dir, "attachments"));
  let control: unknown = controlJson;
  try {
    control = JSON.parse(controlJson);
  } catch {
    // Keep the stored text as it was.
  }
  writeFileSync(
    join(dir, "session.json"),
    `${JSON.stringify({ ...session, control }, null, 2)}\n`,
    {
      mode: 0o600,
      flag: "wx",
    },
  );
}

function removeIfEmpty(dir: string): void {
  try {
    rmdirSync(dir);
  } catch {
    // Missing, or it holds a backup.
  }
}

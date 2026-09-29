/**
 * Sessions that were running when the previous server process ended come back
 * after the next start.
 *
 * Two paths fill one durable queue (`session_restart_resume` in
 * session-state.db):
 * - A graceful stop records every live managed session before stopping it,
 *   because the stop flow then persists `stopped` and erases that evidence.
 * - After a crash or SIGKILL, startup finds sessions still stored as running
 *   and queues them while marking them stopped.
 *
 * Startup then resumes each queued session once. A session that was mid-turn
 * gets a continuation prompt so the agent picks the work back up. Entries are
 * cleared one by one, so a crash during resume keeps the rest queued; a session
 * already resumed is stored as running and the crash path queues it again.
 *
 * Any other start of a session (a client opening it, a prompt) clears its
 * entry in SessionManager.startSession, so a session someone already resumed,
 * and possibly stopped again, is left alone.
 */

import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import {
  canResumeAfterServerRestart as canResumeAfterRestart,
  type SessionLifecycleService,
} from "./session-lifecycle-service.js";
import type { Storage } from "./storage.js";
import type { RestartResumeEntry } from "./storage/session-sqlite-store.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "session_restart" } });

export const RESTART_CONTINUE_PROMPT =
  "The Oppi server restarted while you were working, which interrupted your last step. " +
  "Running tool calls and background jobs were stopped. Continue the task from where " +
  "you left off, and re-check anything that was in progress before relying on it.";

type RestartStorage = Pick<
  Storage,
  | "clearRestartResume"
  | "getSession"
  | "getWorkspace"
  | "listRestartResume"
  | "listSessions"
  | "queueRestartResume"
  | "saveSession"
>;

/** A session caught mid-stop was on its way out; do not bring it back. */
function restartEntry(session: Session): RestartResumeEntry | undefined {
  if (session.status === "stopping" || !canResumeAfterRestart(session)) return undefined;
  return { sessionId: session.id, wasBusy: session.status === "busy" };
}

/** Graceful stop: remember live sessions before the stop flow marks them stopped. */
export function recordLiveSessionsForRestart(
  storage: Pick<Storage, "queueRestartResume">,
  liveSessions: readonly Session[],
  nowMs: number = Date.now(),
): RestartResumeEntry[] {
  const entries = liveSessions.flatMap((session) => restartEntry(session) ?? []);
  storage.queueRestartResume(entries, nowMs);
  if (entries.length > 0) {
    log.info("session_restart.recorded", { source: "shutdown", sessions: entries });
  }
  return entries;
}

/**
 * Startup after a crash: sessions still stored as running were live when the
 * previous process died. Queue the resumable ones and mark every one stopped.
 * Must run only after this process owns the data directory.
 */
export function queueOrphanedSessionsForRestart(
  storage: Pick<Storage, "listSessions" | "queueRestartResume" | "saveSession">,
  nowMs: number = Date.now(),
): RestartResumeEntry[] {
  const orphaned = storage
    .listSessions()
    .filter((session) => session.status !== "stopped" && session.status !== "error");
  const entries = orphaned.flatMap((session) => restartEntry(session) ?? []);
  // Queue before marking stopped: the running status is the only evidence.
  // A crash in between leaves them running, and the next start queues again.
  storage.queueRestartResume(entries, nowMs);
  for (const session of orphaned) {
    session.status = "stopped";
    session.currentTurnStartedAt = undefined;
    storage.saveSession(session);
  }
  if (orphaned.length > 0) {
    log.info("startup.healed_orphaned_sessions", { count: orphaned.length });
  }
  if (entries.length > 0) {
    log.info("session_restart.recorded", { source: "orphaned", sessions: entries });
  }
  return entries;
}

export interface RestartResumeDeps {
  storage: RestartStorage;
  lifecycle: Pick<SessionLifecycleService, "resumeControlSession" | "resumeWorkspaceSession">;
  sendPrompt: (sessionId: string, text: string) => Promise<void>;
  /** Stop before the next entry; server shutdown sets this. */
  cancelled?: () => boolean;
}

export type RestartResumeOutcome = "continued" | "resumed" | "skipped" | "failed";

/** Resume queued sessions one at a time so a restart does not spike startup load. */
export async function resumeSessionsAfterRestart(
  deps: RestartResumeDeps,
): Promise<Array<{ sessionId: string; outcome: RestartResumeOutcome; reason?: string }>> {
  const results: Array<{ sessionId: string; outcome: RestartResumeOutcome; reason?: string }> =
    [];
  // Re-read the queue each time: a client start while earlier entries were
  // resuming removes that session's entry.
  for (;;) {
    if (deps.cancelled?.()) break;
    const [entry] = deps.storage.listRestartResume();
    if (!entry) break;
    const result = await resumeOne(deps, entry);
    deps.storage.clearRestartResume(entry.sessionId);
    results.push({ sessionId: entry.sessionId, ...result });
    const fields = { sessionId: entry.sessionId, wasBusy: entry.wasBusy, ...result };
    if (result.outcome === "failed") log.error("session_restart.resume_failed", fields);
    else log.info("session_restart.resumed", fields);
  }
  // Always logged, even with nothing queued: restart tooling waits for it.
  const count = (outcome: RestartResumeOutcome): number =>
    results.filter((result) => result.outcome === outcome).length;
  log.info("session_restart.resume_complete", {
    continued: count("continued"),
    resumed: count("resumed"),
    skipped: count("skipped"),
    failed: count("failed"),
    ...(deps.cancelled?.() ? { cancelled: true } : {}),
  });
  return results;
}

async function resumeOne(
  deps: RestartResumeDeps,
  entry: RestartResumeEntry,
): Promise<{ outcome: RestartResumeOutcome; reason?: string }> {
  const session = deps.storage.getSession(entry.sessionId);
  if (!session) return { outcome: "skipped", reason: "session deleted" };
  if (!canResumeAfterRestart(session)) return { outcome: "skipped", reason: "not resumable" };

  let resumed: Session;
  try {
    if (session.workspaceId === undefined) {
      resumed = (await deps.lifecycle.resumeControlSession(session)).session;
    } else {
      const workspace = deps.storage.getWorkspace(session.workspaceId);
      if (!workspace) return { outcome: "skipped", reason: "workspace deleted" };
      resumed = (await deps.lifecycle.resumeWorkspaceSession({ session, workspace })).session;
    }
  } catch (error: unknown) {
    return { outcome: "failed", reason: safeErrorMessage(error) };
  }

  // Someone may have prompted the session between startup and this resume;
  // only an idle session gets the continuation.
  if (!entry.wasBusy || resumed.status !== "ready") return { outcome: "resumed" };
  try {
    await deps.sendPrompt(session.id, RESTART_CONTINUE_PROMPT);
  } catch (error: unknown) {
    return { outcome: "failed", reason: `continuation: ${safeErrorMessage(error)}` };
  }
  return { outcome: "continued" };
}

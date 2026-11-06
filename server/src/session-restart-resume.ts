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
 * gets a continuation prompt so the agent picks the work back up. So does an
 * idle one that comes back holding a notice about work the restart killed (a
 * background job it was waiting on): that notice rides on the next turn, and
 * without the prompt the session would sit idle until its idle timeout. This
 * check runs in the new process, so it also covers a crash and a shutdown that
 * could not tell which sessions were waiting. Entries are
 * cleared one by one, so a crash during resume keeps the rest queued; a session
 * already resumed is stored as running and the crash path queues it again.
 *
 * Input sent to a session (SessionManager.sendPrompt/sendSteer/sendFollowUp)
 * or an explicit stop (SessionLifecycleService.stopSession) clears its entry:
 * that person now directs the session, and a stopped session stays stopped.
 * A client merely opening or reconnecting to it does not, so a session the
 * app reopens on reconnect still gets its continuation.
 */

import { isControlConversation } from "./control-session.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { syncProgramStatus } from "./program-status.js";
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

/**
 * A session caught mid-stop was on its way out; do not bring it back. An idle session
 * waiting on work the restart kills (a background job in the server process) counts as
 * busy, so it gets the continuation prompt instead of waiting for a wake that never comes.
 */
function restartEntry(
  session: Session,
  losesWork: ReadonlySet<string> = new Set(),
): RestartResumeEntry | undefined {
  if (session.status === "stopping" || !canResumeAfterRestart(session)) return undefined;
  return { sessionId: session.id, wasBusy: session.status === "busy" || losesWork.has(session.id) };
}

/**
 * Graceful stop: remember live sessions before the stop flow marks them stopped.
 * `losesWork` names sessions whose pending wake dies with this process.
 */
export function recordLiveSessionsForRestart(
  storage: Pick<Storage, "queueRestartResume">,
  liveSessions: readonly Session[],
  losesWork: ReadonlySet<string> = new Set(),
  nowMs: number = Date.now(),
): RestartResumeEntry[] {
  const entries = liveSessions.flatMap((session) => restartEntry(session, losesWork) ?? []);
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
    // A run the crash cut short has no outcome; a finished one keeps done/error.
    syncProgramStatus({ session }, nowMs);
    storage.saveSession(session);
  }
  // Sessions stored before program status existed get the value their lifecycle implies.
  for (const session of storage.listSessions()) {
    if (session.programStatus) continue;
    syncProgramStatus({ session }, session.lastActivity);
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
  lifecycle: Pick<
    SessionLifecycleService,
    "resumeControlConversation" | "resumeControlSession" | "resumeWorkspaceSession"
  >;
  sendPrompt: (sessionId: string, text: string) => Promise<unknown>;
  sendFollowUp: (sessionId: string, text: string) => Promise<unknown>;
  /** The resumed session holds a notice about work an earlier process lost. */
  reportsLostWork: (sessionId: string) => boolean;
  /** Stop before the next entry; server shutdown sets this. */
  cancelled?: () => boolean;
}

export type RestartResumeOutcome = "continued" | "resumed" | "skipped" | "failed";

/** Resume queued sessions one at a time so a restart does not spike startup load. */
export async function resumeSessionsAfterRestart(
  deps: RestartResumeDeps,
): Promise<Array<{ sessionId: string; outcome: RestartResumeOutcome; reason?: string }>> {
  const results: Array<{ sessionId: string; outcome: RestartResumeOutcome; reason?: string }> = [];
  // Re-read the queue each time: a client start while earlier entries were
  // resuming removes that session's entry.
  for (;;) {
    if (deps.cancelled?.()) break;
    const [entry] = deps.storage.listRestartResume();
    if (!entry) break;
    const result = await resumeOne(deps, entry);
    // Shutdown mid-resume keeps the entry (and wasBusy) for the next start.
    if (deps.cancelled?.()) break;
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

/** Start a stored session the way a client's Resume does. */
async function resumeStoredSession(
  deps: {
    storage: Pick<RestartStorage, "getWorkspace">;
    lifecycle: RestartResumeDeps["lifecycle"];
  },
  session: Session,
): Promise<{ resumed: Session } | { outcome: "skipped" | "failed"; reason: string }> {
  if (!canResumeAfterRestart(session)) return { outcome: "skipped", reason: "not resumable" };
  try {
    if (session.workspaceId === undefined) {
      // The control conversation is durable, not a declared control session.
      return {
        resumed: (isControlConversation(session)
          ? await deps.lifecycle.resumeControlConversation(session)
          : await deps.lifecycle.resumeControlSession(session)
        ).session,
      };
    }
    const workspace = deps.storage.getWorkspace(session.workspaceId);
    if (!workspace) return { outcome: "skipped", reason: "workspace deleted" };
    return {
      resumed: (await deps.lifecycle.resumeWorkspaceSession({ session, workspace })).session,
    };
  } catch (error: unknown) {
    return { outcome: "failed", reason: safeErrorMessage(error) };
  }
}

async function resumeOne(
  deps: RestartResumeDeps,
  entry: RestartResumeEntry,
): Promise<{ outcome: RestartResumeOutcome; reason?: string }> {
  const session = deps.storage.getSession(entry.sessionId);
  if (!session) return { outcome: "skipped", reason: "session deleted" };
  const start = await resumeStoredSession(deps, session);
  if (!("resumed" in start)) return start;
  const resumed = start.resumed;

  // Durable continues the original submission: pi-durable retries a request a crash cut
  // off, and a run it ended `interrupted` (no retry left) the attached backend continues
  // (`continueAfterFailedRun`). An extra continuation prompt would manufacture a second
  // user turn after a crash.
  if (
    session.serverDurable?.conversationId !== undefined ||
    !(entry.wasBusy || deps.reportsLostWork(session.id)) ||
    deps.cancelled?.()
  )
    return { outcome: "resumed" };
  // Input sent to the session or an explicit stop while this resume ran
  // cleared the entry: that person now directs it. Opening or reconnecting to
  // the session does not. No await separates this check from delivery below.
  if (!deps.storage.listRestartResume().some((queued) => queued.sessionId === session.id)) {
    return { outcome: "resumed", reason: "taken over during resume" };
  }
  return continueAfterRestart(deps, session.id, resumed.status);
}

export interface HeldInputDeliveryDeps {
  storage: Pick<RestartStorage, "getSession" | "getWorkspace"> &
    Pick<Storage, "clearHeldInputs" | "listHeldInputs">;
  lifecycle: RestartResumeDeps["lifecycle"];
  isActive: (sessionId: string) => boolean;
  /** Send a live session its held inputs; resolves to how many went out. */
  deliver: (sessionId: string) => Promise<number>;
  cancelled?: () => boolean;
}

/**
 * Messages held while the server drained for a restart (server-drain.ts) go out once the
 * sessions are back: after the restart resume, or right away when the drain is cancelled. A
 * session that is not running is resumed first. One that cannot come back (deleted, its
 * workspace gone, incognito) loses its held messages, and the log says so. Runs on every start,
 * so messages held before a crash still go out.
 */
export async function deliverHeldInputs(deps: HeldInputDeliveryDeps): Promise<void> {
  const sessionIds = [...new Set(deps.storage.listHeldInputs().map((input) => input.sessionId))];
  for (const sessionId of sessionIds) {
    if (deps.cancelled?.()) return;
    const session = deps.storage.getSession(sessionId);
    if (!session) {
      const dropped = deps.storage.clearHeldInputs(sessionId);
      log.warn("session_restart.held_input_dropped", { sessionId, dropped, reason: "deleted" });
      continue;
    }
    if (!deps.isActive(sessionId)) {
      const start = await resumeStoredSession(deps, session);
      if (!("resumed" in start)) {
        if (start.outcome === "failed") {
          log.error("session_restart.held_input_resume_failed", {
            sessionId,
            reason: start.reason,
          });
          continue;
        }
        const dropped = deps.storage.clearHeldInputs(sessionId);
        log.warn("session_restart.held_input_dropped", {
          sessionId,
          dropped,
          reason: start.reason,
        });
        continue;
      }
    }
    if (deps.cancelled?.()) return;
    const delivered = await deps.deliver(sessionId);
    log.info("session_restart.held_input_delivered", { sessionId, delivered });
  }
}

/**
 * Runs `deliverHeldInputs` passes one at a time in the background. A pass stops between
 * sessions once `stop()` is called or `paused()` (a new drain) is true.
 */
export class HeldInputDelivery {
  private pass: Promise<void> = Promise.resolve();
  private stopped = false;

  constructor(
    private readonly deps: Omit<HeldInputDeliveryDeps, "lifecycle" | "cancelled"> & {
      paused: () => boolean;
    },
  ) {}

  start(lifecycle: RestartResumeDeps["lifecycle"]): void {
    const cancelled = (): boolean => this.stopped || this.deps.paused();
    this.pass = this.pass
      .then(() => deliverHeldInputs({ ...this.deps, lifecycle, cancelled }))
      .catch((error: unknown) => {
        log.error("session_restart.held_input_delivery_crashed", {
          error: safeErrorMessage(error),
        });
      });
  }

  /** Undelivered inputs stay stored; the next start sends them. */
  async stop(): Promise<void> {
    this.stopped = true;
    await this.pass;
  }
}

/**
 * Best effort: prompt an idle session; queue a follow-up behind a turn that
 * started on its own (an extension at startup), and fall back to a follow-up
 * when the prompt is refused.
 */
async function continueAfterRestart(
  deps: RestartResumeDeps,
  sessionId: string,
  status: Session["status"],
): Promise<{ outcome: RestartResumeOutcome; reason?: string }> {
  if (status === "ready") {
    try {
      await deps.sendPrompt(sessionId, RESTART_CONTINUE_PROMPT);
      return { outcome: "continued" };
    } catch (error: unknown) {
      log.warn("session_restart.continue_prompt_refused", {
        sessionId,
        error: safeErrorMessage(error),
      });
    }
  }
  try {
    await deps.sendFollowUp(sessionId, RESTART_CONTINUE_PROMPT);
    return { outcome: "continued", reason: "queued as follow-up" };
  } catch (error: unknown) {
    return { outcome: "failed", reason: `continuation: ${safeErrorMessage(error)}` };
  }
}

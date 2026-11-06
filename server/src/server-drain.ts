/**
 * Drain, then restart.
 *
 * A requested drain keeps the server running until every busy session has finished its
 * current turn, then restarts the process the normal way (the same re-exec an in-app update
 * uses). A turn includes its tool calls, the subagent children it spawned, and messages it
 * sends to other sessions. While draining:
 *
 * - Prompts and follow-ups from anyone else are held in session-state.db and delivered after
 *   the restart, or right away when the drain is cancelled (`SessionManager`). A steer into a
 *   running turn still goes through: it belongs to that turn.
 * - Due schedules are recorded but dispatched only after the restart (`AgentScheduleRunner`).
 * - Every live session shows a status line saying a restart is pending.
 *
 * A session waiting on the user (an ask or other dialog) does not hold the restart: it could
 * wait forever. Neither does a background job or a pending wake: classic sessions get the
 * usual continuation after the restart, and durable jobs recover on their own. At the deadline
 * the server restarts anyway, which is today's restart: durable sessions resume their run,
 * classic sessions are interrupted and continued.
 */

import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { resolveRestartMode } from "./server-update.js";
import type { ServerRestartMode } from "./types/server-update.js";

const log = createLogger({ base: { component: "server_drain" } });

export const DEFAULT_DRAIN_MAX_WAIT_MS = 10 * 60_000;
/** Longest wait a request may ask for. */
export const MAX_DRAIN_MAX_WAIT_MS = 6 * 60 * 60_000;
const DRAIN_POLL_MS = 1_000;

/** Status line shown on every live session while a restart is pending. */
export const RESTART_PENDING_STATUS =
  "Server restart pending: running turns finish first, new messages wait until after the restart";
/** Timeline notice for a message held until after the restart. */
export const RESTART_HELD_NOTICE =
  "The Oppi server is restarting once running turns finish. Your message is held and runs after the restart.";
/** Error for work that cannot wait for the restart. */
export const RESTART_PENDING_REFUSAL =
  "The Oppi server is restarting once running turns finish. Try again after the restart.";

export interface DrainSession {
  sessionId: string;
  name?: string;
  engine: "durable" | "classic";
  /** Mid-turn but waiting on the user (an ask or dialog); does not hold the restart. */
  waitingOnUser: boolean;
}

export interface ServerDrainStatus {
  state: "idle" | "draining" | "restarting";
  requestedAt?: number;
  deadlineAt?: number;
  maxWaitMs?: number;
  /** Busy sessions the restart waits for. */
  busy: DrainSession[];
  /** Busy sessions waiting on the user; restarted through at the end. */
  waitingOnUser: DrainSession[];
  /** Messages held for after the restart. */
  heldInputs: number;
}

export interface ServerDrainDeps {
  /** Live sessions mid-turn. */
  busySessions(): DrainSession[];
  heldInputCount(): number;
  /** Show `text` on every live session, or clear it when undefined. Called every poll. */
  announce(text: string | undefined): void;
  /**
   * Restart the process the way it can (`restartMode`). Runs once, after the drain finished or
   * hit its deadline. Absent when nothing can restart this process: requests are refused.
   */
  restart?: (mode: ServerRestartMode) => void;
  /** The drain was cancelled: deliver what it held. */
  onCancelled(): void;
  /** How this process restarts itself; `manual` refuses requests. */
  restartMode?: () => ServerRestartMode;
  now?: () => number;
  pollMs?: number;
}

export class ServerDrain {
  private state: ServerDrainStatus["state"] = "idle";
  private requestedAt?: number;
  private deadlineAt?: number;
  private maxWaitMs?: number;
  private poll?: ReturnType<typeof setInterval>;
  private deadline?: ReturnType<typeof setTimeout>;
  /** Idle at the previous poll: a restart needs two idle polls in a row. */
  private idleSeen = false;
  private readonly now: () => number;
  private readonly pollMs: number;
  private readonly restartMode: () => ServerRestartMode;

  constructor(private readonly deps: ServerDrainDeps) {
    this.now = deps.now ?? Date.now;
    this.pollMs = deps.pollMs ?? DRAIN_POLL_MS;
    this.restartMode = deps.restartMode ?? resolveRestartMode;
  }

  /** True from the request until the process restarts. */
  get isDraining(): boolean {
    return this.state !== "idle";
  }

  /** Why this process cannot restart itself, or undefined when it can. */
  unavailableReason(): string | undefined {
    return this.deps.restart && this.restartMode() !== "manual"
      ? undefined
      : "This server process cannot restart itself";
  }

  /** Start draining. A drain already pending is returned unchanged. */
  request(options: { maxWaitMs?: number; source: string }): ServerDrainStatus {
    if (this.state !== "idle") return this.status();
    const maxWaitMs = options.maxWaitMs ?? DEFAULT_DRAIN_MAX_WAIT_MS;
    this.state = "draining";
    this.requestedAt = this.now();
    this.maxWaitMs = maxWaitMs;
    this.deadlineAt = this.requestedAt + maxWaitMs;
    this.idleSeen = false;
    const status = this.status();
    log.info("server.drain_requested", {
      source: options.source,
      maxWaitMs,
      busyCount: status.busy.length,
      waitingOnUserCount: status.waitingOnUser.length,
      busy: status.busy.map(logSession),
      waitingOnUser: status.waitingOnUser.map(logSession),
    });
    this.poll = setInterval(() => this.check(), this.pollMs);
    this.deadline = setTimeout(() => this.finish("deadline"), maxWaitMs);
    this.check();
    return this.status();
  }

  /** Cancel a pending drain. Undefined when none is pending or the restart already began. */
  cancel(source: string): ServerDrainStatus | undefined {
    if (this.state !== "draining") return undefined;
    const heldInputs = this.deps.heldInputCount();
    const elapsedMs = this.now() - (this.requestedAt ?? this.now());
    this.reset();
    this.deps.announce(undefined);
    log.info("server.drain_cancelled", { source, elapsedMs, heldInputs });
    this.deps.onCancelled();
    return this.status();
  }

  status(): ServerDrainStatus {
    const sessions = this.state === "idle" ? [] : this.deps.busySessions();
    return {
      state: this.state,
      ...(this.requestedAt !== undefined ? { requestedAt: this.requestedAt } : {}),
      ...(this.deadlineAt !== undefined ? { deadlineAt: this.deadlineAt } : {}),
      ...(this.maxWaitMs !== undefined ? { maxWaitMs: this.maxWaitMs } : {}),
      busy: sessions.filter((session) => !session.waitingOnUser),
      waitingOnUser: sessions.filter((session) => session.waitingOnUser),
      heldInputs: this.state === "idle" ? 0 : this.deps.heldInputCount(),
    };
  }

  /** Server stop: drop the timers. Held inputs stay stored for the next start. */
  dispose(): void {
    this.clearTimers();
  }

  private check(): void {
    if (this.state !== "draining") return;
    this.deps.announce(RESTART_PENDING_STATUS);
    const blocking = this.deps.busySessions().filter((session) => !session.waitingOnUser);
    if (blocking.length > 0) {
      this.idleSeen = false;
      return;
    }
    // A turn that just ended can hand straight to queued work; one more poll settles it.
    if (!this.idleSeen) {
      this.idleSeen = true;
      return;
    }
    this.finish("idle");
  }

  private finish(reason: "idle" | "deadline"): void {
    if (this.state !== "draining") return;
    this.clearTimers();
    const status = this.status();
    this.state = "restarting";
    const fields = {
      reason,
      elapsedMs: this.now() - (this.requestedAt ?? this.now()),
      heldInputs: status.heldInputs,
      waitingOnUser: status.waitingOnUser.map(logSession),
      // What the restart does to each turn it cuts short.
      interrupted: status.busy.filter((s) => s.engine === "classic").map(logSession),
      resumedAfterRestart: status.busy.filter((s) => s.engine === "durable").map(logSession),
    };
    if (reason === "deadline") log.warn("server.drain_deadline", fields);
    log.info("server.drain_complete", fields);
    this.deps.announce(undefined);
    try {
      const unavailable = this.unavailableReason();
      if (unavailable) throw new Error(unavailable);
      this.deps.restart?.(this.restartMode());
    } catch (error: unknown) {
      log.error("server.drain_restart_failed", { error: safeErrorMessage(error) });
      this.reset();
      this.deps.onCancelled();
    }
  }

  private reset(): void {
    this.clearTimers();
    this.state = "idle";
    this.requestedAt = undefined;
    this.deadlineAt = undefined;
    this.maxWaitMs = undefined;
    this.idleSeen = false;
  }

  private clearTimers(): void {
    if (this.poll) clearInterval(this.poll);
    if (this.deadline) clearTimeout(this.deadline);
    this.poll = undefined;
    this.deadline = undefined;
  }
}

function logSession(session: DrainSession): Record<string, unknown> {
  return {
    sessionId: session.sessionId,
    engine: session.engine,
    ...(session.name ? { name: session.name } : {}),
  };
}

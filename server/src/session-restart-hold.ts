/**
 * The session side of server restarts. For drain-then-restart (server-drain.ts): which input
 * waits for the restart, which sessions are mid-turn, the restart-pending status line, and
 * delivery of what was held. For the restart resume (session-restart-resume.ts): which live
 * sessions lose work with this process.
 */

import {
  runtimeCommandFailure,
  type HeldTurnInput,
  type RuntimeCommandResultMessage,
} from "./agent-runtime-transport.js";
import { managedSessionMessageCaller } from "./cli/managed-session-message.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { RESTART_HELD_NOTICE, RESTART_PENDING_REFUSAL, type DrainSession } from "./server-drain.js";
import { canResumeAfterServerRestart } from "./session-lifecycle-service.js";
import { hasServerDurableBinding } from "./session-runtime-capabilities.js";
import type { Storage } from "./storage.js";
import type { ChatAttachmentRef, Session } from "./types.js";

const log = createLogger({ base: { component: "sessions" } });

const RESTART_STATUS_KEY = "oppi-server-restart";

/** What this needs of a live session. */
export interface RestartHoldSession {
  session: Session;
  sdkBackend: {
    readonly isStreaming: boolean;
    readonly isCompacting: boolean;
    readonly holdsWorkLostOnRestart: boolean;
    readonly reportsLostWork: boolean;
  };
  /** Dialogs and asks waiting on the user. */
  pendingUIRequests: { readonly size: number };
}

export interface SessionRestartHoldDeps {
  storage(): Pick<Storage, "deleteHeldInput" | "getSession" | "holdInput" | "listHeldInputs">;
  liveSessions(): Iterable<RestartHoldSession>;
  liveSession(sessionId: string): RestartHoldSession | undefined;
  /** Emit an event into a live session, as its runtime would. */
  emit(sessionId: string, event: SessionBackendEvent): void;
  broadcast(sessionId: string, message: RuntimeCommandResultMessage): void;
  sendPrompt(
    sessionId: string,
    message: string,
    opts: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      streamingBehavior: "followUp";
    },
  ): Promise<void | HeldTurnInput>;
}

export class SessionRestartHold {
  /** Set by the server: whether it drains for a restart now. */
  drain: { readonly isDraining: boolean } | null = null;
  /** Live sessions showing the restart-pending status line. */
  private readonly announced = new Set<string>();

  constructor(private readonly deps: SessionRestartHoldDeps) {}

  /**
   * While the server drains, store a prompt or follow-up for after the restart instead of
   * starting a turn, and tell the session so. Input that belongs to a running turn goes
   * through: a steer into it, a message to a child the turn spawned, and a message a running
   * session sends (`oppi session send` attributes it). An incognito session does not come back
   * after the restart, so its input is refused rather than held.
   */
  hold(
    sessionId: string,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      streamingBehavior?: "steer" | "followUp";
    },
    followUp = false,
  ): HeldTurnInput | undefined {
    if (!this.drain?.isDraining) return undefined;
    const kind = followUp ? "follow_up" : opts?.streamingBehavior === "steer" ? "steer" : "prompt";
    const live = this.deps.liveSession(sessionId);
    if (!live) return undefined;
    if (kind === "steer" && isTurnRunning(live)) return undefined;
    // A steer into an idle session would start a turn: it is a prompt here.
    if (this.belongsToRunningTurn(live.session, message)) return undefined;
    if (!canResumeAfterServerRestart(live.session)) {
      log.info("server.drain_input_refused", { sessionId, kind, reason: "not_resumable" });
      throw new Error(RESTART_PENDING_REFUSAL);
    }
    const stored = this.deps.storage().holdInput({
      sessionId,
      message,
      ...(opts?.attachments?.length ? { attachments: opts.attachments } : {}),
      ...(opts?.clientTurnId ? { clientTurnId: opts.clientTurnId } : {}),
      heldAt: Date.now(),
    });
    log.info("server.drain_input_held", {
      sessionId,
      kind: kind === "steer" ? "prompt" : kind,
      duplicate: !stored,
      attachmentCount: opts?.attachments?.length ?? 0,
    });
    if (stored) {
      this.deps.emit(sessionId, {
        type: "notice",
        id: `restart-held:${opts?.clientTurnId ?? Date.now()}`,
        message: RESTART_HELD_NOTICE,
      });
    }
    return { held: "server_restart" };
  }

  /**
   * Refuse model work a person starts outside a turn (compaction, a summarizing tree jump): it
   * cannot be held. True when refused; the command's result says why.
   */
  refuseCommand(
    sessionId: string,
    command: { type: string; summarize?: boolean },
    requestId: string | undefined,
  ): boolean {
    if (!this.drain?.isDraining) return false;
    if (command.type !== "compact" && !(command.type === "navigate_tree" && command.summarize))
      return false;
    log.info("server.drain_command_refused", { sessionId, command: command.type });
    this.deps.broadcast(
      sessionId,
      runtimeCommandFailure(command.type, requestId, RESTART_PENDING_REFUSAL),
    );
    return true;
  }

  /** Live sessions mid-turn. */
  drainSessions(): DrainSession[] {
    const sessions: DrainSession[] = [];
    for (const live of this.deps.liveSessions()) {
      if (!isTurnRunning(live)) continue;
      sessions.push({
        sessionId: live.session.id,
        ...(live.session.name ? { name: live.session.name } : {}),
        engine: hasServerDurableBinding(live.session) ? "durable" : "classic",
        waitingOnUser: live.pendingUIRequests.size > 0,
      });
    }
    return sessions;
  }

  /**
   * Show `text` as a status line on every live session, or clear it. Sessions that start later
   * get it on the next call; the drain calls this every poll.
   */
  announce(text: string | undefined): void {
    for (const live of this.deps.liveSessions()) {
      const id = live.session.id;
      if ((text !== undefined) === this.announced.has(id)) continue;
      this.deps.emit(id, {
        type: "extension_ui_request",
        id: `server-restart:${Date.now()}`,
        method: "setStatus",
        statusKey: RESTART_STATUS_KEY,
        ...(text !== undefined ? { statusText: text } : {}),
      });
      if (text !== undefined) this.announced.add(id);
    }
    if (text === undefined) this.announced.clear();
  }

  /**
   * Send a live session the inputs held for it, oldest first: a prompt when it is idle, a
   * follow-up behind a running turn. Each is removed once sent; one that fails is dropped with
   * a notice, and nothing goes out while a new drain is pending.
   */
  async deliver(sessionId: string): Promise<number> {
    let delivered = 0;
    for (const input of this.deps.storage().listHeldInputs(sessionId)) {
      if (this.drain?.isDraining) break;
      try {
        const held = await this.deps.sendPrompt(sessionId, input.message, {
          ...(input.attachments ? { attachments: input.attachments } : {}),
          ...(input.clientTurnId ? { clientTurnId: input.clientTurnId } : {}),
          streamingBehavior: "followUp",
        });
        if (held) break;
        delivered += 1;
      } catch (error: unknown) {
        log.error("session_restart.held_input_failed", {
          sessionId,
          error: safeErrorMessage(error),
        });
        this.deps.emit(sessionId, {
          type: "notice",
          id: `restart-held-failed:${input.id}`,
          message: `A message held during the server restart could not be sent: ${safeErrorMessage(error)}`,
        });
      }
      this.deps.storage().deleteHeldInput(input.id);
    }
    return delivered;
  }

  /** Live sessions waiting on work that dies with this server process (see restart resume). */
  sessionIdsLosingWork(): Set<string> {
    const ids = new Set<string>();
    for (const live of this.deps.liveSessions()) {
      if (live.sdkBackend.holdsWorkLostOnRestart) ids.add(live.session.id);
    }
    return ids;
  }

  /** Whether a live session holds a notice about work an earlier process lost (restart resume). */
  reportsLostWork(sessionId: string): boolean {
    return this.deps.liveSession(sessionId)?.sdkBackend.reportsLostWork ?? false;
  }

  /** Input from a running turn: its sender, or an ancestor of the target, is mid-turn. */
  private belongsToRunningTurn(target: Session, message: string): boolean {
    const caller = managedSessionMessageCaller(message);
    if (caller && this.turnRunning(caller)) return true;
    const seen = new Set<string>([target.id]);
    let parentId = target.launch?.parentSessionId;
    while (parentId && !seen.has(parentId)) {
      if (this.turnRunning(parentId)) return true;
      seen.add(parentId);
      parentId = this.deps.storage().getSession(parentId)?.launch?.parentSessionId;
    }
    return false;
  }

  private turnRunning(sessionId: string): boolean {
    const live = this.deps.liveSession(sessionId);
    return live !== undefined && isTurnRunning(live);
  }
}

function isTurnRunning(live: RestartHoldSession): boolean {
  return (
    live.session.status === "busy" || live.sdkBackend.isStreaming || live.sdkBackend.isCompacting
  );
}

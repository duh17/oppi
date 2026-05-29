import type { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import type { SessionManager } from "./sessions.js";
import type { Storage } from "./storage.js";
import type { WsSessionCommands } from "./ws-message-handler.js";
import type { Session } from "./types.js";

export function prepareDisconnectedMirrorForManagedResume(
  storage: Pick<Storage, "saveSession">,
  session: Session,
): void {
  delete session.runtime;
  session.mirror = {
    ...(session.mirror ?? { status: "disconnected" }),
    status: "disconnected",
  };
  session.status = "stopped";
  session.currentTurnStartedAt = undefined;
  session.lastActivity = Date.now();
  storage.saveSession(session);
}

/**
 * Routes client commands to the runtime that owns a session.
 *
 * Managed sessions continue through the in-process Pi SDK SessionManager.
 * Terminal mirror sessions are owned by a live Pi TUI bridge while connected.
 * Once the bridge disconnects, the server may promote the stored session back
 * into an in-process SDK runtime and continue from the same pi JSONL trace.
 */
export class SessionRuntimeRouter implements WsSessionCommands {
  constructor(
    private readonly storage: Storage,
    private readonly managed: SessionManager,
    private readonly mirror: PiTuiMirrorRuntime,
  ) {}

  private runtimeFor(sessionId: string): WsSessionCommands {
    const session = this.storage.getSession(sessionId);
    return this.isConnectedMirror(session) ? this.mirror : this.managed;
  }

  private isMirror(session: Session | undefined): session is Session {
    return session?.runtime === "pi-tui-mirror";
  }

  private isConnectedMirror(session: Session | undefined): boolean {
    return this.isMirror(session) && this.mirror.isSessionConnected(session.id);
  }

  private isDisconnectedMirror(session: Session | undefined): session is Session {
    return this.isMirror(session) && !this.mirror.isSessionConnected(session.id);
  }

  private async promoteDisconnectedMirror(sessionId: string): Promise<Session | undefined> {
    const session = this.storage.getSession(sessionId);
    if (!this.isDisconnectedMirror(session)) return session;

    if (session.ephemeral) {
      throw new Error("Incognito terminal mirror sessions cannot be resumed");
    }
    if (!session.piSessionFile) {
      throw new Error("Terminal mirror session has no pi session file to resume");
    }

    prepareDisconnectedMirrorForManagedResume(this.storage, session);

    return this.managed.startSession(sessionId);
  }

  sendPrompt: WsSessionCommands["sendPrompt"] = async (sessionId, message, opts) => {
    await this.promoteDisconnectedMirror(sessionId);
    return this.runtimeFor(sessionId).sendPrompt(sessionId, message, opts);
  };

  sendSteer: WsSessionCommands["sendSteer"] = async (sessionId, message, opts) => {
    const wasDisconnectedMirror = this.isDisconnectedMirror(this.storage.getSession(sessionId));
    await this.promoteDisconnectedMirror(sessionId);
    if (wasDisconnectedMirror) {
      return this.managed.sendPrompt(sessionId, message, { ...opts, timestamp: Date.now() });
    }
    return this.runtimeFor(sessionId).sendSteer(sessionId, message, opts);
  };

  sendFollowUp: WsSessionCommands["sendFollowUp"] = async (sessionId, message, opts) => {
    const wasDisconnectedMirror = this.isDisconnectedMirror(this.storage.getSession(sessionId));
    await this.promoteDisconnectedMirror(sessionId);
    if (wasDisconnectedMirror) {
      return this.managed.sendPrompt(sessionId, message, { ...opts, timestamp: Date.now() });
    }
    return this.runtimeFor(sessionId).sendFollowUp(sessionId, message, opts);
  };

  getMessageQueue: WsSessionCommands["getMessageQueue"] = (sessionId) =>
    this.runtimeFor(sessionId).getMessageQueue(sessionId);

  setMessageQueue: WsSessionCommands["setMessageQueue"] = (sessionId, payload) =>
    this.runtimeFor(sessionId).setMessageQueue(sessionId, payload);

  sendAbort: WsSessionCommands["sendAbort"] = (sessionId) =>
    this.runtimeFor(sessionId).sendAbort(sessionId);

  stopSession: WsSessionCommands["stopSession"] = (sessionId) =>
    this.runtimeFor(sessionId).stopSession(sessionId);

  getActiveSession: WsSessionCommands["getActiveSession"] = (sessionId) =>
    this.runtimeFor(sessionId).getActiveSession(sessionId);

  respondToUIRequest: WsSessionCommands["respondToUIRequest"] = (sessionId, response) =>
    this.runtimeFor(sessionId).respondToUIRequest(sessionId, response);

  forwardClientCommand: WsSessionCommands["forwardClientCommand"] = (
    sessionId,
    message,
    requestId,
  ) => this.runtimeFor(sessionId).forwardClientCommand(sessionId, message, requestId);
}

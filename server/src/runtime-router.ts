import type { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import type { SessionManager } from "./sessions.js";
import type { Storage } from "./storage.js";
import type { WsSessionCommands } from "./ws-message-handler.js";
import type { Session } from "./types.js";

/**
 * Routes client commands to the runtime that owns a session.
 *
 * Managed sessions continue through the in-process Pi SDK SessionManager.
 * Terminal mirror sessions are owned by a live Pi TUI bridge and must never be
 * auto-started by the server against the same JSONL trace.
 */
export class SessionRuntimeRouter implements WsSessionCommands {
  constructor(
    private readonly storage: Storage,
    private readonly managed: SessionManager,
    private readonly mirror: PiTuiMirrorRuntime,
  ) {}

  private runtimeFor(sessionId: string): WsSessionCommands {
    const session = this.storage.getSession(sessionId);
    return this.isMirror(session) ? this.mirror : this.managed;
  }

  private isMirror(session: Session | undefined): boolean {
    return session?.runtime === "pi-tui-mirror";
  }

  sendPrompt: WsSessionCommands["sendPrompt"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendPrompt(sessionId, message, opts);

  sendSteer: WsSessionCommands["sendSteer"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendSteer(sessionId, message, opts);

  sendFollowUp: WsSessionCommands["sendFollowUp"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendFollowUp(sessionId, message, opts);

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

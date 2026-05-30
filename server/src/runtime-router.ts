import type { AgentRuntimeCommandTransport } from "./agent-runtime-transport.js";
import type { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import type { SessionManager } from "./sessions.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

/**
 * Routes client commands to the runtime that owns a session.
 *
 * Managed sessions continue through the in-process Pi SDK SessionManager.
 * Terminal mirror sessions stay terminal-owned until an explicit future
 * "resume as managed" flow is added. This avoids split-brain behavior where
 * the server silently starts an SDK runtime while a terminal bridge is only
 * reloading or temporarily disconnected.
 */
export class SessionRuntimeRouter implements AgentRuntimeCommandTransport {
  constructor(
    private readonly storage: Storage,
    private readonly managed: SessionManager,
    private readonly mirror: PiTuiMirrorRuntime,
  ) {}

  private runtimeFor(sessionId: string): AgentRuntimeCommandTransport {
    const session = this.storage.getSession(sessionId);
    return this.isMirror(session) ? this.mirror : this.managed;
  }

  private isMirror(session: Session | undefined): session is Session {
    return session?.runtime === "pi-tui-mirror";
  }

  sendPrompt: AgentRuntimeCommandTransport["sendPrompt"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendPrompt(sessionId, message, opts);

  sendSteer: AgentRuntimeCommandTransport["sendSteer"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendSteer(sessionId, message, opts);

  sendFollowUp: AgentRuntimeCommandTransport["sendFollowUp"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendFollowUp(sessionId, message, opts);

  getMessageQueue: AgentRuntimeCommandTransport["getMessageQueue"] = (sessionId) =>
    this.runtimeFor(sessionId).getMessageQueue(sessionId);

  setMessageQueue: AgentRuntimeCommandTransport["setMessageQueue"] = (sessionId, payload) =>
    this.runtimeFor(sessionId).setMessageQueue(sessionId, payload);

  sendAbort: AgentRuntimeCommandTransport["sendAbort"] = (sessionId) =>
    this.runtimeFor(sessionId).sendAbort(sessionId);

  stopSession: AgentRuntimeCommandTransport["stopSession"] = (sessionId) =>
    this.runtimeFor(sessionId).stopSession(sessionId);

  getActiveSession: AgentRuntimeCommandTransport["getActiveSession"] = (sessionId) =>
    this.runtimeFor(sessionId).getActiveSession(sessionId);

  respondToUIRequest: AgentRuntimeCommandTransport["respondToUIRequest"] = (sessionId, response) =>
    this.runtimeFor(sessionId).respondToUIRequest(sessionId, response);

  forwardClientCommand: AgentRuntimeCommandTransport["forwardClientCommand"] = (
    sessionId,
    message,
    requestId,
  ) => this.runtimeFor(sessionId).forwardClientCommand(sessionId, message, requestId);
}

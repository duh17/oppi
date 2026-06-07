import type { AgentRuntimeTransport } from "./agent-runtime-transport.js";
import type { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import type { SessionManager } from "./sessions.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

/**
 * Concrete facade for the two runtime owners Oppi supports.
 *
 * Oppi runtime sessions continue through the in-process Pi SDK SessionManager.
 * Terminal pi-tui sessions stay terminal-owned until an explicit future
 * "resume as Oppi" flow is requested. This avoids split-brain behavior where
 * the server silently starts an SDK runtime while a terminal bridge is only
 * reloading or temporarily disconnected.
 */
export class SessionRuntimes implements AgentRuntimeTransport {
  constructor(
    private readonly storage: Storage,
    private readonly oppi: SessionManager,
    private readonly piTui: PiTuiMirrorRuntime,
  ) {}

  private runtimeFor(sessionId: string): AgentRuntimeTransport {
    const session = this.storage.getSession(sessionId);
    return this.isPiTui(session) ? this.piTui : this.oppi;
  }

  private isPiTui(session: Session | undefined | null): session is Session {
    return session?.runtime === "pi-tui";
  }

  isSessionConnected(sessionId: string): boolean {
    const session = this.storage.getSession(sessionId);
    if (this.isPiTui(session)) {
      return this.piTui.isSessionConnected(sessionId);
    }
    return this.oppi.getActiveSession(sessionId) !== undefined;
  }

  /** True when the owning runtime currently has an active process/bridge. */
  isSessionLive(sessionId: string): boolean {
    return this.isSessionConnected(sessionId);
  }

  /** Runtime-owned session IDs that currently have a live process or bridge. */
  getActiveSessionIds(): Set<string> {
    const ids = new Set<string>();
    for (const sessionId of this.oppi.getActiveSessionIds()) {
      if (!this.isPiTui(this.storage.getSession(sessionId))) {
        ids.add(sessionId);
      }
    }
    for (const sessionId of this.piTui.getActiveSessionIds()) {
      if (this.piTui.isSessionConnected(sessionId)) {
        ids.add(sessionId);
      }
    }
    return ids;
  }

  getActiveSessions(): Session[] {
    const sessions: Session[] = [];
    for (const sessionId of this.getActiveSessionIds()) {
      const session = this.getActiveSession(sessionId);
      if (session) sessions.push(session);
    }
    return sessions;
  }

  getLiveSession(sessionId: string): Session | undefined {
    return this.getActiveSession(sessionId);
  }

  getSessionSnapshot(sessionId: string): Session | undefined {
    const stored = this.storage.getSession(sessionId);
    if (this.isPiTui(stored)) {
      return this.piTui.getActiveSession(sessionId) ?? stored;
    }
    return this.oppi.getActiveSession(sessionId) ?? stored ?? undefined;
  }

  async stopSessionIfActive(sessionId: string): Promise<void> {
    const session = this.storage.getSession(sessionId);
    if (this.isPiTui(session)) {
      if (this.piTui.isSessionConnected(sessionId)) {
        await this.piTui.stopSession(sessionId);
      }
      return;
    }

    if (this.oppi.isActive(sessionId)) {
      await this.oppi.stopSession(sessionId);
    }
  }

  async refreshSessionState(
    sessionId: string,
  ): Promise<{ sessionFile?: string; sessionId?: string; leafId?: string | null } | null> {
    const session = this.storage.getSession(sessionId);
    if (!this.isPiTui(session)) {
      return this.oppi.refreshSessionState(sessionId);
    }

    const traceState = this.piTui.getSessionTraceState(sessionId);
    if (traceState) return traceState;

    const snapshot = this.piTui.getActiveSession(sessionId) ?? session;
    return {
      sessionFile: snapshot.piSessionFile,
      sessionId: snapshot.piSessionId,
    };
  }

  getToolFullOutputPath(sessionId: string, toolCallId: string): string | null {
    const runtime = this.runtimeFor(sessionId) as AgentRuntimeTransport & {
      getToolFullOutputPath?: (sessionId: string, toolCallId: string) => string | null;
    };
    return runtime.getToolFullOutputPath?.(sessionId, toolCallId) ?? null;
  }

  getEventRing(sessionId: string): { length: number; capacity: number } | null {
    const runtime = this.runtimeFor(sessionId) as AgentRuntimeTransport & {
      getEventRing?: (sessionId: string) => { length: number; capacity: number } | null;
    };
    return runtime.getEventRing?.(sessionId) ?? null;
  }

  sendPrompt: AgentRuntimeTransport["sendPrompt"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendPrompt(sessionId, message, opts);

  sendSteer: AgentRuntimeTransport["sendSteer"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendSteer(sessionId, message, opts);

  sendFollowUp: AgentRuntimeTransport["sendFollowUp"] = (sessionId, message, opts) =>
    this.runtimeFor(sessionId).sendFollowUp(sessionId, message, opts);

  getMessageQueue: AgentRuntimeTransport["getMessageQueue"] = (sessionId) =>
    this.runtimeFor(sessionId).getMessageQueue(sessionId);

  setMessageQueue: AgentRuntimeTransport["setMessageQueue"] = (sessionId, payload) =>
    this.runtimeFor(sessionId).setMessageQueue(sessionId, payload);

  sendAbort: AgentRuntimeTransport["sendAbort"] = (sessionId) =>
    this.runtimeFor(sessionId).sendAbort(sessionId);

  stopSession: AgentRuntimeTransport["stopSession"] = (sessionId) =>
    this.runtimeFor(sessionId).stopSession(sessionId);

  getActiveSession: AgentRuntimeTransport["getActiveSession"] = (sessionId) => {
    const session = this.storage.getSession(sessionId);
    if (this.isPiTui(session)) {
      return this.piTui.isSessionConnected(sessionId)
        ? this.piTui.getActiveSession(sessionId)
        : undefined;
    }
    return this.oppi.getActiveSession(sessionId);
  };

  respondToUIRequest: AgentRuntimeTransport["respondToUIRequest"] = (sessionId, response) =>
    this.runtimeFor(sessionId).respondToUIRequest(sessionId, response);

  forwardClientCommand: AgentRuntimeTransport["forwardClientCommand"] = (
    sessionId,
    message,
    requestId,
  ) => this.runtimeFor(sessionId).forwardClientCommand(sessionId, message, requestId);

  subscribe: AgentRuntimeTransport["subscribe"] = (sessionId, callback) =>
    this.runtimeFor(sessionId).subscribe(sessionId, callback);

  getCurrentSeq: AgentRuntimeTransport["getCurrentSeq"] = (sessionId) =>
    this.runtimeFor(sessionId).getCurrentSeq(sessionId);

  getCatchUp: AgentRuntimeTransport["getCatchUp"] = (sessionId, sinceSeq) =>
    this.runtimeFor(sessionId).getCatchUp(sessionId, sinceSeq);

  getPendingUIRequestMessages: AgentRuntimeTransport["getPendingUIRequestMessages"] = (sessionId) =>
    this.runtimeFor(sessionId).getPendingUIRequestMessages(sessionId);
}

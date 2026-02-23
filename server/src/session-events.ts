import { getGitStatus } from "./git-status.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { PiEvent } from "./pi-events.js";
import {
  applyMessageEndToSession,
  updateSessionChangeStats,
  type TranslationContext,
} from "./session-protocol.js";
import type { PendingStop } from "./session-stop.js";
import type { Storage } from "./storage.js";
import type { Session, ServerMessage } from "./types.js";

/** Extension UI request from pi SDK (stdout) */
export interface ExtensionUIRequest {
  type: "extension_ui_request";
  id: string;
  method: string;
  title?: string;
  options?: string[];
  message?: string;
  placeholder?: string;
  prefill?: string;
  notifyType?: "info" | "warning" | "error";
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: string;
  text?: string;
  timeout?: number;
}

/** Fire-and-forget UI methods (no response needed) */
const FIRE_AND_FORGET_METHODS = new Set([
  "notify",
  "setStatus",
  "setWidget",
  "setTitle",
  "set_editor_text",
]);

export interface EventProcessorSessionState {
  session: Session;
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  partialResults: Map<string, string>;
  streamedAssistantText: string;
  hasStreamedThinking: boolean;
  pendingStop?: PendingStop;
}

export interface SessionEventProcessorDeps {
  storage: Storage;
  mobileRenderers: MobileRendererRegistry;
  broadcast: (key: string, message: ServerMessage) => void;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
}

export class SessionEventProcessor {
  private gitStatusTimers: Map<string, NodeJS.Timeout> = new Map();
  private static readonly GIT_STATUS_DEBOUNCE_MS = 2000;

  constructor(private readonly deps: SessionEventProcessorDeps) {}

  /**
   * Build the TranslationContext for an active session.
   * The context holds mutable streaming state that translatePiEvent reads/writes.
   */
  translationContext(active: EventProcessorSessionState): TranslationContext {
    return {
      sessionId: active.session.id,
      partialResults: active.partialResults,
      streamedAssistantText: active.streamedAssistantText,
      hasStreamedThinking: active.hasStreamedThinking,
      mobileRenderers: this.deps.mobileRenderers,
    };
  }

  /**
   * Handle extension_ui_request from pi.
   * Fire-and-forget methods are forwarded as notifications.
   * Dialog methods (select, confirm, input, editor) are forwarded
   * to the phone and held until respondToUIRequest() is called.
   */
  handleExtensionUIRequest(
    key: string,
    active: EventProcessorSessionState,
    req: ExtensionUIRequest,
  ): void {
    if (FIRE_AND_FORGET_METHODS.has(req.method)) {
      // Forward as notification (pick relevant fields)
      this.deps.broadcast(key, {
        type: "extension_ui_notification",
        method: req.method,
        message: req.message,
        notifyType: req.notifyType,
        statusKey: req.statusKey,
        statusText: req.statusText,
      });
      return;
    }

    // Dialog method — track and forward to phone
    active.pendingUIRequests.set(req.id, req);
    this.deps.broadcast(key, {
      type: "extension_ui_request",
      id: req.id,
      sessionId: active.session.id,
      method: req.method,
      title: req.title,
      options: req.options,
      message: req.message,
      placeholder: req.placeholder,
      prefill: req.prefill,
      timeout: req.timeout,
    });
  }

  /**
   * Update session state from pi events.
   * Delegates extraction to session-protocol functions; handles persistence here.
   */
  updateSessionFromEvent(key: string, active: EventProcessorSessionState, event: PiEvent): void {
    const session = active.session;
    let shouldFlushNow = false;
    const pendingStopMode = active.pendingStop?.mode;

    switch (event.type) {
      case "agent_start":
        if (session.status !== "stopping") {
          session.status = "busy";
        }
        break;

      case "agent_end":
        session.status = pendingStopMode === "terminate" ? "stopping" : "ready";
        shouldFlushNow = true;
        break;

      case "tool_execution_start":
        updateSessionChangeStats(session, event.toolName, event.args);
        this.maybeEmitGitStatus(key, session, event.toolName);
        break;

      case "message_end":
        applyMessageEndToSession(session, event.message);
        break;
    }

    session.lastActivity = Date.now();

    if (shouldFlushNow) {
      this.deps.persistSessionNow(key, session);
      return;
    }

    this.deps.markSessionDirty(key);
  }

  /**
   * After a file-mutating tool call, asynchronously fetch git status
   * and broadcast it to connected clients. Non-blocking — errors are
   * silently ignored (git status is best-effort).
   *
   * Debounced per workspace: rapid-fire edits coalesce into one git
   * call at most every 2 seconds. This avoids spawning 60+ git
   * processes when the agent edits 10 files in quick succession.
   */
  private maybeEmitGitStatus(key: string, session: Session, toolName: unknown): void {
    const name = typeof toolName === "string" ? toolName.toLowerCase() : "";
    if (name !== "edit" && name !== "write" && name !== "bash") return;

    const wsId = session.workspaceId;
    if (!wsId) return;

    // Debounce per workspace — cancel any pending timer and restart
    const existing = this.gitStatusTimers.get(wsId);
    if (existing) clearTimeout(existing);

    this.gitStatusTimers.set(
      wsId,
      setTimeout(() => {
        this.gitStatusTimers.delete(wsId);
        this.emitGitStatusNow(key, wsId);
      }, SessionEventProcessor.GIT_STATUS_DEBOUNCE_MS),
    );
  }

  private emitGitStatusNow(key: string, wsId: string): void {
    const workspace = this.deps.storage.getWorkspace(wsId);
    if (!workspace?.hostMount) return;
    if (workspace.gitStatusEnabled === false) return;

    void getGitStatus(workspace.hostMount)
      .then((status) => {
        if (!status.isGitRepo) return;
        this.deps.broadcast(key, {
          type: "git_status",
          workspaceId: wsId,
          status,
        });
      })
      .catch(() => {
        // Silently ignore git errors
      });
  }
}

import { resolve } from "node:path";

import { ts } from "./log-utils.js";
import { getFileSuggestions } from "./file-suggestions.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import type {
  ClientMessage,
  ImageAttachment,
  MessageQueueDraftItem,
  MessageQueueState,
  ServerMessage,
  Session,
  Workspace,
} from "./types.js";

interface TurnCommandMessage {
  message: string;
  images?: ImageAttachment[];
  clientTurnId?: string;
  requestId?: string;
}

interface SetQueueMessage {
  baseVersion: number;
  steering: MessageQueueDraftItem[];
  followUp: MessageQueueDraftItem[];
  requestId?: string;
}

interface ExtensionUIResponseMessage {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface WsSessionCommands {
  sendPrompt: (
    sessionId: string,
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
      streamingBehavior?: "steer" | "followUp";
      timestamp: number;
    },
  ) => Promise<void>;
  sendSteer: (
    sessionId: string,
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ) => Promise<void>;
  sendFollowUp: (
    sessionId: string,
    message: string,
    opts: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ) => Promise<void>;
  getMessageQueue: (sessionId: string) => MessageQueueState;
  setMessageQueue: (
    sessionId: string,
    payload: {
      baseVersion: number;
      steering: MessageQueueDraftItem[];
      followUp: MessageQueueDraftItem[];
    },
  ) => Promise<MessageQueueState>;
  sendAbort: (sessionId: string) => Promise<void>;
  stopSession: (sessionId: string) => Promise<void>;
  getActiveSession: (sessionId: string) => Session | undefined;
  respondToUIRequest: (sessionId: string, response: ExtensionUIResponseMessage) => boolean;
  forwardClientCommand: (
    sessionId: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
  ) => Promise<void>;
}

interface WsGateDecisions {
  resolveDecision: (
    requestId: string,
    action: "allow" | "deny",
    scope?: "once" | "session" | "global",
    expiresInMs?: number,
  ) => boolean;
}

export interface WsMessageHandlerDeps {
  sessions: WsSessionCommands;
  gate: WsGateDecisions;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession?: (session: Session) => Workspace | undefined;
}

export class WsMessageHandler {
  constructor(private readonly deps: WsMessageHandlerDeps) {}

  async handleClientMessage(
    session: Session,
    msg: ClientMessage,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    switch (msg.type) {
      case "subscribe":
      case "unsubscribe": {
        send({
          type: "error",
          error: `Stream subscriptions are only supported on /stream (received ${msg.type})`,
        });
        return;
      }

      case "prompt":
        await this.handleTurnCommand(session, "prompt", msg, send, (id, text, opts) =>
          this.deps.sessions.sendPrompt(id, text, {
            ...opts,
            streamingBehavior: msg.streamingBehavior,
            timestamp: Date.now(),
          }),
        );
        return;

      case "steer":
        await this.handleTurnCommand(session, "steer", msg, send, (id, text, opts) =>
          this.deps.sessions.sendSteer(id, text, opts),
        );
        return;

      case "follow_up":
        await this.handleTurnCommand(session, "follow_up", msg, send, (id, text, opts) =>
          this.deps.sessions.sendFollowUp(id, text, opts),
        );
        return;

      case "abort":
      case "stop":
        await this.handleStopCommand(session, msg, send);
        return;

      case "stop_session":
        await this.handleStopSessionCommand(session, msg, send);
        return;

      case "get_state": {
        const active = this.deps.sessions.getActiveSession(session.id);
        if (active) {
          send({ type: "state", session: this.deps.ensureSessionContextWindow(active) });
        }
        return;
      }

      case "get_queue": {
        await this.handleGetQueueCommand(session, msg, send);
        return;
      }

      case "set_queue": {
        await this.handleSetQueueCommand(session, msg, send);
        return;
      }

      case "permission_response": {
        const scope = msg.scope || "once";
        const resolved = this.deps.gate.resolveDecision(msg.id, msg.action, scope, msg.expiresInMs);
        if (!resolved) {
          send({ type: "error", error: `Permission request not found: ${msg.id}` });
        }
        return;
      }

      case "extension_ui_response": {
        const ok = this.deps.sessions.respondToUIRequest(session.id, {
          type: "extension_ui_response",
          id: msg.id,
          value: msg.value,
          confirmed: msg.confirmed,
          cancelled: msg.cancelled,
        });
        if (!ok) {
          send({ type: "error", error: `UI request not found: ${msg.id}` });
        }
        return;
      }

      // ── File suggestions (server-handled, no pi round-trip) ──
      case "get_file_suggestions": {
        this.handleFileSuggestions(session, msg.query, msg.requestId, send);
        return;
      }

      // ── RPC passthrough — forward to pi and return result ──
      case "get_messages":
      case "get_session_stats":
      case "get_commands":
      case "set_model":
      case "cycle_model":
      case "get_available_models":
      case "set_thinking_level":
      case "cycle_thinking_level":
      case "new_session":
      case "set_session_name":
      case "compact":
      case "set_auto_compaction":
      case "fork":
      case "switch_session":
      case "set_steering_mode":
      case "set_follow_up_mode":
      case "set_auto_retry":
      case "abort_retry":
      case "abort_bash": {
        const command: Record<string, unknown> = { ...msg };
        await this.deps.sessions.forwardClientCommand(session.id, command, msg.requestId);
        return;
      }
    }
  }

  /**
   * Shared handler for prompt/steer/follow_up turn commands.
   *
   * Logs, maps images, calls the session method, and sends command_result.
   */
  private async handleTurnCommand(
    session: Session,
    command: string,
    msg: TurnCommandMessage,
    send: (msg: ServerMessage) => void,
    handler: (
      sessionId: string,
      message: string,
      opts: {
        images?: Array<{ type: "image"; data: string; mimeType: string }>;
        clientTurnId?: string;
        requestId?: string;
      },
    ) => Promise<void>,
  ): Promise<void> {
    const requestId = msg.requestId;
    const chars = msg.message.length;
    const images = msg.images?.map((img) => ({
      type: "image" as const,
      data: img.data,
      mimeType: img.mimeType,
    }));
    const imageCount = images?.length ?? 0;
    console.log(
      `${ts()} [ws] ${command.toUpperCase()} ${session.id} (chars=${chars}${imageCount > 0 ? `, images=${imageCount}` : ""})`,
    );

    try {
      await handler(session.id, msg.message, {
        images,
        clientTurnId: msg.clientTurnId,
        requestId,
      });
      if (requestId) {
        send({ type: "command_result", command, requestId, success: true });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (requestId) {
        send({ type: "command_result", command, requestId, success: false, error: message });
        return;
      }
      throw err;
    }
  }

  private async handleGetQueueCommand(
    session: Session,
    msg: Extract<ClientMessage, { type: "get_queue" }>,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    const requestId = msg.requestId;

    try {
      const queue = this.deps.sessions.getMessageQueue(session.id);
      send({ type: "queue_state", queue });
      if (requestId) {
        send({
          type: "command_result",
          command: "get_queue",
          requestId,
          success: true,
          data: queue,
        });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (requestId) {
        send({
          type: "command_result",
          command: "get_queue",
          requestId,
          success: false,
          error: message,
        });
        return;
      }
      throw err;
    }
  }

  private async handleSetQueueCommand(
    session: Session,
    msg: SetQueueMessage,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    const requestId = msg.requestId;

    try {
      const queue = await this.deps.sessions.setMessageQueue(session.id, {
        baseVersion: msg.baseVersion,
        steering: msg.steering,
        followUp: msg.followUp,
      });
      if (requestId) {
        send({
          type: "command_result",
          command: "set_queue",
          requestId,
          success: true,
          data: queue,
        });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (requestId) {
        send({
          type: "command_result",
          command: "set_queue",
          requestId,
          success: false,
          error: message,
        });
        return;
      }
      throw err;
    }
  }

  private async handleStopCommand(
    session: Session,
    msg: Extract<ClientMessage, { type: "abort" | "stop" }>,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    const requestId = msg.requestId;
    const command = msg.type;
    console.log(`${ts()} [ws] STOP ${session.id}`);

    try {
      await this.deps.sessions.sendAbort(session.id);
      if (requestId) {
        send({ type: "command_result", command, requestId, success: true });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (requestId) {
        send({ type: "command_result", command, requestId, success: false, error: message });
        return;
      }
      throw err;
    }
  }

  private async handleStopSessionCommand(
    session: Session,
    msg: Extract<ClientMessage, { type: "stop_session" }>,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    const requestId = msg.requestId;
    console.log(`${ts()} [ws] STOP_SESSION ${session.id}`);

    try {
      await this.deps.sessions.stopSession(session.id);
      if (requestId) {
        send({ type: "command_result", command: "stop_session", requestId, success: true });
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      if (requestId) {
        send({
          type: "command_result",
          command: "stop_session",
          requestId,
          success: false,
          error: message,
        });
        return;
      }
      throw err;
    }
  }

  private handleFileSuggestions(
    session: Session,
    query: string,
    requestId: string | undefined,
    send: (msg: ServerMessage) => void,
  ): void {
    const command = "get_file_suggestions";

    // requestId is optional in protocol: still return command_result even when
    // absent so older/broken clients receive a typed response shape.
    const sendResult = (
      payload: Omit<Extract<ServerMessage, { type: "command_result" }>, "type">,
    ): void => {
      send({ type: "command_result", ...payload });
    };

    const workspace = this.deps.resolveWorkspaceForSession?.(session);
    if (!workspace) {
      sendResult({ command, requestId, success: false, error: "workspace_unavailable" });
      return;
    }

    try {
      const workspaceRoot = resolveSdkSessionCwd(workspace);
      const additionalRoots = (workspace.allowedPaths ?? [])
        .filter((entry) => entry.access === "read" || entry.access === "readwrite")
        .map((entry) => {
          const trimmed = entry.path.trim();
          if (trimmed.startsWith("/") || trimmed.startsWith("~")) {
            return trimmed;
          }
          return resolve(workspaceRoot, trimmed);
        });

      const result = getFileSuggestions(workspaceRoot, query, additionalRoots);
      sendResult({ command, requestId, success: true, data: result });
    } catch (err: unknown) {
      const error = err instanceof Error ? err.message : String(err);
      sendResult({ command, requestId, success: false, error });
    }
  }
}

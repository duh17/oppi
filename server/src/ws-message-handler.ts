import type { GateServer } from "./gate.js";
import { ts } from "./log-utils.js";
import type { SessionManager } from "./sessions.js";
import type { ClientMessage, ImageAttachment, ServerMessage, Session } from "./types.js";

interface TurnCommandMessage {
  message: string;
  images?: ImageAttachment[];
  clientTurnId?: string;
  requestId?: string;
}

interface WsMessageHandlerDeps {
  sessions: SessionManager;
  gate: GateServer;
  ensureSessionContextWindow: (session: Session) => Session;
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

      // ── RPC passthrough — forward to pi and return result ──
      case "get_messages":
      case "get_session_stats":
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
        const command = this.toCommandRecord(msg);
        await this.deps.sessions.forwardClientCommand(
          session.id,
          command,
          this.getRequestId(command),
        );
        return;
      }
    }
  }

  private toCommandRecord(message: ClientMessage): Record<string, unknown> {
    return message as unknown as Record<string, unknown>;
  }

  private getRequestId(command: Record<string, unknown>): string | undefined {
    return typeof command.requestId === "string" ? command.requestId : undefined;
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
}

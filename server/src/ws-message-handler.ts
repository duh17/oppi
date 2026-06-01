import {
  runtimeCommandFailure,
  runtimeCommandSuccess,
  type AgentRuntimeCommandTransport,
} from "./agent-runtime-transport.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type {
  ChatAttachmentRef,
  ClientMessage,
  ImageAttachment,
  MessageQueueDraftItem,
  ServerMessage,
  Session,
} from "./types.js";

const log = createLogger({ base: { component: "ws_message_handler" } });

function runtimeLogTag(session: Session): "oppi" | "pi-tui" {
  return session.runtime === "pi-tui" ? "pi-tui" : "oppi";
}

interface TurnCommandMessage {
  message: string;
  images?: ImageAttachment[];
  attachments?: ChatAttachmentRef[];
  clientTurnId?: string;
  requestId?: string;
}

interface SetQueueMessage {
  baseVersion: number;
  steering: MessageQueueDraftItem[];
  followUp: MessageQueueDraftItem[];
  requestId?: string;
}

export type WsSessionCommands = AgentRuntimeCommandTransport;

export interface WsMessageHandlerDeps {
  sessions: WsSessionCommands;
  ensureSessionContextWindow: (session: Session) => Session;
}

export interface WsCommandMeta {
  connId?: string;
}

export class WsMessageHandler {
  constructor(private readonly deps: WsMessageHandlerDeps) {}

  async handleClientMessage(
    session: Session,
    msg: ClientMessage,
    send: (msg: ServerMessage) => void,
    meta: WsCommandMeta = {},
  ): Promise<void> {
    switch (msg.type) {
      case "prompt":
        await this.handleTurnCommand(
          session,
          "prompt",
          msg,
          send,
          (id, text, opts) =>
            this.deps.sessions.sendPrompt(id, text, {
              ...opts,
              streamingBehavior: msg.streamingBehavior,
              timestamp: Date.now(),
            }),
          meta,
        );
        return;

      case "steer":
        await this.handleTurnCommand(
          session,
          "steer",
          msg,
          send,
          (id, text, opts) => this.deps.sessions.sendSteer(id, text, opts),
          meta,
        );
        return;

      case "follow_up":
        await this.handleTurnCommand(
          session,
          "follow_up",
          msg,
          send,
          (id, text, opts) => this.deps.sessions.sendFollowUp(id, text, opts),
          meta,
        );
        return;

      case "abort":
      case "stop":
        await this.handleStopCommand(session, msg, send, meta);
        return;

      case "stop_session":
        await this.handleStopSessionCommand(session, msg, send, meta);
        return;

      case "get_state": {
        const active = this.deps.sessions.getActiveSession(session.id);
        if (active) {
          send({ type: "state", session: this.deps.ensureSessionContextWindow(active) });
        }
        return;
      }

      case "get_queue": {
        await this.handleGetQueueCommand(session, msg, send, meta);
        return;
      }

      case "set_queue": {
        await this.handleSetQueueCommand(session, msg, send, meta);
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
      case "get_fork_messages":
      case "get_session_tree":
      case "navigate_tree":
      case "get_session_stats":
      case "get_commands":
      case "share_session":
      case "set_model":
      case "cycle_model":
      case "get_available_models":
      case "set_thinking_level":
      case "cycle_thinking_level":
      case "reload":
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
        const commandStart = Date.now();
        const command: Record<string, unknown> = { ...msg };

        log.info("ws.command.received", {
          connId: meta.connId,
          sessionId: session.id,
          runtime: runtimeLogTag(session),
          command: msg.type,
          requestId: msg.requestId,
        });

        try {
          await this.deps.sessions.forwardClientCommand(session.id, command, msg.requestId);

          log.info("ws.command.completed", {
            connId: meta.connId,
            sessionId: session.id,
            runtime: runtimeLogTag(session),
            command: msg.type,
            requestId: msg.requestId,
            durationMs: Date.now() - commandStart,
          });

          return;
        } catch (err: unknown) {
          const message = safeErrorMessage(err);

          log.warn("ws.command.failed", {
            connId: meta.connId,
            sessionId: session.id,
            runtime: runtimeLogTag(session),
            command: msg.type,
            requestId: msg.requestId,
            durationMs: Date.now() - commandStart,
            error: message,
          });

          if (msg.requestId) {
            send(runtimeCommandFailure(msg.type, msg.requestId, message));
            return;
          }

          throw err;
        }
      }

      // Dictation messages are handled on the dedicated dictation stream.
      case "dictation_start":
      case "dictation_stop":
      case "dictation_cancel":
        return;

      default: {
        // Compile-time: ensures all ClientMessage cases are handled above.
        // Runtime: unknown types (e.g. future protocol additions) get an error reply.
        const unhandled: never = msg;
        const raw = unhandled as unknown as { type?: string; requestId?: string };
        send(
          runtimeCommandFailure(
            raw.type ?? "unknown",
            raw.requestId ?? "",
            `Unsupported command type: ${raw.type ?? "unknown"}`,
          ),
        );
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
        attachments?: ChatAttachmentRef[];
        clientTurnId?: string;
        requestId?: string;
      },
    ) => Promise<void>,
    meta: WsCommandMeta,
  ): Promise<void> {
    const startedAt = Date.now();
    const requestId = msg.requestId;
    const chars = msg.message.length;
    const images = msg.images?.map((img) => ({
      type: "image" as const,
      data: img.data,
      mimeType: img.mimeType,
    }));
    const imageCount = images?.length ?? 0;
    const attachments = msg.attachments ? [...msg.attachments] : undefined;
    const attachmentCount = attachments?.length ?? 0;

    log.info("ws.turn_command.received", {
      connId: meta.connId,
      sessionId: session.id,
      runtime: runtimeLogTag(session),
      command,
      requestId,
      clientTurnId: msg.clientTurnId,
      chars,
      imageCount,
      attachmentCount,
    });

    try {
      await handler(session.id, msg.message, {
        images,
        attachments,
        clientTurnId: msg.clientTurnId,
        requestId,
      });

      if (requestId) {
        send(runtimeCommandSuccess(command, requestId));
      }

      log.info("ws.turn_command.completed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command,
        requestId,
        clientTurnId: msg.clientTurnId,
        durationMs: Date.now() - startedAt,
      });
    } catch (err: unknown) {
      const message = safeErrorMessage(err);

      log.warn("ws.turn_command.failed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command,
        requestId,
        clientTurnId: msg.clientTurnId,
        durationMs: Date.now() - startedAt,
        error: message,
      });

      if (requestId) {
        send(runtimeCommandFailure(command, requestId, message));
        return;
      }
      throw err;
    }
  }

  private async handleGetQueueCommand(
    session: Session,
    msg: Extract<ClientMessage, { type: "get_queue" }>,
    send: (msg: ServerMessage) => void,
    meta: WsCommandMeta,
  ): Promise<void> {
    const startedAt = Date.now();
    const requestId = msg.requestId;

    log.info("ws.queue_command.received", {
      connId: meta.connId,
      sessionId: session.id,
      runtime: runtimeLogTag(session),
      command: "get_queue",
      requestId,
    });

    try {
      const queue = await this.deps.sessions.getMessageQueue(session.id);
      send({ type: "queue_state", queue });
      if (requestId) {
        send(runtimeCommandSuccess("get_queue", requestId, queue));
      }
      log.info("ws.queue_command.completed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command: "get_queue",
        requestId,
        durationMs: Date.now() - startedAt,
        queueVersion: queue.version,
        steeringCount: queue.steering.length,
        followUpCount: queue.followUp.length,
      });
    } catch (err: unknown) {
      const message = safeErrorMessage(err);
      log.warn("ws.queue_command.failed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command: "get_queue",
        requestId,
        durationMs: Date.now() - startedAt,
        error: message,
      });
      if (requestId) {
        send(runtimeCommandFailure("get_queue", requestId, message));
        return;
      }
      throw err;
    }
  }

  private async handleSetQueueCommand(
    session: Session,
    msg: SetQueueMessage,
    send: (msg: ServerMessage) => void,
    meta: WsCommandMeta,
  ): Promise<void> {
    const startedAt = Date.now();
    const requestId = msg.requestId;

    log.info("ws.queue_command.received", {
      connId: meta.connId,
      sessionId: session.id,
      runtime: runtimeLogTag(session),
      command: "set_queue",
      requestId,
      baseVersion: msg.baseVersion,
      steeringCount: msg.steering.length,
      followUpCount: msg.followUp.length,
    });

    try {
      const queue = await this.deps.sessions.setMessageQueue(session.id, {
        baseVersion: msg.baseVersion,
        steering: msg.steering,
        followUp: msg.followUp,
      });
      if (requestId) {
        send(runtimeCommandSuccess("set_queue", requestId, queue));
      }
      log.info("ws.queue_command.completed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command: "set_queue",
        requestId,
        durationMs: Date.now() - startedAt,
        queueVersion: queue.version,
        steeringCount: queue.steering.length,
        followUpCount: queue.followUp.length,
      });
    } catch (err: unknown) {
      const message = safeErrorMessage(err);
      log.warn("ws.queue_command.failed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command: "set_queue",
        requestId,
        durationMs: Date.now() - startedAt,
        error: message,
      });
      if (requestId) {
        send(runtimeCommandFailure("set_queue", requestId, message));
        return;
      }
      throw err;
    }
  }

  private async handleStopCommand(
    session: Session,
    msg: Extract<ClientMessage, { type: "abort" | "stop" }>,
    send: (msg: ServerMessage) => void,
    meta: WsCommandMeta,
  ): Promise<void> {
    const startedAt = Date.now();
    const requestId = msg.requestId;
    const command = msg.type;

    log.info("ws.stop.received", {
      connId: meta.connId,
      sessionId: session.id,
      runtime: runtimeLogTag(session),
      command,
      requestId,
    });

    try {
      await this.deps.sessions.sendAbort(session.id);
      if (requestId) {
        send(runtimeCommandSuccess(command, requestId));
      }

      log.info("ws.stop.completed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command,
        requestId,
        durationMs: Date.now() - startedAt,
      });
    } catch (err: unknown) {
      const message = safeErrorMessage(err);

      log.warn("ws.stop.failed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        command,
        requestId,
        durationMs: Date.now() - startedAt,
        error: message,
      });

      if (requestId) {
        send(runtimeCommandFailure(command, requestId, message));
        return;
      }
      throw err;
    }
  }

  private async handleStopSessionCommand(
    session: Session,
    msg: Extract<ClientMessage, { type: "stop_session" }>,
    send: (msg: ServerMessage) => void,
    meta: WsCommandMeta,
  ): Promise<void> {
    const startedAt = Date.now();
    const requestId = msg.requestId;

    log.info("ws.stop_session.received", {
      connId: meta.connId,
      sessionId: session.id,
      runtime: runtimeLogTag(session),
      requestId,
    });

    try {
      await this.deps.sessions.stopSession(session.id);
      if (requestId) {
        send(runtimeCommandSuccess("stop_session", requestId));
      }

      log.info("ws.stop_session.completed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        requestId,
        durationMs: Date.now() - startedAt,
      });
    } catch (err: unknown) {
      const message = safeErrorMessage(err);

      log.warn("ws.stop_session.failed", {
        connId: meta.connId,
        sessionId: session.id,
        runtime: runtimeLogTag(session),
        requestId,
        durationMs: Date.now() - startedAt,
        error: message,
      });

      if (requestId) {
        send(runtimeCommandFailure("stop_session", requestId, message));
        return;
      }
      throw err;
    }
  }
}

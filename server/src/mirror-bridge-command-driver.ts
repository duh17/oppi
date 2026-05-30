import { WebSocket } from "ws";

import { safeErrorMessage } from "./log-utils.js";

export interface MirrorBridgeCommandConnection {
  bridgeId: string;
  sessionId: string;
  ws: WebSocket;
  pendingCommands: Map<string, MirrorBridgePendingCommand>;
}

export interface MirrorBridgePendingCommand {
  commandType: string;
  requestId?: string;
  clientTurnId?: string;
  startedAt: number;
  resolve: (data: unknown) => void;
  reject: (err: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
}

export type MirrorBridgeCommandDriverEvent =
  | {
      phase: "sent";
      bridgeId: string;
      sessionId: string;
      commandId: string;
      commandType: string;
      requestId?: string;
      clientTurnId?: string;
      sendDurationMs: number;
    }
  | {
      phase: "result";
      bridgeId: string;
      sessionId: string;
      commandId: string;
      commandType: string;
      requestId?: string;
      clientTurnId?: string;
      success: boolean;
      durationMs: number;
      error?: string;
    }
  | {
      phase: "timeout" | "send_failed" | "rejected";
      bridgeId: string;
      sessionId: string;
      commandId: string;
      commandType: string;
      requestId?: string;
      clientTurnId?: string;
      durationMs: number;
      error: string;
    };

export interface MirrorBridgeCommandDriverObserver {
  onCommandEvent?: (event: MirrorBridgeCommandDriverEvent) => void;
}

export interface MirrorBridgeCommandResult {
  id: string;
  success: boolean;
  data?: unknown;
  error?: string;
}

const DEFAULT_COMMAND_TIMEOUT_MS = 30_000;

function formatCommandId(): string {
  return `mirror_cmd_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

function errorFromUnknown(error: unknown): Error {
  return error instanceof Error ? error : new Error(safeErrorMessage(error));
}

export class MirrorBridgeCommandDriver {
  constructor(
    private readonly commandTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
    private readonly observer: MirrorBridgeCommandDriverObserver = {},
  ) {}

  private notify(event: MirrorBridgeCommandDriverEvent): void {
    try {
      this.observer.onCommandEvent?.(event);
    } catch {
      // Diagnostics must not affect bridge command delivery.
    }
  }

  dispatch(
    connection: MirrorBridgeCommandConnection | undefined,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    if (!connection || connection.ws.readyState !== WebSocket.OPEN) {
      throw new Error("pi-tui is not connected");
    }

    const id = formatCommandId();
    const commandType = typeof command.type === "string" ? command.type : "unknown";
    const requestId = typeof command.requestId === "string" ? command.requestId : undefined;
    const clientTurnId =
      typeof command.clientTurnId === "string" ? command.clientTurnId : undefined;
    const outbound = { type: "command", id, command };
    const startedAt = Date.now();
    let serializedOutbound: string;
    try {
      serializedOutbound = JSON.stringify(outbound);
    } catch (error: unknown) {
      const message = `Failed to serialize pi-tui command ${commandType}: ${safeErrorMessage(
        error,
      )}`;
      this.notify({
        phase: "send_failed",
        bridgeId: connection.bridgeId,
        sessionId: connection.sessionId,
        commandId: id,
        commandType,
        requestId,
        clientTurnId,
        durationMs: Date.now() - startedAt,
        error: message,
      });
      return Promise.reject(new Error(message));
    }

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        connection.pendingCommands.delete(id);
        const message = `pi-tui command timed out: ${commandType}`;
        this.notify({
          phase: "timeout",
          bridgeId: connection.bridgeId,
          sessionId: connection.sessionId,
          commandId: id,
          commandType,
          requestId,
          clientTurnId,
          durationMs: Date.now() - startedAt,
          error: message,
        });
        reject(new Error(message));
      }, this.commandTimeoutMs);

      connection.pendingCommands.set(id, {
        commandType,
        requestId,
        clientTurnId,
        startedAt,
        resolve,
        reject,
        timeout,
      });

      const rejectSendFailure = (error: Error): void => {
        clearTimeout(timeout);
        connection.pendingCommands.delete(id);
        this.notify({
          phase: "send_failed",
          bridgeId: connection.bridgeId,
          sessionId: connection.sessionId,
          commandId: id,
          commandType,
          requestId,
          clientTurnId,
          durationMs: Date.now() - startedAt,
          error: error.message,
        });
        reject(error);
      };

      try {
        connection.ws.send(serializedOutbound, (error) => {
          if (!error) {
            this.notify({
              phase: "sent",
              bridgeId: connection.bridgeId,
              sessionId: connection.sessionId,
              commandId: id,
              commandType,
              requestId,
              clientTurnId,
              sendDurationMs: Date.now() - startedAt,
            });
            return;
          }
          rejectSendFailure(error);
        });
      } catch (error: unknown) {
        rejectSendFailure(errorFromUnknown(error));
      }
    });
  }

  resolveResult(
    connection: MirrorBridgeCommandConnection,
    message: MirrorBridgeCommandResult,
    beforeResolve?: () => void,
  ): boolean {
    const pending = connection.pendingCommands.get(message.id);
    if (!pending) return false;

    connection.pendingCommands.delete(message.id);
    clearTimeout(pending.timeout);

    let sideEffectError: Error | undefined;
    try {
      beforeResolve?.();
    } catch (error: unknown) {
      sideEffectError = errorFromUnknown(error);
    }

    this.notify({
      phase: "result",
      bridgeId: connection.bridgeId,
      sessionId: connection.sessionId,
      commandId: message.id,
      commandType: pending.commandType,
      requestId: pending.requestId,
      clientTurnId: pending.clientTurnId,
      success: message.success && !sideEffectError,
      durationMs: Date.now() - pending.startedAt,
      ...(sideEffectError
        ? { error: sideEffectError.message }
        : message.error
          ? { error: message.error }
          : {}),
    });

    if (sideEffectError) {
      pending.reject(sideEffectError);
    } else if (message.success) {
      pending.resolve(message.data);
    } else {
      pending.reject(new Error(message.error || `${pending.commandType} failed`));
    }
    return true;
  }

  rejectPending(connection: MirrorBridgeCommandConnection, error: Error): void {
    for (const [commandId, pending] of connection.pendingCommands) {
      clearTimeout(pending.timeout);
      this.notify({
        phase: "rejected",
        bridgeId: connection.bridgeId,
        sessionId: connection.sessionId,
        commandId,
        commandType: pending.commandType,
        requestId: pending.requestId,
        clientTurnId: pending.clientTurnId,
        durationMs: Date.now() - pending.startedAt,
        error: error.message,
      });
      pending.reject(error);
    }
    connection.pendingCommands.clear();
  }
}

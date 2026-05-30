import { WebSocket } from "ws";

export interface MirrorBridgeCommandConnection {
  bridgeId: string;
  sessionId: string;
  ws: WebSocket;
  pendingCommands: Map<string, MirrorBridgePendingCommand>;
}

export interface MirrorBridgePendingCommand {
  commandType: string;
  resolve: (data: unknown) => void;
  reject: (err: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
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

export class MirrorBridgeCommandDriver {
  constructor(private readonly commandTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS) {}

  dispatch(
    connection: MirrorBridgeCommandConnection | undefined,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    if (!connection || connection.ws.readyState !== WebSocket.OPEN) {
      throw new Error("Terminal mirror is not connected");
    }

    const id = formatCommandId();
    const commandType = typeof command.type === "string" ? command.type : "unknown";
    const outbound = { type: "command", id, command };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        connection.pendingCommands.delete(id);
        reject(new Error(`Terminal mirror command timed out: ${commandType}`));
      }, this.commandTimeoutMs);

      connection.pendingCommands.set(id, { commandType, resolve, reject, timeout });
      connection.ws.send(JSON.stringify(outbound), (error) => {
        if (!error) return;
        clearTimeout(timeout);
        connection.pendingCommands.delete(id);
        reject(error);
      });
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
    beforeResolve?.();

    if (message.success) {
      pending.resolve(message.data);
    } else {
      pending.reject(new Error(message.error || `${pending.commandType} failed`));
    }
    return true;
  }

  rejectPending(connection: MirrorBridgeCommandConnection, error: Error): void {
    for (const pending of connection.pendingCommands.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    connection.pendingCommands.clear();
  }
}

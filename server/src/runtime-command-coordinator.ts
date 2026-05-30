import {
  runtimeCommandFailure,
  runtimeCommandSuccess,
  unsupportedRuntimeCommandError,
} from "./agent-runtime-transport.js";
import type { ServerMessage } from "./types.js";

export interface RuntimeCommandExecutionContext {
  commandType: string;
  request: Record<string, unknown>;
  data: unknown;
  executeCommand: (command: Record<string, unknown>) => Promise<unknown>;
}

export interface RuntimeCommandCoordinatorDeps {
  runtimeName: string;
  isCommandSupported: (commandType: string) => boolean;
  unsupportedReason?: (commandType: string) => string | undefined;
  normalizeError: (commandType: string, rawError: string) => string;
  broadcast: (sessionId: string, message: ServerMessage) => void;
  onCommandSuccess?: (
    sessionId: string,
    context: RuntimeCommandExecutionContext,
  ) => void | Promise<void>;
  /**
   * Managed runtime historically throws preflight errors so direct HTTP/test
   * callers can handle them. Mirror runtime reports them as command_result
   * frames because the bridge owns command completion.
   */
  preflightFailureMode?: "throw" | "broadcast";
}

export class RuntimeCommandCoordinator {
  constructor(private readonly deps: RuntimeCommandCoordinatorDeps) {}

  async forwardClientCommand(
    sessionId: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
    executeCommand: (command: Record<string, unknown>) => Promise<unknown>,
  ): Promise<void> {
    const commandType = typeof message.type === "string" ? message.type : "unknown";

    try {
      if (!this.deps.isCommandSupported(commandType)) {
        throw unsupportedRuntimeCommandError(
          this.deps.runtimeName,
          commandType,
          this.deps.unsupportedReason?.(commandType),
        );
      }
    } catch (error) {
      if (this.deps.preflightFailureMode === "throw") {
        throw error;
      }
      this.broadcastFailure(sessionId, commandType, requestId, error);
      return;
    }

    try {
      const data = await executeCommand({ ...message });
      await this.deps.onCommandSuccess?.(sessionId, {
        commandType,
        request: message,
        data,
        executeCommand,
      });
      this.deps.broadcast(sessionId, runtimeCommandSuccess(commandType, requestId, data));
    } catch (error) {
      this.broadcastFailure(sessionId, commandType, requestId, error);
    }
  }

  private broadcastFailure(
    sessionId: string,
    commandType: string,
    requestId: string | undefined,
    error: unknown,
  ): void {
    const rawError = error instanceof Error ? error.message : String(error);
    this.deps.broadcast(
      sessionId,
      runtimeCommandFailure(
        commandType,
        requestId,
        this.deps.normalizeError(commandType, rawError),
      ),
    );
  }
}

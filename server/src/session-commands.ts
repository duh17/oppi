import { parsePiStateSnapshot, type PiStateSnapshot } from "./pi-events.js";
import { normalizeCommandError } from "./session-protocol.js";
import { composeModelId, type SessionStateActiveSession } from "./session-state.js";
import type { SdkBackend } from "./sdk-backend.js";
import { ts } from "./log-utils.js";
import type { Session, ServerMessage } from "./types.js";

function toRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

export interface CommandSessionState extends SessionStateActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
}

export interface SessionCommandCoordinatorDeps {
  getActiveSession: (key: string) => CommandSessionState | undefined;
  persistSessionNow: (key: string, session: Session) => void;
  broadcast: (key: string, message: ServerMessage) => void;
  applyPiStateSnapshot: (session: Session, state: PiStateSnapshot | null | undefined) => boolean;
  applyRememberedThinkingLevel: (key: string, active: CommandSessionState) => Promise<boolean>;
  persistThinkingPreference: (session: Session) => void;
  persistWorkspaceLastUsedModel: (session: Session) => void;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
}

export class SessionCommandCoordinator {
  constructor(private readonly deps: SessionCommandCoordinatorDeps) {}

  private static readonly SDK_HANDLERS = new Map<
    string,
    (backend: SdkBackend, cmd: Record<string, unknown>) => unknown | Promise<unknown>
  >([
    // State
    ["get_state", (b) => b.getStateSnapshot()],
    ["get_messages", (b) => b.getMessages()],
    ["get_session_stats", (b) => b.getSessionStats()],

    // Model
    [
      "set_model",
      async (b, cmd) => {
        const modelFromCommand =
          typeof cmd.model === "string" && cmd.model.trim().length > 0
            ? cmd.model.trim()
            : undefined;
        const modelFromParts =
          typeof cmd.provider === "string" &&
          cmd.provider.trim().length > 0 &&
          typeof cmd.modelId === "string" &&
          cmd.modelId.trim().length > 0
            ? composeModelId(cmd.provider.trim(), cmd.modelId.trim())
            : undefined;
        const model = modelFromCommand ?? modelFromParts;
        if (!model) {
          throw new Error("Invalid set_model payload: expected model or provider+modelId");
        }
        const result = await b.setModel(model);
        if (!result.success) {
          throw new Error(result.error);
        }
        return result;
      },
    ],
    ["cycle_model", (b, cmd) => b.cycleModel(cmd.direction as string)],
    ["get_available_models", () => []],

    // Thinking
    [
      "set_thinking_level",
      (b, cmd) => {
        b.setThinkingLevel(cmd.level as string);
        return { level: cmd.level };
      },
    ],
    ["cycle_thinking_level", (b) => ({ level: b.cycleThinkingLevel() })],

    // Session
    [
      "new_session",
      async (b) => {
        await b.newSession();
        return { success: true };
      },
    ],
    [
      "set_session_name",
      (b, cmd) => {
        b.setSessionName(cmd.name as string);
        return { name: cmd.name };
      },
    ],
    ["compact", (b, cmd) => b.compact(cmd.instructions as string | undefined)],
    [
      "set_auto_compaction",
      (b, cmd) => {
        b.setAutoCompaction(!!cmd.enabled);
        return { enabled: !!cmd.enabled };
      },
    ],
    ["fork", (b, cmd) => b.fork(cmd.entryId as string)],
    ["switch_session", (b, cmd) => b.switchSession(cmd.sessionPath as string)],

    // Queue modes
    [
      "set_steering_mode",
      (b, cmd) => {
        b.setSteeringMode(cmd.mode as string);
        return { mode: cmd.mode };
      },
    ],
    [
      "set_follow_up_mode",
      (b, cmd) => {
        b.setFollowUpMode(cmd.mode as string);
        return { mode: cmd.mode };
      },
    ],

    // Retry
    [
      "set_auto_retry",
      (b, cmd) => {
        b.setAutoRetry(!!cmd.enabled);
        return { enabled: !!cmd.enabled };
      },
    ],
    [
      "abort_retry",
      (b) => {
        b.abortRetry();
        return { success: true };
      },
    ],

    // Bash
    [
      "abort_bash",
      (b) => {
        b.abortBash();
        return { success: true };
      },
    ],
  ]);

  isAllowedCommand(commandType: string): boolean {
    return SessionCommandCoordinator.SDK_HANDLERS.has(commandType);
  }

  sendCommand(key: string, command: Record<string, unknown>): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    this.routeSdkCommand(active.sdkBackend, command);
  }

  async sendCommandAsync(key: string, command: Record<string, unknown>): Promise<unknown> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return Promise.reject(new Error("Session not active"));
    }

    const type = command.type as string;
    const handler = SessionCommandCoordinator.SDK_HANDLERS.get(type);
    if (!handler) {
      throw new Error(`Unhandled SDK command: ${type}`);
    }

    return handler(active.sdkBackend, command);
  }

  async forwardClientCommand(
    key: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
    sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>,
  ): Promise<void> {
    const cmdType = message.type as string;
    if (!this.isAllowedCommand(cmdType)) {
      throw new Error(`Command not allowed: ${cmdType}`);
    }

    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    try {
      let rpcData: unknown = await sendCommandAsync(key, { ...message });
      const rpcObject = toRecord(rpcData);

      if (cmdType === "get_state") {
        const snapshot = parsePiStateSnapshot(rpcData);
        if (snapshot && this.deps.applyPiStateSnapshot(active.session, snapshot)) {
          this.deps.persistSessionNow(key, active.session);
          // Broadcast updated session so clients see model/thinking/name changes
          this.deps.broadcast(key, { type: "state", session: active.session });
        }
      }

      // Track thinking level changes so the session object stays in sync
      if (cmdType === "cycle_thinking_level" || cmdType === "set_thinking_level") {
        const levelFromResponse =
          typeof rpcObject.level === "string" && rpcObject.level.trim().length > 0
            ? rpcObject.level.trim()
            : undefined;
        const levelFromRequest =
          cmdType === "set_thinking_level" &&
          typeof message.level === "string" &&
          message.level.trim().length > 0
            ? message.level.trim()
            : undefined;

        const effectiveLevel = levelFromResponse ?? levelFromRequest;
        if (effectiveLevel && active.session.thinkingLevel !== effectiveLevel) {
          active.session.thinkingLevel = effectiveLevel;
          this.deps.persistSessionNow(key, active.session);
        }

        this.deps.persistThinkingPreference(active.session);
      }

      // Track model changes so the session object stays in sync
      if (cmdType === "set_model" || cmdType === "cycle_model") {
        // set_model returns the model object, cycle_model returns { model, thinkingLevel, isScoped }
        const modelData = cmdType === "cycle_model" ? toRecord(rpcObject.model) : rpcObject;
        const provider = modelData.provider;
        const modelId = modelData.id;
        if (typeof provider === "string" && typeof modelId === "string") {
          const fullId = composeModelId(provider, modelId);
          if (active.session.model !== fullId) {
            active.session.model = fullId;
            const contextWindowResolver = this.deps.getContextWindowResolver();
            if (contextWindowResolver) {
              active.session.contextWindow = contextWindowResolver(fullId);
            }
            this.deps.persistWorkspaceLastUsedModel(active.session);
            this.deps.persistSessionNow(key, active.session);
          }
        }

        // cycle_model also returns thinkingLevel
        if (
          cmdType === "cycle_model" &&
          typeof rpcObject.thinkingLevel === "string" &&
          rpcObject.thinkingLevel.trim().length > 0
        ) {
          active.session.thinkingLevel = rpcObject.thinkingLevel.trim();
          this.deps.persistThinkingPreference(active.session);
        }

        const appliedRememberedThinking = await this.deps.applyRememberedThinkingLevel(key, active);

        // Keep command_result payload consistent with server-authoritative session state.
        if (
          cmdType === "cycle_model" &&
          appliedRememberedThinking &&
          active.session.thinkingLevel
        ) {
          rpcObject.thinkingLevel = active.session.thinkingLevel;
          rpcData = rpcObject;
        }
      }

      // Track session name changes so optimistic client renames don't get
      // overwritten by stale local get_state snapshots.
      if (cmdType === "set_session_name") {
        const requestedName = typeof message.name === "string" ? message.name.trim() : "";
        const responseName = typeof rpcObject.name === "string" ? rpcObject.name.trim() : "";
        const nextName = responseName.length > 0 ? responseName : requestedName;
        if (nextName.length > 0 && active.session.name !== nextName) {
          active.session.name = nextName;
          this.deps.persistSessionNow(key, active.session);
        }
      }

      // Session-branching commands mutate pi session identity/file in-place.
      // Refresh state immediately so reconnect/resume uses the new branch.
      if (cmdType === "fork" || cmdType === "new_session" || cmdType === "switch_session") {
        try {
          const refreshed = await sendCommandAsync(key, { type: "get_state" });
          const snapshot = parsePiStateSnapshot(refreshed);
          if (snapshot && this.deps.applyPiStateSnapshot(active.session, snapshot)) {
            this.deps.persistSessionNow(key, active.session);
            this.deps.broadcast(key, { type: "state", session: active.session });
          }
        } catch (stateErr) {
          const message = stateErr instanceof Error ? stateErr.message : String(stateErr);
          console.warn(
            `[sdk] ${cmdType} state refresh failed for ${active.session.id}: ${message}`,
          );
        }
      }

      this.deps.broadcast(key, {
        type: "command_result",
        command: cmdType,
        requestId,
        success: true,
        data: rpcData,
      });

      // Broadcast updated session state after model/thinking/name changes
      // so clients see the change immediately without waiting for next agent event
      if (
        cmdType === "set_model" ||
        cmdType === "cycle_model" ||
        cmdType === "set_thinking_level" ||
        cmdType === "cycle_thinking_level" ||
        cmdType === "set_session_name"
      ) {
        this.deps.broadcast(key, { type: "state", session: active.session });
      }
    } catch (err) {
      const rawError = err instanceof Error ? err.message : String(err);
      this.deps.broadcast(key, {
        type: "command_result",
        command: cmdType,
        requestId,
        success: false,
        error: normalizeCommandError(cmdType, rawError),
      });
    }
  }

  private routeSdkCommand(backend: SdkBackend, command: Record<string, unknown>): void {
    const type = command.type as string;
    switch (type) {
      case "prompt":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
        });
        break;
      case "steer":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "steer",
        });
        break;
      case "follow_up":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "followUp",
        });
        break;
      case "abort":
        void backend.abort();
        break;
      default:
        console.warn(`${ts()} [sdk] Unhandled fire-and-forget command: ${type}`);
    }
  }
}

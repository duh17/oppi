import { formatSkillsForPrompt, type AgentSession } from "@earendil-works/pi-coding-agent";

import {
  applyForwardedCommandResultToSession,
  runtimeCommandFailure,
  type RuntimeClientCommand,
} from "./agent-runtime-transport.js";
import {
  computeCacheWaste,
  navigationCreatedBranchSummary,
  resetCacheMissTracker,
  type CacheMissTrackerState,
} from "./cache-miss.js";
import { parsePiStateSnapshot, type PiStateSnapshot } from "./pi-events.js";
import { createLogger } from "./logger.js";
import {
  RuntimeCommandCoordinator,
  type RuntimeCommandExecutionContext,
} from "./runtime-command-coordinator.js";
import {
  readOptionalBoolean,
  readOptionalString,
  readRequiredString,
  readShareSessionAction,
  readShareSessionRedactionPolicy,
  toRecord,
} from "./session-command-parse.js";
import { normalizeCommandError } from "./session-protocol.js";
import { shareSession } from "./session-share.js";
import { composeModelId, type SessionStateActiveSession } from "./session-state.js";
import { readSessionTreeFilterMode, serializeSessionTree } from "./session-tree.js";
import { extensionNameForAllowlist } from "./extension-loader.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { Session, ServerMessage } from "./types.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import type { ThinkingLevel } from "./thinking-levels.js";

const log = createLogger({ base: { component: "session_commands" } });

function toCommandLocation(value: string | undefined): "user" | "project" | "path" | undefined {
  if (value === "user" || value === "project" || value === "path") {
    return value;
  }
  return undefined;
}

interface SessionCommandDescriptor {
  name: string;
  description?: string;
  source: "builtin" | "extension" | "prompt" | "skill";
  location?: "user" | "project" | "path";
  path?: string;
}

interface ContextFileTokenSnapshot {
  path: string;
  chars: number;
  tokens: number;
}

interface SessionContextCompositionSnapshot {
  piSystemPromptChars: number;
  piSystemPromptTokens: number;
  agentsChars: number;
  agentsTokens: number;
  agentsFiles: ContextFileTokenSnapshot[];
  skillsListingChars: number;
  skillsListingTokens: number;
}

interface SessionResourceSnapshot {
  name: string;
  description?: string;
  path: string;
}

function estimateTokensFromChars(chars: number): number {
  if (chars <= 0) {
    return 0;
  }
  return Math.max(1, Math.ceil(chars / 4));
}

function collectSessionContextComposition(
  session: AgentSession,
): SessionContextCompositionSnapshot {
  const piSystemPromptChars = session.systemPrompt.length;
  const piSystemPromptTokens = estimateTokensFromChars(piSystemPromptChars);

  const agentsFiles = session.resourceLoader.getAgentsFiles().agentsFiles.map((file) => {
    const chars = file.content.length;
    return {
      path: file.path,
      chars,
      tokens: estimateTokensFromChars(chars),
    };
  });

  const agentsChars = agentsFiles.reduce((sum, file) => sum + file.chars, 0);
  const agentsTokens = agentsFiles.reduce((sum, file) => sum + file.tokens, 0);

  const skillsListing = formatSkillsForPrompt(session.resourceLoader.getSkills().skills);
  const skillsListingChars = skillsListing.length;
  const skillsListingTokens = estimateTokensFromChars(skillsListingChars);

  return {
    piSystemPromptChars,
    piSystemPromptTokens,
    agentsChars,
    agentsTokens,
    agentsFiles,
    skillsListingChars,
    skillsListingTokens,
  };
}

function collectLoadedSessionResources(session: AgentSession): {
  skills: SessionResourceSnapshot[];
  extensions: SessionResourceSnapshot[];
} {
  const skills = session.resourceLoader.getSkills().skills.map((skill) => ({
    name: skill.name,
    description: skill.description,
    path: skill.baseDir,
  }));

  const extensions = session.resourceLoader.getExtensions().extensions.map((extension) => ({
    name: extensionNameForAllowlist(extension.resolvedPath || extension.path, extension.sourceInfo),
    path: extension.resolvedPath || extension.path,
  }));

  return { skills, extensions };
}

interface SessionModelUsageSnapshot {
  provider?: string;
  model: string;
  tokens: number;
  cost: number;
}

function finiteNonNegative(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, value) : 0;
}

function addUsageToModelBreakdown(
  byModel: Map<string, SessionModelUsageSnapshot>,
  key: string,
  model: string,
  provider: string | undefined,
  value: unknown,
): void {
  const usage = toRecord(value);
  const cost = toRecord(usage.cost);
  const current = byModel.get(key) ?? {
    ...(provider ? { provider } : {}),
    model,
    tokens: 0,
    cost: 0,
  };
  current.tokens +=
    finiteNonNegative(usage.input) +
    finiteNonNegative(usage.output) +
    finiteNonNegative(usage.cacheRead) +
    finiteNonNegative(usage.cacheWrite);
  current.cost += finiteNonNegative(cost.total);
  byModel.set(key, current);
}

function collectModelUsage(entries: readonly unknown[]): SessionModelUsageSnapshot[] {
  const byModel = new Map<string, SessionModelUsageSnapshot>();

  for (const value of entries) {
    if (!value || typeof value !== "object") continue;
    const entry = value as Record<string, unknown>;

    if (entry.type === "message" && entry.message && typeof entry.message === "object") {
      const message = entry.message as Record<string, unknown>;
      if (message.role === "assistant") {
        const provider = typeof message.provider === "string" ? message.provider : "unknown";
        const configuredModel = typeof message.model === "string" ? message.model : "unknown";
        const model =
          typeof message.responseModel === "string" && message.responseModel.length > 0
            ? message.responseModel
            : configuredModel;
        addUsageToModelBreakdown(byModel, `${provider}/${model}`, model, provider, message.usage);
      } else if (message.role === "toolResult") {
        addUsageToModelBreakdown(
          byModel,
          "tools-summaries",
          "Tools & summaries",
          undefined,
          message.usage,
        );
      }
    } else if (entry.type === "compaction" || entry.type === "branch_summary") {
      addUsageToModelBreakdown(
        byModel,
        "tools-summaries",
        "Tools & summaries",
        undefined,
        entry.usage,
      );
    }
  }

  return [...byModel.values()]
    .filter((entry) => entry.tokens > 0 || entry.cost > 0)
    .sort((left, right) => right.cost - left.cost);
}

function collectSessionStats(backend: SdkBackend): Record<string, unknown> {
  const session = backend.session;
  const entries = session.sessionManager.getEntries();
  return {
    ...session.getSessionStats(),
    cacheWaste: computeCacheWaste(entries, backend.cacheMissModelPriceSource),
    modelBreakdown: collectModelUsage(entries),
    contextComposition: collectSessionContextComposition(session),
    loadedResources: collectLoadedSessionResources(session),
  };
}

const BUILTIN_SLASH_COMMANDS: readonly SessionCommandDescriptor[] = [
  {
    name: "reload",
    description: "Reload extensions, skills, prompts, and context files",
    source: "builtin",
  },
  {
    name: "share",
    description: "Share session as an auto-redacted secret GitHub gist",
    source: "builtin",
  },
];

function collectSessionCommands(session: AgentSession): { commands: SessionCommandDescriptor[] } {
  const commands: SessionCommandDescriptor[] = [...BUILTIN_SLASH_COMMANDS];

  for (const command of session.extensionRunner?.getRegisteredCommands() ?? []) {
    commands.push({
      name: command.name,
      description: command.description,
      source: "extension",
      path: command.sourceInfo.path,
    });
  }

  for (const template of session.promptTemplates) {
    commands.push({
      name: template.name,
      description: template.description,
      source: "prompt",
      location: toCommandLocation(template.sourceInfo.source),
      path: template.filePath,
    });
  }

  for (const skill of session.resourceLoader.getSkills().skills) {
    commands.push({
      name: `skill:${skill.name}`,
      description: skill.description,
      source: "skill",
      location: toCommandLocation(skill.sourceInfo.source),
      path: skill.filePath,
    });
  }

  return { commands };
}

export interface CommandSessionState extends SessionStateActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
  cacheMissTracker?: CacheMissTrackerState;
}

export interface SessionCommandCoordinatorDeps {
  getActiveSession: (key: string) => CommandSessionState | undefined;
  persistSessionNow: (key: string, session: Session) => void;
  broadcast: (key: string, message: ServerMessage) => void;
  applyPiStateSnapshot: (session: Session, state: PiStateSnapshot | null | undefined) => boolean;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
  reloadRuntimeConfig?: () => void;
}

type BackendCommandHandler = (
  backend: SdkBackend,
  cmd: Record<string, unknown>,
) => unknown | Promise<unknown>;

type SessionCommandHandler = (
  session: AgentSession,
  cmd: Record<string, unknown>,
) => unknown | Promise<unknown>;

interface QueuedCompactCommand {
  message: RuntimeClientCommand;
  requestId?: string;
}

const IDLE_ONLY_COMMANDS = new Set(["compact", "navigate_tree", "reload"]);
const IDENTITY_REPLACEMENT_COMMANDS = new Set(["new_session", "switch_session", "fork", "clone"]);

function identityReplacementError(commandType: string): Error {
  return new Error(
    `${commandType} is not allowed inside an Oppi-focused session; create a distinct canonical session through Oppi lifecycle routes`,
  );
}

function assertIdleForCommand(active: CommandSessionState, commandType: string): void {
  if (!IDLE_ONLY_COMMANDS.has(commandType)) {
    return;
  }

  if (
    active.session.status !== "ready" ||
    active.sdkBackend.isStreaming ||
    active.sdkBackend.isCompacting
  ) {
    throw new Error(`${commandType} requires an idle session`);
  }
}

export class SessionCommandCoordinator {
  private readonly runtimeCommandCoordinator: RuntimeCommandCoordinator;
  private readonly queuedCompactCommands = new Map<string, QueuedCompactCommand[]>();

  constructor(private readonly deps: SessionCommandCoordinatorDeps) {
    this.runtimeCommandCoordinator = new RuntimeCommandCoordinator({
      runtimeName: "oppi runtime",
      isCommandSupported: (commandType) => this.isAllowedCommand(commandType),
      unsupportedReason: (commandType) =>
        IDENTITY_REPLACEMENT_COMMANDS.has(commandType)
          ? identityReplacementError(commandType).message
          : undefined,
      normalizeError: normalizeCommandError,
      broadcast: (key, message) => this.deps.broadcast(key, message),
      onCommandSuccess: (key, context) => this.handleForwardedCommandSuccess(key, context),
      preflightFailureMode: "throw",
    });
  }

  private static readonly SERVER_LOGIC_HANDLERS = new Map<string, BackendCommandHandler>([
    ["get_state", (backend) => backend.getStateSnapshot()],
    ["get_session_stats", (backend) => collectSessionStats(backend)],

    [
      "set_model",
      async (backend, cmd) => {
        const modelFromCommand = readOptionalString(cmd.model);
        const provider = readOptionalString(cmd.provider);
        const modelId = readOptionalString(cmd.modelId);
        const modelFromParts = provider && modelId ? composeModelId(provider, modelId) : undefined;
        const model = modelFromCommand ?? modelFromParts;
        if (!model) {
          throw new Error("Invalid set_model payload: expected model or provider+modelId");
        }

        const persist = readOptionalBoolean(cmd.persist) === true;
        const result = await backend.setModel(model, persist ? { persist: true } : undefined);
        if (!result.success) {
          throw new Error(result.error);
        }
        return result;
      },
    ],

    [
      "cycle_model",
      (backend, cmd) =>
        backend.withRuntimeLifecycleTransaction("cycle_model", async () =>
          backend.session.cycleModel(cmd.direction as never),
        ),
    ],

    [
      "set_thinking_level",
      (backend, cmd) => {
        const level = readRequiredString(cmd.level, "level") as ThinkingLevel;
        // Pi 0.84.3 setThinkingLevel always writes session + settings when the level changes.
        backend.session.setThinkingLevel(level);
        return { level };
      },
    ],

    ["cycle_thinking_level", (backend) => ({ level: backend.session.cycleThinkingLevel() })],

    ["reload", (backend) => backend.reloadResources()],

    [
      "set_session_name",
      (backend, cmd) => {
        const name = readRequiredString(cmd.name, "name");
        backend.session.setSessionName(name);
        return { name };
      },
    ],
  ]);

  private static readonly SESSION_PASSTHROUGH_HANDLERS = new Map<string, SessionCommandHandler>([
    ["get_messages", (session) => session.messages],
    ["get_fork_messages", (session) => ({ messages: session.getUserMessagesForForking() })],
    [
      "get_session_tree",
      (session, cmd) =>
        serializeSessionTree(session.sessionManager, readSessionTreeFilterMode(cmd.filterMode)),
    ],
    [
      "navigate_tree",
      (session, cmd) =>
        session.navigateTree(readRequiredString(cmd.targetId, "targetId"), {
          summarize: readOptionalBoolean(cmd.summarize),
          customInstructions: readOptionalString(cmd.customInstructions),
          replaceInstructions: readOptionalBoolean(cmd.replaceInstructions),
          label: readOptionalString(cmd.label),
        }),
    ],
    ["get_commands", (session) => collectSessionCommands(session)],
    [
      "share_session",
      (session, cmd) =>
        shareSession(
          session,
          {},
          {
            action: readShareSessionAction(cmd),
            redactionPolicy: readShareSessionRedactionPolicy(cmd),
          },
        ),
    ],

    ["compact", (session, cmd) => session.compact(readOptionalString(cmd.customInstructions))],

    [
      "set_auto_compaction",
      (session, cmd) => {
        session.setAutoCompactionEnabled(!!cmd.enabled);
        return { enabled: !!cmd.enabled };
      },
    ],

    [
      "set_steering_mode",
      (session, cmd) => {
        session.setSteeringMode(cmd.mode as "all" | "one-at-a-time");
        return { mode: cmd.mode };
      },
    ],

    [
      "set_follow_up_mode",
      (session, cmd) => {
        session.setFollowUpMode(cmd.mode as "all" | "one-at-a-time");
        return { mode: cmd.mode };
      },
    ],

    [
      "set_auto_retry",
      (session, cmd) => {
        session.setAutoRetryEnabled(!!cmd.enabled);
        return { enabled: !!cmd.enabled };
      },
    ],

    [
      "abort_retry",
      (session) => {
        session.abortRetry();
        return { success: true };
      },
    ],

    [
      "abort_bash",
      (session) => {
        session.abortBash();
        return { success: true };
      },
    ],
  ]);

  private static readonly ALLOWED_COMMANDS = new Set<string>([
    ...SessionCommandCoordinator.SERVER_LOGIC_HANDLERS.keys(),
    ...SessionCommandCoordinator.SESSION_PASSTHROUGH_HANDLERS.keys(),
  ]);

  isAllowedCommand(commandType: string): boolean {
    if (IDENTITY_REPLACEMENT_COMMANDS.has(commandType)) return false;
    return SessionCommandCoordinator.ALLOWED_COMMANDS.has(commandType);
  }

  sendCommand(
    key: string,
    command: Record<string, unknown>,
    permit?: SessionRuntimeTransactionPermit,
    onPreflightAccepted?: () => void,
  ): void | Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) return;
    return this.routeSdkCommand(active.sdkBackend, command, permit, onPreflightAccepted);
  }

  async sendCommandAsync(key: string, command: Record<string, unknown>): Promise<unknown> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error("Session not active");
    }

    const type = command.type as string;
    if (IDENTITY_REPLACEMENT_COMMANDS.has(type)) {
      throw identityReplacementError(type);
    }
    assertIdleForCommand(active, type);
    return this.executeCommand(active, type, command);
  }

  resumeQueuedCompactions(key: string): void {
    const queued = this.queuedCompactCommands.get(key);
    if (!queued) {
      return;
    }

    this.queuedCompactCommands.delete(key);
    void this.executeQueuedCompactions(key, queued);
  }

  cancelQueuedCompactions(key: string): void {
    const queued = this.queuedCompactCommands.get(key);
    if (!queued) {
      return;
    }

    this.queuedCompactCommands.delete(key);
    for (const pending of queued) {
      this.deps.broadcast(
        key,
        runtimeCommandFailure(
          "compact",
          pending.requestId,
          "Session ended before queued compact could run",
        ),
      );
    }
  }

  private shouldQueueCompact(active: CommandSessionState, commandType: string): boolean {
    return (
      commandType === "compact" &&
      (active.session.status !== "ready" || active.sdkBackend.isStreaming)
    );
  }

  private enqueueCompact(
    key: string,
    message: RuntimeClientCommand,
    requestId: string | undefined,
  ): void {
    const queued = this.queuedCompactCommands.get(key) ?? [];
    queued.push({ message, requestId });
    this.queuedCompactCommands.set(key, queued);
  }

  private async executeQueuedCompactions(
    key: string,
    queued: QueuedCompactCommand[],
  ): Promise<void> {
    for (const pending of queued) {
      const active = this.deps.getActiveSession(key);
      if (!active || active.session.status !== "ready") {
        this.deps.broadcast(
          key,
          runtimeCommandFailure(
            "compact",
            pending.requestId,
            "Session ended before queued compact could run",
          ),
        );
        continue;
      }

      await this.runtimeCommandCoordinator.forwardClientCommand(
        key,
        pending.message,
        pending.requestId,
        (command) => this.sendCommandAsync(key, command),
      );
    }
  }

  private async executeCommand(
    active: CommandSessionState,
    type: string,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    if (IDENTITY_REPLACEMENT_COMMANDS.has(type)) {
      throw identityReplacementError(type);
    }
    if (type === "reload") {
      return active.sdkBackend.reloadResources(this.deps.reloadRuntimeConfig);
    }

    const backendHandler = SessionCommandCoordinator.SERVER_LOGIC_HANDLERS.get(type);
    if (backendHandler) {
      return backendHandler(active.sdkBackend, command);
    }

    const sessionHandler = SessionCommandCoordinator.SESSION_PASSTHROUGH_HANDLERS.get(type);
    if (!sessionHandler) {
      throw new Error(`Unhandled SDK command: ${type}`);
    }

    const result = await sessionHandler(active.sdkBackend.session, command);
    if (
      type === "navigate_tree" &&
      active.cacheMissTracker &&
      navigationCreatedBranchSummary(result)
    ) {
      resetCacheMissTracker(active.cacheMissTracker);
    }
    return result;
  }

  async forwardClientCommand(
    key: string,
    message: RuntimeClientCommand,
    requestId: string | undefined,
    sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>,
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    const commandType = message.type;
    if (IDENTITY_REPLACEMENT_COMMANDS.has(commandType)) {
      this.deps.broadcast(
        key,
        runtimeCommandFailure(
          commandType,
          requestId,
          identityReplacementError(commandType).message,
        ),
      );
      return;
    }
    if (this.shouldQueueCompact(active, commandType)) {
      this.enqueueCompact(key, message, requestId);
      return;
    }

    await this.runtimeCommandCoordinator.forwardClientCommand(key, message, requestId, (command) =>
      sendCommandAsync(key, command),
    );
  }

  private async handleForwardedCommandSuccess(
    key: string,
    context: RuntimeCommandExecutionContext,
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    const { commandType: cmdType, request, data: rpcData, executeCommand } = context;

    if (cmdType === "get_state") {
      const snapshot = parsePiStateSnapshot(rpcData);
      if (snapshot && this.deps.applyPiStateSnapshot(active.session, snapshot)) {
        this.deps.persistSessionNow(key, active.session);
        // Broadcast updated session so clients see model/thinking/name changes
        this.deps.broadcast(key, { type: "state", session: active.session });
      }
    }

    const resultApplication = applyForwardedCommandResultToSession({
      session: active.session,
      commandType: cmdType,
      request,
      data: rpcData,
      contextWindowResolver: this.deps.getContextWindowResolver(),
    });
    if (resultApplication.changed) {
      this.deps.persistSessionNow(key, active.session);
    }

    // Session-branching commands mutate pi session identity/file in-place.
    // Refresh state immediately so reconnect/resume uses the new branch.
    if (cmdType === "navigate_tree") {
      try {
        const refreshed = await executeCommand({ type: "get_state" });
        const snapshot = parsePiStateSnapshot(refreshed);
        if (snapshot && this.deps.applyPiStateSnapshot(active.session, snapshot)) {
          this.deps.persistSessionNow(key, active.session);
          this.deps.broadcast(key, { type: "state", session: active.session });
        }
      } catch (stateErr) {
        const message = stateErr instanceof Error ? stateErr.message : String(stateErr);
        log.warn("session_commands.state_refresh.failed", {
          sessionId: active.session.id,
          commandType: cmdType,
          error: message,
        });
      }
    }

    // Broadcast updated session state after model/thinking/name changes
    // so clients see the change immediately without waiting for next agent event
    if (resultApplication.shouldBroadcastState) {
      this.deps.broadcast(key, { type: "state", session: active.session });
    }
  }

  private routeSdkCommand(
    backend: SdkBackend,
    command: Record<string, unknown>,
    permit?: SessionRuntimeTransactionPermit,
    onPreflightAccepted?: () => void,
  ): void | Promise<void> {
    const type = command.type as string;
    switch (type) {
      case "prompt": {
        const options = {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: command.streamingBehavior as "steer" | "followUp" | undefined,
          ...(onPreflightAccepted ? { onPreflightAccepted } : {}),
        };
        return permit
          ? backend.prompt(command.message as string, options, permit)
          : backend.prompt(command.message as string, options);
      }
      case "steer": {
        const options = {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "steer" as const,
          ...(onPreflightAccepted ? { onPreflightAccepted } : {}),
        };
        return permit
          ? backend.prompt(command.message as string, options, permit)
          : backend.prompt(command.message as string, options);
      }
      case "follow_up": {
        const options = {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "followUp" as const,
          ...(onPreflightAccepted ? { onPreflightAccepted } : {}),
        };
        return permit
          ? backend.prompt(command.message as string, options, permit)
          : backend.prompt(command.message as string, options);
      }
      case "abort":
        return backend.abort();
      default:
        log.warn("session_commands.unhandled_fire_and_forget_command", {
          commandType: type,
        });
    }
  }
}

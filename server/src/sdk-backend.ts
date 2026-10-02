/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { AgentConfigurationError } from "./agent-launch-errors.js";
import { safeErrorMessage } from "./log-utils.js";
import { isDeclaredControlSession } from "./control-session.js";
import { createLogger } from "./logger.js";
import { chmodSync, existsSync, lstatSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, posix, relative, resolve as resolvePath } from "node:path";

import {
  createAgentSession,
  formatSkillsForPrompt,
  createAgentSessionRuntime,
  createBashToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  createEditToolDefinition,
  createFindToolDefinition,
  createLsToolDefinition,
  type AgentSession,
  type AgentSessionEvent,
  type AgentSessionRuntime,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionToolContext,
  type ResourceDiagnostic,
  type Skill,
  type ToolDefinition,
  SessionManager as PiSessionManager,
  DefaultResourceLoader,
  ModelRuntime,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
  hasTrustRequiringProjectResources,
  resolveModelScopeWithDiagnostics,
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";
import {
  resolveEnabledScopedModels,
  resolveInitialScopedSessionPins,
} from "./session-scoped-models.js";

import type { AgentDefinition } from "./agent-launch-service.js";
import { computeCacheWaste, type CacheMissModelPriceSource } from "./cache-miss.js";
import type { AgentBackend } from "./agent-backend.js";
import { extensionNameForAllowlist } from "./extension-loader.js";
import { toRecord } from "./session-command-parse.js";
import {
  modelCandidatesFromRegistry,
  modelUnavailableMessage,
  RequiredModelUnavailableError,
  resolveModelRequest,
  stripModelThinkingLevel,
} from "./model-resolution.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import { applyPendingProviderRegistrations } from "./extension-model-discovery.js";
import { PROJECT_TRUST_TIMEOUT_MS, resolveManagedProjectTrust } from "./project-trust.js";
import {
  availableMcpBuiltinNames,
  createMcpBuiltinExtensions,
  isBuiltinExtensionPath,
} from "./host-mcp-extensions.js";
import { createSandboxMcpOptions, emptySandboxMcp, loadPiMcpInternals } from "./sandbox-mcp.js";
import { createLifecycleJournalExtension } from "./lifecycle-journal-extension.js";
import {
  DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS,
  freezeMobileOutputGuideSettingsSnapshot,
  type MobileOutputGuideSettingsSnapshot,
} from "./mobile-output-guide-settings.js";
import type { ExtensionErrorEvent, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import { addSessionAttachmentFile, type SessionAttachmentKind } from "./session-attachments.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import { resolveSelectedAgentExtensionPaths } from "./agent-extension-selection.js";
import { SdkUiBridge } from "./sdk-ui-bridge.js";
import { hostMountValidationError, resolveHostPath } from "./host.js";
import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "./oppi-cli-prompt.js";
import { buildMobileOutputGuide, buildOppiSystemPromptAppend } from "./oppi-docs.js";
import type { ReadonlyMount, ReadonlyMountSpec, VmSecretDefinition } from "./gondolin-manager.js";
import type { GondolinVm } from "./gondolin-ops.js";
import type { ServerConfig, Session, Workspace } from "./types.js";
import { resolveWorkspaceSessionCwd, WorkspaceWorktreeError } from "./worktrees.js";
import { callerSessionIdentityShellPrefix } from "./session-caller-identity.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "./session-runtime-transaction.js";
import { createLiveEntryRendererLookup, type LiveEntryRendererSet } from "./trace.js";

function toCommandLocation(value: string | undefined): "user" | "project" | "path" | undefined {
  if (value === "user" || value === "project" || value === "path") {
    return value;
  }
  return undefined;
}

type SessionCommandDescriptor = ReturnType<AgentBackend["commands"]>["commands"][number];

function estimateTokensFromChars(chars: number): number {
  if (chars <= 0) {
    return 0;
  }
  return Math.max(1, Math.ceil(chars / 4));
}

function collectSessionContextComposition(session: AgentSession): {
  piSystemPromptChars: number;
  piSystemPromptTokens: number;
  agentsChars: number;
  agentsTokens: number;
  agentsFiles: Array<{ path: string; chars: number; tokens: number }>;
  skillsListingChars: number;
  skillsListingTokens: number;
} {
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
  skills: Array<{ name: string; description?: string; path: string }>;
  extensions: Array<{ name: string; path: string }>;
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

type AttachmentToolExecute = ToolDefinition["execute"] & {
  __oppiAttachmentHelperWrapped?: true;
};

type AttachmentAddFileInput = {
  path: string;
  kind?: SessionAttachmentKind;
  mimeType?: string;
  fileName?: string;
  durationSeconds?: number;
  width?: number;
  height?: number;
  text?: string;
  deleteSource?: boolean;
};

type ExtensionContextWithAttachments = ExtensionToolContext & {
  attachments: {
    addFile(input: AttachmentAddFileInput): Record<string, unknown>;
  };
};

export function enforceLaunchModelPolicy(
  session: Session,
  resolvedModel: { provider: string; id: string } | undefined,
): void {
  if (session.launch?.modelPolicy !== "required" || !session.model) return;
  const requested = stripModelThinkingLevel(session.model).model.trim();
  const resolvedCanonical = resolvedModel
    ? `${resolvedModel.provider}/${resolvedModel.id}`
    : undefined;
  if (resolvedModel && (requested === resolvedCanonical || requested === resolvedModel.id)) return;
  throw new RequiredModelUnavailableError(session.model);
}

export function normalizeThinkingLevel(level: string | undefined): ThinkingLevel | undefined {
  if (level === undefined) return undefined;
  return isThinkingLevel(level) ? level : undefined;
}

/**
 * Resolve the model a session starts on. An exact stored `provider/id` keeps working
 * while its provider still has auth (Pi's available set), even after enabledModels
 * narrows the picker scope; Pi restores resumed sessions the same way. Everything
 * else, including unauthenticated local models, stays inside enabledModels.
 */
export function resolveSessionSeedModel(
  modelRegistry: Pick<ModelRegistry, "getAvailable" | "getAll">,
  modelId: string,
  enabledModels?: string[],
): ReturnType<ModelRegistry["find"]> {
  const requested = stripModelThinkingLevel(modelId).model.trim();
  const exact = modelRegistry
    .getAvailable()
    .find((model) => `${model.provider}/${model.id}` === requested);
  if (exact) return exact;
  const candidates = modelCandidatesFromRegistry(modelRegistry, enabledModels);
  return resolveModelRequest(modelId, candidates)?.candidate.model;
}

/**
 * Resolve workspace host mount into an absolute SDK cwd.
 *
 * Workspace hostMount is stored in display form (commonly "~/...").
 * Node path APIs do not expand "~" and will treat it as a relative path,
 * producing cwd values like "<server-cwd>/~/workspace/...". Normalize here
 * before passing cwd into SDK components.
 */
function sandboxWorkspaceSlug(workspace: Workspace): string {
  return (
    (workspace.name || workspace.id)
      .toLowerCase()
      .replace(/[^a-z0-9-_]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || workspace.id
  );
}

export function resolveSandboxGuestCwd(workspace: Workspace): string {
  return posix.join("/workspace", sandboxWorkspaceSlug(workspace));
}

function ensureOwnerOnlyRealDirectory(path: string, errorMessage: string): void {
  try {
    mkdirSync(path, { mode: 0o700 });
  } catch (error: unknown) {
    if (
      !(error instanceof Error) ||
      !("code" in error) ||
      (error as NodeJS.ErrnoException).code !== "EEXIST"
    ) {
      throw error;
    }
  }
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error(errorMessage);
  }
  chmodSync(path, 0o700);
}

export function resolveSdkSessionCwd(
  workspace?: Workspace,
  session?: Pick<Session, "workspaceId" | "worktreeId" | "control">,
  options: { dataDir?: string } = {},
): string {
  if (session && isDeclaredControlSession(session)) {
    if (!options.dataDir) {
      throw new Error("Control sessions require an Oppi data directory");
    }
    const controlSessionsDir = join(options.dataDir, "control-sessions");
    ensureOwnerOnlyRealDirectory(
      controlSessionsDir,
      "Control session cwd parent must be a real directory",
    );
    const controlCwd = join(controlSessionsDir, "cwd");
    ensureOwnerOnlyRealDirectory(controlCwd, "Control session cwd must be a real directory");
    return controlCwd;
  }

  if (workspace?.runtime !== "sandbox" && workspace && session?.worktreeId) {
    const worktreePath = resolveWorkspaceSessionCwd(workspace, session.worktreeId, options);
    if (worktreePath && existsSync(worktreePath)) return worktreePath;
    throw new WorkspaceWorktreeError(409, "Session worktree is no longer available");
  }

  const rawHostMount = workspace?.hostMount?.trim();
  if (!rawHostMount) {
    if (workspace?.runtime === "sandbox") {
      // Auto-create a dedicated sandbox directory. Permanent, per-workspace.
      // The host path is never exposed to the sandboxed agent; it only backs
      // the VM mount at resolveSandboxGuestCwd(workspace).
      const sandboxDir = join(homedir(), "sandbox", sandboxWorkspaceSlug(workspace));
      mkdirSync(sandboxDir, { recursive: true });
      return sandboxDir;
    }
    return homedir();
  }

  return resolveHostPath(rawHostMount);
}

export function resolveSdkSessionDisplayCwd(
  workspace?: Workspace,
  session?: Pick<Session, "workspaceId" | "worktreeId" | "control">,
  options: { dataDir?: string } = {},
): string {
  if (session && isDeclaredControlSession(session)) {
    return "Pi Control";
  }
  if (workspace?.runtime === "sandbox") {
    return resolveSandboxGuestCwd(workspace);
  }
  return resolveSdkSessionCwd(workspace, session, options);
}

type AgentContextFile = { path: string; content: string };

type SkillLoadResult = {
  skills: Skill[];
  diagnostics: ResourceDiagnostic[];
};

type ExtensionLoadResult = ReturnType<DefaultResourceLoader["getExtensions"]>;

function assertSelectedAgentResourcesAvailable(
  selectedSkillPaths: string[] | undefined,
  selectedExtensionPaths: string[] | undefined,
): void {
  const unavailableSkills = (selectedSkillPaths ?? []).filter((path) => !existsSync(path));
  if (unavailableSkills.length > 0) {
    throw new AgentConfigurationError(
      "agent_skills_unavailable",
      { unavailableSkills },
      `Selected Agent Skill is unavailable: ${unavailableSkills.join(", ")}`,
    );
  }
  // `builtin:<name>` selections are not files; the selection resolver already
  // restricted them to built-ins this session supplies.
  const unavailableExtensions = (selectedExtensionPaths ?? []).filter(
    (path) => !isBuiltinExtensionPath(path) && !existsSync(path),
  );
  if (unavailableExtensions.length > 0) {
    throw new AgentConfigurationError(
      "agent_extensions_unavailable",
      { unavailableExtensions },
      `Selected Agent Extension is unavailable: ${unavailableExtensions.join(", ")}`,
    );
  }
}

function assertSelectedAgentSkillsLoaded(
  selectedPaths: string[] | undefined,
  result: SkillLoadResult,
): void {
  if (selectedPaths === undefined) return;
  const unavailableSkills = selectedPaths.filter(
    (selectedPath) =>
      !result.skills.some(
        (skill) =>
          isPathWithin(selectedPath, skill.filePath) ||
          isPathWithin(selectedPath, skill.baseDir) ||
          isPathWithin(skill.baseDir, selectedPath),
      ),
  );
  if (unavailableSkills.length > 0) {
    throw new AgentConfigurationError(
      "agent_skills_unavailable",
      { unavailableSkills },
      `Selected Agent Skill is unavailable: ${unavailableSkills.join(", ")}`,
    );
  }
}

function assertSelectedAgentExtensionsLoaded(
  selectedPaths: string[] | undefined,
  result: ExtensionLoadResult,
): void {
  if (selectedPaths === undefined) return;
  const unavailableExtensions = selectedPaths.filter(
    (selectedPath) =>
      !result.extensions.some((extension) =>
        isBuiltinExtensionPath(selectedPath)
          ? extension.path === selectedPath
          : !extension.path.startsWith("<inline:") &&
            !isBuiltinExtensionPath(extension.path) &&
            (isPathWithin(selectedPath, extension.resolvedPath) ||
              isPathWithin(extension.resolvedPath, selectedPath)),
      ),
  );
  if (unavailableExtensions.length > 0) {
    throw new AgentConfigurationError(
      "agent_extensions_unavailable",
      { unavailableExtensions },
      `Selected Agent Extension could not be loaded: ${unavailableExtensions.join(", ")}`,
    );
  }
}

function isPathWithin(parent: string, child: string): boolean {
  const resolvedParent = resolvePath(parent);
  const resolvedChild = resolvePath(child);
  const rel = relative(resolvedParent, resolvedChild);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

/** Real path when it exists (symlinks followed), else the lexical path; like Pi's canonicalizePath. */
function canonicalPath(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return resolvePath(path);
  }
}

function hostWorkspacePathToGuest(
  hostCwd: string,
  guestCwd: string,
  hostPath: string,
): string | null {
  if (!isPathWithin(hostCwd, hostPath)) {
    return null;
  }

  const rel = relative(resolvePath(hostCwd), resolvePath(hostPath));
  return rel ? posix.join(guestCwd, rel.split(/[\\/]/).join("/")) : guestCwd;
}

function safeGuestSegment(value: string): string {
  return (
    value
      .toLowerCase()
      .replace(/[^a-z0-9-_]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "") || "resource"
  );
}

/** One mapping for both SDK presentation and durable-first shared VM mounts. */
function sandboxGuestSkills(
  skills: Skill[],
  guestCwd: string,
  mounts: Map<string, ReadonlyMount>,
): Skill[] {
  return skills.map((skill) => {
    const guestBaseDir = posix.join(guestCwd, ".pi", "skills", safeGuestSegment(skill.name));
    mounts.set(guestBaseDir, { hostPath: skill.baseDir, guestPath: guestBaseDir });
    return {
      ...skill,
      baseDir: guestBaseDir,
      filePath: posix.join(guestBaseDir, basename(skill.filePath)),
    };
  });
}

function replaceAllLiteral(value: string, search: string, replacement: string): string {
  return search ? value.split(search).join(replacement) : value;
}

function redactHostEnvironment(value: string, hostCwd: string, guestCwd: string): string {
  let redacted = replaceAllLiteral(value, hostCwd, guestCwd);
  const home = homedir();
  redacted = replaceAllLiteral(redacted, home, "/workspace/.host-home");
  redacted = replaceAllLiteral(redacted, basename(home), "host-user");
  return redacted;
}

function sandboxSystemPrompt(): string {
  return `You are an expert coding assistant operating inside a sandboxed pi workspace. You help users by reading files, executing commands, editing code, and writing new files.

You are inside an isolated VM. Treat the current working directory as the workspace root and the only filesystem environment available to you. Do not infer, use, or mention host paths, host usernames, host home directories, server runtime paths, or host machine details. If an implementation detail exposes a host path, ignore it and continue using sandbox paths.

Guidelines:
- Use bash for file operations like ls, rg, find.
- Use read to examine files instead of cat or sed.
- Be concise in your responses.
- Show sandbox file paths clearly when working with files.`;
}

export function isOppiDocsPromptEnabled(
  config: Pick<ServerConfig, "oppiDocsPrompt"> | undefined,
): boolean {
  return config?.oppiDocsPrompt?.enabled !== false;
}

export function isOppiCliPromptEnabled(
  config: Pick<ServerConfig, "oppiCliPrompt"> | undefined,
): boolean {
  return config?.oppiCliPrompt?.enabled === true;
}

function buildSdkAppendSystemPrompt(
  workspace: Workspace | undefined,
  options: {
    includeOppiDocsHint: boolean;
    includeOppiCliHint: boolean;
    includeMobileOutputGuide: boolean;
  },
): string[] | undefined {
  const prompts: string[] = [];

  // Host-backed sessions can read the packaged docs path directly. Sandbox sessions
  // use a custom prompt that intentionally avoids exposing host/server paths.
  const oppiDocsHint = options.includeOppiDocsHint ? buildOppiSystemPromptAppend() : undefined;
  if (oppiDocsHint) {
    prompts.push(oppiDocsHint);
  }
  if (options.includeMobileOutputGuide) {
    prompts.push(buildMobileOutputGuide());
  }
  if (options.includeOppiCliHint) {
    prompts.push(OPPI_CLI_SYSTEM_PROMPT_HINT);
  }

  if (workspace?.systemPrompt) {
    prompts.push(workspace.systemPrompt);
  }

  return prompts.length > 0 ? prompts : undefined;
}

function normalizeAgentContextFiles(
  agentDefinition: AgentDefinition | undefined,
  sandboxGuestCwd?: string,
): AgentContextFile[] {
  return (agentDefinition?.resources?.agentsFiles ?? []).map((file) => ({
    path: sandboxGuestCwd ? posix.join(sandboxGuestCwd, file.path) : file.path,
    content: file.content,
  }));
}

export interface SdkBackendConfig {
  session: Session;
  workspace?: Workspace;
  /** Called for SDK agent events and extension callback events. */
  onEvent: (event: SessionBackendEvent) => void;
  /** Called when the session ends. */
  onEnd: (reason: string) => void;
  /** Resolved skill directory paths for this workspace. */
  skillPaths?: string[];
  /** Oppi server data directory for session-owned tool attachments. */
  dataDir?: string;
  /** Operational metrics collector for SDK timing. */
  metrics?: ServerMetricCollector;
  /** Saved Agent definition used to configure this runtime. */
  agentDefinition?: AgentDefinition;
  /** Server settings that affect Oppi-owned SDK sessions. */
  serverConfig?: Pick<ServerConfig, "oppiDocsPrompt" | "oppiCliPrompt">;
  /** Reads one atomic Mobile Output Guide snapshot for each managed runtime rebuild. */
  getMobileOutputGuideSettings?: () => MobileOutputGuideSettingsSnapshot;
  /** Startup-only relay, registered before protected project resources load. */
  onUIBridgeReady?: (bridge: SdkUiBridge | undefined) => void;
  hasUI?: () => boolean;
}

type MobileOutputGuideSettingsHolder = {
  snapshot: MobileOutputGuideSettingsSnapshot;
};

type QueuedModelTurnInput = {
  message: string;
  images?: Array<{ type: "image"; data: string; mimeType: string }>;
};

export type QueuedModelTurnBatch = {
  prompt?: QueuedModelTurnInput;
  steering: QueuedModelTurnInput[];
  followUp: QueuedModelTurnInput[];
};

export interface QueuedModelTurnsAuthority {
  readonly generation: number;
}

export class QueuedModelTurnsAuthorityError extends Error {
  constructor(readonly phase: "before_replay" | "during_replay" | "after_replay") {
    super(`Pi queue authority changed ${phase.replaceAll("_", " ")}`);
    this.name = "QueuedModelTurnsAuthorityError";
  }
}

/**
 * A queue replay was refused while Pi's queues still held exactly what did
 * queue. Carries the settled-state authority so the caller can re-check it in
 * the same JavaScript turn as the rollback's clearQueue().
 */
class QueuedModelTurnsReplayRejected {
  constructor(
    readonly reason: unknown,
    readonly authority: QueuedModelTurnsAuthority,
  ) {}
}

export const QUEUE_RECONCILIATION_REQUIRED_ERROR =
  "Queue reconciliation required: retry setQueue from the last acknowledged queue version";

export const SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS = 5_000;

type SdkRuntimeLifecycleOperation = "reload" | "stop";

type SdkBackendForcedDisposeResult = {
  disposal: "forced";
  /** Local cleanup failures retained even when Pi cleanup has a stronger primary cause. */
  diagnosticReason?: string;
} & (
  | {
      cause: "extension_shutdown_timeout";
      timeoutMs: number;
    }
  | {
      cause: "runtime_dispose_error";
    }
  | {
      cause: "lifecycle_timeout";
      operation: "reload" | "stop";
      timeoutMs: number;
    }
  | {
      cause: "local_cleanup_error";
    }
);

export type SdkBackendDisposeResult = { disposal: "graceful" } | SdkBackendForcedDisposeResult;

export class QueuedModelTurnsReconciliationError extends Error {
  constructor(
    readonly replacementError: unknown,
    readonly rollbackError: unknown,
  ) {
    super(
      `Queue reconciliation required: ${safeErrorMessage(replacementError)} and ${safeErrorMessage(rollbackError)}; retry setQueue from the last acknowledged queue version`,
    );
    this.name = "QueuedModelTurnsReconciliationError";
  }
}

/**
 * Allowed tool names from a saved Agent's sessionDefaults that no active
 * tool matches at launch. These names are stale: the running Pi session can
 * never activate them, so launches drop them from the effective tool set and
 * surface a session warning instead of failing the whole launch. The saved
 * Agent definition is never mutated.
 */
function findUnavailableConfiguredAgentTools(
  configuredAllowed: readonly string[] | undefined,
  configuredExcluded: readonly string[] | undefined,
  activeToolNames: readonly string[],
): string[] {
  if (!configuredAllowed) return [];
  const excluded = new Set(configuredExcluded ?? []);
  const active = new Set(activeToolNames);
  return [...new Set(configuredAllowed)].filter((name) => !excluded.has(name) && !active.has(name));
}

/**
 * VM-backed file tools a sandbox session may expose. Host grep/find are not
 * in this set; customTools overwrite those names with guest implementations.
 */
const SANDBOX_TOOL_NAMES = ["read", "bash", "edit", "write", "ls", "find", "grep"] as const;
const SANDBOX_TOOL_NAME_SET = new Set<string>(SANDBOX_TOOL_NAMES);

/**
 * Intersect a sandbox allowlist with the VM file-tool set.
 *
 * workspace.tools is the fallback when no Agent/launch allowlist is set and
 * stays intersected with SANDBOX_TOOL_NAMES. Agent/launch allowlists replace
 * that fallback and keep selected host-side extension tools. File builtins
 * stay guest-backed via customTools + noTools:builtin. Unknown/stale
 * Agent/launch names stay listed so Pi can
 * ignore them and the existing session warning can report them.
 */
function intersectSandboxToolAllowlist(
  allowed: readonly string[] | undefined,
  reserved: readonly string[] = [],
  options: { keepHostExtensionTools?: boolean } = {},
): { allowed?: string[]; dropped: string[] } {
  if (!allowed) return { dropped: [] };
  const reservedSet = new Set(reserved);
  const kept: string[] = [];
  const dropped: string[] = [];
  const keepHostExtensionTools = options.keepHostExtensionTools === true;
  for (const name of allowed) {
    if (SANDBOX_TOOL_NAME_SET.has(name) || reservedSet.has(name)) {
      if (!kept.includes(name)) kept.push(name);
      continue;
    }
    if (keepHostExtensionTools) {
      // Selected host-side extension tools must survive an Agent/launch
      // allowlist. Stale names stay listed so Pi can ignore them and the
      // existing session warning can report them.
      if (!kept.includes(name)) kept.push(name);
      continue;
    }
    if (!dropped.includes(name)) dropped.push(name);
  }
  return { allowed: kept, dropped };
}

function recordDroppedAgentToolsWarning(
  session: Session,
  configuredAllowed: readonly string[],
  missingTools: readonly string[],
): void {
  const eligibleCount = new Set(configuredAllowed).size;
  const noun = missingTools.length === 1 ? "tool is" : "tools are";
  const warning =
    missingTools.length >= eligibleCount
      ? `Every configured Agent tool is unavailable and was dropped from this session: ${missingTools.join(", ")}. The session started with only the remaining default/reserved tools and may not work as intended. Edit the Agent's Allowed Tools or selected Extensions, then start again.`
      : `Configured Agent ${noun} unavailable and was dropped from this session: ${missingTools.join(", ")}. The session continues with the remaining allowed tools. Edit the Agent's Allowed Tools or selected Extensions to stop this warning.`;
  session.warnings = [...new Set([...(session.warnings ?? []), warning])];
  log.warn("sdk.agent_tools_dropped", {
    sessionId: session.id,
    droppedTools: [...missingTools],
    allConfiguredToolsDropped: missingTools.length >= eligibleCount,
  });
}

const log = createLogger({ base: { component: "sdk_backend" } });

function syncSessionIdentityFromManager(session: Session, manager: PiSessionManager): void {
  const sessionFile = manager.getSessionFile();
  if (sessionFile) {
    session.piSessionFile = sessionFile;
    const knownFiles = new Set(session.piSessionFiles ?? []);
    knownFiles.add(sessionFile);
    session.piSessionFiles = [...knownFiles];
  }
}

/** Product fork: mint Session.id first, then create a distinct Pi JSONL with that id. */
export function forkPiSessionFrom(
  sourcePath: string,
  targetCwd: string,
  id: string,
): { sessionFile?: string; sessionId: string } {
  const manager = PiSessionManager.forkFrom(sourcePath, targetCwd, undefined, { id });
  const sessionId = manager.getSessionId();
  if (sessionId !== id) {
    throw new Error(`Forked Pi session id ${sessionId} does not match minted Session.id ${id}`);
  }
  return {
    sessionFile: manager.getSessionFile(),
    sessionId,
  };
}

/**
 * Wraps a pi AgentSession for use by SessionManager.
 *
 * Lifecycle:
 *   const backend = await SdkBackend.create(config);
 *   backend.prompt("hello");
 *   backend.abort();
 *   backend.dispose();
 */
export class SdkBackend implements AgentBackend {
  private static readonly DEFAULT_STEERING_MODE = "all" as const;
  private static readonly DEFAULT_FOLLOW_UP_MODE = "one-at-a-time" as const;
  /** Maximum graceful cleanup time within the documented stop bound. */
  static readonly RUNTIME_LIFECYCLE_TIMEOUT_MS = SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private static _gondolinManager: any;

  /** Shared VM owner for both managed backends; never create a parallel VM. */
  static async ensureSandboxWorkspaceVm(
    workspace: Workspace,
    hostCwd: string,
    readonlyMounts?: ReadonlyMountSpec[],
  ): Promise<GondolinVm> {
    if (readonlyMounts === undefined) {
      // Discover exactly the normal sandbox Skills, but never execute classic
      // extensions just to attach a durable environment to the shared VM.
      const mounts = new Map<string, ReadonlyMount>();
      const agentDir = getAgentDir();
      const loader = new DefaultResourceLoader({
        cwd: hostCwd,
        agentDir,
        settingsManager: SettingsManager.create(hostCwd, agentDir, { projectTrusted: true }),
        noExtensions: true,
        noPromptTemplates: true,
        noThemes: true,
        noContextFiles: true,
        systemPrompt: "",
        appendSystemPrompt: [],
        skillsOverride: (base) => ({
          ...base,
          skills: sandboxGuestSkills(base.skills, resolveSandboxGuestCwd(workspace), mounts),
        }),
      });
      await loader.reload();
      readonlyMounts = [...mounts.values()];
    }
    const { GondolinManager, isQemuAvailable } = await import("./gondolin-manager.js");
    if (!(await isQemuAvailable())) throw new Error("Sandbox mode requires QEMU on the server");
    SdkBackend._gondolinManager ??= new GondolinManager();
    return SdkBackend._gondolinManager.ensureWorkspaceVm(
      workspace,
      hostCwd,
      {},
      readonlyMounts,
      workspace.sandboxConfig?.env,
      resolveSandboxGuestCwd(workspace),
    );
  }

  /** Stop one workspace VM. No-op when sandbox mode has never booted. */
  static async stopWorkspaceVm(workspaceId: string): Promise<void> {
    await SdkBackend._gondolinManager?.stopWorkspaceVm?.(workspaceId);
  }

  /** Stop every workspace VM. Wired from server shutdown. */
  static async stopAllWorkspaceVms(): Promise<void> {
    await SdkBackend._gondolinManager?.stopAll?.();
  }

  /** Cancel idle VM teardown while this sandbox session is busy. */
  static noteWorkspaceBusy(workspaceId: string, sessionId: string): void {
    SdkBackend._gondolinManager?.noteWorkspaceBusy?.(workspaceId, sessionId);
  }

  /** Start idle VM teardown when this sandbox session is ready/stopped/error. */
  static noteWorkspaceIdle(workspaceId: string, sessionId: string): void {
    SdkBackend._gondolinManager?.noteWorkspaceIdle?.(workspaceId, sessionId);
  }

  private runtime: AgentSessionRuntime;
  private unsub: (() => void) | null = null;
  private readonly emitEvent: (event: SessionBackendEvent) => void;
  private readonly uiBridge: SdkUiBridge;
  private shutdownCleanupPromise: Promise<SdkBackendDisposeResult> | null = null;
  private forcedDisposalResult: SdkBackendDisposeResult | undefined;
  private readonly sessionManagerDisplayCwd?: string;
  private readonly oppiSessionId: string;
  private readonly dataDir?: string;
  private readonly mobileOutputGuideSettingsHolder?: MobileOutputGuideSettingsHolder;
  private readonly getMobileOutputGuideSettings?: () => MobileOutputGuideSettingsSnapshot;
  private readonly assertSelectedResourcesAvailableBeforeReload?: () => void;
  private readonly consumeSelectedResourceReloadError?: () => Error | undefined;
  private entryRendererGeneration = 0;
  private selectedResourceInvariantError?: string;
  private runtimeTransaction = new SessionRuntimeTransaction();
  private requestedExclusiveOperations: Array<{ name: string }> = [];
  private queueReconciliationRequired = false;
  private queueAuthorityGeneration = 0;
  private disposed = false;
  private localCleanupFailures: string[] = [];

  private constructor(
    runtime: AgentSessionRuntime,
    emitEvent: (event: SessionBackendEvent) => void,
    oppiSessionId: string,
    dataDir?: string,
    cwdOverrides?: { displayCwd?: string },
    mobileOutputGuideRuntimeSettings?: {
      holder: MobileOutputGuideSettingsHolder;
      get: () => MobileOutputGuideSettingsSnapshot;
    },
    assertSelectedResourcesAvailableBeforeReload?: () => void,
    consumeSelectedResourceReloadError?: () => Error | undefined,
    uiBridge?: SdkUiBridge,
  ) {
    this.runtime = runtime;
    this.emitEvent = emitEvent;
    this.oppiSessionId = oppiSessionId;
    this.dataDir = dataDir;
    this.mobileOutputGuideSettingsHolder = mobileOutputGuideRuntimeSettings?.holder;
    this.getMobileOutputGuideSettings = mobileOutputGuideRuntimeSettings?.get;
    this.assertSelectedResourcesAvailableBeforeReload =
      assertSelectedResourcesAvailableBeforeReload;
    this.consumeSelectedResourceReloadError = consumeSelectedResourceReloadError;
    this.sessionManagerDisplayCwd = cwdOverrides?.displayCwd;
    this.uiBridge = uiBridge ?? new SdkUiBridge(emitEvent, () => this.disposed);
    this.restoreSessionManagerDisplayCwd();
    this.subscribeToCurrentSession();
  }

  private get piSession(): AgentSession {
    return this.runtime.session;
  }

  private get modelRegistry(): ModelRegistry {
    return new ModelRegistry(this.runtime.services.modelRuntime);
  }

  private restoreSessionManagerDisplayCwd(): void {
    if (!this.sessionManagerDisplayCwd) {
      return;
    }

    // Pi's cwd-existence guard runs in the host process, so sandbox session
    // switches need a host cwd override. Keep the live session manager aligned
    // with the sandbox-visible cwd after that guard has passed, so host paths do
    // not leak through extension/session-manager APIs.
    (this.piSession.sessionManager as unknown as { cwd?: string }).cwd =
      this.sessionManagerDisplayCwd;
  }

  private static createPiSessionManager(
    session: Session,
    cwd: string,
    cwdExistsOverride: string = cwd,
  ): PiSessionManager {
    const piSessionFile = session.piSessionFile;
    if (session.ephemeral) {
      return PiSessionManager.inMemory(cwd, { id: session.id });
    }
    if (piSessionFile) {
      return PiSessionManager.open(piSessionFile, undefined, cwdExistsOverride);
    }

    const manager = PiSessionManager.create(cwd, undefined, { id: session.id });
    const sessionFile = manager.getSessionFile();
    if (cwdExistsOverride === cwd || !sessionFile) {
      return manager;
    }

    const header = manager.getHeader();
    if (header) {
      writeFileSync(sessionFile, `${JSON.stringify(header)}\n`);
    }
    return PiSessionManager.open(sessionFile, undefined, cwdExistsOverride);
  }

  static async create(config: SdkBackendConfig): Promise<SdkBackend> {
    const createStartMs = Date.now();
    const { session, workspace, onEvent, onEnd: _onEnd } = config;
    const initialHostCwd = resolveSdkSessionCwd(workspace, session, { dataDir: config.dataDir });
    const displayCwd = resolveSdkSessionDisplayCwd(workspace, session, { dataDir: config.dataDir });
    const sandboxMode = workspace?.runtime === "sandbox";
    // Sandboxes persist a guest/display cwd in Pi session state and need a real
    // host path only for Pi's existence check. Control sessions are not a guest
    // filesystem: "Pi Control" is display metadata only. Persisting that label
    // as SessionManager cwd materializes JSONLs under process.cwd()/Pi Control
    // and leaks them into workspace importable-local discovery.
    const piSessionCwd = sandboxMode ? displayCwd : initialHostCwd;
    const cwdExistsOverride = sandboxMode ? initialHostCwd : piSessionCwd;
    const hostMountError = hostMountValidationError(workspace?.hostMount);
    if (hostMountError) {
      throw new Error(hostMountError);
    }
    const agentDir = getAgentDir();
    const initialSessionManager = SdkBackend.createPiSessionManager(
      session,
      piSessionCwd,
      cwdExistsOverride,
    );
    syncSessionIdentityFromManager(session, initialSessionManager);

    const agentDefinition = config.agentDefinition;
    const managedSession = (session.runtime ?? "oppi") !== "pi-tui";
    const getMobileOutputGuideSettings =
      config.getMobileOutputGuideSettings ?? (() => DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS);
    const mobileOutputGuideSettingsHolder: MobileOutputGuideSettingsHolder = {
      snapshot: DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS,
    };
    let bridgeDisposed = false;
    const backendRef: { current?: SdkBackend } = {};
    const uiBridge = new SdkUiBridge(
      onEvent,
      () => bridgeDisposed || backendRef.current?.disposed === true,
    );
    config.onUIBridgeReady?.(uiBridge);
    const trustUI = uiBridge.createContext();
    let assertSelectedResourcesAvailableBeforeReload: (() => void) | undefined;
    let consumeSelectedResourceReloadError: (() => Error | undefined) | undefined;
    const createRuntimeFactory: CreateAgentSessionRuntimeFactory = async ({
      cwd,
      agentDir: runtimeAgentDir,
      sessionManager,
      sessionStartEvent,
    }) => {
      if (managedSession) {
        mobileOutputGuideSettingsHolder.snapshot = freezeMobileOutputGuideSettingsSnapshot(
          getMobileOutputGuideSettings(),
        );
      }
      const hostCwd = sandboxMode ? initialHostCwd : cwd;
      const guestCwd = sandboxMode && workspace ? resolveSandboxGuestCwd(workspace) : cwd;
      const sessionCwd = sandboxMode ? guestCwd : cwd;
      const sandboxReadonlyMounts = new Map<string, ReadonlyMount>();
      const savedAgentFiles = normalizeAgentContextFiles(
        agentDefinition,
        sandboxMode ? sessionCwd : undefined,
      );
      const selectedAgentSkillPaths = agentDefinition?.resources?.skillPaths;
      const selectedAgentExtensionIds = agentDefinition?.resources?.extensionIds;
      const modelRuntime = await ModelRuntime.create({
        authPath: join(runtimeAgentDir, "auth.json"),
        modelsPath: join(runtimeAgentDir, "models.json"),
      });
      const trustManagedProject = managedSession && !sandboxMode;
      const settingsManager = SettingsManager.create(hostCwd, runtimeAgentDir, {
        projectTrusted: !trustManagedProject,
      });
      let sessionTrust: boolean | undefined;
      // Handlers see only Pi's declared `select`/`confirm`/`input`/`notify`,
      // each bounded so an unanswered phone cannot hold startup (and the
      // workspace lock) forever. Timeouts <= 0 mean "no timeout" upstream.
      const boundTrustDialog = <T extends { timeout?: number }>(opts: T | undefined): T =>
        ({
          ...opts,
          timeout: Math.min(
            opts?.timeout && opts.timeout > 0 ? opts.timeout : PROJECT_TRUST_TIMEOUT_MS,
            PROJECT_TRUST_TIMEOUT_MS,
          ),
        }) as T;
      const resolveTrust = async (): Promise<void> => {
        if (!trustManagedProject) return;
        // Nothing to gate is not a decision: do not cache it. Protected files
        // added mid-session (an agent can write `.pi/mcp.json`) must reach a real
        // trust decision on the next /reload, as in Pi's own per-call check.
        if (!hasTrustRequiringProjectResources(hostCwd)) {
          settingsManager.setProjectTrusted(true);
          await settingsManager.reload();
          return;
        }
        const hasUI = config.hasUI?.() ?? false;
        // Remember a session-only/default-allow decision across /reload. A runtime
        // replacement gets a new cwd-bound decision through this factory.
        sessionTrust ??= await resolveManagedProjectTrust(
          hostCwd,
          runtimeAgentDir,
          settingsManager,
          {
            cwd: hostCwd,
            mode: "rpc",
            hasUI,
            ui: hasUI
              ? {
                  select: (title, choices, opts) =>
                    trustUI.select(title, choices, boundTrustDialog(opts)),
                  confirm: (title, message, opts) =>
                    trustUI.confirm(title, message, boundTrustDialog(opts)),
                  input: (title, placeholder, opts) =>
                    trustUI.input(title, placeholder, boundTrustDialog(opts)),
                  notify: trustUI.notify,
                }
              : // Like Pi's CLI context: no phone attached, so dialogs resolve
                // immediately instead of holding startup for the 15 s bound.
                {
                  select: async () => undefined,
                  confirm: async () => false,
                  input: async () => undefined,
                  notify: trustUI.notify,
                },
          },
          (extensionPath, error) =>
            onEvent({
              type: "extension_error",
              extensionPath,
              event: "project_trust",
              error: safeErrorMessage(error),
            }),
          selectedAgentExtensionIds,
        );
        settingsManager.setProjectTrusted(sessionTrust);
        await settingsManager.reload();
      };
      await resolveTrust();
      // Pi MCP/codemode/tool-search: on for managed sessions; sandboxes get no codemode.
      const mcpBuiltinNames = availableMcpBuiltinNames({
        managed: managedSession,
        sandbox: sandboxMode,
      });
      const selectedAgentExtensionPaths = await resolveSelectedAgentExtensionPaths(
        selectedAgentExtensionIds,
        hostCwd,
        runtimeAgentDir,
        settingsManager,
        mcpBuiltinNames,
      );
      // A sandbox gets only the global servers its owner picked, with stdio servers
      // run inside the VM. Servers connect at session_start, after the VM exists below.
      let sandboxVm: GondolinVm | undefined;
      const sandboxMcpPicks = sandboxMode ? (workspace?.sandboxConfig?.mcpServers ?? []) : [];
      // Each sandbox's own log, away from `~/.pi/agent/mcp.log` that host agents read.
      const sandboxMcpLog = join(
        config.dataDir ?? join(runtimeAgentDir, "oppi"),
        "sandbox-mcp-logs",
        `${workspace?.id ?? "sandbox"}.log`,
      );
      const sandboxMcp = !sandboxMode
        ? undefined
        : sandboxMcpPicks.length === 0
          ? emptySandboxMcp(sandboxMcpLog)
          : createSandboxMcpOptions({
              internals: await loadPiMcpInternals(),
              agentDir: runtimeAgentDir,
              logPath: sandboxMcpLog,
              selected: sandboxMcpPicks,
              allowedHosts: workspace?.sandboxConfig?.allowedHosts,
              guestCwd,
              // This session's own VM. Re-ensuring could stop a newer session's VM whose
              // settings differ, and bring back this session's older Allowed Hosts.
              vm: async () => {
                if (!sandboxVm) throw new Error("The sandbox VM is not ready");
                return sandboxVm;
              },
            });

      // Resource loader: follow Pi's normal cwd/settings/package discovery.
      // Oppi no longer applies a workspace-level skills/extensions policy for
      // host sessions. Project/user Pi settings remain the source of truth.
      //
      // The resource loader is reused by AgentSession.reload(). Build the
      // append list through a callback so the guide follows the frozen live
      // server setting on every reload, rather than the snapshot that
      // happened to exist when this loader was constructed.
      const staticAppendSystemPrompt = buildSdkAppendSystemPrompt(workspace, {
        includeOppiDocsHint:
          !sandboxMode && managedSession && isOppiDocsPromptEnabled(config.serverConfig),
        includeOppiCliHint:
          !sandboxMode && managedSession && isOppiCliPromptEnabled(config.serverConfig),
        includeMobileOutputGuide: false,
      });
      const buildCurrentAppendSystemPrompt = (base: string[]): string[] => {
        // A saved-Agent replacement remains authoritative over this optional
        // capability guide. Preserve the append resources Pi/Oppi already
        // supplied before this feature, but never add the guide after replace.
        if (agentDefinition?.instructions?.mode === "replace") {
          return staticAppendSystemPrompt ? [...staticAppendSystemPrompt] : [...base];
        }

        // Preserve Pi's discovered APPEND_SYSTEM.md, then add Oppi-owned
        // append capabilities. A global SYSTEM.md replacement remains the base
        // system prompt and does not suppress these append-only additions.
        const prompts = [...base, ...(staticAppendSystemPrompt ?? [])];
        if (managedSession && mobileOutputGuideSettingsHolder.snapshot.enabled) {
          prompts.push(buildMobileOutputGuide());
        }
        if (agentDefinition?.instructions?.mode === "append") {
          prompts.push(agentDefinition.instructions.text);
        }
        return prompts;
      };
      const normalizedSelectedAgentSkillPaths = selectedAgentSkillPaths?.map((path) =>
        isAbsolute(path) ? path : resolvePath(hostCwd, path),
      );
      if (trustManagedProject && !settingsManager.isProjectTrusted()) {
        // Explicit Skill paths are CLI resources to Pi. They must not bypass
        // the host session's denial of protected project directories.
        // Compare real paths so a symlinked cwd (or a skill path given through
        // the real location) cannot slip past the protected-directory check.
        const canonicalCwd = canonicalPath(hostCwd);
        const canonicalHome = canonicalPath(homedir());
        // `.pi` itself may be a symlink; canonicalize it like the .agents/skills walk.
        const canonicalProjectPi = canonicalPath(join(canonicalCwd, ".pi"));
        const unavailableSkills = (normalizedSelectedAgentSkillPaths ?? []).filter((original) => {
          const path = canonicalPath(original);
          if (isPathWithin(canonicalProjectPi, path)) return true;
          for (let parent = canonicalCwd; ; parent = resolvePath(parent, "..")) {
            if (
              parent !== canonicalHome &&
              isPathWithin(canonicalPath(join(parent, ".agents", "skills")), path)
            )
              return true;
            if (parent === resolvePath(parent, "..")) return false;
          }
        });
        if (unavailableSkills.length > 0)
          throw new AgentConfigurationError(
            "agent_skills_unavailable",
            { unavailableSkills },
            `Selected Agent Skill is unavailable in an untrusted project: ${unavailableSkills.join(", ")}`,
          );
      }
      assertSelectedResourcesAvailableBeforeReload = () =>
        assertSelectedAgentResourcesAvailable(
          normalizedSelectedAgentSkillPaths,
          selectedAgentExtensionPaths,
        );
      // Resource selection is a startup and reload-preflight invariant. The
      // SdkBackend preflight rejects known missing paths before Pi shutdown.
      // During a live Pi reload, validation runs after Pi has emitted
      // session_shutdown. Let Pi finish rebuilding a coherent runtime, then
      // reject the reload and block model turns until an exact selection is
      // restored and a later reload satisfies the invariant.
      let isInitialResourceLoad = true;
      let selectedResourceReloadError: Error | undefined;
      const recordSelectedResourceReloadError = (error: unknown): void => {
        selectedResourceReloadError ??=
          error instanceof Error ? error : new Error(safeErrorMessage(error));
      };
      consumeSelectedResourceReloadError = () => {
        const error = selectedResourceReloadError;
        selectedResourceReloadError = undefined;
        return error;
      };
      const loader = new DefaultResourceLoader({
        cwd: hostCwd,
        agentDir: runtimeAgentDir,
        settingsManager,
        appendSystemPromptOverride: (base) => buildCurrentAppendSystemPrompt(base),
        extensionFactories: [
          createLifecycleJournalExtension(sessionManager),
          ...createMcpBuiltinExtensions(mcpBuiltinNames, sandboxMcp),
        ],
        ...(selectedAgentSkillPaths !== undefined
          ? { noSkills: true, additionalSkillPaths: selectedAgentSkillPaths }
          : config.skillPaths
            ? { additionalSkillPaths: config.skillPaths }
            : {}),
        ...(selectedAgentExtensionPaths !== undefined
          ? {
              noExtensions: true,
              additionalExtensionPaths: selectedAgentExtensionPaths,
            }
          : {}),
        ...(agentDefinition?.resources?.noContextFiles ? { noContextFiles: true } : {}),
        ...(agentDefinition?.instructions?.mode === "replace"
          ? { systemPromptOverride: () => agentDefinition.instructions?.text }
          : {}),
        ...(sandboxMode
          ? {
              systemPrompt: sandboxSystemPrompt(),
              agentsFilesOverride: (base: { agentsFiles: AgentContextFile[] }) => ({
                agentsFiles: [
                  ...base.agentsFiles.flatMap((file) => {
                    const guestPath = hostWorkspacePathToGuest(hostCwd, guestCwd, file.path);
                    if (!guestPath) return [];
                    return [
                      {
                        path: guestPath,
                        content: redactHostEnvironment(file.content, hostCwd, guestCwd),
                      },
                    ];
                  }),
                  ...savedAgentFiles,
                ],
              }),
              skillsOverride: (base: SkillLoadResult): SkillLoadResult => {
                // The sandbox loader rewrites resource paths to guest paths
                // below. Validate the saved Agent selection against the host
                // paths before that presentation-only rewrite on every load.
                try {
                  assertSelectedAgentSkillsLoaded(normalizedSelectedAgentSkillPaths, base);
                } catch (error) {
                  if (isInitialResourceLoad) throw error;
                  recordSelectedResourceReloadError(error);
                }
                return {
                  skills: sandboxGuestSkills(base.skills, guestCwd, sandboxReadonlyMounts),
                  diagnostics: base.diagnostics,
                };
              },
            }
          : {
              agentsFilesOverride: (base: { agentsFiles: AgentContextFile[] }) => ({
                agentsFiles: [...base.agentsFiles, ...savedAgentFiles],
              }),
            }),
      });
      const reload = loader.reload.bind(loader);
      loader.reload = async (options) => {
        selectedResourceReloadError = undefined;
        await resolveTrust();
        await reload(options);
        try {
          if (!sandboxMode) {
            assertSelectedAgentSkillsLoaded(normalizedSelectedAgentSkillPaths, loader.getSkills());
          }
          assertSelectedAgentExtensionsLoaded(selectedAgentExtensionPaths, loader.getExtensions());
        } catch (error) {
          if (isInitialResourceLoad) throw error;
          recordSelectedResourceReloadError(error);
        }
        if (selectedResourceReloadError) {
          log.warn("sdk.selected_agent_resource_reload_failed", {
            sessionId: session.id,
            error: safeErrorMessage(selectedResourceReloadError),
          });
        }
        isInitialResourceLoad = false;
        if (!sandboxMode) {
          const configuredShellCommandPrefix = settingsManager.getShellCommandPrefix();
          settingsManager.applyOverrides({
            shellCommandPrefix: [
              callerSessionIdentityShellPrefix(session.id),
              configuredShellCommandPrefix,
            ]
              .filter((prefix): prefix is string => Boolean(prefix))
              .join("\n"),
          });
        }
      };
      await loader.reload();

      // Apply providers that extensions registered during reload() before
      // resolving the seeded model, so custom provider models (e.g. kiro/
      // antigravity) resolve at session start instead of silently defaulting.
      // Mirrors pi's createAgentSessionServices; clearing the pending queue here
      // means the runner bind inside createAgentSession does not re-apply them.
      const providerRegistrations = applyPendingProviderRegistrations(
        modelRuntime,
        loader.getExtensions(),
      );
      for (const diagnostic of providerRegistrations.diagnostics) {
        log.warn("sdk.extension_provider_registration_failed", {
          sessionId: session.id,
          extensionPath: diagnostic.extensionPath,
          error: diagnostic.message,
        });
      }
      await modelRuntime.refresh({ allowNetwork: false });

      const modelRegistry = new ModelRegistry(modelRuntime);
      const shouldSeedFromSessionState = !sessionStartEvent;
      const model =
        shouldSeedFromSessionState && session.model
          ? resolveSessionSeedModel(
              modelRegistry,
              session.model,
              settingsManager.getEnabledModels(),
            )
          : undefined;
      if (shouldSeedFromSessionState && session.model) {
        if (session.launch?.modelPolicy === "required") {
          try {
            enforceLaunchModelPolicy(session, model);
          } catch (error) {
            log.error("sdk.model_resolve_required_failed", {
              sessionId: session.id,
              model: session.model,
              launchSource: session.launch.source,
              resolvedModel: model ? `${model.provider}/${model.id}` : undefined,
            });
            throw error;
          }
        }
        if (!model) {
          log.warn("sdk.model_resolve_defaulted", {
            model: session.model,
          });
        }
      }

      // Sandbox mode: create tools backed by Gondolin micro-VM
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let sandboxTools: any[] | undefined;
      if (workspace?.runtime === "sandbox") {
        // Pre-flight: check QEMU availability before attempting VM creation.
        const { isQemuAvailable, GondolinManager, shouldShadowSandboxWorkspacePath } =
          await import("./gondolin-manager.js");
        if (!(await isQemuAvailable())) {
          throw new Error(
            "Sandbox mode requires QEMU but it is not installed on the server. " +
              "Install with: brew install qemu (macOS) or apt install qemu-system (Linux)",
          );
        }

        const {
          createGondolinBashOps,
          createGondolinReadOps,
          createGondolinWriteOps,
          createGondolinEditOps,
          createGondolinFindOps,
          createSandboxLsOps,
          createSandboxGrepToolDefinition,
        } = await import("./gondolin-ops.js");

        // Lazy singleton — shared across all sessions for VM reuse.
        if (!SdkBackend._gondolinManager) {
          SdkBackend._gondolinManager = new GondolinManager();
        }
        const manager = SdkBackend._gondolinManager;

        // Do not inject Oppi/pi provider credentials into the guest by default.
        // The host process owns model calls; sandbox commands must opt into any
        // future secret bridge explicitly instead of inheriting LLM API keys.
        const secrets: Record<string, VmSecretDefinition> = {};

        // Mount only the read-only resources whose paths were rewritten into
        // sandbox-visible locations. Do NOT mount agentDir itself — it contains
        // auth.json and host-specific configuration.
        const readonlyMounts = [...sandboxReadonlyMounts.values()];

        const extraEnv = workspace.sandboxConfig?.env;
        const vm = await manager.ensureWorkspaceVm(
          workspace,
          hostCwd,
          secrets,
          readonlyMounts,
          extraEnv,
          guestCwd,
        );
        sandboxVm = vm;

        // Authoritative sandbox set. Custom grep/find overwrite host builtins
        // in Pi's registry; do not call createGrepToolDefinition (host rg).
        sandboxTools = [
          createReadToolDefinition(sessionCwd, {
            operations: createGondolinReadOps(vm, sessionCwd, guestCwd),
          }),
          createBashToolDefinition(sessionCwd, {
            operations: createGondolinBashOps(vm, sessionCwd, guestCwd),
          }),
          createEditToolDefinition(sessionCwd, {
            operations: createGondolinEditOps(vm, sessionCwd, guestCwd),
          }),
          createWriteToolDefinition(sessionCwd, {
            operations: createGondolinWriteOps(vm, sessionCwd, guestCwd),
          }),
          createLsToolDefinition(sessionCwd, {
            operations: createSandboxLsOps(vm, sessionCwd, guestCwd, {
              shouldShadow: (posixPath) =>
                shouldShadowSandboxWorkspacePath({ op: "readdir", path: posixPath }),
            }),
          }),
          createFindToolDefinition(sessionCwd, {
            operations: createGondolinFindOps(vm, sessionCwd, guestCwd),
          }),
          createSandboxGrepToolDefinition(vm, sessionCwd, guestCwd),
        ];
        log.info("sdk.sandbox_vm_ready", { workspaceId: workspace.id || "unknown" });
      }

      const workspaceTools = sandboxTools && workspace?.tools?.length ? workspace.tools : undefined;
      const agentDefaultToolPolicy = agentDefinition?.sessionDefaults
        ? {
            allowed: agentDefinition.sessionDefaults.tools,
            excluded: agentDefinition.sessionDefaults.excludeTools,
            noTools: agentDefinition.sessionDefaults.noTools,
          }
        : undefined;
      const launchToolPolicy = session.launch?.tools ?? agentDefaultToolPolicy;
      const configuredToolPolicy = {
        allowed: launchToolPolicy?.allowed ?? workspaceTools,
        excluded: launchToolPolicy?.excluded,
        noTools: launchToolPolicy?.noTools ?? (sandboxTools ? ("builtin" as const) : undefined),
      };
      const sandboxAllowlist = sandboxTools
        ? intersectSandboxToolAllowlist(configuredToolPolicy.allowed, [], {
            keepHostExtensionTools: Boolean(launchToolPolicy?.allowed),
          })
        : { allowed: configuredToolPolicy.allowed, dropped: [] };
      // Pi admits extension tools by exact name, and MCP tool names are known only after
      // connecting, so a workspace Tools list leaves picked MCP servers unreachable.
      if (sandboxMcpPicks.length > 0 && !launchToolPolicy?.allowed && workspaceTools) {
        const warning =
          "This sandbox's Tools list hides its MCP servers. Clear the workspace Tools list to use them.";
        session.warnings = [...new Set([...(session.warnings ?? []), warning])];
      }
      const effectiveToolPolicy = {
        ...configuredToolPolicy,
        ...(sandboxAllowlist.allowed ? { allowed: sandboxAllowlist.allowed } : {}),
      };
      const scoped = await resolveEnabledScopedModels(
        settingsManager.getEnabledModels(),
        (patterns) => resolveModelScopeWithDiagnostics(patterns, modelRuntime),
      );
      for (const diagnostic of scoped.diagnostics) {
        log.warn("sdk.scoped_models.diagnostic", {
          sessionId: session.id,
          code: diagnostic.code,
          pattern: diagnostic.pattern,
          message: diagnostic.message,
        });
      }
      const existingMessages = sessionManager.buildSessionContext().messages.length > 0;
      const isResume =
        existingMessages ||
        (session.messageCount ?? 0) > 0 ||
        sessionStartEvent?.reason === "resume" ||
        sessionStartEvent?.reason === "fork" ||
        sessionStartEvent?.reason === "reload";
      const explicitThinkingLevel =
        normalizeThinkingLevel(session.thinkingLevel) ??
        normalizeThinkingLevel(session.launch?.thinkingLevel);
      const scopedPins = resolveInitialScopedSessionPins({
        scopedModels: scoped.scopedModels,
        resolvedModel: model,
        sessionModel: session.model,
        explicitThinkingLevel,
        requiredLaunchModel: session.launch?.modelPolicy === "required",
        isResume,
        defaultProvider: settingsManager.getDefaultProvider(),
        defaultModel: settingsManager.getDefaultModel(),
      });
      if (!session.thinkingLevel && scopedPins.thinkingLevel) {
        session.thinkingLevel = scopedPins.thinkingLevel;
      }
      if (!session.model && scopedPins.model) {
        session.model = `${scopedPins.model.provider}/${scopedPins.model.id}`;
      }
      const createResult = await createAgentSession({
        cwd: sessionCwd,
        agentDir: runtimeAgentDir,
        modelRuntime,
        model: scopedPins.model ?? model,
        thinkingLevel: scopedPins.thinkingLevel,
        sessionManager,
        settingsManager,
        resourceLoader: loader,
        sessionStartEvent,
        ...(scoped.scopedModels ? { scopedModels: scoped.scopedModels } : {}),
        ...(sandboxTools ? { customTools: sandboxTools } : {}),
        ...(effectiveToolPolicy.noTools ? { noTools: effectiveToolPolicy.noTools } : {}),
        ...(effectiveToolPolicy.allowed ? { tools: effectiveToolPolicy.allowed } : {}),
        ...(effectiveToolPolicy.excluded ? { excludeTools: effectiveToolPolicy.excluded } : {}),
      });

      if (agentDefinition && launchToolPolicy?.allowed) {
        const activeToolNames = createResult.session.agent.state.tools.map((tool) => tool.name);
        const missingTools = findUnavailableConfiguredAgentTools(
          launchToolPolicy.allowed,
          launchToolPolicy.excluded,
          activeToolNames,
        );
        if (missingTools.length > 0) {
          // Warn and start: stale allowlist names never enter the running
          // session's effective tool set because Pi filters the allowlist
          // against registered tools, so the active set above already
          // excludes them. Only Extensions and Skills stay fail-closed.
          recordDroppedAgentToolsWarning(session, launchToolPolicy.allowed, missingTools);
        }
      }

      SdkBackend.applyDefaultQueueModes(createResult.session);

      return {
        ...createResult,
        services: {
          cwd: sessionCwd,
          agentDir: runtimeAgentDir,
          modelRuntime,
          settingsManager,
          resourceLoader: loader,
          diagnostics: [],
        },
        diagnostics: [],
      };
    };

    let runtime: AgentSessionRuntime;
    try {
      runtime = await createAgentSessionRuntime(createRuntimeFactory, {
        cwd: initialHostCwd,
        agentDir,
        sessionManager: initialSessionManager,
      });
    } catch (error) {
      bridgeDisposed = true;
      uiBridge.dispose();
      config.onUIBridgeReady?.(undefined);
      throw error;
    }

    const backend = new SdkBackend(
      runtime,
      onEvent,
      session.id,
      config.dataDir,
      sandboxMode ? { displayCwd } : undefined,
      managedSession
        ? {
            holder: mobileOutputGuideSettingsHolder,
            get: getMobileOutputGuideSettings,
          }
        : undefined,
      () => assertSelectedResourcesAvailableBeforeReload?.(),
      () => consumeSelectedResourceReloadError?.(),
      uiBridge,
    );

    backendRef.current = backend;
    const preBindMs = Date.now() - createStartMs;
    config.metrics?.record("server.session_create_sdk_ms", preBindMs);

    try {
      await backend.bindCurrentSessionExtensions();
    } catch (error) {
      await backend.dispose();
      throw error;
    } finally {
      config.onUIBridgeReady?.(undefined);
    }

    const totalMs = Date.now() - createStartMs;
    const bindMs = totalMs - preBindMs;
    config.metrics?.record("server.session_create_bind_ms", bindMs);

    log.info("sdk.session.created", {
      model: backend.piSession.model?.id ?? backend.piSession.model?.name,
      thinking: backend.piSession.thinkingLevel,
      setupMs: preBindMs,
      bindExtensionMs: bindMs,
      totalMs,
    });

    return backend;
  }

  get session(): AgentSession {
    return this.piSession;
  }

  abortBash(): void {
    this.piSession.abortBash();
  }

  queuedMessages(): ReturnType<AgentBackend["queuedMessages"]> {
    return {
      steering: this.piSession.getSteeringMessages(),
      followUp: this.piSession.getFollowUpMessages(),
    };
  }

  leafId(): string | null {
    return this.piSession.sessionManager.getLeafId();
  }

  sessionTree(): ReturnType<AgentBackend["sessionTree"]> {
    return this.piSession.sessionManager;
  }

  toolDefinition(name: string): ToolDefinition | undefined {
    return this.piSession.getToolDefinition(name);
  }

  messages(): ReturnType<AgentBackend["messages"]> {
    return this.piSession.messages;
  }

  forkMessages(): ReturnType<AgentBackend["forkMessages"]> {
    return this.piSession.getUserMessagesForForking();
  }

  cycleModel(direction?: "forward" | "backward"): ReturnType<AgentBackend["cycleModel"]> {
    return this.piSession.cycleModel(direction);
  }

  setThinkingLevel(level: ThinkingLevel, options?: { persist?: boolean }): void {
    if (options?.persist === true) this.piSession.setThinkingLevel(level, { persist: true });
    else this.piSession.setThinkingLevel(level);
  }

  cycleThinkingLevel(): ThinkingLevel | undefined {
    return this.piSession.cycleThinkingLevel();
  }

  setSessionName(name: string): void {
    this.piSession.setSessionName(name);
  }

  navigateTree(
    targetId: string,
    options?: Parameters<AgentBackend["navigateTree"]>[1],
  ): ReturnType<AgentBackend["navigateTree"]> {
    return this.piSession.navigateTree(targetId, options);
  }

  commands(): ReturnType<AgentBackend["commands"]> {
    return collectSessionCommands(this.piSession);
  }

  getSessionStats(): ReturnType<AgentBackend["getSessionStats"]> {
    const session = this.piSession;
    const entries = session.sessionManager.getEntries();
    return {
      ...session.getSessionStats(),
      cacheWaste: computeCacheWaste(entries, this.cacheMissModelPriceSource),
      modelBreakdown: collectModelUsage(entries),
      contextComposition: collectSessionContextComposition(session),
      loadedResources: collectLoadedSessionResources(session),
    };
  }

  exportToHtml(outputPath: string): Promise<string> {
    return this.piSession.exportToHtml(outputPath);
  }

  compact(customInstructions?: string): ReturnType<AgentBackend["compact"]> {
    return this.piSession.compact(customInstructions);
  }

  setAutoCompactionEnabled(enabled: boolean): void {
    this.piSession.setAutoCompactionEnabled(enabled);
  }

  setSteeringMode(mode: "all" | "one-at-a-time"): void {
    this.piSession.setSteeringMode(mode);
  }

  setFollowUpMode(mode: "all" | "one-at-a-time"): void {
    this.piSession.setFollowUpMode(mode);
  }

  setAutoRetryEnabled(enabled: boolean): void {
    this.piSession.setAutoRetryEnabled(enabled);
  }

  abortRetry(): void {
    this.piSession.abortRetry();
  }

  appendAssistantMessage(content: string, fallbackModel?: string): void {
    const runtimeModel = this.piSession.model;
    this.piSession.sessionManager.appendMessage({
      role: "assistant",
      content: [{ type: "text", text: content }],
      api: runtimeModel?.api ?? "openai-completions",
      provider: runtimeModel?.provider ?? "oppi-e2e",
      model: runtimeModel?.id ?? fallbackModel ?? "oppi-e2e",
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    });
  }

  promptCacheRuntime(): ReturnType<AgentBackend["promptCacheRuntime"]> {
    const session = this.piSession;
    const status = session.cacheWarmingStatus;
    return {
      ...(status
        ? {
            warmer: {
              state: status.state,
              ...(status.decision ? { action: status.decision.action } : {}),
              ...(status.nextWarmAt !== undefined ? { nextWarmAt: status.nextWarmAt } : {}),
              ...(status.reason ? { reason: status.reason } : {}),
            },
          }
        : {}),
      ...(session.model?.promptCache ? { promptCache: session.model.promptCache } : {}),
    };
  }

  getEntryRenderers(): LiveEntryRendererSet | undefined {
    return createLiveEntryRendererLookup(
      this.piSession.extensionRunner,
      this.entryRendererGeneration,
    );
  }

  get showCacheMissNotices(): boolean {
    return this.runtime.services.settingsManager.getShowCacheMissNotices();
  }

  get cacheMissModelPriceSource(): CacheMissModelPriceSource {
    return this.modelRegistry;
  }

  private subscribeToCurrentSession(): void {
    this.unsub?.();
    this.unsub = this.piSession.subscribe((event: AgentSessionEvent) => {
      if (event.type === "queue_update") {
        this.queueAuthorityGeneration = (this.queueAuthorityGeneration ?? 0) + 1;
      }
      this.emitEvent(event);
    });
  }

  private async bindCurrentSessionExtensions(): Promise<void> {
    SdkBackend.applyDefaultQueueModes(this.piSession);

    await this.piSession.bindExtensions({
      uiContext: this.createExtensionUIContext(),
      mode: "rpc",
      onError: (error) => {
        const event: ExtensionErrorEvent = {
          type: "extension_error",
          extensionPath: error.extensionPath,
          event: error.event,
          error: error.error,
        };
        this.emitEvent(event);
      },
    });
    this.entryRendererGeneration += 1;
    this.installSessionAttachmentToolHelpers();
  }

  private installSessionAttachmentToolHelpers(): void {
    if (!this.dataDir) return;

    for (const registered of this.piSession.extensionRunner.getAllRegisteredTools()) {
      const definition = registered.definition;
      const currentExecute = definition.execute as AttachmentToolExecute;
      if (currentExecute.__oppiAttachmentHelperWrapped === true) {
        continue;
      }

      const originalExecute = currentExecute.bind(definition) as ToolDefinition["execute"];
      const wrappedExecute: ToolDefinition["execute"] = (
        toolCallId,
        params,
        signal,
        onUpdate,
        ctx,
      ) => {
        return originalExecute(
          toolCallId,
          params,
          signal,
          onUpdate,
          this.contextWithSessionAttachments(ctx, toolCallId),
        );
      };
      (wrappedExecute as AttachmentToolExecute).__oppiAttachmentHelperWrapped = true;
      definition.execute = wrappedExecute;
    }
  }

  private contextWithSessionAttachments(
    ctx: ExtensionToolContext,
    toolCallId: string,
  ): ExtensionContextWithAttachments {
    const dataDir = this.dataDir;
    const context = Object.create(ctx) as ExtensionContextWithAttachments;
    Object.defineProperty(context, "attachments", {
      configurable: true,
      enumerable: true,
      value: {
        addFile: (input: AttachmentAddFileInput): Record<string, unknown> => {
          if (!dataDir) {
            throw new Error("Oppi session attachment storage is unavailable");
          }
          return addSessionAttachmentFile({
            dataDir,
            sessionId: this.oppiSessionId,
            toolCallId,
            path: input.path,
            ...(input.kind !== undefined ? { kind: input.kind } : {}),
            ...(input.mimeType !== undefined ? { mimeType: input.mimeType } : {}),
            ...(input.fileName !== undefined ? { fileName: input.fileName } : {}),
            ...(input.durationSeconds !== undefined
              ? { durationSeconds: input.durationSeconds }
              : {}),
            ...(input.width !== undefined ? { width: input.width } : {}),
            ...(input.height !== undefined ? { height: input.height } : {}),
            ...(input.text !== undefined ? { text: input.text } : {}),
            ...(input.deleteSource !== undefined ? { deleteSource: input.deleteSource } : {}),
          });
        },
      },
    });
    return context;
  }

  private static applyDefaultQueueModes(session: AgentSession): void {
    // AgentSession's public queue setters persist to Pi user settings. Oppi
    // wants these delivery defaults session-locally without rewriting
    // ~/.pi/agent/settings.json.
    const agent = (
      session as unknown as {
        agent?: {
          steeringMode?: "all" | "one-at-a-time";
          followUpMode?: "all" | "one-at-a-time";
        };
      }
    ).agent;
    if (!agent) {
      return;
    }

    agent.steeringMode = SdkBackend.DEFAULT_STEERING_MODE;
    agent.followUpMode = SdkBackend.DEFAULT_FOLLOW_UP_MODE;
  }

  private createExtensionUIContext(): ReturnType<SdkUiBridge["createContext"]> {
    return this.uiBridge.createContext();
  }

  respondToExtensionUIRequest(response: ExtensionUIResponsePayload): boolean {
    return this.uiBridge.respond(response);
  }

  async reloadResources(reloadRuntimeConfig?: () => void): Promise<{ success: true }> {
    return this.withExclusiveRuntimeOperation("reload", async () => {
      this.assertRuntimeIdle("reload");
      try {
        this.assertSelectedResourcesAvailableBeforeReload?.();
      } catch (error) {
        this.selectedResourceInvariantError = safeErrorMessage(error);
        throw error;
      }
      reloadRuntimeConfig?.();

      const holder = this.mobileOutputGuideSettingsHolder;
      const getSettings = this.getMobileOutputGuideSettings;
      const previousSnapshot = holder?.snapshot;
      if (holder && getSettings) {
        // Read before Pi emits session_shutdown so storage failures leave the
        // current runtime and its guide snapshot untouched.
        holder.snapshot = freezeMobileOutputGuideSettingsSnapshot(getSettings());
      }

      try {
        await this.reloadCurrentSessionWithinLifecycleBound();
      } catch (error) {
        if (holder && previousSnapshot) holder.snapshot = previousSnapshot;
        throw error;
      }

      const selectedResourceError = this.consumeSelectedResourceReloadError?.();
      if (selectedResourceError) {
        this.selectedResourceInvariantError = safeErrorMessage(selectedResourceError);
        throw selectedResourceError;
      }
      this.selectedResourceInvariantError = undefined;
      SdkBackend.applyDefaultQueueModes(this.piSession);
      this.installSessionAttachmentToolHelpers();
      return { success: true };
    });
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    throw new Error(
      "new_session is not allowed inside an Oppi-focused session; create a distinct canonical session through Oppi lifecycle routes",
    );
  }

  async fork(_entryId: string): Promise<{ cancelled: boolean; selectedText?: string }> {
    throw new Error(
      "fork is not allowed inside an Oppi-focused session; create a distinct canonical session through Oppi lifecycle routes",
    );
  }

  // ─── Runtime transaction ───

  async withModelTurnAdmission<T>(
    commandType: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T> {
    this.assertSelectedResourceInvariant();
    if (this.isQueueReconciliationRequired) {
      throw new Error(QUEUE_RECONCILIATION_REQUIRED_ERROR);
    }
    const blocker = (this.requestedExclusiveOperations ?? [])[0]?.name;
    const unavailableMessage =
      blocker === "reload"
        ? `${commandType} cannot start while reload is rebuilding the session`
        : `${commandType} cannot start while the session runtime lifecycle is changing`;
    return this.getRuntimeTransaction().tryWithShared(unavailableMessage, async (permit) => {
      this.assertNotDisposed();
      if (this.isQueueReconciliationRequired) {
        throw new Error(QUEUE_RECONCILIATION_REQUIRED_ERROR);
      }
      return operation(permit);
    });
  }

  async withRuntimeLifecycleTransaction<T>(
    operationName: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
    options: { allowDisposed?: boolean } = {},
  ): Promise<T> {
    return this.withExclusiveRuntimeOperation(operationName, operation, options);
  }

  get isRuntimeLifecycleTransactionExclusive(): boolean {
    return this.getRuntimeTransaction().isExclusiveActive;
  }

  get isQueueReconciliationRequired(): boolean {
    return this.queueReconciliationRequired === true;
  }

  private getRuntimeTransaction(): SessionRuntimeTransaction {
    return (this.runtimeTransaction ??= new SessionRuntimeTransaction());
  }

  private async withExclusiveRuntimeOperation<T>(
    name: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
    options: { allowDisposed?: boolean } = {},
  ): Promise<T> {
    const request = { name };
    (this.requestedExclusiveOperations ??= []).push(request);
    try {
      return await this.getRuntimeTransaction().withExclusive(async (permit) => {
        if (!options.allowDisposed) this.assertNotDisposed();
        return operation(permit);
      });
    } finally {
      const index = this.requestedExclusiveOperations.indexOf(request);
      if (index !== -1) this.requestedExclusiveOperations.splice(index, 1);
    }
  }

  private assertNotDisposed(): void {
    if (this.disposed) throw new Error("Session backend is disposed");
  }

  private assertSelectedResourceInvariant(): void {
    if (this.selectedResourceInvariantError) {
      throw new Error(
        `${this.selectedResourceInvariantError}; restore the resource and reload before sending another prompt`,
      );
    }
  }

  private assertRuntimeIdle(operation: string): void {
    if (this.piSession.isStreaming || this.piSession.isCompacting) {
      throw new Error(`${operation} requires an idle session`);
    }
  }

  // ─── Commands ───

  /** Resolve after Pi accepts prompt preflight; model events continue through subscribe(). */
  async prompt(
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
      onPreflightAccepted?: () => void;
    },
    permit?: SessionRuntimeTransactionPermit,
  ): Promise<void> {
    const commandType =
      opts?.streamingBehavior === "steer"
        ? "steer"
        : opts?.streamingBehavior === "followUp"
          ? "follow_up"
          : "prompt";
    if (permit) {
      this.getRuntimeTransaction().assertPermit(permit, "shared");
      this.assertNotDisposed();
      this.assertSelectedResourceInvariant();
      await this.promptWithoutTransaction(message, opts);
      return;
    }
    await this.withModelTurnAdmission(commandType, (admission) =>
      this.prompt(message, opts, admission),
    );
  }

  captureQueuedModelTurnsAuthority(
    permit: SessionRuntimeTransactionPermit,
  ): QueuedModelTurnsAuthority {
    this.getRuntimeTransaction().assertPermit(permit, "exclusive");
    this.assertNotDisposed();
    return { generation: this.queueAuthorityGeneration ?? 0 };
  }

  assertQueuedModelTurnsAuthority(
    authority: QueuedModelTurnsAuthority,
    permit: SessionRuntimeTransactionPermit,
    phase: QueuedModelTurnsAuthorityError["phase"] = "after_replay",
  ): void {
    this.getRuntimeTransaction().assertPermit(permit, "exclusive");
    this.assertNotDisposed();
    if ((this.queueAuthorityGeneration ?? 0) !== authority.generation) {
      throw new QueuedModelTurnsAuthorityError(phase);
    }
  }

  async replaceQueuedModelTurns(
    batch: QueuedModelTurnBatch,
    rollback?: QueuedModelTurnBatch,
    permit?: SessionRuntimeTransactionPermit,
    authority?: QueuedModelTurnsAuthority,
  ): Promise<QueuedModelTurnsAuthority | undefined> {
    if (!permit) {
      return this.withExclusiveRuntimeOperation("queue replacement", (transaction) =>
        this.replaceQueuedModelTurns(batch, rollback, transaction, authority),
      );
    }

    this.getRuntimeTransaction().assertPermit(permit, "exclusive");
    this.assertNotDisposed();
    if (batch.prompt) this.assertSelectedResourceInvariant();
    const previous = rollback ?? this.sdkQueueSnapshot();
    try {
      const replayAuthority = authority
        ? await this.replayQueuedModelTurnsWithAuthority(batch, authority, permit)
        : (await this.replayQueuedModelTurns(batch), undefined);
      this.queueReconciliationRequired = false;
      return replayAuthority;
    } catch (caught) {
      const rejected = caught instanceof QueuedModelTurnsReplayRejected ? caught : undefined;
      const error = rejected ? rejected.reason : caught;
      if (error instanceof QueuedModelTurnsAuthorityError) {
        if (error.phase !== "before_replay") this.queueReconciliationRequired = false;
        throw error;
      }
      try {
        // The content check ran before the rejection reached this catch. Pi may
        // have consumed a queued message since, and rollback would restore it.
        // Re-check with no await before replayQueuedModelTurns() clears the queue.
        if (rejected)
          this.assertQueuedModelTurnsAuthority(rejected.authority, permit, "during_replay");
      } catch (authorityError) {
        if (authorityError instanceof QueuedModelTurnsAuthorityError) {
          this.queueReconciliationRequired = false;
        }
        throw authorityError;
      }
      try {
        await this.replayQueuedModelTurns(previous);
      } catch (rollbackError) {
        this.queueReconciliationRequired = true;
        log.error("sdk.queue_rollback.failed", {
          sessionId: this.oppiSessionId,
          replacementError: safeErrorMessage(error),
          rollbackError: safeErrorMessage(rollbackError),
        });
        throw new QueuedModelTurnsReconciliationError(error, rollbackError);
      }
      throw error;
    }
  }

  clearQueuedModelTurns(permit: SessionRuntimeTransactionPermit): void {
    this.getRuntimeTransaction().assertPermit(permit, "exclusive");
    this.assertNotDisposed();
    this.piSession.clearQueue();
    this.queueReconciliationRequired = false;
  }

  private sdkQueueSnapshot(): QueuedModelTurnBatch {
    return {
      steering: this.piSession.getSteeringMessages().map((message) => ({ message })),
      followUp: this.piSession.getFollowUpMessages().map((message) => ({ message })),
    };
  }

  private async replayQueuedModelTurns(batch: QueuedModelTurnBatch): Promise<void> {
    this.piSession.clearQueue();
    // Queue the remainder before starting an idle deferred prompt. If prompt
    // preflight rejects, rollback can still restore the complete prior intent.
    for (const item of batch.steering) await this.piSession.steer(item.message, item.images);
    for (const item of batch.followUp) await this.piSession.followUp(item.message, item.images);
    if (batch.prompt) {
      await this.promptWithoutTransaction(batch.prompt.message, { images: batch.prompt.images });
    }
  }

  private async replayQueuedModelTurnsWithAuthority(
    batch: QueuedModelTurnBatch,
    authority: QueuedModelTurnsAuthority,
    permit: SessionRuntimeTransactionPermit,
  ): Promise<QueuedModelTurnsAuthority> {
    if (batch.prompt) {
      throw new Error("Authoritative queue replacement cannot start a prompt");
    }
    this.assertQueuedModelTurnsAuthority(authority, permit, "before_replay");

    // Pi exposes no queue mutation barrier. clearQueue() mutates synchronously,
    // but steer()/followUp() await input handlers before they queue, so each
    // one appends and emits its own queue_update on a later microtask. Start the
    // whole batch in one JavaScript turn so clear and replay stay adjacent, then
    // wait for every replay to settle: none may still be pending when a rollback
    // or the Oppi commit runs.
    const replays: ReturnType<AgentSession["steer"]>[] = [];
    this.piSession.clearQueue();
    for (const item of batch.steering) {
      replays.push(this.piSession.steer(item.message, item.images));
    }
    for (const item of batch.followUp) {
      replays.push(this.piSession.followUp(item.message, item.images));
    }
    const settled = await Promise.allSettled(replays);
    const fulfilled = (
      offset: number,
      items: QueuedModelTurnBatch["steering"],
    ): QueuedModelTurnBatch["steering"] =>
      items.filter((_, index) => settled[offset + index]?.status === "fulfilled");
    const expected = {
      steering: fulfilled(0, batch.steering),
      followUp: fulfilled(batch.steering.length, batch.followUp),
    };

    // Everything settled, so Oppi's own queue_update events have all landed and
    // the generation captured here is the baseline for anything Pi does next.
    // Capturing earlier would count our own events as a foreign change, and a
    // generation count cannot tell them apart. Compare content instead: Pi's
    // queues must hold exactly the items whose replay succeeded, in order.
    const replayAuthority = this.captureQueuedModelTurnsAuthority(permit);
    const queueMatches = this.piQueueMatches(expected);

    const rejected = settled.find(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    if (rejected) {
      // A replay was refused. Rolling back is only safe if Pi still holds exactly
      // what did queue. If Pi started one of those messages meanwhile, restoring
      // the pre-edit queue would send it a second time, so reconcile instead.
      if (!queueMatches) throw new QueuedModelTurnsAuthorityError("during_replay");
      throw new QueuedModelTurnsReplayRejected(rejected.reason, replayAuthority);
    }
    if (!queueMatches) throw new QueuedModelTurnsAuthorityError("during_replay");
    return replayAuthority;
  }

  private piQueueMatches(expected: Pick<QueuedModelTurnBatch, "steering" | "followUp">): boolean {
    const same = (live: readonly string[], items: QueuedModelTurnBatch["steering"]): boolean =>
      live.length === items.length &&
      live.every((message, index) => message === items[index]?.message);
    return (
      same(this.piSession.getSteeringMessages(), expected.steering) &&
      same(this.piSession.getFollowUpMessages(), expected.followUp)
    );
  }

  private async promptWithoutTransaction(
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
      onPreflightAccepted?: () => void;
    },
  ): Promise<void> {
    const images: ImageContent[] | undefined = opts?.images?.map((img) => ({
      type: "image" as const,
      data: img.data,
      mimeType: img.mimeType,
    }));

    let accepted = false;
    let acceptanceNotified = false;
    let preflightSettled = false;
    let resolvePreflight!: () => void;
    let rejectPreflight!: (error: unknown) => void;
    const preflight = new Promise<void>((resolve, reject) => {
      resolvePreflight = resolve;
      rejectPreflight = reject;
    });
    const acceptPreflight = (): void => {
      if (this.disposed) {
        rejectPreflight(new Error("Session backend is disposed"));
        return;
      }
      if (!acceptanceNotified) {
        acceptanceNotified = true;
        opts?.onPreflightAccepted?.();
      }
      resolvePreflight();
    };
    const completion = Promise.resolve(
      this.piSession.prompt(message, {
        images,
        streamingBehavior: opts?.streamingBehavior,
        preflightResult: (success) => {
          preflightSettled = true;
          accepted = success && !this.disposed;
          if (success) acceptPreflight();
        },
      }),
    );
    completion.then(
      () => {
        if (!preflightSettled) acceptPreflight();
        else if (!accepted) rejectPreflight(new Error("Pi prompt preflight rejected"));
      },
      (error: unknown) => {
        if (!accepted) {
          rejectPreflight(error);
          return;
        }
        log.error("sdk.prompt.failed", { error: safeErrorMessage(error) });
        this.emitEvent({
          type: "prompt_error",
          error: error instanceof Error ? error.message : String(error),
        });
      },
    );
    await preflight;
  }

  async abort(permit?: SessionRuntimeTransactionPermit): Promise<void> {
    if (permit) {
      this.getRuntimeTransaction().assertPermit(permit, "exclusive");
      if (!this.disposed) await this.piSession.abort();
      return;
    }
    await this.withExclusiveRuntimeOperation("abort", (transaction) => this.abort(transaction), {
      allowDisposed: true,
    });
  }

  async setModel(
    modelId: string,
    options?: { persist?: boolean },
  ): Promise<{
    success: boolean;
    provider?: string;
    id?: string;
    name?: string;
    thinkingLevel?: string;
    error?: string;
  }> {
    return this.withRuntimeLifecycleTransaction("set_model", async () => {
      // Interactive model changes use the runtime's cached availability snapshot;
      // network refreshes must not block command or prompt admission.
      const candidates = modelCandidatesFromRegistry(
        this.modelRegistry,
        this.runtime.services.settingsManager.getEnabledModels(),
      );
      const resolution = resolveModelRequest(modelId, candidates);
      if (!resolution) {
        return { success: false, error: modelUnavailableMessage(modelId, candidates) };
      }

      try {
        if (options?.persist === true) {
          await this.piSession.setModel(resolution.candidate.model, { persist: true });
        } else {
          await this.piSession.setModel(resolution.candidate.model);
        }

        const activeModel = this.piSession.model;
        return {
          success: true,
          provider: activeModel?.provider,
          id: activeModel?.id,
          name: activeModel?.name,
          thinkingLevel: this.piSession.thinkingLevel,
        };
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return { success: false, error: message };
      }
    });
  }

  /** Full state snapshot for client command responses. */
  getStateSnapshot(): PiStateSnapshot {
    const m = this.piSession.model;
    return {
      sessionFile: this.piSession.sessionFile,
      sessionId: this.piSession.sessionId,
      sessionName: this.piSession.sessionName,
      model: m ? { provider: m.provider, id: m.id, name: m.name } : undefined,
      thinkingLevel: this.piSession.thinkingLevel,
      isStreaming: this.piSession.isStreaming,
      isCompacting: this.piSession.isCompacting,
      autoCompaction: this.piSession.autoCompactionEnabled,
    };
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  get isStreaming(): boolean {
    return this.piSession.isStreaming;
  }

  get isCompacting(): boolean {
    return this.piSession.isCompacting;
  }

  private recordLocalCleanupFailure(message: string): void {
    const failures = (this.localCleanupFailures ??= []);
    if (!failures.includes(message)) failures.push(message);
  }

  private localCleanupDiagnostic(): string | undefined {
    const failures = this.localCleanupFailures ?? [];
    return failures.length > 0 ? failures.join("; ") : undefined;
  }

  private withLocalCleanupDiagnostic(result: SdkBackendDisposeResult): SdkBackendDisposeResult {
    const diagnosticReason = this.localCleanupDiagnostic();
    if (!diagnosticReason) return result;
    if (result.disposal === "graceful") {
      return {
        disposal: "forced",
        cause: "local_cleanup_error",
        diagnosticReason,
      };
    }
    if (result.diagnosticReason === diagnosticReason) return result;
    return {
      ...result,
      diagnosticReason: [result.diagnosticReason, diagnosticReason].filter(Boolean).join("; "),
    };
  }

  private markLocallyDisposed(): void {
    if (this.disposed) return;
    this.disposed = true;

    try {
      const cleanup = this.uiBridge.dispose();
      for (const failure of cleanup?.failures ?? []) {
        this.recordLocalCleanupFailure(failure.message);
      }
    } catch (error: unknown) {
      const errorMessage = safeErrorMessage(error);
      this.recordLocalCleanupFailure(`Extension UI bridge cleanup failed: ${errorMessage}`);
      log.error("sdk.local_cleanup.ui_bridge_failed", {
        sessionId: this.oppiSessionId,
        error: errorMessage,
      });
    }

    try {
      this.unsub?.();
    } catch (error: unknown) {
      const errorMessage = safeErrorMessage(error);
      this.recordLocalCleanupFailure(`Session event unsubscribe failed: ${errorMessage}`);
      log.error("sdk.local_cleanup.unsubscribe_failed", {
        sessionId: this.oppiSessionId,
        error: errorMessage,
      });
    } finally {
      this.unsub = null;
    }
  }

  private forceDisposeAfterLifecycleTimeout(
    operation: "reload",
    session: AgentSession,
    timeoutMs: number,
  ): SdkBackendDisposeResult {
    const result: SdkBackendDisposeResult = {
      disposal: "forced",
      cause: "lifecycle_timeout",
      operation,
      timeoutMs,
    };
    this.markLocallyDisposed();
    // Same limit as the shutdown-timeout force path below: no session_shutdown,
    // so MCP stdio servers can survive if a handler was still pending.
    session.dispose();
    const diagnosedResult = this.withLocalCleanupDiagnostic(result);
    this.forcedDisposalResult = diagnosedResult;
    this.shutdownCleanupPromise ??= Promise.resolve(diagnosedResult);
    return diagnosedResult;
  }

  /** Capture the current Pi session before stop waits for the runtime permit. */
  captureEmergencyDisposalForStop(): (timeoutMs: number) => SdkBackendDisposeResult {
    const capturedSession = this.piSession;
    return (timeoutMs) => this.emergencyDisposeAfterStopTimeout(capturedSession, timeoutMs);
  }

  private emergencyDisposeAfterStopTimeout(
    capturedSession: AgentSession,
    timeoutMs: number,
  ): SdkBackendDisposeResult {
    const existing = this.forcedDisposalResult;
    this.markLocallyDisposed();
    this.getRuntimeTransaction().poison(
      new Error(`stop timed out after ${timeoutMs}ms; session backend is disposed`),
    );

    let cleanupFailed = false;
    for (const session of new Set([capturedSession, this.piSession])) {
      try {
        session.dispose();
      } catch (error: unknown) {
        cleanupFailed = true;
        log.error("sdk.runtime_lifecycle.force_cleanup_failed", {
          sessionId: this.oppiSessionId,
          operation: "stop",
          error: safeErrorMessage(error),
        });
      }
    }

    const result = this.withLocalCleanupDiagnostic(
      existing ??
        (cleanupFailed
          ? { disposal: "forced", cause: "runtime_dispose_error" }
          : {
              disposal: "forced",
              cause: "lifecycle_timeout",
              operation: "stop",
              timeoutMs,
            }),
    );
    this.forcedDisposalResult ??= result;
    this.shutdownCleanupPromise ??= Promise.resolve(result);
    return result;
  }

  private disposeLateLifecycleContinuation(
    operation: SdkRuntimeLifecycleOperation,
    session: AgentSession,
  ): void {
    try {
      // Pi's reload mutates its AgentSession after session_shutdown settles.
      // Re-dispose the detached session after any abandoned continuation so a
      // rebuilt extension runner cannot revive resources on the poisoned backend.
      session.dispose();
    } catch (error: unknown) {
      log.error("sdk.runtime_lifecycle.late_cleanup_failed", {
        sessionId: this.oppiSessionId,
        operation,
        error: safeErrorMessage(error),
      });
    }
  }

  private reloadCurrentSessionWithinLifecycleBound(): Promise<void> {
    const operation = "reload" as const;
    const session = this.piSession;
    const timeoutMs = SdkBackend.RUNTIME_LIFECYCLE_TIMEOUT_MS;

    return new Promise<void>((resolve, reject) => {
      let timedOut = false;
      const timeout = setTimeout(() => {
        timedOut = true;
        log.warn("sdk.runtime_lifecycle.timeout_force_cleanup", {
          sessionId: this.oppiSessionId,
          operation,
          timeoutMs,
        });
        try {
          this.forceDisposeAfterLifecycleTimeout(operation, session, timeoutMs);
          reject(
            new Error(`${operation} timed out after ${timeoutMs}ms; session backend was disposed`),
          );
        } catch (error: unknown) {
          log.error("sdk.runtime_lifecycle.force_cleanup_failed", {
            sessionId: this.oppiSessionId,
            operation,
            error: safeErrorMessage(error),
          });
          reject(error);
        }
      }, timeoutMs);

      let reload: Promise<void>;
      try {
        reload = Promise.resolve(session.reload());
      } catch (error: unknown) {
        clearTimeout(timeout);
        reject(error);
        return;
      }

      void reload.then(
        () => {
          if (timedOut) {
            this.disposeLateLifecycleContinuation(operation, session);
            return;
          }
          clearTimeout(timeout);
          resolve();
        },
        (error: unknown) => {
          if (timedOut) {
            this.disposeLateLifecycleContinuation(operation, session);
            return;
          }
          clearTimeout(timeout);
          reject(error);
        },
      );
    });
  }

  private startShutdownCleanup(): Promise<SdkBackendDisposeResult> {
    if (this.shutdownCleanupPromise) {
      return this.shutdownCleanupPromise;
    }

    const session = this.piSession;
    const timeoutMs = SdkBackend.RUNTIME_LIFECYCLE_TIMEOUT_MS;
    this.shutdownCleanupPromise = new Promise<SdkBackendDisposeResult>((resolve, reject) => {
      let settled = false;
      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        log.warn("sdk.runtime_dispose.timeout_force_cleanup", {
          sessionId: this.oppiSessionId,
          timeoutMs,
        });
        try {
          // Pi waits for every extension's session_shutdown handler before it
          // invalidates the session. A broken handler must not retain Oppi's
          // lifecycle transaction and workspace locks forever.
          //
          // Known limit: dispose() does not emit session_shutdown. If an earlier
          // handler hung, Pi's MCP extension never closed its stdio servers and
          // they can outlive this session. Pi's public surface offers no handle
          // to close them: `createMcpExtension({ createTransport })` needs the
          // default transport, which Pi does not export, and rebuilding it would
          // copy Pi internals (process-group spawn and kill). Revisit when Pi
          // exposes connection close or transport tracking.
          session.dispose();
          const result = this.withLocalCleanupDiagnostic({
            disposal: "forced",
            cause: "extension_shutdown_timeout",
            timeoutMs,
          });
          this.forcedDisposalResult = result;
          resolve(result);
        } catch (error: unknown) {
          log.error("sdk.runtime_dispose.force_cleanup_failed", {
            sessionId: this.oppiSessionId,
            error: safeErrorMessage(error),
          });
          reject(error);
        }
      }, timeoutMs);

      void Promise.resolve()
        .then(() => this.runtime.dispose())
        .then(
          () => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            resolve(this.withLocalCleanupDiagnostic({ disposal: "graceful" }));
          },
          (error: unknown) => {
            // A timed-out runtime can settle after forced local cleanup. Its
            // result no longer owns disposal and must not emit a second failure.
            if (settled) return;
            settled = true;
            log.error("sdk.runtime_dispose.failed", {
              sessionId: this.oppiSessionId,
              error: safeErrorMessage(error),
            });
            clearTimeout(timeout);
            try {
              session.dispose();
              const result = this.withLocalCleanupDiagnostic({
                disposal: "forced",
                cause: "runtime_dispose_error",
              });
              this.forcedDisposalResult = result;
              resolve(result);
            } catch (forceError: unknown) {
              log.error("sdk.runtime_dispose.force_cleanup_failed", {
                sessionId: this.oppiSessionId,
                error: safeErrorMessage(forceError),
              });
              reject(forceError);
            }
          },
        );
    });

    return this.shutdownCleanupPromise;
  }

  async dispose(permit?: SessionRuntimeTransactionPermit): Promise<SdkBackendDisposeResult> {
    if (!permit) {
      return this.withExclusiveRuntimeOperation(
        "dispose",
        (transaction) => this.dispose(transaction),
        { allowDisposed: true },
      );
    }

    this.getRuntimeTransaction().assertPermit(permit, "exclusive");
    if (this.disposed) {
      return this.startShutdownCleanup();
    }
    this.markLocallyDisposed();
    return this.startShutdownCleanup();
  }
}

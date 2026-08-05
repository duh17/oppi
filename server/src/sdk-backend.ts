/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { safeErrorMessage } from "./log-utils.js";
import { isDeclaredControlSession } from "./control-session.js";
import { createLogger } from "./logger.js";
import { chmodSync, existsSync, lstatSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, posix, relative, resolve as resolvePath } from "node:path";

import {
  createAgentSession,
  createAgentSessionRuntime,
  createBashToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  createEditToolDefinition,
  type AgentSession,
  type AgentSessionEvent,
  type AgentSessionRuntime,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionContext,
  type InlineExtension,
  type ResourceDiagnostic,
  type Skill,
  type ToolDefinition,
  SessionManager as PiSessionManager,
  DefaultPackageManager,
  DefaultResourceLoader,
  ModelRuntime,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";

import type { AgentDefinition } from "./agent-launch-service.js";
import type { CacheMissModelPriceSource } from "./cache-miss.js";
import { DEFAULT_AGENT_TOOL_NAMES, isDefaultAgentId } from "./default-agent.js";
import {
  modelCandidatesFromRegistry,
  modelUnavailableMessage,
  RequiredModelUnavailableError,
  resolveModelRequest,
  stripModelThinkingLevel,
} from "./model-resolution.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import { createDefaultAgentExtensionFactory } from "./default-agent-tool.js";
import { applyPendingProviderRegistrations } from "./extension-model-discovery.js";
import { createLifecycleJournalExtension } from "./lifecycle-journal-extension.js";
import {
  DEFAULT_OPPI_EXTENSION_SETTINGS,
  freezeOppiExtensionSettingsSnapshot,
  type OppiExtensionSettingsSnapshot,
} from "./oppi-extension-settings.js";
import { createOppiToolExtensionFactory } from "./oppi-tool-extension.js";
import type { ExtensionErrorEvent, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import { addSessionAttachmentFile, type SessionAttachmentKind } from "./session-attachments.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import { serverResourceId } from "./server-resource-id.js";
import { SdkUiBridge } from "./sdk-ui-bridge.js";
import { hostMountValidationError, resolveHostPath } from "./host.js";
import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "./oppi-cli-prompt.js";
import { buildOppiSystemPromptAppend } from "./oppi-docs.js";
import type { ReadonlyMount } from "./gondolin-manager.js";
import type { ServerConfig, Session, Workspace } from "./types.js";
import { resolveWorkspaceSessionCwd, WorkspaceWorktreeError } from "./worktrees.js";
import { callerSessionIdentityShellPrefix } from "./session-caller-identity.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "./session-runtime-transaction.js";

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

type ExtensionContextWithAttachments = ExtensionContext & {
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

function resolveRegistryModel(
  modelRegistry: ModelRegistry,
  modelId: string,
  enabledModels?: string[],
): ReturnType<ModelRegistry["find"]> {
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
    if (worktreePath) return worktreePath;
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
    return "Oppi Control";
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

async function resolveSelectedAgentExtensionPaths(
  extensionIds: string[] | undefined,
  cwd: string,
  agentDir: string,
  settingsManager: SettingsManager,
): Promise<string[] | undefined> {
  if (extensionIds === undefined) return undefined;
  if (extensionIds.length === 0) return [];

  const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  const resolved = await packageManager.resolve(async () => "skip");
  const pathsById = new Map(
    resolved.extensions
      .filter((resource) => resource.metadata.scope === "user")
      .map((resource) => [serverResourceId("extension", resource.path), resource.path]),
  );
  const selectedPaths: string[] = [];
  for (const extensionId of new Set(extensionIds)) {
    if (extensionId === "oppi") {
      throw new Error("The built-in Oppi extension is managed by server policy, not an Agent");
    }
    const path = pathsById.get(extensionId);
    if (!path) {
      throw new Error(`Selected Agent Extension is unavailable: ${extensionId}`);
    }
    selectedPaths.push(path);
  }
  return selectedPaths;
}

function assertSelectedAgentResourcesAvailable(
  selectedSkillPaths: string[] | undefined,
  selectedExtensionPaths: string[] | undefined,
): void {
  for (const selectedPath of selectedSkillPaths ?? []) {
    if (!existsSync(selectedPath)) {
      throw new Error(`Selected Agent Skill is unavailable: ${selectedPath}`);
    }
  }
  for (const selectedPath of selectedExtensionPaths ?? []) {
    if (!existsSync(selectedPath)) {
      throw new Error(`Selected Agent Extension is unavailable: ${selectedPath}`);
    }
  }
}

function assertSelectedAgentSkillsLoaded(
  selectedPaths: string[] | undefined,
  result: SkillLoadResult,
): void {
  if (selectedPaths === undefined) return;
  for (const selectedPath of selectedPaths) {
    const loaded = result.skills.some(
      (skill) =>
        isPathWithin(selectedPath, skill.filePath) ||
        isPathWithin(selectedPath, skill.baseDir) ||
        isPathWithin(skill.baseDir, selectedPath),
    );
    if (!loaded) {
      throw new Error(`Selected Agent Skill is unavailable: ${selectedPath}`);
    }
  }
}

function assertSelectedAgentExtensionsLoaded(
  selectedPaths: string[] | undefined,
  result: ExtensionLoadResult,
): void {
  if (selectedPaths === undefined) return;
  for (const selectedPath of selectedPaths) {
    const loaded = result.extensions.some(
      (extension) =>
        !extension.path.startsWith("<inline:") &&
        (isPathWithin(selectedPath, extension.resolvedPath) ||
          isPathWithin(extension.resolvedPath, selectedPath)),
    );
    if (!loaded) {
      throw new Error(`Selected Agent Extension could not be loaded: ${selectedPath}`);
    }
  }
}

function isPathWithin(parent: string, child: string): boolean {
  const resolvedParent = resolvePath(parent);
  const resolvedChild = resolvePath(child);
  const rel = relative(resolvedParent, resolvedChild);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
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
  options: { includeOppiDocsHint: boolean; includeOppiCliHint: boolean },
): string[] | undefined {
  const prompts: string[] = [];

  // Host-backed sessions can read the packaged docs path directly. Sandbox sessions
  // use a custom prompt that intentionally avoids exposing host/server paths.
  const oppiDocsHint = options.includeOppiDocsHint ? buildOppiSystemPromptAppend() : undefined;
  if (oppiDocsHint) {
    prompts.push(oppiDocsHint);
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
  /** Reads one atomic built-in Oppi settings snapshot for each ordinary runtime rebuild. */
  getOppiExtensionSettings?: () => OppiExtensionSettingsSnapshot;
}

type OppiExtensionSettingsHolder = {
  snapshot: OppiExtensionSettingsSnapshot;
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

export const QUEUE_RECONCILIATION_REQUIRED_ERROR =
  "Queue reconciliation required: retry setQueue from the last acknowledged queue version";

export const SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS = 5_000;

type SdkRuntimeLifecycleOperation = "reload" | "new_session" | "switch_session" | "fork" | "stop";

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

function assertConfiguredAgentToolsAvailable(
  configuredAllowed: readonly string[] | undefined,
  configuredExcluded: readonly string[] | undefined,
  activeToolNames: readonly string[],
): void {
  if (!configuredAllowed) return;
  const excluded = new Set(configuredExcluded ?? []);
  const active = new Set(activeToolNames);
  const missing = [...new Set(configuredAllowed)].filter(
    (name) => !excluded.has(name) && !active.has(name),
  );
  if (missing.length === 0) return;
  const noun = missing.length === 1 ? "tool is" : "tools are";
  throw new Error(
    `Configured Agent ${noun} unavailable: ${missing.join(", ")}. Update the Agent's selected Extensions or tool allowlist.`,
  );
}

function reserveOppiToolPolicy(options: {
  allowed?: readonly string[];
  excluded?: readonly string[];
  noTools?: "all" | "builtin";
}): { allowed?: string[]; excluded?: string[]; noTools?: "all" | "builtin" } {
  const allowed = options.allowed
    ? [...new Set([...options.allowed, "oppi"])]
    : options.noTools === "all"
      ? ["oppi"]
      : undefined;
  const excluded = options.excluded?.filter((name) => name !== "oppi");
  return {
    ...(allowed ? { allowed } : {}),
    ...(excluded && excluded.length > 0 ? { excluded } : {}),
    ...(options.noTools ? { noTools: options.noTools } : {}),
  };
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

  const piSessionId = manager.getSessionId();
  if (piSessionId) {
    session.piSessionId = piSessionId;
  }
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
export class SdkBackend {
  private static readonly DEFAULT_STEERING_MODE = "all" as const;
  private static readonly DEFAULT_FOLLOW_UP_MODE = "one-at-a-time" as const;
  /** Maximum graceful cleanup time within the documented stop bound. */
  static readonly RUNTIME_LIFECYCLE_TIMEOUT_MS = SDK_RUNTIME_LIFECYCLE_TIMEOUT_MS;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private static _gondolinManager: any;

  private runtime: AgentSessionRuntime;
  private unsub: (() => void) | null = null;
  private readonly emitEvent: (event: SessionBackendEvent) => void;
  private readonly uiBridge: SdkUiBridge;
  private shutdownCleanupPromise: Promise<SdkBackendDisposeResult> | null = null;
  private forcedDisposalResult: SdkBackendDisposeResult | undefined;
  private readonly sessionCwdExistsOverride?: string;
  private readonly sessionManagerDisplayCwd?: string;
  private readonly oppiSessionId: string;
  private readonly dataDir?: string;
  private readonly oppiSettingsHolder?: OppiExtensionSettingsHolder;
  private readonly getOppiExtensionSettings?: () => OppiExtensionSettingsSnapshot;
  private readonly assertSelectedResourcesAvailableBeforeReload?: () => void;
  private readonly consumeSelectedResourceReloadError?: () => Error | undefined;
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
    cwdOverrides?: { existsCwd: string; displayCwd?: string },
    oppiRuntimeSettings?: {
      holder: OppiExtensionSettingsHolder;
      get: () => OppiExtensionSettingsSnapshot;
    },
    assertSelectedResourcesAvailableBeforeReload?: () => void,
    consumeSelectedResourceReloadError?: () => Error | undefined,
  ) {
    this.runtime = runtime;
    this.emitEvent = emitEvent;
    this.oppiSessionId = oppiSessionId;
    this.dataDir = dataDir;
    this.oppiSettingsHolder = oppiRuntimeSettings?.holder;
    this.getOppiExtensionSettings = oppiRuntimeSettings?.get;
    this.assertSelectedResourcesAvailableBeforeReload =
      assertSelectedResourcesAvailableBeforeReload;
    this.consumeSelectedResourceReloadError = consumeSelectedResourceReloadError;
    this.sessionCwdExistsOverride = cwdOverrides?.existsCwd;
    this.sessionManagerDisplayCwd = cwdOverrides?.displayCwd;
    this.uiBridge = new SdkUiBridge(emitEvent, () => this.disposed);
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
      return PiSessionManager.inMemory(cwd);
    }
    if (piSessionFile) {
      return PiSessionManager.open(piSessionFile, undefined, cwdExistsOverride);
    }

    const manager = PiSessionManager.create(cwd);
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
    // filesystem: "Oppi Control" is Oppi UI metadata only. Persisting that label
    // as SessionManager cwd materializes JSONLs under process.cwd()/Oppi Control
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
    const isDefaultAgentSession = isDefaultAgentId(session.launch?.agentId ?? "");
    const isolatedControlRuntime = isDeclaredControlSession(session) || isDefaultAgentSession;
    const controlToolRuntime = isolatedControlRuntime && !sandboxMode;
    const ordinaryManagedRuntime =
      !sandboxMode && !isolatedControlRuntime && (session.runtime ?? "oppi") !== "pi-tui";
    const settingsManagedRuntime = ordinaryManagedRuntime || controlToolRuntime;
    const getOppiExtensionSettings =
      config.getOppiExtensionSettings ?? (() => DEFAULT_OPPI_EXTENSION_SETTINGS);
    const oppiSettingsHolder: OppiExtensionSettingsHolder = {
      snapshot: DEFAULT_OPPI_EXTENSION_SETTINGS,
    };
    const controlPolicySnapshot = {
      get approvalPolicy() {
        return oppiSettingsHolder.snapshot.approvalPolicy;
      },
    };
    const ordinaryOppiExtension: InlineExtension | undefined = ordinaryManagedRuntime
      ? {
          name: "oppi",
          factory: (pi) => {
            const snapshot = oppiSettingsHolder.snapshot;
            if (!snapshot.enabled) return;
            return createOppiToolExtensionFactory({
              ...(config.dataDir !== undefined ? { dataDir: config.dataDir } : {}),
              policySnapshot: snapshot,
              identity: "ordinary",
              callerSessionId: session.id,
            })(pi);
          },
        }
      : undefined;
    let assertSelectedResourcesAvailableBeforeReload: (() => void) | undefined;
    let consumeSelectedResourceReloadError: (() => Error | undefined) | undefined;
    const createRuntimeFactory: CreateAgentSessionRuntimeFactory = async ({
      cwd,
      agentDir: runtimeAgentDir,
      sessionManager,
      sessionStartEvent,
    }) => {
      if (settingsManagedRuntime) {
        oppiSettingsHolder.snapshot = freezeOppiExtensionSettingsSnapshot(
          getOppiExtensionSettings(),
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
      const settingsManager = SettingsManager.create(hostCwd, runtimeAgentDir);
      const selectedAgentExtensionPaths = isolatedControlRuntime
        ? undefined
        : await resolveSelectedAgentExtensionPaths(
            selectedAgentExtensionIds,
            hostCwd,
            runtimeAgentDir,
            settingsManager,
          );

      // Resource loader: follow Pi's normal cwd/settings/package discovery.
      // Oppi no longer applies a workspace-level skills/extensions policy for
      // host sessions. Project/user Pi settings remain the source of truth.
      const isOppiOwnedHostSession = !sandboxMode && (session.runtime ?? "oppi") !== "pi-tui";
      const baseAppendSystemPrompt = buildSdkAppendSystemPrompt(workspace, {
        includeOppiDocsHint: isOppiOwnedHostSession && isOppiDocsPromptEnabled(config.serverConfig),
        includeOppiCliHint: isOppiOwnedHostSession && isOppiCliPromptEnabled(config.serverConfig),
      });
      const normalizedSelectedAgentSkillPaths = selectedAgentSkillPaths?.map((path) =>
        isAbsolute(path) ? path : resolvePath(hostCwd, path),
      );
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
        appendSystemPrompt: baseAppendSystemPrompt,
        extensionFactories: [
          createLifecycleJournalExtension(sessionManager),
          ...(controlToolRuntime
            ? [
                createDefaultAgentExtensionFactory({
                  dataDir: config.dataDir,
                  callerSessionId: session.id,
                  policySnapshot: controlPolicySnapshot,
                }),
              ]
            : ordinaryOppiExtension
              ? [ordinaryOppiExtension]
              : []),
        ],
        ...(ordinaryManagedRuntime
          ? {
              extensionsOverride: (base) =>
                oppiSettingsHolder.snapshot.enabled
                  ? base
                  : {
                      ...base,
                      extensions: base.extensions.filter(
                        (extension) => extension.path !== "<inline:oppi>",
                      ),
                    },
            }
          : {}),
        ...(isolatedControlRuntime
          ? {
              noExtensions: true,
              noSkills: true,
              noPromptTemplates: true,
            }
          : {
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
            }),
        ...(isolatedControlRuntime || agentDefinition?.resources?.noContextFiles
          ? { noContextFiles: true }
          : {}),
        ...(agentDefinition?.instructions?.mode === "replace"
          ? { systemPromptOverride: () => agentDefinition.instructions?.text }
          : {}),
        ...(agentDefinition?.instructions?.mode === "append"
          ? {
              appendSystemPromptOverride: (base: string[]) =>
                [...base, agentDefinition.instructions?.text ?? ""].filter(
                  (prompt) => prompt.length > 0,
                ),
            }
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
                  skills: base.skills.map((skill) => {
                    const guestBaseDir = posix.join(
                      guestCwd,
                      ".pi",
                      "skills",
                      safeGuestSegment(skill.name),
                    );
                    sandboxReadonlyMounts.set(guestBaseDir, {
                      hostPath: skill.baseDir,
                      guestPath: guestBaseDir,
                    });
                    return {
                      ...skill,
                      baseDir: guestBaseDir,
                      filePath: posix.join(guestBaseDir, basename(skill.filePath)),
                    };
                  }),
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
          ? resolveRegistryModel(modelRegistry, session.model, settingsManager.getEnabledModels())
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
        const { isQemuAvailable, GondolinManager } = await import("./gondolin-manager.js");
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
        } = await import("./gondolin-ops.js");

        // Lazy singleton — shared across all sessions for VM reuse.
        if (!SdkBackend._gondolinManager) {
          SdkBackend._gondolinManager = new GondolinManager();
        }
        const manager = SdkBackend._gondolinManager;

        // Do not inject Oppi/pi provider credentials into the guest by default.
        // The host process owns model calls; sandbox commands must opt into any
        // future secret bridge explicitly instead of inheriting LLM API keys.
        const secrets: Record<string, { value: string; headerName?: string }> = {};

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
      const launchToolPolicy = controlToolRuntime
        ? { allowed: [...DEFAULT_AGENT_TOOL_NAMES], noTools: "builtin" as const }
        : (session.launch?.tools ?? agentDefaultToolPolicy);
      const configuredToolPolicy = {
        allowed: launchToolPolicy?.allowed ?? workspaceTools,
        excluded: launchToolPolicy?.excluded,
        noTools: launchToolPolicy?.noTools ?? (sandboxTools ? ("builtin" as const) : undefined),
      };
      const effectiveToolPolicy = ordinaryManagedRuntime
        ? reserveOppiToolPolicy(configuredToolPolicy)
        : configuredToolPolicy;
      const createResult = await createAgentSession({
        cwd: sessionCwd,
        agentDir: runtimeAgentDir,
        modelRuntime,
        model,
        thinkingLevel: normalizeThinkingLevel(session.thinkingLevel),
        sessionManager,
        settingsManager,
        resourceLoader: loader,
        sessionStartEvent,
        ...(sandboxTools ? { customTools: sandboxTools } : {}),
        ...(effectiveToolPolicy.noTools ? { noTools: effectiveToolPolicy.noTools } : {}),
        ...(effectiveToolPolicy.allowed ? { tools: effectiveToolPolicy.allowed } : {}),
        ...(effectiveToolPolicy.excluded ? { excludeTools: effectiveToolPolicy.excluded } : {}),
      });

      try {
        if (agentDefinition) {
          assertConfiguredAgentToolsAvailable(
            launchToolPolicy?.allowed,
            launchToolPolicy?.excluded,
            createResult.session.agent.state.tools.map((tool) => tool.name),
          );
        }
      } catch (error) {
        createResult.session.dispose();
        throw error;
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

    const runtime = await createAgentSessionRuntime(createRuntimeFactory, {
      cwd: initialHostCwd,
      agentDir,
      sessionManager: initialSessionManager,
    });

    const backend = new SdkBackend(
      runtime,
      onEvent,
      session.id,
      config.dataDir,
      sandboxMode
        ? { existsCwd: initialHostCwd, displayCwd }
        : isDeclaredControlSession(session)
          ? { existsCwd: initialHostCwd }
          : undefined,
      settingsManagedRuntime
        ? {
            holder: oppiSettingsHolder,
            get: getOppiExtensionSettings,
          }
        : undefined,
      () => assertSelectedResourcesAvailableBeforeReload?.(),
      () => consumeSelectedResourceReloadError?.(),
    );

    const preBindMs = Date.now() - createStartMs;
    config.metrics?.record("server.session_create_sdk_ms", preBindMs);

    await backend.bindCurrentSessionExtensions();

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
    ctx: ExtensionContext,
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

  private async refreshRuntimeSessionBindings(): Promise<void> {
    this.subscribeToCurrentSession();
    await this.bindCurrentSessionExtensions();
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

      const holder = this.oppiSettingsHolder;
      const getSettings = this.getOppiExtensionSettings;
      const previousSnapshot = holder?.snapshot;
      if (holder && getSettings) {
        // Read before Pi emits session_shutdown so provider/storage failures leave
        // the old extension runner and its captured policy untouched.
        holder.snapshot = freezeOppiExtensionSettingsSnapshot(getSettings());
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
    return this.withExclusiveRuntimeOperation(
      "new_session",
      async () => {
        if (this.disposed) return { cancelled: true };
        this.assertRuntimeIdle("new_session");
        const parentSession = this.piSession.sessionFile;
        const result = await this.runtime.newSession({ parentSession });
        this.assertReplacementContinuationActive("new_session");
        if (!result.cancelled) {
          this.restoreSessionManagerDisplayCwd();
          await this.refreshRuntimeSessionBindings();
          this.assertReplacementContinuationActive("new_session");
        }
        return result;
      },
      { allowDisposed: true },
    );
  }

  async switchSession(sessionPath: string): Promise<{ cancelled: boolean }> {
    return this.withExclusiveRuntimeOperation(
      "switch_session",
      async () => {
        if (this.disposed) return { cancelled: true };
        this.assertRuntimeIdle("switch_session");
        const result = await this.runtime.switchSession(
          sessionPath,
          this.sessionCwdExistsOverride
            ? { cwdOverride: this.sessionCwdExistsOverride }
            : undefined,
        );
        this.assertReplacementContinuationActive("switch_session");
        if (!result.cancelled) {
          this.restoreSessionManagerDisplayCwd();
          await this.refreshRuntimeSessionBindings();
          this.assertReplacementContinuationActive("switch_session");
        }
        return result;
      },
      { allowDisposed: true },
    );
  }

  async fork(entryId: string): Promise<{ cancelled: boolean; selectedText?: string }> {
    return this.withExclusiveRuntimeOperation(
      "fork",
      async () => {
        if (this.disposed) return { cancelled: true };
        this.assertRuntimeIdle("fork");
        const result = await this.runtime.fork(entryId);
        this.assertReplacementContinuationActive("fork");
        if (!result.cancelled) {
          this.restoreSessionManagerDisplayCwd();
          await this.refreshRuntimeSessionBindings();
          this.assertReplacementContinuationActive("fork");
        }
        return result;
      },
      { allowDisposed: true },
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
    } catch (error) {
      if (error instanceof QueuedModelTurnsAuthorityError) {
        if (error.phase !== "before_replay") this.queueReconciliationRequired = false;
        throw error;
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

    // Pi exposes no queue mutation barrier. Its queue methods mutate synchronously
    // before their promises settle, so invoke the whole clear/replay batch in one
    // JavaScript turn. Pi cannot consume between the final authority check and
    // the clear, or between individual replays.
    const replays: Promise<void>[] = [];
    this.piSession.clearQueue();
    for (const item of batch.steering) {
      replays.push(this.piSession.steer(item.message, item.images));
    }
    for (const item of batch.followUp) {
      replays.push(this.piSession.followUp(item.message, item.images));
    }
    const replayAuthority = this.captureQueuedModelTurnsAuthority(permit);

    try {
      await Promise.all(replays);
    } catch (error) {
      // An authoritative dequeue outranks a concurrent replay rejection. Do not
      // roll stale pre-replay intent back over a message Pi already consumed.
      this.assertQueuedModelTurnsAuthority(replayAuthority, permit, "during_replay");
      throw error;
    }
    this.assertQueuedModelTurnsAuthority(replayAuthority, permit, "during_replay");
    const steering = this.piSession.getSteeringMessages();
    const followUp = this.piSession.getFollowUpMessages();
    const queueMatches =
      steering.length === batch.steering.length &&
      steering.every((message, index) => message === batch.steering[index]?.message) &&
      followUp.length === batch.followUp.length &&
      followUp.every((message, index) => message === batch.followUp[index]?.message);
    if (!queueMatches) throw new QueuedModelTurnsAuthorityError("during_replay");
    return replayAuthority;
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

  get isReloading(): boolean {
    return (this.requestedExclusiveOperations ?? []).some(
      (operation) => operation.name === "reload",
    );
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

  async setModel(modelId: string): Promise<{
    success: boolean;
    provider?: string;
    id?: string;
    name?: string;
    thinkingLevel?: string;
    error?: string;
  }> {
    await this.modelRegistry.refresh();
    const candidates = modelCandidatesFromRegistry(
      this.modelRegistry,
      this.runtime.services.settingsManager.getEnabledModels(),
    );
    const resolution = resolveModelRequest(modelId, candidates);
    if (!resolution) {
      return { success: false, error: modelUnavailableMessage(modelId, candidates) };
    }

    try {
      await this.piSession.setModel(resolution.candidate.model);

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

  private assertReplacementContinuationActive(operation: SdkRuntimeLifecycleOperation): void {
    if (!this.disposed) return;
    this.disposeLateLifecycleContinuation(operation, this.piSession);
    throw new Error("Session backend is disposed");
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

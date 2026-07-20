/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { safeErrorMessage } from "./log-utils.js";
import { isDeclaredControlSession } from "./control-session.js";
import { createLogger } from "./logger.js";
import { chmodSync, lstatSync, mkdirSync, writeFileSync } from "node:fs";
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
  type ResourceDiagnostic,
  type Skill,
  type ToolDefinition,
  SessionManager as PiSessionManager,
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
  resolveModelRequest,
} from "./model-resolution.js";
import { createDefaultAgentExtensionFactory } from "./default-agent-tool.js";
import { createLifecycleJournalExtension } from "./lifecycle-journal-extension.js";
import type { ExtensionErrorEvent, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import { addSessionAttachmentFile, type SessionAttachmentKind } from "./session-attachments.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import { SdkUiBridge } from "./sdk-ui-bridge.js";
import { hostMountValidationError, resolveHostPath } from "./host.js";
import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "./oppi-cli-prompt.js";
import { buildOppiSystemPromptAppend } from "./oppi-docs.js";
import type { ReadonlyMount } from "./gondolin-manager.js";
import type { ServerConfig, Session, Workspace } from "./types.js";
import { resolveWorkspaceSessionCwd, WorkspaceWorktreeError } from "./worktrees.js";
import { callerSessionIdentityShellPrefix } from "./session-caller-identity.js";

type PiThinkingLevel = Parameters<AgentSession["setThinkingLevel"]>[0];
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

export function normalizeThinkingLevel(level: string | undefined): PiThinkingLevel | undefined {
  switch (level) {
    case "off":
    case "minimal":
    case "low":
    case "medium":
    case "high":
    case "xhigh":
      return level;
    default:
      return undefined;
  }
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
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private static _gondolinManager: any;

  private runtime: AgentSessionRuntime;
  private unsub: (() => void) | null = null;
  private readonly emitEvent: (event: SessionBackendEvent) => void;
  private readonly uiBridge: SdkUiBridge;
  private shutdownCleanupPromise: Promise<void> | null = null;
  private readonly sessionCwdExistsOverride?: string;
  private readonly sessionManagerDisplayCwd?: string;
  private readonly oppiSessionId: string;
  private readonly dataDir?: string;
  private disposed = false;

  private constructor(
    runtime: AgentSessionRuntime,
    emitEvent: (event: SessionBackendEvent) => void,
    oppiSessionId: string,
    dataDir?: string,
    cwdOverrides?: { existsCwd: string; displayCwd: string },
  ) {
    this.runtime = runtime;
    this.emitEvent = emitEvent;
    this.oppiSessionId = oppiSessionId;
    this.dataDir = dataDir;
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
    const initialCwd = resolveSdkSessionDisplayCwd(workspace, session, { dataDir: config.dataDir });
    const sandboxMode = workspace?.runtime === "sandbox";
    // Pi verifies a saved session's header cwd against a real host directory.
    // Sandboxes and control sessions deliberately persist a display-only cwd,
    // so their real cwd must remain available as the verification override.
    const preserveDisplayCwd = sandboxMode || isDeclaredControlSession(session);
    const runtimeAssertCwd = preserveDisplayCwd ? initialHostCwd : initialCwd;
    const hostMountError = hostMountValidationError(workspace?.hostMount);
    if (hostMountError) {
      throw new Error(hostMountError);
    }
    const agentDir = getAgentDir();
    const initialSessionManager = SdkBackend.createPiSessionManager(
      session,
      initialCwd,
      runtimeAssertCwd,
    );
    syncSessionIdentityFromManager(session, initialSessionManager);

    const agentDefinition = config.agentDefinition;
    const isDefaultAgentSession = isDefaultAgentId(session.launch?.agentId ?? "");
    const createRuntimeFactory: CreateAgentSessionRuntimeFactory = async ({
      cwd,
      agentDir: runtimeAgentDir,
      sessionManager,
      sessionStartEvent,
    }) => {
      const hostCwd = sandboxMode ? initialHostCwd : cwd;
      const guestCwd = sandboxMode && workspace ? resolveSandboxGuestCwd(workspace) : cwd;
      const sessionCwd = sandboxMode ? guestCwd : cwd;
      const sandboxReadonlyMounts = new Map<string, ReadonlyMount>();
      const savedAgentFiles = normalizeAgentContextFiles(
        agentDefinition,
        sandboxMode ? sessionCwd : undefined,
      );
      const savedAgentSkillPaths = agentDefinition?.resources?.skillPaths ?? [];
      const additionalSkillPaths = [...(config.skillPaths ?? []), ...savedAgentSkillPaths];
      const modelRuntime = await ModelRuntime.create({
        authPath: join(runtimeAgentDir, "auth.json"),
        modelsPath: join(runtimeAgentDir, "models.json"),
      });
      const modelRegistry = new ModelRegistry(modelRuntime);
      const settingsManager = SettingsManager.create(hostCwd, runtimeAgentDir);

      const shouldSeedFromSessionState = !sessionStartEvent;
      const model =
        shouldSeedFromSessionState && session.model
          ? resolveRegistryModel(modelRegistry, session.model, settingsManager.getEnabledModels())
          : undefined;
      if (shouldSeedFromSessionState && session.model && !model) {
        log.warn("sdk.model_resolve_defaulted", {
          model: session.model,
        });
      }

      // Resource loader: follow Pi's normal cwd/settings/package discovery.
      // Oppi no longer applies a workspace-level skills/extensions policy for
      // host sessions. Project/user Pi settings remain the source of truth.
      const isOppiOwnedHostSession = !sandboxMode && (session.runtime ?? "oppi") !== "pi-tui";
      const baseAppendSystemPrompt = buildSdkAppendSystemPrompt(workspace, {
        includeOppiDocsHint: isOppiOwnedHostSession && isOppiDocsPromptEnabled(config.serverConfig),
        includeOppiCliHint: isOppiOwnedHostSession && isOppiCliPromptEnabled(config.serverConfig),
      });
      const loader = new DefaultResourceLoader({
        cwd: hostCwd,
        agentDir: runtimeAgentDir,
        settingsManager,
        appendSystemPrompt: baseAppendSystemPrompt,
        extensionFactories: [
          createLifecycleJournalExtension(sessionManager),
          ...(isDefaultAgentSession
            ? [createDefaultAgentExtensionFactory({ dataDir: config.dataDir })]
            : []),
        ],
        ...(isDefaultAgentSession
          ? {
              noExtensions: true,
              noSkills: true,
              noPromptTemplates: true,
            }
          : { additionalSkillPaths }),
        ...(isDefaultAgentSession || agentDefinition?.resources?.noContextFiles
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
              skillsOverride: (base: SkillLoadResult): SkillLoadResult => ({
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
              }),
            }
          : {
              agentsFilesOverride: (base: { agentsFiles: AgentContextFile[] }) => ({
                agentsFiles: [...base.agentsFiles, ...savedAgentFiles],
              }),
            }),
      });
      if (!sandboxMode) {
        const reload = loader.reload.bind(loader);
        loader.reload = async (options) => {
          await reload(options);
          const configuredShellCommandPrefix = settingsManager.getShellCommandPrefix();
          settingsManager.applyOverrides({
            shellCommandPrefix: [
              callerSessionIdentityShellPrefix(session.id),
              configuredShellCommandPrefix,
            ]
              .filter((prefix): prefix is string => Boolean(prefix))
              .join("\n"),
          });
        };
      }
      await loader.reload();

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
      const launchToolPolicy = isDefaultAgentSession
        ? { allowed: [...DEFAULT_AGENT_TOOL_NAMES], noTools: "builtin" as const }
        : (session.launch?.tools ?? agentDefaultToolPolicy);
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
        ...(launchToolPolicy?.noTools
          ? { noTools: launchToolPolicy.noTools }
          : sandboxTools
            ? { noTools: "builtin" as const }
            : {}),
        ...(launchToolPolicy?.allowed
          ? { tools: launchToolPolicy.allowed }
          : workspaceTools
            ? { tools: workspaceTools }
            : {}),
        ...(launchToolPolicy?.excluded ? { excludeTools: launchToolPolicy.excluded } : {}),
      });

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
      cwd: runtimeAssertCwd,
      agentDir,
      sessionManager: initialSessionManager,
    });

    const backend = new SdkBackend(
      runtime,
      onEvent,
      session.id,
      config.dataDir,
      preserveDisplayCwd ? { existsCwd: runtimeAssertCwd, displayCwd: initialCwd } : undefined,
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

  async reloadResources(): Promise<{ success: true }> {
    if (this.disposed) {
      throw new Error("Session backend is disposed");
    }

    await this.piSession.reload();
    SdkBackend.applyDefaultQueueModes(this.piSession);
    this.installSessionAttachmentToolHelpers();
    return { success: true };
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const parentSession = this.piSession.sessionFile;
    const result = await this.runtime.newSession({ parentSession });
    if (!result.cancelled) {
      this.restoreSessionManagerDisplayCwd();
      await this.refreshRuntimeSessionBindings();
    }
    return result;
  }

  async switchSession(sessionPath: string): Promise<{ cancelled: boolean }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const result = await this.runtime.switchSession(
      sessionPath,
      this.sessionCwdExistsOverride ? { cwdOverride: this.sessionCwdExistsOverride } : undefined,
    );
    if (!result.cancelled) {
      this.restoreSessionManagerDisplayCwd();
      await this.refreshRuntimeSessionBindings();
    }
    return result;
  }

  async fork(entryId: string): Promise<{ cancelled: boolean; selectedText?: string }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const result = await this.runtime.fork(entryId);
    if (!result.cancelled) {
      this.restoreSessionManagerDisplayCwd();
      await this.refreshRuntimeSessionBindings();
    }
    return result;
  }

  // ─── Commands ───

  /** Send a prompt. Fire-and-forget — events come via subscribe. */
  prompt(
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
    },
  ): void {
    if (this.disposed) return;

    const images: ImageContent[] | undefined = opts?.images?.map((img) => ({
      type: "image" as const,
      data: img.data,
      mimeType: img.mimeType,
    }));

    this.piSession
      .prompt(message, {
        images,
        streamingBehavior: opts?.streamingBehavior,
      })
      .catch((err) => {
        const errorMessage = err instanceof Error ? err.message : String(err);
        log.error("sdk.prompt.failed", { error: safeErrorMessage(err) });
        this.emitEvent({ type: "prompt_error", error: errorMessage });
      });
  }

  async abort(): Promise<void> {
    if (this.disposed) return;
    await this.piSession.abort();
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

  private startShutdownCleanup(): Promise<void> {
    if (this.shutdownCleanupPromise) {
      return this.shutdownCleanupPromise;
    }

    this.shutdownCleanupPromise = (async () => {
      try {
        // Runtime dispose emits session_shutdown and tears down the current
        // session lifecycle (extensions + event subscriptions).
        await this.runtime.dispose();
      } catch (err: unknown) {
        log.error("sdk.runtime_dispose.failed", {
          sessionId: this.piSession.sessionId,
          error: safeErrorMessage(err),
        });
      }
    })();

    return this.shutdownCleanupPromise;
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      await this.startShutdownCleanup();
      return;
    }
    this.disposed = true;

    this.uiBridge.dispose();

    this.unsub?.();
    this.unsub = null;

    await this.startShutdownCleanup();
  }
}

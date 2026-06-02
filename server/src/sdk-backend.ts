/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { existsSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
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
  type ExtensionFactory,
  type ResourceDiagnostic,
  type Skill,
  SessionManager as PiSessionManager,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";

import type { ExtensionErrorEvent, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import {
  BUILT_IN_EXTENSION_NAMES,
  isBuiltInExtensionName,
  isManagedExtensionName,
  isWorkspaceBuiltInExtensionEnabled,
} from "../extensions/built-ins.js";
import { createAskFactory } from "../extensions/ask.js";
import { createOppiAdminFactory } from "../extensions/oppi-admin.js";
import { createSubagentsFactory, type SubagentsContext } from "../extensions/subagents.js";
import { createVoiceFactory } from "../extensions/voice.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { Storage } from "./storage.js";
import { SdkUiBridge, type ExtensionUIResponsePayload } from "./sdk-ui-bridge.js";
import { extensionNameFromPath } from "./extension-loader.js";
import { hostMountValidationError, resolveHostPath } from "./host.js";
import type { ReadonlyMount } from "./gondolin-manager.js";
import type { Session, SubagentConfig, Workspace } from "./types.js";

type PiThinkingLevel = Parameters<AgentSession["setThinkingLevel"]>[0];

function normalizeThinkingLevel(level: string | undefined): PiThinkingLevel | undefined {
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

/** Parse an oppi model string like "anthropic/claude-sonnet-4-20250514" into { provider, model }. */
function parseModelId(modelId: string): { provider: string; model: string } | null {
  const slash = modelId.indexOf("/");
  if (slash <= 0) return null;
  return { provider: modelId.substring(0, slash), model: modelId.substring(slash + 1) };
}

function resolveRegistryModel(
  modelRegistry: Pick<ModelRegistry, "find">,
  modelId: string,
): ReturnType<ModelRegistry["find"]> {
  const parsed = parseModelId(modelId);
  if (!parsed) {
    return undefined;
  }

  return modelRegistry.find(parsed.provider, parsed.model);
}

const PERMISSION_GATE_EXTENSION_NAME = "permission-gate";

type LoadedExtensionForFilter = {
  path: string;
  resolvedPath: string;
};

export interface SdkExtensionFilterOptions {
  workspaceExtensions?: string[];
  permissionGateEnabled: boolean;
  permissionGatePath?: string;
}

function getLoadedExtensionName(ext: { path: string; resolvedPath?: string }): string {
  return extensionNameFromPath(ext.resolvedPath || ext.path);
}

function resolveGlobalPermissionGateExtensionPath(agentDir: string): string | undefined {
  const base = join(agentDir, "extensions", PERMISSION_GATE_EXTENSION_NAME);
  const candidates = [`${base}.ts`, `${base}.js`, base];
  return candidates.find((candidate) => existsSync(candidate));
}

function canonicalPathForCompare(path: string): string {
  const resolved = resolvePath(path);
  try {
    return realpathSync.native(resolved);
  } catch {
    return resolved;
  }
}

function extensionPathMatches(ext: LoadedExtensionForFilter, targetPath: string): boolean {
  const target = canonicalPathForCompare(targetPath);
  return [ext.path, ext.resolvedPath].some(
    (candidate) => canonicalPathForCompare(candidate) === target,
  );
}

export function filterSdkLoadedExtensions<T extends LoadedExtensionForFilter>(
  extensions: T[],
  options: SdkExtensionFilterOptions,
): T[] {
  let filtered = extensions.filter((ext) => {
    if (ext.path.startsWith("<inline:")) return true;

    const name = getLoadedExtensionName(ext);
    if (isManagedExtensionName(name) || isBuiltInExtensionName(name)) {
      return false;
    }

    if (name !== PERMISSION_GATE_EXTENSION_NAME) {
      return true;
    }

    if (!options.permissionGateEnabled) {
      return false;
    }

    if (options.permissionGatePath) {
      return extensionPathMatches(ext, options.permissionGatePath);
    }

    return options.workspaceExtensions?.includes(PERMISSION_GATE_EXTENSION_NAME) ?? false;
  });

  if (options.workspaceExtensions !== undefined) {
    const allowed = new Set(options.workspaceExtensions);
    filtered = filtered.filter((ext) => {
      if (ext.path.startsWith("<inline:")) return true;

      const name = getLoadedExtensionName(ext);
      if (name === PERMISSION_GATE_EXTENSION_NAME && options.permissionGateEnabled) {
        return true;
      }

      return allowed.has(name);
    });
  }

  return filtered;
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

export function resolveSdkSessionCwd(workspace?: Workspace): string {
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

export function resolveSdkSessionDisplayCwd(workspace?: Workspace): string {
  if (workspace?.runtime === "sandbox") {
    return resolveSandboxGuestCwd(workspace);
  }
  return resolveSdkSessionCwd(workspace);
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

export interface BuiltInExtensionContext {
  storage: Storage;
  subagents: {
    context: SubagentsContext;
    childMode: boolean;
    subagentConfig: SubagentConfig;
  };
}

export interface SdkBackendConfig {
  session: Session;
  workspace?: Workspace;
  /** Called for SDK agent events and extension callback events. */
  onEvent: (event: SessionBackendEvent) => void;
  /** Called when the session ends. */
  onEnd: (reason: string) => void;
  /** Whether to keep the configured global host extension available. Default: true. */
  permissionGate?: boolean;
  /** Resolved skill directory paths for this workspace. */
  skillPaths?: string[];
  /** Session-scoped deps for Oppi built-in extensions. */
  builtInExtensionContext?: BuiltInExtensionContext;
  /** Additional extension factories injected for this session. */
  extraExtensionFactories?: ExtensionFactory[];
  /** Operational metrics collector for SDK timing. */
  metrics?: ServerMetricCollector;
}

const log = createLogger({ base: { component: "sdk_backend" } });

function createBuiltInExtensionFactories(
  workspace: Workspace | undefined,
  context: BuiltInExtensionContext | undefined,
): ExtensionFactory[] {
  if (!context) {
    return [];
  }

  const factories: ExtensionFactory[] = [];
  for (const name of BUILT_IN_EXTENSION_NAMES) {
    if (!isWorkspaceBuiltInExtensionEnabled(workspace, name)) {
      continue;
    }

    switch (name) {
      case "ask":
        factories.push(createAskFactory());
        break;
      case "subagents":
        factories.push(
          createSubagentsFactory(context.subagents.context, {
            childMode: context.subagents.childMode,
            subagentConfig: context.subagents.subagentConfig,
          }),
        );
        break;
      case "voice":
        factories.push(createVoiceFactory(context.storage));
        break;
      case "oppi-admin":
        factories.push(createOppiAdminFactory(context.storage));
        break;
    }
  }
  return factories;
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
  private shutdownCleanupCompleted = false;
  private readonly shutdownCleanupListeners = new Set<() => void>();
  private readonly sessionCwdExistsOverride?: string;
  private readonly sessionManagerDisplayCwd?: string;
  private disposed = false;

  private constructor(
    runtime: AgentSessionRuntime,
    emitEvent: (event: SessionBackendEvent) => void,
    cwdOverrides?: { existsCwd: string; displayCwd: string },
  ) {
    this.runtime = runtime;
    this.emitEvent = emitEvent;
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
    return this.runtime.services.modelRegistry;
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
    const initialHostCwd = resolveSdkSessionCwd(workspace);
    const initialCwd = resolveSdkSessionDisplayCwd(workspace);
    const sandboxMode = workspace?.runtime === "sandbox";
    const runtimeAssertCwd = sandboxMode ? initialHostCwd : initialCwd;
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
      const authStorage = AuthStorage.create(join(runtimeAgentDir, "auth.json"));
      const modelRegistry = ModelRegistry.create(authStorage, join(runtimeAgentDir, "models.json"));
      const settingsManager = SettingsManager.create(hostCwd, runtimeAgentDir);

      const shouldSeedFromSessionState = !sessionStartEvent;
      const model =
        shouldSeedFromSessionState && session.model
          ? resolveRegistryModel(modelRegistry, session.model)
          : undefined;
      if (shouldSeedFromSessionState && session.model && !model) {
        log.warn("sdk.model_resolve_defaulted", {
          model: session.model,
        });
      }

      // Build extension factories for Oppi-owned in-process tools.
      // Approval behavior stays in host extensions; SDK sessions load the
      // configured global host extension through the resource loader.
      const extensionFactories: ExtensionFactory[] = [];
      const usePermissionGate = config.permissionGate !== false;
      const permissionGateExtensionPath = usePermissionGate
        ? resolveGlobalPermissionGateExtensionPath(runtimeAgentDir)
        : undefined;
      if (usePermissionGate && !permissionGateExtensionPath) {
        log.warn("sdk.permission_gate_extension.missing", {
          agentDir: runtimeAgentDir,
        });
      }
      extensionFactories.push(
        ...createBuiltInExtensionFactories(workspace, config.builtInExtensionContext),
      );
      if (config.extraExtensionFactories) {
        extensionFactories.push(...config.extraExtensionFactories);
      }

      // Resource loader — suppress skill/theme auto-discovery, but keep
      // prompt templates enabled because Oppi exposes them as slash commands.
      // Built-in Oppi extensions are injected as in-process factories when the
      // workspace explicitly enables them. The configured global host extension
      // remains a normal Pi extension so approvals use native extension UI requests.
      const loader = new DefaultResourceLoader({
        cwd: hostCwd,
        agentDir: runtimeAgentDir,
        settingsManager,
        additionalExtensionPaths: permissionGateExtensionPath
          ? [permissionGateExtensionPath]
          : undefined,
        additionalSkillPaths: config.skillPaths ?? [],
        noSkills: true,
        noThemes: true,
        extensionFactories,
        appendSystemPrompt: workspace?.systemPrompt ? [workspace.systemPrompt] : undefined,
        ...(sandboxMode
          ? {
              systemPrompt: sandboxSystemPrompt(),
              agentsFilesOverride: (base: { agentsFiles: AgentContextFile[] }) => ({
                agentsFiles: base.agentsFiles.flatMap((file) => {
                  const guestPath = hostWorkspacePathToGuest(hostCwd, guestCwd, file.path);
                  if (!guestPath) return [];
                  return [
                    {
                      path: guestPath,
                      content: redactHostEnvironment(file.content, hostCwd, guestCwd),
                    },
                  ];
                }),
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
          : {}),
        extensionsOverride: (base) => {
          // Filter out names owned directly by oppi-server from host paths.
          // Built-ins are injected above as inline factories when enabled.
          // The configured global host extension is kept even when workspace.extensions
          // is an explicit allowlist, so users do not need to add it to every workspace.
          const allowedNames = workspace?.extensions;
          const filtered = filterSdkLoadedExtensions(base.extensions, {
            workspaceExtensions: allowedNames,
            permissionGateEnabled: usePermissionGate,
            permissionGatePath: permissionGateExtensionPath,
          });

          // Debug: log extension filtering
          const extNames = base.extensions.map(
            (ext) =>
              `${getLoadedExtensionName(ext)}(tools:${[...ext.tools.keys()].join(",") || "none"})`,
          );
          const filteredNames = filtered.map(
            (ext) =>
              `${getLoadedExtensionName(ext)}(tools:${[...ext.tools.keys()].join(",") || "none"})`,
          );
          if (process.env.DEBUG) {
            log.info("sdk.extensions_override_debug", {
              workspace: workspace?.name,
              input: extNames,
              errors: base.errors.map((e) => `${e.path}: ${e.error}`),
              allowlist: allowedNames,
              output: filteredNames,
            });
          }

          return { ...base, extensions: filtered };
        },
      });
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

      const workspaceTools = workspace?.tools?.length ? workspace.tools : undefined;
      const createResult = await createAgentSession({
        cwd: sessionCwd,
        agentDir: runtimeAgentDir,
        authStorage,
        modelRegistry,
        model,
        thinkingLevel: normalizeThinkingLevel(session.thinkingLevel),
        sessionManager,
        settingsManager,
        resourceLoader: loader,
        sessionStartEvent,
        // Sandbox: disable host-backed built-in tools and inject VM-backed
        // implementations as customTools. Do not use `tools: []` here: in pi SDK
        // that is an authoritative allowlist, so it filters out custom and
        // extension tools too, leaving the model with no tool-call capability.
        ...(sandboxTools ? { noTools: "builtin" as const, customTools: sandboxTools } : {}),
        ...(workspaceTools ? { tools: workspaceTools } : {}),
      });

      SdkBackend.applyDefaultQueueModes(createResult.session);

      return {
        ...createResult,
        services: {
          cwd: sessionCwd,
          agentDir: runtimeAgentDir,
          authStorage,
          settingsManager,
          modelRegistry,
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
      sandboxMode ? { existsCwd: runtimeAssertCwd, displayCwd: initialCwd } : undefined,
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
  }

  private async refreshRuntimeSessionBindings(): Promise<void> {
    this.subscribeToCurrentSession();
    await this.bindCurrentSessionExtensions();
  }

  private static applyDefaultQueueModes(
    session: Pick<AgentSession, "setSteeringMode" | "setFollowUpMode">,
  ): void {
    session.setSteeringMode(SdkBackend.DEFAULT_STEERING_MODE);
    session.setFollowUpMode(SdkBackend.DEFAULT_FOLLOW_UP_MODE);
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

    await this.runtime.services.resourceLoader.reload();
    await this.refreshRuntimeSessionBindings();
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
    const parsed = parseModelId(modelId);
    if (!parsed) {
      return { success: false, error: `Invalid model ID: ${modelId}` };
    }

    this.modelRegistry.refresh();
    const model = this.modelRegistry.find(parsed.provider, parsed.model);
    if (!model) {
      return { success: false, error: `Unknown model: ${modelId}` };
    }

    try {
      await this.piSession.setModel(model);

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
      autoCompaction: this.piSession.autoCompactionEnabled,
    };
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  get isStreaming(): boolean {
    return this.piSession.isStreaming;
  }

  get sessionFile(): string | undefined {
    return this.piSession.sessionFile;
  }

  get sessionId(): string {
    return this.piSession.sessionId;
  }

  onShutdownCleanupComplete(listener: () => void): void {
    if (this.shutdownCleanupCompleted) {
      try {
        listener();
      } catch (err: unknown) {
        log.error("sdk.shutdown_cleanup_listener.failed", {
          sessionId: this.piSession.sessionId,
          error: safeErrorMessage(err),
        });
      }
      return;
    }

    this.shutdownCleanupListeners.add(listener);
  }

  private flushShutdownCleanupListeners(): void {
    if (this.shutdownCleanupCompleted) {
      return;
    }

    this.shutdownCleanupCompleted = true;
    const listeners = [...this.shutdownCleanupListeners];
    this.shutdownCleanupListeners.clear();

    for (const listener of listeners) {
      try {
        listener();
      } catch (err: unknown) {
        log.error("sdk.shutdown_cleanup_listener.failed", {
          sessionId: this.piSession.sessionId,
          error: safeErrorMessage(err),
        });
      }
    }
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
      } finally {
        this.flushShutdownCleanupListeners();
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

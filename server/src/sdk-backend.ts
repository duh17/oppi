/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { randomUUID } from "node:crypto";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { basename, extname, join, resolve } from "node:path";

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
  type ExtensionUIDialogOptions,
  type ExtensionUIContext,
  SessionManager as PiSessionManager,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
} from "@mariozechner/pi-coding-agent";
import type { ImageContent } from "@mariozechner/pi-ai";

import type { GateServer } from "./gate.js";
import type {
  ExtensionAudioStreamEvent,
  ExtensionErrorEvent,
  ExtensionUIRequestEvent,
  PiStateSnapshot,
  SessionBackendEvent,
} from "./pi-events.js";
import { isFirstPartyExtensionName, isManagedExtensionName } from "../extensions/first-party.js";
import {
  getReloadableFirstPartyExtensionPaths,
  withReloadableFirstPartyExtensionContext,
  type ReloadableFirstPartyExtensionContext,
} from "./first-party-extension-runtime.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { AskQuestion, Session, Workspace } from "./types.js";

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

function getExtensionName(ext: { path: string; resolvedPath: string }): string {
  const file = basename(ext.resolvedPath || ext.path);
  const suffix = extname(file);
  return suffix ? file.slice(0, -suffix.length) : file;
}

type ExtensionAudioStreamInput = Omit<ExtensionAudioStreamEvent, "type">;

type OppiExtensionUIContext = ExtensionUIContext & {
  audioStream: (event: ExtensionAudioStreamInput) => void;
};

const MAX_EXTENSION_AUDIO_CHUNK_BASE64_BYTES = 512 * 1024;
const MAX_EXTENSION_AUDIO_TEXT_CHARS = 2_000;
const EXTENSION_AUDIO_MIME_TYPES = new Set<ExtensionAudioStreamEvent["mimeType"]>([
  "audio/wav",
  "audio/pcm; codecs=s16le",
]);

function validateExtensionAudioStreamEvent(
  event: ExtensionAudioStreamInput,
): ExtensionAudioStreamInput {
  if (event.kind !== "audio-stream") {
    throw new Error("audioStream kind must be audio-stream");
  }
  if (!event.id || event.id.length > 128) {
    throw new Error("audioStream id must be 1-128 characters");
  }
  if (!["metadata", "chunk", "done", "error"].includes(event.event)) {
    throw new Error("audioStream event must be metadata, chunk, done, or error");
  }
  if (!EXTENSION_AUDIO_MIME_TYPES.has(event.mimeType)) {
    throw new Error(`Unsupported audioStream MIME type: ${event.mimeType}`);
  }
  if (
    event.sampleRate !== undefined &&
    (!Number.isInteger(event.sampleRate) || event.sampleRate < 8_000 || event.sampleRate > 48_000)
  ) {
    throw new Error("audioStream sampleRate must be an integer between 8000 and 48000 Hz");
  }
  if (event.channels !== undefined && event.channels !== 1 && event.channels !== 2) {
    throw new Error("audioStream channels must be 1 or 2");
  }
  if (
    event.chunkIndex !== undefined &&
    (!Number.isInteger(event.chunkIndex) || event.chunkIndex < 0)
  ) {
    throw new Error("audioStream chunkIndex must be a non-negative integer");
  }
  if (
    event.durationSeconds !== undefined &&
    (!Number.isFinite(event.durationSeconds) || event.durationSeconds < 0)
  ) {
    throw new Error("audioStream durationSeconds must be a finite non-negative number");
  }
  if (event.audioBase64 !== undefined) {
    if (Buffer.byteLength(event.audioBase64, "utf8") > MAX_EXTENSION_AUDIO_CHUNK_BASE64_BYTES) {
      throw new Error("audioStream chunk exceeds 512KB base64 limit");
    }
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(event.audioBase64) || event.audioBase64.length % 4 !== 0) {
      throw new Error("audioStream audioBase64 must be valid base64");
    }
  }
  if (event.text !== undefined && event.text.length > MAX_EXTENSION_AUDIO_TEXT_CHARS) {
    throw new Error("audioStream text exceeds 2000 character limit");
  }
  return event;
}

/**
 * Resolve workspace host mount into an absolute SDK cwd.
 *
 * Workspace hostMount is stored in display form (commonly "~/...").
 * Node path APIs do not expand "~" and will treat it as a relative path,
 * producing cwd values like "<server-cwd>/~/workspace/...". Normalize here
 * before passing cwd into SDK components.
 */
export function resolveSdkSessionCwd(workspace?: Workspace): string {
  const rawHostMount = workspace?.hostMount?.trim();
  if (!rawHostMount) {
    if (workspace?.runtime === "sandbox") {
      // Auto-create a dedicated sandbox directory. Permanent, per-workspace.
      // Slug the name to a safe directory name, fall back to id.
      const slug =
        (workspace.name || workspace.id)
          .toLowerCase()
          .replace(/[^a-z0-9-_]/g, "-")
          .replace(/-+/g, "-")
          .replace(/^-|-$/g, "") || workspace.id;
      const sandboxDir = join(homedir(), "sandbox", slug);
      mkdirSync(sandboxDir, { recursive: true });
      return sandboxDir;
    }
    return homedir();
  }

  const expanded =
    rawHostMount === "~" || rawHostMount.startsWith("~/")
      ? rawHostMount.replace(/^~(?=\/|$)/, homedir())
      : rawHostMount;

  return resolve(expanded);
}

export interface SdkBackendConfig {
  session: Session;
  workspace?: Workspace;
  /** Called for SDK agent events and extension callback events. */
  onEvent: (event: SessionBackendEvent) => void;
  /** Called when the session ends. */
  onEnd: (reason: string) => void;
  /** Gate server for permission checks. */
  gate?: GateServer;
  /** Workspace ID for gate guard registration. */
  workspaceId?: string;
  /** Whether to enable the permission gate. Default: true if gate is provided. */
  permissionGate?: boolean;
  /** Resolved skill directory paths for this workspace. */
  skillPaths?: string[];
  /** Session-scoped deps for Oppi's reloadable first-party extensions. */
  reloadableFirstPartyExtensionContext?: ReloadableFirstPartyExtensionContext;
  /** Additional extension factories injected for this session. */
  extraExtensionFactories?: ExtensionFactory[];
  /** Operational metrics collector for SDK timing. */
  metrics?: ServerMetricCollector;
}

interface ExtensionUIResponsePayload {
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface PendingExtensionUIResponse {
  resolve: (response: ExtensionUIResponsePayload) => void;
  cancel: () => void;
}

interface AskUIResult {
  answers: Record<string, string | string[]>;
  allIgnored: boolean;
}

function invalidAskResponse(message: string): Error {
  return new Error(`Malformed ask response: ${message}`);
}

function normalizeAskAnswers(value: string): Record<string, string | string[]> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw invalidAskResponse(error instanceof Error ? error.message : String(error));
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw invalidAskResponse("expected a JSON object");
  }

  const answers: Record<string, string | string[]> = {};
  for (const [key, answer] of Object.entries(parsed)) {
    if (typeof answer === "string") {
      answers[key] = answer;
      continue;
    }

    if (Array.isArray(answer) && answer.every((item) => typeof item === "string")) {
      answers[key] = answer;
      continue;
    }

    throw invalidAskResponse(`expected string or string[] for "${key}"`);
  }

  return answers;
}

interface CustomUIComponent {
  render: (width: number) => string[];
  handleInput?: (data: string) => void;
  invalidate?: () => void;
  dispose?: () => void;
}

type CustomUIControl = "up" | "down" | "enter" | "type" | "cancel";

const CUSTOM_UI_COMPAT_TITLE = "Extension (TUI compatibility mode)";
const CUSTOM_UI_COMPAT_WIDTH = 88;
const CUSTOM_UI_COMPAT_MAX_LINES = 28;
const CUSTOM_UI_COMPAT_MAX_MESSAGE_CHARS = 6_000;
const CUSTOM_UI_COMPAT_MAX_STEPS = 200;
const CUSTOM_UI_COMPAT_TIMEOUT_MS = 5 * 60_000;
const CUSTOM_UI_COMPAT_WIDGET_MAX_LINES = 8;
const CUSTOM_UI_COMPAT_TYPE_PROMPT = "Type text for extension UI";
const CUSTOM_UI_COMPAT_CONTROL_OPTIONS = [
  "↑ Up",
  "↓ Down",
  "⏎ Enter",
  "Type text…",
  "Cancel",
] as const;

const CUSTOM_UI_COMPAT_CONTROL_INPUT: Record<
  Exclude<CustomUIControl, "type" | "cancel">,
  string
> = {
  up: "__OPPI_TUI_UP__",
  down: "__OPPI_TUI_DOWN__",
  enter: "__OPPI_TUI_ENTER__",
};

const log = createLogger({ base: { component: "sdk_backend" } });

function decodeCustomUIControlOption(option: string | undefined): CustomUIControl | undefined {
  switch (option) {
    case "↑ Up":
      return "up";
    case "↓ Down":
      return "down";
    case "⏎ Enter":
      return "enter";
    case "Type text…":
      return "type";
    case "Cancel":
      return "cancel";
    default:
      return undefined;
  }
}

function stripAnsiCodes(input: string): string {
  let output = "";
  let skippingAnsi = false;

  for (let i = 0; i < input.length; i++) {
    const char = input[i];

    if (!skippingAnsi && char === "\u001b" && input[i + 1] === "[") {
      skippingAnsi = true;
      i += 1;
      continue;
    }

    if (skippingAnsi) {
      if (char === "m") {
        skippingAnsi = false;
      }
      continue;
    }

    output += char;
  }

  return output;
}

function renderCustomUIMessage(component: CustomUIComponent): string {
  let lines: string[];

  try {
    lines = component.render(CUSTOM_UI_COMPAT_WIDTH);
  } catch (error) {
    const reason = safeErrorMessage(error);
    lines = [`[render error] ${reason}`];
  }

  const safeLines = lines.map((line) => stripAnsiCodes(line));
  const limited = safeLines.slice(0, CUSTOM_UI_COMPAT_MAX_LINES);
  if (safeLines.length > CUSTOM_UI_COMPAT_MAX_LINES) {
    limited.push(`… (${safeLines.length - CUSTOM_UI_COMPAT_MAX_LINES} more lines)`);
  }

  const intro = [
    "This extension requested a keyboard-driven TUI component.",
    "Use the controls below to navigate and submit.",
    "",
  ];

  const combined = [...intro, ...limited].join("\n");
  if (combined.length <= CUSTOM_UI_COMPAT_MAX_MESSAGE_CHARS) {
    return combined;
  }

  return `${combined.slice(0, CUSTOM_UI_COMPAT_MAX_MESSAGE_CHARS)}\n…`;
}

function renderWidgetSnapshotLines(component: CustomUIComponent): string[] {
  let lines: string[];

  try {
    lines = component.render(CUSTOM_UI_COMPAT_WIDTH);
  } catch (error) {
    lines = [`[render error] ${safeErrorMessage(error)}`];
  }

  const safeLines = lines
    .map((line) => stripAnsiCodes(line).trimEnd())
    .filter((line) => line.length > 0);

  const limited = safeLines.slice(0, CUSTOM_UI_COMPAT_WIDGET_MAX_LINES);
  if (safeLines.length > CUSTOM_UI_COMPAT_WIDGET_MAX_LINES) {
    limited.push(`… (${safeLines.length - CUSTOM_UI_COMPAT_WIDGET_MAX_LINES} more lines)`);
  }

  return limited;
}

function createCustomUICompatTheme(): ExtensionUIContext["theme"] {
  const passthrough = (value: string): string => value;

  return {
    fg: (_color: unknown, text: string): string => text,
    bg: (_color: unknown, text: string): string => text,
    bold: passthrough,
    dim: passthrough,
    italic: passthrough,
    underline: passthrough,
    inverse: passthrough,
    gray: (_level: unknown, text: string): string => text,
    hex: (_hex: unknown, text: string): string => text,
    rgb: (_r: unknown, _g: unknown, _b: unknown, text: string): string => text,
    parseInline: passthrough,
  } as unknown as ExtensionUIContext["theme"];
}

function createCustomUICompatKeybindings(): {
  matches: (data: string, keybinding: string) => boolean;
} {
  return {
    matches: (data: string, keybinding: string) => {
      switch (keybinding) {
        case "tui.select.up":
          return data === CUSTOM_UI_COMPAT_CONTROL_INPUT.up;
        case "tui.select.down":
          return data === CUSTOM_UI_COMPAT_CONTROL_INPUT.down;
        case "tui.select.confirm":
          return data === CUSTOM_UI_COMPAT_CONTROL_INPUT.enter;
        case "tui.select.cancel":
          return data === "\u001b";
        default:
          return false;
      }
    },
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
export class SdkBackend {
  private static readonly DEFAULT_STEERING_MODE = "all" as const;
  private static readonly DEFAULT_FOLLOW_UP_MODE = "one-at-a-time" as const;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private static _gondolinManager: any;

  private runtime: AgentSessionRuntime;
  private unsub: (() => void) | null = null;
  private readonly emitEvent: (event: SessionBackendEvent) => void;
  private readonly pendingExtensionResponses = new Map<string, PendingExtensionUIResponse>();
  private shutdownCleanupPromise: Promise<void> | null = null;
  private shutdownCleanupCompleted = false;
  private readonly shutdownCleanupListeners = new Set<() => void>();
  private disposed = false;

  private constructor(
    runtime: AgentSessionRuntime,
    emitEvent: (event: SessionBackendEvent) => void,
  ) {
    this.runtime = runtime;
    this.emitEvent = emitEvent;
    this.subscribeToCurrentSession();
  }

  private get piSession(): AgentSession {
    return this.runtime.session;
  }

  private get modelRegistry(): ModelRegistry {
    return this.runtime.services.modelRegistry;
  }

  private static createPiSessionManager(session: Session, cwd: string): PiSessionManager {
    const piSessionFile = session.piSessionFile;
    if (session.ephemeral) {
      return PiSessionManager.inMemory(cwd);
    }
    return piSessionFile ? PiSessionManager.open(piSessionFile) : PiSessionManager.create(cwd);
  }

  static async create(config: SdkBackendConfig): Promise<SdkBackend> {
    const createStartMs = Date.now();
    const { session, workspace, onEvent, onEnd: _onEnd } = config;
    const initialCwd = resolveSdkSessionCwd(workspace);
    const agentDir = getAgentDir();
    const initialSessionManager = SdkBackend.createPiSessionManager(session, initialCwd);

    const createRuntimeFactory: CreateAgentSessionRuntimeFactory = async ({
      cwd,
      agentDir: runtimeAgentDir,
      sessionManager,
      sessionStartEvent,
    }) => {
      const authStorage = AuthStorage.create(join(runtimeAgentDir, "auth.json"));
      const modelRegistry = ModelRegistry.create(authStorage, join(runtimeAgentDir, "models.json"));
      const settingsManager = SettingsManager.create(cwd, runtimeAgentDir);

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

      // Build extension factories for in-process tools
      const extensionFactories: ExtensionFactory[] = [];
      const useGate = config.gate && config.permissionGate !== false;
      if (useGate && config.gate) {
        extensionFactories.push(
          createPermissionGateFactory(config.gate, session.id, config.workspaceId || "", cwd),
        );
      }
      if (config.extraExtensionFactories) {
        extensionFactories.push(...config.extraExtensionFactories);
      }

      const firstPartyExtensionPaths = getReloadableFirstPartyExtensionPaths();

      // Resource loader — suppress skill/prompt/theme auto-discovery, but keep
      // file-based extensions so /reload can re-import Oppi's first-party ones.
      // Extension factories (permission gate + temporary pending factories) are
      // still injected here.
      // Pi's auto-discovered permission-gate extension is filtered out since
      // oppi has its own policy engine (GateServer). Without this, both gates
      // run and the pi extension blocks commands it considers "dangerous" with
      // no UI to approve them (ctx.hasUI is false in oppi sessions).
      const workspaceSystemPromptMode = workspace?.systemPromptMode ?? "append";
      const loader = new DefaultResourceLoader({
        cwd,
        agentDir: runtimeAgentDir,
        settingsManager,
        additionalExtensionPaths: firstPartyExtensionPaths,
        additionalSkillPaths: config.skillPaths ?? [],
        noSkills: true,
        noPromptTemplates: true,
        noThemes: true,
        extensionFactories,
        systemPrompt: workspaceSystemPromptMode === "replace" ? workspace?.systemPrompt : undefined,
        appendSystemPrompt:
          workspaceSystemPromptMode === "append" && workspace?.systemPrompt
            ? [workspace.systemPrompt]
            : undefined,
        extensionsOverride: (base) => {
          // 1. Filter out extensions managed directly by oppi-server.
          //    permission-gate is replaced by oppi's own policy engine.
          //    ask, voice, and subagents stay file-based so /reload can re-import them.
          let filtered = base.extensions.filter(
            (ext) => !isManagedExtensionName(getExtensionName(ext)),
          );

          // 2. If the workspace specifies an extensions allowlist, that allowlist is
          //    authoritative. Always keep inline factory extensions (path "<inline:N>")
          //    because they're injected programmatically by the server.
          const allowedNames = workspace?.extensions;
          if (allowedNames !== undefined) {
            const allowed = new Set(allowedNames);
            filtered = filtered.filter((ext) => {
              if (ext.path.startsWith("<inline:")) return true;
              return allowed.has(getExtensionName(ext));
            });
          } else {
            // 3. Without an explicit allowlist, keep normal pi discovery intact but
            //    leave Oppi-owned extension names off unless the workspace opted in.
            filtered = filtered.filter((ext) => {
              const name = getExtensionName(ext);
              if (!isFirstPartyExtensionName(name)) {
                return true;
              }
              return false;
            });
          }

          // Debug: log extension filtering
          const extNames = base.extensions.map(
            (ext) => `${getExtensionName(ext)}(tools:${[...ext.tools.keys()].join(",") || "none"})`,
          );
          const filteredNames = filtered.map(
            (ext) => `${getExtensionName(ext)}(tools:${[...ext.tools.keys()].join(",") || "none"})`,
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
      const firstPartyExtensionContext = config.reloadableFirstPartyExtensionContext;
      if (firstPartyExtensionContext) {
        const reloadWithContext = loader.reload.bind(loader);
        loader.reload = () =>
          withReloadableFirstPartyExtensionContext(firstPartyExtensionContext, reloadWithContext);
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

        // Extract LLM provider API keys as secrets for host-mediated injection.
        // The VM gets placeholder values; real keys are injected by the host HTTP proxy.
        const secrets: Record<string, { value: string; headerName?: string }> = {};
        try {
          const allCreds = authStorage.getAll();
          for (const [provider, cred] of Object.entries(allCreds)) {
            if (cred.type === "api_key" && cred.key) {
              secrets[`${provider.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_API_KEY`] = {
                value: cred.key,
                headerName: "Authorization",
              };
            }
          }
        } catch {
          // Auth extraction failed — proceed without secrets
        }

        // Mount specific subdirectories read-only so the agent can read
        // SKILL.md files and extensions at the paths referenced in the system prompt.
        // Do NOT mount agentDir itself — it contains auth.json (API keys).
        const readonlyMounts: string[] = [];
        if (config.skillPaths) {
          readonlyMounts.push(...config.skillPaths);
        }
        // Mount only safe subdirectories, not the whole agentDir.
        // skills/ is already covered by skillPaths above.
        // extensions/ is needed for loaded extensions to resolve their own files.
        const extensionsDir = join(runtimeAgentDir, "extensions");
        if (existsSync(extensionsDir)) {
          readonlyMounts.push(extensionsDir);
        }

        const extraEnv = workspace.sandboxConfig?.env;
        const vm = await manager.ensureWorkspaceVm(
          workspace,
          cwd,
          secrets,
          readonlyMounts,
          extraEnv,
        );

        sandboxTools = [
          createReadToolDefinition(cwd, { operations: createGondolinReadOps(vm, cwd) }),
          createBashToolDefinition(cwd, { operations: createGondolinBashOps(vm, cwd) }),
          createEditToolDefinition(cwd, { operations: createGondolinEditOps(vm, cwd) }),
          createWriteToolDefinition(cwd, { operations: createGondolinWriteOps(vm, cwd) }),
        ];
        log.info("sdk.sandbox_vm_ready", { workspaceId: workspace.id || "unknown" });
      }

      const createResult = await createAgentSession({
        cwd,
        agentDir: runtimeAgentDir,
        authStorage,
        modelRegistry,
        model,
        sessionManager,
        settingsManager,
        resourceLoader: loader,
        sessionStartEvent,
        // Sandbox: disable all built-in tools (tools: []) and inject VM-backed
        // implementations as customTools. This ensures bash/read/write/edit execute
        // inside the Gondolin VM, not on the host.
        ...(sandboxTools ? { tools: [], customTools: sandboxTools } : {}),
      });

      SdkBackend.applyDefaultQueueModes(createResult.session);

      return {
        ...createResult,
        services: {
          cwd,
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
      cwd: initialCwd,
      agentDir,
      sessionManager: initialSessionManager,
    });

    const backend = new SdkBackend(runtime, onEvent);

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

  private emitExtensionUIRequest(request: Omit<ExtensionUIRequestEvent, "type">): void {
    this.emitEvent({
      type: "extension_ui_request",
      ...request,
    });
  }

  private createDialogPromise<T>(
    opts: ExtensionUIDialogOptions | undefined,
    defaultValue: T,
    request: Omit<ExtensionUIRequestEvent, "type" | "id">,
    parseResponse: (response: ExtensionUIResponsePayload) => T,
  ): Promise<T> {
    if (this.disposed || opts?.signal?.aborted) {
      return Promise.resolve(defaultValue);
    }

    const id = randomUUID();

    return new Promise<T>((resolve, reject) => {
      let timeoutId: NodeJS.Timeout | undefined;

      const cleanup = (): void => {
        if (timeoutId) {
          clearTimeout(timeoutId);
        }
        opts?.signal?.removeEventListener("abort", onAbort);
        this.pendingExtensionResponses.delete(id);
        this.emitEvent({ type: "extension_ui_request_settled", id });
      };

      const cancel = (): void => {
        cleanup();
        resolve(defaultValue);
      };

      const onAbort = (): void => {
        cancel();
      };

      opts?.signal?.addEventListener("abort", onAbort, { once: true });

      if (opts?.timeout) {
        timeoutId = setTimeout(() => {
          cancel();
        }, opts.timeout);
      }

      this.pendingExtensionResponses.set(id, {
        resolve: (response) => {
          cleanup();
          try {
            resolve(parseResponse(response));
          } catch (error) {
            reject(error);
          }
        },
        cancel,
      });

      this.emitExtensionUIRequest({
        id,
        ...request,
        timeout: opts?.timeout,
        timeoutAt: opts?.timeout ? Date.now() + opts.timeout : undefined,
      });
    });
  }

  private async runCustomUICompatibility<T>(
    factory: (
      tui: unknown,
      theme: ExtensionUIContext["theme"],
      keybindings: unknown,
      done: (result: T) => void,
    ) => CustomUIComponent | Promise<CustomUIComponent>,
  ): Promise<T> {
    if (this.disposed) {
      return undefined as T;
    }

    let resolved = false;
    let resolvedValue: T | undefined;

    const done = (value: T): void => {
      resolved = true;
      resolvedValue = value;
    };

    const tui = {
      requestRender: () => {
        // Render is polled after each control action.
      },
    };

    const theme = createCustomUICompatTheme();
    const keybindings = createCustomUICompatKeybindings();

    const component = await factory(tui, theme, keybindings, done);

    try {
      for (let step = 0; step < CUSTOM_UI_COMPAT_MAX_STEPS; step++) {
        if (resolved) {
          return resolvedValue as T;
        }

        if (this.disposed) {
          return undefined as T;
        }

        const control = await this.createDialogPromise<CustomUIControl | undefined>(
          { timeout: CUSTOM_UI_COMPAT_TIMEOUT_MS },
          undefined,
          {
            method: "select",
            title: CUSTOM_UI_COMPAT_TITLE,
            message: renderCustomUIMessage(component),
            options: [...CUSTOM_UI_COMPAT_CONTROL_OPTIONS],
          },
          (response) => {
            if (response.cancelled) {
              return undefined;
            }
            return decodeCustomUIControlOption(response.value);
          },
        );

        if (!control || control === "cancel") {
          return undefined as T;
        }

        if (control === "type") {
          const typed = await this.createDialogPromise<string | undefined>(
            { timeout: CUSTOM_UI_COMPAT_TIMEOUT_MS },
            undefined,
            {
              method: "input",
              title: CUSTOM_UI_COMPAT_TYPE_PROMPT,
              placeholder: "type and submit",
            },
            (response) => (response.cancelled ? undefined : response.value),
          );

          if (typed) {
            for (const char of typed) {
              component.handleInput?.(char);
              if (resolved) {
                return resolvedValue as T;
              }
            }
          }

          continue;
        }

        component.handleInput?.(CUSTOM_UI_COMPAT_CONTROL_INPUT[control]);
      }

      this.emitExtensionUIRequest({
        id: randomUUID(),
        method: "notify",
        notifyType: "warning",
        message:
          "TUI compatibility mode hit the interaction limit before completion. Try again with a more direct extension command.",
      });

      return undefined as T;
    } finally {
      component.dispose?.();
    }
  }

  private createExtensionUIContext(): ExtensionUIContext {
    const context = {
      ask: (questions: AskQuestion[], allowCustom = true, opts?: ExtensionUIDialogOptions) => {
        if (!Array.isArray(questions) || questions.length === 0) {
          return Promise.reject(new Error("ask UI requires at least one question"));
        }

        return this.createDialogPromise<AskUIResult>(
          opts,
          { answers: {}, allIgnored: true },
          { method: "ask", questions, allowCustom },
          (response) => {
            if (response.cancelled || !response.value) {
              return { answers: {}, allIgnored: true };
            }

            const answers = normalizeAskAnswers(response.value);
            return {
              answers,
              allIgnored: Object.keys(answers).length === 0,
            };
          },
        );
      },

      select: (title, options, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "select", title, options },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      confirm: (title, message, opts) =>
        this.createDialogPromise(opts, false, { method: "confirm", title, message }, (response) =>
          response.cancelled ? false : (response.confirmed ?? false),
        ),

      input: (title, placeholder, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "input", title, placeholder },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      notify: (message, type) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "notify",
          message,
          notifyType: type,
        });
      },

      onTerminalInput: () => () => {
        // Raw terminal input is not supported in Oppi server sessions.
      },

      setStatus: (key, text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setStatus",
          statusKey: key,
          statusText: text,
        });
      },

      setWorkingMessage: (_message) => {
        // Working message requires TUI access; unsupported in Oppi sessions.
      },

      setWorkingIndicator: (_options) => {
        // Working indicator customization requires TUI access; unsupported in Oppi sessions.
      },

      setWidget: (key, content, options) => {
        if (content === undefined || Array.isArray(content)) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: content,
            widgetPlacement: options?.placement,
          });
          return;
        }

        try {
          const component = content(
            { requestRender: () => {} } as never,
            createCustomUICompatTheme() as never,
          ) as CustomUIComponent;
          const lines = renderWidgetSnapshotLines(component);
          component.dispose?.();

          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: lines,
            widgetPlacement: options?.placement,
          });
        } catch (error) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "notify",
            notifyType: "warning",
            message: `Failed to render extension widget: ${safeErrorMessage(error)}`,
          });
        }
      },

      setFooter: (_factory) => {
        // Custom footer requires TUI access; unsupported in Oppi sessions.
      },

      setHeader: (_factory) => {
        // Custom header requires TUI access; unsupported in Oppi sessions.
      },

      setTitle: (title) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setTitle",
          title,
        });
      },

      custom: async <T>(
        factory: (
          tui: unknown,
          theme: ExtensionUIContext["theme"],
          keybindings: unknown,
          done: (result: T) => void,
        ) => CustomUIComponent | Promise<CustomUIComponent>,
      ) => {
        try {
          return await this.runCustomUICompatibility<T>(factory);
        } catch (error) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "notify",
            notifyType: "warning",
            message: `Extension custom UI failed: ${safeErrorMessage(error)}`,
          });
          throw error;
        }
      },

      pasteToEditor: (text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "set_editor_text",
          text,
        });
      },

      setEditorText: (text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "set_editor_text",
          text,
        });
      },

      getEditorText: () => {
        return "";
      },

      editor: (title, prefill) =>
        this.createDialogPromise(
          undefined,
          undefined,
          { method: "editor", title, prefill },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      addAutocompleteProvider: (_factory) => {
        // Autocomplete provider stacking requires TUI access; unsupported in Oppi sessions.
      },

      setEditorComponent: (_factory) => {
        // Custom editor components require TUI access; unsupported in Oppi sessions.
      },

      get theme() {
        return {} as ExtensionUIContext["theme"];
      },

      getAllThemes: () => [],

      getTheme: (_name) => undefined,

      setTheme: (_theme) => ({
        success: false,
        error: "Theme switching not supported in Oppi sessions",
      }),

      getToolsExpanded: () => false,

      setToolsExpanded: (_expanded) => {
        // Tool expansion requires TUI access; unsupported in Oppi sessions.
      },

      setHiddenThinkingLabel: (_label) => {
        // Thinking label customization requires TUI; unsupported in Oppi sessions.
      },
    } as ExtensionUIContext;

    const oppiContext = context as OppiExtensionUIContext;
    oppiContext.audioStream = (event) => {
      this.emitEvent({
        type: "extension_audio_stream",
        ...validateExtensionAudioStreamEvent(event),
      });
    };
    return oppiContext;
  }

  respondToExtensionUIRequest(response: ExtensionUIResponsePayload): boolean {
    const pending = this.pendingExtensionResponses.get(response.id);
    if (!pending) {
      return false;
    }

    pending.resolve(response);
    return true;
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const parentSession = this.piSession.sessionFile;
    const result = await this.runtime.newSession({ parentSession });
    if (!result.cancelled) {
      await this.refreshRuntimeSessionBindings();
    }
    return result;
  }

  async switchSession(sessionPath: string): Promise<{ cancelled: boolean }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const result = await this.runtime.switchSession(sessionPath);
    if (!result.cancelled) {
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

    for (const pending of this.pendingExtensionResponses.values()) {
      pending.cancel();
    }
    this.pendingExtensionResponses.clear();

    this.unsub?.();
    this.unsub = null;

    await this.startShutdownCleanup();
  }
}

// ─── In-Process Permission Gate Extension Factory ───

/**
 * Create an ExtensionFactory that gates tool calls through GateServer.
 * Runs in-process — every tool call is evaluated by the policy engine.
 */
function createPermissionGateFactory(
  gate: GateServer,
  sessionId: string,
  workspaceId: string,
  sessionCwd: string,
): ExtensionFactory {
  return (extensionApi: unknown) => {
    const pi = extensionApi as {
      on(
        event: "tool_call",
        handler: (event: {
          toolName: string;
          toolCallId: string;
          input: Record<string, unknown>;
        }) => Promise<{ block: true; reason: string } | void>,
      ): void;
      on(event: "session_shutdown", handler: () => void): void;
    };

    // Register guard for this session.
    gate.createGuard(sessionId, workspaceId);
    log.info("sdk.gate_guard.registered", {
      sessionId,
      workspaceId,
    });

    // Gate every tool call through the policy engine
    pi.on(
      "tool_call",
      async (event: { toolName: string; toolCallId: string; input: Record<string, unknown> }) => {
        const result = await gate.checkToolCall(sessionId, {
          tool: event.toolName,
          input: event.input,
          toolCallId: event.toolCallId,
          sessionCwd,
        });

        if (result.action === "deny") {
          return { block: true, reason: result.reason || "Denied by permission gate" };
        }

        // Allow — return void, tool executes normally
      },
    );

    // Clean up on shutdown
    pi.on("session_shutdown", () => {
      gate.destroySessionGuard(sessionId);
      log.info("sdk.gate_guard.destroyed", {
        sessionId,
      });
    });
  };
}

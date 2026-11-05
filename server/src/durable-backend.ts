import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
  ModelRegistry,
  SettingsManager,
  getAgentDir,
  hasTrustRequiringProjectResources,
  type ModelRuntime,
  type CompactionResult,
} from "@earendil-works/pi-coding-agent";
import {
  AgentDoc,
  InboxDoc,
  LiveDoc,
  type AgentChange,
  type ModelRef,
  type Conversation,
  type Harness,
  type ConversationId,
  type AgentState,
  type LiveState,
  type InboxState,
  type UsageState,
  type EntryRecord,
  CompactionEntry,
  ResetEntry,
} from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { getCurrentSystemPrompt } from "@earendil-works/pi-ai/utils/transcript";
import { computeCacheWaste } from "./cache-miss.js";
import {
  addUsageToModelBreakdown,
  estimateTokensFromChars,
  estimateToolDeclarationTokens,
  sortedModelUsage,
  TOOLS_SUMMARIES_USAGE_KEY,
  TOOLS_SUMMARIES_USAGE_LABEL,
  type ContextToolSnapshot,
  type ContextToolSource,
  type SessionModelUsageSnapshot,
} from "./session-stats.js";
import { durableUnsupportedFeature, type AgentDefinition } from "./agent-launch-service.js";
import {
  OppiAgentDoc,
  piDefaultTools,
  resolveDurableAgent,
  toolAllowed,
  type OppiAgentState,
} from "./durable-agent.js";
import type { AgentBackend } from "./agent-backend.js";
import { isControlConversation } from "./control-session.js";
import { readRequestDisplay, type DurableAgentController } from "./durable-agent-controller.js";
import { controlConversationTools } from "./durable-control-conversation.js";
import { DurableRuntime, type SessionHost } from "./durable-harness.js";
import { DurableSessionDoc } from "./durable-session-doc.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import { readDurableInputCards } from "./durable-input-cards.js";
import { DurableClassicEvents } from "./durable-classic-events.js";
import { exportDurableToHtml } from "./durable-export.js";
import { isRecoveredPartial, readDurableSessionEntries } from "./durable-history.js";
import { splitCanonicalModelId } from "./model-resolution.js";
import type { PiMessage, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import type { SdkBackendDisposeResult } from "./sdk-backend.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";
import {
  SdkBackend,
  resolveSessionSeedModel,
  resolveSdkSessionCwdAsync,
  toCommandLocation,
  type QueuedModelTurnBatch,
} from "./sdk-backend.js";
import {
  DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS,
  type RevisionedEnabled,
} from "./settings/config-settings.js";
import {
  dropInstructionsWorkspacePrompt,
  syncProjectContext,
  type PresentedResources,
} from "./durable-prompt-sections.js";
import { oppiAppendSystemPrompt } from "./oppi-docs.js";
import { resolveSandboxGuestCwd } from "./workspace-folder.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "./session-runtime-transaction.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import type { MessageQueueState, ServerConfig, Session, Workspace } from "./types.js";
import {
  DURABLE_QUEUE_REQUEST_ID_PREFIX,
  DURABLE_RESERVED_REQUEST_ID_PREFIXES,
} from "./durable-request-ids.js";
import {
  DURABLE_FAILURE_ENTRY_KIND,
  reconcileFailureCards,
  recordRunFailureCard,
  runFailureText,
  recordTaskFailure,
} from "./durable-failure-cards.js";
import { sanitizeTranscriptCard } from "./durable-ui.js";
import {
  WORKING_WORDS_EXTENSION,
  WORKING_WORDS_TASK,
  ensureWorkingWords,
} from "../plugins/working-words/contract.js";
import {
  SUBAGENT_WIDGET_TASK,
  Subagents,
  ensureSubagentWidget,
} from "../plugins/subagents/contract.js";
import { DurableUIProjection } from "./durable-ui-projection.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import { DurableMcp } from "./durable-mcp.js";
import { sandboxMcpForWorkspace } from "./sandbox-mcp.js";
import { expandSkillCommand, loadDurableProjectResources } from "./durable-project-resources.js";
import { ProjectContextDoc } from "../plugins/project-context/contract.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { managedProjectTrustContext, resolveManagedProjectTrust } from "./project-trust.js";
import { SdkUiBridge } from "./sdk-ui-bridge.js";
import { MAIN_WORKTREE_ID } from "./worktrees.js";

const log = createLogger({ base: { component: "durable-backend" } });

export class DurableNotSupportedError extends Error {
  readonly code = "server_durable_not_supported";
  constructor(readonly operation: string) {
    super(`${operation} is not supported for server durable sessions`);
    this.name = "DurableNotSupportedError";
  }
}

interface DurableBackendOptions {
  harness: Harness;
  host: SessionHost;
  models: ModelRuntime;
  session: Session;
  workspace?: Workspace;
  agentDefinition?: AgentDefinition;
  dataDir: string;
  persistBinding: () => void;
  onEvent: (event: SessionBackendEvent) => void;
  /** Startup dialogs (project trust) before the projection exists, as for SDK sessions. */
  onUIBridgeReady?: (bridge: SdkUiBridge | undefined) => void;
  metrics?: ServerTelemetry;
  hasUI?: () => boolean;
  /** Server settings that gate Oppi's prompt appends, as for SDK sessions. */
  serverConfig?: Pick<ServerConfig, "oppiDocsPrompt" | "oppiCliPrompt">;
  /** Read on every attach and `/reload`, as an SDK session reads it per runtime rebuild. */
  getMobileOutputGuideSettings?: () => RevisionedEnabled;
}

/**
 * Gates project MCP servers, settings, and Skills. Same decision as an SDK session start:
 * nothing to gate is trusted; otherwise trust extensions, the remembered answer,
 * `defaultProjectTrust`, then a bounded phone dialog.
 */
async function resolveProjectTrust(
  cwd: string,
  agentDir: string,
  options: DurableBackendOptions,
): Promise<boolean> {
  if (!hasTrustRequiringProjectResources(cwd)) return true;
  const bridge = new SdkUiBridge(options.onEvent, () => false);
  options.onUIBridgeReady?.(bridge);
  try {
    return await resolveManagedProjectTrust(
      cwd,
      agentDir,
      SettingsManager.create(cwd, agentDir, { projectTrusted: false }),
      managedProjectTrustContext(cwd, options.hasUI?.() ?? false, bridge.createContext()),
      (extensionPath, error) =>
        options.onEvent({
          type: "extension_error",
          extensionPath,
          event: "project_trust",
          error: safeErrorMessage(error),
        }),
    );
  } finally {
    options.onUIBridgeReady?.(undefined);
  }
}

/** What a session runs as. */
interface LaunchedAs {
  /** Its `oppi.agent` document; undefined for a conversation created before the document existed. */
  doc: OppiAgentState | undefined;
  /** It may use `subagent spawn`. */
  spawn: boolean;
  /** For the conversation this attach creates: the resolved agent and document. */
  created?: ReturnType<typeof resolveDurableAgent>;
}

/**
 * The saved Agent's Extensions this session runs without, as a session warning like the classic
 * dropped-tools one: it is stored with the session, so a launch nobody watched still shows it.
 */
function recordSkippedExtensionsWarning(session: Session, skipped: readonly string[]): void {
  const warning = `Selected Agent Extensions are not loaded in this durable session (no durable version, or turned off with oppi extensions disable): ${skipped.join(", ")}. Edit the Agent's selected Extensions, or start it Classic, to use them.`;
  if (session.warnings?.includes(warning)) return;
  session.warnings = [...(session.warnings ?? []), warning];
  log.warn("durable_agent.extensions_skipped", {
    sessionId: session.id,
    agentId: session.launch?.agentId,
    skipped: [...skipped],
  });
}

/** The model and thinking level a new conversation starts with: the session's, else Pi's defaults. */
function seedModel(
  models: ModelRuntime,
  hostCwd: string,
  session: Session,
): { model: ModelRef; thinkingLevel?: ThinkingLevel } {
  const registry = new ModelRegistry(models);
  const settings = SettingsManager.create(hostCwd, getAgentDir(), { projectTrusted: false });
  const defaultModel =
    settings.getDefaultProvider() && settings.getDefaultModel()
      ? `${settings.getDefaultProvider()}/${settings.getDefaultModel()}`
      : undefined;
  const first = registry.getAvailable()[0];
  const model = resolveSessionSeedModel(
    registry,
    session.model ?? defaultModel ?? (first ? `${first.provider}/${first.id}` : ""),
    settings.getEnabledModels(),
  );
  if (!model) throw new Error(`Server durable model is unavailable: ${session.model ?? "default"}`);
  const thinkingLevel =
    session.thinkingLevel !== undefined && isThinkingLevel(session.thinkingLevel)
      ? session.thinkingLevel
      : settings.getDefaultThinkingLevel();
  return {
    model: { provider: model.provider, modelId: model.id },
    ...(thinkingLevel ? { thinkingLevel } : {}),
  };
}

/**
 * Fork-list text for a user message, empty when the trace shows no user row for it. The trace
 * emits a row for text and for image/audio blocks that carry data, so a media-only message
 * lists a placeholder rather than copying the media.
 */
function forkMessageText(content: string | ReadonlyArray<object>): string {
  if (typeof content === "string") return content;
  let text = "";
  let media: "[Image]" | "[Audio]" | undefined;
  for (const block of content as ReadonlyArray<Record<string, unknown>>) {
    if (block.type === "text" && typeof block.text === "string") text += block.text;
    else if (!block.data) continue;
    else if (block.type === "image") media = "[Image]";
    else if (block.type === "audio" || block.type === "output_audio") media ??= "[Audio]";
  }
  return text || media || "";
}

/** The error text of an assistant message that ended with `stopReason: "error"`. */
function asErrorText(message: unknown): string | undefined {
  const record = message as { stopReason?: unknown; errorMessage?: unknown } | undefined;
  return record?.stopReason === "error" &&
    typeof record.errorMessage === "string" &&
    record.errorMessage
    ? record.errorMessage
    : undefined;
}

/**
 * The classic-event facade of a conversation for the session socket: classic events, lifecycle
 * permits, Skill expansion, and the queue version over the host's `AgentController` and `Models`,
 * which own input, run, and model control. The Harness owns execution and queues.
 */
export class DurableBackend implements AgentBackend {
  private readonly transactions = new SessionRuntimeTransaction();
  private ui!: DurableUIProjection;
  private disposed = false;
  /** Aborted on detach: admission still waiting in the controller's chain is refused. */
  private readonly lifetime = new AbortController();
  private eventsStarted = false;
  private detaching?: Promise<void>;
  private readonly registry: ModelRegistry;
  readonly abortClearsQueuedModelTurns = true;
  readonly cancelsExtensionUIOnAbort = true;
  readonly isQueueReconciliationRequired = false;
  readonly persistsWithoutSessionFile = true;
  readonly retainsIdleQueueUntilAdmission = true;
  private queueVersion = 0;
  private queueFingerprint = "";
  /** Error texts the current run already showed live; cleared when it ends. */
  private readonly shownRunErrors = new Set<string>();
  /** Unregisters this attachment from Live Voice call-state changes. */
  private detachLiveVoice?: () => void;
  /** Live Voice selection commits, in the order calls attached and detached. */
  private liveVoiceSelection: Promise<void> = Promise.resolve();

  private constructor(
    private readonly harness: Harness,
    private readonly host: SessionHost,
    private readonly conversation: Conversation,
    models: ModelRuntime,
    private readonly session: Session,
    /** The conversation's state and the classic events it tells; its view backs the getters. */
    private readonly events: DurableClassicEvents,
    private readonly onEvent: (event: SessionBackendEvent) => void,
    private readonly mcp: DurableMcp | undefined,
    private resources: PresentedResources,
    private readonly loadResources: () => Promise<PresentedResources>,
    private readonly dataDir: string,
    /** Reads a presented Skill file: the VM for a sandbox, the host otherwise. */
    private readonly readSkillFile: (path: string) => Promise<string>,
    /** The session's effective Pi settings, the same manager its Pi Tools setting came from. */
    private readonly piSettings: SettingsManager,
  ) {
    this.registry = new ModelRegistry(models);
  }

  static async create(options: DurableBackendOptions): Promise<DurableBackend> {
    const { models, session } = options;
    const workspace = options.workspace;
    const unsupported = durableUnsupportedFeature({ ephemeral: session.ephemeral });
    if (unsupported) throw new DurableNotSupportedError(unsupported);
    const sandbox = workspace?.runtime === "sandbox";
    const hostCwd = await resolveSdkSessionCwdAsync(options.workspace, session, {
      dataDir: options.dataDir,
    });
    const cwd = sandbox ? resolveSandboxGuestCwd(workspace) : hostCwd;
    const host = options.host;
    const agentDir = getAgentDir();
    const control = isControlConversation(session);
    // Sandboxes see only the workspace, as SDK sandbox sessions: trusted.
    const projectTrusted =
      sandbox || (!control && (await resolveProjectTrust(hostCwd, agentDir, options)));
    // The Pi Tools setting, as a classic session reads it. A sandbox reads only the global one:
    // the project's `.pi/settings.json` is in the guest-writable workspace. The attach holds this
    // manager for its other settings too, which are read live where they apply.
    const piSettings = SettingsManager.create(hostCwd, agentDir, {
      projectTrusted: projectTrusted && !sandbox,
    });
    const piTools = piDefaultTools(piSettings);
    const launched = control
      ? undefined
      : await DurableBackend.launchedAs(options, { hostCwd, cwd, sandbox, piTools });
    const skipped = launched?.doc?.extensions?.skipped;
    if (skipped?.length) recordSkippedExtensionsWarning(session, skipped);
    // A sandbox's workspace VM comes first: its Skills and context files are what this VM
    // mounts and reads, whichever session booted it. Before the conversation exists, so a
    // saved Agent selection the VM cannot present still fails the launch before it binds.
    const sandboxEnv = sandbox
      ? await DurableBackend.sandboxEnv(workspace, hostCwd, cwd)
      : undefined;
    // An Oppi Control session presents no AGENTS files and no Skills, global or project, as
    // with `/reload`. Oppi's appends read the settings and the workspace prompt each time, so an
    // attach or `/reload` applies a change from the next request, as an SDK session's runtime
    // rebuild does.
    const loadResources = async (): Promise<PresentedResources> => {
      const appends = oppiAppendSystemPrompt({
        target: control ? "control" : sandbox ? "sandbox" : "host",
        serverConfig: options.serverConfig,
        workspacePrompt: workspace?.systemPrompt,
        mobileOutputGuide: (
          options.getMobileOutputGuideSettings?.() ?? DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS
        ).enabled,
        replace: launched?.doc?.projectContext === false,
      });
      if (control) return { contextFiles: [], skills: [], appends };
      const files = await loadDurableProjectResources({
        hostCwd,
        agentDir,
        ...(sandboxEnv ? { sandbox: sandboxEnv } : {}),
        projectTrusted,
        ...(launched?.doc?.resources ? { resources: launched.doc.resources } : {}),
        projectContext: launched?.doc?.projectContext !== false,
      });
      return { ...files, appends };
    };
    const resources = await loadResources();
    // An Oppi Control session selects an exact extension list; it gets no MCP tools, and an
    // exact Extension selection without `builtin:mcp` gets none either.
    const mcp =
      control || launched?.doc?.extensions?.mcp === false
        ? undefined
        : await host.replaceMcp(session.id, async () => {
            const registry = new ModelRegistry(models);
            return DurableMcp.open({
              sessionId: session.id,
              // The MCP root servers see via roots/list: a sandbox gets only the guest path.
              cwd,
              agentDir,
              projectTrusted,
              ...(sandbox
                ? {
                    sandbox: await sandboxMcpForWorkspace({
                      workspace,
                      agentDir,
                      dataDir: options.dataDir,
                      guestCwd: cwd,
                      // This attachment's VM, as classic sandbox sessions use theirs.
                      vm: async () => {
                        if (!sandboxEnv) throw new Error("The sandbox VM is not ready");
                        return sandboxEnv.vm;
                      },
                    }),
                  }
                : {}),
              policy: session.launch?.tools,
              piTools,
              providerToken: (provider) => registry.getApiKeyForProvider(provider),
              install: (extension) => host.runtime.installExtension(extension),
              uninstall: (extension) => host.runtime.uninstallExtension(extension),
              namespaces: (namespaces) => host.runtime.setMcpNamespaces(session.id, namespaces),
              metrics: options.metrics,
            });
          });
    try {
      return await DurableBackend.bind(options, {
        hostCwd,
        cwd,
        mcp,
        piTools,
        piSettings,
        launched,
        sandboxEnv,
        resources,
        loadResources,
      });
    } catch (error) {
      await host.closeMcp(session.id);
      throw error;
    }
  }

  /**
   * A bound conversation's stored `oppi.agent` document, or, for the conversation this attach
   * creates, the agent the one resolver makes from the session's saved Agent, model, tool
   * policy, and delegation grant (`AgentLaunchService` recorded them on the row).
   */
  private static async launchedAs(
    options: DurableBackendOptions,
    target: { hostCwd: string; cwd: string; sandbox: boolean; piTools: ReadonlySet<string> },
  ): Promise<LaunchedAs> {
    const { harness, session, host } = options;
    const id = session.serverDurable?.conversationId as ConversationId | undefined;
    if (id !== undefined) {
      // A bound conversation without the document (one created before it existed) runs as an
      // unconfigured session and never spawns.
      const doc = await harness.snapshot(OppiAgentDoc, id, BACKGROUND_CONTEXT);
      return { doc, spawn: doc?.spawn === true };
    }
    const runtime = target.sandbox ? "sandbox" : "host";
    const grant = session.launch?.allowsNestedDelegation === true;
    // As `oppi session create --parent`: a delegated session spawns only with the grant.
    const spawn = !session.launch?.parentSessionId || grant;
    const agentId = session.launch?.agentId;
    const definition = options.agentDefinition;
    const created = resolveDurableAgent({
      ...(agentId && definition
        ? { saved: { id: agentId, version: session.launch?.agentVersion ?? 0, definition } }
        : {}),
      ...seedModel(options.models, target.hostCwd, session),
      ...(session.launch?.tools ? { policy: session.launch.tools } : {}),
      runtime,
      base: [...host.runtime.builtInsFor(runtime), ...host.runtime.packageExtensionsFor(runtime)],
      loaded: host.runtime.loadedPackages,
      classic: host.runtime.classicExtensions,
      enabled: (name) => host.runtime.isExtensionEnabled(name),
      piTools: target.piTools,
      codemode: host.runtime.codemode,
      sessions: host.runtime.sessionsExtension,
      spawn,
      grant,
      notify: host.runtime.notifyExtension,
      notifies: host.runtime.offersNotify(session.id),
      instructions: { cwd: target.cwd },
    });
    return { doc: created.doc, spawn, created };
  }

  private static async bind(
    options: DurableBackendOptions,
    target: {
      hostCwd: string;
      cwd: string;
      mcp: DurableMcp | undefined;
      piTools: ReadonlySet<string>;
      /** The session's effective Pi settings, as its Pi Tools setting is read. */
      piSettings: SettingsManager;
      launched: LaunchedAs | undefined;
      sandboxEnv: GondolinExecutionEnv | undefined;
      resources: PresentedResources;
      loadResources: () => Promise<PresentedResources>;
    },
  ): Promise<DurableBackend> {
    const { harness, models, session, host } = options;
    const { hostCwd, cwd, mcp, resources, launched } = target;
    const workspace = options.workspace;
    const sandbox = workspace?.runtime === "sandbox";
    const id = session.serverDurable?.conversationId;
    const control = isControlConversation(session);
    // Owner plugins' extensions allowed in this runtime, or the exact
    // selection the session launched with; never on control.
    const exact = launched?.doc?.extensions?.packages;
    const packageExtensions = control
      ? []
      : exact
        ? host.runtime.loadedPackages
            .filter(
              (loaded) =>
                exact.includes(loaded.extension.name) &&
                host.runtime.isExtensionEnabled(loaded.extension.name),
            )
            .map((loaded) => loaded.extension)
        : host.runtime.packageExtensionsFor(sandbox ? "sandbox" : "host");
    // A child without the `allowNestedDelegation` grant has no `subagent` tool.
    const spawn = launched?.spawn === true;
    // Asked again on every attach: push may have turned on or off since the last one.
    const notifies = host.runtime.offersNotify(session.id);
    // A saved Agent's exact Extension selection without `builtin:codemode` has none.
    const codemode = launched?.doc?.extensions?.codemode !== false;
    const builtIns = [
      ...host.runtime.attachedBuiltIns(spawn, notifies),
      ...(codemode ? [host.runtime.codemode] : []),
    ];
    let conversation: Conversation;
    if (id !== undefined) {
      const existing = await harness.conversation(id as ConversationId, BACKGROUND_CONTEXT);
      if (!existing) throw new Error(`Server durable conversation ${id} is missing`);
      const runtime = await harness.snapshot(DurableRuntime, existing.id, BACKGROUND_CONTEXT);
      if (
        (runtime?.kind === "sandbox") !== sandbox ||
        (sandbox && runtime?.workspaceId !== options.workspace?.id)
      )
        throw new Error(
          "A bound server durable session cannot switch execution runtime or sandbox workspace",
        );
      conversation = existing;
      await dropInstructionsWorkspacePrompt(existing, workspace?.systemPrompt);
      // The Session this conversation belongs to, for hooks and tasks of durable extensions. A
      // conversation bound before the document existed gets it here.
      if (
        (await harness.snapshot(DurableSessionDoc, existing.id, BACKGROUND_CONTEXT))?.sessionId !==
        session.id
      )
        await conversation.commit(async (tx) => {
          (await tx.doc(DurableSessionDoc, existing.id)).sessionId = session.id;
        }, BACKGROUND_CONTEXT);
      // A session bound to a worktree runs where the row says: one that moved off a removed
      // worktree must not keep writing in the old checkout. Main-checkout sessions (the id
      // "main" an HTTP create stores) keep the cwd their conversation stored: a missing
      // workspace resolves to $HOME and must not be written.
      if (session.worktreeId && session.worktreeId !== MAIN_WORKTREE_ID) {
        const stored = await harness.snapshot(AgentDoc, existing.id, BACKGROUND_CONTEXT);
        if (stored?.cwd !== cwd)
          await conversation.commit(async (tx) => {
            (await tx.doc(AgentDoc, existing.id)).cwd = cwd;
          }, BACKGROUND_CONTEXT);
      }
      // Bound conversations store exact extension/tool names. Enroll the native
      // UI ports and this attachment's MCP extension too, without overriding
      // their launch tool policy. An Oppi Control session instead re-asserts its exact
      // selection, so one created before an extension joined the list picks it up here.
      await conversation.configure(
        control
          ? {
              extensions: [...host.runtime.controlExtensions],
              tools: controlConversationTools(host.runtime.controlExtensions),
            }
          : {
              extensions: {
                add: [...builtIns, ...packageExtensions, ...(mcp ? [mcp.selection] : [])],
                // The host default selection includes all three.
                remove: [
                  ...(spawn ? [] : [host.runtime.sessionsExtension]),
                  ...(notifies ? [] : [host.runtime.notifyExtension]),
                  ...(codemode ? [] : [host.runtime.codemode]),
                ],
              },
            },
        BACKGROUND_CONTEXT,
      );
      const agent = await conversation.agent(BACKGROUND_CONTEXT);
      const policy = session.launch?.tools;
      const selected = new Set(agent.tools.map((tool) => tool.name));
      // As Pi's `/reload`: a tool the Pi Tools setting newly enables joins; one it no longer
      // enables stays until the session ends.
      const additions = (control ? [] : [CodingTools, ...builtIns, ...packageExtensions])
        .flatMap((extension) => extension.tools ?? [])
        .filter(
          (tool) => !selected.has(tool.name) && toolAllowed(policy, tool.name, target.piTools),
        );
      // Append names instead of rewriting the list from resolved tools: MCP tools a
      // previous attachment offered are not registered until their servers reconnect.
      if (additions.length)
        await conversation.commit(async (tx) => {
          const state = await tx.doc(AgentDoc, conversation.id);
          if (!Array.isArray(state.tools)) return;
          for (const tool of additions)
            if (!state.tools.includes(tool.name)) state.tools.push(tool.name);
        }, BACKGROUND_CONTEXT);
    } else {
      const created = launched?.created;
      // An Oppi Control session's instructions are its `oppi-control` prompt section.
      const agent: AgentChange = created
        ? {
            ...created.change,
            cwd,
            // MCP offers its tools, codemode, and tool search when it attaches, before a prompt.
            extensions: [...created.change.extensions, ...(mcp ? [mcp.selection] : [])],
          }
        : {
            extensions: [...host.runtime.controlExtensions],
            ...seedModel(models, hostCwd, session),
            cwd,
            tools: controlConversationTools(host.runtime.controlExtensions),
          };
      conversation = await harness.createConversation(
        {
          ownership: { kind: "ownerless" },
          init: async (tx, id) => {
            const runtime = await tx.doc(DurableRuntime, id);
            runtime.kind = sandbox ? "sandbox" : "host";
            if (sandbox) runtime.workspaceId = workspace.id;
            (await tx.doc(DurableSessionDoc, id)).sessionId = session.id;
            if (created) Object.assign(await tx.doc(OppiAgentDoc, id), created.doc);
          },
          // The resolved agent, committed with the conversation: one configure.
          agent,
        },
        BACKGROUND_CONTEXT,
      );
      // Keep the rest of the enrollment (the control role) when binding.
      session.serverDurable = { ...session.serverDurable, conversationId: conversation.id };
      // Bind before any submit can be accepted. A crash before this save leaves
      // only an empty unbound conversation, never a duplicated user turn.
      options.persistBinding();
    }
    // `/skill:` bytes come through the session's own view: the VM for a sandbox, whose
    // shadow and mount jails the host filesystem does not apply.
    const readInView = sandbox
      ? (path: string) => options.host.readSandboxTextFile(conversation.id, path)
      : (path: string) => readFile(path, "utf-8");
    // Stdio MCP servers run in this VM; they connect at `attach` below.
    if (target.sandboxEnv) options.host.bindSandboxEnv(conversation.id, target.sandboxEnv);
    await syncProjectContext(conversation, resources);
    // Its ticker runs from the registry, not the selection, so turning it off means not starting
    // it. An Oppi Control session keeps its fixed selection.
    if (control || host.runtime.isExtensionEnabled(WORKING_WORDS_EXTENSION)) {
      const words = host.runtime.installedTask(WORKING_WORDS_TASK);
      await conversation.commit(
        (tx) => ensureWorkingWords(tx, conversation.id, words),
        BACKGROUND_CONTEXT,
      );
    }
    // The subagent pill's watcher is a ticker: an idle store retires it and a Stop fence
    // aborts it. A conversation with children gets it back here.
    const subagents = await harness.snapshot(Subagents, conversation.id, BACKGROUND_CONTEXT);
    if (Object.keys(subagents?.children ?? {}).length > 0) {
      const widget = host.runtime.installedTask(SUBAGENT_WIDGET_TASK);
      await conversation.commit(
        (tx) => ensureSubagentWidget(tx, conversation.id, widget),
        BACKGROUND_CONTEXT,
      );
    }
    mcp?.attach(conversation);
    const events = await DurableClassicEvents.open(
      harness,
      conversation,
      () => host.runtime.retrySettings ?? {},
    );
    try {
      // A run in progress resumes after this attachment; its MCP tool calls must find
      // their tools, so let the servers connect first (bounded).
      if (mcp && (events.view.docs["pi.live"] as LiveState | undefined)?.run !== undefined)
        await mcp.waitForStartup();
      const backend = new DurableBackend(
        harness,
        options.host,
        conversation,
        models,
        session,
        events,
        options.onEvent,
        mcp,
        resources,
        target.loadResources,
        options.dataDir,
        readInView,
        target.piSettings,
      );
      backend.ui = await DurableUIProjection.create(harness, conversation, options.onEvent);
      // Last, so nothing after it can fail with the toggle registered. The attach's `{ add }`
      // edit above dropped any `oppi.live-voice` a previous attachment left; this puts it back
      // when a call is attached now. An Oppi Control session never takes calls.
      if (!control)
        backend.detachLiveVoice = host.runtime.boundLiveVoice?.attachRuntime(
          session.id,
          (attached) => backend.selectLiveVoice(attached),
        );
      return backend;
    } catch (error) {
      await events.stop();
      throw error;
    }
  }

  /**
   * The workspace VM's capabilities for one sandbox attachment. The same env discovers its
   * resources, on attach and on `/reload`, and is bound to the conversation once it exists.
   */
  private static async sandboxEnv(
    workspace: Workspace,
    hostCwd: string,
    cwd: string,
  ): Promise<GondolinExecutionEnv> {
    const vm = await SdkBackend.ensureSandboxWorkspaceVm(workspace, hostCwd);
    const probe = await vm.exec(["/usr/bin/setsid", "/bin/true"]);
    if (!probe.ok) throw new Error("Durable sandbox execution requires guest setsid");
    return new GondolinExecutionEnv(vm, workspace.id, cwd);
  }

  /** Start only after Oppi has registered its projection listener. */
  async startEvents(): Promise<void> {
    if (this.eventsStarted) return;
    this.eventsStarted = true;
    this.ui.start();
    // One warning after the first connection attempts, as Pi's MCP extension notifies
    // SDK sessions.
    void this.mcp?.startupProblems().then((message) => {
      if (message && !this.disposed)
        this.onEvent({
          type: "extension_ui_request",
          id: randomUUID(),
          method: "notify",
          message,
          notifyType: "warning",
        });
    });
    if (!this.host.isResumeHeld) this.harness.resume();
    for (const event of this.events.snapshot(this.host.isResumeHeld)) this.onEvent(event);
    this.events.start(async (frame) => {
      if (this.disposed) return;
      // A new run starts with nothing shown, also after an idle task's failure. A frame
      // that also ends a run keeps that run's texts until its settlement is handled below.
      if (frame.runStarted && !frame.runEnded) this.shownRunErrors.clear();
      for (const pi of frame.events) {
        if (this.disposed) return;
        // The protocol already shows an assistant error as the live error row.
        const ended = pi.type === "message_end" ? asErrorText(pi.message) : undefined;
        if (ended) this.shownRunErrors.add(ended);
        // A failed blocking compaction fails its run with pi-durable's
        // `Compaction failed: <error>`; the compaction row already shows it.
        if (pi.type === "compaction_end" && pi.errorMessage)
          this.shownRunErrors.add(`Compaction failed: ${pi.errorMessage}`);
        this.onEvent(pi);
      }
      for (const entry of frame.appended) {
        const card = this.events.inputCards.entries.get(entry.id);
        if (entry.model?.length) {
          if (card)
            this.onEvent({
              type: "notice",
              id: `entry:${entry.id}`,
              message: `${card.title}${card.status ? ` · ${card.status}` : ""}${card.body ? ` — ${card.body}` : ""}`,
            });
          continue;
        }
        if (entry.kind === DURABLE_FAILURE_ENTRY_KIND) continue;
        const data = entry.data;
        const display = sanitizeTranscriptCard(
          data && typeof data === "object" && !Array.isArray(data) ? data.card : undefined,
        );
        if (display)
          this.onEvent({
            type: "notice",
            id: `entry:${entry.id}`,
            message: display.body ? `${display.title} — ${display.body}` : display.title,
          });
      }
      // Native placement carries identity. Recover display metadata by request,
      // never by matching user text or keeping an Oppi queue shadow.
      for (const record of frame.placed) {
        if (!record.requestId) continue;
        const display = await readRequestDisplay(
          this.harness,
          this.conversation.id,
          record.requestId,
        );
        if (
          display &&
          (display.kind === "steer" || display.kind === "followUp") &&
          !this.events.inputCards.submissions.has(record.id)
        )
          this.onEvent({
            type: "queue_item_started",
            kind: display.kind === "steer" ? "steer" : "follow_up",
            item: {
              id: String(record.id),
              message: display.message,
              createdAt: display.createdAt,
              ...(display.attachments.length ? { attachments: display.attachments } : {}),
            },
            queueVersion: this.inboxVersion(),
          });
      }
      // A run that ended without an answer gets its card here, whoever submitted its inputs (a
      // background job's follow-up, a reporter); the request id makes the controller's own write
      // for its prompts a no-op. The live error is the card's text, written or not, once per run.
      // A host stop Oppi continues is no failure the user sees: no error, no card.
      const failure = frame.runFailure;
      const continued = failure?.reason === "interrupted" && frame.continuation !== undefined;
      if (failure && !continued) {
        this.showRunError(runFailureText(failure));
        try {
          await recordRunFailureCard(this.harness, this.conversation, failure);
        } catch (error) {
          log.warn("durable_failure.run_card_failed", {
            taskId: failure.taskId,
            error: safeErrorMessage(error),
          });
        }
      }
      if (frame.inboxChanged) this.onEvent({ type: "queue_update", ...this.queuedMessages() });
      // A generation fault also settles its inputs, which record the card; a compaction
      // failure shows on its compaction row.
      for (const failure of frame.taskFailures) {
        this.showRunError(failure.message.trim() || failure.kind);
        try {
          await recordTaskFailure(this.conversation, {
            id: failure.taskId,
            kind: failure.kind,
            message: failure.message,
          });
        } catch (error) {
          log.warn("durable_failure.task_card_failed", {
            taskId: failure.taskId,
            error: safeErrorMessage(error),
          });
        }
      }
      // A run that failed with inputs queued behind it: its card is written above, so start them
      // now, behind it. The frame held the run's `agent_settled`; send it if none starts.
      const failed = frame.continuation;
      if (failed !== undefined && !this.disposed) {
        let next: "running" | "idle" = "idle";
        try {
          next = await (await this.controller()).continueAfterFailedRun(failed);
        } catch (error) {
          log.warn("durable_failure.continue_failed", {
            taskId: failed.taskId,
            error: safeErrorMessage(error),
          });
        }
        if (next === "idle") for (const pi of this.events.settle()) this.onEvent(pi);
      }
      // A run's settlement commits with its end, so its errors are in this frame or earlier.
      // A later run starts with nothing shown.
      if (frame.runEnded) this.shownRunErrors.clear();
    });
    // After the listener is attached. A commit, not Conversation.submit, so a
    // held startup scheduler stays held. A crash between settlement and the
    // card write is filled here; a card that already landed is a no-op.
    // A failed scan fails the attach. Swallowing it would leave the miss hidden.
    if (this.disposed) return;
    await reconcileFailureCards(this.harness, this.conversation, this.host.storage);
    // A host stop cut the run off mid-request with no retry left before this attachment saw
    // it end: continue it, as a run this attachment sees end does, once startup opens
    // scheduling. A continue the frame listener already sent shares its request id.
    const live = this.live;
    const failure = live.runFailure;
    if (live.run === undefined && failure?.reason === "interrupted")
      void this.host.whenResumed().then(async () => {
        if (this.disposed) return;
        try {
          await (await this.controller()).continueAfterFailedRun(failure);
        } catch (error) {
          log.warn("durable_failure.continue_failed", {
            taskId: failure.taskId,
            error: safeErrorMessage(error),
          });
        }
      });
  }

  /**
   * One live error per failed run: the failure's own text (what its card says), unless this
   * run already showed that text (an assistant error row, a failed compaction row, or another
   * input of the same run).
   */
  private showRunError(error: string | undefined): void {
    if (!error || this.shownRunErrors.has(error)) return;
    this.shownRunErrors.add(error);
    this.onEvent({ type: "prompt_error", error });
  }

  private get agent(): AgentState {
    return (this.events.view.docs["pi.agent"] as AgentState) ?? {};
  }
  private get live(): LiveState {
    return (this.events.view.docs["pi.live"] as LiveState) ?? {};
  }
  get isDisposed(): boolean {
    return this.disposed;
  }
  hasPendingWake(): Promise<boolean> {
    return this.host.hasPendingWake(this.conversation.id);
  }
  async hasPendingWork(): Promise<boolean> {
    const { harness } = await this.host.open();
    const [live, inbox] = await Promise.all([
      harness.snapshot(LiveDoc, this.conversation.id, BACKGROUND_CONTEXT),
      harness.snapshot(InboxDoc, this.conversation.id, BACKGROUND_CONTEXT),
    ]);
    return live?.run !== undefined || (inbox?.items.length ?? 0) > 0;
  }
  /** Durable tasks recover after a restart and report an interrupted job themselves. */
  readonly holdsWorkLostOnRestart = false;
  readonly reportsLostWork = false;
  get isStreaming(): boolean {
    return this.live.run !== undefined;
  }
  get isCompacting(): boolean {
    return (this.live.compactions?.length ?? 0) > 0;
  }
  get isRuntimeLifecycleTransactionExclusive(): boolean {
    return this.transactions.isExclusiveActive;
  }
  get cacheMissModelPriceSource(): ModelRegistry {
    return this.registry;
  }
  /** Read per event, as an SDK session reads its runtime's settings, not pinned at attach. */
  get showCacheMissNotices(): boolean {
    return this.piSettings.getShowCacheMissNotices();
  }

  private assertOpen(): void {
    if (this.disposed) throw new Error("Session backend is disposed");
  }

  withModelTurnAdmission<T>(
    _command: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T> {
    this.assertOpen();
    this.host.assertSchedulingReady();
    return this.transactions.withShared(operation);
  }
  withRuntimeLifecycleTransaction<T>(
    _operation: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
    options?: { allowDisposed?: boolean },
  ): Promise<T> {
    if (!options?.allowDisposed) this.assertOpen();
    return this.transactions.withExclusive(operation);
  }

  async prompt(
    message: string,
    options?: Parameters<AgentBackend["prompt"]>[1],
    permit?: SessionRuntimeTransactionPermit,
  ): Promise<void | { duplicate: true }> {
    if (!permit)
      return this.withModelTurnAdmission("prompt", (token) => this.prompt(message, options, token));
    this.transactions.assertPermit(permit, "shared");
    this.assertOpen();
    const clientTurnId = options?.clientTurnId;
    if (
      clientTurnId &&
      DURABLE_RESERVED_REQUEST_ID_PREFIXES.some((prefix) => clientTurnId.startsWith(prefix))
    )
      throw new Error("clientTurnId uses a reserved durable requestId namespace");
    const requestId = clientTurnId ?? `${DURABLE_QUEUE_REQUEST_ID_PREFIX}${randomUUID()}`;
    // The model sees the expanded Skill; queue display keeps what the user typed.
    const text = await expandSkillCommand(message, this.resources, this.readSkillFile);
    const content = options?.images?.length
      ? [{ type: "text" as const, text }, ...options.images]
      : text;
    await this.mcp?.beforePrompt();
    // Admission, not the whole generation, holds the permit. Abort must not
    // wait behind a stream, and a duplicate can find its settled submission.
    const { duplicate, settled } = await (
      await this.controller()
    ).prompt(content, {
      requestId,
      whenBusy: options?.streamingBehavior,
      display: {
        message: options?.queueDisplay?.message ?? message,
        attachments: options?.queueDisplay?.attachments ?? [],
      },
      signal: this.lifetime.signal,
      onAccepted: options?.onPreflightAccepted,
    });
    // An unanswered input's error is its failure card (see startEvents), not a second row here.
    void settled.catch((error: unknown) => {
      if (!this.disposed)
        this.onEvent({
          type: "prompt_error",
          error: error instanceof Error ? error.message : String(error),
        });
    });
    if (duplicate) return { duplicate: true };
  }

  async abort(permit?: SessionRuntimeTransactionPermit): Promise<void> {
    if (!permit) return this.withRuntimeLifecycleTransaction("abort", (token) => this.abort(token));
    this.transactions.assertPermit(permit, "exclusive");
    this.assertOpen();
    await (await this.controller()).abort();
    this.onEvent({ type: "queue_update", ...this.queuedMessages() });
  }
  // Classic aborts only a user-started shell command, which the server never starts on either
  // engine. A model's bash call is a durable tool task that `abort` already stops.
  abortBash(): never {
    return this.unsupported("abortBash (use abort)");
  }
  async dispose(permit?: SessionRuntimeTransactionPermit): Promise<SdkBackendDisposeResult> {
    if (!permit)
      return this.withRuntimeLifecycleTransaction("dispose", (token) => this.dispose(token), {
        allowDisposed: true,
      });
    if (this.disposed) return { disposal: "graceful" };
    this.transactions.assertPermit(permit, "exclusive");
    await this.host.abortConversation(this.conversation.id);
    await this.host.abortSessionReporters(this.conversation.id);
    await this.detachForRestart();
    await this.host.unbindSandboxEnv(this.conversation.id);
    await this.host.closeMcp(this.session.id);
    return { disposal: "graceful" };
  }
  /**
   * Select `oppi.live-voice` while a call is attached, so the agent has `speak` and the call's
   * prompt section; drop it when the call ends. pi-durable resolves the agent before each model
   * request, so a run already in progress gets the change at its next model call. Commits run in
   * call order; a failure only costs the agent its voice, and the run's final reply is still read
   * aloud (`LiveVoiceSpeech.observe`).
   */
  private selectLiveVoice(attached: boolean): void {
    const extension = this.host.runtime.liveVoiceExtension;
    const on = attached && this.host.runtime.isExtensionEnabled(extension.name);
    const policy = this.session.launch?.tools;
    // `speak` is no tool of the Pi Tools setting: only the policy decides.
    const tools = (extension.tools ?? [])
      .map((tool) => tool.name)
      .filter((name) => toolAllowed(policy, name, new Set()));
    const id = this.conversation.id;
    this.liveVoiceSelection = this.liveVoiceSelection
      .then(async () => {
        if (this.disposed) return;
        await this.conversation.commit(
          async (tx) => selectExtension(await tx.doc(AgentDoc, id), extension.name, tools, on),
          BACKGROUND_CONTEXT,
        );
      })
      .catch((error: unknown) => {
        log.warn("durable.live_voice_select_failed", {
          sessionId: this.session.id,
          attached,
          error: safeErrorMessage(error),
        });
      });
  }

  /** Projection teardown only: the recorded original submission must survive shutdown. */
  detachForRestart(): Promise<void> {
    return (this.detaching ??= (async () => {
      this.disposed = true;
      this.detachLiveVoice?.();
      this.detachLiveVoice = undefined;
      this.lifetime.abort(new Error("Session backend is disposed"));
      await this.ui.stop();
      await this.events.stop();
    })());
  }
  captureEmergencyDisposalForStop(): (timeoutMs: number) => Promise<SdkBackendDisposeResult> {
    return async (timeoutMs) => {
      // Never report a successful stop until Durable has admitted cancellation.
      // A rejected abort leaves the projection alive and propagates stop_failed.
      await this.host.abortConversation(this.conversation.id);
      await this.host.abortSessionReporters(this.conversation.id);
      await this.detachForRestart();
      await this.host.unbindSandboxEnv(this.conversation.id);
      await this.host.closeMcp(this.session.id);
      this.transactions.poison(new Error("Server durable stop timed out"));
      return { disposal: "forced", cause: "lifecycle_timeout", operation: "stop", timeoutMs };
    };
  }

  private inboxVersion(items = this.currentInbox()?.items ?? []): number {
    const fingerprint = JSON.stringify(items);
    if (fingerprint !== this.queueFingerprint) {
      this.queueFingerprint = fingerprint;
      this.queueVersion += 1;
    }
    return this.queueVersion;
  }

  private controller(): Promise<DurableAgentController> {
    return this.host.controller(this.conversation.id);
  }

  async nativeMessageQueue(): Promise<MessageQueueState> {
    return (await this.controller()).queue((inbox) => this.inboxVersion(inbox));
  }

  queuedMessages(): { steering: readonly string[]; followUp: readonly string[] } {
    const items = (this.currentInbox()?.items ?? []).filter(
      (item) => !this.events.inputCards.submissions.has(item.id),
    );
    const text = (content: string | readonly { type: string; text?: string }[]): string =>
      typeof content === "string"
        ? content
        : content.map((block) => (block.type === "text" ? (block.text ?? "") : "")).join("");
    return {
      steering: items.flatMap((item) => (item.mode === "steer" ? [text(item.content)] : [])),
      followUp: items.flatMap((item) => (item.mode === "followUp" ? [text(item.content)] : [])),
    };
  }
  /**
   * The active transcript the model sees, head marker first: `Conversation.context()`, not the
   * conversation view, whose entries pi-durable may bound to a window.
   */
  private async contextEntries(): Promise<readonly EntryRecord[]> {
    return (await this.conversation.context(BACKGROUND_CONTEXT)).entries;
  }
  /** Messages of `entries` as the trace shows them: no generated inputs, no retried attempts. */
  private async visibleMessages(entries: readonly EntryRecord[]): Promise<PiMessage[]> {
    const cards = await readDurableInputCards(
      this.harness,
      new Set(entries.map((entry) => entry.conversationId)),
    );
    const messages: PiMessage[] = [];
    for (const entry of entries) {
      if (cards.entries.has(entry.id)) continue;
      if (await isRecoveredPartial(entry, this.harness, entries)) continue;
      messages.push(...(entry.model ?? []));
    }
    return messages;
  }
  async messages(): Promise<PiMessage[]> {
    return this.visibleMessages(await this.contextEntries());
  }
  getStateSnapshot(): PiStateSnapshot {
    const model = this.agent.model;
    return {
      sessionId: this.session.id,
      sessionName: this.session.name,
      model: model
        ? {
            provider: model.provider,
            id: model.modelId,
            name: this.registry.find(model.provider, model.modelId)?.name,
          }
        : undefined,
      thinkingLevel: this.agent.thinkingLevel,
      isStreaming: this.isStreaming,
      isCompacting: this.isCompacting,
    };
  }
  async getSessionStats(): Promise<Awaited<ReturnType<AgentBackend["getSessionStats"]>>> {
    const entries = await this.contextEntries();
    const messages = await this.visibleMessages(entries);
    const usage = this.events.view.docs["pi.usage"] as UsageState | undefined;
    const tokens = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
    let cost = 0;
    const byModel = new Map<string, SessionModelUsageSnapshot>();
    for (const [key, value] of Object.entries(usage?.models ?? {})) {
      // `pi.usage` keys models as `provider/modelId`.
      const split = splitCanonicalModelId(key);
      addUsageToModelBreakdown(byModel, key, split?.modelId ?? key, split?.provider, value);
    }
    for (const value of Object.values(usage?.tools ?? {}))
      addUsageToModelBreakdown(
        byModel,
        TOOLS_SUMMARIES_USAGE_KEY,
        TOOLS_SUMMARIES_USAGE_LABEL,
        undefined,
        value,
      );
    for (const value of [
      ...Object.values(usage?.models ?? {}),
      ...Object.values(usage?.tools ?? {}),
    ]) {
      tokens.input += value.input;
      tokens.output += value.output;
      tokens.cacheRead += value.cacheRead;
      tokens.cacheWrite += value.cacheWrite;
      tokens.total += value.totalTokens;
      cost += value.cost.total;
    }
    // The effective prompt is the replay of the active context's `pi.system` entries.
    const systemPromptChars = getCurrentSystemPrompt(
      entries.flatMap((entry) => entry.model ?? []),
    ).length;
    const agent = await this.conversation.agent(BACKGROUND_CONTEXT);
    const agentsFiles = this.resources.contextFiles.map((file) => ({
      path: file.path,
      chars: file.content.length,
      tokens: estimateTokensFromChars(file.content.length),
    }));
    const agentsChars = agentsFiles.reduce((sum, file) => sum + file.chars, 0);
    const skillsListingChars =
      (await this.harness.snapshot(ProjectContextDoc, this.conversation.id, BACKGROUND_CONTEXT))
        ?.skills?.length ?? 0;
    // The Harness compacts at the context window minus this reserve.
    const compaction = this.host.runtime.runPolicySettings.getCompactionSettings();
    return {
      cacheWaste: computeCacheWaste(
        (await this.historyEntries()).flatMap((entry) =>
          CompactionEntry.is(entry) || ResetEntry.is(entry)
            ? [{ type: "compaction" }]
            : (entry.model ?? []).map((message) => ({ type: "message", message })),
        ),
        this.registry,
      ),
      modelBreakdown: sortedModelUsage(byModel),
      contextComposition: {
        piSystemPromptChars: systemPromptChars,
        piSystemPromptTokens: estimateTokensFromChars(systemPromptChars),
        agentsChars,
        agentsTokens: agentsFiles.reduce((sum, file) => sum + file.tokens, 0),
        agentsFiles,
        skillsListingChars,
        skillsListingTokens: estimateTokensFromChars(skillsListingChars),
        tools: this.contextTools(agent),
        ...(compaction.enabled ? { compactionReserveTokens: compaction.reserveTokens } : {}),
      },
      loadedResources: {
        skills: this.resources.skills.map((skill) => ({
          name: skill.name,
          description: skill.description,
          path: skill.baseDir,
        })),
        extensions: agent.extensions.map((extension) => ({ name: extension.name, path: "" })),
      },
      sessionId: this.session.id,
      sessionFile: undefined,
      userMessages: messages.filter((message) => message.role === "user").length,
      assistantMessages: messages.filter((message) => message.role === "assistant").length,
      toolCalls: messages.reduce(
        (count, message) =>
          count +
          (Array.isArray(message.content)
            ? message.content.filter((block: { type?: string }) => block.type === "toolCall").length
            : 0),
        0,
      ),
      toolResults: messages.filter((message) => message.role === "toolResult").length,
      totalMessages: messages.length,
      tokens,
      cost,
    };
  }
  /** Every entry of this conversation, oldest first, including entries before the active head. */
  private async historyEntries(): Promise<EntryRecord[]> {
    const records: EntryRecord[] = [];
    let cursor;
    do {
      const page = await this.conversation.entries({}, 500, cursor, BACKGROUND_CONTEXT);
      records.push(...page.items);
      cursor = page.next;
    } while (cursor !== undefined);
    return records.reverse();
  }
  private models(): ReturnType<SessionHost["models"]> {
    this.assertOpen();
    return this.host.models(this.conversation.id);
  }
  async setModel(modelId: string): Promise<Awaited<ReturnType<AgentBackend["setModel"]>>> {
    const selected = await (await this.models()).select(modelId);
    return selected
      ? { success: true, ...selected }
      : { success: false, error: `Model unavailable: ${modelId}` };
  }
  async cycleModel(
    direction: "forward" | "backward" = "forward",
  ): Promise<Awaited<ReturnType<AgentBackend["cycleModel"]>>> {
    return (await this.models()).cycleModel(direction);
  }
  async setThinkingLevel(level: ThinkingLevel): Promise<void> {
    await (await this.models()).selectThinking(level);
  }
  async cycleThinkingLevel(): Promise<ThinkingLevel> {
    return (await this.models()).cycleThinking();
  }
  setSessionName(name: string): void {
    this.session.name = name;
  }
  async compact(instructions?: string): Promise<CompactionResult> {
    this.assertOpen();
    const usageBefore = (await this.messages())
      .reverse()
      .find((message) => message.role === "assistant")?.usage;
    const tokensBefore =
      usageBefore?.totalTokens ??
      (usageBefore?.input ?? 0) +
        (usageBefore?.output ?? 0) +
        (usageBefore?.cacheRead ?? 0) +
        (usageBefore?.cacheWrite ?? 0);
    return { ...(await (await this.controller()).compact(instructions)), tokensBefore };
  }
  toolDefinition(): undefined {
    return undefined;
  }

  private unsupported(operation: string): never {
    throw new DurableNotSupportedError(operation);
  }

  // Classic rebuilds its in-memory queue with these. Durable owns the queue as inbox state and
  // the queue coordinator uses `nativeMessageQueue`, `withdrawNativeQueue`, and
  // `abortClearsQueuedModelTurns` instead, so no supported path reaches them.
  replaceQueuedModelTurns(_batch: QueuedModelTurnBatch): never {
    return this.unsupported("replaceQueuedModelTurns (use the native queue)");
  }

  clearQueuedModelTurns(): never {
    return this.unsupported("clearQueuedModelTurns (abort withdraws the inbox)");
  }

  private currentInbox(): InboxState | undefined {
    return this.events.view.docs["pi.inbox"] as InboxState | undefined;
  }

  async withdrawNativeQueue(
    itemId: string | undefined,
    permit: SessionRuntimeTransactionPermit,
  ): Promise<MessageQueueState> {
    this.transactions.assertPermit(permit, "exclusive");
    this.assertOpen();
    const withdrawn = await (await this.controller()).cancelQueued(itemId);
    return { version: this.inboxVersion(), ...withdrawn };
  }

  respondToExtensionUIRequest(response: ExtensionUIResponsePayload): Promise<boolean> {
    this.assertOpen();
    return this.ui.respond(response);
  }
  /** Reload AGENTS files, Skills, then every session's plugins (`reloadPluginsOrThrow`). */
  async reloadResources(reloadRuntimeConfig?: () => void): Promise<{ success: true }> {
    this.assertOpen();
    reloadRuntimeConfig?.();
    // As an SDK session's `/reload` rebuilds its runtime: Pi's settings are read again, so a
    // change to one (the cache miss notice) applies to this session without restarting it.
    await this.piSettings.reload();
    const resources = await this.loadResources();
    this.assertOpen();
    await syncProjectContext(this.conversation, resources);
    this.resources = resources;
    await this.host.runtime.reloadPluginsOrThrow();
    return { success: true };
  }
  /**
   * Fork points: the user rows of the durable trace, by the same decimal entry ids. Generated
   * inputs (cards) and compaction entries (a user-role summary the trace shows as a compaction)
   * are not user rows. Media-only messages are, so they list with a placeholder, not their bytes.
   */
  async forkMessages(): Promise<Array<{ entryId: string; text: string }>> {
    this.assertOpen();
    const records = await this.historyEntries();
    const cards = await readDurableInputCards(
      this.harness,
      records.map((entry) => entry.conversationId),
    );
    return records.flatMap((entry) => {
      const message = entry.model?.[0];
      if (message?.role !== "user" || entry.kind === "pi.compaction" || cards.entries.has(entry.id))
        return [];
      const text = forkMessageText(message.content);
      return text ? [{ entryId: String(entry.id), text }] : [];
    });
  }
  // A durable conversation has no in-place leaf. Navigating would fork the conversation and
  // rebind this session to the fork, which drops every later turn from the tree, cannot
  // summarize the abandoned branch, and abandons the old conversation's background work. The
  // tree view would then misread the session. `get_fork_messages` + `fork` is the supported
  // way to continue from an earlier turn, as its own session.
  sessionTree(): never {
    return this.unsupported("sessionTree (fork a message instead)");
  }
  leafId(): null {
    return null;
  }
  navigateTree(): never {
    return this.unsupported("navigateTree (fork a message instead)");
  }
  /**
   * Only what a durable session runs from a slash command: `/compact` and `/share` have
   * backend commands, `/reload` rebuilds resources, `/skill:*` expands in `prompt`. Fork, tree,
   * new and resume replace the session's identity or leaf (unsupported here), and classic
   * extension and prompt-template commands cannot load, so none of them is advertised.
   */
  commands(): ReturnType<AgentBackend["commands"]> {
    return {
      commands: [
        {
          name: "reload",
          description: "Reload plugins, skills and context files",
          source: "builtin",
        },
        {
          name: "compact",
          description: "Manually compact the session context",
          source: "builtin",
        },
        {
          name: "share",
          description: "Share session as an auto-redacted secret GitHub gist",
          source: "builtin",
        },
        ...this.resources.skills.map((skill) => ({
          name: `skill:${skill.name}`,
          description: skill.description,
          source: "skill" as const,
          location: toCommandLocation(skill.sourceInfo.source),
          path: skill.filePath,
        })),
      ],
    };
  }
  /** Offered tools, then the deferred ones `tool_search` can load, each under its extension. */
  private contextTools(agent: Awaited<ReturnType<Conversation["agent"]>>): ContextToolSnapshot[] {
    const source = (name: string): ContextToolSource => {
      const server = this.mcp?.serverOf(name);
      if (server !== undefined) return { kind: "mcp", name: server };
      const extension = agent.extensions.find((candidate) =>
        candidate.tools?.some((tool) => tool.name === name),
      );
      return { kind: "extension", name: extension?.name ?? "" };
    };
    return [
      ...agent.tools.map((tool) => ({ tool, inContext: true })),
      ...agent.deferred.map((tool) => ({ tool, inContext: false })),
    ].map(({ tool, inContext }) => ({
      name: tool.name,
      tokens: estimateToolDeclarationTokens(tool),
      inContext,
      source: source(tool.name),
    }));
  }

  /** Pi's exporter over the whole conversation, with the active system prompt and offered tools. */
  async exportToHtml(outputPath: string): Promise<string> {
    this.assertOpen();
    const agent = await this.conversation.agent(BACKGROUND_CONTEXT);
    return exportDurableToHtml({
      entries: await readDurableSessionEntries(this.harness, this.conversation.id),
      cwd: agent.cwd ?? "",
      state: {
        systemPrompt: getCurrentSystemPrompt(
          (await this.contextEntries()).flatMap((entry) => entry.model ?? []),
        ),
        tools: agent.tools.map((tool) => ({
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        })),
      },
      outputPath,
      themeName: this.host.runtime.runPolicySettings.getTheme(),
    });
  }
  // The four settings below are the Harness's run policy: global user settings it reads at every
  // use, written exactly as a classic session writes them. They apply to every durable
  // conversation from its next boundary or attempt, not to this session alone.
  setAutoCompactionEnabled(enabled: boolean): void {
    this.assertOpen();
    this.host.runtime.runPolicySettings.setCompactionEnabled(enabled);
  }
  setSteeringMode(mode: "all" | "one-at-a-time"): void {
    this.assertOpen();
    this.host.runtime.runPolicySettings.setSteeringMode(mode);
  }
  setFollowUpMode(mode: "all" | "one-at-a-time"): void {
    this.assertOpen();
    this.host.runtime.runPolicySettings.setFollowUpMode(mode);
  }
  setAutoRetryEnabled(enabled: boolean): void {
    this.assertOpen();
    this.host.runtime.runPolicySettings.setRetryEnabled(enabled);
  }
  async abortRetry(): Promise<void> {
    this.assertOpen();
    await (await this.controller()).abortRetry();
  }
  getEntryRenderers(): undefined {
    return undefined;
  }
  // Only the E2E UI harness fixture route calls this (OPPI_E2E_UI_HARNESS). It is a synchronous
  // test seam that forges an assistant turn; a durable transcript has no such edit.
  appendAssistantMessage(): never {
    return this.unsupported("appendAssistantMessage");
  }
}

/**
 * Turn one extension, and the tool names it offers, on or off in a stored `pi.agent` selection,
 * whichever form it has: an exact list, or an `{ add, remove }` edit of the host default (which
 * never carries this extension). An unset tool filter enables every selected tool. Writes only
 * what changes.
 */
function selectExtension(
  state: AgentState,
  name: string,
  tools: readonly string[],
  on: boolean,
): void {
  const extensions = state.extensions;
  if (Array.isArray(extensions)) {
    if (on && !extensions.includes(name)) state.extensions = [...extensions, name];
    if (!on && extensions.includes(name))
      state.extensions = extensions.filter((entry) => entry !== name);
  } else {
    const add = extensions?.add ?? [];
    if (on && !add.includes(name)) state.extensions = { ...extensions, add: [...add, name] };
    if (!on && add.includes(name))
      state.extensions = { ...extensions, add: add.filter((entry) => entry !== name) };
  }
  if (!Array.isArray(state.tools)) return;
  const selected = state.tools;
  const missing = tools.filter((tool) => !selected.includes(tool));
  if (on && missing.length) state.tools = [...selected, ...missing];
  if (!on && selected.some((tool) => tools.includes(tool)))
    state.tools = selected.filter((tool) => !tools.includes(tool));
}

import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AttachedReplicatedState } from "@earendil-works/chord";
import {
  ModelRegistry,
  SettingsManager,
  getAgentDir,
  hasTrustRequiringProjectResources,
  type ModelRuntime,
  type CompactionResult,
} from "@earendil-works/pi-coding-agent";
import {
  watchEvents,
  AgentDoc,
  type AgentChange,
  type AgentEventStream,
  type ModelRef,
  type Conversation,
  type ConversationView,
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
  sortedModelUsage,
  TOOLS_SUMMARIES_USAGE_KEY,
  TOOLS_SUMMARIES_USAGE_LABEL,
  type SessionModelUsageSnapshot,
} from "./session-stats.js";
import { durableUnsupportedFeature, type AgentDefinition } from "./agent-launch-service.js";
import {
  OppiAgentDoc,
  resolveDurableAgent,
  toolAllowed,
  type OppiAgentState,
} from "./durable-agent.js";
import type { AgentBackend } from "./agent-backend.js";
import { isControlConversation } from "./control-session.js";
import { readRequestDisplay, type DurableAgentController } from "./durable-agent-controller.js";
import { controlConversationTools } from "./durable-control-conversation.js";
import { DurableRuntime, type SessionHost } from "./durable-harness.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import { DurableSandboxTools } from "./durable-sandbox-tools.js";
import { readDurableInputCards } from "./durable-input-cards.js";
import { DurableEventProjection } from "./durable-event-projection.js";
import { exportDurableToHtml } from "./durable-export.js";
import { readDurableSessionEntries } from "./durable-history.js";
import type { PiMessage, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import type { SdkBackendDisposeResult } from "./sdk-backend.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import {
  SdkBackend,
  resolveSessionSeedModel,
  resolveSdkSessionCwdAsync,
  toCommandLocation,
  type QueuedModelTurnBatch,
} from "./sdk-backend.js";
import { resolveSandboxGuestCwd } from "./workspace-folder.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "./session-runtime-transaction.js";
import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";
import type { MessageQueueState, Session, Workspace } from "./types.js";
import { DurableAsk } from "../extensions/durable/ask/durable.js";
import { DurableBackgroundJobs } from "../extensions/durable/background-jobs/durable.js";
import {
  DURABLE_QUEUE_REQUEST_ID_PREFIX,
  DURABLE_RESERVED_REQUEST_ID_PREFIXES,
} from "./durable-request-ids.js";
import {
  DURABLE_FAILURE_ENTRY_KIND,
  inputFailureText,
  reconcileFailureCards,
  recordInputFailure,
  recordTaskFailure,
} from "./durable-failure-cards.js";
import { sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";
import {
  DurableWorkingWords,
  ensureWorkingWords,
} from "../extensions/durable/working-words/durable.js";
import { DurableUIProjection } from "./durable-ui-projection.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import { DurableMcp } from "./durable-mcp.js";
import type { GondolinVm } from "./gondolin-ops.js";
import { sandboxMcpForWorkspace } from "./sandbox-mcp.js";
import {
  expandSkillCommand,
  readSandboxContextFiles,
  loadDurableProjectResources,
  renderProjectContext,
  renderSkills,
  type DurableProjectResources,
} from "./durable-project-resources.js";
import {
  ProjectContextDoc,
  DurableProjectContext,
} from "../extensions/durable/project-context/durable.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { managedProjectTrustContext, resolveManagedProjectTrust } from "./project-trust.js";
import { SdkUiBridge } from "./sdk-ui-bridge.js";

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
  metrics?: ServerMetricCollector;
  hasUI?: () => boolean;
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
  /** Its `oppi.agent` document; undefined for a conversation bound before the document existed. */
  doc: OppiAgentState | undefined;
  /** It may use `subagent spawn`. */
  spawn: boolean;
  /** For the conversation this attach creates: the resolved agent and document. */
  created?: ReturnType<typeof resolveDurableAgent>;
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

/** Store the rendered sections; a changed section reaches the model on its next request. */
async function syncProjectContext(
  conversation: Conversation,
  resources: DurableProjectResources,
): Promise<void> {
  const tools = (await conversation.agent(BACKGROUND_CONTEXT)).tools.map((tool) => tool.name);
  const next = {
    projectContext: renderProjectContext(resources.contextFiles),
    skills: renderSkills(resources.skills, tools),
  };
  await conversation.commit(async (tx) => {
    const doc = await tx.doc(ProjectContextDoc, conversation.id);
    for (const key of ["projectContext", "skills"] as const) {
      const value = next[key];
      if (doc[key] === value) continue;
      if (value === undefined) delete doc[key];
      else doc[key] = value;
    }
  }, BACKGROUND_CONTEXT);
}

/**
 * The classic-event facade of a conversation for the session socket: classic events, lifecycle
 * permits, Skill expansion, and the queue version over the host's `AgentController` and `Models`,
 * which own input, run, and model control. The Harness owns execution and queues.
 */
export class DurableBackend implements AgentBackend {
  private readonly transactions = new SessionRuntimeTransaction();
  private readonly projection: DurableEventProjection;
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
  readonly showCacheMissNotices = false;
  readonly retainsIdleQueueUntilAdmission = true;
  private queueVersion = 0;
  private queueFingerprint = "";
  /** Error texts the current run already showed live; cleared when it ends. */
  private readonly shownRunErrors = new Set<string>();

  private constructor(
    private readonly harness: Harness,
    private readonly host: SessionHost,
    private readonly conversation: Conversation,
    models: ModelRuntime,
    private readonly session: Session,
    private readonly view: AttachedReplicatedState<ConversationView>,
    private readonly events: AgentEventStream,
    private readonly onEvent: (event: SessionBackendEvent) => void,
    private readonly mcp: DurableMcp | undefined,
    private resources: DurableProjectResources,
    private readonly loadResources: () => Promise<DurableProjectResources>,
    private readonly dataDir: string,
    /** Reads a presented Skill file: the VM for a sandbox, the host otherwise. */
    private readonly readSkillFile: (path: string) => Promise<string>,
  ) {
    this.registry = new ModelRegistry(models);
    this.projection = new DurableEventProjection(harness, () => host.runtime.retrySettings ?? {});
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
    const launched = control
      ? undefined
      : await DurableBackend.launchedAs(options, { hostCwd, cwd, sandbox });
    // Sandboxes see only the workspace, as SDK sandbox sessions: trusted.
    const projectTrusted = sandbox || (await resolveProjectTrust(hostCwd, agentDir, options));
    const loadResources = (): Promise<DurableProjectResources> =>
      loadDurableProjectResources({
        hostCwd,
        agentDir,
        ...(sandbox ? { sandboxGuestCwd: cwd } : {}),
        projectTrusted,
        ...(launched?.doc?.resources ? { resources: launched.doc.resources } : {}),
        projectContext: launched?.doc?.projectContext !== false,
      });
    const resources = await loadResources();
    // Set by `bind` once this attachment's workspace VM is up, before servers connect.
    let sandboxVm: GondolinVm | undefined;
    // The control conversation selects an exact extension list; it gets no MCP tools, and an
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
                        if (!sandboxVm) throw new Error("The sandbox VM is not ready");
                        return sandboxVm;
                      },
                    }),
                  }
                : {}),
              policy: session.launch?.tools,
              providerToken: (provider) => registry.getApiKeyForProvider(provider),
              install: (extension) => host.runtime.installExtension(extension),
              uninstall: (extension) => host.runtime.uninstallExtension(extension),
              metrics: options.metrics,
            });
          });
    try {
      return await DurableBackend.bind(options, {
        hostCwd,
        cwd,
        mcp,
        launched,
        onSandboxVm: (vm) => {
          sandboxVm = vm;
        },
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
    target: { hostCwd: string; cwd: string; sandbox: boolean },
  ): Promise<LaunchedAs> {
    const { harness, session, host } = options;
    const id = session.serverDurable?.conversationId as ConversationId | undefined;
    if (id !== undefined) {
      const doc = await harness.snapshot(OppiAgentDoc, id, BACKGROUND_CONTEXT);
      if (doc) return { doc, spawn: doc.spawn };
      const record = await harness.commit((tx) => tx.conversation(id), BACKGROUND_CONTEXT);
      return { doc: undefined, spawn: record?.owner === undefined };
    }
    const runtime = target.sandbox ? "sandbox" : "host";
    const grant = session.launch?.allowsNestedDelegation === true;
    // As `oppi session create --parent`: a delegated session spawns only with the grant.
    const spawn = !session.launch?.parentSessionId || grant;
    const agentId = session.launch?.agentId;
    const definition = options.agentDefinition;
    const workspacePrompt = options.workspace?.systemPrompt;
    const created = resolveDurableAgent({
      ...(agentId && definition
        ? { saved: { id: agentId, version: session.launch?.agentVersion ?? 0, definition } }
        : {}),
      ...seedModel(options.models, target.hostCwd, session),
      ...(session.launch?.tools ? { policy: session.launch.tools } : {}),
      runtime,
      base: [
        CodingTools,
        ...(target.sandbox ? [DurableSandboxTools] : []),
        DurableAsk,
        DurableWorkingWords,
        DurableBackgroundJobs,
        DurableProjectContext,
        ...host.runtime.packageExtensionsFor(runtime),
      ],
      loaded: host.runtime.loadedPackages,
      sessions: host.runtime.sessionsExtension,
      spawn,
      grant,
      instructions: { cwd: target.cwd, ...(workspacePrompt ? { workspacePrompt } : {}) },
    });
    return { doc: created.doc, spawn, created };
  }

  private static async bind(
    options: DurableBackendOptions,
    target: {
      hostCwd: string;
      cwd: string;
      mcp: DurableMcp | undefined;
      launched: LaunchedAs | undefined;
      onSandboxVm: (vm: GondolinVm) => void;
      resources: DurableProjectResources;
      loadResources: () => Promise<DurableProjectResources>;
    },
  ): Promise<DurableBackend> {
    const { harness, models, session, host } = options;
    const { hostCwd, cwd, mcp, resources, launched } = target;
    const workspace = options.workspace;
    const sandbox = workspace?.runtime === "sandbox";
    const id = session.serverDurable?.conversationId;
    const control = isControlConversation(session);
    // Extensions from Pi packages' durable entries allowed in this runtime, or the exact
    // selection the session launched with; never on control.
    const exact = launched?.doc?.extensions?.packages;
    const packageExtensions = control
      ? []
      : exact
        ? host.runtime.loadedPackages
            .filter((loaded) => exact.includes(loaded.extension.name))
            .map((loaded) => loaded.extension)
        : host.runtime.packageExtensionsFor(sandbox ? "sandbox" : "host");
    // A child without the `allowNestedDelegation` grant has no `subagent` tool.
    const sessionsExtension = launched?.spawn ? [host.runtime.sessionsExtension] : [];
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
      // Bound conversations store exact extension/tool names. Enroll the native
      // UI ports and this attachment's MCP extension too, without overriding
      // their launch tool policy. The control conversation instead re-asserts its exact
      // selection, so one created before an extension joined the list picks it up here.
      await conversation.configure(
        control
          ? {
              extensions: [...host.runtime.controlExtensions],
              tools: controlConversationTools(host.runtime.controlExtensions),
            }
          : {
              extensions: {
                add: [
                  DurableAsk,
                  DurableWorkingWords,
                  DurableBackgroundJobs,
                  ...sessionsExtension,
                  DurableProjectContext,
                  ...packageExtensions,
                  ...(mcp ? [mcp.selection] : []),
                ],
                // The host default selection includes it.
                ...(sessionsExtension.length ? {} : { remove: [host.runtime.sessionsExtension] }),
              },
            },
        BACKGROUND_CONTEXT,
      );
      const agent = await conversation.agent(BACKGROUND_CONTEXT);
      const policy = session.launch?.tools;
      const selected = new Set(agent.tools.map((tool) => tool.name));
      const additions = (
        control
          ? []
          : [
              DurableAsk,
              DurableWorkingWords,
              DurableBackgroundJobs,
              ...sessionsExtension,
              ...packageExtensions,
            ]
      )
        .flatMap((extension) => extension.tools ?? [])
        .filter((tool) => !selected.has(tool.name) && toolAllowed(policy, tool.name));
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
      // The control conversation's instructions are its `oppi-control` prompt section.
      const agent: AgentChange = created
        ? {
            ...created.change,
            cwd,
            extensions: [...created.change.extensions, ...(mcp ? [mcp.selection] : [])],
            tools: [...created.change.tools, ...(mcp?.initialTools ?? [])],
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
    // Skill and context-file bytes come through the session's own view: the VM for a
    // sandbox, whose shadow and mount jails the host loader does not apply.
    const readInView = sandbox
      ? (path: string) => options.host.readSandboxTextFile(conversation.id, path)
      : (path: string) => readFile(path, "utf-8");
    const present = async (loaded: DurableProjectResources): Promise<DurableProjectResources> =>
      sandbox ? readSandboxContextFiles(loaded, readInView, hostCwd, cwd) : loaded;
    if (sandbox) {
      const vm = await SdkBackend.ensureSandboxWorkspaceVm(workspace, hostCwd, [
        ...resources.readonlyMounts,
      ]);
      const probe = await vm.exec(["/usr/bin/setsid", "/bin/true"]);
      if (!probe.ok) throw new Error("Durable sandbox execution requires guest setsid");
      const env = new GondolinExecutionEnv(vm, workspace.id, cwd);
      options.host.bindSandboxEnv(conversation.id, env);
      // Stdio MCP servers run in this VM; they connect at `attach` below.
      target.onSandboxVm(vm);
    }
    // After the VM is bound: a sandbox's context files are read through it.
    const presented = await present(resources);
    await syncProjectContext(conversation, presented);
    await conversation.commit((tx) => ensureWorkingWords(tx, conversation.id), BACKGROUND_CONTEXT);
    mcp?.attach(conversation);
    const view = await conversation.viewState(BACKGROUND_CONTEXT);
    try {
      // A run in progress resumes after this attachment; its MCP tool calls must find
      // their tools, so let the servers connect first (bounded).
      if (mcp && (view.value.docs["pi.live"] as LiveState | undefined)?.run !== undefined)
        await mcp.waitForStartup();
      const events = await watchEvents(harness, conversation.id, BACKGROUND_CONTEXT);
      const backend = new DurableBackend(
        harness,
        options.host,
        conversation,
        models,
        session,
        view,
        events,
        options.onEvent,
        mcp,
        presented,
        async () => present(await target.loadResources()),
        options.dataDir,
        readInView,
      );
      backend.ui = await DurableUIProjection.create(harness, conversation, options.onEvent);
      await backend.projection.refreshInputCards([
        conversation.id,
        ...events.snapshot.entries.map((entry) => entry.conversationId),
      ]);
      return backend;
    } catch (error) {
      view.dispose();
      throw error;
    }
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
    for (const event of this.projection.snapshot(this.events.snapshot, this.host.isResumeHeld))
      this.onEvent(event);
    this.events.start(async (events) => {
      if (this.disposed) return;
      // A new run starts with nothing shown, also after an idle task's failure. A batch
      // that also ends a run keeps that run's texts until its settlement is handled below.
      if (
        events.some((event) => event.type === "run_start") &&
        !events.some((event) => event.type === "run_end")
      )
        this.shownRunErrors.clear();
      for (const pi of await this.projection.batch(events)) {
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
      for (const event of events) {
        if (event.type === "message_end") {
          const card = this.projection.inputCards.entries.get(event.entry.id);
          if (card)
            this.onEvent({
              type: "notice",
              id: `entry:${event.entry.id}`,
              message: `${card.title}${card.status ? ` · ${card.status}` : ""}${card.body ? ` — ${card.body}` : ""}`,
            });
        }
        if (
          event.type === "entry_appended" &&
          !event.entry.model?.length &&
          event.entry.kind !== DURABLE_FAILURE_ENTRY_KIND
        ) {
          const data = event.entry.data;
          const card = sanitizeTranscriptCard(
            data && typeof data === "object" && !Array.isArray(data) ? data.card : undefined,
          );
          if (card)
            this.onEvent({
              type: "notice",
              id: `entry:${event.entry.id}`,
              message: card.body ? `${card.title} — ${card.body}` : card.title,
            });
        }
        // Native placement carries identity. Recover display metadata by request,
        // never by matching user text or keeping an Oppi queue shadow.
        if (
          event.type === "submission" &&
          event.record.type === "input" &&
          event.record.status === "placed" &&
          event.record.requestId
        ) {
          const display = await readRequestDisplay(
            this.harness,
            this.conversation.id,
            event.record.requestId,
          );
          if (
            display &&
            (display.kind === "steer" || display.kind === "followUp") &&
            !this.projection.inputCards.submissions.has(event.record.id)
          ) {
            this.onEvent({
              type: "queue_item_started",
              kind: display.kind === "steer" ? "steer" : "follow_up",
              item: {
                id: String(event.record.id),
                message: display.message,
                createdAt: display.createdAt,
                ...(display.attachments.length ? { attachments: display.attachments } : {}),
              },
              queueVersion: this.inboxVersion(),
            });
          }
        }
        if (event.type === "inbox_update")
          this.onEvent({ type: "queue_update", ...this.queuedMessages() });
        // Inputs from any source (a background job's follow-up, a reporter) get their card
        // here; the request id makes the controller's own write for its prompts a no-op.
        // The live error is the card's text, written or not, once per run.
        if (
          event.type === "submission" &&
          event.record.type === "input" &&
          event.record.status === "unanswered"
        ) {
          this.showRunError(inputFailureText(event.record));
          try {
            await recordInputFailure(this.conversation, event.record);
          } catch (error) {
            log.warn("durable_failure.input_card_failed", {
              submissionId: event.record.id,
              error: safeErrorMessage(error),
            });
          }
        }
        // A generation fault also settles its inputs, which record the card; a compaction
        // failure shows on its compaction row.
        if (
          event.type === "task_failed" &&
          event.kind !== "pi.compaction" &&
          event.kind !== "pi.generation"
        ) {
          this.showRunError(event.message.trim() || event.kind);
          try {
            await recordTaskFailure(this.conversation, {
              id: event.taskId,
              kind: event.kind,
              message: event.message,
            });
          } catch (error) {
            log.warn("durable_failure.task_card_failed", {
              taskId: event.taskId,
              error: safeErrorMessage(error),
            });
          }
        }
      }
      // A run's settlement commits with its end, so its errors are in this batch or earlier.
      // A later run starts with nothing shown.
      if (events.some((event) => event.type === "run_end")) this.shownRunErrors.clear();
    });
    // After the listener is attached. A commit, not Conversation.submit, so a
    // held startup scheduler stays held. A crash between settlement and the
    // card write is filled here; a card that already landed is a no-op.
    // A failed scan fails the attach. Swallowing it would leave the miss hidden.
    if (this.disposed) return;
    await reconcileFailureCards(this.conversation, this.host.storage);
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
    return (this.view.value.docs["pi.agent"] as AgentState) ?? {};
  }
  private get live(): LiveState {
    return (this.view.value.docs["pi.live"] as LiveState) ?? {};
  }
  get isDisposed(): boolean {
    return this.disposed;
  }
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
  /** Projection teardown only: the recorded original submission must survive shutdown. */
  detachForRestart(): Promise<void> {
    return (this.detaching ??= (async () => {
      this.disposed = true;
      this.lifetime.abort(new Error("Session backend is disposed"));
      await this.ui.stop();
      await this.events.stop();
      this.view.dispose();
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
      (item) => !this.projection.inputCards.submissions.has(item.id),
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
  messages(): PiMessage[] {
    return this.view.value.entries.flatMap((entry) =>
      this.projection.recoveredEntryIds.has(entry.id) ||
      this.projection.inputCards.entries.has(entry.id)
        ? []
        : (entry.model ?? []),
    );
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
    const messages = this.messages();
    const usage = this.view.value.docs["pi.usage"] as UsageState | undefined;
    const tokens = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
    let cost = 0;
    const byModel = new Map<string, SessionModelUsageSnapshot>();
    for (const [key, value] of Object.entries(usage?.models ?? {})) {
      // `pi.usage` keys models as `provider/modelId`.
      const slash = key.indexOf("/");
      addUsageToModelBreakdown(
        byModel,
        key,
        slash < 0 ? key : key.slice(slash + 1),
        slash < 0 ? undefined : key.slice(0, slash),
        value,
      );
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
      this.view.value.entries.flatMap((entry) => entry.model ?? []),
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
    const usageBefore = this.messages()
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
  promptCacheRuntime(): ReturnType<AgentBackend["promptCacheRuntime"]> {
    const model = this.agent.model;
    const promptCache = model
      ? this.registry.find(model.provider, model.modelId)?.promptCache
      : undefined;
    return promptCache ? { promptCache } : {};
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
    return this.view.value.docs["pi.inbox"] as InboxState | undefined;
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
  /** Reload AGENTS files and Skills; the next request sends the changed sections. */
  async reloadResources(reloadRuntimeConfig?: () => void): Promise<{ success: true }> {
    this.assertOpen();
    reloadRuntimeConfig?.();
    const resources = await this.loadResources();
    this.assertOpen();
    await syncProjectContext(this.conversation, resources);
    this.resources = resources;
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
  commands(): ReturnType<AgentBackend["commands"]> {
    return {
      commands: [
        {
          name: "reload",
          description: "Reload skills and context files",
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
  /** Pi's exporter over the whole conversation, with the active system prompt and offered tools. */
  async exportToHtml(outputPath: string): Promise<string> {
    this.assertOpen();
    const agent = await this.conversation.agent(BACKGROUND_CONTEXT);
    return exportDurableToHtml({
      entries: await readDurableSessionEntries(this.harness, this.conversation.id),
      cwd: agent.cwd ?? "",
      state: {
        systemPrompt: getCurrentSystemPrompt(
          this.view.value.entries.flatMap((entry) => entry.model ?? []),
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

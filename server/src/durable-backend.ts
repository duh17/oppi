import { randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
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
  InboxDoc,
  defineDocFamily,
  type AgentEventStream,
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
import type { AgentDefinition } from "./agent-launch-service.js";
import type { AgentBackend } from "./agent-backend.js";
import { DurableRuntime, type DurableHarness } from "./durable-harness.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import { DurableSandboxTools } from "./durable-sandbox-tools.js";
import { readDurableInputCards, resolveDurableInputCards } from "./durable-input-cards.js";
import { DurableEventProjection } from "./durable-event-projection.js";
import type { PiMessage, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import type { SdkBackendDisposeResult } from "./sdk-backend.js";
import {
  SdkBackend,
  resolveSandboxGuestCwd,
  resolveSessionSeedModel,
  resolveSdkSessionCwd,
  toCommandLocation,
  type QueuedModelTurnBatch,
} from "./sdk-backend.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "./session-runtime-transaction.js";
import { isThinkingLevel, THINKING_LEVELS, type ThinkingLevel } from "./thinking-levels.js";
import type {
  ChatAttachmentRef,
  MessageQueueItem,
  MessageQueueState,
  Session,
  Workspace,
} from "./types.js";
import { DurableAsk } from "../extensions/durable/ask/durable.js";
import { DurableBackgroundJobs } from "../extensions/durable/background-jobs/durable.js";
import {
  DURABLE_QUEUE_REQUEST_ID_PREFIX,
  DURABLE_RESERVED_REQUEST_ID_PREFIXES,
} from "./durable-request-ids.js";
import { DurableGoal } from "../extensions/durable/goal/durable.js";
import { sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";
import {
  DurableWorkingWords,
  ensureWorkingWords,
} from "../extensions/durable/working-words/durable.js";
import { DurableUIProjection } from "./durable-ui-projection.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import { DurableMcp } from "./durable-mcp.js";
import {
  expandSkillCommand,
  loadDurableProjectResources,
  renderProjectContext,
  renderSkills,
  type DurableProjectResources,
} from "./durable-project-resources.js";
import {
  ProjectContextDoc,
  DurableProjectContext,
} from "../extensions/durable/project-context/durable.js";
import { safeErrorMessage } from "./log-utils.js";
import { managedProjectTrustContext, resolveManagedProjectTrust } from "./project-trust.js";
import { SdkUiBridge } from "./sdk-ui-bridge.js";

export class DurableNotSupportedError extends Error {
  readonly code = "server_durable_not_supported";
  constructor(readonly operation: string) {
    super(`${operation} is not supported for server durable sessions`);
    this.name = "DurableNotSupportedError";
  }
}

// Submission records omit content after queued input withdrawal. Keep its
// fingerprint durable too, so a later replay cannot silently change that input.
const RequestContent = defineDocFamily<{ content: string; display?: string }, null>({
  kind: "oppi.request-content",
  version: 1,
  family: true,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ content: "" }),
});

interface DurableBackendOptions {
  harness: Harness;
  owner: DurableHarness;
  models: ModelRuntime;
  session: Session;
  workspace?: Workspace;
  agentDefinition?: AgentDefinition;
  dataDir: string;
  persistBinding: () => void;
  onEvent: (event: SessionBackendEvent) => void;
  /** Startup dialogs (project trust) before the projection exists, as for SDK sessions. */
  onUIBridgeReady?: (bridge: SdkUiBridge | undefined) => void;
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

/** Store the rendered sections; a changed section reaches the model on its next request. */
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

/** An AgentBackend over a conversation; the Harness owns execution and queues. */
export class DurableBackend implements AgentBackend {
  private readonly transactions = new SessionRuntimeTransaction();
  private readonly projection: DurableEventProjection;
  private ui!: DurableUIProjection;
  private disposed = false;
  private eventsStarted = false;
  private admissions: Promise<void> = Promise.resolve();
  private detaching?: Promise<void>;
  private readonly registry: ModelRegistry;
  readonly abortClearsQueuedModelTurns = true;
  readonly cancelsExtensionUIOnAbort = true;
  readonly isQueueReconciliationRequired = false;
  readonly showCacheMissNotices = false;
  readonly retainsIdleQueueUntilAdmission = true;
  private queueVersion = 0;
  private queueFingerprint = "";

  private constructor(
    private readonly harness: Harness,
    private readonly owner: DurableHarness,
    private readonly conversation: Conversation,
    models: ModelRuntime,
    private readonly session: Session,
    private readonly view: AttachedReplicatedState<ConversationView>,
    private readonly events: AgentEventStream,
    private readonly onEvent: (event: SessionBackendEvent) => void,
    private readonly mcp: DurableMcp | undefined,
    private resources: DurableProjectResources,
    private readonly loadResources: () => Promise<DurableProjectResources>,
  ) {
    this.registry = new ModelRegistry(models);
    this.projection = new DurableEventProjection(harness, () => owner.retrySettings ?? {});
  }

  static async create(options: DurableBackendOptions): Promise<DurableBackend> {
    const { models, session, agentDefinition } = options;
    if (session.ephemeral) throw new DurableNotSupportedError("Incognito sessions");
    // Classic extension factories cannot run in a durable conversation.
    if (agentDefinition?.resources?.extensionIds?.length)
      throw new DurableNotSupportedError("Saved Agent Extensions");
    const workspace = options.workspace;
    const sandbox = workspace?.runtime === "sandbox";
    if (sandbox && options.workspace?.sandboxConfig?.mcpServers?.length)
      throw new DurableNotSupportedError("Sandbox MCP servers");
    const hostCwd = resolveSdkSessionCwd(options.workspace, session, { dataDir: options.dataDir });
    const cwd = sandbox ? resolveSandboxGuestCwd(workspace) : hostCwd;
    const owner = options.owner;
    const agentDir = getAgentDir();
    // Sandboxes see only the workspace, as SDK sandbox sessions: trusted.
    const projectTrusted = sandbox || (await resolveProjectTrust(hostCwd, agentDir, options));
    const resources = await loadDurableProjectResources({
      hostCwd,
      agentDir,
      ...(sandbox ? { sandboxGuestCwd: cwd } : {}),
      projectTrusted,
      agentDefinition,
    });
    const mcp = sandbox
      ? undefined
      : await owner.replaceMcp(session.id, async () => {
          const registry = new ModelRegistry(models);
          return DurableMcp.open({
            sessionId: session.id,
            cwd: hostCwd,
            agentDir,
            projectTrusted,
            policy: session.launch?.tools,
            providerToken: (provider) => registry.getApiKeyForProvider(provider),
            install: (extension) => owner.installExtension(extension),
            uninstall: (extension) => owner.uninstallExtension(extension),
          });
        });
    try {
      return await DurableBackend.bind(options, {
        hostCwd,
        cwd,
        mcp,
        resources,
        loadResources: () =>
          loadDurableProjectResources({
            hostCwd,
            agentDir,
            ...(sandbox ? { sandboxGuestCwd: cwd } : {}),
            projectTrusted,
            agentDefinition,
          }),
      });
    } catch (error) {
      await owner.closeMcp(session.id);
      throw error;
    }
  }

  private static async bind(
    options: DurableBackendOptions,
    target: {
      hostCwd: string;
      cwd: string;
      mcp: DurableMcp | undefined;
      resources: DurableProjectResources;
      loadResources: () => Promise<DurableProjectResources>;
    },
  ): Promise<DurableBackend> {
    const { harness, models, session, agentDefinition } = options;
    const { hostCwd, cwd, mcp, resources } = target;
    const workspace = options.workspace;
    const sandbox = workspace?.runtime === "sandbox";
    const id = session.serverDurable?.conversationId;
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
      // their launch tool policy.
      await conversation.configure(
        {
          extensions: {
            add: [
              DurableAsk,
              DurableWorkingWords,
              DurableBackgroundJobs,
              DurableGoal,
              DurableProjectContext,
              ...(mcp ? [mcp.selection] : []),
            ],
          },
        },
        BACKGROUND_CONTEXT,
      );
      const agent = await conversation.agent(BACKGROUND_CONTEXT);
      const policy = session.launch?.tools;
      const selected = new Set(agent.tools.map((tool) => tool.name));
      const additions = [DurableAsk, DurableWorkingWords, DurableBackgroundJobs, DurableGoal]
        .flatMap((extension) => extension.tools ?? [])
        .filter(
          (tool) =>
            !selected.has(tool.name) &&
            !policy?.noTools &&
            (!policy?.allowed || policy.allowed.includes(tool.name)) &&
            !policy?.excluded?.includes(tool.name),
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
      const registry = new ModelRegistry(models);
      const settings = SettingsManager.create(hostCwd, getAgentDir(), { projectTrusted: false });
      const defaultModel =
        settings.getDefaultProvider() && settings.getDefaultModel()
          ? `${settings.getDefaultProvider()}/${settings.getDefaultModel()}`
          : undefined;
      const available = registry.getAvailable();
      const first = available[0];
      const model = resolveSessionSeedModel(
        registry,
        session.model ?? defaultModel ?? (first ? `${first.provider}/${first.id}` : ""),
        settings.getEnabledModels(),
      );
      if (!model)
        throw new Error(`Server durable model is unavailable: ${session.model ?? "default"}`);
      const policy = session.launch?.tools;
      const tools = [
        ...(CodingTools.tools ?? []),
        ...(DurableAsk.tools ?? []),
        ...(DurableGoal.tools ?? []),
        ...(sandbox ? (DurableSandboxTools.tools ?? []) : []),
        ...(DurableBackgroundJobs.tools ?? []),
      ].filter(
        (tool) =>
          !policy?.noTools &&
          (!policy?.allowed || policy.allowed.includes(tool.name)) &&
          !policy?.excluded?.includes(tool.name),
      );
      const instructions = agentDefinition?.instructions;
      const append = [
        options.workspace?.systemPrompt,
        instructions?.mode === "append" ? instructions.text : undefined,
      ]
        .filter(Boolean)
        .join("\n\n");
      conversation = await harness.createConversation(
        {
          ownership: { kind: "ownerless" },
          init: async (tx, id) => {
            const runtime = await tx.doc(DurableRuntime, id);
            runtime.kind = sandbox ? "sandbox" : "host";
            if (sandbox) runtime.workspaceId = workspace.id;
          },
          agent: {
            extensions: sandbox
              ? [
                  CodingTools,
                  DurableSandboxTools,
                  DurableAsk,
                  DurableWorkingWords,
                  DurableBackgroundJobs,
                  DurableGoal,
                  DurableProjectContext,
                ]
              : [
                  CodingTools,
                  DurableAsk,
                  DurableWorkingWords,
                  DurableBackgroundJobs,
                  DurableGoal,
                  DurableProjectContext,
                  ...(mcp ? [mcp.selection] : []),
                ],
            model: { provider: model.provider, modelId: model.id },
            thinkingLevel:
              session.thinkingLevel !== undefined && isThinkingLevel(session.thinkingLevel)
                ? session.thinkingLevel
                : settings.getDefaultThinkingLevel(),
            cwd,
            tools: [...tools, ...(mcp?.initialTools ?? [])],
            // Pi's experimental prompt loader is not published in 1.0.0. Do not
            // reach into private dist paths or load classic extension factories.
            instructions: [
              instructions?.mode === "replace"
                ? instructions.text
                : "You are an expert coding assistant. Use the available tools to inspect and change files. Be concise.",
              `Working directory: ${cwd}`,
              append,
            ]
              .filter(Boolean)
              .join("\n\n"),
          },
        },
        BACKGROUND_CONTEXT,
      );
      session.serverDurable = { conversationId: conversation.id };
      // Bind before any submit can be accepted. A crash before this save leaves
      // only an empty unbound conversation, never a duplicated user turn.
      options.persistBinding();
    }
    await syncProjectContext(conversation, resources);
    if (sandbox) {
      const vm = await SdkBackend.ensureSandboxWorkspaceVm(workspace, hostCwd, [
        ...resources.readonlyMounts,
      ]);
      const probe = await vm.exec(["/usr/bin/setsid", "/bin/true"]);
      if (!probe.ok) throw new Error("Durable sandbox execution requires guest setsid");
      const env = new GondolinExecutionEnv(vm, workspace.id, cwd);
      options.owner.bindSandboxEnv(conversation.id, env);
    }
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
        options.owner,
        conversation,
        models,
        session,
        view,
        events,
        options.onEvent,
        mcp,
        resources,
        target.loadResources,
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
  startEvents(): void {
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
    if (!this.owner.isResumeHeld) this.harness.resume();
    for (const event of this.projection.snapshot(this.events.snapshot, this.owner.isResumeHeld))
      this.onEvent(event);
    this.events.start(async (events) => {
      if (this.disposed) return;
      for (const pi of await this.projection.batch(events)) {
        if (this.disposed) return;
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
        if (event.type === "entry_appended" && !event.entry.model?.length) {
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
          const metadata = await this.harness.snapshot(
            RequestContent,
            this.conversation.id,
            event.record.requestId,
            BACKGROUND_CONTEXT,
          );
          const display = metadata?.display
            ? (JSON.parse(metadata.display) as {
                message: string;
                attachments: ChatAttachmentRef[];
                createdAt: number;
                kind?: string;
              })
            : undefined;
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
        if (event.type === "task_failed" && event.kind !== "pi.compaction")
          this.onEvent({ type: "prompt_error", error: event.message });
      }
    });
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
    this.owner.assertSchedulingReady();
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
    this.owner.assertSchedulingReady();
    const clientTurnId = options?.clientTurnId;
    if (
      clientTurnId &&
      DURABLE_RESERVED_REQUEST_ID_PREFIXES.some((prefix) => clientTurnId.startsWith(prefix))
    )
      throw new Error("clientTurnId uses a reserved durable requestId namespace");
    const requestId = clientTurnId ?? `${DURABLE_QUEUE_REQUEST_ID_PREFIX}${randomUUID()}`;
    // The model sees the expanded Skill; queue display keeps what the user typed.
    const text = expandSkillCommand(message, this.resources);
    const content = options?.images?.length
      ? [{ type: "text" as const, text }, ...options.images]
      : text;
    await this.mcp?.beforePrompt();
    // Shared lifecycle permits allow concurrent prompts. Serialize only durable
    // admission so two copies of one request cannot both append a local user row.
    const admission = this.admissions.then(async () => {
      this.assertOpen();
      this.owner.assertSchedulingReady();
      const existing = await this.conversation.commit(async (tx) => {
        const record = await tx.submissionByRequest(this.conversation.id, requestId);
        const queued =
          record && record.entry === undefined
            ? (await tx.doc(InboxDoc, this.conversation.id)).items.find(
                (item) => item.id === record.id,
              )
            : undefined;
        const stored =
          record?.entry !== undefined
            ? (await tx.entry(record.entry))?.model?.find((item) => item.role === "user")?.content
            : queued && queued.mode !== "write"
              ? queued.content
              : undefined;
        const fingerprint = await tx.doc(RequestContent, this.conversation.id, requestId, null);
        if (!record) {
          fingerprint.content = JSON.stringify(content);
          fingerprint.display = JSON.stringify({
            message: options?.queueDisplay?.message ?? message,
            attachments: options?.queueDisplay?.attachments ?? [],
            createdAt: Date.now(),
            kind: options?.streamingBehavior,
          });
          return undefined;
        }
        if (
          stored !== undefined
            ? !isDeepStrictEqual(content, stored)
            : fingerprint.content !== JSON.stringify(content)
        )
          throw new Error(
            "clientTurnId conflict: the stored durable submission has different content",
          );
        return record;
      }, BACKGROUND_CONTEXT);
      const submission = await this.conversation.submit(
        {
          type: "input",
          content,
          requestId,
          whenBusy: options?.streamingBehavior ?? "reject",
        },
        BACKGROUND_CONTEXT,
      );
      if (!existing) options?.onPreflightAccepted?.();
      return { submission, duplicate: existing !== undefined };
    });
    this.admissions = admission.then(
      () => undefined,
      () => undefined,
    );
    const { submission, duplicate } = await admission;
    // Admission, not the whole generation, holds the permit. Abort must not
    // wait behind a stream, and a duplicate can find its settled submission.
    void submission
      .wait(BACKGROUND_CONTEXT)
      .then((settled) => {
        if (!this.disposed && settled.status === "unanswered" && settled.reason !== "aborted") {
          this.onEvent({
            type: "prompt_error",
            error: `Server durable input unanswered: ${settled.reason}`,
          });
        }
      })
      .catch((error: unknown) => {
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
    await this.owner.abortConversation(this.conversation.id);
    this.onEvent({ type: "queue_update", ...this.queuedMessages() });
  }
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
    await this.owner.abortConversation(this.conversation.id);
    await this.detachForRestart();
    await this.owner.unbindSandboxEnv(this.conversation.id);
    await this.owner.closeMcp(this.session.id);
    return { disposal: "graceful" };
  }
  /** Projection teardown only: the recorded original submission must survive shutdown. */
  detachForRestart(): Promise<void> {
    return (this.detaching ??= (async () => {
      this.disposed = true;
      await this.ui.stop();
      await this.events.stop();
      this.view.dispose();
    })());
  }
  captureEmergencyDisposalForStop(): (timeoutMs: number) => Promise<SdkBackendDisposeResult> {
    return async (timeoutMs) => {
      // Never report a successful stop until Durable has admitted cancellation.
      // A rejected abort leaves the projection alive and propagates stop_failed.
      await this.owner.abortConversation(this.conversation.id);
      await this.detachForRestart();
      await this.owner.unbindSandboxEnv(this.conversation.id);
      await this.owner.closeMcp(this.session.id);
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

  private async queueItem(
    item: Exclude<NonNullable<InboxState>["items"][number], { mode: "write" }>,
  ): Promise<MessageQueueItem> {
    const receipt = await this.harness.submission(item.id, BACKGROUND_CONTEXT);
    const record = await receipt?.status(BACKGROUND_CONTEXT);
    const metadata = record?.requestId
      ? await this.harness.snapshot(
          RequestContent,
          this.conversation.id,
          record.requestId,
          BACKGROUND_CONTEXT,
        )
      : undefined;
    const text =
      typeof item.content === "string"
        ? item.content
        : item.content.map((block) => (block.type === "text" ? block.text : "")).join("");
    const display = metadata?.display
      ? (JSON.parse(metadata.display) as {
          message: string;
          attachments: ChatAttachmentRef[];
          createdAt: number;
        })
      : undefined;
    return {
      id: String(item.id),
      message: display?.message ?? text,
      ...(display?.attachments?.length ? { attachments: display.attachments } : {}),
      createdAt: display?.createdAt ?? 0,
    };
  }

  async nativeMessageQueue(): Promise<MessageQueueState> {
    await this.admissions;
    const { internal, items, version } = await this.conversation.commit(async (tx) => {
      // Cards and inbox membership must share a mutation line: a generated
      // report admitted after the card read must not flash as user input.
      const { submissions: internal } = await resolveDurableInputCards(tx, this.conversation.id);
      const inbox = await tx.doc(InboxDoc, this.conversation.id);
      const items = JSON.parse(JSON.stringify(inbox.items)) as InboxState["items"];
      return { internal, items, version: this.inboxVersion(items) };
    }, BACKGROUND_CONTEXT);
    const queue: MessageQueueState = { version, steering: [], followUp: [] };
    for (const item of items) {
      if (item.mode === "write" || internal.has(item.id)) continue;
      queue[item.mode === "steer" ? "steering" : "followUp"].push(await this.queueItem(item));
    }
    return queue;
  }

  queuedMessages(): { steering: readonly string[]; followUp: readonly string[] } {
    const items = (this.currentInbox()?.items ?? []).filter(
      (item) => !this.projection.inputCards.submissions.has(item.id),
    );
    const text = (content: string | readonly { type: string; text?: string }[]) =>
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
  async setModel(modelId: string): Promise<Awaited<ReturnType<AgentBackend["setModel"]>>> {
    this.assertOpen();
    const model = resolveSessionSeedModel(this.registry, modelId);
    if (!model) return { success: false, error: `Model unavailable: ${modelId}` };
    await this.conversation.configure(
      { model: { provider: model.provider, modelId: model.id } },
      BACKGROUND_CONTEXT,
    );
    return {
      success: true,
      provider: model.provider,
      id: model.id,
      name: model.name,
      thinkingLevel: this.agent.thinkingLevel,
    };
  }
  async cycleModel(
    direction: "forward" | "backward" = "forward",
  ): Promise<Awaited<ReturnType<AgentBackend["cycleModel"]>>> {
    const models = this.registry.getAvailable();
    if (!models.length) return undefined;
    const index = models.findIndex(
      (model) =>
        model.provider === this.agent.model?.provider && model.id === this.agent.model?.modelId,
    );
    const next =
      models[(index + (direction === "forward" ? 1 : -1) + models.length) % models.length];
    if (!next) return undefined;
    await this.setModel(`${next.provider}/${next.id}`);
    return {
      model: { provider: next.provider, id: next.id },
      thinkingLevel:
        this.agent.thinkingLevel !== undefined && isThinkingLevel(this.agent.thinkingLevel)
          ? this.agent.thinkingLevel
          : "off",
    };
  }
  async setThinkingLevel(level: ThinkingLevel): Promise<void> {
    this.assertOpen();
    await this.conversation.configure({ thinkingLevel: level }, BACKGROUND_CONTEXT);
  }
  async cycleThinkingLevel(): Promise<ThinkingLevel> {
    const levels = THINKING_LEVELS;
    const next =
      levels[(levels.indexOf(this.agent.thinkingLevel as ThinkingLevel) + 1) % levels.length] ??
      "off";
    await this.setThinkingLevel(next);
    return next;
  }
  setSessionName(name: string): void {
    this.session.name = name;
  }
  async compact(instructions?: string): Promise<CompactionResult> {
    this.assertOpen();
    this.owner.assertSchedulingReady();
    const usageBefore = this.messages()
      .reverse()
      .find((message) => message.role === "assistant")?.usage;
    const tokensBefore =
      usageBefore?.totalTokens ??
      (usageBefore?.input ?? 0) +
        (usageBefore?.output ?? 0) +
        (usageBefore?.cacheRead ?? 0) +
        (usageBefore?.cacheWrite ?? 0);
    const id = await this.conversation.compact(instructions, BACKGROUND_CONTEXT);
    const task = await this.harness.waitForTask(id, BACKGROUND_CONTEXT);
    const outcome = task.state.outcome;
    if (outcome.status !== "completed" || outcome.result.submissionId === undefined)
      throw new Error("Server durable compaction did not produce a summary");
    const submission = await this.harness.submission(
      outcome.result.submissionId,
      BACKGROUND_CONTEXT,
    );
    const placed = await submission?.wait(BACKGROUND_CONTEXT);
    if (placed?.status !== "done") throw new Error("Server durable compaction was not placed");
    const entry = this.view.value.entries.find((entry) => entry.id === placed.entry);
    const message = entry?.model?.[0];
    if (!message || message.role !== "user")
      throw new Error("Server durable compaction summary is unavailable");
    const summary =
      typeof message.content === "string"
        ? message.content
        : message.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
    return { summary, firstKeptEntryId: String(entry?.head), tokensBefore };
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

  replaceQueuedModelTurns(_batch: QueuedModelTurnBatch): never {
    return this.unsupported("replaceQueuedModelTurns");
  }

  clearQueuedModelTurns(): never {
    return this.unsupported("clearQueuedModelTurns");
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
    const withdrawn: MessageQueueState = {
      version: this.inboxVersion(),
      steering: [],
      followUp: [],
    };
    // Snapshot identities only. Each commit checks current inbox membership and
    // current internal-card receipts; placement in between is a successful no-op.
    const ids = (this.currentInbox()?.items ?? [])
      .filter(
        (item) => item.mode !== "write" && (itemId === undefined || String(item.id) === itemId),
      )
      .map((item) => item.id);
    for (const id of ids) {
      const item = await this.conversation.commit(async (tx) => {
        const inbox = await tx.doc(InboxDoc, this.conversation.id);
        const { submissions } = await resolveDurableInputCards(tx, this.conversation.id);
        const index = inbox.items.findIndex(
          (item) => item.id === id && item.mode !== "write" && !submissions.has(item.id),
        );
        const item = inbox.items[index];
        if (!item || item.mode === "write") return undefined;
        // Mirrors pi-durable inbox.js withdrawQueuedInputs/removeInboxItem.
        // Membership on this mutation line means queued in this conversation;
        // placement and settlement remove it atomically. Never re-admit inputs.
        const snapshot = JSON.parse(JSON.stringify(item)) as typeof item;
        tx.settleSubmission(item.id, { status: "unanswered", reason: "aborted" });
        inbox.items.splice(index, 1);
        return snapshot;
      }, BACKGROUND_CONTEXT);
      if (item)
        withdrawn[item.mode === "steer" ? "steering" : "followUp"].push(await this.queueItem(item));
    }
    withdrawn.version = this.inboxVersion();
    return withdrawn;
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
  sessionTree(): never {
    return this.unsupported("sessionTree");
  }
  leafId(): null {
    return null;
  }
  navigateTree(): never {
    return this.unsupported("navigateTree");
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
  exportToHtml(): never {
    return this.unsupported("exportToHtml");
  }
  setAutoCompactionEnabled(): never {
    return this.unsupported("setAutoCompactionEnabled");
  }
  setSteeringMode(): never {
    return this.unsupported("setSteeringMode");
  }
  setFollowUpMode(): never {
    return this.unsupported("setFollowUpMode");
  }
  setAutoRetryEnabled(): never {
    return this.unsupported("setAutoRetryEnabled");
  }
  abortRetry(): never {
    return this.unsupported("abortRetry");
  }
  getEntryRenderers(): undefined {
    return undefined;
  }
  appendAssistantMessage(): never {
    return this.unsupported("appendAssistantMessage");
  }
}

import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AttachedReplicatedState } from "@earendil-works/chord";
import {
  ModelRegistry,
  SettingsManager,
  getAgentDir,
  type ModelRuntime,
  type CompactionResult,
} from "@earendil-works/pi-coding-agent";
import {
  watchEvents,
  type AgentEventStream,
  type Conversation,
  type ConversationView,
  type Harness,
  type ConversationId,
  type AgentState,
  type LiveState,
  type InboxState,
  type UsageState,
} from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import type { AgentDefinition } from "./agent-launch-service.js";
import type { AgentBackend } from "./agent-backend.js";
import { adaptDurableEvent, createAdapterState, snapshotEvents } from "./durable-event-adapter.js";
import type { PiMessage, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import type { SdkBackendDisposeResult } from "./sdk-backend.js";
import { resolveSessionSeedModel, resolveSdkSessionCwd } from "./sdk-backend.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "./session-runtime-transaction.js";
import { isThinkingLevel, THINKING_LEVELS, type ThinkingLevel } from "./thinking-levels.js";
import type { Session, Workspace } from "./types.js";

export class DurableNotSupportedError extends Error {
  readonly code = "server_durable_not_supported";
  constructor(readonly operation: string) {
    super(`${operation} is not supported for server durable sessions`);
    this.name = "DurableNotSupportedError";
  }
}

/** An AgentBackend over a conversation; the Harness owns execution and queues. */
export class DurableBackend implements AgentBackend {
  private readonly transactions = new SessionRuntimeTransaction();
  private readonly adapter = createAdapterState();
  private disposed = false;
  private eventsStarted = false;
  private readonly registry: ModelRegistry;
  readonly abortClearsQueuedModelTurns = true;
  readonly isQueueReconciliationRequired = false;
  readonly showCacheMissNotices = false;

  private constructor(
    private readonly harness: Harness,
    private readonly conversation: Conversation,
    models: ModelRuntime,
    private readonly session: Session,
    private readonly view: AttachedReplicatedState<ConversationView>,
    private readonly events: AgentEventStream,
    private readonly onEvent: (event: SessionBackendEvent) => void,
  ) {
    this.registry = new ModelRegistry(models);
  }

  static async create(options: {
    harness: Harness;
    models: ModelRuntime;
    session: Session;
    workspace?: Workspace;
    agentDefinition?: AgentDefinition;
    dataDir: string;
    persistBinding: () => void;
    onEvent: (event: SessionBackendEvent) => void;
  }): Promise<DurableBackend> {
    const { harness, models, session, agentDefinition } = options;
    if (session.ephemeral) throw new DurableNotSupportedError("Incognito sessions");
    if (
      agentDefinition?.resources?.extensionIds?.length ||
      agentDefinition?.resources?.skillPaths?.length
    ) {
      throw new DurableNotSupportedError("Saved Agent Skills/Extensions");
    }
    const id = session.serverDurable?.conversationId;
    let conversation: Conversation;
    if (id !== undefined) {
      const existing = await harness.conversation(id as ConversationId, BACKGROUND_CONTEXT);
      if (!existing) throw new Error(`Server durable conversation ${id} is missing`);
      conversation = existing;
    } else {
      const registry = new ModelRegistry(models);
      const cwd = resolveSdkSessionCwd(options.workspace, session, { dataDir: options.dataDir });
      const settings = SettingsManager.create(cwd, getAgentDir(), { projectTrusted: false });
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
      const tools = (CodingTools.tools ?? []).filter(
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
          agent: {
            model: { provider: model.provider, modelId: model.id },
            thinkingLevel:
              session.thinkingLevel !== undefined && isThinkingLevel(session.thinkingLevel)
                ? session.thinkingLevel
                : settings.getDefaultThinkingLevel(),
            cwd,
            tools,
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
    const view = await conversation.viewState(BACKGROUND_CONTEXT);
    try {
      const events = await watchEvents(harness, conversation.id, BACKGROUND_CONTEXT);
      return new DurableBackend(
        harness,
        conversation,
        models,
        session,
        view,
        events,
        options.onEvent,
      );
    } catch (error) {
      view.dispose();
      throw error;
    }
  }

  /** Start only after Oppi has registered its projection listener. */
  startEvents(): void {
    if (this.eventsStarted) return;
    this.eventsStarted = true;
    for (const event of snapshotEvents(this.events.snapshot, this.adapter)) this.onEvent(event);
    this.events.start(async (events) => {
      if (this.disposed) return;
      for (const event of events) {
        for (const pi of adaptDurableEvent(event, this.adapter)) this.onEvent(pi);
        if (event.type === "inbox_update")
          this.onEvent({ type: "queue_update", ...this.queuedMessages() });
        if (event.type === "task_failed")
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
  ): Promise<void> {
    if (!permit)
      return this.withModelTurnAdmission("prompt", (token) => this.prompt(message, options, token));
    this.transactions.assertPermit(permit, "shared");
    this.assertOpen();
    const submission = await this.conversation.submit(
      {
        type: "input",
        content: options?.images?.length
          ? [{ type: "text", text: message }, ...options.images]
          : message,
        requestId: options?.clientTurnId,
        whenBusy: options?.streamingBehavior ?? "reject",
      },
      BACKGROUND_CONTEXT,
    );
    options?.onPreflightAccepted?.();
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
  }

  async abort(permit?: SessionRuntimeTransactionPermit): Promise<void> {
    if (!permit) return this.withRuntimeLifecycleTransaction("abort", (token) => this.abort(token));
    this.transactions.assertPermit(permit, "exclusive");
    this.assertOpen();
    await this.conversation.abort(BACKGROUND_CONTEXT);
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
    await this.conversation.abort(BACKGROUND_CONTEXT);
    this.disposed = true;
    await this.events.stop();
    this.view.dispose();
    return { disposal: "graceful" };
  }
  captureEmergencyDisposalForStop(): (timeoutMs: number) => SdkBackendDisposeResult {
    return (timeoutMs) => {
      // Persist the abort mark even if a tool ignores cancellation. Detaching
      // its projection is not an execution cancellation or a graceful disposal.
      void this.conversation.abort(BACKGROUND_CONTEXT).catch(() => undefined);
      this.disposed = true;
      void this.events.stop();
      this.view.dispose();
      this.transactions.poison(new Error("Server durable stop timed out"));
      return { disposal: "forced", cause: "lifecycle_timeout", operation: "stop", timeoutMs };
    };
  }

  queuedMessages(): { steering: readonly string[]; followUp: readonly string[] } {
    const inbox = this.view.value.docs["pi.inbox"] as InboxState | undefined;
    const text = (content: string | readonly { type: string; text?: string }[]): string =>
      typeof content === "string"
        ? content
        : content.map((block) => (block.type === "text" ? (block.text ?? "") : "")).join("");
    return {
      steering:
        inbox?.items.flatMap((item) => (item.mode === "steer" ? [text(item.content)] : [])) ?? [],
      followUp:
        inbox?.items.flatMap((item) => (item.mode === "followUp" ? [text(item.content)] : [])) ??
        [],
    };
  }
  messages(): PiMessage[] {
    return this.view.value.entries.flatMap((entry) => entry.model ?? []);
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
  getSessionStats(): ReturnType<AgentBackend["getSessionStats"]> {
    const messages = this.messages();
    const usage = this.view.value.docs["pi.usage"] as UsageState | undefined;
    const tokens = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
    let cost = 0;
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
    return {
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
  captureQueuedModelTurnsAuthority(): never {
    return this.unsupported("captureQueuedModelTurnsAuthority");
  }
  assertQueuedModelTurnsAuthority(): never {
    return this.unsupported("assertQueuedModelTurnsAuthority");
  }
  replaceQueuedModelTurns(): never {
    return this.unsupported("replaceQueuedModelTurns");
  }
  clearQueuedModelTurns(): never {
    return this.unsupported("clearQueuedModelTurns");
  }
  respondToExtensionUIRequest(): never {
    return this.unsupported("respondToExtensionUIRequest");
  }
  reloadResources(): never {
    return this.unsupported("reloadResources");
  }
  forkMessages(): never {
    return this.unsupported("forkMessages");
  }
  sessionTree(): never {
    return this.unsupported("sessionTree");
  }
  leafId(): never {
    return this.unsupported("leafId");
  }
  navigateTree(): never {
    return this.unsupported("navigateTree");
  }
  commands(): never {
    return this.unsupported("commands");
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
  getEntryRenderers(): never {
    return this.unsupported("getEntryRenderers");
  }
  appendAssistantMessage(): never {
    return this.unsupported("appendAssistantMessage");
  }
}

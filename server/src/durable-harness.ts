import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import {
  AgentDoc,
  Harness,
  createRegistry,
  defineDoc,
  type Extension,
  type HarnessSettings,
  type ConversationId,
  type EntryId,
  type Registry,
  type Tx,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import { DurableSandboxTools } from "./durable-sandbox-tools.js";
import { DurableAsk } from "../extensions/durable/ask/durable.js";
import {
  DurableBackgroundJobs,
  DurableJobs,
} from "../extensions/durable/background-jobs/durable.js";
import { controlConversationExtensions } from "./durable-control-conversation.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import { DurableGoal } from "../extensions/durable/goal/durable.js";
import { DurableWorkingWords } from "../extensions/durable/working-words/durable.js";
import { DurableProjectContext } from "../extensions/durable/project-context/durable.js";
import {
  SESSION_REPORTER_TASK,
  createDurableSessions,
} from "../extensions/durable/sessions/durable.js";
import {
  createDurableControl,
  type DurableControlHost,
} from "../extensions/durable/control/durable.js";
import { DurableUI } from "../extensions/durable/durable-ui.js";
import type { DurableMcp } from "./durable-mcp.js";
import type { DurableThreads } from "./durable-threads.js";

/** Persist the execution boundary so a resumed conversation cannot change runtime. */
export const DurableRuntime = defineDoc<{ kind: "host" | "sandbox"; workspaceId?: string }>({
  kind: "oppi.execution-runtime",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ kind: "host" }),
});

/** Process-owned, lazy Harness. A disabled server never creates this owner. */
export class DurableHarness {
  private opening?: Promise<{ harness: Harness; models: ModelRuntime }>;
  private closed = false;
  /** Server catalog runtime. Carries global `registerProvider` overlays such as Anthropic OMP. */
  private boundModels?: ModelRuntime;
  private discoveredModelsRequired = false;
  // Created before the local HTTP listener. No conversation may enable the
  // harness-wide scheduler until startup has resolved every persisted binding.
  private resumeHeld = true;
  private readonly pausedAborts = new Set<Promise<void>>();
  private runSettings?: HarnessSettings;
  private readonly sandboxEnvs = new Map<ConversationId, ExecutionEnv>();
  private registry?: Registry;
  /** Per Oppi session: its MCP connections and registry extension. */
  private readonly mcps = new Map<string, DurableMcp>();
  private threads?: DurableThreads;
  private control?: DurableControlHost;
  /** The session tools; they reach Oppi through the host bound with `bindThreads`. */
  readonly sessionsExtension = createDurableSessions(() => this.threads);
  /** The control conversation's tools; they reach Oppi through the host bound with `bindControl`. */
  readonly controlExtension = createDurableControl(() => this.control);
  /** The control conversation's exact selection. Never part of `baseExtensions`. */
  readonly controlExtensions: readonly Extension[] = controlConversationExtensions(
    this.controlExtension,
  );
  /**
   * Extensions every process installs, in install order. They are also the Harness default
   * selection, so a conversation whose stored selection is an `{ add }` edit never picks up
   * another session's MCP extension from the registry.
   */
  readonly baseExtensions: Extension[] = [
    CodingTools,
    DurableSandboxTools,
    DurableAsk,
    DurableGoal,
    DurableWorkingWords,
    DurableBackgroundJobs,
    this.sessionsExtension,
    DurableProjectContext,
  ];

  bindThreads(threads: DurableThreads): void {
    this.threads = threads;
  }
  bindControl(control: DurableControlHost): void {
    this.control = control;
  }
  get boundThreads(): DurableThreads | undefined {
    return this.threads;
  }

  get retrySettings(): HarnessSettings["retry"] {
    return this.runSettings?.retry;
  }

  installExtension(extension: Extension): void {
    if (!this.registry) throw new Error("Server durable Harness is not open");
    this.registry.install(extension);
  }
  uninstallExtension(extension: Extension): void {
    this.registry?.uninstall(extension);
  }

  /** Close the session's previous MCP before opening its next one, which reuses the extension name. */
  async replaceMcp(
    sessionId: string,
    open: () => Promise<DurableMcp | undefined>,
  ): Promise<DurableMcp | undefined> {
    await this.closeMcp(sessionId);
    if (this.closed) return undefined;
    const mcp = await open();
    if (mcp) this.mcps.set(sessionId, mcp);
    return mcp;
  }
  async closeMcp(sessionId: string): Promise<void> {
    const mcp = this.mcps.get(sessionId);
    this.mcps.delete(sessionId);
    await mcp?.close();
  }

  bindSandboxEnv(id: ConversationId, env: ExecutionEnv): void {
    // A stopped projection can reattach while conversation-owned jobs still run.
    if (!this.sandboxEnvs.has(id)) this.sandboxEnvs.set(id, env);
  }
  async unbindSandboxEnv(id: ConversationId, force = false): Promise<void> {
    if (!force && this.opening) {
      const { harness } = await this.opening;
      const jobs = await harness.snapshot(DurableJobs, id, BACKGROUND_CONTEXT);
      if (jobs?.jobs.some((job) => !job.delivered)) return;
    }
    const env = this.sandboxEnvs.get(id);
    await env?.cleanup(BACKGROUND_CONTEXT);
    this.sandboxEnvs.delete(id);
  }

  get isResumeHeld(): boolean {
    return this.resumeHeld;
  }

  assertSchedulingReady(): void {
    if (this.resumeHeld) {
      throw Object.assign(
        new Error(
          "Server durable startup is still resolving conversations; retry this command after startup completes",
        ),
        { code: "server_durable_startup_pending", retryable: true },
      );
    }
  }

  async abortConversation(id: ConversationId): Promise<void> {
    if (this.resumeHeld) await this.abortConversations(new Set([id]));
    else {
      const { harness } = await this.open();
      await (await harness.conversation(id, BACKGROUND_CONTEXT))?.abort(BACKGROUND_CONTEXT);
    }
    const { harness } = await this.open();
    // Bash runs under a background-capable task before promotion, but Stop
    // still owns that foreground execution. Join its abort protocol so guest
    // kill confirmation cannot race the live-doc observer's cancellation.
    if (!this.resumeHeld) {
      const jobs = await harness.snapshot(DurableJobs, id, BACKGROUND_CONTEXT);
      const foreground =
        jobs?.jobs.filter((job) => job.decision === "waiting" && !job.delivered) ?? [];
      for (const job of foreground) await harness.abortTask(job.taskId, BACKGROUND_CONTEXT);
      await Promise.all(
        foreground.map((job) => harness.waitForTask(job.taskId, BACKGROUND_CONTEXT)),
      );
    }
    const conversation = await harness.conversation(id, BACKGROUND_CONTEXT);
    await conversation?.commit(async (tx) => {
      (await tx.doc(DurableUI, id)).requests = {};
    }, BACKGROUND_CONTEXT);
    // Confirm the guest kill boundary independently, without cleanup() killing
    // conversation-owned background executions that ordinary Stop excludes.
    const env = this.sandboxEnvs.get(id);
    if (env instanceof GondolinExecutionEnv) await env.confirmCancelledCalls();
  }

  /**
   * Stop (not composer abort) of a session: its background children's reporters would
   * submit a follow-up and start a new turn on the stopped conversation. Aborts only
   * those reporters; the children, and background jobs, keep running.
   */
  async abortSessionReporters(id: ConversationId): Promise<void> {
    const { harness } = await this.open();
    const live = await harness.inspect(BACKGROUND_CONTEXT);
    for (const { record } of live.tasks)
      if (record.conversationId === id && record.kind === SESSION_REPORTER_TASK)
        await harness.abortTask(record.id, BACKGROUND_CONTEXT);
  }

  holdResume(): void {
    this.resumeHeld = true;
  }
  async resume(): Promise<void> {
    if (!this.resumeHeld && this.opening) (await this.opening).harness.resume();
  }
  async releaseResume(): Promise<void> {
    // Stops of already attached projections may still be committing their
    // cancellation marks. Join them before opening the scheduling gate.
    while (this.pausedAborts.size) await Promise.all([...this.pausedAborts]);
    this.resumeHeld = false;
    await this.resume();
  }

  constructor(private readonly dataDir: string) {}

  /** Production open must not invent a runtime that skipped extension provider discovery. */
  requireDiscoveredModels(): void {
    if (this.opening) {
      throw new Error("Server durable model runtime cannot be required after the Harness opens");
    }
    this.discoveredModelsRequired = true;
  }

  /** Adopt the server ModelRuntime. Call before open(); later catalog resyncs stay on this object. */
  bindModelRuntime(models: ModelRuntime): void {
    if (this.opening) {
      throw new Error("Server durable model runtime cannot change after the Harness opens");
    }
    this.boundModels = models;
  }

  open(): Promise<{ harness: Harness; models: ModelRuntime }> {
    if (this.closed) return Promise.reject(new Error("Server durable Harness is closed"));
    return (this.opening ??= this.openInner());
  }

  private async openInner(): Promise<{ harness: Harness; models: ModelRuntime }> {
    const agentDir = getAgentDir();
    if (this.discoveredModelsRequired && !this.boundModels) {
      throw new Error(
        "Server durable Harness opened before the discovered model runtime was bound",
      );
    }
    const models =
      this.boundModels ??
      (await ModelRuntime.create({
        authPath: join(agentDir, "auth.json"),
        modelsPath: join(agentDir, "models.json"),
      }));
    // Run policy is global to the Harness, not the first workspace to open it.
    const settings = SettingsManager.create(homedir(), agentDir, { projectTrusted: false });
    this.runSettings = harnessSettings(settings, this.baseExtensions);
    const registry = createRegistry();
    for (const extension of this.baseExtensions) registry.install(extension);
    // Installed so the control conversation can select them by name. Installing is not
    // selecting: only `baseExtensions` is the default selection of other conversations.
    for (const extension of this.controlExtensions)
      if (!this.baseExtensions.includes(extension)) registry.install(extension);
    this.registry = registry;
    const directory = join(this.dataDir, "durable");
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    // Bun-based CLI commands must not load node:sqlite when the experiment is
    // off. The native SQLite adapter belongs to this lazy execution boundary.
    const { openNodeSqliteStorage } =
      await import("@earendil-works/pi-durable/storage/sqlite/node");
    const harness = await Harness.open(
      await openNodeSqliteStorage(join(directory, "harness.sqlite")),
      {
        models,
        registry,
        settings: this.runSettings,
        env: async ({ conversationId, cwd, read }, context) => {
          const runtime = await read.snapshot(DurableRuntime, conversationId, context);
          if (runtime?.kind !== "sandbox") return new NodeExecutionEnv({ cwd: cwd ?? homedir() });
          const env = this.sandboxEnvs.get(conversationId);
          if (!env)
            throw new Error("Durable sandbox workspace is not attached; refusing host execution");
          return env;
        },
      },
      BACKGROUND_CONTEXT,
    );
    return { harness, models };
  }

  /**
   * Fork `sourceId` at `entryId` into a new ownerless conversation, as classic fork does with
   * `navigate_tree`: a user message is excluded (the branch point is the visible entry before
   * it), any other entry is included. The first user message has no earlier entry, so the fork
   * is a fresh conversation carrying the source's stored agent. Resolves `undefined` when the
   * entry is not visible from the source. The fork keeps the source's execution runtime:
   * `DurableRuntime` forks as its initial value, which would turn a sandbox conversation into
   * a host one.
   */
  async forkConversation(
    sourceId: ConversationId,
    entryId: EntryId,
  ): Promise<ConversationId | undefined> {
    const { harness } = await this.open();
    const source = await harness.conversation(sourceId, BACKGROUND_CONTEXT);
    if (!source) throw new Error(`Server durable conversation ${sourceId} is missing`);
    // Newest first: the chosen entry, then the visible entry before it.
    const { items } = await source.entries(
      { maxEntryId: entryId },
      2,
      undefined,
      BACKGROUND_CONTEXT,
    );
    const [chosen, previous] = items;
    if (chosen?.id !== entryId) return undefined;
    const runtime = await harness.snapshot(DurableRuntime, sourceId, BACKGROUND_CONTEXT);
    const copyRuntime = async (tx: Tx, id: ConversationId): Promise<void> => {
      if (!runtime) return;
      const doc = await tx.doc(DurableRuntime, id);
      doc.kind = runtime.kind;
      if (runtime.workspaceId !== undefined) doc.workspaceId = runtime.workspaceId;
    };
    const ownership = { kind: "ownerless" } as const;
    // A compaction entry carries a user-role summary but is not a user message: branch at it,
    // so the fork keeps the summary instead of the pre-compaction transcript.
    const isUserMessage = chosen.model?.[0]?.role === "user" && chosen.kind !== "pi.compaction";
    const branchPoint = isUserMessage ? previous?.id : chosen.id;
    if (branchPoint !== undefined) {
      const fork = await source.fork(
        branchPoint,
        { ownership, init: copyRuntime },
        BACKGROUND_CONTEXT,
      );
      return fork.id;
    }
    const agent = await harness.snapshot(AgentDoc, sourceId, BACKGROUND_CONTEXT);
    const fresh = await harness.createConversation(
      {
        ownership,
        init: async (tx, id) => {
          await copyRuntime(tx, id);
          if (!agent) return;
          // The stored selection, by name: resolved objects would drop tools whose
          // extension (such as MCP) is not attached yet.
          const doc = await tx.doc(AgentDoc, id);
          Object.assign(doc, structuredClone(agent));
        },
      },
      BACKGROUND_CONTEXT,
    );
    return fresh.id;
  }

  /** Mark cancellation without Conversation.abort(), which enables ALL scheduling. */
  abortConversations(
    ids: ReadonlySet<ConversationId>,
    options?: { background?: boolean },
  ): Promise<void> {
    const operation = this.markAbortedConversations(ids, options?.background === true);
    this.pausedAborts.add(operation);
    void operation.finally(() => this.pausedAborts.delete(operation)).catch(() => undefined);
    return operation;
  }

  private async markAbortedConversations(
    ids: ReadonlySet<ConversationId>,
    background: boolean,
  ): Promise<void> {
    const { harness } = await this.open();
    const live = await harness.inspect(BACKGROUND_CONTEXT);
    for (const submission of live.submissions) {
      if (
        ids.has(submission.conversationId) &&
        submission.type === "input" &&
        submission.status === "queued"
      )
        await harness.abortSubmission(submission.id, BACKGROUND_CONTEXT);
    }
    const foreground = new Set<number>();
    for (const id of ids) {
      const jobs = await harness.snapshot(DurableJobs, id, BACKGROUND_CONTEXT);
      for (const job of jobs?.jobs ?? [])
        if (job.decision === "waiting" && !job.delivered) foreground.add(job.taskId);
    }
    for (const { record } of live.tasks) {
      if (
        ids.has(record.conversationId) &&
        (background || !record.background || foreground.has(record.id))
      )
        await harness.abortTask(record.id, BACKGROUND_CONTEXT);
    }
    for (const id of ids) {
      const conversation = await harness.conversation(id, BACKGROUND_CONTEXT);
      await conversation?.commit(async (tx) => {
        (await tx.doc(DurableUI, id)).requests = {};
      }, BACKGROUND_CONTEXT);
    }
  }

  async close(resumeIds: ReadonlySet<ConversationId> = new Set()): Promise<void> {
    if (!this.opening) {
      this.closed = true;
      return;
    }
    try {
      await this.closeHarness(resumeIds);
    } finally {
      // MCP stdio servers are host processes: close them even when Harness shutdown fails.
      await Promise.all([...this.mcps.keys()].map((id) => this.closeMcp(id)));
    }
  }

  private async closeHarness(resumeIds: ReadonlySet<ConversationId>): Promise<void> {
    if (!this.opening) return;
    const { harness } = await this.opening;
    const live = await harness.inspect(BACKGROUND_CONTEXT);
    const stopped = new Set(
      [
        ...live.tasks.map(({ record }) => record.conversationId),
        ...live.submissions.map((submission) => submission.conversationId),
      ].filter((id) => !resumeIds.has(id)),
    );
    await this.abortConversations(stopped);
    this.closed = true;
    // Closing interrupts invocations without settling their tasks. Recorded
    // restart work remains durable and is continued by the next Harness.open.
    await harness.close(BACKGROUND_CONTEXT);
    await Promise.all([...this.sandboxEnvs.keys()].map((id) => this.unbindSandboxEnv(id, true)));
  }
}

// Pi v1 experimental/durable/harness-setup.ts: read policy at each use,
// without writing user settings or copying run policy onto conversations.
function harnessSettings(settings: SettingsManager, extensions: Extension[]): HarnessSettings {
  return {
    extensions,
    get stream() {
      const provider = settings.getProviderRetrySettings();
      const idle = settings.getHttpIdleTimeoutMs();
      return {
        timeoutMs: provider.timeoutMs ?? (idle === 0 ? 2147483647 : idle),
        maxRetryDelayMs: provider.maxRetryDelayMs,
        ...(provider.maxRetries === undefined ? {} : { maxRetries: provider.maxRetries }),
      };
    },
    get compaction() {
      return settings.getCompactionSettings();
    },
    get retry() {
      return settings.getRetrySettings();
    },
    get steeringMode() {
      return settings.getSteeringMode();
    },
    get followUpMode() {
      return settings.getFollowUpMode();
    },
  };
}

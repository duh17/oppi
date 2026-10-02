import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import {
  Harness,
  createRegistry,
  defineDoc,
  type HarnessSettings,
  type ConversationId,
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
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import { DurableWorkingWords } from "../extensions/durable/working-words/durable.js";
import { DurableUI } from "../extensions/durable/durable-ui.js";

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
  // Created before the local HTTP listener. No conversation may enable the
  // harness-wide scheduler until startup has resolved every persisted binding.
  private resumeHeld = true;
  private readonly pausedAborts = new Set<Promise<void>>();
  private runSettings?: HarnessSettings;
  private readonly sandboxEnvs = new Map<ConversationId, ExecutionEnv>();

  get retrySettings(): HarnessSettings["retry"] {
    return this.runSettings?.retry;
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

  open(): Promise<{ harness: Harness; models: ModelRuntime }> {
    if (this.closed) return Promise.reject(new Error("Server durable Harness is closed"));
    return (this.opening ??= this.openInner());
  }

  private async openInner(): Promise<{ harness: Harness; models: ModelRuntime }> {
    const agentDir = getAgentDir();
    const models = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });
    // Run policy is global to the Harness, not the first workspace to open it.
    const settings = SettingsManager.create(homedir(), agentDir, { projectTrusted: false });
    this.runSettings = harnessSettings(settings);
    const registry = createRegistry();
    registry.install(CodingTools);
    registry.install(DurableSandboxTools);
    registry.install(DurableAsk);
    registry.install(DurableWorkingWords);
    registry.install(DurableBackgroundJobs);
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
function harnessSettings(settings: SettingsManager): HarnessSettings {
  return {
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

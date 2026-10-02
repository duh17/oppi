import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import {
  Harness,
  createRegistry,
  type HarnessSettings,
  type ConversationId,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Process-owned, lazy Harness. A disabled server never creates this owner. */
export class DurableHarness {
  private opening?: Promise<{ harness: Harness; models: ModelRuntime }>;
  private closed = false;
  // Created before the local HTTP listener. No conversation may enable the
  // harness-wide scheduler until startup has resolved every persisted binding.
  private resumeHeld = true;
  private readonly pausedAborts = new Set<Promise<void>>();

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
    if (this.resumeHeld) return this.abortConversations(new Set([id]));
    const { harness } = await this.open();
    await (await harness.conversation(id, BACKGROUND_CONTEXT))?.abort(BACKGROUND_CONTEXT);
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
    const registry = createRegistry();
    registry.install(CodingTools);
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
        settings: harnessSettings(settings),
        env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? homedir() }),
      },
      BACKGROUND_CONTEXT,
    );
    return { harness, models };
  }

  /** Mark cancellation without Conversation.abort(), which enables ALL scheduling. */
  abortConversations(ids: ReadonlySet<ConversationId>): Promise<void> {
    const operation = this.markAbortedConversations(ids);
    this.pausedAborts.add(operation);
    void operation.finally(() => this.pausedAborts.delete(operation)).catch(() => undefined);
    return operation;
  }

  private async markAbortedConversations(ids: ReadonlySet<ConversationId>): Promise<void> {
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
    for (const { record } of live.tasks) {
      if (ids.has(record.conversationId)) await harness.abortTask(record.id, BACKGROUND_CONTEXT);
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

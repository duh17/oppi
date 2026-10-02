import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager, getAgentDir } from "@earendil-works/pi-coding-agent";
import { Harness, createRegistry, type HarnessSettings } from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Process-owned, lazy Harness. A disabled server never creates this owner. */
export class DurableHarness {
  private opening?: Promise<{ harness: Harness; models: ModelRuntime }>;
  private closed = false;
  private resumeHeld = false;

  holdResume(): void {
    this.resumeHeld = true;
  }
  async resume(): Promise<void> {
    if (!this.resumeHeld && this.opening) (await this.opening).harness.resume();
  }
  async releaseResume(): Promise<void> {
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

  async close(): Promise<void> {
    this.closed = true;
    if (!this.opening) return;
    const { harness } = await this.opening;
    // close alone leaves pending work, exactly like a crash. Abort every bound
    // conversation first, including ones that aren't currently mounted in Oppi.
    const conversations = await harness.commit(async (tx) => {
      const ids = [];
      let cursor;
      do {
        const page = await tx.scanConversations({}, 100, cursor);
        ids.push(...page.items.map((item) => item.id));
        cursor = page.next;
      } while (cursor !== undefined);
      return ids;
    }, BACKGROUND_CONTEXT);
    for (const id of conversations) {
      await (await harness.conversation(id, BACKGROUND_CONTEXT))?.abort(BACKGROUND_CONTEXT);
    }
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

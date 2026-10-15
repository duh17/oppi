import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AttachedReplicatedState } from "@earendil-works/chord";
import {
  ModelRegistry,
  ModelRuntime,
  SettingsManager,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";
import {
  AgentDoc,
  Harness,
  SessionFailed,
  createRegistry,
  defineDoc,
  type AnyTask,
  type Extension,
  type HarnessSettings,
  type Conversation,
  type ConversationId,
  type EntryId,
  type Registry,
  type Storage,
  type TaskGraph,
  type Tx,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import { DurableSandboxTools } from "./durable-sandbox-tools.js";
import { DurableJobs } from "../extensions/durable/background-jobs/contract.js";
import { controlConversationExtensions } from "./durable-control-conversation.js";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
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
import {
  BUNDLED_PACKAGES_DIR,
  bundledDurableExtensionPackages,
  discoverDurableExtensionPackages,
  loadDurableExtensions,
  type DurableExtensionIssue,
  type DurableExtensionRuntime,
  type LoadedDurableExtension,
} from "./durable-extension-loader.js";
import type { DurableMcp } from "./durable-mcp.js";
import { DurableAgentController } from "./durable-agent-controller.js";
import {
  attachConversationStream,
  readOlderConversationEntries,
  type ConversationStreamSubscription,
} from "./durable-conversation-stream.js";
import { DurableModels } from "./durable-models.js";
import { createLogger } from "./logger.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import { safeErrorMessage } from "./log-utils.js";
import type { DurableThreads } from "./durable-threads.js";
import { properLockfile } from "./pi-lockfile.js";
import { requireDurableStoreId } from "./session-runtime-capabilities.js";
import type { ConversationStreamServerMessage, Session } from "./types.js";

/** Persist the execution boundary so a resumed conversation cannot change runtime. */
export const DurableRuntime = defineDoc<{ kind: "host" | "sandbox"; workspaceId?: string }>({
  kind: "oppi.execution-runtime",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ kind: "host" }),
});

const log = createLogger({ base: { component: "durable_harness" } });

const STORE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
/**
 * Waits before each reopen of a store whose Harness failed. pi-durable fails the Harness on any
 * storage error and does not retry; commits are atomic, so a reopen recovers what was committed.
 * A store that cannot reopen after these is given up, so a broken disk does not loop forever.
 */
const RECOVERY_DELAYS_MS = [0, 1_000, 5_000];
/** VM memory of one control codemode script; the VM runs in a worker of the server process. */
const CONTROL_SCRIPT_MEMORY_LIMIT_BYTES = 256 * 1024 * 1024;
const METADATA_FILE = "meta.json";
const STORAGE_FILE = "session.sqlite";

const sessionHostsByEnv = new WeakMap<ExecutionEnv, SessionHost>();

export function sessionHostOfEnv(env: ExecutionEnv | undefined): SessionHost | undefined {
  return env ? sessionHostsByEnv.get(env) : undefined;
}

export function hostOfEnv(env: ExecutionEnv | undefined): SessionHost {
  const host = sessionHostOfEnv(env);
  if (!host) throw new Error("Durable session host is missing");
  return host;
}

export function durableSessionsRoot(dataDir: string): string {
  return join(dataDir, "durable", "sessions");
}

export function durableStoreDir(dataDir: string, storeId: string): string {
  return join(durableSessionsRoot(dataDir), storeId);
}

export function durableStoreSqlitePath(dataDir: string, storeId: string): string {
  return join(durableStoreDir(dataDir, storeId), STORAGE_FILE);
}

export function assertDurableStoreId(storeId: string): void {
  if (!STORE_ID.test(storeId)) throw new Error(`Invalid durable store id: ${storeId}`);
}

export interface DurableStoreMeta {
  createdAt: number;
  cwd: string;
  name?: string;
  workspaceId?: string;
  agent?: { id: string; version: number };
}

export function durableStoreMetaFromSession(session: Session, cwd: string): DurableStoreMeta {
  const agent =
    session.launch?.agentId !== undefined
      ? {
          id: session.launch.agentId,
          version: session.launch.agentVersion ?? 0,
        }
      : undefined;
  return {
    createdAt: session.createdAt,
    cwd,
    ...(session.name ? { name: session.name } : {}),
    ...(session.workspaceId ? { workspaceId: session.workspaceId } : {}),
    ...(agent ? { agent } : {}),
  };
}

export interface DurableExtensionSummary {
  name: string;
  entry: string;
  runtimes: readonly DurableExtensionRuntime[];
  tools: string[];
  /** One of Oppi's bundled packages rather than a user's Pi package. */
  builtIn: boolean;
}

/** What one load of the bundled and Pi packages' durable entries did to the registry. */
export interface DurableExtensionReport {
  /** Installed from this load; a name that was already installed was replaced in place. */
  loaded: DurableExtensionSummary[];
  /** Failed to load this time; the previously loaded code stays installed. */
  kept: DurableExtensionSummary[];
  /** Installed before, and no longer provided by any enabled package: uninstalled. */
  removed: string[];
  skipped: DurableExtensionIssue[];
  errors: DurableExtensionIssue[];
}

function summarize(loaded: LoadedDurableExtension, builtIn: boolean): DurableExtensionSummary {
  return {
    name: loaded.extension.name,
    entry: loaded.entry,
    runtimes: loaded.runtimes,
    tools: (loaded.extension.tools ?? []).map((tool) => tool.name),
    builtIn,
  };
}

/** Selected only by the control conversation, never by default. */
const CONTROL_EXTENSION = "oppi.control";
/** Offers `subagent`; a session selects it only when it may spawn. */
const SESSIONS_EXTENSION = "oppi.sessions";

/** A built-in extension and the runtimes whose sessions select it by default. */
type BuiltIn = Pick<LoadedDurableExtension, "extension" | "runtimes">;

function readStoreMeta(directory: string): DurableStoreMeta | undefined {
  const path = join(directory, METADATA_FILE);
  if (!existsSync(path)) return undefined;
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error("Durable store meta.json is invalid", { cause: error });
  }
  if (typeof value !== "object" || value === null) {
    throw new Error("Durable store meta.json is invalid");
  }
  const record = value as { createdAt?: unknown; cwd?: unknown };
  if (typeof record.createdAt !== "number" || typeof record.cwd !== "string") {
    throw new Error("Durable store meta.json is invalid");
  }
  const meta: DurableStoreMeta = { createdAt: record.createdAt, cwd: record.cwd };
  const name = (value as { name?: unknown }).name;
  if (typeof name === "string") meta.name = name;
  const workspaceId = (value as { workspaceId?: unknown }).workspaceId;
  if (typeof workspaceId === "string") meta.workspaceId = workspaceId;
  const agent = (value as { agent?: unknown }).agent;
  if (
    typeof agent === "object" &&
    agent !== null &&
    typeof (agent as { id?: unknown }).id === "string" &&
    typeof (agent as { version?: unknown }).version === "number"
  ) {
    meta.agent = {
      id: (agent as { id: string }).id,
      version: (agent as { version: number }).version,
    };
  }
  return meta;
}

function writeStoreMeta(directory: string, meta: DurableStoreMeta): void {
  const body: Record<string, unknown> = { createdAt: meta.createdAt, cwd: meta.cwd };
  if (meta.name !== undefined) body.name = meta.name;
  if (meta.workspaceId !== undefined) body.workspaceId = meta.workspaceId;
  if (meta.agent !== undefined) body.agent = meta.agent;
  const dest = join(directory, METADATA_FILE);
  const tmp = join(directory, `${METADATA_FILE}.tmp`);
  writeFileSync(tmp, `${JSON.stringify(body, null, "\t")}\n`);
  renameSync(tmp, dest);
}

/**
 * One socket's transcript stream; re-attached from its cursor when the store recovers or its
 * room fails.
 */
interface TranscriptStream {
  readonly id: ConversationId;
  readonly options: {
    renderers: MobileRendererRegistry;
    send: (frame: ConversationStreamServerMessage) => void;
    onLost: () => void;
  };
  subscription: ConversationStreamSubscription;
}

/** The session services `SessionHost` keeps for one opened Harness. */
interface HostServices {
  harness: Harness;
  /** Shared by every conversation's `DurableModels`. */
  registry: ModelRegistry;
  conversations: Map<
    ConversationId,
    { conversation: Conversation; controller?: DurableAgentController; models?: DurableModels }
  >;
}

/**
 * One open pi-durable store: the directory lock, sqlite, Harness, resume gate,
 * sandbox envs, MCP connections, and live-task watch of that tree, plus the session services of
 * its conversations: `controller` (input and run control), `models`, and `transcript`. They take
 * the Harness, the conversation, and this host only; `DurableBackend` delegates to them.
 */
export class SessionHost {
  private opening?: Promise<{ harness: Harness; models: ModelRuntime }>;
  private closed = false;
  private harnessStorage?: Storage;
  private resumeHeld: boolean;
  private readonly pausedAborts = new Set<Promise<void>>();
  private readonly sandboxEnvs = new Map<ConversationId, ExecutionEnv>();
  private readonly mcps = new Map<string, DurableMcp>();
  private releaseLock?: () => Promise<void>;
  private readonly holds: string[] = [];
  private taskGraph?: AttachedReplicatedState<TaskGraph>;
  private stopTaskGraph?: () => void;
  private closing?: Promise<void>;
  private idleCloseTimer: ReturnType<typeof setImmediate> | undefined;
  /** Set when the Harness opens, dropped on close. */
  private services?: HostServices;
  /** Set while a failed Harness is torn down and the store reopened. */
  private recovering?: Promise<unknown>;
  /** The last reopen error once recovery gave up; this host never opens again. */
  private abandoned?: unknown;
  /**
   * A Harness that began closing while it was this host's, so a storage error failed it.
   * Known when the close begins, before `closed` settles: the call that hit the error gets the
   * raw error, not `SessionFailed`, and recovery starts only after tasks are joined.
   */
  private failingHarness?: Harness;
  private readonly transcripts = new Set<TranscriptStream>();

  constructor(
    readonly runtime: DurableHarness,
    readonly storeId: string,
    readonly directory: string,
    readonly meta: DurableStoreMeta,
    holdResume: boolean,
  ) {
    this.resumeHeld = holdResume;
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

  /** Read a text file through the conversation's sandbox VM; fails when none is bound. */
  async readSandboxTextFile(id: ConversationId, path: string): Promise<string> {
    const env = this.sandboxEnvs.get(id);
    if (!env) throw new Error("The sandbox VM is not ready");
    const result = await env.readTextFile(path, BACKGROUND_CONTEXT);
    if (!result.ok) throw new Error(`Cannot read ${path}: ${result.error.message}`);
    return result.value;
  }

  bindSandboxEnv(id: ConversationId, env: ExecutionEnv): void {
    // A stopped projection can reattach while conversation-owned jobs still run.
    if (!this.sandboxEnvs.has(id)) this.sandboxEnvs.set(id, env);
    sessionHostsByEnv.set(env, this);
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
    if (this.runtime.shuttingDown) {
      await this.abortConversations(new Set([id]));
      return;
    }
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

  /** Storage `open()` retained. Absent until the Harness storage exists. */
  get storage(): Storage {
    if (!this.harnessStorage) throw new Error("Server durable store is not open");
    return this.harnessStorage;
  }

  /**
   * Test seam: use this Harness instead of opening session.sqlite. Production
   * always goes through `open()` / the directory lock.
   */
  bindOpenedHarness(harness: Harness, storage: Storage, models: ModelRuntime): void {
    if (this.opening) throw new Error("Server durable store is already opening");
    this.harnessStorage = storage;
    this.opening = this.watchTaskGraph(harness).then(() => this.opened(harness, models));
  }

  retain(reason: string): () => void {
    this.holds.push(reason);
    this.cancelIdleClose();
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const index = this.holds.indexOf(reason);
      if (index >= 0) this.holds.splice(index, 1);
      if (this.holds.length === 0) {
        void this.retireIdleTickers()
          .catch((error) => {
            log.error("durable_store.idle_ticker_abort_failed", {
              storeId: this.storeId,
              error: safeErrorMessage(error),
            });
          })
          .then(() => this.maybeClose());
        return;
      }
      this.maybeClose();
    };
  }

  /** The one input and run controller of conversation `id` while this host is open. */
  async controller(id: ConversationId): Promise<DurableAgentController> {
    const { harness, entry } = await this.serviceEntry(id);
    return (entry.controller ??= new DurableAgentController(harness, entry.conversation, this));
  }

  /** The one model and thinking service of conversation `id` while this host is open. */
  async models(id: ConversationId): Promise<DurableModels> {
    const { harness, registry, entry } = await this.serviceEntry(id);
    return (entry.models ??= new DurableModels(harness, entry.conversation, registry));
  }

  private async serviceEntry(id: ConversationId): Promise<{
    harness: Harness;
    registry: ModelRegistry;
    entry: NonNullable<ReturnType<HostServices["conversations"]["get"]>>;
  }> {
    const { harness } = await this.open();
    const services = this.services;
    if (services?.harness !== harness) throw new Error("Server durable store is closed");
    let entry = services.conversations.get(id);
    if (!entry) {
      const conversation = await harness.conversation(id, BACKGROUND_CONTEXT);
      if (!conversation) throw new Error(`Server durable conversation ${id} is missing`);
      // A close (or close and reopen) during the lookup dropped these services: cache nothing.
      if (this.services !== services) throw new Error("Server durable store is closed");
      entry = services.conversations.get(id) ?? { conversation };
      services.conversations.set(id, entry);
    }
    return { harness, registry: services.registry, entry };
  }

  private opened(
    harness: Harness,
    models: ModelRuntime,
  ): { harness: Harness; models: ModelRuntime } {
    this.services = { harness, registry: new ModelRegistry(models), conversations: new Map() };
    return { harness, models };
  }

  private dropServices(): void {
    for (const { controller } of this.services?.conversations.values() ?? []) controller?.close();
    this.services = undefined;
  }

  /**
   * Stream conversation `id` to one socket (see `durable-conversation-stream.ts`). Sends the
   * first frame before resolving and holds this host open until the returned function runs.
   */
  async transcript(
    id: ConversationId,
    options: {
      renderers: MobileRendererRegistry;
      afterEntryId?: number;
      send: (frame: ConversationStreamServerMessage) => void;
    },
  ): Promise<() => void> {
    const release = this.retain("stream");
    try {
      const { harness } = await this.open();
      const streamOptions: TranscriptStream["options"] = {
        renderers: options.renderers,
        send: options.send,
        onLost: () => void this.reattachLostTranscript(stream),
      };
      const stream: TranscriptStream = {
        id,
        options: streamOptions,
        subscription: await attachConversationStream({
          harness,
          conversationId: id,
          ...streamOptions,
          ...(options.afterEntryId !== undefined ? { afterEntryId: options.afterEntryId } : {}),
        }),
      };
      this.transcripts.add(stream);
      let disposed = false;
      return () => {
        if (disposed) return;
        disposed = true;
        this.transcripts.delete(stream);
        stream.subscription.dispose();
        release();
      };
    } catch (error) {
      release();
      throw error;
    }
  }

  /** `Transcript` paging: the conversation stream's `older` frame for entries before `beforeEntryId`. */
  async olderEntries(
    id: ConversationId,
    options: { renderers: MobileRendererRegistry; beforeEntryId: number; limit?: number },
  ): Promise<Extract<ConversationStreamServerMessage, { type: "older" }>> {
    return this.use((harness) =>
      readOlderConversationEntries({ harness, conversationId: id, ...options }),
    );
  }

  async use<T>(fn: (harness: Harness, host: SessionHost) => Promise<T>): Promise<T> {
    const release = this.retain("use");
    try {
      return await fn((await this.open()).harness, this);
    } finally {
      release();
    }
  }

  get isIdle(): boolean {
    return this.holds.length === 0 && Object.keys(this.taskGraph?.value?.tasks ?? {}).length === 0;
  }

  /** Why this host stays open. Empty when it can idle-close. */
  get holdReasons(): string[] {
    const reasons = [...this.holds];
    const tasks = this.taskGraph?.value?.tasks ?? {};
    const live = Object.keys(tasks).length;
    if (live > 0) {
      const kinds = Object.values(tasks).map(
        (task) => `${task.kind}${task.background ? ":bg" : ""}`,
      );
      reasons.push(`tasks:${live}${kinds.length ? `(${kinds.join(",")})` : ""}`);
    }
    return reasons;
  }

  /**
   * Whether `error` came from this store failing (again): the Harness rejected with
   * `SessionFailed`, or a recovery is under way. A session re-attach that failed this way waits
   * for that recovery's outcome instead of ending.
   */
  failedWithStore(error: unknown): boolean {
    return (
      error instanceof SessionFailed ||
      this.recovering !== undefined ||
      (this.failingHarness !== undefined && this.failingHarness === this.services?.harness)
    );
  }

  get isOpen(): boolean {
    return !this.closed && (this.opening !== undefined || this.recovering !== undefined);
  }

  open(): Promise<{ harness: Harness; models: ModelRuntime }> {
    if (this.recovering) return this.recovering.then(() => this.open());
    if (this.abandoned !== undefined)
      return Promise.reject(
        new Error(
          `Durable store ${this.storeId} failed and could not reopen: ${safeErrorMessage(this.abandoned)}`,
        ),
      );
    if (this.closing) {
      return this.closing.then(() => {
        if (this.runtime.shuttingDown || this.runtime.isClosed) {
          return Promise.reject(new Error("Server durable store is closed"));
        }
        return this.open();
      });
    }
    if (this.closed) {
      if (this.runtime.shuttingDown || this.runtime.isClosed) {
        return Promise.reject(new Error("Server durable store is closed"));
      }
      this.closed = false;
      this.opening = undefined;
    }
    if (this.runtime.isClosed) return Promise.reject(new Error("Server durable runtime is closed"));
    return (this.opening ??= this.openInner());
  }

  private async openInner(): Promise<{ harness: Harness; models: ModelRuntime }> {
    const shared = await this.runtime.ensureShared();
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    try {
      this.releaseLock = await properLockfile.lock(this.directory, {
        realpath: true,
        stale: 2_000,
        update: 1_000,
        retries: 0,
      });
    } catch (error) {
      throw Object.assign(
        new Error(`Durable store ${this.storeId} is already open`, { cause: error }),
        { code: "durable_store_locked" },
      );
    }
    try {
      const { openNodeSqliteStorage } =
        await import("@earendil-works/pi-durable/storage/sqlite/node");
      const storage = await openNodeSqliteStorage(join(this.directory, STORAGE_FILE));
      this.harnessStorage = storage;
      const harness = await Harness.open(
        storage,
        {
          models: shared.models,
          registry: shared.registry,
          settings: shared.settings,
          env: async ({ conversationId, cwd, read }, context) => {
            const runtime = await read.snapshot(DurableRuntime, conversationId, context);
            if (runtime?.kind !== "sandbox") {
              const env = new NodeExecutionEnv({ cwd: cwd ?? homedir() });
              sessionHostsByEnv.set(env, this);
              return env;
            }
            const env = this.sandboxEnvs.get(conversationId);
            if (!env)
              throw new Error("Durable sandbox workspace is not attached; refusing host execution");
            sessionHostsByEnv.set(env, this);
            return env;
          },
        },
        BACKGROUND_CONTEXT,
      );
      await this.watchTaskGraph(harness);
      this.watchFailure(harness);
      return this.opened(harness, shared.models);
    } catch (error) {
      await this.unlock();
      this.opening = undefined;
      throw error;
    }
  }

  private async watchTaskGraph(harness: Harness): Promise<void> {
    this.stopTaskGraph?.();
    const graph = await harness.taskGraph(BACKGROUND_CONTEXT);
    this.taskGraph = graph;
    const unsubscribe = graph.subscribe(() => {
      this.maybeClose();
    });
    this.stopTaskGraph = () => {
      unsubscribe();
      graph.dispose();
    };
  }

  /**
   * pi-durable closes a Harness by itself after any storage error: every later call fails with
   * `SessionFailed`. Reopen the store instead of handing that dead Harness out until a restart,
   * then tell the runtime so it re-attaches the sessions of this tree.
   */
  private watchFailure(harness: Harness): void {
    // This host drops its services before it closes a Harness, so a close that begins while
    // the Harness is still current is a failure.
    harness.subscribeClose(() => {
      if (this.services?.harness === harness) this.failingHarness = harness;
    });
    void harness.closed.then(async (end) => {
      if (end.reason !== "failed") return;
      // A Harness a recovery attempt opened and then dropped is that recovery's business.
      while (this.recovering) await this.recovering;
      if (this.services?.harness !== harness) return;
      if (this.closed || this.closing || this.runtime.shuttingDown) return;
      const recovering = this.recover(end.error).catch(async (error: unknown) => {
        // Recovery itself must never leave `recovering` set: give up, and say so.
        await this.seal(error);
        return { kind: "abandoned" as const, error };
      });
      this.recovering = recovering;
      const outcome = await recovering;
      if (this.recovering === recovering) this.recovering = undefined;
      // Shutdown detaches the sessions for restart; there is nothing to re-attach or end.
      if (outcome.kind === "stopped") return;
      // After `recovering` clears: the listener re-attaches sessions, which open this host.
      await this.runtime
        .onHostRecovered?.(this, outcome.kind === "abandoned" ? outcome.error : undefined)
        .catch((error: unknown) => {
          log.error("durable_store.recovery_listener_failed", {
            storeId: this.storeId,
            error: safeErrorMessage(error),
          });
        });
    });
  }

  private async recover(
    error: unknown,
  ): Promise<{ kind: "recovered" } | { kind: "stopped" } | { kind: "abandoned"; error: unknown }> {
    log.error("durable_store.session_failed", {
      storeId: this.storeId,
      error: safeErrorMessage(error),
    });
    // The Harness already closed itself and its storage. Drop what was bound to it.
    this.cancelIdleClose();
    await this.dropOpened();
    // Each session's backend opens its MCP servers again when it re-attaches.
    await Promise.allSettled([...this.mcps.keys()].map((id) => this.closeMcp(id)));
    let failure = error;
    for (const delay of RECOVERY_DELAYS_MS) {
      if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
      if (this.runtime.shuttingDown) {
        await this.seal();
        return { kind: "stopped" };
      }
      try {
        const { harness } = await (this.opening ??= this.openInner());
        for (const stream of [...this.transcripts]) await this.reattachTranscript(harness, stream);
        // Shutdown began while this opened: `close()` closes it; nothing re-attaches.
        if (this.runtime.shuttingDown) return { kind: "stopped" };
        await this.resume();
        log.info("durable_store.recovered", { storeId: this.storeId });
        return { kind: "recovered" };
      } catch (reopenError) {
        failure = reopenError;
        // A failed open must not be reused by the next attempt.
        await this.dropOpened();
        log.warn("durable_store.reopen_failed", {
          storeId: this.storeId,
          error: safeErrorMessage(reopenError),
        });
      }
    }
    log.error("durable_store.recovery_abandoned", {
      storeId: this.storeId,
      error: safeErrorMessage(failure),
    });
    await this.seal(failure);
    return { kind: "abandoned", error: failure };
  }

  /**
   * Forget the opened Harness: services first, so its failure watcher sees it is no longer
   * this host's, then close it (a failed one closed itself) and release the lock.
   */
  private async dropOpened(): Promise<void> {
    const opening = this.opening;
    this.stopTaskGraph?.();
    this.stopTaskGraph = undefined;
    this.taskGraph = undefined;
    this.dropServices();
    this.opening = undefined;
    this.harnessStorage = undefined;
    await opening
      ?.then(({ harness }) => harness.close(BACKGROUND_CONTEXT))
      .catch((error: unknown) => {
        log.warn("durable_store.close_failed", {
          storeId: this.storeId,
          error: safeErrorMessage(error),
        });
      });
    await this.unlock();
  }

  /**
   * Dead for good: nothing reopens this host. Releases its sandbox work and streams; a waiter
   * on `open()` must not take the lock behind a host the runtime forgot. With `failure`, its
   * `open()` rejects with it; a later `openHost` builds a fresh host, which is the next attempt.
   */
  private async seal(failure?: unknown): Promise<void> {
    if (failure !== undefined) this.abandoned = failure;
    this.closed = true;
    await this.dropOpened();
    await Promise.allSettled(
      [...this.sandboxEnvs.keys()].map((id) => this.unbindSandboxEnv(id, true)),
    );
    for (const stream of this.transcripts) stream.subscription.dispose();
    this.transcripts.clear();
    this.runtime.forgetHost(this);
  }

  /** The stream's room failed while the store stayed open: resume the socket on a fresh room. */
  private async reattachLostTranscript(stream: TranscriptStream): Promise<void> {
    if (!this.transcripts.has(stream)) return;
    // The store itself is failing: its recovery re-attaches every transcript.
    if (this.failedWithStore(undefined)) return;
    try {
      await this.use((harness) => this.reattachTranscript(harness, stream));
    } catch (error) {
      log.error("durable_store.transcript_reattach_failed", {
        storeId: this.storeId,
        conversationId: stream.id,
        error: safeErrorMessage(error),
      });
    }
  }

  /** Resume the socket where it was: the subscription's cursor is the last entry it sent. */
  private async reattachTranscript(harness: Harness, stream: TranscriptStream): Promise<void> {
    const previous = stream.subscription;
    try {
      const subscription = await attachConversationStream({
        harness,
        conversationId: stream.id,
        ...stream.options,
        ...(previous.cursor ? { afterEntryId: previous.cursor } : {}),
      });
      // The socket left, or another re-attach (store recovery and a lost room can race)
      // already replaced the subscription: one socket keeps exactly one subscription.
      if (!this.transcripts.has(stream) || stream.subscription !== previous) subscription.dispose();
      else {
        stream.subscription = subscription;
        previous.dispose();
      }
    } catch (error) {
      log.error("durable_store.transcript_reattach_failed", {
        storeId: this.storeId,
        conversationId: stream.id,
        error: safeErrorMessage(error),
      });
    }
  }

  private async unlock(): Promise<void> {
    try {
      await this.releaseLock?.();
    } catch (error) {
      log.error("durable_store.unlock_failed", {
        storeId: this.storeId,
        error: safeErrorMessage(error),
      });
    }
    this.releaseLock = undefined;
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

  /** Close this store and release the directory lock. */
  close(): Promise<void> {
    if (this.recovering) return this.recovering.then(() => this.close());
    if (this.closing) return this.closing;
    if (!this.opening) {
      this.closed = true;
      this.runtime.forgetHost(this);
      return Promise.resolve();
    }
    this.cancelIdleClose();
    this.closing = this.closeInner().finally(() => {
      this.closing = undefined;
    });
    return this.closing;
  }

  private async closeInner(): Promise<void> {
    try {
      if (this.opening) {
        const { harness } = await this.opening;
        this.stopTaskGraph?.();
        this.stopTaskGraph = undefined;
        this.taskGraph = undefined;
        this.closed = true;
        this.dropServices();
        // Closing interrupts invocations without settling their tasks. Recorded
        // restart work remains durable and is continued by the next Harness.open.
        await harness.close(BACKGROUND_CONTEXT);
        await Promise.all(
          [...this.sandboxEnvs.keys()].map((id) => this.unbindSandboxEnv(id, true)),
        );
      } else {
        this.closed = true;
      }
    } finally {
      await Promise.all([...this.mcps.keys()].map((id) => this.closeMcp(id)));
      await this.unlock();
      this.opening = undefined;
      this.harnessStorage = undefined;
      this.runtime.forgetHost(this);
    }
  }

  /** Abort leftover tickers so an empty store can close. Jobs and child-owning tasks stay. */
  private async retireIdleTickers(): Promise<void> {
    if (this.runtime.shuttingDown || this.closed || this.closing || !this.opening) return;
    const { harness } = await this.opening;
    if (this.runtime.shuttingDown || this.closed || this.closing) return;
    const keep = new Set<number>();
    for (const node of Object.values(this.taskGraph?.value?.tasks ?? {})) {
      if (node.conversations.length > 0) keep.add(node.id);
    }
    const conversationIds = new Set(
      Object.values(this.taskGraph?.value?.tasks ?? {}).map((node) => node.conversationId),
    );
    for (const conversationId of conversationIds) {
      if (this.closed || this.closing) return;
      const jobs = await harness.snapshot(DurableJobs, conversationId, BACKGROUND_CONTEXT);
      for (const job of jobs?.jobs ?? []) if (!job.delivered) keep.add(job.taskId);
    }
    for (const node of Object.values(this.taskGraph?.value?.tasks ?? {})) {
      if (this.closed || this.closing) return;
      if (!node.background || keep.has(node.id)) continue;
      await harness.abortTask(node.id, BACKGROUND_CONTEXT);
    }
  }

  private async closeIfIdle(): Promise<void> {
    if (
      this.runtime.startupHeld ||
      this.runtime.shuttingDown ||
      !this.isIdle ||
      this.closed ||
      this.closing
    )
      return;
    await this.close().catch((error) => {
      log.error("durable_store.idle_close_failed", {
        storeId: this.storeId,
        error: safeErrorMessage(error),
      });
    });
  }

  private cancelIdleClose(): void {
    if (this.idleCloseTimer === undefined) return;
    clearImmediate(this.idleCloseTimer);
    this.idleCloseTimer = undefined;
  }

  private maybeClose(): void {
    if (
      this.runtime.startupHeld ||
      this.runtime.shuttingDown ||
      !this.isIdle ||
      this.closed ||
      this.closing
    )
      return;
    if (this.idleCloseTimer !== undefined) return;
    // Defer so a task-graph publish cannot close the host reentrantly, and so a
    // caller that opens then retains in the same turn is not racing this close.
    this.idleCloseTimer = setImmediate(() => {
      this.idleCloseTimer = undefined;
      void this.closeIfIdle();
    });
  }
}

/** Process-owned durable runtime. A disabled server never creates this owner. */
export class DurableHarness {
  private closed = false;
  /** Server catalog runtime. Carries global `registerProvider` overlays such as Anthropic OMP. */
  private boundModels?: ModelRuntime;
  private discoveredModelsRequired = false;
  startupHeld = true;
  shuttingDown = false;
  private runSettings?: HarnessSettings;
  /** The manager `runSettings` reads live. Writes reach every conversation and persist to user settings. */
  private runPolicy?: SettingsManager;
  private registry?: Registry;
  private threads?: DurableThreads;
  private control?: DurableControlHost;
  /** Extensions from Oppi's bundled packages, in install order. */
  private bundled: readonly LoadedDurableExtension[] = [];
  /** Extensions from the durable entries of enabled Pi packages, in load order. */
  private packageExtensions: readonly LoadedDurableExtension[] = [];
  /** One load or reload at a time. */
  private extensionLoad: Promise<unknown> = Promise.resolve();
  private shared?: Promise<{
    models: ModelRuntime;
    registry: Registry;
    settings: HarnessSettings;
  }>;
  private readonly hosts = new Map<string, SessionHost>();
  private readonly openingHosts = new Map<string, Promise<SessionHost>>();
  /** Abort leftover work of stopped conversations when a store first opens. */
  onHostOpened?: (host: SessionHost) => Promise<void>;
  /**
   * A store's Harness failed and the host reopened it (`failure` undefined), or gave up
   * (`failure` is the last error). Re-attach or end the sessions of that tree.
   */
  onHostRecovered?: (host: SessionHost, failure: unknown) => Promise<void>;
  /** The session tools; they reach Oppi through the host bound with `bindThreads`. */
  private readonly sessions = createDurableSessions(() => this.threads);
  /** The control conversation's tools; they reach Oppi through the host bound with `bindControl`. */
  private readonly controlTools = createDurableControl(() => this.control);
  /**
   * Runs the control conversation's codemode scripts. A sandbox only holds defaults; each script
   * gets its own VM worker, limited so a runaway script fails inside it, not the server.
   */
  private readonly controlSandbox = new CodemodeSandbox({
    memoryLimitBytes: CONTROL_SCRIPT_MEMORY_LIMIT_BYTES,
  });
  /**
   * pi-durable's own `codemode` for the control conversation: scripts call the control tools as
   * nested calls and resume after a restart without running finished calls again. No `models.*`:
   * control has no use for classifiers or image generation.
   */
  readonly controlCodemode = createCodemodeExtension({
    sandbox: this.controlSandbox,
    models: false,
  });

  /**
   * @param bundledDir Where Oppi's bundled packages are; a test points it at a copy to reload.
   */
  constructor(
    readonly dataDir: string,
    private readonly bundledDir = BUNDLED_PACKAGES_DIR,
  ) {}

  /** Oppi's built-in extensions, in install order. */
  private get builtIns(): readonly BuiltIn[] {
    return [
      { extension: DurableSandboxTools, runtimes: ["sandbox"] },
      ...this.bundled,
      { extension: this.sessions, runtimes: ["host", "sandbox"] },
      { extension: DurableProjectContext, runtimes: ["host", "sandbox"] },
      { extension: this.controlTools, runtimes: ["host"] },
    ];
  }

  private builtIn(name: string): Extension {
    const found = this.builtIns.find((builtIn) => builtIn.extension.name === name);
    if (!found) throw new Error(`Built-in durable extension ${name} is not loaded`);
    return found.extension;
  }

  /** The installed `oppi.sessions`, which offers `subagent`. */
  get sessionsExtension(): Extension {
    return this.builtIn(SESSIONS_EXTENSION);
  }

  /** The control conversation's exact selection. Never part of `defaultExtensions`. */
  get controlExtensions(): readonly Extension[] {
    return controlConversationExtensions((name) => this.builtIn(name), this.controlCodemode);
  }

  /**
   * The Harness default selection: CodingTools and every built-in but control, in install order.
   * A conversation whose stored selection is an `{ add }` edit starts from it, so it never picks
   * up another session's MCP extension from the registry.
   */
  get defaultExtensions(): Extension[] {
    return [
      CodingTools,
      ...this.builtIns
        .filter((builtIn) => builtIn.extension.name !== CONTROL_EXTENSION)
        .map((builtIn) => builtIn.extension),
    ];
  }

  /** What a new session of `runtime` starts from: CodingTools and the built-ins it allows. */
  builtInsFor(runtime: DurableExtensionRuntime): Extension[] {
    return [
      CodingTools,
      ...this.builtIns
        .filter(
          (builtIn) =>
            builtIn.runtimes.includes(runtime) && builtIn.extension.name !== CONTROL_EXTENSION,
        )
        .map((builtIn) => builtIn.extension),
    ];
  }

  /**
   * The built-ins a bound conversation's `{ add }` edit enrolls on every attach, in install order:
   * those every runtime allows, with `oppi.sessions` only when the session may spawn.
   */
  attachedBuiltIns(spawn: boolean): Extension[] {
    return this.builtIns
      .filter(
        (builtIn) =>
          builtIn.runtimes.includes("host") &&
          builtIn.runtimes.includes("sandbox") &&
          (spawn || builtIn.extension.name !== SESSIONS_EXTENSION),
      )
      .map((builtIn) => builtIn.extension);
  }

  get isClosed(): boolean {
    return this.closed;
  }

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

  /**
   * Classic `set_auto_retry`, `set_auto_compaction`, and the queue modes write global user
   * settings. The Harness reads the same getters at every use, so writing here is the same
   * scope: it reaches every durable conversation, and no per-session copy exists.
   */
  get runPolicySettings(): SettingsManager {
    if (!this.runPolicy) throw new Error("Server durable runtime is not open");
    return this.runPolicy;
  }

  /**
   * Extensions loaded from Pi packages that a session of this runtime selects next to the
   * built-ins. The control conversation selects none of them.
   */
  packageExtensionsFor(runtime: DurableExtensionRuntime): Extension[] {
    return this.packageExtensions
      .filter((loaded) => loaded.runtimes.includes(runtime))
      .map((loaded) => loaded.extension);
  }

  /** Every loaded Pi package durable extension, with the classic IDs saved Agents select it by. */
  get loadedPackages(): readonly LoadedDurableExtension[] {
    return this.packageExtensions;
  }

  /**
   * Re-read Oppi's bundled packages and the durable entries of enabled Pi packages, and install
   * them in the open registry. Installing an extension under an installed name replaces it in
   * place: running tool calls finish on their old code, and the next task phase, request, or
   * call uses the new code. A package that fails to load, bundled or not, keeps its previous code
   * installed; a Pi package that is gone is uninstalled, and conversations that selected it stop
   * getting it.
   */
  async reloadExtensions(): Promise<DurableExtensionReport> {
    const { registry } = await this.ensureShared();
    return this.loadExtensions(registry, false);
  }

  private loadExtensions(registry: Registry, first: boolean): Promise<DurableExtensionReport> {
    const run = this.extensionLoad.then(() => this.loadExtensionsOnce(registry, first));
    this.extensionLoad = run.catch(() => undefined);
    return run;
  }

  private async loadExtensionsOnce(
    registry: Registry,
    first: boolean,
  ): Promise<DurableExtensionReport> {
    const builtIns = await this.loadBuiltIns(registry, first);
    // Installed so the control conversation can select it by name. Installing is not
    // selecting: only `defaultExtensions` is the default selection of other conversations.
    if (first) registry.install(this.controlCodemode);
    const packages = await this.loadPackages(registry);
    const report: DurableExtensionReport = {
      loaded: [...builtIns.loaded, ...packages.loaded],
      kept: [...builtIns.kept, ...packages.kept],
      removed: packages.removed,
      skipped: packages.skipped,
      errors: [...builtIns.errors, ...packages.errors],
    };
    this.logExtensionReport(report);
    return report;
  }

  /**
   * Load Oppi's bundled packages. The first load installs every built-in in order and fails the
   * runtime when one is broken; a reload replaces the ones that load and keeps the previous code
   * of the others. A built-in is never uninstalled.
   */
  private async loadBuiltIns(
    registry: Registry,
    first: boolean,
  ): Promise<Pick<DurableExtensionReport, "loaded" | "kept" | "errors">> {
    const previous = this.bundled;
    const found = bundledDurableExtensionPackages(this.bundledDir);
    const others = [
      CodingTools,
      this.controlCodemode,
      ...this.builtIns
        .map((builtIn) => builtIn.extension)
        .filter((extension) => !previous.some((old) => old.extension === extension)),
    ];
    // Names only: built-ins may offer a tool CodingTools has, as background-jobs does with `bash`.
    const result = await loadDurableExtensions(found.packages, {
      names: reservedBy(others).names,
      tools: new Set(),
    });
    const errors = [...found.errors, ...result.errors, ...result.skipped];
    if (first && errors.length)
      throw new Error(
        `Oppi's bundled durable extensions failed to load: ${errors
          .map((issue) => `${issue.entry}: ${issue.message}`)
          .join("; ")}`,
      );
    const fresh = new Map(result.loaded.map((loaded) => [loaded.extension.name, loaded]));
    const kept = previous.filter((old) => !fresh.has(old.extension.name));
    this.bundled = [
      ...previous.map((old) => fresh.get(old.extension.name) ?? old),
      ...result.loaded.filter(
        (loaded) => !previous.some((old) => old.extension.name === loaded.extension.name),
      ),
    ];
    if (first) for (const builtIn of this.builtIns) registry.install(builtIn.extension);
    else for (const loaded of result.loaded) registry.install(loaded.extension);
    return {
      loaded: result.loaded.map((loaded) => summarize(loaded, true)),
      kept: kept.map((old) => summarize(old, true)),
      errors,
    };
  }

  private async loadPackages(registry: Registry): Promise<DurableExtensionReport> {
    const previous = this.packageExtensions;
    let discovered: Awaited<ReturnType<typeof discoverDurableExtensionPackages>>;
    try {
      discovered = await discoverDurableExtensionPackages(getAgentDir());
    } catch (error) {
      // Discovery itself failed: change nothing, so a settings typo cannot unload everything.
      return {
        loaded: [],
        kept: previous.map((old) => summarize(old, false)),
        removed: [],
        skipped: [],
        errors: [
          { entry: getAgentDir(), message: `Package discovery failed: ${safeErrorMessage(error)}` },
        ],
      };
    }
    const result = await loadDurableExtensions(
      discovered.packages,
      reservedBy([...this.defaultExtensions, ...this.controlExtensions]),
    );
    const loadedNames = new Set(result.loaded.map((loaded) => loaded.extension.name));
    const errors = [...discovered.errors, ...result.errors];
    const failedRoots = new Set(errors.flatMap((issue) => (issue.root ? [issue.root] : [])));
    const kept = previous.filter(
      (old) => failedRoots.has(old.root) && !loadedNames.has(old.extension.name),
    );
    const next = [...result.loaded, ...kept];
    const nextNames = new Set(next.map((loaded) => loaded.extension.name));
    for (const loaded of result.loaded) registry.install(loaded.extension);
    const removed = previous.filter((old) => !nextNames.has(old.extension.name));
    for (const old of removed) registry.uninstall(old.extension);
    this.packageExtensions = next;
    return {
      loaded: result.loaded.map((loaded) => summarize(loaded, false)),
      kept: kept.map((old) => summarize(old, false)),
      removed: removed.map((old) => old.extension.name),
      skipped: result.skipped,
      errors,
    };
  }

  private logExtensionReport(report: DurableExtensionReport): void {
    if (report.loaded.length || report.removed.length)
      log.info("durable_extensions.loaded", {
        loaded: report.loaded.map((loaded) => loaded.name),
        removed: report.removed,
      });
    for (const issue of report.errors)
      log.error("durable_extensions.load_failed", { entry: issue.entry, message: issue.message });
  }

  /** The installed definition of task `name`; pi-durable resolves tasks by name, so the current code. */
  installedTask(name: string): AnyTask {
    const task = this.registry?.snapshot().task(name);
    if (!task) throw new Error(`Durable task ${name} is not installed`);
    return task;
  }

  installExtension(extension: Extension): void {
    if (!this.registry) throw new Error("Server durable runtime is not open");
    this.registry.install(extension);
  }
  uninstallExtension(extension: Extension): void {
    this.registry?.uninstall(extension);
  }

  /** Production open must not invent a runtime that skipped extension provider discovery. */
  requireDiscoveredModels(): void {
    if (this.shared) {
      throw new Error("Server durable model runtime cannot be required after the runtime opens");
    }
    this.discoveredModelsRequired = true;
  }

  /** Adopt the server ModelRuntime. Call before open(); later catalog resyncs stay on this object. */
  bindModelRuntime(models: ModelRuntime): void {
    if (this.shared) {
      throw new Error("Server durable model runtime cannot change after the runtime opens");
    }
    this.boundModels = models;
  }

  async ensureShared(): Promise<{
    models: ModelRuntime;
    registry: Registry;
    settings: HarnessSettings;
  }> {
    if (this.closed) throw new Error("Server durable runtime is closed");
    return (this.shared ??= this.ensureSharedInner());
  }

  private async ensureSharedInner(): Promise<{
    models: ModelRuntime;
    registry: Registry;
    settings: HarnessSettings;
  }> {
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
    const settings = SettingsManager.create(homedir(), agentDir, { projectTrusted: false });
    this.runPolicy = settings;
    const registry = createRegistry();
    registry.install(CodingTools);
    await this.loadExtensions(registry, true);
    this.registry = registry;
    this.runSettings = harnessSettings(settings, this.defaultExtensions);
    return { models, registry, settings: this.runSettings };
  }

  host(storeId: string): SessionHost | undefined {
    return this.hosts.get(storeId);
  }

  openHosts(): readonly SessionHost[] {
    return [...this.hosts.values()];
  }

  forgetHost(host: SessionHost): void {
    if (this.hosts.get(host.storeId) === host) this.hosts.delete(host.storeId);
  }

  async withSession<T>(
    session: Pick<Session, "serverDurable">,
    fn: (harness: Harness, host: SessionHost) => Promise<T>,
  ): Promise<T> {
    return (await this.openHost(requireDurableStoreId(session))).use(fn);
  }

  /**
   * Open (or reuse) the store for `storeId`. Creates the directory and meta.json
   * on first use. The directory is locked while the host is open.
   */
  async openHost(
    storeId: string,
    meta?: Partial<DurableStoreMeta> & { cwd?: string },
  ): Promise<SessionHost> {
    assertDurableStoreId(storeId);
    if (this.closed) throw new Error("Server durable runtime is closed");
    const existing = this.hosts.get(storeId);
    if (existing?.isOpen) {
      await existing.open();
      return existing;
    }
    const pending = this.openingHosts.get(storeId);
    if (pending) return pending;
    const opening = this.openHostInner(storeId, meta);
    this.openingHosts.set(storeId, opening);
    try {
      return await opening;
    } finally {
      if (this.openingHosts.get(storeId) === opening) this.openingHosts.delete(storeId);
    }
  }

  private async openHostInner(
    storeId: string,
    meta?: Partial<DurableStoreMeta> & { cwd?: string },
  ): Promise<SessionHost> {
    await this.ensureShared();
    const directory = durableStoreDir(this.dataDir, storeId);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    let stored = readStoreMeta(directory);
    if (!stored) {
      const cwd = meta?.cwd;
      if (!cwd) throw new Error(`Durable store ${storeId} has no working directory`);
      stored = {
        createdAt: meta.createdAt ?? Date.now(),
        cwd,
        ...(meta.name ? { name: meta.name } : {}),
        ...(meta.workspaceId ? { workspaceId: meta.workspaceId } : {}),
        ...(meta.agent ? { agent: meta.agent } : {}),
      };
      writeStoreMeta(directory, stored);
    }
    const host = new SessionHost(this, storeId, directory, stored, this.startupHeld);
    this.hosts.set(storeId, host);
    await host.open();
    await this.onHostOpened?.(host);
    return host;
  }

  /**
   * Test seam: bind an already-open Harness as this store without the directory lock. Opens
   * the runtime first, so the built-ins the session's backend selects are loaded.
   */
  async attachOpened(
    storeId: string,
    opened: { harness: Harness; storage: Storage; models: ModelRuntime },
    meta: DurableStoreMeta,
  ): Promise<SessionHost> {
    assertDurableStoreId(storeId);
    if (!this.shared && !this.boundModels) this.boundModels = opened.models;
    await this.ensureShared();
    const directory = durableStoreDir(this.dataDir, storeId);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    writeStoreMeta(directory, meta);
    const host = new SessionHost(this, storeId, directory, meta, this.startupHeld);
    host.bindOpenedHarness(opened.harness, opened.storage, opened.models);
    this.hosts.set(storeId, host);
    return host;
  }

  async finishStartup(): Promise<void> {
    this.startupHeld = false;
    await Promise.all([...this.hosts.values()].map((host) => host.releaseResume()));
  }

  /** Close every open store. */
  async closeAll(): Promise<void> {
    this.closed = true;
    const hosts = [...this.hosts.values()];
    await Promise.all(hosts.map((host) => host.close()));
    await this.controlSandbox.close();
  }
}

/** Names and tool names a loaded package must not take from `extensions`. */
function reservedBy(extensions: readonly Extension[]): {
  names: Set<string>;
  tools: Set<string>;
} {
  return {
    names: new Set(extensions.map((extension) => extension.name)),
    tools: new Set(
      extensions.flatMap((extension) => extension.tools ?? []).map((tool) => tool.name),
    ),
  };
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

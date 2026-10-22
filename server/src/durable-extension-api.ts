import type { Context, JsonValue } from "@earendil-works/chord";
import type {
  Agent,
  ConversationId,
  TaskId,
  ToolExecutionApi,
  ToolExecutionResult,
  Tx,
} from "@earendil-works/pi-durable";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import type { TSchema } from "typebox";
import type { Job } from "../extensions/durable/background-jobs/contract.js";
import type { NotifyInput, NotifyOutcome } from "../extensions/durable/notify/contract.js";

/**
 * `oppi/durable`: the host API a durable extension imports for what only Oppi provides. The
 * extension itself is plain pi-durable (`export default defineExtension(...)`), and its package
 * declares the entry in `package.json` `oppi.durable`. The loader aliases this module, and
 * pi-durable, chord, pi-ai, and typebox, to the server's own copies, as upstream's plugin loader
 * resolved its plugin API.
 *
 * Every package entry gets its own evaluation of this module (the loader keeps no module cache,
 * so a reload re-reads everything), so nothing here may keep state: documents are matched by
 * kind, not by object, and the host the server binds lives in one process-wide slot that is
 * written once and never replaced.
 * @public
 */

/**
 * Oppi's extension UI: dialogs (`requestUI`), persistent notifications, and transcript cards,
 * kept in the conversation's `oppi.extension-ui` and `oppi.input-cards` documents and shown by
 * the server's generic projection.
 */
export {
  DurableInputCards,
  DurableUI,
  requestUI,
  type UINotification,
  type UIRequest,
  type UIResponse,
  type UIState,
} from "../extensions/durable/durable-ui.js";

// ---------------------------------------------------------------------------------------------
// The host: server internals Oppi's own built-ins need. The server binds it before it loads any
// package; extension code reads it with `oppiHost()`.
// ---------------------------------------------------------------------------------------------

/**
 * What Oppi's server offers durable extensions beyond pi-durable. `env` is a tool call's
 * `api.env`; the server knows which conversation each env it made runs, and scopes what it
 * returns to that conversation.
 */
export interface OppiDurableHost {
  /**
   * `subagent`'s side of Oppi for the conversation running `env`: it reaches only that
   * conversation's own children. Undefined for an env the server did not make, or until the
   * server binds its threads.
   */
  sessions(env: ExecutionEnv | undefined): DurableSessionsHost | undefined;
  /**
   * The `oppi` CLI, only when `env` runs the control conversation; undefined for every other
   * conversation.
   */
  control(env: ExecutionEnv | undefined): DurableControlHost | undefined;
  /**
   * `notify`'s send for the Session bound to the conversation running `env`. Undefined for an
   * env the server did not make, or a conversation without a Session.
   */
  notify(
    env: ExecutionEnv | undefined,
  ): ((input: NotifyInput) => Promise<NotifyOutcome>) | undefined;
  /** File tools over a sandbox session's Gondolin VM. */
  readonly sandbox: OppiSandboxHost;
}

const HOST = Symbol.for("oppi.durable.host");
type HostSlot = { [HOST]?: OppiDurableHost };

/** The host the Oppi server bound. Throws outside a server that loads durable extensions. */
export function oppiHost(): OppiDurableHost {
  const host = (globalThis as HostSlot)[HOST];
  if (!host) throw new Error("oppi/durable: no Oppi server has bound its durable host");
  return host;
}

/**
 * Server only: bind the host once, before any package loads. The slot cannot be written,
 * deleted, or bound again, and the host's objects are frozen, so package code cannot replace
 * the host or wrap one of its functions (`control`, a sandbox tool's `execute`).
 */
export function bindOppiHost(host: OppiDurableHost): void {
  if (Object.hasOwn(globalThis, HOST))
    throw new Error("oppi/durable: the Oppi durable host is already bound");
  // Freeze is shallow: freeze each object a built-in calls through.
  for (const tool of [host.sandbox.ls, host.sandbox.find, host.sandbox.grep]) Object.freeze(tool);
  Object.freeze(host.sandbox);
  Object.freeze(host);
  Object.defineProperty(globalThis, HOST, {
    value: host,
    writable: false,
    configurable: false,
    enumerable: false,
  });
}

// --- sessions (`oppi.sessions`) --------------------------------------------------------------

/** Registered name of the subagent reporter task; Stop aborts tasks of this kind. */
export const SESSION_REPORTER_TASK = "oppi.session-reporter";

/**
 * The tasks that wake conversation `id` when they end: its subagent reporters among `tasks`
 * (live task records, of any conversation) and its background jobs not yet delivered, from
 * `jobs`, its `DurableJobs` document. Tickers that never end (pills, working words) are not
 * among them. The one rule behind `SessionHost.pendingWakers` (`DurableSessionsHost`), which
 * reads `tasks` from the scheduler and also drops blocked tasks, and the subagent pill, which
 * reads them in a commit, where blocked is not known.
 */
export function wakingTasks(
  id: ConversationId,
  tasks: Iterable<{
    readonly id: TaskId;
    readonly conversationId?: ConversationId;
    readonly kind: string;
  }>,
  jobs: { readonly jobs: readonly Job[] } | null | undefined,
): TaskId[] {
  const waking: TaskId[] = [];
  for (const task of tasks)
    if (task.conversationId === id && task.kind === SESSION_REPORTER_TASK) waking.push(task.id);
  for (const job of jobs?.jobs ?? [])
    if (job.decision === "background" && !job.delivered) waking.push(job.taskId);
  return waking;
}

/** A session as the sender of an agent message. */
export type SessionSender = { sessionId: string; name?: string };

/** What `subagent spawn` asks for. */
export type SubagentRequest = {
  /** A saved Agent, by id or name. */
  agent?: string;
  /** provider/model; overrides the saved Agent's. */
  model?: string;
  /** Overrides the saved Agent's. */
  thinking?: string;
  allowNestedDelegation?: boolean;
};

/** A spawn the host resolved: how the child conversation is configured. */
export interface ResolvedSubagent {
  /** The saved Agent's name, for `list`. */
  agent?: string;
  /** The saved Agent's emoji icon, for the subagent pill's row title. */
  icon?: string;
  /**
   * Configure the new child inside its creating commit: its agent (`configure`), runtime, and
   * `oppi.agent` documents, so it never exists unconfigured.
   */
  apply(tx: Tx, child: ConversationId): Promise<void>;
}

/**
 * `DurableSessionsHost.activate`'s outcome: what `submit` returned, or why the child's Session
 * could not be attached (`submit` did not run). `shuttingDown`: the server is stopping, so the
 * caller should wait for its abort and run again after the restart instead of failing.
 */
export type Activated<T> = { submitted: T } | { failed: string; shuttingDown: boolean };

/**
 * What the subagent tool needs from Oppi (see `DurableThreads.forCaller`), for one calling
 * conversation. Every Session it takes must be bound to a child conversation that the caller
 * owns; any other is refused.
 */
export interface DurableSessionsHost {
  /** The store of the calling conversation. */
  readonly storeId: string;
  /**
   * The Oppi Session bound to a child conversation the caller owns, created on first use (not
   * attached: `activate` does that with the first message). Idempotent: one Session per
   * conversation id, however often this runs.
   */
  materialize(child: { conversationId: ConversationId; name: string }): Promise<string>;
  /** The calling conversation's own Oppi session: who sent an agent message. */
  sender(): SessionSender | undefined;
  /**
   * Live tasks of a child conversation the caller owns that wake it when they end: its
   * background jobs not yet delivered and its own subagent reporters. Tickers that never end
   * (pills, working words) are not among them. The same set holds the child's idle timeout
   * (`hasPendingWake`). By conversation, not Session: the wakers belong to the conversation,
   * which outlives a deleted Session. Rejects for a conversation the caller does not own.
   */
  pendingWakers(child: ConversationId): Promise<TaskId[]>;
  /**
   * Wait until a child's conversation is idle. Undefined on success, otherwise an error message.
   * Rejects with `signal`'s reason once it aborts, and then waits no longer: the child's run is
   * not the caller's to wait out (Stop of the caller does not cascade to a background child).
   */
  waitForIdle(sessionId: string, signal?: AbortSignal): Promise<string | undefined>;
  /**
   * Attach a child's Session (or keep it attached) and run `submit`, the commit that delivers
   * a message to it. A child stops once it settles with no pending wake; until `submit`
   * settles it does not, and a stop already under way finishes first. Errors of `submit`
   * propagate; a Session that cannot be attached is a `failed` result.
   */
  activate<T>(sessionId: string, submit: () => Promise<T>): Promise<Activated<T>>;
  /**
   * Resolve a spawn: the saved Agent, model, and thinking level, checked against the caller's
   * delegation grant and workspace. `agent` is the caller's current agent. Rejects with a
   * message for the model.
   */
  resolveAgent(request: SubagentRequest, agent: Agent): Promise<ResolvedSubagent>;
}

// --- control (`oppi.control`) ----------------------------------------------------------------

/** A JSON object; the CLI envelope is one, and a stored document must be JSON. */
export type ControlJson = { [key: string]: JsonValue };

/** One write the CLI is about to send, as the owner must see it before it goes out. */
export interface ControlWrite {
  method: string;
  /** Path and query, as sent. */
  path: string;
  body?: JsonValue;
  /** For a PATCH: the record as it is now, fetched by the host; absent when it could not be read. */
  current?: JsonValue;
  currentError?: string;
}

/** What the control tools need from Oppi (see `DurableControlCli`). */
export interface DurableControlHost {
  /**
   * Run one `oppi` CLI invocation in this process and resolve its JSON envelope; never rejects
   * for a failing command. `onWrite` is awaited before each non-GET request is sent and decides
   * it by resolving or throwing (a thrown `code` becomes the envelope's error code); without
   * `onWrite` every non-GET is refused. `key` is the tool call's task id, the same when a crashed
   * call reruns: the host derives the one replay key a write carries from it, and replaces any
   * key the caller passed. `wrote` is true once a write was approved.
   */
  run(
    argv: readonly string[],
    options: {
      conversationId: ConversationId;
      key: string;
      signal: AbortSignal;
      onWrite?: (write: ControlWrite) => Promise<void>;
    },
  ): Promise<{ envelope: ControlJson; wrote: boolean }>;
}

// --- sandbox tools (`oppi.sandbox-tools`) ----------------------------------------------------

/** A file tool over the calling sandbox session's VM. Throws for any other execution env. */
export interface OppiSandboxTool {
  readonly description: string;
  readonly parameters: TSchema;
  execute(args: unknown, api: ToolExecutionApi, context: Context): Promise<ToolExecutionResult>;
}

/**
 * Gondolin operations behind the sandbox tools. Only schemas and descriptions come from Pi's
 * host tools; execution always runs over the invocation's sandbox VM, never host rg/fd.
 */
export interface OppiSandboxHost {
  readonly ls: OppiSandboxTool;
  readonly find: OppiSandboxTool;
  /** Guest rg or grep. */
  readonly grep: OppiSandboxTool;
  /**
   * Read an image file (PNG, JPEG, GIF, WebP) through the sandbox VM. Undefined when the call
   * does not run in a sandbox or the file is not an image, so the caller reads it as text.
   */
  readImage(
    args: { path: string },
    api: ToolExecutionApi,
    context: Context,
  ): Promise<Pick<ToolExecutionResult, "output"> | undefined>;
}

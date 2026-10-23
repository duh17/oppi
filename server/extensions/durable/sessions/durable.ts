import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import type { Context, JsonValue } from "@earendil-works/chord";
import { withCancel } from "@earendil-works/chord/context";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import {
  AgentDoc,
  AssistantEntry,
  InboxDoc,
  LiveDoc,
  defineExtension,
  defineTask,
  defineTool,
  section,
  type ConversationId,
  type DocumentWatch,
  type EntryId,
  type Extension,
  type InputSubmissionDraft,
  type LiveState,
  type Task,
  type TaskId,
  type TaskRecord,
  type ToolExecutionApi,
  type ToolExecutionResult,
  type Tx,
} from "@earendil-works/pi-durable";
import {
  SESSION_REPORTER_TASK,
  oppiHost,
  type DurableSessionsHost,
  type SessionSender,
  type SubagentWorktreeRequest,
} from "oppi/durable";
import { DurableJobs } from "../background-jobs/contract.js";
import { agentMessageEntry, type MessageOrigin } from "./agent-message.js";
import { Subagents, ensureSubagentWidget, type Child, type SubagentWorktree } from "./contract.js";
import { isLive, liveTasks } from "./wakers.js";
import { SubagentWidget } from "./widget.js";

type Sender = SessionSender;

function sentBy(
  sender: Sender | undefined,
  intent: MessageOrigin["intent"],
  textOffset?: number,
): { entry?: ReturnType<typeof agentMessageEntry> } {
  return sender
    ? { entry: agentMessageEntry({ kind: "session", ...sender, intent }, textOffset) }
    : {};
}

/**
 * Owner of a background child. It finishes at once; being a background task it is the
 * boundary that keeps the parent's Stop and idle waits away from the child
 * (pi-durable example 23).
 */
const Anchor = defineTask<null, { phase: "done" }, null>({
  name: "oppi.session-anchor",
  version: 1,
  initial: () => ({ phase: "done" }),
  phases: {
    done: (_anchor, runtime, context) =>
      runtime.commit(
        () => ({ status: "terminal", outcome: { status: "completed", result: null } }),
        context,
      ),
  },
  abort: (_anchor, runtime, context) =>
    runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
});

type ReporterInput = {
  conversationId: ConversationId;
  sessionId: string;
  name: string;
  /** The message it delivers: a spawn's task, or a `send`'s message. */
  task: string;
  /** The spawning session; absent on reporters created before agent messages. */
  parent?: Sender;
  /** A `send`: how the message reaches a busy child, and its request id. Absent for a spawn. */
  send?: { whenBusy: "steer" | "followUp"; requestId: string };
};
type ReporterState =
  | { phase: "deliver" }
  | {
      phase: "report";
      report?: string;
      /** Length of the report's model-only header. */
      textOffset?: number;
      /** Follow the child afterwards, for its answers after this entry; absent: end. */
      after?: EntryId;
      /** The child's answer this report carries; its request id is `reportRequestId`. */
      answer?: EntryId;
    }
  | { phase: "follow"; after: EntryId };

/** Model-only header of a finished child's report; the transcript shows the text after it. */
function reportHeader(name: string, sessionId: string): string {
  return `[session ${name} (${sessionId}) finished, no reply needed] `;
}

/**
 * The request id of the report of `child`'s answer `answer` in its parent: one per answer,
 * whichever reporter posts it, so `wait` can withdraw a report of the answer it returns.
 */
function reportRequestId(child: ConversationId, answer: EntryId): string {
  return `oppi-report:${child}:${answer}`;
}

function textOf(message: AssistantMessage | undefined): string {
  return (message?.content ?? [])
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join("");
}

/** A conversation's newest entry; 0 before its first. */
async function newestEntry(tx: Tx, conversationId: ConversationId): Promise<EntryId> {
  return (await tx.scanEntries({ conversationId }, 1)).items[0]?.id ?? (0 as EntryId);
}

/**
 * A conversation's newest final answer: its newest assistant entry, unless that one calls tools
 * (a run in progress) or failed.
 */
async function newestAnswer(
  tx: Tx,
  conversationId: ConversationId,
): Promise<{ id: EntryId; message: AssistantMessage } | undefined> {
  let cursor;
  do {
    const page = await tx.scanEntries({ conversationId }, 50, cursor);
    for (const entry of page.items) {
      const message = entry.model?.[0];
      if (message?.role !== "assistant") continue;
      const { stopReason } = message as AssistantMessage;
      if (stopReason === "toolUse" || stopReason === "error" || stopReason === "aborted")
        return undefined;
      return { id: entry.id, message: message as AssistantMessage };
    }
    cursor = page.next;
  } while (cursor);
  return undefined;
}

/** What `followChild` uses of a task runtime or a tool call. */
type Follower = {
  watchDoc(
    token: typeof LiveDoc,
    conversationId: ConversationId,
    context: Context,
  ): Promise<DocumentWatch<LiveState> | undefined>;
  commit(change: (tx: Tx) => Promise<undefined>, context: Context): Promise<unknown>;
  waitForTask(id: TaskId, context: Context): Promise<unknown>;
};

/**
 * Follows child `conversationId` round by round until it is idle with no pending wakers (its
 * background jobs not yet delivered, its own reporters), or with none `decide` waits for. Each
 * round waits for the child to be idle (`idle`, whose error ends the follow and is returned), marks its
 * newest entry, reads its pending wakers, and calls `decide`, which runs its own commit and
 * calls `check` in it: "again" when the child runs or committed since the mark (a run that
 * started a job or answered, so the wakers read may be stale), else the wakers still live.
 * `decide` returns "again" to go round, no wakers to end, or the wakers to wait for: the round
 * then waits until one of them ends (its receipt may wake the child) or the child's `pi.live`
 * changes, and goes round. Each waker is waited on once, however many rounds. Rejects with
 * `signal`'s reason once it aborts.
 */
async function followChild(
  follower: Follower,
  conversationId: ConversationId,
  io: {
    idle: () => Promise<string | undefined>;
    wakers: () => Promise<TaskId[]>;
    decide: (check: (tx: Tx) => Promise<"again" | TaskId[]>) => Promise<"again" | TaskId[]>;
    signal: AbortSignal | undefined;
  },
  context: Context,
): Promise<string | undefined> {
  const { signal } = io;
  // `pi.live` exists once the child's first run started; a commit must not create it.
  let live = await follower.watchDoc(LiveDoc, conversationId, context);
  /** The child's `pi.live` changed or a waker ended since the round began. */
  let changed = false;
  let wake: (() => void) | undefined;
  const poke = (): void => {
    changed = true;
    wake?.();
  };
  const listen = (): void => live?.start(async () => poke());
  listen();
  /** Wakers already waited on: one waiter each, however many rounds. */
  const watched = new Set<TaskId>();
  // The waiters end with the follow, not with the task or call that follows.
  const waiters = withCancel(context);
  try {
    for (;;) {
      const error = await io.idle();
      if (error !== undefined) return error;
      signal?.throwIfAborted();
      changed = false;
      if (!live) {
        live = await follower.watchDoc(LiveDoc, conversationId, context);
        listen();
      }
      // Any child commit after this mark (a run that starts a job, or answers) means the
      // wakers read next may be stale: decide again.
      let mark: EntryId | undefined;
      await follower.commit(async (tx) => {
        mark = await newestEntry(tx, conversationId);
        return undefined;
      }, context);
      const wakers = await io.wakers();
      const pending = await io.decide(async (tx) => {
        const busy =
          live !== undefined && (await tx.doc(LiveDoc, conversationId)).run !== undefined;
        if (busy || (await newestEntry(tx, conversationId)) !== mark) return "again";
        return liveTasks(tx, wakers);
      });
      if (pending !== "again" && pending.length === 0) return undefined;
      if (pending === "again" || changed) continue;
      // Until a waker ends (its receipt may wake the child) or the child starts a run.
      for (const id of pending)
        if (!watched.has(id)) {
          watched.add(id);
          follower.waitForTask(id, waiters.context).then(poke, poke);
        }
      await new Promise<void>((resolve, reject) => {
        const cleanup = (): void => {
          signal?.removeEventListener("abort", abort);
          wake = undefined;
        };
        const finish = (): void => {
          cleanup();
          resolve();
        };
        const abort = (): void => {
          cleanup();
          reject(signal?.reason);
        };
        wake = finish;
        signal?.addEventListener("abort", abort, { once: true });
        if (signal?.aborted) abort();
        else if (changed) finish();
      });
    }
  } finally {
    waiters.cancel();
    await live?.stop();
  }
}

/** A background job of a child whose command still runs. */
type RunningJob = { id: string; command: string };

/**
 * The jobs behind `wakers`, a child's live pending wakers, when every one is a background job of
 * its own whose command still runs; else undefined. Such a job may never end (a dev server, a
 * watcher), so `wait` returns the child's answer rather than wait for it. A reporter of the
 * child (a subagent of its own) and a finished job whose receipt is not delivered yet each wake
 * the child soon to answer again, so `wait` keeps following those.
 */
async function runningJobsOnly(
  tx: Tx,
  conversationId: ConversationId,
  wakers: readonly TaskId[],
): Promise<RunningJob[] | undefined> {
  // Reporters first: a child without jobs has no jobs document, and a read must not create it.
  for (const id of wakers) if ((await tx.task(id))?.kind === SESSION_REPORTER_TASK) return;
  const jobs = (await tx.doc(DurableJobs, conversationId)).jobs;
  const running: RunningJob[] = [];
  for (const id of wakers) {
    const job = jobs.find((candidate) => candidate.taskId === id);
    if (job?.status !== "running") return undefined;
    running.push({ id: job.id, command: job.command });
  }
  return running;
}

/** What `wait` and `spawn` with `wait: true` add to the answer of a child whose jobs still run. */
function stillRunning(name: string, jobs: readonly RunningJob[], followed: boolean): string {
  const named = jobs
    .map(({ id, command }) => {
      const line = command.trimStart().split("\n", 1)[0]?.trimEnd() ?? "";
      return `job ${id} \`${line.length > 80 ? `${line.slice(0, 79)}…` : line}\``;
    })
    .join(", ");
  return (
    `[still running: ${named}. ${name} keeps running and answers again when its job ` +
    (followed
      ? "ends; that answer arrives as a follow-up message, so do not poll.]"
      : "ends, but that answer does not arrive on its own. wait returns at once while the job " +
        `runs, so wait again only after the job should have ended, or message ${name}.]`)
  );
}

/**
 * The answer `wait` or `spawn` returns for a child: its newest `latest`, with `note` when that is
 * still the answer the note was made for. A newer answer came after the child's turn on its job
 * (the job ended), so the note would be wrong.
 */
function answerWithNote(
  latest: { id: EntryId; text: string } | undefined,
  note: { text: string; answer: EntryId | undefined } | undefined,
): string {
  const text = latest?.text ?? "(no answer yet)";
  return note !== undefined && latest?.id === note.answer ? `${text}\n\n${note.text}` : text;
}

const COMPLETED = { status: "terminal", outcome: { status: "completed", result: null } } as const;

const SUBAGENT_TOOL = "subagent";

/**
 * What a `readOnly` child reads before its task. `bash` is not a sandbox: a command can still
 * write, so the line says so instead of promising more than the tools do.
 */
const READ_ONLY_PREFIX =
  "[Read-only subagent: you have `read` and `bash` only. `bash` is not a sandbox, so a command " +
  "can still change files: do not edit, commit, or run anything that writes.]";

/** `spawn`'s `worktree`: `"new"`, a branch request, or an existing worktree's id. */
function worktreeRequest(
  value: string | { branch: string; base?: string } | undefined,
): SubagentWorktreeRequest | undefined {
  if (value === undefined) return undefined;
  if (value === "new") return "new";
  if (typeof value === "string") return { id: value.trim() };
  return { branch: value.branch.trim(), ...(value.base ? { base: value.base } : {}) };
}

/** The one line a child with a worktree adds to `list` and to its answers. */
async function worktreeLine(
  sessions: DurableSessionsHost,
  worktree: SubagentWorktree | undefined,
): Promise<string | undefined> {
  if (!worktree) return undefined;
  const state = await sessions.worktreeState(worktree);
  return state === undefined ? undefined : `worktree: ${state}`;
}

/**
 * The submission a reporter makes of its message. `wait` submits the same draft to wait for a
 * message not delivered yet; the request id makes both one submission.
 */
function messageDraft(
  reporter: TaskId,
  input: ReporterInput,
): InputSubmissionDraft & { requestId: string } {
  const { task, parent, send } = input;
  return send
    ? {
        type: "input",
        content: task,
        whenBusy: send.whenBusy,
        requestId: send.requestId,
        ...sentBy(parent, "message"),
      }
    : {
        type: "input",
        content: task,
        requestId: `oppi-spawn:${reporter}`,
        ...sentBy(parent, "task"),
      };
}

/**
 * Never resolves: rejects with `signal`'s reason once the server's shutdown aborts the running
 * task, so the task stays pending and runs again after the restart.
 */
function aborted(signal: AbortSignal | undefined): Promise<never> {
  return new Promise((_, reject) => {
    if (!signal) reject(new Error("The server is stopping"));
    else if (signal.aborted) reject(signal.reason);
    else signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
}

/** The live (pending or running) reporters of `parent` for its child `child`. */
async function liveReporters(
  tx: Tx,
  parent: ConversationId,
  child: ConversationId,
): Promise<Array<TaskRecord<JsonValue, JsonValue, JsonValue>>> {
  const found: Array<TaskRecord<JsonValue, JsonValue, JsonValue>> = [];
  for (const status of ["pending", "running"] as const) {
    let cursor;
    do {
      const page = await tx.scanTasks(
        { conversationId: parent, kind: SESSION_REPORTER_TASK, status },
        50,
        cursor,
      );
      for (const task of page.items)
        if ((task.input as ReporterInput).conversationId === child) found.push(task);
      cursor = page.next;
    } while (cursor);
  }
  return found;
}

/** The calling conversation's live reporters for `child` that have not delivered their message. */
async function undelivered(
  api: ToolExecutionApi,
  child: ConversationId,
  context: Context,
): Promise<Array<{ id: TaskId; input: ReporterInput }>> {
  return api.commit(
    async (tx) =>
      (await liveReporters(tx, api.conversationId, child)).flatMap((task) => {
        const phase = (task.state.checkpoint as { phase?: string } | undefined)?.phase;
        // A reporter Stop aborted must not have its message delivered after all.
        return phase === "deliver" && !task.abortRequested
          ? [{ id: task.id, input: task.input as ReporterInput }]
          : [];
      }),
    context,
  );
}

/**
 * Delivers one message to a background child (a spawn's task or a `send`) and posts the answer
 * back to the parent as a follow-up (pi-durable example 23). Background too, so the parent's
 * Stop and idle waits leave it alone. Request ids make a restart deliver the message once and
 * each report once; the registry's `reported` list makes several messages that end in one
 * answer report it once.
 *
 * Then it follows the child, so answers no parent message caused still come back: a child that
 * ends its turn waiting on a background job of its own answers again when the job's receipt
 * wakes it. While the child has pending wakers (`pendingWakers`: undelivered jobs, its own
 * reporters; never tickers, which do not end), the reporter waits for one to end or for the
 * child to run, then reports the child's newest unreported answer. One reporter per child
 * follows (`follower`); it ends once the child is idle with no pending wakers, so it never keeps
 * the store open longer than the child's own work does.
 */
function defineReporter(
  host: (env: ExecutionEnv | undefined) => DurableSessionsHost,
): Task<ReporterInput, ReporterState, null, object> {
  return defineTask<ReporterInput, ReporterState, null>({
    name: SESSION_REPORTER_TASK,
    version: 1,
    initial: () => ({ phase: "deliver" }),
    phases: {
      deliver: async (reporter, runtime, context) => {
        const { conversationId, sessionId, name } = reporter.input;
        const child = await runtime.conversation(conversationId, context);
        if (!child) throw new Error(`Subagent ${name} (${sessionId}) conversation disappeared`);
        const draft = messageDraft(reporter.id, reporter.input);
        // A child stops once it settles with nothing pending: attach it while the message lands.
        // A rerun whose message the child already settled has no work to attach it for.
        let settledBefore = false;
        await runtime.commit(async (tx) => {
          const known = await tx.submissionByRequest(conversationId, draft.requestId);
          settledBefore = known?.status === "done" || known?.status === "unanswered";
          return undefined;
        }, context);
        const delivered = settledBefore
          ? { submitted: await child.submit(draft, context) }
          : await host(await runtime.env(context)).activate(sessionId, () =>
              child.submit(draft, context),
            );
        if ("failed" in delivered) {
          // A stopping server cut this off: rerun after the restart instead of reporting.
          if (delivered.shuttingDown) await aborted(runtime.signal);
          // The message never reached the child; the parent hears why, and this reporter ends.
          await runtime.commit(
            () => ({
              status: "running",
              checkpoint: {
                phase: "report",
                report: `[session ${name} (${sessionId}) failed: could not start: ${delivered.failed}]`,
              },
            }),
            context,
          );
          return;
        }
        const settled = await delivered.submitted.wait(context);
        // Read outside the commit: where a worktree child's tree stands is git work, not a
        // document read, and the Session line must not wait on it.
        const state = await worktreeLine(
          host(await runtime.env(context)),
          (await runtime.snapshot(Subagents, runtime.conversationId, context))?.children[name]
            ?.worktree,
        );
        // One commit decides the report and records the answer, so a restart does not decide again.
        await runtime.commit(async (tx) => {
          const next = (after: EntryId, report?: string, textOffset?: number, answer?: EntryId) =>
            ({
              status: "running",
              checkpoint: {
                phase: "report",
                after,
                ...(report !== undefined ? { report } : {}),
                ...(textOffset ? { textOffset } : {}),
                ...(answer !== undefined ? { answer } : {}),
              },
            }) as const;
          // Aborted: stopped or withdrawn. Whoever stopped it knows; nothing to report.
          if (settled.status === "unanswered")
            return next(
              await newestEntry(tx, conversationId),
              settled.reason === "aborted"
                ? undefined
                : `[session ${name} (${sessionId}) failed: ${settled.reason}]`,
            );
          if (settled.type !== "input") return next(await newestEntry(tx, conversationId));
          const record = (await tx.doc(Subagents, runtime.conversationId)).children[name];
          if (record) {
            // Read back from the draft: `??=` yields the plain value, not the stored draft.
            record.reported ??= [];
            if (record.reported.includes(settled.answer)) return next(settled.answer);
            record.reported.push(settled.answer);
          }
          const answer = (await tx.entry(AssistantEntry, settled.answer))?.model?.[0] as
            AssistantMessage | undefined;
          const header = reportHeader(name, sessionId);
          const report = `${header}${textOf(answer)}${state ? `\n\n[${state}]` : ""}`;
          return next(settled.answer, report, header.length, settled.answer);
        }, context);
      },
      report: async (reporter, runtime, context) => {
        const { report, textOffset: saved, after, answer } = reporter.state.checkpoint;
        const { sessionId, name } = reporter.input;
        // A report checkpointed before agent messages has no offset; its header is the same text.
        const header = reportHeader(name, sessionId);
        const textOffset = saved ?? (report?.startsWith(header) ? header.length : undefined);
        if (report !== undefined) {
          const parent = await runtime.conversation(runtime.conversationId, context);
          if (!parent) throw new Error("Parent conversation disappeared");
          // A follow-up starts a turn when the parent is idle, or waits for its answer.
          await parent.submit(
            {
              type: "input",
              content: report,
              whenBusy: "followUp",
              // An answer's report is named by the answer; a failure by this reporter.
              requestId:
                answer === undefined
                  ? `oppi-report:${reporter.id}`
                  : reportRequestId(reporter.input.conversationId, answer),
              ...sentBy({ sessionId, name }, "report", textOffset),
            },
            context,
          );
        }
        await runtime.commit(
          () =>
            after === undefined
              ? COMPLETED
              : { status: "running", checkpoint: { phase: "follow", after } },
          context,
        );
      },
      follow: async (reporter, runtime, context) => {
        const { conversationId, sessionId, name } = reporter.input;
        const { after } = reporter.state.checkpoint;
        const sessions = host(await runtime.env(context));
        const child = await runtime.conversation(conversationId, context);
        if (!child) throw new Error(`Subagent ${name} (${sessionId}) conversation disappeared`);
        await followChild(
          runtime,
          conversationId,
          {
            idle: async () => {
              await child.waitForIdle(context);
              return undefined;
            },
            wakers: () => sessions.pendingWakers(conversationId),
            // Ends (no wakers) once this commit reports the child's newest answer or ends the
            // reporter.
            decide: async (check) => {
              let pending = [] as "again" | TaskId[];
              const state = await worktreeLine(
                sessions,
                (await runtime.snapshot(Subagents, runtime.conversationId, context))?.children[name]
                  ?.worktree,
              );
              await runtime.commit(async (tx) => {
                pending = [];
                const record = (await tx.doc(Subagents, runtime.conversationId)).children[name];
                if (!record) return COMPLETED;
                if (record.follower !== reporter.id) {
                  // Another reporter already follows this child.
                  if (record.follower !== undefined && isLive(await tx.task(record.follower)))
                    return COMPLETED;
                  record.follower = reporter.id;
                }
                const live = await check(tx);
                if (live === "again") {
                  pending = "again";
                  return undefined;
                }
                const answer = await newestAnswer(tx, conversationId);
                record.reported ??= [];
                if (answer && answer.id > after && !record.reported.includes(answer.id)) {
                  record.reported.push(answer.id);
                  const header = reportHeader(name, sessionId);
                  const report = `${header}${textOf(answer.message)}${state ? `\n\n[${state}]` : ""}`;
                  return {
                    status: "running",
                    checkpoint: {
                      phase: "report",
                      report,
                      textOffset: header.length,
                      after: answer.id,
                      answer: answer.id,
                    },
                  };
                }
                if (live.length === 0) return COMPLETED;
                pending = live;
                return undefined;
              }, context);
              return pending;
            },
            signal: runtime.signal,
          },
          context,
        );
      },
    },
    abort: (_reporter, runtime, context) =>
      runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
  });
}

const GUIDANCE =
  "subagent manages child sessions you address by name. spawn starts one for a self-contained " +
  "task; by default it runs in the background and its answer arrives later as a follow-up " +
  "message, so do not poll. wait: true makes spawn return the answer instead, once the child " +
  "has no background work of its own pending other than jobs still running. agent picks a " +
  "saved Agent; model and thinking override it. send messages a child (steer by default, " +
  "followUp: true after its current answer); its answer also arrives later as a follow-up " +
  "message, as does any later answer of a child that finishes background work of its own. " +
  "wait blocks until children answered your messages and are idle with no background work of " +
  "their own pending, and returns their latest answers instead; an answer wait returns does " +
  "not also arrive as a follow-up. A child idle with only background jobs of its own still " +
  "running (a dev server, a watcher) does not hold wait or spawn: its answer comes back with a " +
  "note naming those jobs, and it answers again when one ends. stop aborts " +
  "a child's current work (it stays usable), list shows them. A child can spawn its own " +
  "children only when you pass allowNestedDelegation. worktree gives a child a checkout of its " +
  "own, branched from your HEAD or an existing worktree id, so editing workers never touch your " +
  "files; their answers and list rows add the worktree's branch, commits ahead of its base, and " +
  "whether it is dirty; one the spawn made stays until it lands, and spawn never removes it, " +
  "landing or Oppi's daily cleanup does. tools, excludeTools, and readOnly only narrow a " +
  "child's tools.";

type ReplyDetails = Record<string, JsonValue>;

function reply(
  text: string,
  details: ReplyDetails,
  isError = false,
): ToolExecutionResult<ReplyDetails> {
  return { output: [{ type: "text" as const, text }], details, ...(isError ? { isError } : {}) };
}

/**
 * The `oppi.sessions` extension over `host`, which finds Oppi's subagent host for a tool call's
 * execution env. The package's entry binds it to `oppiHost()`; tests bind their own.
 */
export function createDurableSessions(
  host: (env: ExecutionEnv | undefined) => DurableSessionsHost | undefined,
): Extension {
  const bound = (env: ExecutionEnv | undefined): DurableSessionsHost => {
    const current = host(env);
    if (!current) throw new Error("subagent is not available: the Oppi host is not bound");
    return current;
  };
  const children = async (
    api: ToolExecutionApi,
    context: Context,
  ): Promise<Readonly<Record<string, Child>>> =>
    (await api.snapshot(Subagents, api.conversationId, context))?.children ?? {};
  /** The child's Session; bound again when a crash came between the spawn commit and the bind. */
  const sessionIdOf = (api: ToolExecutionApi, name: string, child: Child): Promise<string> =>
    child.sessionId !== undefined
      ? Promise.resolve(child.sessionId)
      : bound(api.env).materialize({ conversationId: child.conversationId, name });
  const Reporter = defineReporter(bound);
  /**
   * Waits until child `name` (`conversationId`) of the caller is idle with no background work
   * of its own pending: idle alone may be an interim answer ("still waiting on the job"), and the
   * waker's receipt wakes it to answer again. Its `error` when it failed. Idle with only jobs of
   * its own still running is enough, as such a job may never end: then `note` names them, for
   * the child's newest answer then (`note.answer`). The call's abort (the parent's Stop) ends
   * the wait.
   */
  const finished = async (
    api: ToolExecutionApi,
    sessions: DurableSessionsHost,
    {
      name,
      conversationId,
      sessionId,
    }: { name: string; conversationId: ConversationId; sessionId: string },
    context: Context,
  ): Promise<{ error?: string; note?: { text: string; answer: EntryId | undefined } }> => {
    let note: { text: string; answer: EntryId | undefined } | undefined;
    const error = await followChild(
      api,
      conversationId,
      {
        idle: () => sessions.waitForIdle(sessionId, context.abortSignal),
        wakers: () => sessions.pendingWakers(conversationId),
        decide: (check) =>
          api.commit(async (tx) => {
            note = undefined;
            const live = await check(tx);
            if (live === "again" || live.length === 0) return live;
            const jobs = await runningJobsOnly(tx, conversationId, live);
            if (!jobs) return live;
            // A reporter that follows the child reports its next answer to the caller. One that
            // only reports a failure to start (`report` without `after`) ends after it.
            const followed = (await liveReporters(tx, api.conversationId, conversationId)).some(
              (task) => {
                const checkpoint = task.state.checkpoint as { phase?: string; after?: EntryId };
                return (
                  !task.abortRequested &&
                  (checkpoint.phase === "deliver" ||
                    checkpoint.phase === "follow" ||
                    (checkpoint.phase === "report" && checkpoint.after !== undefined))
                );
              },
            );
            note = {
              text: stillRunning(name, jobs, followed),
              answer: (await latestText(tx, conversationId))?.id,
            };
            return [];
          }, context),
        signal: context.abortSignal,
      },
      context,
    );
    return error !== undefined ? { error } : note !== undefined ? { note } : {};
  };
  const background = { ownership: { kind: "conversation" }, background: true } as const;

  const subagent = defineTool({
    name: SUBAGENT_TOOL,
    description:
      "Manage child sessions by name. spawn (name, task; optional agent, model, thinking, wait, " +
      "allowNestedDelegation, worktree, tools, excludeTools, readOnly) starts one: in the " +
      "background by default, its answer arrives later as a follow-up message; wait: true " +
      "returns its final answer instead, once it has no background work of its own pending. " +
      'worktree runs the child in a checkout of its own: "new" for a branch named after it, a ' +
      "{ branch } to create or adopt that branch, or an existing worktree id to adopt; work " +
      "that may land should use worktree, so the parent's checkout stays untouched. Those " +
      "children's answers and list rows also report their worktree, commits ahead and whether " +
      "they are dirty. spawn never removes the worktree it made; landing or the daily cleanup " +
      "does. " +
      "Tools narrow only: tools and readOnly name an exact set (readOnly keeps read and bash, " +
      "and bash is not a sandbox), while excludeTools only removes the tools it names. " +
      "send (name, message; " +
      "followUp: true queues after its current answer instead of steering) messages one; its " +
      "answer arrives later as a follow-up message too, as do a child's later answers after " +
      "background work of its own. wait (names) blocks until they answered your messages and " +
      "are idle with no background work of their own pending, and returns their latest " +
      "answers. Neither waits for a child's own background jobs that still run once it is " +
      "idle: its answer then ends with a note naming them. stop (name) aborts its current " +
      "work; it stays usable. list shows every child.",
    parameters: Type.Object({
      action: Type.Union([
        Type.Literal("spawn"),
        Type.Literal("send"),
        Type.Literal("wait"),
        Type.Literal("stop"),
        Type.Literal("list"),
      ]),
      name: Type.Optional(Type.String({ description: "The child, for spawn, send, and stop." })),
      names: Type.Optional(Type.Array(Type.String(), { description: "The children to wait for." })),
      task: Type.Optional(Type.String({ description: "spawn: what the child should do." })),
      message: Type.Optional(Type.String({ description: "send: the message." })),
      followUp: Type.Optional(
        Type.Boolean({ description: "send: queue after the child's current answer." }),
      ),
      agent: Type.Optional(Type.String({ description: "spawn: a saved Agent, by name or id." })),
      model: Type.Optional(
        Type.String({ description: "spawn: provider/model; default: the Agent's or yours." }),
      ),
      thinking: Type.Optional(
        Type.String({ description: "spawn: thinking level; default: the Agent's or yours." }),
      ),
      wait: Type.Optional(
        Type.Boolean({ description: "spawn: wait for the child's answer and return it." }),
      ),
      allowNestedDelegation: Type.Optional(
        Type.Boolean({ description: "spawn: let the child spawn children of its own." }),
      ),
      worktree: Type.Optional(
        Type.Union(
          [
            Type.Literal("new"),
            Type.String({ description: "An existing worktree id (wt_…), to adopt it." }),
            Type.Object({
              branch: Type.String(),
              base: Type.Optional(Type.String()),
            }),
          ],
          {
            description:
              'spawn: run the child in its own worktree. "new" branches from your HEAD with a ' +
              "branch named after the child; { branch } creates or adopts that branch, based on " +
              '`base` or your HEAD; a "wt_…" id adopts that worktree of this workspace. Use it ' +
              "for work that may land.",
          },
        ),
      ),
      tools: Type.Optional(
        Type.Array(Type.String(), {
          description: "spawn: only these tools; a child never gains one you lack.",
        }),
      ),
      excludeTools: Type.Optional(
        Type.Array(Type.String(), { description: "spawn: never these tools." }),
      ),
      readOnly: Type.Optional(
        Type.Boolean({
          description:
            "spawn: read and bash only, and the task says so. bash is not a sandbox: it can " +
            "still write.",
        }),
      ),
    }),
    // A rerun after a crash finds the same child, Session, and submissions; stop records its
    // decision before it aborts, so a rerun does not stop newer work.
    replay: "safe",
    async execute(args, api, context) {
      switch (args.action) {
        case "spawn":
          return spawn(args, api, context);
        case "send": {
          const name = args.name?.trim() ?? "";
          const child = (await children(api, context))[name];
          if (!child) return reply(`No subagent named ${name}.`, { name }, true);
          if (!args.message) return reply("send needs a message.", { name }, true);
          const sessions = bound(api.env);
          // Its reporter attaches the child when it delivers the message.
          const sessionId = await sessionIdOf(api, name, child);
          const whenBusy = args.followUp === true ? "followUp" : "steer";
          const requestId = `oppi-send:${sessions.storeId}:${api.conversationId}:${api.taskId}`;
          const parent = sessions.sender();
          const message = args.message;
          // A reporter delivers the message and reports its answer, keyed by this call so a
          // rerun creates no second one.
          await api.commit(async (tx) => {
            const state = await tx.doc(Subagents, api.conversationId);
            state.reporters ??= {};
            if (state.reporters[String(api.taskId)] !== undefined) return;
            state.reporters[String(api.taskId)] = await tx.createTask(
              Reporter,
              {
                conversationId: child.conversationId,
                sessionId,
                name,
                task: message,
                ...(parent ? { parent } : {}),
                send: { whenBusy, requestId },
              },
              background,
            );
          }, context);
          return reply(
            `Sent to ${name} (${whenBusy}). Its answer arrives later as a follow-up message; ` +
              "do not poll.",
            { name, conversationId: child.conversationId, sessionId, requestId },
          );
        }
        case "wait": {
          const names = args.names ?? (args.name ? [args.name] : []);
          if (names.length === 0) return reply("wait needs names.", {}, true);
          const known = await children(api, context);
          const found = names.flatMap((name) => {
            const child = known[name];
            return child ? [{ name, child }] : [];
          });
          const missing = names.filter((name) => !known[name]);
          if (missing.length)
            return reply(`No subagent named ${missing.join(", ")}.`, { missing }, true);
          const sessions = bound(api.env);
          // Earlier subagent calls of this round (a `send` in the same answer) take effect first.
          const round = (await api.snapshot(LiveDoc, api.conversationId, context))?.tools ?? [];
          for (const slot of round)
            if (
              slot.name === SUBAGENT_TOOL &&
              slot.taskId !== undefined &&
              slot.taskId < api.taskId &&
              slot.status !== "done"
            )
              await api.waitForTask(slot.taskId, context);
          const waited = await Promise.all(
            found.map(async ({ name, child }) => {
              const sessionId = await sessionIdOf(api, name, child);
              const ids = { name, conversationId: child.conversationId, sessionId };
              // A message whose reporter has not delivered it yet is not in the child, so the
              // child can look idle with the previous answer. Wait for its answer: submitting
              // the reporter's draft returns the reporter's submission (one request id).
              const conversation = await api.conversation(child.conversationId, context);
              if (!conversation)
                return { ids, name, error: `Subagent ${name} has no conversation.` };
              // The child is attached while they land, as their reporters attach it.
              for (const { id, input } of await undelivered(api, child.conversationId, context)) {
                const delivered = await sessions.activate(sessionId, () =>
                  conversation.submit(messageDraft(id, input), context),
                );
                if ("failed" in delivered) {
                  if (delivered.shuttingDown) await aborted(context.abortSignal);
                  return {
                    ids,
                    name,
                    error: `Subagent ${name} could not start: ${delivered.failed}`,
                  };
                }
                await delivered.submitted.wait(context);
              }
              return { ids, name, ...(await finished(api, sessions, ids, context)) };
            }),
          );
          // Only once every child is done: an answer taken (and its report withdrawn) is in
          // this call's result, so no abort or other child's error can lose it.
          const idle = waited.filter((result) => result.error === undefined);
          const answers = await takeLatestAnswers(
            api,
            idle.map(({ name, ids }) => ({ name, conversationId: ids.conversationId })),
            context,
          );
          const states = await Promise.all(
            waited.map((result) =>
              result.error === undefined
                ? worktreeLine(sessions, known[result.name]?.worktree)
                : undefined,
            ),
          );
          const lines = waited.map((result, index) => {
            const line =
              result.error === undefined
                ? `${result.name}: ${answerWithNote(answers[idle.indexOf(result)], result.note)}`
                : `${result.name}: ${result.error}`;
            const state = states[index];
            return state ? `${line}\n[${state}]` : line;
          });
          const failed = waited.some((result) => result.error !== undefined);
          return reply(lines.join("\n\n"), { children: waited.map((r) => r.ids) }, failed);
        }
        case "stop": {
          const name = args.name?.trim() ?? "";
          const child = (await children(api, context))[name];
          if (!child) return reply(`No subagent named ${name}.`, { name }, true);
          const details = {
            name,
            conversationId: child.conversationId,
            ...(child.sessionId ? { sessionId: child.sessionId } : {}),
          };
          const conversation = await api.conversation(child.conversationId, context);
          if (!conversation) return reply(`Subagent ${name} has no conversation.`, details, true);
          // The commit that stores this call's token decides to abort; a rerun finds an earlier
          // decision and skips the abort, which may already have reached newer work.
          const decision = randomUUID();
          if ((await api.memo<JsonValue>("stopped", decision, context)) === decision)
            await conversation.abort(context);
          return reply(`Stopped ${name}.`, details);
        }
        case "list": {
          const known = Object.entries(await children(api, context));
          if (known.length === 0) return reply("No subagents.", { children: [] });
          const sessions = bound(api.env);
          const rows = await Promise.all(
            known.map(async ([name, child]) => {
              const busy =
                (await api.snapshot(LiveDoc, child.conversationId, context))?.run !== undefined;
              const wakers = busy ? [] : await sessions.pendingWakers(child.conversationId);
              const waiting = (
                await Promise.all(wakers.map((id) => api.getTask(id, context)))
              ).some(isLive);
              const model = (await api.snapshot(AgentDoc, child.conversationId, context))?.model;
              const worktree = await worktreeLine(sessions, child.worktree);
              return {
                line: [
                  name,
                  busy ? "working" : waiting ? "waiting on background work" : "idle",
                  `agent: ${child.agent ?? "none"}`,
                  `model: ${model ? `${model.provider}/${model.modelId}` : "default"}`,
                  `session: ${child.sessionId ?? "pending"}`,
                  ...(worktree ? [worktree] : []),
                ].join(" | "),
                ids: {
                  name,
                  conversationId: child.conversationId,
                  ...(child.sessionId !== undefined ? { sessionId: child.sessionId } : {}),
                },
              };
            }),
          );
          return reply(rows.map((row) => row.line).join("\n"), {
            children: rows.map((row) => row.ids),
          });
        }
      }
    },
  });

  async function spawn(
    args: {
      name?: string;
      task?: string;
      agent?: string;
      model?: string;
      thinking?: string;
      wait?: boolean;
      allowNestedDelegation?: boolean;
      worktree?: string | { branch: string; base?: string };
      tools?: string[];
      excludeTools?: string[];
      readOnly?: boolean;
    },
    api: ToolExecutionApi,
    context: Context,
  ): Promise<ToolExecutionResult<ReplyDetails>> {
    const sessions = bound(api.env);
    const name = args.name?.trim();
    const task = args.task?.trim();
    if (!name) return reply("spawn needs a name.", {}, true);
    if (!task) return reply("spawn needs a task.", { name }, true);
    const request = worktreeRequest(args.worktree);
    if (typeof args.worktree === "string" && args.worktree.trim() === "")
      return reply(`worktree needs "new", a branch, or a worktree id.`, { name }, true);
    const call = String(api.taskId);
    const before = await api.snapshot(Subagents, api.conversationId, context);
    const rerun = before?.calls[call] === name;
    if (!rerun && before?.children[name])
      return reply(`${name} already exists; use send.`, { name }, true);
    const foreground = args.wait === true;
    const prompt = args.readOnly === true ? `${READ_ONLY_PREFIX}\n\n${task}` : task;
    // A rerun finds its child below; only a new spawn resolves the Agent.
    const resolved = rerun
      ? undefined
      : await sessions.resolveAgent(
          {
            ...(args.agent ? { agent: args.agent } : {}),
            ...(args.model ? { model: args.model } : {}),
            ...(args.thinking ? { thinking: args.thinking } : {}),
            ...(args.allowNestedDelegation ? { allowNestedDelegation: true } : {}),
            ...(args.tools ? { tools: args.tools } : {}),
            ...(args.excludeTools ? { excludeTools: args.excludeTools } : {}),
            ...(args.readOnly ? { readOnly: true } : {}),
          },
          await api.agent(context),
        );
    // The child's own checkout: planned and checked first, then provisioned. A rerun's child
    // already has the worktree its first run bound (or none): it is read from the record, never
    // provisioned again. A `"new"` spawn never adopts a worktree, so a rerun after a crash
    // before the child commit takes the next free branch; the orphaned untouched checkout is
    // clean and merged, and the daily safe cleanup removes it.
    const earlier = rerun ? before?.children[name] : undefined;
    let worktree: SubagentWorktree | undefined = earlier?.worktree;
    if (earlier === undefined && request !== undefined) {
      const plan = await sessions.planWorktree(request, name, call);
      worktree = await sessions.provisionWorktree(plan, { call, adopt: request !== "new" });
    }
    const conversationId = await api.commit(async (tx) => {
      const state = await tx.doc(Subagents, api.conversationId);
      const existing = state.calls[call];
      const earlier = existing === undefined ? undefined : state.children[existing];
      if (earlier) return earlier.conversationId;
      if (!resolved) throw new Error(`Subagent ${name} spawn record disappeared`);
      if (Object.hasOwn(state.children, name)) throw new Error(`${name} already exists; use send.`);
      // First: it reads the task table, which a commit cannot do after a table write.
      await ensureSubagentWidget(tx, api.conversationId, SubagentWidget);
      // Foreground: the child belongs to this call, so aborting the call aborts it and the
      // parent stays busy until it is idle. Background: an anchor owns it.
      const owner = foreground
        ? api.taskId
        : await tx.createTask(Anchor, null, {
            ownership: { kind: "conversation" },
            background: true,
          });
      const child = await tx.createConversation({ ownership: { kind: "task", taskId: owner } });
      await resolved.apply(tx, child.id, worktree);
      state.children[name] = {
        conversationId: child.id,
        background: !foreground,
        ...(resolved.agent ? { agent: resolved.agent } : {}),
        ...(resolved.icon ? { icon: resolved.icon } : {}),
        ...(worktree ? { worktree } : {}),
      };
      state.calls[call] = name;
      return child.id;
    }, context);
    const sessionId = await sessions.materialize({ conversationId, name });
    await api.commit(async (tx) => {
      const child = (await tx.doc(Subagents, api.conversationId)).children[name];
      if (child && child.sessionId === undefined) child.sessionId = sessionId;
    }, context);
    await api.details({ name, conversationId, sessionId }, context);
    const parent = sessions.sender();

    if (!foreground) {
      // The reporter is created after the Session is bound, so the child never runs unattached.
      await api.commit(async (tx) => {
        const child = (await tx.doc(Subagents, api.conversationId)).children[name];
        if (!child) throw new Error(`Subagent ${name} spawn record disappeared`);
        if (child.reporter !== undefined) return;
        child.reporter = await tx.createTask(
          Reporter,
          { conversationId, sessionId, name, task: prompt, ...(parent ? { parent } : {}) },
          background,
        );
      }, context);
      return reply(
        `Started ${name} (session ${sessionId}) in the background. Its answer arrives later as ` +
          "a follow-up message; do not poll.",
        { name, conversationId, sessionId, background: true },
      );
    }

    const child = await api.conversation(conversationId, context);
    if (!child) throw new Error(`Subagent ${name} (${sessionId}) conversation disappeared`);
    const delivered = await sessions.activate(sessionId, () =>
      child.submit(
        {
          type: "input",
          content: prompt,
          requestId: `oppi-spawn:${api.taskId}`,
          ...sentBy(parent, "task"),
        },
        context,
      ),
    );
    if ("failed" in delivered) {
      if (delivered.shuttingDown) await aborted(context.abortSignal);
      throw new Error(`Subagent ${name} (${sessionId}) could not start: ${delivered.failed}`);
    }
    const settled = await delivered.submitted.wait(context);
    if (settled.status !== "done" || settled.type !== "input")
      throw new Error(`Subagent ${name} (${sessionId}) did not answer: ${settled.status}`);
    // Its answer to the task may be interim, given while a job of its own runs: as `wait`.
    const { error, note } = await finished(
      api,
      sessions,
      { name, conversationId, sessionId },
      context,
    );
    if (error !== undefined) throw new Error(`Subagent ${name} (${sessionId}): ${error}`);
    const latest = await api.commit((tx) => latestText(tx, conversationId), context);
    const state = await worktreeLine(
      sessions,
      (await api.snapshot(Subagents, api.conversationId, context))?.children[name]?.worktree,
    );
    const answer = answerWithNote(latest, note);
    return reply(state ? `${answer}\n\n[${state}]` : answer, {
      name,
      conversationId,
      sessionId,
    });
  }

  return defineExtension({
    name: "oppi.sessions",
    tools: [subagent],
    tasks: [Anchor, Reporter, SubagentWidget],
    sections: [section("sessions", () => GUIDANCE)],
  });
}

/** A conversation's newest assistant message that has text: what `wait` returns. */
async function latestText(
  tx: Tx,
  conversationId: ConversationId,
): Promise<{ id: EntryId; text: string } | undefined> {
  let cursor;
  do {
    const page = await tx.scanEntries({ conversationId }, 50, cursor);
    for (const entry of page.items) {
      const message = entry.model?.[0];
      if (message?.role !== "assistant") continue;
      const text = textOf(message as AssistantMessage);
      if (text) return { id: entry.id, text };
    }
    cursor = page.next;
  } while (cursor);
  return undefined;
}

/** Whether a live reporter of `parent` decided to report `child`'s `answer` and has not yet. */
async function reportDecided(
  tx: Tx,
  parent: ConversationId,
  child: ConversationId,
  answer: EntryId,
): Promise<boolean> {
  return (await liveReporters(tx, parent, child)).some((task) => {
    const checkpoint = task.state.checkpoint as { phase?: string; answer?: EntryId };
    return checkpoint.phase === "report" && checkpoint.answer === answer;
  });
}

/**
 * The newest answers of the idle `children`, which `wait` returns, taken in one commit just
 * before it returns: each is recorded as reported, so no reporter decides to post it afterwards,
 * and the report of a reporter that already decided is withdrawn. While `wait` runs the parent is
 * busy, so a submitted report is still queued: it is settled `withdrawn` and leaves the inbox, as
 * `Harness.abortSubmission` does. A report not submitted yet has its request id taken by a record
 * already settled `withdrawn`, so the reporter's submit returns that one. The parent reads each
 * answer once: as the `wait` result, or as the report when `wait` ends before this commit.
 */
async function takeLatestAnswers(
  api: ToolExecutionApi,
  children: Array<{ name: string; conversationId: ConversationId }>,
  context: Context,
): Promise<Array<{ id: EntryId; text: string } | undefined>> {
  return api.commit(async (tx) => {
    // pi-durable refuses a table read after a table write in one commit: read everything first.
    const state = await tx.doc(Subagents, api.conversationId);
    const plans = [];
    for (const { name, conversationId } of children) {
      const latest = await latestText(tx, conversationId);
      const record = state.children[name];
      if (!latest || !record) {
        plans.push({ latest, record });
        continue;
      }
      const requestId = reportRequestId(conversationId, latest.id);
      const recorded = record.reported?.includes(latest.id) === true;
      const report = recorded
        ? await tx.submissionByRequest(api.conversationId, requestId)
        : undefined;
      // Recorded by an earlier `wait` and no reporter decided it: nothing to withdraw.
      const decided =
        recorded &&
        report === undefined &&
        (await reportDecided(tx, api.conversationId, conversationId, latest.id));
      plans.push({ latest, record, recorded, requestId, report, decided });
    }
    const taken: Array<{ id: EntryId; text: string } | undefined> = [];
    for (const { latest, record, recorded, requestId, report, decided } of plans) {
      taken.push(latest);
      if (!latest || !record) continue;
      if (!recorded) {
        record.reported ??= [];
        if (!record.reported.includes(latest.id)) record.reported.push(latest.id);
      }
      if (report?.status === "queued") {
        tx.settleSubmission(report.id, { status: "unanswered", reason: "withdrawn" });
        const items = (await tx.doc(InboxDoc, api.conversationId)).items;
        const index = items.findIndex((item) => item.id === report.id);
        if (index >= 0) items.splice(index, 1);
      } else if (decided && requestId !== undefined)
        await tx.createSubmission({
          conversationId: api.conversationId,
          requestId,
          type: "input",
          status: "unanswered",
          reason: "withdrawn",
        });
    }
    return taken;
  }, context);
}

/** The durable entry (`package.json` `oppi.durable`): `subagent` over the server's threads. */
export default createDurableSessions((env) => oppiHost().sessions(env));

import type { Context } from "@earendil-works/chord/context";
import { withCancel } from "@earendil-works/chord/context";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  AgentDoc,
  LiveDoc,
  UsageDoc,
  defineTask,
  type ConversationId,
  type DocumentWatch,
  type EntryId,
  type LiveState,
  type RunFailure,
  type TaskId,
  type Tx,
} from "@earendil-works/pi-durable";
import {
  DurableSessionDoc,
  DurableUI,
  SESSION_REPORTER_TASK,
  oppiHost,
  wakingTasks,
  type UIState,
} from "oppi/v1";
import type { UsageState } from "@earendil-works/pi-durable";
import { SUBAGENT_WIDGET_TASK, SubagentPill, Subagents, type Child } from "./contract.js";
import { DurableJobs } from "../background-jobs/contract.js";
import { panel, subagentView } from "./panel.js";
import { liveTasks, wakingReporters } from "./wakers.js";
import {
  ANSWER_EXCERPT_MAX,
  EARLIER_EXCERPT_MAX,
  cutMarkdown,
  sessionLink,
  titledWithAgent,
  type Subagent,
} from "./subagents.js";

// The durable form of the reference `subagents` extension's pill: the same rows, built by the same
// helpers, drawn by the composable surface in `panel.ts`. This task follows the children and writes
// what it read to `oppi.subagents.pill`, then publishes the panel from that document; the owner's
// dismissals are the panel's own document, so a tap and this watch never write the same one. Rows
// link to `oppi://session/<id>`, which the app already opens; when the surface limits leave children
// without a row, a last row links to `oppi://thread/<this session>`, the whole thread.
//
// The pill shows while a child needs you or works; its subtitle counts those, and the rows are
// every child: those that need you (a dialog, or a failure not stopped since), the working ones, the
// newest finished ones under Recent, and the rest under Earlier. A row discloses the child's answer,
// kept from the same read as its first line.
// So every child's state is followed, not only the shown ones: a child that was done and starts
// again, or opens a dialog, takes a row at once. Each child's `pi.live` (busy, its current
// activity, and why its newest run failed) and `oppi.extension-ui` (an open dialog, and when the
// owner last stopped it) are watched in process; a write happens only when the pill changes. The
// model and the answer's first line (or its error) come from the child's newest assistant entry,
// read when the child is first seen and when a run ends; its spend comes from `pi.usage` at the
// same times, and a run's start and end from the busy edges this watch sees (or, for a run it did
// not see, the newest user message and the answer). A failed child stays under Needs You until it
// runs again (it was messaged) or the owner stops it after the failure (`stoppedAt`). A change of
// activity alone is written at most every `ACTIVITY_INTERVAL_MS`, and only while the child has a
// row: streamed text changes it with every partial.
//
// An idle child is not done while background work of its own (its pending wakers: undelivered
// jobs, its own reporters) will wake it to answer again: its row stays Working. The wakers are
// read when the child is first seen, when a run ends, and when one of them ends; each live one
// has a waiter that marks the pass when it ends. No timer polls them. They are read from the
// child's documents and tasks by `wakingTasks`, the rule `pendingWakers` uses, and not through
// the subagent host: that needs the watcher's execution env, which a sandbox parent has only
// while its VM is attached. A commit cannot see which tasks the scheduler blocked, so a blocked
// waker (parked by the restart limit, or with no definition) keeps its row Working, where
// `pendingWakers` drops it; the work it stands for did not finish either.
//
// The watch never ends on its own, but its invocation does, every `WATCH_INVOCATION_MS`: pi-durable
// keeps the registry snapshot an invocation was reserved with until the invocation ends, and that
// snapshot holds every extension installed then, including those of sessions stopped since. The
// last pass commits a sleep that is already due, so the scheduler reserves the task again with the
// current registry. The checkpoint carries what each child's rows were derived from (`Carried`:
// whether it had run, its newest answer, its configured model, its pending wakers, and whether it
// was busy, and the id of its newest entry when read), so the new phase scans no answers and reads
// no job lists for a child whose `pi.live` still agrees on busy or idle with the checkpoint and
// whose newest entry is still that one (one entry read per child; busy or idle cannot tell that a
// child ran and ended in between): it only watches the child's two documents. A child that moved
// on since, or that had not run yet, is read as at first sight. The
// checkpoint is written when what it carries changes (a run ended and its answer was read), and
// at every invocation end. It holds about 400 bytes per child: an Earlier child's answer is
// carried cut to what its row shows (`EARLIER_EXCERPT_MAX`), and only the dozen or so live and
// Recent children carry up to `ANSWER_EXCERPT_MAX`. A pill of 500 children writes some 200 kB
// when a run ends.
//
// A child without `pi.live` or `oppi.extension-ui` (not started yet, or never asked anything) is
// looked for again with a backoff, from `DOCS_RETRY_MIN_MS` doubling to `DOCS_RETRY_MAX_MS`, not at
// every pass. A child that is starting, or busy, is looked for at every pass: its first run and its
// dialogs are what the watch is for.

/** While a child waits for its first input, how often to look for its run. */
const STARTING_RETRY_MS = 1_000;
/** Entries read back for a child's newest assistant message. */
const ANSWER_SCAN = 50;
/** How soon a child without a watched document is looked for again, doubling up to the maximum. */
const DOCS_RETRY_MIN_MS = 1_000;
const DOCS_RETRY_MAX_MS = 60_000;
/** Least time between writes that change only rows' current activity. */
export const ACTIVITY_INTERVAL_MS = 2_000;
/** Longest activity line, in characters. */
const ACTIVITY_MAX = 120;
/** The activity of an idle child whose pending wakers will wake it. */
const WAITING_ACTIVITY = "Waiting on background work";
/** How long one watch invocation runs before its next pass ends it, releasing its registry snapshot. */
export const WATCH_INVOCATION_MS = 5 * 60_000;

/** The version 1 widget's key, whose slots the first pass after an upgrade clears. */
const WIDGET_KEY = "subagents";

/** What a child's newest assistant entry says. */
type Answer = {
  provider: string;
  model: string;
  failed: boolean;
  /** The first line of its text, or of its error. */
  line?: string;
  /**
   * Its text, or its error, cut to `ANSWER_EXCERPT_MAX` characters: the row's disclosure. The
   * checkpoint carries an Earlier child's cut to `EARLIER_EXCERPT_MAX`, all its row shows.
   */
  text?: string;
  /** When it was written, epoch ms. */
  at?: number;
};

/**
 * What a child's row was derived from, carried in the watcher's checkpoint across invocations.
 * Only a child that had `pi.live` is carried: its first run's answer was read.
 */
type Carried = {
  busy: boolean;
  /**
   * The id of the child's newest entry when `answer` was read, null for a child with none. Busy
   * or idle cannot version the answer (a child can run and end between two invocations), so the
   * next invocation compares this with the child's newest entry before it trusts the rest.
   */
  head: EntryId | null;
  answer?: Answer;
  /** Configured model, for a child that has no answer. */
  model?: string;
  /** Configured thinking level. */
  thinking?: string;
  /** Its live pending wakers when last read. */
  wakers: TaskId[];
  /** When its newest run started and ended, epoch ms. */
  since?: number;
  ended?: number;
  /** Its spend, read when a run ends. */
  cost?: number;
};

type WatchCheckpoint = { phase: "watch"; children?: Record<string, Carried> };

/** The carried state without `busy`, which changes with every run and decides nothing by itself. */
function carryKey(children: Readonly<Record<string, Carried>>): string {
  return JSON.stringify(
    Object.entries(children).map(([id, { busy: _busy, ...rest }]) => [id, rest]),
  );
}

type Watched = {
  /** Carried by the checkpoint until the child's `pi.live` is first seen and agrees on busy. */
  carried?: Carried;
  /** The newest entry the carried (or, once read, the current) answer was read at. */
  head?: EntryId | null;
  /** The carried head, to compare with the child's newest entry in the first commit. */
  headCheck?: { head: EntryId | null };
  /** The next time a missing document is looked for, and the delay after it, while idle. */
  retryAt: number;
  retryDelay: number;
  live?: DocumentWatch<LiveState>;
  ui?: DocumentWatch<UIState>;
  busy: boolean;
  /** `currentActivity` of the child's `pi.live`, as of its last change. */
  activity?: string;
  /** Why its newest run ended without an answer (`pi.live.runFailure`), until a run starts. */
  failure?: RunFailure;
  /** The first open dialog's words: it waits on you. */
  question?: string;
  /** When the open dialog was first seen, epoch ms. */
  askedAt?: number;
  /** When the owner last stopped it (`oppi.extension-ui` `stoppedAt`): dismisses a failure. */
  stoppedAt?: number;
  /** When its newest run started and ended, epoch ms (carried). */
  since?: number;
  ended?: number;
  /** No `pi.live` yet, and the task that hands the child its first input is still live. */
  starting: boolean;
  /** The child has a row in the pill as last written; hidden children's activity writes nothing. */
  visible?: boolean;
  /** Reread `answer` before the next publish: first sight, or a run ended. */
  stale: boolean;
  /** `answer` was read once. */
  read?: boolean;
  answer?: Answer;
  /** Configured model, shown before the first answer. */
  model?: string;
  thinking?: string;
  /** Its spend, and whether to read it again before the next publish: first sight, a run ended. */
  cost?: number;
  costStale: boolean;
  /** The command of a running background job of its own, while idle waiting on one. */
  waitingOn?: string;
  /** Reread the child's pending wakers before the next publish: first sight, a run ended, or one ended. */
  wakersStale: boolean;
  /** The child's job list, read for the pass's commit to decide its wakers from. */
  jobs?: { list: Parameters<typeof wakingTasks>[2] };
  /** The child's live pending wakers as of the last read. Idle with any: still working. */
  wakers: Set<TaskId>;
  /** Wakers with a waiter, which ends when the task ends or `waiters` is cancelled. */
  waiting: Set<TaskId>;
  /** Cancels the waiters when the row goes away or the watcher ends. */
  waiters: { context: Context; cancel: () => void };
};

/** A child bound to its Session; until then it has no link and no row. */
type Shown = Child & { sessionId: string };

/**
 * What a busy child is doing, from its `pi.live`: the newest running tool's name, else the last
 * line of text of the answer it is generating. Undefined while idle, waiting, or only thinking.
 */
export function currentActivity(live: Readonly<LiveState> | null | undefined): string | undefined {
  if (live?.run === undefined) return undefined;
  const running = (live.tools ?? []).filter((slot) => slot.status === "running").at(-1);
  if (running) return clip(`Running ${running.name}`);
  const content = (live.generation?.message as { content?: unknown } | undefined)?.content;
  if (!Array.isArray(content)) return undefined;
  for (let index = content.length - 1; index >= 0; index--) {
    const block = content[index] as { type?: unknown; text?: unknown } | undefined;
    if (block?.type !== "text" || typeof block.text !== "string") continue;
    const line = block.text
      .split("\n")
      .map((candidate) => candidate.trim())
      .filter((candidate) => candidate.length > 0)
      .at(-1);
    if (line) return clip(line);
  }
  return undefined;
}

function clip(line: string): string {
  return line.length > ACTIVITY_MAX ? `${line.slice(0, ACTIVITY_MAX - 1)}\u2026` : line;
}

/** The words of the first open dialog: its title, message, or first question. */
function question(ui: Readonly<UIState> | null): string | undefined {
  const open = Object.values(ui?.requests ?? {})[0]?.request;
  if (!open) return undefined;
  const text = open.title ?? open.message ?? open.questions?.[0]?.question;
  return clip(firstLine(text) ?? "Waiting for your answer");
}

function firstLine(text: string | undefined): string | undefined {
  return text
    ?.split("\n")
    .map((line) => line.trim())
    .find((line) => line.length > 0);
}

/** Total spend of a conversation's `pi.usage`, in dollars. */
function totalCost(usage: Readonly<UsageState> | null | undefined): number | undefined {
  if (!usage) return undefined;
  let cost = 0;
  for (const value of [...Object.values(usage.models), ...Object.values(usage.tools)])
    cost += value.cost?.total ?? 0;
  return cost;
}

/**
 * The child's newest answer, the newest entry it was read at, and when its newest run started:
 * the time of the newest user message (`pi.live`'s run carries no start time).
 */
async function newestAnswer(
  tx: Tx,
  id: ConversationId,
): Promise<{ answer?: Answer; head: EntryId | null; asked?: number }> {
  const page = await tx.scanEntries({ conversationId: id }, ANSWER_SCAN);
  const head = page.items[0]?.id ?? null;
  let asked: number | undefined;
  for (const entry of page.items) {
    const message = entry.model?.[0];
    if (message?.role === "user") {
      asked ??= message.timestamp;
      continue;
    }
    if (message?.role !== "assistant") continue;
    const { provider, model, stopReason, errorMessage, content, timestamp } =
      message as AssistantMessage;
    const failed = stopReason === "error";
    const text = content
      .filter((block): block is { type: "text"; text: string } => block.type === "text")
      .map((block) => block.text)
      .join("\n");
    const said = (failed ? errorMessage : text) ?? "";
    const line = firstLine(said);
    return {
      head,
      asked,
      answer: {
        provider,
        model,
        failed,
        ...(line ? { line: clip(line), text: cutMarkdown(said, ANSWER_EXCERPT_MAX) } : {}),
        ...(timestamp ? { at: timestamp } : {}),
      },
    };
  }
  return { head, asked };
}

/** A run that ended without an answer for a reason the child did not choose. */
function runFailed(failure: RunFailure | undefined): boolean {
  return (
    failure !== undefined && !["aborted", "reset", "nothing_to_answer"].includes(failure.reason)
  );
}

/** Its newest run failed, and the owner has not stopped it since: it waits on you. */
function failedUnstopped(watched: Watched): boolean {
  const failed = runFailed(watched.failure) || watched.answer?.failed === true;
  if (!failed) return false;
  return !(watched.stoppedAt !== undefined && watched.stoppedAt >= (watched.ended ?? 0));
}

/** Finished by a stop: its run was aborted, or its failure dismissed with Stop. */
function stoppedChild(watched: Watched): boolean {
  if (watched.failure?.reason === "aborted") return true;
  const failed = runFailed(watched.failure) || watched.answer?.failed === true;
  return failed && !failedUnstopped(watched);
}

/** Idle, but background work of its own will wake it to answer again. */
function waitingOnWakers(watched: Watched): boolean {
  return !watched.busy && watched.question === undefined && watched.wakers.size > 0;
}

function rowState(watched: Watched): Subagent["state"] {
  if (watched.question !== undefined) return "warning";
  if (watched.busy || watched.starting || waitingOnWakers(watched)) return "running";
  if (failedUnstopped(watched)) return "error";
  // Idle without an answer: stopped before it replied, or never started.
  return "success";
}

/** The row's second line for `state`: the question, the step or wait, the error, or the answer. */
function rowActivity(watched: Watched, state: Subagent["state"]): string | undefined {
  switch (state) {
    case "warning":
      return watched.question;
    case "running":
      if (watched.busy) return watched.activity;
      if (waitingOnWakers(watched))
        return watched.waitingOn
          ? clip(`Waiting on a background job: ${watched.waitingOn}`)
          : WAITING_ACTIVITY;
      return "Starting";
    case "error":
      return clip(firstLine(watched.failure?.detail) ?? watched.answer?.line ?? "The run failed");
    case "success":
      return stoppedChild(watched) ? undefined : watched.answer?.line;
  }
}

/** When the row's state began: the question opened, the run started, the run ended. */
function rowSince(watched: Watched, state: Subagent["state"]): number | undefined {
  if (state === "warning") return watched.askedAt;
  if (state === "running") return watched.busy || watched.starting ? watched.since : watched.ended;
  if (state === "error") return watched.ended;
  return undefined;
}

/**
 * The task that submits a child's first input: its reporter, or (foreground, or background before
 * the reporter exists) the spawn call, whose task id keys `calls`.
 */
function starterOf(
  name: string,
  child: Child,
  calls: Readonly<Record<string, string>>,
): TaskId | undefined {
  if (child.reporter !== undefined) return child.reporter;
  const call = Object.keys(calls).find((key) => calls[key] === name);
  return call === undefined ? undefined : (Number(call) as TaskId);
}

/**
 * Whether the starter has yet to hand the child its first input. A reporter lives on after that
 * (its report, then following the child), so only its `deliver` phase counts.
 */
function stillStarting(task: {
  kind: string;
  state: { status: string; checkpoint?: unknown };
}): boolean {
  if (task.state.status === "terminal") return false;
  if (task.kind !== SESSION_REPORTER_TASK) return true;
  return (task.state.checkpoint as { phase?: string } | undefined)?.phase === "deliver";
}

/**
 * A row's worktree: its branch only when the spawn did not name it after the child (`<name>`, or
 * a prefix such as `subagent/<name>`), and the progress the child's newest report recorded.
 */
function worktreeOf(
  name: string,
  branch: string | null,
  progress: Child["progress"],
): Subagent["worktree"] {
  const label = branch ?? "detached";
  const named = label === name || label.endsWith(`/${name}`);
  return {
    ...(named ? {} : { branch: label }),
    ...(progress ? { ahead: progress.ahead, dirty: progress.dirty } : {}),
  };
}

function shortId(sessionId: string): string {
  return sessionId.replace(/-/g, "").slice(0, 8);
}

export const SubagentWidget = defineTask<null, WatchCheckpoint, null>({
  name: SUBAGENT_WIDGET_TASK,
  version: 1,
  initial: () => ({ phase: "watch" }),
  abort: (_task, runtime, context) =>
    runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
  phases: {
    async watch(task, runtime, context) {
      const parent = runtime.conversationId;
      const invocationEnds = Date.now() + WATCH_INVOCATION_MS;
      let ending = false;
      const list = await runtime.watchDoc(Subagents, parent, context);
      if (!list) throw new Error("The subagent pill needs oppi.subagents");
      // Where the pill's last row opens the whole thread; none for a conversation without a Session.
      const threadSessionId = (await runtime.snapshot(DurableSessionDoc, parent, context))
        ?.sessionId;
      const carriedAtStart = task.state.checkpoint.children ?? {};
      // What the checkpoint holds now, to write another only when it changes.
      let writtenKey = carryKey(carriedAtStart);
      const watched = new Map<ConversationId, Watched>();
      let dirty = true;
      let wake: (() => void) | undefined;
      const mark = (): void => {
        dirty = true;
        wake?.();
      };
      // A change of activity alone waits for the interval since the last write pass began. The
      // timer exists only while a child is busy and its newest activity is unwritten: going idle
      // is a busy edge, written at once, and every pass takes the pending activity with it.
      // Counting from the pass's start, a change during a pass's commit waits out the interval
      // too instead of writing again right after it.
      let lastWrite = 0;
      let activityTimer: ReturnType<typeof setTimeout> | undefined;
      const markActivity = (): void => {
        if (dirty || activityTimer) return;
        activityTimer = setTimeout(
          () => {
            activityTimer = undefined;
            mark();
          },
          Math.max(0, lastWrite + ACTIVITY_INTERVAL_MS - Date.now()),
        );
      };
      list.start(async () => mark());

      /** Watch what is missing of a child. `pi.live` exists only once its first run starts. */
      const acquire = async (id: ConversationId, entry: Watched): Promise<void> => {
        if (entry.live && entry.ui) return;
        // A child that is idle and has no such document is looked for on a backoff; one that is
        // starting or busy, at every pass.
        if (!entry.starting && !entry.busy && Date.now() < entry.retryAt) return;
        if (!entry.live) {
          const live = await runtime.watchDoc(LiveDoc, id, context);
          if (live) {
            entry.live = live;
            entry.busy = live.value?.run !== undefined;
            entry.activity = currentActivity(live.value);
            entry.failure = live.value?.runFailure;
            // The checkpoint's answer and wakers hold while busy or idle is what it saw; a first
            // run that started and ended before this watch has an answer to read.
            if (entry.carried?.busy !== entry.busy) {
              entry.stale = true;
              entry.wakersStale = true;
              entry.costStale = true;
              entry.wakers = new Set();
              // Its run times are read again with its answer.
              entry.since = undefined;
              entry.ended = undefined;
            }
            entry.carried = undefined;
            live.start(async (call) => {
              if (call.kind !== "value") return;
              const value = call.retired ? null : call.value;
              const busy = value?.run !== undefined;
              const activity = currentActivity(value);
              const failure = value?.runFailure;
              if (JSON.stringify(failure) !== JSON.stringify(entry.failure)) {
                entry.failure = failure;
                if (busy === entry.busy) {
                  mark();
                  return;
                }
              }
              if (busy === entry.busy) {
                if (activity === entry.activity) return;
                entry.activity = activity;
                // A hidden child's activity is on no row; a pass that gives it one reads it.
                if (entry.visible) markActivity();
                return;
              }
              // A run's edges: its start and end times, and its end's answer and spend.
              if (busy) entry.since = Date.now();
              else {
                entry.ended = Date.now();
                entry.stale = true;
                entry.wakersStale = true;
                entry.costStale = true;
              }
              // Its documents (a dialog's) may have appeared with the run.
              entry.retryAt = 0;
              entry.busy = busy;
              entry.activity = activity;
              mark();
            });
          }
        }
        if (!entry.ui) {
          const ui = await runtime.watchDoc(DurableUI, id, context);
          if (ui) {
            entry.ui = ui;
            const read = (value: Readonly<UIState> | null): void => {
              const next = question(value);
              if (next !== undefined && entry.question === undefined) entry.askedAt = Date.now();
              entry.question = next;
              entry.stoppedAt = value?.stoppedAt;
            };
            read(ui.value);
            ui.start(async (call) => {
              if (call.kind !== "value") return;
              const value = call.retired ? null : call.value;
              // Before its first run, any change (the run's working message) means look for
              // `pi.live` again.
              if (
                question(value) === entry.question &&
                value?.stoppedAt === entry.stoppedAt &&
                entry.live
              )
                return;
              read(value);
              entry.retryAt = 0;
              mark();
            });
          }
        }
        if (entry.live && entry.ui) {
          entry.retryDelay = 0;
          entry.retryAt = 0;
        } else {
          entry.retryDelay = Math.min(
            DOCS_RETRY_MAX_MS,
            Math.max(DOCS_RETRY_MIN_MS, entry.retryDelay * 2),
          );
          entry.retryAt = Date.now() + entry.retryDelay;
        }
      };
      const release = async (entry: Watched): Promise<void> => {
        entry.waiters.cancel();
        await entry.live?.stop();
        await entry.ui?.stop();
      };
      /** Wait for `id`, a live waker of `entry`, to end: then the child may wake, so read again. */
      const watchWaker = (entry: Watched, id: TaskId): void => {
        if (entry.waiting.has(id)) return;
        entry.waiting.add(id);
        const ended = (): void => {
          entry.waiting.delete(id);
          // Cancelled: the row went away or the watcher ended.
          if (entry.waiters.context.abortSignal?.aborted) return;
          if (!entry.wakers.delete(id)) return;
          entry.wakersStale = true;
          mark();
        };
        runtime.waitForTask(id, entry.waiters.context).then(ended, ended);
      };

      try {
        while (!runtime.signal.aborted) {
          // An invocation ends with a pass, so the next one starts from the rows this one wrote.
          ending = Date.now() >= invocationEnds;
          dirty = false;
          // This pass writes every row's current activity.
          clearTimeout(activityTimer);
          activityTimer = undefined;
          lastWrite = Date.now();
          const calls = list.value?.calls ?? {};
          // Every child is followed, so one that was not shown can take a row when its state
          // changes. Conversation ids ascend in spawn order; key order would put numeric names
          // first. Newest first, as `selectPillRows` takes them.
          const children = Object.entries(list.value?.children ?? {})
            .filter((pair): pair is [string, Shown] => !!pair[1].sessionId)
            .sort(([, a], [, b]) => b.conversationId - a.conversationId);
          const ids = new Set(children.map(([, child]) => child.conversationId));
          for (const [id, entry] of watched)
            if (!ids.has(id)) {
              watched.delete(id);
              await release(entry);
            }
          const rowsOf: Array<{ name: string; child: Shown; entry: Watched }> = [];
          for (const [name, child] of children) {
            const id = child.conversationId;
            let entry = watched.get(id);
            if (!entry) {
              // A child the checkpoint carries is not read again: not its answer, its model, or its
              // wakers (`acquire` drops them if its `pi.live` disagrees on busy).
              const carried = carriedAtStart[String(id)];
              const agent = carried ? undefined : await runtime.snapshot(AgentDoc, id, context);
              const configured = agent?.model;
              entry = {
                busy: false,
                starting: false,
                retryAt: 0,
                retryDelay: 0,
                ...(carried
                  ? {
                      carried,
                      head: carried.head,
                      headCheck: { head: carried.head },
                      stale: false,
                      read: true,
                      ...(carried.answer ? { answer: carried.answer } : {}),
                      ...(carried.model ? { model: carried.model } : {}),
                      ...(carried.thinking ? { thinking: carried.thinking } : {}),
                      ...(carried.since !== undefined ? { since: carried.since } : {}),
                      ...(carried.ended !== undefined ? { ended: carried.ended } : {}),
                      ...(carried.cost !== undefined ? { cost: carried.cost } : {}),
                      costStale: false,
                      wakersStale: false,
                      wakers: new Set(carried.wakers),
                    }
                  : {
                      stale: true,
                      ...(configured
                        ? { model: `${configured.provider}/${configured.modelId}` }
                        : {}),
                      ...(agent?.thinkingLevel ? { thinking: agent.thinkingLevel } : {}),
                      costStale: true,
                      wakersStale: true,
                      wakers: new Set(),
                    }),
                waiting: new Set(),
                waiters: withCancel(context),
              };
              watched.set(id, entry);
            }
            // A row about to be written may carry this child's activity: its changes count from now.
            entry.visible = true;
            await acquire(id, entry);
            // A busy child's wakers do not decide its row; its run's end reads them.
            if (entry.wakersStale && !entry.busy) {
              entry.wakersStale = false;
              // A commit would create a missing document: read the job list before it.
              entry.jobs = { list: await runtime.snapshot(DurableJobs, id, context) };
              entry.waitingOn = entry.jobs.list?.jobs.find(
                (job) => job.status === "running" && !job.delivered,
              )?.command;
            }
            // Its spend, read when a run ends (and at first sight), outside the commit as the jobs.
            if (entry.costStale && !entry.busy) {
              entry.costStale = false;
              entry.cost = totalCost(await runtime.snapshot(UsageDoc, id, context));
            }
            rowsOf.push({ name, child, entry });
          }

          let shownIds = new Set<string>();
          let carry: Record<string, Carried> = {};
          /** The commit changed the rows the panel draws: publish it now. */
          let publish = false;
          let rereadWakers = false;
          await runtime.commit(async (tx) => {
            const rows: Subagent[] = [];
            for (const { name, child, entry } of rowsOf) {
              const starter = entry.live ? undefined : starterOf(name, child, calls);
              const task = starter === undefined ? undefined : await tx.task(starter);
              entry.starting = task !== undefined && stillStarting(task);
              if (entry.jobs) {
                const reporters = await wakingReporters(tx, child.conversationId);
                const waking = wakingTasks(child.conversationId, reporters, entry.jobs.list);
                entry.wakers = new Set(await liveTasks(tx, waking));
                entry.jobs = undefined;
              }
              // A carried answer holds only while the child has no newer entry than it was read at
              // (a run may have come and gone between two invocations).
              if (entry.headCheck) {
                const newest = (await tx.scanEntries({ conversationId: child.conversationId }, 1))
                  .items[0]?.id;
                if ((newest ?? null) !== entry.headCheck.head) {
                  entry.stale = true;
                  // Its jobs and spend are read outside the commit: the next pass.
                  entry.wakersStale = true;
                  entry.costStale = true;
                  entry.since = undefined;
                  entry.ended = undefined;
                  rereadWakers = true;
                }
                entry.headCheck = undefined;
              }
              // First sight reads the previous answer even while busy; then each run's end.
              if (entry.stale && (!entry.busy || !entry.read)) {
                const read = await newestAnswer(tx, child.conversationId);
                entry.answer = read.answer;
                entry.head = read.head;
                entry.read = true;
                entry.stale = false;
                // Run times this watch did not see happen come from the entries: the newest
                // user message started the run, its answer ended it.
                entry.since ??= read.asked;
                if (!entry.busy) entry.ended ??= read.answer?.at;
              }
              const answer = entry.answer;
              const model = answer ? `${answer.provider}/${answer.model}` : entry.model;
              const state = rowState(entry);
              const activity = rowActivity(entry, state);
              const since = rowSince(entry, state);
              const worktree = child.worktree
                ? worktreeOf(name, child.worktree.branch, child.progress)
                : undefined;
              rows.push({
                id: child.sessionId,
                title: titledWithAgent(
                  name,
                  child.icon ? { kind: "emoji", value: child.icon } : undefined,
                ),
                subtitle: shortId(child.sessionId),
                link: sessionLink(child.sessionId),
                state,
                ...(state === "success" && stoppedChild(entry) ? { stopped: true } : {}),
                ...(model ? { model } : {}),
                ...(entry.thinking ? { thinking: entry.thinking } : {}),
                ...(activity ? { activity } : {}),
                ...(since !== undefined ? { since } : {}),
                ...(entry.ended !== undefined ? { finishedAt: entry.ended } : {}),
                ...(entry.since !== undefined &&
                entry.ended !== undefined &&
                entry.ended >= entry.since
                  ? { took: entry.ended - entry.since }
                  : {}),
                ...(entry.cost !== undefined ? { cost: entry.cost } : {}),
                ...(worktree ? { worktree } : {}),
                ...(answer?.text ? { answer: answer.text } : {}),
              });
            }
            const view = subagentView({ rows, ...(threadSessionId ? { threadSessionId } : {}) });
            shownIds = view.shown;
            // Needs You, Working, and Recent rows keep a long answer; the rest, Earlier, a glance:
            // the document saves what the drawer can show, not the whole answer of every century.
            const fullAnswers = view.full;
            for (const row of rows)
              if (row.answer && !fullAnswers.has(row.id))
                row.answer = cutMarkdown(row.answer, EARLIER_EXCERPT_MAX);
            carry = {};
            for (const { child, entry } of rowsOf)
              if (entry.live && entry.read && entry.head !== undefined)
                carry[String(child.conversationId)] = {
                  busy: entry.busy,
                  head: entry.head,
                  ...(entry.answer
                    ? {
                        answer:
                          entry.answer.text && !fullAnswers.has(child.sessionId)
                            ? {
                                ...entry.answer,
                                text: cutMarkdown(entry.answer.text, EARLIER_EXCERPT_MAX),
                              }
                            : entry.answer,
                      }
                    : {}),
                  ...(entry.model ? { model: entry.model } : {}),
                  ...(entry.thinking ? { thinking: entry.thinking } : {}),
                  wakers: [...entry.wakers],
                  ...(entry.since !== undefined ? { since: entry.since } : {}),
                  ...(entry.ended !== undefined ? { ended: entry.ended } : {}),
                  ...(entry.cost !== undefined ? { cost: entry.cost } : {}),
                };
            // The pill is this Session's own surface now. A Session that ran the version 1 widget
            // keeps its strip entry until it is cleared here: absent slots are not written again.
            const ui = await tx.doc(DurableUI, parent);
            for (const slot of [`status:${WIDGET_KEY}`, `widget:${WIDGET_KEY}`])
              if (slot in ui.notifications) delete ui.notifications[slot];
            // What `load` draws when the chat attaches, after a restart too. Only a change is
            // written, and only a change republishes the surface.
            const saved = await tx.doc(SubagentPill, parent);
            const key = (value: { rows: Subagent[]; threadSessionId?: string }): string =>
              JSON.stringify([value.rows, value.threadSessionId ?? null]);
            publish = key(saved) !== key({ rows, ...(threadSessionId ? { threadSessionId } : {}) });
            if (publish) {
              saved.rows = rows;
              if (threadSessionId) saved.threadSessionId = threadSessionId;
              else delete saved.threadSessionId;
            }
            // A sleep that is already due, not a running checkpoint: only a new invocation takes
            // a new snapshot (one that goes on to the next phase keeps the one it was reserved with).
            if (ending)
              return {
                status: "sleeping" as const,
                until: runtime.now(),
                checkpoint: { phase: "watch" as const, children: carry },
              };
            // Otherwise the checkpoint is rewritten only when what it carries changed.
            return carryKey(carry) === writtenKey
              ? undefined
              : {
                  status: "running" as const,
                  checkpoint: { phase: "watch" as const, children: carry },
                };
          }, context);
          writtenKey = carryKey(carry);
          if (rereadWakers) mark();
          for (const { child, entry } of rowsOf) entry.visible = shownIds.has(child.sessionId);
          // What the panel draws from the documents just committed, now. Undefined where the chat
          // has no live Session: its attach draws the panel instead.
          if (publish) {
            const surfaces = await oppiHost().sessionSurfaces(runtime, context);
            if (surfaces) await panel.sync({ surfaces }, context);
          }
          if (ending) return;
          // After the commit that read them live: one that ended since resolves at once.
          for (const { entry } of rowsOf) for (const id of entry.wakers) watchWaker(entry, id);

          await new Promise<void>((resolve, reject) => {
            let timer: ReturnType<typeof setTimeout> | undefined;
            const cleanup = (): void => {
              if (timer) clearTimeout(timer);
              runtime.signal.removeEventListener("abort", abort);
              wake = undefined;
            };
            const finish = (): void => {
              cleanup();
              resolve();
            };
            const abort = (): void => {
              cleanup();
              reject(runtime.signal.reason);
            };
            wake = finish;
            runtime.signal.addEventListener("abort", abort, { once: true });
            if (runtime.signal.aborted) abort();
            else if (dirty) finish();
            else {
              // Bounded by the starter: it submits the first input, or ends.
              const retry = rowsOf.some(({ entry }) => entry.starting)
                ? STARTING_RETRY_MS
                : Number.POSITIVE_INFINITY;
              // The next backoff of an idle child still missing a document.
              const docs = Math.min(
                Number.POSITIVE_INFINITY,
                ...rowsOf
                  .filter(({ entry }) => !(entry.live && entry.ui) && !entry.starting)
                  .map(({ entry }) => entry.retryAt - Date.now()),
              );
              timer = setTimeout(
                finish,
                Math.max(0, Math.min(retry, docs, invocationEnds - Date.now())),
              );
            }
          });
        }
      } finally {
        clearTimeout(activityTimer);
        await list.stop();
        await Promise.all([...watched.values()].map(release));
      }
    },
  },
});

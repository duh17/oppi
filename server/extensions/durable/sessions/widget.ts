import type { Context } from "@earendil-works/chord";
import { withCancel } from "@earendil-works/chord/context";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import {
  AgentDoc,
  LiveDoc,
  defineTask,
  type ConversationId,
  type DocumentWatch,
  type JsonObject,
  type LiveState,
  type Task,
  type TaskId,
  type Tx,
} from "@earendil-works/pi-durable";
import {
  DurableUI,
  SESSION_REPORTER_TASK,
  type DurableSessionsHost,
  type UINotification,
  type UIState,
} from "oppi/durable";
import { SUBAGENT_WIDGET_TASK, Subagents, type Child } from "./contract.js";
import { liveTasks } from "./wakers.js";
import {
  renderSubagentTerminal,
  rowFallback,
  sessionLink,
  subagentRows,
  titledWithAgent,
  widgetChrome,
  type Subagent,
} from "./subagents.js";

// The durable form of the reference `subagents` extension's pill: the same activity rows, built by
// the same helpers, published through the `oppi.extension-ui` notification slots. Rows link to
// `oppi://session/<id>`, which the app already opens.
//
// Refresh follows the documents; there is no ticking timer. Each shown child's `pi.live` (busy,
// and its current activity) and `oppi.extension-ui` (an open dialog: needs attention) are
// watched in process; a write happens only when a row changes. Model and context usage come from
// the child's newest assistant entry, read when the child is first shown and when a run ends, so
// a working child shows the usage of its previous answer. A change of activity alone is written
// at most every `ACTIVITY_INTERVAL_MS`: streamed text changes it with every partial.
//
// An idle child is not done while background work of its own (its pending wakers: undelivered
// jobs, its own reporters) will wake it to answer again: its row stays Working. The wakers are
// read when the child is first shown, when a run ends, and when one of them ends; each live one
// has a waiter that marks the pass when it ends. No timer polls them.

/** Rows the pill shows: the newest children, in spawn order. */
const MAX_ROWS = 8;
/** While a child waits for its first input, how often to look for its run. */
const STARTING_RETRY_MS = 1_000;
/** Entries read back for a child's newest assistant message. */
const ANSWER_SCAN = 50;
/** Least time between writes that change only rows' current activity. */
export const ACTIVITY_INTERVAL_MS = 2_000;
/** Longest activity line, in characters. */
const ACTIVITY_MAX = 120;
/** The activity of an idle child whose pending wakers will wake it. */
export const WAITING_ACTIVITY = "Waiting on background work";

const PROVENANCE = {
  extensionScopeId: "repo:subagents",
  extensionDisplayName: "Subagents",
} as const;
const WIDGET_KEY = "subagents";

/** What a child's newest assistant entry says. */
type Answer = {
  provider: string;
  model: string;
  contextTokens?: number;
  failed: boolean;
};

type Watched = {
  live?: DocumentWatch<LiveState>;
  ui?: DocumentWatch<UIState>;
  busy: boolean;
  /** `currentActivity` of the child's `pi.live`, as of its last change. */
  activity?: string;
  asking: boolean;
  /** No `pi.live` yet, and the task that hands the child its first input is still live. */
  starting: boolean;
  /** Reread `answer` before the next publish: first sight, or a run ended. */
  stale: boolean;
  /** `answer` was read once. */
  read?: boolean;
  answer?: Answer;
  /** Configured model, shown before the first answer. */
  model?: string;
  /** Reread the child's pending wakers before the next publish: first sight, a run ended, or one ended. */
  wakersStale: boolean;
  /** Pending wakers read but not yet checked live in the pass's commit. */
  candidates?: TaskId[];
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

function asking(ui: Readonly<UIState> | null): boolean {
  return Object.values(ui?.requests ?? {}).some((entry) => !entry.response);
}

async function newestAnswer(tx: Tx, id: ConversationId): Promise<Answer | undefined> {
  const page = await tx.scanEntries({ conversationId: id }, ANSWER_SCAN);
  for (const entry of page.items) {
    const message = entry.model?.[0];
    if (message?.role !== "assistant") continue;
    const { provider, model, usage, stopReason } = message as AssistantMessage;
    const total =
      usage?.totalTokens ||
      (usage ? usage.input + usage.output + usage.cacheRead + usage.cacheWrite : 0);
    return {
      provider,
      model,
      ...(total > 0 ? { contextTokens: total } : {}),
      failed: stopReason === "error",
    };
  }
  return undefined;
}

/** Idle, but background work of its own will wake it to answer again. */
function waitingOnWakers(watched: Watched): boolean {
  return !watched.busy && !watched.asking && watched.wakers.size > 0;
}

function rowState(watched: Watched): Subagent["state"] {
  if (watched.asking) return "warning";
  if (watched.busy || watched.starting || waitingOnWakers(watched)) return "running";
  // Idle without an answer: stopped before it replied, or never started.
  return watched.answer?.failed ? "error" : "success";
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

function shortId(sessionId: string): string {
  return sessionId.replace(/-/g, "").slice(0, 8);
}

function notifications(rows: Subagent[]): Record<string, UINotification> {
  const status: UINotification = {
    id: "subagents:status",
    method: "setStatus",
    statusKey: WIDGET_KEY,
    ...PROVENANCE,
  };
  const widget: UINotification = {
    id: "subagents:widget",
    method: "setWidget",
    widgetKey: WIDGET_KEY,
    ...PROVENANCE,
  };
  if (rows.length > 0) {
    const chrome = widgetChrome(rows);
    const native = subagentRows(rows);
    if (chrome.subtitle) status.statusText = chrome.subtitle;
    widget.widgetLines = renderSubagentTerminal(rows);
    widget.nativeSurface = {
      version: 1,
      id: `widget:${WIDGET_KEY}`,
      source: "widget",
      presentation: {
        style: "surfacePanel",
        title: chrome.title,
        ...(chrome.subtitle ? { subtitle: chrome.subtitle } : {}),
      },
      blocks: [{ type: "activityList", id: "subagents", rows: native }],
      fallback: { lines: native.map(rowFallback) },
    } as unknown as JsonObject;
  }
  return { [`status:${WIDGET_KEY}`]: status, [`widget:${WIDGET_KEY}`]: widget };
}

/**
 * The pill's watcher. `host` finds Oppi's subagent host for the watcher's execution env, which
 * runs in the parent conversation: it reads the children's pending wakers.
 */
export function defineSubagentWidget(
  host: (env: ExecutionEnv | undefined) => DurableSessionsHost | undefined,
): Task<null, { phase: "watch" }, null, object> {
  return defineTask<null, { phase: "watch" }, null>({
    name: SUBAGENT_WIDGET_TASK,
    version: 1,
    initial: () => ({ phase: "watch" }),
    abort: (_task, runtime, context) =>
      runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
    phases: {
      async watch(_task, runtime, context) {
        const parent = runtime.conversationId;
        let sessions: DurableSessionsHost | undefined;
        /**
         * A child's pending wakers; undefined while the parent's subagent host cannot be found.
         * Resolved at the first read, not at start: a sandbox parent has an env only while its
         * VM is attached, and the pill needs none for anything else. Until it is found, rows
         * show no wakers, and the next pass reads again.
         */
        const wakersOf = async (child: ConversationId): Promise<TaskId[] | undefined> => {
          sessions ??= await runtime.env(context).then(host, () => undefined);
          return sessions?.pendingWakers(child);
        };
        const list = await runtime.watchDoc(Subagents, parent, context);
        if (!list) throw new Error("The subagent pill needs oppi.subagents");
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

        /** Watch what is missing of a shown child. `pi.live` exists only once its first run starts. */
        const acquire = async (id: ConversationId, entry: Watched): Promise<void> => {
          if (!entry.live) {
            const live = await runtime.watchDoc(LiveDoc, id, context);
            if (live) {
              entry.live = live;
              entry.busy = live.value?.run !== undefined;
              entry.activity = currentActivity(live.value);
              // A first run that started and ended before this watch has an answer to read.
              entry.stale = true;
              entry.wakersStale = true;
              live.start(async (value) => {
                const busy = value?.run !== undefined;
                const activity = currentActivity(value);
                if (busy === entry.busy) {
                  if (activity === entry.activity) return;
                  entry.activity = activity;
                  markActivity();
                  return;
                }
                if (!busy) {
                  entry.stale = true;
                  entry.wakersStale = true;
                }
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
              entry.asking = asking(ui.value);
              ui.start(async (value) => {
                const next = asking(value);
                // Before its first run, any change (the run's working message) means look for
                // `pi.live` again.
                if (next === entry.asking && entry.live) return;
                entry.asking = next;
                mark();
              });
            }
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
            dirty = false;
            // This pass writes every row's current activity.
            clearTimeout(activityTimer);
            activityTimer = undefined;
            lastWrite = Date.now();
            const calls = list.value?.calls ?? {};
            // Conversation ids ascend in spawn order; key order would put numeric names first.
            const shown = Object.entries(list.value?.children ?? {})
              .filter((pair): pair is [string, Shown] => !!pair[1].sessionId)
              .sort(([, a], [, b]) => a.conversationId - b.conversationId)
              .slice(-MAX_ROWS);
            const ids = new Set(shown.map(([, child]) => child.conversationId));
            for (const [id, entry] of watched)
              if (!ids.has(id)) {
                watched.delete(id);
                await release(entry);
              }
            const rowsOf: Array<{ name: string; child: Shown; entry: Watched }> = [];
            for (const [name, child] of shown) {
              const id = child.conversationId;
              let entry = watched.get(id);
              if (!entry) {
                const configured = (await runtime.snapshot(AgentDoc, id, context))?.model;
                entry = {
                  busy: false,
                  asking: false,
                  starting: false,
                  stale: true,
                  ...(configured ? { model: `${configured.provider}/${configured.modelId}` } : {}),
                  wakersStale: true,
                  wakers: new Set(),
                  waiting: new Set(),
                  waiters: withCancel(context),
                };
                watched.set(id, entry);
              }
              await acquire(id, entry);
              // A busy child's wakers do not decide its row; its run's end reads them.
              if (entry.wakersStale && !entry.busy) {
                entry.candidates = await wakersOf(id);
                entry.wakersStale = entry.candidates === undefined;
              }
              rowsOf.push({ name, child, entry });
            }

            await runtime.commit(async (tx) => {
              const rows: Subagent[] = [];
              for (const { name, child, entry } of rowsOf) {
                const starter = entry.live ? undefined : starterOf(name, child, calls);
                const task = starter === undefined ? undefined : await tx.task(starter);
                entry.starting = task !== undefined && stillStarting(task);
                if (entry.candidates) {
                  entry.wakers = new Set(await liveTasks(tx, entry.candidates));
                  entry.candidates = undefined;
                }
                // First sight reads the previous answer even while busy; then each run's end.
                if (entry.stale && (!entry.busy || !entry.read)) {
                  entry.answer = await newestAnswer(tx, child.conversationId);
                  entry.read = true;
                  entry.stale = false;
                }
                const answer = entry.answer;
                const window = answer
                  ? runtime.models.getModel(answer.provider, answer.model)?.contextWindow
                  : undefined;
                const model = answer ? `${answer.provider}/${answer.model}` : entry.model;
                rows.push({
                  id: child.sessionId,
                  title: titledWithAgent(
                    name,
                    child.icon ? { kind: "emoji", value: child.icon } : undefined,
                  ),
                  subtitle: shortId(child.sessionId),
                  link: sessionLink(child.sessionId),
                  state: rowState(entry),
                  ...(model ? { model } : {}),
                  ...(answer?.contextTokens !== undefined
                    ? { contextTokens: answer.contextTokens }
                    : {}),
                  ...(window ? { contextWindow: window } : {}),
                  ...(entry.busy && entry.activity
                    ? { activity: entry.activity }
                    : waitingOnWakers(entry)
                      ? { activity: WAITING_ACTIVITY }
                      : {}),
                });
              }
              const ui = await tx.doc(DurableUI, parent);
              for (const [slot, next] of Object.entries(notifications(rows))) {
                const current = ui.notifications[slot];
                // Nothing shown yet: no clear to publish.
                if (current === undefined && rows.length === 0) continue;
                if (JSON.stringify(current) !== JSON.stringify(next)) ui.notifications[slot] = next;
              }
              return undefined;
            }, context);
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
              // Bounded by the starter: it submits the first input, or ends.
              else if (rowsOf.some(({ entry }) => entry.starting))
                timer = setTimeout(finish, STARTING_RETRY_MS);
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
}

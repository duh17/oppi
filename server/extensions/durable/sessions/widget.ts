import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  AgentDoc,
  LiveDoc,
  defineTask,
  type ConversationId,
  type DocumentWatch,
  type JsonObject,
  type LiveState,
  type TaskId,
  type Tx,
} from "@earendil-works/pi-durable";
import { DurableUI, type UINotification, type UIState } from "oppi/durable";
import { SUBAGENT_WIDGET_TASK, Subagents, type Child } from "./contract.js";
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
// Refresh follows the documents; there is no timer. Each shown child's `pi.live` (busy) and
// `oppi.extension-ui` (an open dialog: needs attention) are watched in process; a write happens
// only when a row changes. Model and context usage come from the child's newest assistant entry,
// read when the child is first shown and when a run ends, so a working child shows the usage of
// its previous answer.

/** Rows the pill shows: the newest children, in spawn order. */
const MAX_ROWS = 8;
/** While a child waits for its first input, how often to look for its run. */
const STARTING_RETRY_MS = 1_000;
/** Entries read back for a child's newest assistant message. */
const ANSWER_SCAN = 50;

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
};

/** A child bound to its Session; until then it has no link and no row. */
type Shown = Child & { sessionId: string };

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

function rowState(watched: Watched): Subagent["state"] {
  if (watched.asking) return "warning";
  if (watched.busy || watched.starting) return "running";
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

export const SubagentWidget = defineTask<null, { phase: "watch" }, null>({
  name: SUBAGENT_WIDGET_TASK,
  version: 1,
  initial: () => ({ phase: "watch" }),
  abort: (_task, runtime, context) =>
    runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
  phases: {
    async watch(_task, runtime, context) {
      const parent = runtime.conversationId;
      const list = await runtime.watchDoc(Subagents, parent, context);
      if (!list) throw new Error("The subagent pill needs oppi.subagents");
      const watched = new Map<ConversationId, Watched>();
      let dirty = true;
      let wake: (() => void) | undefined;
      const mark = (): void => {
        dirty = true;
        wake?.();
      };
      list.start(async () => mark());

      /** Watch what is missing of a shown child. `pi.live` exists only once its first run starts. */
      const acquire = async (id: ConversationId, entry: Watched): Promise<void> => {
        if (!entry.live) {
          const live = await runtime.watchDoc(LiveDoc, id, context);
          if (live) {
            entry.live = live;
            entry.busy = live.value?.run !== undefined;
            // A first run that started and ended before this watch has an answer to read.
            entry.stale = true;
            live.start(async (value) => {
              const busy = value?.run !== undefined;
              if (busy === entry.busy) return;
              if (!busy) entry.stale = true;
              entry.busy = busy;
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
        await entry.live?.stop();
        await entry.ui?.stop();
      };

      try {
        while (!runtime.signal.aborted) {
          dirty = false;
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
              };
              watched.set(id, entry);
            }
            await acquire(id, entry);
            rowsOf.push({ name, child, entry });
          }

          await runtime.commit(async (tx) => {
            const rows: Subagent[] = [];
            for (const { name, child, entry } of rowsOf) {
              const starter = entry.live ? undefined : starterOf(name, child, calls);
              const task = starter === undefined ? undefined : await tx.task(starter);
              entry.starting = task !== undefined && task.state.status !== "terminal";
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
        await list.stop();
        await Promise.all([...watched.values()].map(release));
      }
    },
  },
});

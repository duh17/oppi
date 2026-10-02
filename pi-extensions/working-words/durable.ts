import {
  defineDoc,
  defineExtension,
  defineTask,
  LiveDoc,
  type ConversationId,
  type LiveState,
  type Tx,
  type TaskId,
} from "@earendil-works/pi-durable";
import { DurableUI, type UINotification } from "../durable-ui.js";

// Durable port of the global `working-message` Pi extension: an activity
// phrase plus elapsed time while busy, chosen deterministically per run.
// No status, no custom indicator frames, no model call.

export type Activity =
  | "thinking"
  | "writing"
  | "reading"
  | "editing"
  | "running"
  | "searching"
  | "delegating"
  | "asking"
  | "drawing"
  | "checking";

export const PHRASES: Record<Activity, string[]> = {
  thinking: [
    "Chewing on it",
    "Walking the maze",
    "Sorting a route",
    "Holding a thought",
  ],
  writing: [
    "Putting it in words",
    "Talking it out",
    "Laying the reply",
    "Typing it through",
  ],
  reading: [
    "Leafing through",
    "Following a thread",
    "Opening a drawer",
    "Skimming the file",
  ],
  editing: [
    "Nipping a line",
    "Tightening a screw",
    "Sanding a corner",
    "Patching a hole",
  ],
  running: [
    "Poking the machine",
    "Waiting on bash",
    "Listening for a cough",
    "Taking a pulse",
  ],
  searching: [
    "Looking for receipts",
    "Asking around",
    "Checking the map",
    "Hunting a source",
  ],
  delegating: [
    "Sending a scout",
    "Splitting the table",
    "Opening another desk",
    "Calling backup",
  ],
  asking: ["Waiting on you", "Your move", "Need a nod", "Holding for you"],
  drawing: [
    "Sketching it",
    "Waiting on pixels",
    "Mixing a frame",
    "Cooking a still",
  ],
  checking: [
    "Tapping the wheels",
    "Scanning for smoke",
    "Closing the loop",
    "Walking it back",
  ],
};

const TICK_MS = 1_000;

function hashText(text: string): number {
  let hash = 2166136261;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

export function pickPhrase(activity: Activity, turn: string | number): string {
  const options = PHRASES[activity];
  return (
    options[hashText(`${activity}:${turn}`) % options.length] ??
    options[0] ??
    ""
  );
}

export function formatElapsed(ms: number): string | undefined {
  if (ms < 1000) return undefined;
  const totalSec = Math.floor(ms / 1000);
  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);
  const seconds = totalSec % 60;
  if (hours > 0) {
    return minutes > 0
      ? `${hours}h ${String(minutes).padStart(2, "0")}m`
      : `${hours}h`;
  }
  if (minutes > 0) {
    return seconds > 0
      ? `${minutes}m ${String(seconds).padStart(2, "0")}s`
      : `${minutes}m`;
  }
  return `${seconds}s`;
}

export function workingLine(phrase: string, elapsedMs: number): string {
  const elapsed = formatElapsed(elapsedMs);
  return elapsed ? `${phrase} · ${elapsed}` : phrase;
}

export function classifyTool(toolName: string): Activity {
  const name = toolName.toLowerCase();
  if (name === "bash" || name === "powershell") return "running";
  if (name === "read" || name === "grep" || name === "find" || name === "ls")
    return "reading";
  if (name === "edit" || name === "write") return "editing";
  if (name === "ask") return "asking";
  if (
    name.includes("imagen") ||
    name.includes("image_gen") ||
    name.includes("drawthings")
  ) {
    return "drawing";
  }
  if (
    name.includes("search") ||
    name.includes("fetch") ||
    name === "hacker_news" ||
    name === "x_read" ||
    name === "reddit" ||
    name === "zhihu" ||
    name === "v2ex" ||
    name.includes("transcribe")
  ) {
    return "searching";
  }
  if (
    name.includes("agent") ||
    name.includes("herdr") ||
    name === "launch_agent_session"
  ) {
    return "delegating";
  }
  if (
    name.includes("test") ||
    name.includes("review") ||
    name.includes("verify") ||
    name === "qa"
  ) {
    return "checking";
  }
  return "thinking";
}

type View = { run?: string; activity: Activity };

/**
 * Classic event mapping over `pi.live`: a running tool wins (the latest one
 * started), a finished tool round reads as thinking, otherwise the last
 * thinking/text block of the streaming partial.
 */
export function deriveView(live: Readonly<LiveState> | null | undefined): View {
  const run = live?.run;
  if (!run) return { activity: "thinking" };
  const id = String((run as { taskId?: unknown }).taskId);
  const tools = Array.isArray(live?.tools) ? live.tools : [];
  const running = tools.filter((slot) => slot.status === "running").at(-1);
  if (running) return { run: id, activity: classifyTool(running.name) };
  if (tools.length) return { run: id, activity: "thinking" };
  const content = (
    live?.generation?.message as { content?: unknown } | undefined
  )?.content;
  if (Array.isArray(content)) {
    for (let i = content.length - 1; i >= 0; i--) {
      const type = (content[i] as { type?: unknown } | undefined)?.type;
      if (type === "text") return { run: id, activity: "writing" };
      if (type === "thinking") return { run: id, activity: "thinking" };
    }
  }
  return { run: id, activity: "thinking" };
}

// `run` survives restart so elapsed time keeps counting from the real start.
const WordsOwner = defineDoc<{
  task?: TaskId;
  run?: { id: string; startedAt: number };
}>({
  kind: "oppi.working-words-owner",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({}),
});

const PROVENANCE = {
  extensionScopeId: "repo:working-words",
  extensionDisplayName: "Working Words",
} as const;

// Explicit clears for slots earlier versions published (status pill and
// custom indicator frames). Kept in the document so reconnect clears too.
const CLEARS: Record<string, Omit<UINotification, "id">> = {
  "status:working-words": { method: "setStatus", statusKey: "working-words" },
  "working:indicator": { method: "setWorkingIndicator" },
};

function sameNotification(
  a: UINotification | undefined,
  b: UINotification,
): boolean {
  return a !== undefined && JSON.stringify(a) === JSON.stringify(b);
}

const Words = defineTask<null, { phase: "watch" }, null>({
  name: "oppi.working-words",
  version: 1,
  initial: () => ({ phase: "watch" }),
  abort: async (_task, runtime, context) => {
    await runtime.commit(
      () => ({ status: "terminal", outcome: { status: "aborted" } }),
      context,
    );
  },
  phases: {
    async watch(task, runtime, context) {
      const live = await runtime.watchDoc(
        LiveDoc,
        runtime.conversationId,
        context,
      );
      if (!live) throw new Error("Working words requires pi.live");
      let view = deriveView(live.value);
      let wake: (() => void) | undefined;
      live.start(async (value) => {
        const next = deriveView(value);
        if (next.run !== view.run || next.activity !== view.activity) {
          view = next;
          wake?.();
        }
      });
      try {
        while (!runtime.signal.aborted) {
          // A live-doc edge can arrive while the UI commit is in flight and no
          // waiter is installed. Compare against the view actually published.
          const published = view;
          await runtime.commit(async (tx) => {
            const owner = await tx.doc(WordsOwner, runtime.conversationId);
            let message: string | undefined;
            if (published.run === undefined) {
              delete owner.run;
            } else {
              if (owner.run?.id !== published.run)
                owner.run = { id: published.run, startedAt: Date.now() };
              message = workingLine(
                pickPhrase(published.activity, published.run),
                Date.now() - owner.run.startedAt,
              );
            }
            const ui = await tx.doc(DurableUI, runtime.conversationId);
            const put = (
              slot: string,
              value: Omit<UINotification, "id">,
            ): void => {
              const next = {
                id: `working-words:${slot}`,
                ...PROVENANCE,
                ...value,
              } as UINotification;
              if (!sameNotification(ui.notifications[slot], next))
                ui.notifications[slot] = next;
            };
            for (const [slot, value] of Object.entries(CLEARS))
              put(slot, value);
            put("working:message", {
              method: "setWorkingMessage",
              ...(message ? { message } : {}),
            });
            return { status: "running", checkpoint: task.state.checkpoint };
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
            else if (published !== view) finish();
            else if (view.run !== undefined)
              timer = setTimeout(finish, TICK_MS);
          });
        }
      } finally {
        await live.stop();
      }
    },
  },
});

export const DurableWorkingWords = defineExtension({
  name: "working-words",
  tasks: [Words],
});

/** Called at conversation attachment, before scheduling. Also repairs a stopped owner. */
export async function ensureWorkingWords(
  tx: Tx,
  id: ConversationId,
): Promise<void> {
  const state = await tx.doc(WordsOwner, id);
  const task = state.task === undefined ? undefined : await tx.task(state.task);
  if (!task || task.state.status === "terminal")
    state.task = await tx.createTask(Words, null, {
      conversationId: id,
      ownership: { kind: "conversation" },
      background: true,
    });
}

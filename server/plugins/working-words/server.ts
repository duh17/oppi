import { defineTask, LiveDoc, type LiveState } from "@earendil-works/pi-durable";
import { defineExtension, defineFacet, DurableUI, Extensions, type UINotification } from "oppi/v1";
import { WORKING_WORDS_EXTENSION, WORKING_WORDS_TASK } from "./contract.js";

// Durable port of the global `working-message` Pi extension: an activity
// phrase while busy, chosen deterministically per run. It carries no clock: the
// client's working row shows the turn's time itself, so the message changes only
// when the activity does. No status, no custom indicator frames, no model call.

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
  thinking: ["Chewing on it", "Walking the maze", "Sorting a route", "Holding a thought"],
  writing: ["Putting it in words", "Talking it out", "Laying the reply", "Typing it through"],
  reading: ["Leafing through", "Following a thread", "Opening a drawer", "Skimming the file"],
  editing: ["Nipping a line", "Tightening a screw", "Sanding a corner", "Patching a hole"],
  running: ["Poking the machine", "Waiting on bash", "Listening for a cough", "Taking a pulse"],
  searching: ["Looking for receipts", "Asking around", "Checking the map", "Hunting a source"],
  delegating: ["Sending a scout", "Splitting the table", "Opening another desk", "Calling backup"],
  asking: ["Waiting on you", "Your move", "Need a nod", "Holding for you"],
  drawing: ["Sketching it", "Waiting on pixels", "Mixing a frame", "Cooking a still"],
  checking: ["Tapping the wheels", "Scanning for smoke", "Closing the loop", "Walking it back"],
};

/**
 * How long one watch invocation runs. pi-durable keeps the registry snapshot an invocation was
 * reserved with until it ends, and with it every extension installed then, also after it is
 * uninstalled: a watcher of an idle conversation would hold them for as long as it stays open.
 * The last pass commits a sleep that is already due, so the task is reserved again on the
 * current registry.
 */
const INVOCATION_MS = 5 * 60_000;

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
  return options[hashText(`${activity}:${turn}`) % options.length] ?? options[0] ?? "";
}

export function classifyTool(toolName: string): Activity {
  const name = toolName.toLowerCase();
  if (name === "bash" || name === "powershell") return "running";
  if (name === "read" || name === "grep" || name === "find" || name === "ls") return "reading";
  if (name === "edit" || name === "write") return "editing";
  if (name === "ask") return "asking";
  if (name.includes("imagen") || name.includes("image_gen") || name.includes("drawthings")) {
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
  if (name.includes("agent") || name.includes("herdr") || name === "launch_agent_session") {
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
  const content = (live?.generation?.message as { content?: unknown } | undefined)?.content;
  if (Array.isArray(content)) {
    for (let i = content.length - 1; i >= 0; i--) {
      const type = (content[i] as { type?: unknown } | undefined)?.type;
      if (type === "text") return { run: id, activity: "writing" };
      if (type === "thinking") return { run: id, activity: "thinking" };
    }
  }
  return { run: id, activity: "thinking" };
}

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

function sameNotification(a: UINotification | undefined, b: UINotification): boolean {
  return a !== undefined && JSON.stringify(a) === JSON.stringify(b);
}

const Words = defineTask<null, { phase: "watch" }, null>({
  name: WORKING_WORDS_TASK,
  version: 1,
  initial: () => ({ phase: "watch" }),
  abort: async (_task, runtime, context) => {
    await runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context);
  },
  phases: {
    async watch(task, runtime, context) {
      const live = await runtime.watchDoc(LiveDoc, runtime.conversationId, context);
      if (!live) throw new Error("Working words requires pi.live");
      const invocationEnds = Date.now() + INVOCATION_MS;
      let view = deriveView(live.value);
      let wake: (() => void) | undefined;
      live.start(async (call) => {
        if (call.kind !== "value") return;
        const next = deriveView(call.retired ? null : call.value);
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
          const ending = Date.now() >= invocationEnds;
          await runtime.commit(async (tx) => {
            const message =
              published.run === undefined
                ? undefined
                : pickPhrase(published.activity, published.run);
            const ui = await tx.doc(DurableUI, runtime.conversationId);
            const put = (slot: string, value: Omit<UINotification, "id">): void => {
              const next = {
                id: `working-words:${slot}`,
                ...PROVENANCE,
                ...value,
              } as UINotification;
              if (!sameNotification(ui.notifications[slot], next)) ui.notifications[slot] = next;
            };
            for (const [slot, value] of Object.entries(CLEARS)) put(slot, value);
            put("working:message", {
              method: "setWorkingMessage",
              ...(message ? { message } : {}),
            });
            // A sleep, not a running checkpoint: only a new invocation takes a new snapshot.
            return ending
              ? {
                  status: "sleeping",
                  until: runtime.now(),
                  checkpoint: task.state.checkpoint,
                }
              : { status: "running", checkpoint: task.state.checkpoint };
          }, context);
          if (ending) return;
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
            // Nothing to publish until the activity or run changes (`wake`) or this
            // invocation ends.
            if (runtime.signal.aborted) abort();
            else if (published !== view) finish();
            else timer = setTimeout(finish, Math.max(0, invocationEnds - Date.now()));
          });
        }
      } finally {
        await live.stop();
      }
    },
  },
});

export const DurableWorkingWords = defineExtension({
  name: WORKING_WORDS_EXTENSION,
  runtimes: ["host", "sandbox"],
  tasks: [Words],
});

/** The plugin facet. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableWorkingWords));

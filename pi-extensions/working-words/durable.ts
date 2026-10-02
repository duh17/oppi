import {
  defineDoc,
  defineExtension,
  defineTask,
  LiveDoc,
  type ConversationId,
  type Tx,
  type TaskId,
} from "@earendil-works/pi-durable";
import { DurableUI, type UINotification } from "../durable-ui.js";

const PHRASES = [
  "Checking files…",
  "Reading context…",
  "Tracing references…",
  "Reviewing diffs…",
  "Inspecting tests…",
  "Updating the plan…",
  "Looking for edge cases…",
  "Verifying assumptions…",
  "Preparing the next step…",
  "Tightening the patch…",
  "Checking nearby code…",
  "Waiting on tools…",
  "Comparing options…",
  "Keeping state tidy…",
  "Reviewing output…",
  "Ready for the next move…",
];
const WordsOwner = defineDoc<{ task?: TaskId }>({
  kind: "oppi.working-words-owner",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({}),
});
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
      let busy = live.value?.run !== undefined;
      let wake: (() => void) | undefined;
      live.start(async (value) => {
        const next = value?.run !== undefined;
        if (busy !== next) {
          busy = next;
          wake?.();
        }
      });
      try {
        while (!runtime.signal.aborted) {
          // A live-doc edge can arrive while the UI commit is in flight and no
          // waiter is installed. Compare against the state actually published.
          const publishedBusy = busy;
          const message = publishedBusy
            ? (PHRASES[Math.floor(Math.random() * PHRASES.length)] ??
              PHRASES[0])
            : undefined;
          await runtime.commit(async (tx) => {
            const ui = await tx.doc(DurableUI, runtime.conversationId);
            const put = (
              slot: string,
              value: Omit<UINotification, "id">,
            ): void => {
              ui.notifications[slot] = {
                id: `working-words:${slot}`,
                extensionScopeId: "repo:working-words",
                extensionDisplayName: "Working Words",
                ...value,
              };
            };
            put("status:working-words", {
              method: "setStatus",
              statusKey: "working-words",
              statusText: `shuffled · ${PHRASES.length} phrases`,
            });
            put("working:indicator", {
              method: "setWorkingIndicator",
              workingIndicator: {
                frames: ["·", "•", "●", "•"],
                intervalMs: 120,
              },
            });
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
            else if (publishedBusy !== busy) finish();
            else if (busy) timer = setTimeout(finish, 1500);
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

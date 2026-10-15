import {
  defineDoc,
  type AnyTask,
  type ConversationId,
  type Task,
  type TaskId,
  type Tx,
} from "@earendil-works/pi-durable";

// What the Oppi server needs of this extension: starting its ticker task when a conversation
// attaches. Shared by the server and the durable entry, so it imports nothing from
// `oppi/durable`, which only the extension loader resolves.

/** Name of the ticker task the durable entry registers. */
export const WORKING_WORDS_TASK = "oppi.working-words";

// `run` survives restart so elapsed time keeps counting from the real start.
export const WordsOwner = defineDoc<{
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

/**
 * Called at conversation attachment, before scheduling. Also repairs a stopped owner. `words`
 * is the installed `WORKING_WORDS_TASK` definition; pi-durable resolves tasks by name, so the
 * one installed now is the one that runs.
 */
export async function ensureWorkingWords(
  tx: Tx,
  id: ConversationId,
  words: AnyTask,
): Promise<void> {
  const state = await tx.doc(WordsOwner, id);
  const task = state.task === undefined ? undefined : await tx.task(state.task);
  if (!task || task.state.status === "terminal")
    state.task = await tx.createTask(
      words as unknown as Task<null, { phase: "watch" }, null, object>,
      null,
      {
        conversationId: id,
        ownership: { kind: "conversation" },
        background: true,
      },
    );
}

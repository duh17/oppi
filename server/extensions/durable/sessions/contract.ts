import {
  defineDoc,
  type AnyTask,
  type ConversationId,
  type EntryId,
  type Task,
  type TaskId,
  type Tx,
} from "@earendil-works/pi-durable";

// What the Oppi server needs of `oppi.sessions`: the children list, to restart the subagent
// pill's watcher when a conversation with children attaches. Shared by the server and the
// durable entry, so it imports nothing from `oppi/durable`, which only the extension loader
// resolves.

export type Child = {
  conversationId: ConversationId;
  sessionId?: string;
  /** The saved Agent it was spawned as. */
  agent?: string;
  /** The saved Agent's emoji, for the pill row's title. */
  icon?: string;
  /** Owned by an anchor: its answer comes back as a follow-up. Else owned by the spawning call. */
  background: boolean;
  /** Hands a background child its task and reports the answer: the task of its first input. */
  reporter?: TaskId;
  /**
   * Answers already reported to the parent, or returned by `wait`: several messages can end in
   * one answer, reported once. The commit that decides a report records its answer.
   */
  reported?: EntryId[];
  /** The reporter that reports this child's later answers, which no parent message caused. */
  follower?: TaskId;
};

/** The children of a conversation by name, and which spawn call made which, so a rerun finds it. */
export const Subagents = defineDoc<{
  children: Record<string, Child>;
  calls: Record<string, string>;
  /** The reporter each `send` call created, by the call's task id, so a rerun creates no second. */
  reporters?: Record<string, TaskId>;
  /** The pill's watcher (`SUBAGENT_WIDGET_TASK`), once a child exists. */
  widget?: TaskId;
}>({
  kind: "oppi.subagents",
  version: 1,
  scope: "conversation",
  history: "latest",
  // A fork of the parent starts without its children.
  fork: "initial",
  initial: () => ({ children: {}, calls: {} }),
  // Written by every spawn, send, and report for the conversation's lifetime, and `reported`
  // and `reporters` only grow; a base bounds its replay.
  checkpointWhen: (_value, _ops, { deltasSinceBase }) => deltasSinceBase >= 64,
});

/** Name of the pill watcher task the durable entry registers. */
export const SUBAGENT_WIDGET_TASK = "oppi.subagent-widget";

/**
 * Start the pill's watcher unless a live one exists. Called by `spawn` and, for a conversation
 * that already has children, at attachment: the idle store retires it as a ticker, and a Stop
 * fence aborts it. `widget` is the installed `SUBAGENT_WIDGET_TASK` definition.
 */
export async function ensureSubagentWidget(
  tx: Tx,
  id: ConversationId,
  widget: AnyTask,
): Promise<void> {
  const state = await tx.doc(Subagents, id);
  const task = state.widget === undefined ? undefined : await tx.task(state.widget);
  // A watcher marked for abort (the idle store retiring it) is about to end; replace it too.
  if (!task || task.state.status === "terminal" || task.abortRequested)
    state.widget = await tx.createTask(
      widget as unknown as Task<null, { phase: "watch" }, null, object>,
      null,
      {
        conversationId: id,
        ownership: { kind: "conversation" },
        background: true,
      },
    );
}

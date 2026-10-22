import type { ConversationId, TaskId, Tx } from "@earendil-works/pi-durable";
import { SESSION_REPORTER_TASK } from "oppi/durable";

// A child's pending wakers: `subagent` reads them from the host (`pendingWakers`) outside a
// commit, so some may have ended by the time a commit decides on them; the pill reads its
// reporters inside its commit and its job list just before (`wakingTasks` takes both). Either
// way a waker counts only while `liveTasks` finds it live in the deciding commit.

/** Whether a task has not ended: neither terminal nor completing. */
export function isLive(task: { state: { status: string } } | undefined): boolean {
  return (
    task !== undefined && task.state.status !== "terminal" && task.state.status !== "completing"
  );
}

/**
 * Conversation `id`'s own subagent reporters that have not ended, as a commit reads them: those
 * that wake it, not a parent's reporters for it (`liveReporters` in `durable.ts`).
 */
export async function wakingReporters(
  tx: Tx,
  id: ConversationId,
): Promise<Array<{ id: TaskId; conversationId?: ConversationId; kind: string }>> {
  const found = [];
  for (const status of ["pending", "running", "waiting", "sleeping"] as const) {
    let cursor;
    do {
      const page = await tx.scanTasks(
        { conversationId: id, kind: SESSION_REPORTER_TASK, status },
        50,
        cursor,
      );
      found.push(...page.items);
      cursor = page.next;
    } while (cursor);
  }
  return found;
}

/** Those of `ids` that are live tasks: the pending wakers that have not ended yet. */
export async function liveTasks(tx: Tx, ids: readonly TaskId[]): Promise<TaskId[]> {
  const live: TaskId[] = [];
  for (const id of ids) if (isLive(await tx.task(id))) live.push(id);
  return live;
}

import type { TaskId, Tx } from "@earendil-works/pi-durable";

// A child's pending wakers (`DurableSessionsHost.pendingWakers`) are read outside a commit, so
// some may have ended by the time a commit decides on them. Shared by `subagent` and its pill.

/** Whether a task has not ended: neither terminal nor completing. */
export function isLive(task: { state: { status: string } } | undefined): boolean {
  return (
    task !== undefined && task.state.status !== "terminal" && task.state.status !== "completing"
  );
}

/** Those of `ids` that are live tasks: the pending wakers that have not ended yet. */
export async function liveTasks(tx: Tx, ids: readonly TaskId[]): Promise<TaskId[]> {
  const live: TaskId[] = [];
  for (const id of ids) if (isLive(await tx.task(id))) live.push(id);
  return live;
}

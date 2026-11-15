import { defineDoc, type TaskId } from "@earendil-works/pi-durable";

// What others read of this extension. The Oppi server reads the job list, to keep a sandbox VM
// while a job still has undelivered output. `oppi.sessions` reads a child's jobs (`id`, `taskId`,
// `command`, `status`, and `endsOnItsOwn`) in `wakerJobs`, so `subagent wait` returns while only
// jobs still `running` remain and a child's interim answers are held while its jobs end on their
// own, and `wakingTasks` in `oppi/v1` reads `taskId`, `decision`, and
// `delivered` for a conversation's pending wakers (the idle timeout, `subagent wait`, and the
// subagent pill): a change here must keep those readers right. Shared by the server and the
// plugins, so it imports nothing from `oppi/v1`, which only the plugin host resolves.

export type Status = "running" | "completed" | "failed" | "cancelled" | "timed_out" | "interrupted";
export type Job = {
  id: string;
  taskId: TaskId;
  starter: TaskId;
  command: string;
  cwd: string;
  status: Status;
  startedAt: number;
  timeout?: number;
  decision: "waiting" | "foreground" | "background";
  deadline: number;
  foregroundOnly: boolean;
  cancelRequested: boolean;
  cancelTask?: TaskId;
  delivered: boolean;
  receiptId: string;
  exitCode: number | null;
};
/**
 * Whether running `job` ends on its own: it has a timeout, or it was started to be awaited (a
 * `bash` call that waits in the foreground before it moves to the background, so the agent
 * expected it to finish). A job started straight into the background (`background_job start`, a
 * command ending in `&`) with no timeout may be a dev server or a watcher that never ends.
 * `oppi.sessions` holds a child's answers while all its running jobs end on their own.
 */
export function endsOnItsOwn(job: Job): boolean {
  return job.timeout !== undefined || job.deadline > job.startedAt;
}

export const DurableJobs = defineDoc<{ seq: number; jobs: Job[] }>({
  kind: "oppi.background-jobs",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({ seq: 0, jobs: [] }),
  // Written at every job change for the conversation's lifetime; a base bounds its replay.
  checkpointWhen: (_value, _ops, { deltasSinceBase }) => deltasSinceBase >= 64,
});

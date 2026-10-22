import { defineDoc, type TaskId } from "@earendil-works/pi-durable";

// What others read of this extension. The Oppi server reads the job list, to keep a sandbox VM
// while a job still has undelivered output. `oppi.sessions` reads a child's jobs (`id`, `taskId`,
// `command`, `status`) in `runningJobsOnly`, so `subagent wait` returns while only jobs still
// `running` remain: a change here must keep that reader right. Shared by the server and the
// durable entries, so it imports nothing from `oppi/durable`, which only the extension loader
// resolves.

export type Status =
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "timed_out"
  | "interrupted";
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

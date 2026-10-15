import { defineDoc, type TaskId } from "@earendil-works/pi-durable";

// What the Oppi server reads of this extension: the job list, to keep a sandbox VM while a job
// still has undelivered output. Shared by the server and the durable entry, so it imports
// nothing from `oppi/durable`, which only the extension loader resolves.

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
});

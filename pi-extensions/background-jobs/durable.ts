import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import { withAbortSignal } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import {
  defineDoc,
  defineExtension,
  defineTask,
  defineTool,
  LiveDoc,
  section,
  type ConversationId,
  type DocumentObserver,
  type DocumentReader,
  type TaskId,
  type ToolExecutionApi,
  type Tx,
} from "@earendil-works/pi-durable";
import { DurableUI, DurableInputCards } from "../durable-ui.js";
import {
  BACKGROUND_POLICY,
  backgroundDisposition,
  backgroundPill,
  bashBackgroundAdvice,
  formatBackgroundNotice,
  formatForegroundResult,
  POLL_RULE,
} from "./jobs.js";
import { RESULT_GUIDANCE } from "./delivery.js";

type Status =
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "timed_out"
  | "interrupted";
type Job = {
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
  output: string;
  truncated: boolean;
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

async function publish(tx: Tx, id: ConversationId): Promise<void> {
  const jobs = (await tx.doc(DurableJobs, id)).jobs;
  const pill = backgroundPill(
    jobs
      .filter((job) => job.decision === "background" && !job.delivered)
      .map((job) => ({
        ...job,
        // The classic pill treats every non-success terminal outcome as an error.
        status: job.status === "interrupted" ? "failed" : job.status,
        backgrounded: true,
      })),
  );
  const ui = await tx.doc(DurableUI, id);
  const provenance = {
    extensionScopeId: "repo:background-jobs",
    extensionDisplayName: "Background Jobs",
  };
  ui.notifications["status:background-jobs"] = {
    id: "background-jobs:status",
    method: "setStatus",
    statusKey: "background-jobs",
    ...provenance,
    ...(pill ? { statusText: pill.status } : {}),
  };
  ui.notifications["widget:background-jobs"] = {
    id: "background-jobs:widget",
    method: "setWidget",
    widgetKey: "background-jobs",
    ...provenance,
    ...(pill
      ? {
          widgetLines: pill.lines,
          nativeSurface: {
            version: 1,
            id: "widget:background-jobs",
            source: "widget",
            presentation: {
              style: "surfacePanel",
              title: pill.title,
              subtitle: pill.subtitle,
            },
            blocks: [{ type: "activityList", id: "jobs", rows: pill.rows }],
            fallback: { lines: pill.summary },
          },
        }
      : {}),
  };
}

/** Watch acquisition + initial read closes the edge-before-listener race. */
async function waitForJob(
  api: DocumentReader & DocumentObserver,
  id: ConversationId,
  jobId: string,
  predicate: (job: Job) => boolean,
  context: Context,
  deadline?: number,
): Promise<Job> {
  const watch = await api.watchDoc(DurableJobs, id, context);
  if (!watch) throw new Error("Background jobs document disappeared");
  let cleanup = () => {};
  try {
    return await new Promise<Job>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const abort = () =>
        reject(context.abortSignal?.reason ?? new Error("Job wait aborted"));
      cleanup = () => {
        if (timer) clearTimeout(timer);
        context.abortSignal?.removeEventListener("abort", abort);
      };
      const take = (value: typeof watch.value, expired = false) => {
        const job = value?.jobs.find((item) => item.id === jobId);
        if (!job) reject(new Error(`No background job ${jobId}.`));
        else if (expired || predicate(job)) resolve(job);
      };
      watch.start(async (value) => take(value));
      context.abortSignal?.addEventListener("abort", abort, { once: true });
      take(watch.value);
      if (deadline !== undefined)
        timer = setTimeout(
          () => take(watch.value, true),
          Math.max(0, deadline - Date.now()),
        );
      if (context.abortSignal?.aborted) abort();
    });
  } finally {
    cleanup();
    await watch.stop();
  }
}

const INTERRUPTED_PROCESS_WARNING =
  "The previous host or guest process may still be running. Do not start it again until it is confirmed dead.";

function report(job: Job): {
  content: string;
  output: {
    kind: "terminal";
    offset: number;
    length: number;
    command: string;
    truncated: boolean;
  };
} {
  const headline =
    job.status === "interrupted"
      ? `Background job ${job.id} was interrupted by a host restart before it finished. It was not rerun. ${INTERRUPTED_PROCESS_WARNING}`
      : job.status === "cancelled"
        ? `Background job ${job.id} was cancelled.`
        : job.status === "timed_out"
          ? `Background job ${job.id} timed out after ${job.timeout} seconds and was killed.`
          : `Background job ${job.id} ${job.status === "completed" ? "finished" : "failed"} (exit ${job.exitCode}).`;
  const prefix = [
    RESULT_GUIDANCE,
    "",
    headline,
    "",
    `command: ${job.command}`,
    `cwd: ${job.cwd}`,
    "",
    ...(job.truncated
      ? [
          "Output truncated to the last 64000 characters. Earlier output was dropped.",
        ]
      : []),
    "output:",
    "",
  ].join("\n");
  const output = job.output.trimEnd() || "(no output)";
  return {
    content: `${prefix}${output}\n\nThis is the final result. Do not poll for this job.`,
    output: {
      kind: "terminal",
      offset: prefix.length,
      length: output.length,
      command: job.command,
      truncated: job.truncated,
    },
  };
}

const JobRunner = defineTask<
  { jobId: string },
  { phase: "run" } | { phase: "report" },
  null
>({
  name: "oppi.background-job",
  version: 1,
  initial: () => ({ phase: "run" }),
  phases: {
    async run(task, runtime, context) {
      const job = (await runtime.snapshot(
        DurableJobs,
        runtime.conversationId,
        context,
      ))!.jobs.find((item) => item.id === task.input.jobId)!;
      // Claim before any external side effect. Re-entering this phase after a
      // crash OR a clean close reports interruption, never retries the shell.
      const claim = randomUUID();
      const winner = await runtime.memo("exec-claim", claim, context);
      let status: Status = "interrupted";
      let output = "";
      let truncated = false;
      let exitCode: number | null = null;
      const appendOutput = (text: string): void => {
        output += text;
        if (output.length > 64_000) {
          output = output.slice(-64_000);
          truncated = true;
        }
      };
      if (winner === claim) {
        try {
          const env = await runtime.env(context);
          if (!env)
            throw new Error("No execution environment for background job");
          const cancel = new AbortController();
          const watch = await runtime.watchDoc(
            DurableJobs,
            runtime.conversationId,
            context,
          );
          const live = await runtime.watchDoc(
            LiveDoc,
            runtime.conversationId,
            context,
          );
          const changed = (value: { jobs: readonly Job[] } | null): void => {
            if (value?.jobs.find((item) => item.id === job.id)?.cancelRequested)
              cancel.abort();
          };
          const checkStop = async (): Promise<void> => {
            // Independent document watchers can deliver idle before promotion.
            // Read committed job ownership rather than a cached watcher frame.
            const latest = await runtime.snapshot(
              DurableJobs,
              runtime.conversationId,
              context,
            );
            if (
              latest?.jobs.find((item) => item.id === job.id)?.decision ===
              "waiting"
            )
              cancel.abort();
          };
          watch?.start(async (value) => changed(value));
          live?.start(async (value) => {
            if (value?.run === undefined) await checkStop();
          });
          changed(watch?.value ?? null);
          if (live?.value?.run === undefined) await checkStop();
          try {
            const result = await env.exec(
              job.command,
              {
                cwd: job.cwd,
                inheritEnv: true,
                ...(job.timeout === undefined ? {} : { timeout: job.timeout }),
                onOutput: appendOutput,
              },
              withAbortSignal(cancel.signal, context),
            );
            // Invocation cancellation is process detach/background abort, not an
            // exec result. Leave the claim and run checkpoint for restart/abort.
            if (runtime.signal.aborted) return;
            if (cancel.signal.aborted) status = "cancelled";
            else if (!result.ok) {
              status = result.error.code === "timeout" ? "timed_out" : "failed";
              appendOutput(`${output ? "\n" : ""}${result.error.message}`);
            } else {
              exitCode = result.value.exitCode;
              status = exitCode === 0 ? "completed" : "failed";
            }
          } finally {
            await watch?.stop();
            await live?.stop();
          }
        } catch (error) {
          if (runtime.signal.aborted) return;
          status = "failed";
          appendOutput(
            `${output ? "\n" : ""}${error instanceof Error ? error.message : String(error)}`,
          );
        }
      }
      await runtime.commit(async (tx) => {
        const current = (
          await tx.doc(DurableJobs, runtime.conversationId)
        ).jobs.find((item) => item.id === job.id)!;
        Object.assign(current, { status, output, truncated, exitCode });
        if (
          current.decision === "waiting" &&
          (await tx.doc(LiveDoc, runtime.conversationId)).run === undefined
        )
          current.decision = "foreground";
        await publish(tx, runtime.conversationId);
        return { status: "running", checkpoint: { phase: "report" } };
      }, context);
    },
    async report(task, runtime, context) {
      // Stop can win after exec completion but before the bash tool claims its
      // result. Retire that foreground result instead of waiting for a dead tool.
      const live = await runtime.watchDoc(
        LiveDoc,
        runtime.conversationId,
        context,
      );
      const retireStoppedForeground = async (): Promise<void> => {
        await runtime.commit(async (tx) => {
          const current = (
            await tx.doc(DurableJobs, runtime.conversationId)
          ).jobs.find((item) => item.id === task.input.jobId)!;
          if (current.decision === "waiting") current.decision = "foreground";
        }, context);
      };
      live?.start(async (value) => {
        if (value?.run === undefined) await retireStoppedForeground();
      });
      let job: Job;
      try {
        if (live?.value?.run === undefined) await retireStoppedForeground();
        job = await waitForJob(
          runtime,
          runtime.conversationId,
          task.input.jobId,
          (item) => item.decision !== "waiting",
          context,
        );
      } finally {
        await live?.stop();
      }
      const settle = async (tx: Tx) => {
        const current = (
          await tx.doc(DurableJobs, runtime.conversationId)
        ).jobs.find((item) => item.id === job.id)!;
        current.delivered = true;
        current.output = "";
        await publish(tx, runtime.conversationId);
        return {
          status: "terminal" as const,
          outcome: { status: "completed" as const, result: null },
        };
      };
      if (job.decision === "background") {
        const conversation = await runtime.conversation(
          runtime.conversationId,
          context,
        );
        if (!conversation)
          throw new Error("Background job conversation disappeared");
        // Follow pi-durable/test/examples/23-subagent-background.ts: one
        // stable submission identity, then retire the reporter. Admission owns
        // the bytes from here on. Stop may withdraw a queued report; replay must
        // not resurrect it under a new identity.
        const requestId = job.receiptId || `background-job:${job.id}`;
        const result = report(job);
        await runtime.commit(async (tx) => {
          const cards = await tx.doc(DurableInputCards, runtime.conversationId);
          cards.requests[requestId] ??= {
            title: `Background job ${job.id}`,
            output: result.output,
            status: job.status,
            body:
              job.status === "interrupted"
                ? `${job.command}\n${INTERRUPTED_PROCESS_WARNING}`
                : job.command,
            fields: [
              {
                label: "Result",
                value:
                  job.exitCode === null ? job.status : `Exit ${job.exitCode}`,
              },
            ],
            accent:
              job.status === "completed"
                ? "success"
                : job.status === "cancelled"
                  ? "warning"
                  : "error",
            at: runtime.now(),
          };
        }, context);
        await conversation.submit(
          {
            type: "input",
            content: result.content,
            whenBusy: "followUp",
            requestId,
          },
          context,
        );
      } else {
        // Foreground bash is replay-safe too. Keep its bytes until its starter
        // has committed the tool result, not merely selected foreground mode.
        await runtime.waitForTask(job.starter, context);
      }
      await runtime.commit(settle, context);
    },
  },
  async abort(task, runtime, context) {
    await runtime.commit(async (tx) => {
      const job = (await tx.doc(DurableJobs, runtime.conversationId)).jobs.find(
        (item) => item.id === task.input.jobId,
      )!;
      job.status = "cancelled";
      job.delivered = true;
      job.output = "";
      await publish(tx, runtime.conversationId);
      return { status: "terminal", outcome: { status: "aborted" } };
    }, context);
  },
});

function validateTimeout(timeout?: number): void {
  if (
    timeout !== undefined &&
    (!Number.isFinite(timeout) || timeout <= 0 || timeout > 2_147_483.647)
  )
    throw new Error(
      "Invalid timeout: must be a finite number of seconds greater than 0, at most 2147483.647.",
    );
}
async function start(
  api: ToolExecutionApi,
  command: string,
  timeout: number | undefined,
  waitMs: number,
  backgrounded: boolean,
  context: Context,
  foregroundPolicy?: "only" | "fallback",
): Promise<Job> {
  validateTimeout(timeout);
  if (!api.env) throw new Error("No execution environment for background job");
  return api.commit(async (tx) => {
    const state = await tx.doc(DurableJobs, api.conversationId);
    const existing = state.jobs.find((job) => job.starter === api.taskId);
    if (existing) return { ...existing };
    const full =
      state.jobs.filter(
        (job) => job.status === "running" && !job.foregroundOnly,
      ).length >= 8;
    if (full && !foregroundPolicy)
      throw new Error(
        "Too many background jobs are already running. Cancel one, or end your reply and wait to be woken. Do not poll.",
      );
    const id = `bash-${++state.seq}`;
    const taskId = await tx.createTask(
      JobRunner,
      { jobId: id },
      {
        ownership: { kind: "conversation" },
        background: true,
      },
    );
    const foregroundOnly =
      foregroundPolicy === "only" || (full && foregroundPolicy === "fallback");
    const startedAt = Date.now();
    const job: Job = {
      id,
      taskId,
      starter: api.taskId,
      command,
      cwd: api.env!.cwd,
      status: "running",
      startedAt,
      deadline: startedAt + waitMs,
      foregroundOnly,
      decision: backgrounded && !foregroundOnly ? "background" : "waiting",
      cancelRequested: false,
      delivered: false,
      receiptId: `background-job:${id}`,
      output: "",
      truncated: false,
      exitCode: null,
      ...(timeout === undefined ? {} : { timeout }),
    };
    state.jobs.push(job);
    await publish(tx, api.conversationId);
    return job;
  }, context);
}
function notice(job: Job) {
  return {
    content: [
      {
        type: "text" as const,
        text: `${formatBackgroundNotice(job.id).replace("in a batched follow-up, not one reply per job", "as a follow-up")}\n\ncommand: ${job.command}`,
      },
    ],
    details: { jobId: job.id, backgrounded: true, status: "running" },
  };
}
const backgroundJob = defineTool({
  name: "background_job",
  description:
    "Start or cancel a background shell job. start returns immediately; cancel stops a job, not a status check. Output arrives as a follow-up at a safe boundary. " +
    POLL_RULE,
  parameters: Type.Object({
    action: Type.Union([Type.Literal("start"), Type.Literal("cancel")]),
    command: Type.Optional(
      Type.String({ description: "Shell command. Required for start." }),
    ),
    timeout: Type.Optional(
      Type.Number({ description: "Kill the job after this many seconds." }),
    ),
    job_id: Type.Optional(
      Type.String({
        description: "Job id returned by start. Required for cancel.",
      }),
    ),
  }),
  replay: "safe",
  executionMode: "parallel",
  async execute(args, api, context) {
    if (args.action === "cancel") {
      if (!args.job_id) throw new Error("cancel requires job_id.");
      return api.commit(async (tx) => {
        const job = (await tx.doc(DurableJobs, api.conversationId)).jobs.find(
          (item) => item.id === args.job_id,
        );
        if (!job) throw new Error(`No background job ${args.job_id}.`);
        if (job.status !== "running" && job.cancelTask !== api.taskId)
          throw new Error(
            `${job.id} already finished. Its final result is delivered as a follow-up. Do not poll.`,
          );
        job.cancelRequested = true;
        job.cancelTask = api.taskId;
        return {
          content: [
            {
              type: "text" as const,
              text: `Cancel requested for ${job.id}. You will be told when it stops. Do not poll.`,
            },
          ],
          details: { jobId: job.id, cancelled: true },
        };
      }, context);
    }
    if (!args.command?.trim()) throw new Error("start requires command.");
    return notice(
      await start(api, args.command.trim(), args.timeout, 0, true, context),
    );
  },
});
const bash = defineTool({
  name: "bash",
  description: `Execute a bash command. ${BACKGROUND_POLICY.afterWait} ${BACKGROUND_POLICY.immediate} ${BACKGROUND_POLICY.stayForeground} ${POLL_RULE}`,
  parameters: Type.Object({
    command: Type.String({ description: "Bash command to execute" }),
    timeout: Type.Optional(
      Type.Number({
        description:
          "Timeout in seconds. A timeout of 1 second or less stays in the foreground.",
      }),
    ),
  }),
  replay: "safe",
  executionMode: "parallel",
  async execute(args, api, context) {
    if (!args.command.trim()) throw new Error("bash requires command.");
    const jobs = await api.snapshot(DurableJobs, api.conversationId, context);
    const advice = bashBackgroundAdvice(
      args.command,
      jobs?.jobs.some(
        (job) => job.status === "running" && job.starter !== api.taskId,
      ) ?? false,
    );
    if (advice) throw new Error(advice);
    const disposition = backgroundDisposition(args.command, {
      timeoutSeconds: args.timeout,
    });
    const job = await start(
      api,
      disposition.command,
      args.timeout,
      disposition.waitMs,
      disposition.mode === "immediate",
      context,
      disposition.mode === "foreground-only" ? "only" : "fallback",
    );
    if (job.decision === "background") return notice(job);
    await waitForJob(
      api,
      api.conversationId,
      job.id,
      (item) => item.status !== "running",
      context,
      job.foregroundOnly ? undefined : job.deadline,
    );
    const selected = await api.commit(async (tx) => {
      const current = (await tx.doc(DurableJobs, api.conversationId)).jobs.find(
        (item) => item.id === job.id,
      )!;
      // Decide against committed completion, not a stale watcher frame at the deadline.
      current.decision =
        current.status === "running" ? "background" : "foreground";
      await publish(tx, api.conversationId);
      return { ...current };
    }, context);
    if (selected.decision === "background") return notice(selected);
    const formatted =
      selected.status === "interrupted"
        ? {
            text: `Command interrupted by a host restart; it was not rerun. ${INTERRUPTED_PROCESS_WARNING}`,
            isError: true,
          }
        : formatForegroundResult(selected, {
            status: selected.status === "running" ? "failed" : selected.status,
            exitCode: selected.exitCode,
            timeoutSeconds: selected.timeout,
          });
    return {
      content: [{ type: "text" as const, text: formatted.text }],
      isError: formatted.isError,
      details: { jobId: selected.id, backgrounded: false },
      ...(selected.status === "interrupted"
        ? {
            diagnostics: [
              {
                severity: "error" as const,
                code: "interrupted",
                message: formatted.text,
              },
            ],
          }
        : {}),
    };
  },
});
export const DurableBackgroundJobs = defineExtension({
  name: "background-jobs",
  tools: [backgroundJob, bash],
  tasks: [JobRunner],
  sections: [
    section(
      "background-jobs",
      () =>
        `${BACKGROUND_POLICY.afterWait} ${BACKGROUND_POLICY.immediate} ${BACKGROUND_POLICY.stayForeground} ` +
        "background_job start backgrounds immediately. cancel only stops a job. Finished output is delivered as a follow-up. " +
        POLL_RULE +
        " Do not use bash or background_job for commands that read or print secrets. Use secret_run.",
    ),
  ],
});

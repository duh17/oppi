import { bool, lit, num, obj, oneOf, opt, str, union } from "@earendil-works/pi-schema";
import { withAbortSignal } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord/context";
import {
  defineDoc,
  defineTask,
  defineTool,
  LiveDoc,
  section,
  type ConversationId,
  type DocumentObserver,
  type DocumentReader,
  type TaskId,
  type TaskOutcome,
  type ToolExecutionApi,
  type ToolExecutionResult,
  type Tx,
} from "@earendil-works/pi-durable";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import {
  defineExtension,
  defineFacet,
  DurableInputCards,
  DurableUI,
  Extensions,
  oppiHost,
  type InternalTarget,
  type SchemeReader,
  type SchemeViewer,
  type SurfaceConversation,
  type SurfacePublisher,
} from "oppi/v1";
import {
  BACKGROUND_POLICY,
  backgroundDisposition,
  bashBackgroundAdvice,
  displayCommand,
  formatBackgroundNotice,
  formatForegroundResult,
  POLL_RULE,
} from "./jobs.js";
import { RESULT_GUIDANCE } from "./delivery.js";
import { DurableJobs, type Job, type Status } from "./contract.js";
import {
  commandTitle,
  jobsPanel,
  outputTail,
  requestJobStop,
  type PanelJob,
  type PanelState,
} from "./panel.js";

type Output = { output: string; truncated: boolean };
/**
 * Finished output, held from completion until delivery. Task-scoped to the
 * runner: pi-durable retires it and deletes its stored revisions when the
 * runner becomes terminal, so up to 64 KB per job never enters the job list's
 * history. Written in the same commit as the terminal status.
 */
const JobOutput = defineDoc<Output>({
  kind: "oppi.background-job-output",
  version: 1,
  scope: "task",
  initial: () => ({ output: "", truncated: false }),
  // Written once, when the job ends; the document retires with its task.
  checkpointWhen: () => false,
});
/** The run phase always writes it, and the runner stays live until delivery. */
async function jobOutput(
  api: DocumentReader,
  taskId: TaskId,
  context: Context,
): Promise<Readonly<Output>> {
  const value = await api.snapshot(JobOutput, taskId, context);
  if (!value) throw new Error(`Background job output for task ${taskId} is gone`);
  return value;
}

function jobById(jobs: readonly Job[], jobId: string): Job {
  const job = jobs.find((item) => item.id === jobId);
  if (!job) throw new Error(`No background job ${jobId}.`);
  return job;
}

// --- the panel --------------------------------------------------------------------------------
//
// The jobs panel is a v2 surface (`panel.ts`) in the live Session's own loop, so it has no saved
// record of its own: it is drawn from the job list in `DurableJobs`, which is. Every change to that
// list publishes it again, and so does a runner that resumes after a restart; the host draws it
// when the Session attaches (`surfaces` below). A conversation with no live Session has no panel.

/**
 * Before the panel, the pill was two notification slots in the conversation's `DurableUI`
 * document, and a client replays what that document holds when it attaches. A conversation saved
 * with a pill (a session from before the panel) would keep drawing it, so the first commit this
 * plugin makes for a conversation writes the cleared form of both slots, as the pill did when no
 * job was left. A cleared slot is left alone, so a conversation pays this once.
 */
async function retireLegacyPill(tx: Tx, id: ConversationId): Promise<void> {
  const provenance = {
    extensionScopeId: "repo:background-jobs",
    extensionDisplayName: "Background Jobs",
  };
  const { notifications } = await tx.doc(DurableUI, id);
  const status = notifications["status:background-jobs"];
  if (status?.statusText)
    notifications["status:background-jobs"] = {
      id: "background-jobs:status",
      method: "setStatus",
      statusKey: "background-jobs",
      ...provenance,
    };
  const widget = notifications["widget:background-jobs"];
  if (widget?.nativeSurface || widget?.widgetLines?.length)
    notifications["widget:background-jobs"] = {
      id: "background-jobs:widget",
      method: "setWidget",
      widgetKey: "background-jobs",
      ...provenance,
    };
}

/**
 * How often a running job's runner looks for new output to redraw (and, with a timeout, for a
 * minute of the countdown the panel lacks).
 */
const PANEL_LOOP_CHECK_MS = 1_000;
/**
 * The least time between a panel's last publish and a redraw for new output. It is the panel's
 * pace, not each job's: several jobs printing at once still redraw it at most this often.
 */
const LIVE_REDRAW_MS = 2_000;
/**
 * How much of the end of a running job's output the panel reads. A row shows at most 12 lines and
 * 480 characters, and a carriage-return progress line is redrawn in place, so this holds what is
 * drawn unless one line is longer.
 */
const LIVE_TAIL_CHARS = 16_384;

/** A running job's output as its runner holds it: the last 64,000 characters, and how many came before. */
type LiveOutput = { output: string; truncated: boolean; dropped: number };

/**
 * Running jobs' output, by runner task: a read of the string the runner already holds, so a live
 * read costs no copy and no write. Memory only: the terminal commit in `JobOutput` stays the only
 * write of a job's output, and nothing here reaches the transcript or the model.
 */
const liveOutputs = new Map<TaskId, () => LiveOutput>();

/** The Session loop of the conversation that runs `env`; none for a bare Harness or a stopped Session. */
function surfacesOf(env: ExecutionEnv | undefined): SurfacePublisher | undefined {
  try {
    return oppiHost().surfaces(env);
  } catch {
    return undefined;
  }
}

/** The execution env of a task, or none when its sandbox is not attached. */
async function envOf(
  runtime: { env(context: Context): Promise<ExecutionEnv | undefined> },
  context: Context,
): Promise<ExecutionEnv | undefined> {
  try {
    return await runtime.env(context);
  } catch {
    return undefined;
  }
}

/**
 * A conversation's panel state from its saved job list: the backgrounded jobs whose results are
 * not delivered yet, or nothing when none is left, which ends the panel. Ending is unconditional:
 * after `/reload` the Session may still show a panel this code never drew, and a dismissal of
 * nothing live is a no-op.
 */
async function loadPanel(
  conversation: SurfaceConversation,
  context: Context,
): Promise<PanelState | undefined> {
  const saved =
    (await conversation.snapshot(DurableJobs, conversation.conversationId, context))?.jobs ?? [];
  const shown: PanelJob[] = [];
  for (const job of saved) {
    if (job.decision !== "background" || job.delivered) continue;
    // A finished job's output waits in its runner's document until delivery.
    const output =
      job.status === "running"
        ? undefined
        : (await conversation.snapshot(JobOutput, job.taskId, context))?.output;
    const live = job.status === "running" ? liveOutputs.get(job.taskId)?.() : undefined;
    shown.push({
      id: job.id,
      command: job.command,
      cwd: job.cwd,
      ...(job.status === "running" && job.timeout !== undefined
        ? { timeoutAt: job.startedAt + job.timeout * 1000 }
        : {}),
      ...(live ? { output: live.output.slice(-LIVE_TAIL_CHARS), truncated: live.truncated } : {}),
      // The classic pill treats every non-success terminal outcome as an error.
      status: job.status === "interrupted" ? "failed" : job.status,
      startedAt: job.startedAt,
      ...(job.endedAt === undefined ? {} : { endedAt: job.endedAt }),
      ...(job.status === "running" ? {} : { exitCode: job.exitCode }),
      ...(output === undefined ? {} : { output }),
    });
  }
  return shown.length > 0 ? { jobs: shown, at: Date.now() } : undefined;
}

/** One panel for every conversation: `surface()` keeps each Session loop's own state. */
const panel = jobsPanel(loadPanel);

/**
 * Publish the panel of the conversation running `env` from its saved job list. A panel that
 * cannot be drawn must not fail the job it shows, so a failure here ends the publish and nothing
 * else.
 */
async function syncPanel(env: ExecutionEnv | undefined, context: Context): Promise<void> {
  const surfaces = surfacesOf(env);
  if (!surfaces) return;
  try {
    await panel.sync({ surfaces }, context);
  } catch {
    // The panel is display only; the next change publishes it again.
  }
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
  let cleanup = (): void => {};
  try {
    return await new Promise<Job>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const abort = (): void =>
        reject(context.abortSignal?.reason ?? new Error("Job wait aborted"));
      cleanup = () => {
        if (timer) clearTimeout(timer);
        context.abortSignal?.removeEventListener("abort", abort);
      };
      const take = (value: typeof watch.value | null, expired = false): void => {
        const job = value?.jobs.find((item) => item.id === jobId);
        if (!job) reject(new Error(`No background job ${jobId}.`));
        else if (expired || predicate(job)) resolve(job);
      };
      watch.start(async (call) => {
        if (call.kind === "value") take(call.retired ? null : call.value);
      });
      context.abortSignal?.addEventListener("abort", abort, { once: true });
      take(watch.value);
      if (deadline !== undefined)
        timer = setTimeout(() => take(watch.value, true), Math.max(0, deadline - Date.now()));
      if (context.abortSignal?.aborted) abort();
    });
  } finally {
    cleanup();
    await watch.stop();
  }
}

const INTERRUPTED_PROCESS_WARNING =
  "The previous host or guest process may still be running. Do not start it again until it is confirmed dead.";
const STOPPED_BY_RESTART_MESSAGE =
  "was stopped by the server restart; its process was killed and its output is lost — rerun it if still needed.";

/** Whether this store's previous close killed every job cleanly; false outside an Oppi server. */
async function wasCleanClose(
  api: DocumentReader & { readonly conversationId: ConversationId },
  context: Context,
): Promise<boolean> {
  try {
    return await oppiHost().storeClosedCleanly(api, context);
  } catch {
    return false;
  }
}

function report(
  job: Job,
  result: Output,
): {
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
      ? job.resumed === "stopped"
        ? `Background job ${job.id} ${STOPPED_BY_RESTART_MESSAGE}`
        : `Background job ${job.id} was interrupted by a host restart before it finished. It was not rerun. ${INTERRUPTED_PROCESS_WARNING}`
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
    ...(result.truncated
      ? ["Output truncated to the last 64000 characters. Earlier output was dropped."]
      : []),
    "output:",
    "",
  ].join("\n");
  const output = result.output.trimEnd() || "(no output)";
  return {
    content: `${prefix}${output}\n\nThis is the final result. Do not poll for this job.`,
    output: {
      kind: "terminal",
      offset: prefix.length,
      length: output.length,
      command: job.command,
      truncated: result.truncated,
    },
  };
}

const JobRunner = defineTask<{ jobId: string }, { phase: "run" } | { phase: "report" }, null>({
  name: "oppi.background-job",
  version: 1,
  initial: () => ({ phase: "run" }),
  phases: {
    async run(task, runtime, context) {
      const snapshot = await runtime.snapshot(DurableJobs, runtime.conversationId, context);
      if (!snapshot) throw new Error("Background jobs document disappeared");
      const job = jobById(snapshot.jobs, task.input.jobId);
      // Claim before any external side effect. Re-entering this phase after a
      // crash OR a clean close reports interruption, never retries the shell.
      const claim = globalThis.crypto.randomUUID();
      const winner = await runtime.memo("exec-claim", claim, context);
      let status: Status = "interrupted";
      let output = "";
      let truncated = false;
      /** Characters dropped from the front, so the app's viewer can append to what it holds. */
      let dropped = 0;
      let exitCode: number | null = null;
      let resumed: Job["resumed"];
      const appendOutput = (text: string): void => {
        output += text;
        if (output.length > 64_000) {
          dropped += output.length - 64_000;
          output = output.slice(-64_000);
          truncated = true;
        }
      };
      // The panel and the app's viewer read this run's output while it runs. The entry stays until
      // the terminal commit, so neither draws this job as running without its output.
      const liveOutput = (): string => output.slice(-LIVE_TAIL_CHARS);
      liveOutputs.set(runtime.taskId, () => ({ output, truncated, dropped }));
      try {
        if (winner === claim) {
          try {
            const env = await runtime.env(context);
            if (!env) throw new Error("No execution environment for background job");
            const cancel = new AbortController();
            const watch = await runtime.watchDoc(DurableJobs, runtime.conversationId, context);
            const live = await runtime.watchDoc(LiveDoc, runtime.conversationId, context);
            // Only a backgrounded job is a row in the panel; a foreground one's output never redraws it.
            let shown = job.decision === "background";
            const changed = (value: { jobs: readonly Job[] } | null): void => {
              const current = value?.jobs.find((item) => item.id === job.id);
              shown = current?.decision === "background";
              if (current?.cancelRequested) cancel.abort();
            };
            const checkStop = async (): Promise<void> => {
              // Independent document watchers can deliver idle before promotion.
              // Read committed job ownership rather than a cached watcher frame.
              const latest = await runtime.snapshot(DurableJobs, runtime.conversationId, context);
              if (latest?.jobs.find((item) => item.id === job.id)?.decision === "waiting")
                cancel.abort();
            };
            watch?.start(async (call) => {
              if (call.kind === "value") changed(call.retired ? null : call.value);
            });
            live?.start(async (call) => {
              if (call.kind === "value" && (call.retired || call.value.run === undefined))
                await checkStop();
            });
            changed(watch?.value ?? null);
            if (live?.value?.run === undefined) await checkStop();
            // The job's age is a client-ticked node and needs no redraw. Only the static "times out
            // in Nm" caption does, so a job with a timeout is drawn again each minute.
            const minutesLeft = (): number =>
              job.timeout === undefined
                ? 0
                : Math.floor((job.startedAt + job.timeout * 1000 - Date.now()) / 60_000);
            let drawnMinutes = minutesLeft();
            // New output redraws the panel once it has gone LIVE_REDRAW_MS unpublished, and only
            // when this job's row would change. The same tick paces it: a job adds no timer.
            // What the Session's loop shows now is the panel's last state there: its read time and
            // this job's row.
            const outputChanged = (drawn: PanelState | undefined): boolean =>
              shown &&
              drawn !== undefined &&
              Date.now() - drawn.at >= LIVE_REDRAW_MS &&
              (outputTail(liveOutput()) ?? "") !==
                (outputTail(drawn.jobs.find((item) => item.id === job.id)?.output) ?? "");
            // A Session that stops and starts again while this job runs has a new loop, which the
            // host draws when it attaches; this tick redraws whichever loop is current.
            const watchLoop = setInterval(() => {
              const surfaces = surfacesOf(env);
              if (!surfaces) return;
              const minutes = minutesLeft();
              if (minutes !== drawnMinutes || outputChanged(panel.current({ surfaces }))) {
                drawnMinutes = minutes;
                void syncPanel(env, context);
              }
            }, PANEL_LOOP_CHECK_MS);
            watchLoop.unref?.();
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
              clearInterval(watchLoop);
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
        } else if (await wasCleanClose(runtime, context)) {
          resumed = "stopped";
        }
        await runtime.commit(async (tx) => {
          const current = jobById((await tx.doc(DurableJobs, runtime.conversationId)).jobs, job.id);
          Object.assign(current, {
            status,
            exitCode,
            endedAt: runtime.now(),
            ...(dropped > 0 ? { dropped } : {}),
            ...(resumed === undefined ? {} : { resumed }),
          });
          Object.assign(await tx.doc(JobOutput, runtime.taskId), {
            output,
            truncated,
          });
          if (
            current.decision === "waiting" &&
            (await tx.doc(LiveDoc, runtime.conversationId)).run === undefined
          )
            current.decision = "foreground";
          await retireLegacyPill(tx, runtime.conversationId);
          return { status: "running", checkpoint: { phase: "report" } };
        }, context);
      } finally {
        liveOutputs.delete(runtime.taskId);
      }
    },
    async report(task, runtime, context) {
      // Stop can win after exec completion but before the bash tool claims its
      // result. Retire that foreground result instead of waiting for a dead tool.
      const live = await runtime.watchDoc(LiveDoc, runtime.conversationId, context);
      const retireStoppedForeground = async (): Promise<void> => {
        await runtime.commit(async (tx) => {
          const current = jobById(
            (await tx.doc(DurableJobs, runtime.conversationId)).jobs,
            task.input.jobId,
          );
          if (current.decision === "waiting") current.decision = "foreground";
        }, context);
      };
      live?.start(async (call) => {
        if (call.kind === "value" && (call.retired || call.value.run === undefined))
          await retireStoppedForeground();
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
      const settle = async (
        tx: Tx,
      ): Promise<{ status: "terminal"; outcome: TaskOutcome<null> }> => {
        const current = jobById((await tx.doc(DurableJobs, runtime.conversationId)).jobs, job.id);
        // Terminal settlement retires this runner's JobOutput document.
        current.delivered = true;
        await retireLegacyPill(tx, runtime.conversationId);
        return {
          status: "terminal",
          outcome: { status: "completed", result: null },
        };
      };
      if (job.decision === "background") {
        // The result waits for delivery, so the panel shows it: after a restart this is where the
        // panel comes back for a job that finished or was interrupted while the server was down.
        await syncPanel(await envOf(runtime, context), context);
        const conversation = await runtime.conversation(runtime.conversationId, context);
        if (!conversation) throw new Error("Background job conversation disappeared");
        // Follow pi-durable/test/examples/23-subagent-background.ts: one
        // stable submission identity, then retire the reporter. Admission owns
        // the bytes from here on. Stop may withdraw a queued report; replay must
        // not resurrect it under a new identity.
        const requestId = job.receiptId || `background-job:${job.id}`;
        const result = report(job, await jobOutput(runtime, runtime.taskId, context));
        const cardNote =
          job.status === "interrupted"
            ? job.resumed === "stopped"
              ? "Stopped by the server restart; its process was killed and its output is lost."
              : INTERRUPTED_PROCESS_WARNING
            : undefined;
        await runtime.commit(async (tx) => {
          const cards = await tx.doc(DurableInputCards, runtime.conversationId);
          cards.requests[requestId] ??= {
            title: `Background job ${job.id}`,
            output: result.output,
            status: job.status,
            body: cardNote === undefined ? job.command : `${job.command}\n${cardNote}`,
            fields: [
              {
                label: "Result",
                value: job.exitCode === null ? job.status : `Exit ${job.exitCode}`,
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
      if (job.decision === "background") await syncPanel(await envOf(runtime, context), context);
    },
  },
  async abort(task, runtime, context) {
    await runtime.commit(async (tx) => {
      const job = jobById(
        (await tx.doc(DurableJobs, runtime.conversationId)).jobs,
        task.input.jobId,
      );
      job.status = "cancelled";
      job.endedAt ??= runtime.now();
      job.delivered = true;
      await retireLegacyPill(tx, runtime.conversationId);
      return { status: "terminal", outcome: { status: "aborted" } };
    }, context);
    await syncPanel(await envOf(runtime, context), context);
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
  const env = api.env;
  if (!env) throw new Error("No execution environment for background job");
  const started = await api.commit(async (tx) => {
    const state = await tx.doc(DurableJobs, api.conversationId);
    const existing = state.jobs.find((job) => job.starter === api.taskId);
    if (existing) return { ...existing };
    const full =
      state.jobs.filter((job) => job.status === "running" && !job.foregroundOnly).length >= 8;
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
    const foregroundOnly = foregroundPolicy === "only" || (full && foregroundPolicy === "fallback");
    const startedAt = Date.now();
    const job: Job = {
      id,
      taskId,
      starter: api.taskId,
      command,
      cwd: env.cwd,
      status: "running",
      startedAt,
      deadline: startedAt + waitMs,
      foregroundOnly,
      decision: backgrounded && !foregroundOnly ? "background" : "waiting",
      cancelRequested: false,
      delivered: false,
      receiptId: `background-job:${id}`,
      exitCode: null,
      ...(timeout === undefined ? {} : { timeout }),
    };
    state.jobs.push(job);
    await retireLegacyPill(tx, api.conversationId);
    return job;
  }, context);
  if (started.decision === "background") await syncPanel(env, context);
  return started;
}
function notice(job: Job): ToolExecutionResult {
  return {
    output: [
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
  parameters: obj({
    action: oneOf(["start", "cancel"]),
    command: opt(str({ description: "Shell command. Required for start." })),
    timeout: opt(num({ description: "Kill the job after this many seconds." })),
    job_id: opt(str({ description: "Job id returned by start. Required for cancel." })),
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
          output: [
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
    return notice(await start(api, args.command.trim(), args.timeout, 0, true, context));
  },
});
/**
 * What a program that calls `bash` (a code mode script, `api.executeTool`) receives. A finished
 * command matches pi-durable's own `bash`, so scripts check `exitCode`; a command that moved to
 * the background gives its job instead, whose result arrives later as a follow-up.
 */
const bashStructuredOutput = union([
  obj({
    output: str({
      description: "Combined stdout and stderr, at most the last 64000 characters",
    }),
    truncated: bool({ description: "Whether earlier output was dropped" }),
    exitCode: num(),
  }),
  obj({ jobId: str(), backgrounded: lit(true) }),
]);
function backgrounded(job: Job): ToolExecutionResult {
  return {
    ...notice(job),
    structuredOutput: { jobId: job.id, backgrounded: true },
  };
}
const bash = defineTool({
  name: "bash",
  description: `Execute a bash command. ${BACKGROUND_POLICY.afterWait} ${BACKGROUND_POLICY.immediate} ${BACKGROUND_POLICY.stayForeground} ${POLL_RULE}`,
  parameters: obj(
    {
      command: str({ description: "Bash command to execute" }),
      timeout: opt(
        num({
          description: "Timeout in seconds. A timeout of 1 second or less stays in the foreground.",
        }),
      ),
    },
    // Open: models carry other harnesses' flags (`run_in_background`, `background`) into
    // bash calls, and such a call still runs, under this tool's own backgrounding rules.
    { open: true },
  ),
  structuredOutputSchema: bashStructuredOutput,
  replay: "safe",
  executionMode: "parallel",
  async execute(args, api, context) {
    if (!args.command.trim()) throw new Error("bash requires command.");
    const jobs = await api.snapshot(DurableJobs, api.conversationId, context);
    const advice = bashBackgroundAdvice(
      args.command,
      jobs?.jobs.some((job) => job.status === "running" && job.starter !== api.taskId) ?? false,
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
    if (job.decision === "background") return backgrounded(job);
    await waitForJob(
      api,
      api.conversationId,
      job.id,
      (item) => item.status !== "running",
      context,
      job.foregroundOnly ? undefined : job.deadline,
    );
    const selected = await api.commit(async (tx) => {
      const current = jobById((await tx.doc(DurableJobs, api.conversationId)).jobs, job.id);
      // Decide against committed completion, not a stale watcher frame at the deadline.
      current.decision = current.status === "running" ? "background" : "foreground";
      await retireLegacyPill(tx, api.conversationId);
      return { ...current };
    }, context);
    if (selected.decision === "background") {
      await syncPanel(api.env, context);
      return backgrounded(selected);
    }
    // The runner's report phase waits for this tool task before it settles, so
    // its JobOutput is still current here.
    const output = await jobOutput(api, selected.taskId, context);
    const formatted =
      selected.status === "interrupted"
        ? {
            text:
              selected.resumed === "stopped"
                ? `Command ${STOPPED_BY_RESTART_MESSAGE}`
                : `Command interrupted by a host restart; it was not rerun. ${INTERRUPTED_PROCESS_WARNING}`,
            isError: true,
          }
        : formatForegroundResult(output, {
            status: selected.status === "running" ? "failed" : selected.status,
            exitCode: selected.exitCode,
            timeoutSeconds: selected.timeout,
          });
    // As pi-durable's `bash`: a command that exited is an error result only for a nonzero
    // code, with an `exit_code` diagnostic, and programs get its output and code either way.
    const exitCode =
      selected.status === "completed" || selected.status === "failed" ? selected.exitCode : null;
    const diagnostics =
      selected.status === "interrupted"
        ? [
            {
              severity: "error" as const,
              code: "interrupted",
              message: formatted.text,
            },
          ]
        : exitCode !== null && exitCode !== 0
          ? [
              {
                severity: "error" as const,
                code: "exit_code",
                message: `Command exited with code ${exitCode}`,
              },
            ]
          : [];
    return {
      output: [{ type: "text" as const, text: formatted.text }],
      isError: formatted.isError,
      details: { jobId: selected.id, backgrounded: false },
      ...(exitCode === null
        ? {}
        : {
            structuredOutput: {
              output: output.output,
              truncated: output.truncated,
              exitCode,
            },
          }),
      ...(diagnostics.length ? { diagnostics } : {}),
    };
  },
});
// `proc://` for `read`: this conversation's background jobs, as `background_job` reports them. A
// running job shows its live tail, a finished one its output until it is delivered (the delivery
// carries it from then on). Read only; `background_job cancel` stops a job.
const readProc: SchemeReader = async (target, api, context) => {
  if (target.path !== "" && target.path !== "/")
    throw new Error(`proc://${target.id} has no sub-paths. Read proc://${target.id}.`);
  const jobs = (await api.snapshot(DurableJobs, api.conversationId, context))?.jobs ?? [];
  const shown = jobs.filter((job) => job.decision !== "foreground");
  if (target.id === "")
    return shown.length === 0
      ? "No background jobs."
      : `Background jobs (read proc://<id> for output):\n${shown
          .map((job) => `${job.id}  ${job.status}  ${displayCommand(job.command)}`)
          .join("\n")}`;
  const id = target.pick(
    "background job",
    shown.map((job) => job.id),
  );
  const job = jobById(shown, id);
  const state =
    job.status === "running" ? "running" : `${job.status} (exit ${job.exitCode ?? "none"})`;
  const head = `${job.id}  ${state}\ncommand: ${job.command}\ncwd: ${job.cwd}\nstarted: ${new Date(job.startedAt).toISOString()}`;
  if (job.status === "running") {
    const live = liveOutputs.get(job.taskId)?.();
    return `${head}\n\n${live ? `Output${live.truncated ? " (latest part)" : ""}:\n${live.output}` : "No output yet."}`;
  }
  const saved = job.delivered
    ? undefined
    : await api.snapshot(JobOutput, job.taskId, context).catch(() => undefined);
  return `${head}\n\n${
    saved
      ? saved.output
      : "Its result was handed to the conversation as a follow-up: it is in the transcript once the current turn ends. A Stop before that discards it. The output is not kept here."
  }`;
};

/** The backgrounded job `target` names, as `read` lists them: a foreground call is not one. */
async function procJob(
  target: InternalTarget,
  conversation: SurfaceConversation,
  context: Context,
): Promise<Job> {
  const jobs =
    (await conversation.snapshot(DurableJobs, conversation.conversationId, context))?.jobs ?? [];
  const shown = jobs.filter((job) => job.decision !== "foreground");
  return jobById(
    shown,
    target.pick(
      "background job",
      shown.map((job) => job.id),
    ),
  );
}

/** How a job's state reads at the top of its view: the word, and its tone. */
function procStatus(job: Job): { text: string; tone: "accent" | "success" | "warning" | "danger" } {
  switch (job.status) {
    case "running":
      return { text: "Running", tone: "accent" };
    case "completed":
      return { text: "Done", tone: "success" };
    case "cancelled":
      return { text: "Stopped", tone: "warning" };
    case "timed_out":
      return { text: "Timed out", tone: "warning" };
    case "interrupted":
      return { text: "Interrupted", tone: "danger" };
    case "failed":
      return { text: job.exitCode === null ? "Failed" : `Exit ${job.exitCode}`, tone: "danger" };
  }
}

// `proc://` in the app: one job's status, where and when it ran, its command, and its output. A
// running job's output is the runner's live window; a finished one's is saved until its result is
// delivered, and then the result card in the transcript holds it.
const viewProc: SchemeViewer = {
  async view(target, conversation, context) {
    const job = await procJob(target, conversation, context);
    const running = job.status === "running";
    const live = running ? liveOutputs.get(job.taskId)?.() : undefined;
    const saved =
      running || job.delivered
        ? undefined
        : await conversation.snapshot(JobOutput, job.taskId, context);
    const timeoutAt =
      running && job.timeout !== undefined ? job.startedAt + job.timeout * 1000 : undefined;
    return {
      id: job.id,
      title: commandTitle(job.command),
      status: {
        ...procStatus(job),
        live: running,
        startedAt: job.startedAt,
        ...(job.endedAt === undefined ? {} : { endedAt: job.endedAt }),
      },
      facts: [
        { label: "Folder", value: job.cwd },
        { label: "Started", time: job.startedAt },
        ...(job.endedAt === undefined ? [] : [{ label: "Ended", time: job.endedAt }]),
        ...(timeoutAt === undefined ? [] : [{ label: "Times out", time: timeoutAt }]),
        { label: "Job", value: job.id },
      ],
      command: job.command,
      output: live
        ? { text: live.output, dropped: live.dropped, truncated: live.truncated }
        : saved
          ? { text: saved.output, dropped: job.dropped ?? 0, truncated: saved.truncated }
          : job.delivered && job.decision === "background"
            ? { inputCard: job.receiptId || `background-job:${job.id}`, dropped: job.dropped ?? 0 }
            : { text: "" },
      stoppable: running,
    };
  },
  async stop(target, conversation, context) {
    const job = await procJob(target, conversation, context);
    return (await requestJobStop(conversation, job.id, context))
      ? undefined
      : `${job.id} is not running.`;
  },
};

export const DurableBackgroundJobs = defineExtension({
  name: "background-jobs",
  runtimes: ["host", "sandbox"],
  tools: [backgroundJob, bash],
  tasks: [JobRunner],
  // Drawn again from the job list when a Session attaches, after a server restart too.
  surfaces: [panel],
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

/**
 * The plugin facet. A built-in: the plugin host skips the owner's copy of this package (a link
 * in `~/.pi/agent/extensions`) and lets its classic ID stand for this one.
 */
export default defineFacet((_host, self) => {
  oppiHost().files.internalUrls.register("proc", readProc, viewProc);
  return self.contribute(Extensions, DurableBackgroundJobs);
});

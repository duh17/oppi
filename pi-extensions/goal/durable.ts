import { Type, type Static } from "typebox";
import type { JsonValue } from "@earendil-works/chord";
import {
  defineDoc,
  defineEntry,
  defineExtension,
  defineTask,
  defineTool,
  section,
  hook,
  CompactionTask,
  LiveDoc,
  InboxDoc,
  UserEntry,
  GenerationTask,
  type TaskId,
  type SubmissionId,
  type Tx,
  type ConversationId,
  type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { DurableUI } from "../durable-ui.js";

// Deliberately independent of the classic factory (and its TUI/SDK imports).
// Forks start without a goal: inherited transcript evidence must not launch a
// second autonomous runner. Oppi currently does not expose Durable forks.
type TaskStatus = "pending" | "in_progress" | "completed";
type GoalStatus = "active" | "paused" | "blocked" | "complete";
type GoalTask = {
  id: string;
  title: string;
  status: TaskStatus;
  startedAt?: string;
  completedAt?: string;
  elapsedMs?: number;
};
type Goal = {
  id: string;
  status: GoalStatus;
  objective: string;
  summary?: string;
  blocker?: string;
  tasks: GoalTask[];
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
  revision: number;
  continuationCount: number;
  maxContinuations: number;
};
export const GoalDoc = defineDoc<{
  goal?: Goal;
  runner?: TaskId;
  nextAttempt?: number;
}>({
  kind: "oppi.goal",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({}),
});
const GoalSnapshot = defineEntry<{ version: 1; goal: Goal }>("oppi-goal");
const Decision = defineEntry<{
  goalId: string;
  decision: string;
  reason: string;
  continuation: number;
  requestId?: string;
}>("oppi-goal-continuation");
const TaskStatusSchema = Type.Union([
  Type.Literal("pending"),
  Type.Literal("in_progress"),
  Type.Literal("completed"),
]);
const TaskSchema = Type.Object({
  id: Type.Optional(
    Type.String({ description: "Stable task id. Generated when omitted." }),
  ),
  title: Type.String({ description: "Concrete task title." }),
  status: Type.Optional(TaskStatusSchema),
});
const TaskUpdateSchema = Type.Object({
  id: Type.Optional(Type.String({ description: "Task id to update." })),
  index: Type.Optional(
    Type.Number({ minimum: 1, description: "One-based task index." }),
  ),
  title: Type.Optional(
    Type.String({ description: "New or replacement task title." }),
  ),
  status: Type.Optional(TaskStatusSchema),
});
const BudgetSchema = Type.Number({
  minimum: 1,
  maximum: 100,
  description: "Maximum automatic continuation turns before the runner blocks.",
});
const CreateParams = Type.Object({
  objective: Type.String({
    description: "User-facing objective for the autonomous goal.",
  }),
  summary: Type.Optional(
    Type.String({ description: "Initial state or context summary." }),
  ),
  tasks: Type.Optional(Type.Array(TaskSchema)),
  max_continuations: Type.Optional(BudgetSchema),
  replace: Type.Optional(
    Type.Boolean({
      description: "Replace an existing active goal. Default false.",
    }),
  ),
});
const UpdateParams = Type.Object({
  goal_id: Type.Optional(
    Type.String({
      description: "Current goal id. If provided, stale ids are rejected.",
    }),
  ),
  status: Type.Optional(
    Type.Union([
      Type.Literal("active"),
      Type.Literal("paused"),
      Type.Literal("blocked"),
      Type.Literal("complete"),
    ]),
  ),
  objective: Type.Optional(
    Type.String({ description: "Updated objective text." }),
  ),
  summary: Type.Optional(
    Type.String({ description: "Current progress summary." }),
  ),
  blocker: Type.Optional(
    Type.String({ description: "Why the goal cannot continue." }),
  ),
  tasks: Type.Optional(
    Type.Array(TaskSchema, { description: "Replace the task checklist." }),
  ),
  task_updates: Type.Optional(
    Type.Array(TaskUpdateSchema, {
      description: "Patch specific tasks by id or one-based index.",
    }),
  ),
  max_continuations: Type.Optional(BudgetSchema),
  note: Type.Optional(
    Type.String({ description: "Short note explaining this update." }),
  ),
});
const text = (value: string | undefined): string | undefined =>
  value?.trim() || undefined;
const budget = (value: number): number =>
  Math.max(1, Math.min(100, Math.floor(value)));
const iso = (): string => new Date().toISOString();
function tasks(values: Static<typeof TaskSchema>[] = []): GoalTask[] {
  return values.flatMap((value) => {
    const title = text(value.title);
    return title
      ? [
          {
            id: text(value.id) ?? `task-${crypto.randomUUID().slice(0, 8)}`,
            title,
            status: value.status ?? "pending",
          },
        ]
      : [];
  });
}
function elapsed(start: string | undefined, end?: string): number | undefined {
  if (!start) return undefined;
  const result = (end ? Date.parse(end) : Date.now()) - Date.parse(start);
  return Number.isFinite(result) && result >= 0 ? result : undefined;
}
function duration(ms: number | undefined): string | undefined {
  if (ms === undefined || ms < 1000) return undefined;
  const s = Math.floor(ms / 1000);
  if (s >= 86400)
    return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
  if (s >= 3600)
    return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  if (s >= 60) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${s}s`;
}
function timed(
  previous: GoalTask[],
  next: GoalTask[],
  timestamp: string,
): GoalTask[] {
  return next.map((task) => {
    const old = previous.find(
      (candidate) => candidate.id === task.id || candidate.title === task.title,
    );
    const startedAt = task.startedAt ?? old?.startedAt;
    const completedAt = task.completedAt ?? old?.completedAt;
    if (task.status === "in_progress")
      return {
        ...task,
        startedAt: startedAt ?? timestamp,
        completedAt: undefined,
        elapsedMs: undefined,
      };
    if (task.status === "completed") {
      const start = startedAt ?? timestamp;
      const end = completedAt ?? timestamp;
      return {
        ...task,
        startedAt: start,
        completedAt: end,
        elapsedMs: task.elapsedMs ?? old?.elapsedMs ?? elapsed(start, end) ?? 0,
      };
    }
    return {
      ...task,
      startedAt: undefined,
      completedAt: undefined,
      elapsedMs: undefined,
    };
  });
}
function enforceCompletion(goal: Goal): void {
  const unfinished = goal.tasks.filter((task) => task.status !== "completed");
  if (goal.status !== "complete" || !unfinished.length) return;
  goal.status = "active";
  goal.blocker = undefined;
  goal.completedAt = undefined;
  const note = `Completion deferred: unfinished tasks remain (${unfinished
    .slice(0, 5)
    .map((task) => task.title)
    .join(
      ", ",
    )}${unfinished.length > 5 ? `, +${unfinished.length - 5} more` : ""}).`;
  if (!goal.summary?.includes(note))
    goal.summary = [goal.summary, note].filter(Boolean).join("\n\n");
}
function update(goal: Goal, params: Static<typeof UpdateParams>): Goal {
  const next: Goal = {
    ...goal,
    tasks: goal.tasks.map((task) => ({ ...task })),
  };
  const objective = text(params.objective);
  if (objective) next.objective = objective;
  if (params.status) next.status = params.status;
  if (params.summary !== undefined) next.summary = text(params.summary);
  if (params.blocker !== undefined) next.blocker = text(params.blocker);
  if (params.tasks !== undefined) next.tasks = tasks(params.tasks);
  for (const patch of params.task_updates ?? []) {
    const id = text(patch.id);
    const title = text(patch.title);
    const index = id
      ? next.tasks.findIndex((task) => task.id === id)
      : patch.index !== undefined
        ? Math.floor(patch.index) - 1
        : -1;
    const target = next.tasks[index];
    if (target)
      next.tasks[index] = {
        ...target,
        ...(title ? { title } : {}),
        ...(patch.status ? { status: patch.status } : {}),
      };
    else if (title)
      next.tasks.push({
        id: id ?? `task-${crypto.randomUUID().slice(0, 8)}`,
        title,
        status: patch.status ?? "pending",
      });
  }
  next.updatedAt = iso();
  next.tasks = timed(goal.tasks, next.tasks, next.updatedAt);
  if (params.max_continuations !== undefined)
    next.maxContinuations = budget(params.max_continuations);
  if (next.status === "active" && params.blocker === undefined)
    next.blocker = undefined;
  if (next.status === "blocked" && !next.blocker)
    next.blocker = text(params.note) ?? "Goal is blocked.";
  enforceCompletion(next);
  if (next.status === "complete" && !next.summary)
    next.summary = text(params.note) ?? "Goal completed.";
  next.completedAt =
    next.status === "complete"
      ? (next.completedAt ?? next.updatedAt)
      : undefined;
  next.revision += 1;
  return next;
}
function label(status: GoalStatus): string {
  return status.charAt(0).toUpperCase() + status.slice(1);
}
function format(goal?: Goal): string {
  if (!goal) return "No active goal.";
  const lines = [
    `Goal ${goal.id} · ${label(goal.status)}`,
    `Objective: ${goal.objective}`,
    `Continuations: ${goal.continuationCount}/${goal.maxContinuations}`,
    `Elapsed: ${duration(elapsed(goal.createdAt, goal.status === "active" ? undefined : (goal.completedAt ?? goal.updatedAt))) ?? "0s"}`,
  ];
  if (goal.summary) lines.push(`Summary: ${goal.summary}`);
  if (goal.blocker) lines.push(`Blocker: ${goal.blocker}`);
  if (goal.tasks.length) {
    lines.push("Tasks:");
    for (const [index, task] of goal.tasks.entries()) {
      const time = duration(
        task.elapsedMs ?? elapsed(task.startedAt, task.completedAt),
      );
      lines.push(
        `  ${index + 1}. [${task.status}] ${task.title}${time ? ` · ${time}` : ""}`,
      );
    }
  }
  return lines.join("\n");
}
function prompt(goal: Goal): string {
  return [
    "## Active goal runner",
    "This session has an active durable goal. Keep working toward it until it is complete, blocked, paused by the user, or the continuation budget stops the runner.",
    "Use get_goal when you need the current state. Use update_goal whenever progress, tasks, blockers, or terminal status changes.",
    "The continuation budget is a safety cap, not a target to spend. Complete early when the whole objective is actually done and verified; otherwise keep the goal active and continue making concrete progress.",
    "Before status=complete, audit the objective against real evidence: inspect the relevant files, command output, tests, docs, or runtime state; map every explicit requirement to evidence; treat uncertainty as incomplete.",
    "Set status=blocked with a concrete blocker when you cannot continue without user input, credentials, unavailable services, or a risky decision.",
    "Keep status=active when useful autonomous work remains, evidence is weak, or any listed task is still pending or in progress.",
    format(goal),
  ].join("\n\n");
}
function continuation(goal: Goal): string {
  return [
    "Continue the active goal autonomously.",
    "",
    format(goal),
    "",
    "Instructions:",
    "- Pick the next concrete step and execute it with the available tools.",
    "- Do not wait for the user unless the goal is blocked by a real decision, missing access, or an unsafe action.",
    "- Avoid repeating the same check without new information; if the obvious work looks done, broaden the audit or run stronger validation.",
    "- Call update_goal when you complete work, learn something important, update tasks, or become blocked.",
    "- Before status=complete, perform a completion audit: restate the deliverables, verify each explicit requirement with real artifacts, and make sure pending tasks are completed or intentionally removed with an explanation.",
    "- If the goal is finished and verified, call update_goal with status=complete and a concise evidence-backed summary.",
    "- If you cannot continue, call update_goal with status=blocked and a concrete blocker.",
  ].join("\n");
}
function jsonGoal(goal: Goal): Goal {
  // Chord documents require strict JSON; classic optional fields use undefined.
  return JSON.parse(JSON.stringify(goal)) as Goal;
}
function result(goal?: Goal): {
  content: Array<{ type: "text"; text: string }>;
  details: { status: "ok"; goal?: Goal };
} {
  return {
    content: [{ type: "text" as const, text: format(goal) }],
    details: { status: "ok", ...(goal ? { goal: jsonGoal(goal) } : {}) },
  };
}
function error(message: string): {
  content: Array<{ type: "text"; text: string }>;
  details: { status: "error"; error: string };
  isError: true;
} {
  return {
    content: [{ type: "text" as const, text: message }],
    details: { status: "error", error: message },
    isError: true,
  };
}
async function persist(
  tx: Tx,
  id: ConversationId,
  goal: Goal,
  running: boolean,
): Promise<void> {
  goal = jsonGoal(goal);
  (await tx.doc(GoalDoc, id)).goal = goal;
  await tx.appendEntry(GoalSnapshot, id, { data: { version: 1, goal } });
  await publishUi(tx, id, goal, running);
}
async function publishUi(
  tx: Tx,
  id: ConversationId,
  goal: Goal,
  running: boolean,
): Promise<void> {
  const runnerLabel =
    goal.status === "active" && !running
      ? "Active · Runner stopped"
      : label(goal.status);
  const visible = goal.status !== "complete";
  const ui = await tx.doc(DurableUI, id);
  const provenance = {
    extensionScopeId: "repo:goal",
    extensionDisplayName: "Goal",
  };
  ui.notifications["status:goal"] = {
    id: "goal:status",
    method: "setStatus",
    statusKey: "goal",
    ...provenance,
    ...(visible
      ? {
          statusText: `goal: ${runnerLabel} ${goal.continuationCount}/${goal.maxContinuations}`,
        }
      : {}),
  };
  const widgetLines = visible ? format(goal).split("\n") : [];
  const states = {
    active: "running",
    paused: "inactive",
    blocked: "warning",
    complete: "success",
    pending: "queued",
    in_progress: "running",
    completed: "success",
  };
  const blocks: JsonValue[] = [
    {
      type: "activityList",
      id: "goal-status",
      rows: [
        {
          id: goal.id,
          title: goal.objective,
          subtitle: `${runnerLabel} · ${goal.continuationCount}/${goal.maxContinuations} continuations`,
          state:
            goal.status === "active" && !running
              ? "inactive"
              : states[goal.status],
          children: goal.tasks.map((task) => ({
            id: task.id,
            title: task.title,
            subtitle: task.status.replaceAll("_", " "),
            state: states[task.status],
          })),
        },
      ],
    },
  ];
  if (goal.summary)
    blocks.push({ type: "markdown", markdown: `**Summary:** ${goal.summary}` });
  if (goal.blocker)
    blocks.push({ type: "markdown", markdown: `**Blocker:** ${goal.blocker}` });
  ui.notifications["widget:goal"] = {
    id: "goal:widget",
    method: "setWidget",
    widgetKey: "goal",
    widgetPlacement: "aboveEditor",
    widgetLines,
    ...provenance,
    ...(visible
      ? {
          nativeSurface: {
            version: 1,
            id: "widget:goal",
            source: "widget",
            presentation: {
              style: "surfacePanel",
              title: "Goal",
              subtitle: runnerLabel,
            },
            blocks,
            fallback: { lines: widgetLines },
          },
        }
      : {}),
  };
}
async function decision(
  tx: Tx,
  id: ConversationId,
  goal: Pick<Goal, "id" | "continuationCount">,
  action: string,
  reason: string,
  requestId?: string,
): Promise<void> {
  await tx.appendEntry(Decision, id, {
    // A passive user message uses the phone's existing message renderer without
    // inventing a tool call or impersonating a model response. It starts no run.
    model: [
      {
        role: "user",
        content: `[Goal runner] ${action}: ${reason}`,
        timestamp: Date.now(),
      },
    ],
    data: {
      goalId: goal.id,
      decision: action,
      reason,
      continuation: goal.continuationCount,
      ...(requestId ? { requestId } : {}),
    },
  });
}

type Checkpoint =
  | { phase: "watch" }
  | { phase: "compacted"; goalId: string; compactions: TaskId[] }
  | {
      phase: "submit";
      goalId: string;
      count: number;
      requestId: string;
      content: string;
    };
// Not background: user Abort/Stop must cancel the loop. Host busy/idle and
// auto-stop are driven by pi.live.run, not by this observer. A same-run onYield
// continuation would hide every settled boundary from that host policy.
const Runner = defineTask<null, Checkpoint, null>({
  name: "oppi.goal-runner",
  version: 1,
  initial: () => ({ phase: "watch" }),
  abort: async (task, runtime, context) => {
    await runtime.commit(async (tx) => {
      const plan =
        task.state.checkpoint.phase === "submit"
          ? task.state.checkpoint
          : undefined;
      const existing = plan
        ? await tx.submissionByRequest(runtime.conversationId, plan.requestId)
        : undefined;
      const entry =
        existing?.entry === undefined
          ? undefined
          : await tx.entry(existing.entry);
      const inbox = await tx.doc(InboxDoc, runtime.conversationId);
      const queued = existing
        ? inbox.items.find((item) => item.id === existing.id)
        : undefined;
      const content =
        entry?.model?.find((message) => message.role === "user")?.content ??
        (queued && queued.mode !== "write" ? queued.content : undefined);
      const owned =
        plan && existing?.type === "input" && content === plan.content;
      let goal = (await tx.doc(GoalDoc, runtime.conversationId)).goal;
      if (owned && existing?.status === "queued") {
        const index = inbox.items.findIndex((item) => item.id === existing.id);
        if (index >= 0) inbox.items.splice(index, 1);
        tx.settleSubmission(existing.id, {
          status: "unanswered",
          reason: "aborted",
        });
      }
      if (
        plan &&
        (!owned || existing?.status === "queued") &&
        goal?.id === plan.goalId &&
        goal.continuationCount === plan.count
      ) {
        goal = {
          ...goal,
          continuationCount: Math.max(0, goal.continuationCount - 1),
          revision: goal.revision + 1,
          updatedAt: iso(),
        };
        await persist(tx, runtime.conversationId, goal, false);
        await decision(
          tx,
          runtime.conversationId,
          goal,
          "skip",
          "Abort/Stop withdrew the unconsumed continuation reservation.",
          plan.requestId,
        );
      }
      if (goal) {
        await publishUi(tx, runtime.conversationId, goal, false);
        await decision(
          tx,
          runtime.conversationId,
          goal,
          "stop",
          "Goal runner cancelled by Abort/Stop; state retained.",
        );
      }
      return { status: "terminal", outcome: { status: "aborted" } };
    }, context);
  },
  phases: {
    async watch(_task, runtime, context) {
      // Watches are acquired before checking: no lost idle/goal-update edge.
      const live = await runtime.watchDoc(
        LiveDoc,
        runtime.conversationId,
        context,
      );
      const goals = await runtime.watchDoc(
        GoalDoc,
        runtime.conversationId,
        context,
      );
      const inboxWatch = await runtime.watchDoc(
        InboxDoc,
        runtime.conversationId,
        context,
      );
      if (!live || !goals || !inboxWatch)
        throw new Error("Goal runner requires conversation state");
      let wake: (() => void) | undefined;
      let changed = false;
      const compactions = new Set<TaskId>(
        live.value?.compactions?.map((item) => item.taskId),
      );
      let busy = live.value?.run !== undefined;
      let compactIds = (live.value?.compactions ?? [])
        .map((item) => item.taskId)
        .join(",");
      let queued = (inboxWatch.value?.items.length ?? 0) > 0;
      const notify = async (): Promise<void> => {
        changed = true;
        wake?.();
      };
      live.start(async (value) => {
        const nextBusy = value?.run !== undefined;
        const nextIds = (value?.compactions ?? [])
          .map((item) => item.taskId)
          .join(",");
        if (nextBusy === busy && nextIds === compactIds) return;
        busy = nextBusy;
        compactIds = nextIds;
        for (const item of value?.compactions ?? [])
          compactions.add(item.taskId);
        await notify();
      });
      inboxWatch.start(async (value) => {
        const nextQueued = (value?.items.length ?? 0) > 0;
        if (queued === nextQueued) return;
        queued = nextQueued;
        await notify();
      });
      goals.start(notify);
      try {
        while (!runtime.signal.aborted) {
          changed = false;
          let ready = false;
          await runtime.commit(async (tx) => {
            const state = await tx.doc(GoalDoc, runtime.conversationId);
            const goal = state.goal;
            if (!goal || goal.status !== "active") {
              if (goal) {
                await publishUi(tx, runtime.conversationId, goal, false);
                await decision(
                  tx,
                  runtime.conversationId,
                  goal,
                  "stop",
                  goal.blocker ?? `Goal is ${goal.status}.`,
                );
              }
              ready = true;
              return {
                status: "terminal",
                outcome: { status: "completed", result: null },
              };
            }
            const activity = await tx.doc(LiveDoc, runtime.conversationId);
            const inbox = await tx.doc(InboxDoc, runtime.conversationId);
            for (const item of activity.compactions ?? [])
              compactions.add(item.taskId);
            if (compactions.size) {
              const ids = [...compactions];
              await decision(
                tx,
                runtime.conversationId,
                goal,
                "wait",
                "Waiting for context compaction before another continuation.",
              );
              ready = true;
              return {
                status: "waiting",
                checkpoint: {
                  phase: "compacted",
                  goalId: goal.id,
                  compactions: ids,
                },
                on: ids,
                policy: "allSettled",
              };
            }
            if (activity.run || inbox.items.length) return;
            if (goal.continuationCount >= goal.maxContinuations) {
              const blocked = update(goal, {
                status: "blocked",
                blocker: `Continuation budget exhausted (${goal.continuationCount}/${goal.maxContinuations}).`,
              });
              await persist(tx, runtime.conversationId, blocked, false);
              await decision(
                tx,
                runtime.conversationId,
                blocked,
                "stop",
                blocked.blocker ?? "Continuation budget exhausted.",
              );
              ready = true;
              return {
                status: "terminal",
                outcome: { status: "completed", result: null },
              };
            }
            const next = {
              ...goal,
              continuationCount: goal.continuationCount + 1,
              updatedAt: iso(),
              revision: goal.revision + 1,
            };
            // A skipped reservation may reuse its budget count, but must never
            // reuse the request ID of a withdrawn submission.
            state.nextAttempt = (state.nextAttempt ?? 0) + 1;
            const requestId = `oppi-goal:${next.id}:${next.continuationCount}:${state.nextAttempt}`;
            await persist(tx, runtime.conversationId, next, true);
            await decision(
              tx,
              runtime.conversationId,
              next,
              "continue",
              "Run settled; no pending messages or compaction; active goal has budget remaining.",
              requestId,
            );
            ready = true;
            return {
              status: "running",
              checkpoint: {
                phase: "submit",
                goalId: next.id,
                count: next.continuationCount,
                requestId,
                content: continuation(next),
              },
            };
          }, context);
          if (ready) return;
          await new Promise<void>((resolve, reject) => {
            const abort = (): void => {
              cleanup();
              reject(runtime.signal.reason);
            };
            const cleanup = (): void => {
              runtime.signal.removeEventListener("abort", abort);
              wake = undefined;
            };
            wake = () => {
              cleanup();
              resolve();
            };
            runtime.signal.addEventListener("abort", abort, { once: true });
            if (runtime.signal.aborted) abort();
            else if (changed) wake();
          });
        }
      } finally {
        await live.stop();
        await goals.stop();
        await inboxWatch.stop();
      }
    },
    async compacted(task, runtime, context) {
      const outcomes = await runtime.outcomes(
        task.state.checkpoint.compactions,
        context,
      );
      await runtime.commit(async (tx) => {
        const goal = (await tx.doc(GoalDoc, runtime.conversationId)).goal;
        if (
          goal?.id === task.state.checkpoint.goalId &&
          goal.status === "active"
        ) {
          const failed = outcomes.find(
            (outcome) => outcome.status !== "completed",
          );
          if (failed) {
            const reason = `Context compaction failed: ${"error" in failed ? (failed.error?.message ?? failed.status) : failed.status}`;
            const blocked = update(goal, {
              status: "blocked",
              blocker: reason,
            });
            await persist(tx, runtime.conversationId, blocked, false);
            await decision(tx, runtime.conversationId, blocked, "stop", reason);
            return {
              status: "terminal",
              outcome: { status: "completed", result: null },
            };
          }
          await decision(
            tx,
            runtime.conversationId,
            goal,
            "resume",
            "Context compaction completed; goal state retained outside the transcript.",
          );
        }
        return { status: "running", checkpoint: { phase: "watch" } };
      }, context);
    },
    async submit(task, runtime, context) {
      const plan = task.state.checkpoint;
      await runtime.commit(async (tx) => {
        const existing = await tx.submissionByRequest(
          runtime.conversationId,
          plan.requestId,
        );
        const entry =
          existing?.entry === undefined
            ? undefined
            : await tx.entry(existing.entry);
        const state = await tx.doc(GoalDoc, runtime.conversationId);
        const live = await tx.doc(LiveDoc, runtime.conversationId);
        const inbox = await tx.doc(InboxDoc, runtime.conversationId);
        const queued = existing
          ? inbox.items.find((item) => item.id === existing.id)
          : undefined;
        const content =
          entry?.model?.find((message) => message.role === "user")?.content ??
          (queued && queued.mode !== "write" ? queued.content : undefined);
        const goal = state.goal;
        const rollback = async (
          reason: string,
          conflict = false,
        ): Promise<void> => {
          if (existing?.status === "queued" && !conflict) {
            const index = inbox.items.findIndex(
              (item) => item.id === existing.id,
            );
            if (index >= 0) inbox.items.splice(index, 1);
            tx.settleSubmission(existing.id, {
              status: "unanswered",
              reason: "aborted",
            });
          }
          if (
            goal?.id === plan.goalId &&
            goal.continuationCount === plan.count
          ) {
            const next = {
              ...goal,
              continuationCount: Math.max(0, goal.continuationCount - 1),
              revision: goal.revision + 1,
              updatedAt: iso(),
            };
            const restored = conflict
              ? update(next, { status: "blocked", blocker: reason })
              : next;
            await persist(tx, runtime.conversationId, restored, !conflict);
          }
          await decision(
            tx,
            runtime.conversationId,
            { id: plan.goalId, continuationCount: plan.count },
            "skip",
            reason,
            plan.requestId,
          );
        };
        if (
          existing &&
          (existing.type !== "input" || content !== plan.content)
        ) {
          await rollback(
            "Continuation requestId conflict: stored content differs from the planned continuation.",
            true,
          );
          return {
            status: "terminal",
            outcome: { status: "completed", result: null },
          };
        }
        if (
          (!existing || existing.status === "queued") &&
          (goal?.id !== plan.goalId ||
            goal.status !== "active" ||
            live.run ||
            inbox.items.some((item) => item.id !== existing?.id) ||
            live.compactions?.length)
        ) {
          await rollback(
            goal?.id !== plan.goalId || goal.status !== "active"
              ? "Goal changed or stopped before continuation admission."
              : "User work or compaction arrived before continuation admission; continuation withdrawn without spending budget.",
          );
          return { status: "running", checkpoint: { phase: "watch" } };
        }
        if (existing && existing.status !== "queued") {
          // Only our exact content can be a replay. New admission below is
          // idle-only and atomically creates a run with this sole placed input.
          return { status: "running", checkpoint: { phase: "watch" } };
        }
        // Conversation.submit cannot combine a goal-state check with admission.
        // Use the public Tx surface for this narrow idle-only admission (no
        // queue/boundary policy): goal, inbox and run cannot change between the
        // check and placing this single input. This also closes restart races.
        const user = await tx.appendEntry(UserEntry, runtime.conversationId, {
          model: [
            { role: "user", content: plan.content, timestamp: runtime.now() },
          ],
        });
        let submissionId: SubmissionId;
        if (existing) {
          // Recover an exact-content sole queued input without a new request.
          const index = inbox.items.findIndex(
            (item) => item.id === existing.id,
          );
          if (index >= 0) inbox.items.splice(index, 1);
          tx.placeSubmission(existing.id, user.id);
          submissionId = existing.id;
        } else {
          submissionId = (
            await tx.createSubmission({
              conversationId: runtime.conversationId,
              type: "input",
              requestId: plan.requestId,
              status: "placed",
              entry: user.id,
            })
          ).id;
        }
        live.run = {
          taskId: await tx.createTask(
            GenerationTask,
            {},
            {
              conversationId: runtime.conversationId,
              ownership: { kind: "conversation" },
            },
          ),
          inputs: [submissionId],
        };
        return { status: "running", checkpoint: { phase: "watch" } };
      }, context);
    },
  },
});
async function ensureRunner(
  tx: Tx,
  id: ConversationId,
  arm: boolean,
): Promise<boolean> {
  const doc = await tx.doc(GoalDoc, id);
  const old = doc.runner === undefined ? undefined : await tx.task(doc.runner);
  if (
    arm &&
    doc.goal?.status === "active" &&
    (!old || old.state.status === "terminal")
  )
    doc.runner = await tx.createTask(Runner, null, {
      conversationId: id,
      ownership: { kind: "conversation" },
    });
  return (
    (arm && doc.runner !== old?.id) ||
    !!(old && old.state.status !== "terminal" && !old.abortRequested)
  );
}
const ToolReceipt = defineDoc<{
  result?: ReturnType<typeof result> | ReturnType<typeof error>;
}>({
  kind: "oppi.goal-tool-receipt",
  version: 1,
  scope: "task",
  initial: () => ({}),
});
// Receipt and the document write must share a commit: replay after the state write
// but before the tool result must not repeat updates or create a new goal ID.
async function mutate(
  api: ToolExecutionApi,
  context: Parameters<ToolExecutionApi["commit"]>[1],
  change: (goal?: Goal) => ReturnType<typeof result> | ReturnType<typeof error>,
  arm: boolean,
): Promise<ReturnType<typeof result> | ReturnType<typeof error>> {
  return api.commit(async (tx) => {
    const receipt = await tx.doc(ToolReceipt, api.taskId);
    if (receipt.result) return receipt.result;
    const doc = await tx.doc(GoalDoc, api.conversationId);
    const outcome = change(doc.goal);
    // Read the runner before any table writes (Durable enforces ReadAfterWrite).
    const running = await ensureRunnerBeforeWrite(
      tx,
      api.conversationId,
      outcome,
      arm,
    );
    if ("goal" in outcome.details && outcome.details.goal) {
      await persist(tx, api.conversationId, outcome.details.goal, running);
      await decision(
        tx,
        api.conversationId,
        outcome.details.goal,
        "update",
        outcome.details.goal.blocker ??
          `Goal is ${outcome.details.goal.status}; revision ${outcome.details.goal.revision}.`,
      );
    }
    receipt.result = outcome;
    return outcome;
  }, context);
}
async function ensureRunnerBeforeWrite(
  tx: Tx,
  id: ConversationId,
  outcome: ReturnType<typeof result> | ReturnType<typeof error>,
  arm: boolean,
): Promise<boolean> {
  if (!("goal" in outcome.details) || !outcome.details.goal) return false;
  const doc = await tx.doc(GoalDoc, id);
  doc.goal = outcome.details.goal;
  return ensureRunner(tx, id, arm);
}
const get = defineTool({
  name: "get_goal",
  description: "Return the current durable session goal, if one exists.",
  parameters: Type.Object({}),
  replay: "safe",
  async execute(_args, api, context) {
    return result(
      (await api.snapshot(GoalDoc, api.conversationId, context))?.goal,
    );
  },
});
const create = defineTool({
  name: "create_goal",
  description:
    "Create a durable autonomous goal for this session. The extension will keep triggering continuation turns while the goal remains active. Use only when the user explicitly asks for a durable or autonomous multi-turn objective. Do not replace an active goal unless the user clearly asked to change goals or replace=true is appropriate.",
  parameters: CreateParams,
  executionMode: "sequential",
  replay: "safe",
  async execute(args, api, context) {
    return mutate(
      api,
      context,
      (old) => {
        if (old?.status === "active" && !args.replace)
          return error(
            `Active goal already exists (${old.id}). Use update_goal or pass replace=true if replacement is intended.`,
          );
        const objective = text(args.objective);
        if (!objective) return error("Goal objective cannot be empty.");
        const timestamp = iso();
        return result({
          id: crypto.randomUUID(),
          status: "active",
          objective,
          summary: text(args.summary),
          tasks: timed([], tasks(args.tasks), timestamp),
          createdAt: timestamp,
          updatedAt: timestamp,
          revision: 1,
          continuationCount: 0,
          maxContinuations: budget(args.max_continuations ?? 25),
        });
      },
      true,
    );
  },
});
const patch = defineTool({
  name: "update_goal",
  description:
    "Update the durable session goal status, progress summary, blocker, checklist, or continuation budget. Use after meaningful progress. Set status=complete only after the objective is finished and validated against real evidence. Unfinished tasks defer completion and keep the runner active. Set status=blocked with a concrete blocker when user input or external state changes are required. Keep status=active while useful work remains or evidence is weak.",
  parameters: UpdateParams,
  executionMode: "sequential",
  replay: "safe",
  async execute(args, api, context) {
    return mutate(
      api,
      context,
      (goal) => {
        if (!goal) return error("No goal exists. Use create_goal first.");
        if (args.goal_id && args.goal_id !== goal.id)
          return error(
            `Stale goal id: expected ${goal.id}, received ${args.goal_id}.`,
          );
        return result(update(goal, args));
      },
      args.status === "active",
    );
  },
});
export const DurableGoal = defineExtension({
  name: "goal",
  tools: [get, create, patch],
  tasks: [Runner],
  sections: [
    section("goal", async (input, context) => {
      const goal = (
        await input.read.snapshot(GoalDoc, input.conversationId, context)
      )?.goal;
      return goal?.status === "active" ? prompt(goal) : undefined;
    }),
  ],
  hooks: [
    hook(CompactionTask, {
      async beforeCompact(_compaction, api, context) {
        const goal = (await api.snapshot(GoalDoc, api.conversationId, context))
          ?.goal;
        if (goal)
          await api.memo(
            "oppi-goal-before-compact",
            { version: 1, goal },
            context,
          );
        // No summary override: preserve the host's summarizer and its evidence. Goal
        // state is outside the compacted transcript and reinjected by the section.
        return undefined;
      },
    }),
  ],
});

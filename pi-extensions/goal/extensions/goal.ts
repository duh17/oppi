import type {
  ExtensionAPI,
  ExtensionContext,
  ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { randomUUID } from "node:crypto";

const CUSTOM_TYPE = "oppi-goal";
const CONTINUATION_TYPE = "oppi-goal-continuation";
const WIDGET_KEY = "goal";
const DEFAULT_MAX_CONTINUATIONS = 25;
const DEFAULT_CONTINUATION_DELAY_MS = 100;
const DEFAULT_MAX_CONTEXT_PERCENT = 95;
const DEFAULT_WIDGET_TIMER_MS = 30_000;

type GoalStatus = "active" | "paused" | "blocked" | "complete" | "cleared";
type TaskStatus = "pending" | "in_progress" | "completed";

interface GoalTask {
  id: string;
  title: string;
  status: TaskStatus;
  startedAt?: string;
  completedAt?: string;
  elapsedMs?: number;
}

interface SessionGoal {
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
}

interface GoalSnapshot {
  version: 1;
  goal: SessionGoal;
}

export interface GoalExtensionOptions {
  defaultMaxContinuations?: number;
  continuationDelayMs?: number;
  maxContextPercent?: number;
  widgetTimerMs?: number;
}

const TaskStatusSchema = Type.Union([
  Type.Literal("pending"),
  Type.Literal("in_progress"),
  Type.Literal("completed"),
]);

const GoalStatusSchema = Type.Union([
  Type.Literal("active"),
  Type.Literal("paused"),
  Type.Literal("blocked"),
  Type.Literal("complete"),
]);

const GoalTaskSchema = Type.Object({
  id: Type.Optional(
    Type.String({ description: "Stable task id. Generated when omitted." }),
  ),
  title: Type.String({ description: "Concrete task title." }),
  status: Type.Optional(TaskStatusSchema),
});

const GoalTaskUpdateSchema = Type.Object({
  id: Type.Optional(Type.String({ description: "Task id to update." })),
  index: Type.Optional(
    Type.Number({ minimum: 1, description: "One-based task index." }),
  ),
  title: Type.Optional(
    Type.String({ description: "New or replacement task title." }),
  ),
  status: Type.Optional(TaskStatusSchema),
});

const GetGoalParams = Type.Object({});

const CreateGoalParams = Type.Object({
  objective: Type.String({
    description: "User-facing objective for the autonomous goal.",
  }),
  summary: Type.Optional(
    Type.String({ description: "Initial state or context summary." }),
  ),
  tasks: Type.Optional(Type.Array(GoalTaskSchema)),
  max_continuations: Type.Optional(
    Type.Number({
      minimum: 1,
      maximum: 100,
      description:
        "Maximum automatic continuation turns before the runner blocks.",
    }),
  ),
  replace: Type.Optional(
    Type.Boolean({
      description: "Replace an existing active goal. Default false.",
    }),
  ),
});

const UpdateGoalParams = Type.Object({
  goal_id: Type.Optional(
    Type.String({
      description: "Current goal id. If provided, stale ids are rejected.",
    }),
  ),
  status: Type.Optional(GoalStatusSchema),
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
    Type.Array(GoalTaskSchema, { description: "Replace the task checklist." }),
  ),
  task_updates: Type.Optional(
    Type.Array(GoalTaskUpdateSchema, {
      description: "Patch specific tasks by id or one-based index.",
    }),
  ),
  max_continuations: Type.Optional(
    Type.Number({
      minimum: 1,
      maximum: 100,
      description: "Updated continuation budget.",
    }),
  ),
  note: Type.Optional(
    Type.String({ description: "Short note explaining this update." }),
  ),
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nowIso(): string {
  return new Date().toISOString();
}

function normalizeText(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function normalizeIso(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? value : undefined;
}

function normalizeElapsedMs(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    return undefined;
  }
  return Math.floor(value);
}

function normalizeMaxContinuations(value: unknown, fallback: number): number {
  const numeric =
    typeof value === "number" && Number.isFinite(value) ? value : fallback;
  return Math.max(1, Math.min(100, Math.floor(numeric)));
}

function isGoalStatus(value: unknown): value is GoalStatus {
  return (
    value === "active" ||
    value === "paused" ||
    value === "blocked" ||
    value === "complete" ||
    value === "cleared"
  );
}

function isTaskStatus(value: unknown): value is TaskStatus {
  return (
    value === "pending" || value === "in_progress" || value === "completed"
  );
}

function taskId(): string {
  return `task-${randomUUID().slice(0, 8)}`;
}

function normalizeTask(value: unknown): GoalTask | undefined {
  if (!isRecord(value)) return undefined;
  const title = typeof value.title === "string" ? value.title.trim() : "";
  if (!title) return undefined;
  return {
    id:
      typeof value.id === "string" && value.id.trim()
        ? value.id.trim()
        : taskId(),
    title,
    status: isTaskStatus(value.status) ? value.status : "pending",
    startedAt: normalizeIso(value.startedAt),
    completedAt: normalizeIso(value.completedAt),
    elapsedMs: normalizeElapsedMs(value.elapsedMs),
  };
}

function normalizeTasks(values: unknown): GoalTask[] {
  if (!Array.isArray(values)) return [];
  return values.flatMap((value) => {
    const task = normalizeTask(value);
    return task ? [task] : [];
  });
}

function cloneGoal(goal: SessionGoal): SessionGoal {
  return {
    ...goal,
    tasks: goal.tasks.map((task) => ({ ...task })),
  };
}

function normalizeLoadedGoal(value: unknown): SessionGoal | undefined {
  if (!isRecord(value)) return undefined;
  const id =
    typeof value.id === "string" && value.id.trim()
      ? value.id.trim()
      : undefined;
  const objective =
    typeof value.objective === "string" && value.objective.trim()
      ? value.objective.trim()
      : undefined;
  if (!id || !objective || !isGoalStatus(value.status)) return undefined;
  const createdAt =
    typeof value.createdAt === "string" ? value.createdAt : nowIso();
  const updatedAt =
    typeof value.updatedAt === "string" ? value.updatedAt : createdAt;
  const revision =
    typeof value.revision === "number" && Number.isFinite(value.revision)
      ? Math.max(1, Math.floor(value.revision))
      : 1;
  const continuationCount =
    typeof value.continuationCount === "number" &&
    Number.isFinite(value.continuationCount)
      ? Math.max(0, Math.floor(value.continuationCount))
      : 0;
  const maxContinuations = normalizeMaxContinuations(
    value.maxContinuations,
    DEFAULT_MAX_CONTINUATIONS,
  );
  return {
    id,
    status: value.status,
    objective,
    summary: normalizeText(
      typeof value.summary === "string" ? value.summary : undefined,
    ),
    blocker: normalizeText(
      typeof value.blocker === "string" ? value.blocker : undefined,
    ),
    tasks: normalizeTasks(value.tasks),
    createdAt,
    updatedAt,
    completedAt: normalizeIso(value.completedAt),
    revision,
    continuationCount,
    maxContinuations,
  };
}

function goalFromSnapshot(value: unknown): SessionGoal | undefined {
  if (!isRecord(value)) return undefined;
  if (value.version !== 1) return undefined;
  return normalizeLoadedGoal(value.goal);
}

function readGoalFromSession(ctx: ExtensionContext): SessionGoal | undefined {
  const sessionManager = ctx.sessionManager;
  const entries = sessionManager.getBranch?.() ?? sessionManager.getEntries();
  let latest: SessionGoal | undefined;
  for (const entry of entries) {
    if (entry.type !== "custom") continue;
    if (entry.customType !== CUSTOM_TYPE) continue;
    latest = goalFromSnapshot(entry.data);
  }
  return latest?.status === "cleared" ? undefined : latest;
}

function statusLabel(status: GoalStatus): string {
  switch (status) {
    case "active":
      return "Active";
    case "paused":
      return "Paused";
    case "blocked":
      return "Blocked";
    case "complete":
      return "Complete";
    case "cleared":
      return "Cleared";
  }
}

function statusState(
  status: GoalStatus,
): "queued" | "running" | "success" | "warning" | "error" | "inactive" {
  switch (status) {
    case "active":
      return "running";
    case "paused":
      return "inactive";
    case "blocked":
      return "warning";
    case "complete":
      return "success";
    case "cleared":
      return "inactive";
  }
}

function taskState(
  status: TaskStatus,
): "queued" | "running" | "success" | "warning" | "error" | "inactive" {
  switch (status) {
    case "pending":
      return "queued";
    case "in_progress":
      return "running";
    case "completed":
      return "success";
  }
}

function truncate(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  return `${value.slice(0, Math.max(0, maxLength - 1))}…`;
}

function elapsedMsBetween(
  startIso: string | undefined,
  endIso: string | undefined,
): number | undefined {
  if (!startIso) return undefined;
  const started = Date.parse(startIso);
  const ended = endIso ? Date.parse(endIso) : Date.now();
  if (!Number.isFinite(started) || !Number.isFinite(ended) || ended < started) {
    return undefined;
  }
  return ended - started;
}

function goalElapsedMs(goal: SessionGoal): number | undefined {
  const endIso =
    goal.status === "active" ? undefined : (goal.completedAt ?? goal.updatedAt);
  return elapsedMsBetween(goal.createdAt, endIso);
}

function taskElapsedMs(task: GoalTask): number | undefined {
  return task.elapsedMs ?? elapsedMsBetween(task.startedAt, task.completedAt);
}

function formatDuration(ms: number | undefined): string | undefined {
  if (ms === undefined) return undefined;
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  if (totalSeconds === 0) return undefined;
  const days = Math.floor(totalSeconds / 86_400);
  const hours = Math.floor((totalSeconds % 86_400) / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  const seconds = totalSeconds % 60;

  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function taskSubtitle(task: GoalTask): string {
  const parts = [task.status.replace(/_/g, " ")];
  const duration = formatDuration(taskElapsedMs(task));
  if (duration) parts.push(duration);
  return parts.join(" · ");
}

function goalSubtitle(goal: SessionGoal): string {
  return [
    `${statusLabel(goal.status)} · ${goal.continuationCount}/${goal.maxContinuations} continuations`,
    `${formatDuration(goalElapsedMs(goal)) ?? "0s"} elapsed`,
  ].join(" · ");
}

function formatGoal(goal: SessionGoal | undefined): string {
  if (!goal) return "No active goal.";
  const lines = [
    `Goal ${goal.id} · ${statusLabel(goal.status)}`,
    `Objective: ${goal.objective}`,
    `Continuations: ${goal.continuationCount}/${goal.maxContinuations}`,
    `Elapsed: ${formatDuration(goalElapsedMs(goal)) ?? "0s"}`,
  ];
  if (goal.summary) lines.push(`Summary: ${goal.summary}`);
  if (goal.blocker) lines.push(`Blocker: ${goal.blocker}`);
  if (goal.tasks.length > 0) {
    lines.push("Tasks:");
    for (const [index, task] of goal.tasks.entries()) {
      const duration = formatDuration(taskElapsedMs(task));
      lines.push(
        `  ${index + 1}. [${task.status}] ${task.title}${duration ? ` · ${duration}` : ""}`,
      );
    }
  }
  return lines.join("\n");
}

function buildSystemPrompt(goal: SessionGoal): string {
  return [
    "\n\n## Active goal runner",
    "This session has an active durable goal. Keep working toward it until it is complete, blocked, paused by the user, or the continuation budget stops the runner.",
    "Use get_goal when you need the current state. Use update_goal whenever progress, tasks, blockers, or terminal status changes.",
    "The continuation budget is a safety cap, not a target to spend. Complete early when the whole objective is actually done and verified; otherwise keep the goal active and continue making concrete progress.",
    "Before status=complete, audit the objective against real evidence: inspect the relevant files, command output, tests, docs, or runtime state; map every explicit requirement to evidence; treat uncertainty as incomplete.",
    "Set status=blocked with a concrete blocker when you cannot continue without user input, credentials, unavailable services, or a risky decision.",
    "Keep status=active when useful autonomous work remains, evidence is weak, or any listed task is still pending or in progress.",
    "",
    formatGoal(goal),
  ].join("\n");
}

function buildContinuationPrompt(goal: SessionGoal): string {
  return [
    "Continue the active goal autonomously.",
    "",
    formatGoal(goal),
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

function createGoalFromParams(
  params: Static<typeof CreateGoalParams>,
  defaultMaxContinuations: number,
): SessionGoal | undefined {
  const objective = params.objective.trim();
  if (!objective) return undefined;
  const createdAt = nowIso();
  return {
    id: randomUUID(),
    status: "active",
    objective,
    summary: normalizeText(params.summary),
    tasks: applyTaskTiming([], normalizeTasks(params.tasks), createdAt),
    createdAt,
    updatedAt: createdAt,
    revision: 1,
    continuationCount: 0,
    maxContinuations: normalizeMaxContinuations(
      params.max_continuations,
      defaultMaxContinuations,
    ),
  };
}

function applyTaskTiming(
  previousTasks: GoalTask[],
  nextTasks: GoalTask[],
  timestamp: string,
): GoalTask[] {
  return nextTasks.map((task) => {
    const previous = previousTasks.find(
      (candidate) => candidate.id === task.id || candidate.title === task.title,
    );
    const startedAt = task.startedAt ?? previous?.startedAt;
    const completedAt = task.completedAt ?? previous?.completedAt;
    const elapsedMs = task.elapsedMs ?? previous?.elapsedMs;

    if (task.status === "in_progress") {
      return {
        ...task,
        startedAt: startedAt ?? timestamp,
        completedAt: undefined,
        elapsedMs: undefined,
      };
    }

    if (task.status === "completed") {
      const finalStartedAt = startedAt ?? timestamp;
      const finalCompletedAt = completedAt ?? timestamp;
      return {
        ...task,
        startedAt: finalStartedAt,
        completedAt: finalCompletedAt,
        elapsedMs:
          elapsedMs ?? elapsedMsBetween(finalStartedAt, finalCompletedAt) ?? 0,
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

function applyTaskUpdates(
  tasks: GoalTask[],
  updates: Static<typeof GoalTaskUpdateSchema>[] | undefined,
): GoalTask[] {
  if (!updates?.length) return tasks;
  const next = tasks.map((task) => ({ ...task }));
  for (const update of updates) {
    const updateId = normalizeText(update.id);
    const title = normalizeText(update.title);
    const targetIndex =
      updateId !== undefined
        ? next.findIndex((task) => task.id === updateId)
        : typeof update.index === "number"
          ? Math.floor(update.index) - 1
          : -1;

    if (targetIndex >= 0 && targetIndex < next.length) {
      next[targetIndex] = {
        ...next[targetIndex],
        ...(title ? { title } : {}),
        ...(update.status ? { status: update.status } : {}),
      };
      continue;
    }

    if (title) {
      next.push({
        id: updateId ?? taskId(),
        title,
        status: update.status ?? "pending",
      });
    }
  }
  return next;
}

function unfinishedTasks(goal: SessionGoal): GoalTask[] {
  return goal.tasks.filter((task) => task.status !== "completed");
}

function appendSummaryNote(summary: string | undefined, note: string): string {
  const normalized = normalizeText(summary);
  if (!normalized) return note;
  if (normalized.includes(note)) return normalized;
  return `${normalized}\n\n${note}`;
}

function updateGoalFromParams(
  goal: SessionGoal,
  params: Static<typeof UpdateGoalParams>,
): SessionGoal {
  const next = cloneGoal(goal);
  const objective = normalizeText(params.objective);
  if (objective) next.objective = objective;
  if (params.status) next.status = params.status;
  if (params.summary !== undefined)
    next.summary = normalizeText(params.summary);
  if (params.blocker !== undefined)
    next.blocker = normalizeText(params.blocker);
  if (params.tasks !== undefined) next.tasks = normalizeTasks(params.tasks);
  next.tasks = applyTaskUpdates(next.tasks, params.task_updates);
  const updatedAt = nowIso();
  next.tasks = applyTaskTiming(goal.tasks, next.tasks, updatedAt);
  if (params.max_continuations !== undefined) {
    next.maxContinuations = normalizeMaxContinuations(
      params.max_continuations,
      goal.maxContinuations,
    );
  }
  if (next.status === "active" && params.blocker === undefined)
    next.blocker = undefined;
  if (next.status === "blocked" && !next.blocker) {
    next.blocker = normalizeText(params.note) ?? "Goal is blocked.";
  }
  if (next.status === "complete") {
    const remainingTasks = unfinishedTasks(next);
    if (remainingTasks.length > 0) {
      next.status = "active";
      next.blocker = undefined;
      next.completedAt = undefined;
      const taskList = remainingTasks
        .slice(0, 5)
        .map((task) => task.title)
        .join(", ");
      const suffix =
        remainingTasks.length > 5 ? `, +${remainingTasks.length - 5} more` : "";
      next.summary = appendSummaryNote(
        next.summary,
        `Completion deferred: unfinished tasks remain (${taskList}${suffix}).`,
      );
    }
  }
  if (next.status === "complete" && !next.summary) {
    next.summary = normalizeText(params.note) ?? "Goal completed.";
  }
  next.completedAt =
    next.status === "complete" ? (next.completedAt ?? updatedAt) : undefined;
  next.updatedAt = updatedAt;
  next.revision += 1;
  return next;
}

function errorResult(message: string): {
  content: Array<{ type: "text"; text: string }>;
  details: { status: "error"; error: string };
  isError: true;
} {
  return {
    content: [{ type: "text", text: message }],
    details: { status: "error", error: message },
    isError: true,
  };
}

function goalResult(goal: SessionGoal | undefined): {
  content: Array<{ type: "text"; text: string }>;
  details: { goal?: SessionGoal; status: "ok" };
} {
  return {
    content: [{ type: "text", text: formatGoal(goal) }],
    details: goal ? { status: "ok", goal } : { status: "ok" },
  };
}

function createGoalWidget(getGoal: () => SessionGoal | undefined): {
  render(width: number): string[];
  renderNative(): unknown;
  invalidate(): void;
  dispose(): void;
} {
  return {
    render(width: number): string[] {
      const goal = getGoal();
      if (!goal) return [];
      const maxTitle = Math.max(24, Math.min(72, width - 14));
      const lines = [
        `Goal · ${statusLabel(goal.status)} · ${goal.continuationCount}/${goal.maxContinuations} · ${formatDuration(goalElapsedMs(goal)) ?? "0s"}`,
        `  ${truncate(goal.objective, maxTitle)}`,
      ];
      if (goal.summary) lines.push(`  ${truncate(goal.summary, maxTitle)}`);
      if (goal.blocker)
        lines.push(`  Blocked: ${truncate(goal.blocker, maxTitle)}`);
      for (const task of goal.tasks.slice(0, 4)) {
        lines.push(
          `  - [${task.status}] ${truncate(task.title, maxTitle - 4)}${formatDuration(taskElapsedMs(task)) ? ` · ${formatDuration(taskElapsedMs(task))}` : ""}`,
        );
      }
      if (goal.tasks.length > 4)
        lines.push(`  … ${goal.tasks.length - 4} more tasks`);
      return lines;
    },
    renderNative() {
      const goal = getGoal();
      if (!goal) return undefined;
      const blocks: Array<Record<string, unknown>> = [
        {
          type: "activityList",
          id: "goal-status",
          rows: [
            {
              id: goal.id,
              title: goal.objective,
              subtitle: goalSubtitle(goal),
              state: statusState(goal.status),
              children: goal.tasks.map((task) => ({
                id: task.id,
                title: task.title,
                subtitle: taskSubtitle(task),
                state: taskState(task.status),
              })),
            },
          ],
        },
      ];
      if (goal.summary)
        blocks.push({
          type: "markdown",
          markdown: `**Summary:** ${goal.summary}`,
        });
      if (goal.blocker)
        blocks.push({
          type: "markdown",
          markdown: `**Blocker:** ${goal.blocker}`,
        });
      return {
        version: 1,
        id: "widget:goal",
        source: "widget",
        presentation: {
          style: "surfacePanel",
          title: "Goal",
          subtitle: `${statusLabel(goal.status)} · ${formatDuration(goalElapsedMs(goal)) ?? "0s"}`,
        },
        blocks,
        fallback: { lines: this.render(88) },
      };
    },
    invalidate() {},
    dispose() {},
  };
}

export function createGoalExtension(
  options: GoalExtensionOptions = {},
): ExtensionFactory {
  return (pi) => {
    let currentGoal: SessionGoal | undefined;
    let latestCtx: ExtensionContext | undefined;
    let widgetRender: (() => void) | undefined;
    let continuationTimer: ReturnType<typeof setTimeout> | undefined;
    let widgetTimer: ReturnType<typeof setInterval> | undefined;
    let continuationQueued = false;
    let compactionInFlight = false;

    const defaultMaxContinuations = normalizeMaxContinuations(
      options.defaultMaxContinuations,
      DEFAULT_MAX_CONTINUATIONS,
    );
    const continuationDelayMs = Math.max(
      0,
      Math.floor(options.continuationDelayMs ?? DEFAULT_CONTINUATION_DELAY_MS),
    );
    const maxContextPercent = Math.max(
      1,
      Math.min(100, options.maxContextPercent ?? DEFAULT_MAX_CONTEXT_PERCENT),
    );
    const widgetTimerMs = Math.max(
      1_000,
      Math.floor(options.widgetTimerMs ?? DEFAULT_WIDGET_TIMER_MS),
    );

    function clearContinuationTimer(): void {
      if (continuationTimer) clearTimeout(continuationTimer);
      continuationTimer = undefined;
    }

    function clearWidgetTimer(): void {
      if (widgetTimer) clearInterval(widgetTimer);
      widgetTimer = undefined;
    }

    function syncWidgetTimer(): void {
      if (!currentGoal || currentGoal.status !== "active") {
        clearWidgetTimer();
        return;
      }
      if (widgetTimer) return;
      widgetTimer = setInterval(() => {
        updateUi();
      }, widgetTimerMs);
    }

    function updateUi(): void {
      const goal = currentGoal;
      latestCtx?.ui.setStatus(
        WIDGET_KEY,
        goal
          ? `goal: ${statusLabel(goal.status)} ${goal.continuationCount}/${goal.maxContinuations}`
          : undefined,
      );
      widgetRender?.();
      syncWidgetTimer();
    }

    function persistGoal(goal: SessionGoal | undefined): void {
      if (!goal) return;
      pi.appendEntry<GoalSnapshot>(CUSTOM_TYPE, { version: 1, goal });
      currentGoal = goal.status === "cleared" ? undefined : goal;
      if (!currentGoal || currentGoal.status !== "active") {
        clearContinuationTimer();
        continuationQueued = false;
        compactionInFlight = false;
      }
      updateUi();
    }

    function stopGoal(
      goal: SessionGoal,
      status: Exclude<GoalStatus, "active">,
      note?: string,
    ): void {
      const next = cloneGoal(goal);
      next.status = status;
      if (status === "blocked")
        next.blocker = normalizeText(note) ?? next.blocker;
      if (status === "complete")
        next.summary = normalizeText(note) ?? next.summary;
      next.updatedAt = nowIso();
      next.completedAt =
        status === "complete"
          ? (next.completedAt ?? next.updatedAt)
          : undefined;
      next.revision += 1;
      persistGoal(next);
    }

    function maybeStopForBudget(
      ctx: ExtensionContext,
      goal: SessionGoal,
    ): boolean {
      if (goal.continuationCount >= goal.maxContinuations) {
        stopGoal(
          goal,
          "blocked",
          `Continuation budget exhausted (${goal.continuationCount}/${goal.maxContinuations}).`,
        );
        ctx.ui.notify("Goal blocked: continuation budget exhausted", "warning");
        return true;
      }

      const usage = ctx.getContextUsage?.();
      if (
        usage?.percent !== null &&
        usage?.percent !== undefined &&
        usage.percent >= maxContextPercent
      ) {
        if (!compactionInFlight) {
          compactionInFlight = true;
          ctx.ui.notify(
            "Goal waiting for compaction: context usage limit reached",
            "warning",
          );
          ctx.compact({
            customInstructions:
              "Preserve the active goal objective, completed cleanup steps, pending tasks, validation commands, and known unrelated working-tree changes.",
            onComplete: () => {
              compactionInFlight = false;
              const activeCtx = latestCtx;
              if (
                currentGoal?.status === "active" &&
                activeCtx?.isIdle() &&
                !activeCtx.hasPendingMessages()
              ) {
                scheduleContinuation(activeCtx);
              }
            },
            onError: (error) => {
              compactionInFlight = false;
              if (currentGoal?.status !== "active") return;
              stopGoal(
                currentGoal,
                "blocked",
                `Context compaction failed: ${error.message}`,
              );
              latestCtx?.ui.notify("Goal blocked: compaction failed", "error");
            },
          });
        }
        return true;
      }
      return false;
    }

    function scheduleContinuation(ctx: ExtensionContext): void {
      latestCtx = ctx;
      const goal = currentGoal;
      if (!goal || goal.status !== "active") return;
      if (continuationQueued || continuationTimer) return;

      continuationTimer = setTimeout(() => {
        continuationTimer = undefined;
        const activeGoal = currentGoal;
        const activeCtx = latestCtx;
        if (!activeGoal || activeGoal.status !== "active" || !activeCtx) return;
        if (!activeCtx.isIdle()) {
          scheduleContinuation(activeCtx);
          return;
        }
        if (activeCtx.hasPendingMessages()) return;
        if (maybeStopForBudget(activeCtx, activeGoal)) return;

        const next = cloneGoal(activeGoal);
        next.continuationCount += 1;
        next.updatedAt = nowIso();
        next.revision += 1;
        persistGoal(next);

        try {
          pi.sendMessage(
            {
              customType: CONTINUATION_TYPE,
              content: buildContinuationPrompt(next),
              display: true,
              details: {
                goalId: next.id,
                continuation: next.continuationCount,
                maxContinuations: next.maxContinuations,
              },
            },
            { deliverAs: "followUp", triggerTurn: true },
          );
          continuationQueued = true;
        } catch (error) {
          continuationQueued = false;
          activeCtx.ui.notify(
            `Goal continuation failed: ${error instanceof Error ? error.message : String(error)}`,
            "error",
          );
        }
      }, continuationDelayMs);
    }

    function setActiveGoal(goal: SessionGoal, ctx: ExtensionContext): void {
      latestCtx = ctx;
      persistGoal(goal);
      ctx.ui.notify(`Goal active: ${goal.objective}`, "info");
      scheduleContinuation(ctx);
    }

    pi.on("session_start", (_event, ctx) => {
      latestCtx = ctx;
      currentGoal = readGoalFromSession(ctx);
      ctx.ui.setWidget(
        WIDGET_KEY,
        (tui: unknown) => {
          widgetRender = () => {
            (tui as { requestRender?: () => void }).requestRender?.();
          };
          return createGoalWidget(() => currentGoal);
        },
        { placement: "aboveEditor" },
      );
      syncWidgetTimer();
      updateUi();
      if (
        currentGoal?.status === "active" &&
        ctx.isIdle() &&
        !ctx.hasPendingMessages()
      ) {
        scheduleContinuation(ctx);
      }
    });

    pi.on("session_shutdown", (_event, ctx) => {
      clearContinuationTimer();
      clearWidgetTimer();
      continuationQueued = false;
      compactionInFlight = false;
      widgetRender = undefined;
      latestCtx = undefined;
      currentGoal = undefined;
      ctx.ui.setStatus(WIDGET_KEY, undefined);
      ctx.ui.setWidget(WIDGET_KEY, undefined);
    });

    pi.on("agent_start", () => {
      clearContinuationTimer();
      continuationQueued = false;
    });

    pi.on("before_agent_start", (event) => {
      if (currentGoal?.status !== "active") return undefined;
      return {
        systemPrompt: event.systemPrompt + buildSystemPrompt(currentGoal),
      };
    });

    pi.on("agent_end", (_event, ctx) => {
      // Extension-triggered continuations can run without a matching agent_start
      // event, so clear the queued marker here before deciding whether to loop.
      continuationQueued = false;
      if (currentGoal?.status === "active") scheduleContinuation(ctx);
    });

    pi.on("session_before_compact", (_event, ctx) => {
      latestCtx = ctx;
      compactionInFlight = true;
      clearContinuationTimer();
      return undefined;
    });

    pi.on("session_compact", (_event, ctx) => {
      compactionInFlight = false;
      if (
        currentGoal?.status === "active" &&
        ctx.isIdle() &&
        !ctx.hasPendingMessages()
      ) {
        scheduleContinuation(ctx);
      }
    });

    pi.registerCommand("goal", {
      description:
        "Manage a durable autonomous goal: /goal <objective>, /goal pause, /goal resume, /goal complete, /goal block, /goal clear, /goal budget <n>.",
      handler: async (args, ctx) => {
        latestCtx = ctx;
        const trimmed = args.trim();
        const [command = "", ...rest] = trimmed.split(/\s+/);
        const lower = command.toLowerCase();
        const restText = rest.join(" ").trim();

        if (!trimmed) {
          ctx.ui.notify(
            currentGoal
              ? formatGoal(currentGoal)
              : "No active goal. Use /goal <objective>.",
            "info",
          );
          return;
        }

        if (["status", "show", "get"].includes(lower)) {
          ctx.ui.notify(formatGoal(currentGoal), "info");
          return;
        }

        if (lower === "clear") {
          if (!currentGoal) {
            ctx.ui.notify("No active goal to clear.", "info");
            return;
          }
          const next = cloneGoal(currentGoal);
          next.status = "cleared";
          next.updatedAt = nowIso();
          next.revision += 1;
          persistGoal(next);
          ctx.ui.notify("Goal cleared.", "info");
          return;
        }

        if (lower === "pause") {
          if (!currentGoal) {
            ctx.ui.notify("No active goal to pause.", "info");
            return;
          }
          stopGoal(currentGoal, "paused", restText);
          ctx.ui.notify("Goal paused.", "info");
          return;
        }

        if (lower === "resume") {
          if (!currentGoal) {
            ctx.ui.notify("No paused or blocked goal to resume.", "warning");
            return;
          }
          const next = cloneGoal(currentGoal);
          next.status = "active";
          next.blocker = undefined;
          if (restText) next.summary = restText;
          next.updatedAt = nowIso();
          next.revision += 1;
          setActiveGoal(next, ctx);
          return;
        }

        if (lower === "complete" || lower === "done") {
          if (!currentGoal) {
            ctx.ui.notify("No active goal to complete.", "info");
            return;
          }
          stopGoal(currentGoal, "complete", restText);
          ctx.ui.notify("Goal complete.", "info");
          return;
        }

        if (lower === "block" || lower === "blocked") {
          if (!currentGoal) {
            ctx.ui.notify("No active goal to block.", "info");
            return;
          }
          stopGoal(
            currentGoal,
            "blocked",
            restText || "Blocked by user command.",
          );
          ctx.ui.notify("Goal blocked.", "warning");
          return;
        }

        if (lower === "budget") {
          if (!currentGoal) {
            ctx.ui.notify("No active goal to budget.", "info");
            return;
          }
          const parsed = Number(restText || command);
          if (!Number.isFinite(parsed) || parsed < 1) {
            ctx.ui.notify("Usage: /goal budget <continuations>", "warning");
            return;
          }
          const next = cloneGoal(currentGoal);
          next.maxContinuations = normalizeMaxContinuations(
            parsed,
            next.maxContinuations,
          );
          next.updatedAt = nowIso();
          next.revision += 1;
          persistGoal(next);
          ctx.ui.notify(`Goal budget set to ${next.maxContinuations}.`, "info");
          if (next.status === "active") scheduleContinuation(ctx);
          return;
        }

        const objective =
          lower === "start" || lower === "create" ? restText : trimmed;
        if (!objective) {
          ctx.ui.notify("Usage: /goal <objective>", "warning");
          return;
        }
        if (currentGoal?.status === "active") {
          ctx.ui.notify(
            "An active goal already exists. Use /goal clear or /goal complete first.",
            "warning",
          );
          return;
        }
        const goal = createGoalFromParams(
          { objective, max_continuations: defaultMaxContinuations },
          defaultMaxContinuations,
        );
        if (!goal) {
          ctx.ui.notify("Goal objective cannot be empty.", "warning");
          return;
        }
        setActiveGoal(goal, ctx);
      },
    });

    pi.registerTool<typeof GetGoalParams>({
      name: "get_goal",
      label: "Get Goal",
      description: "Return the current durable session goal, if one exists.",
      promptSnippet: "get_goal() — inspect the current durable goal state",
      promptGuidelines: [
        "Use get_goal when you need the current autonomous goal, checklist, blocker, or continuation budget.",
      ],
      parameters: GetGoalParams,
      async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
        latestCtx = ctx;
        if (!currentGoal) currentGoal = readGoalFromSession(ctx);
        updateUi();
        return goalResult(currentGoal);
      },
    });

    pi.registerTool<typeof CreateGoalParams>({
      name: "create_goal",
      label: "Create Goal",
      description:
        "Create a durable autonomous goal for this session. The extension will keep triggering continuation turns while the goal remains active.",
      promptSnippet:
        "create_goal(objective, summary?, tasks?, max_continuations?, replace?) — start an autonomous goal",
      promptGuidelines: [
        "Use create_goal only when the user explicitly asks for a durable or autonomous multi-turn objective.",
        "Do not replace an active goal unless the user clearly asked to change goals or replace=true is appropriate.",
      ],
      parameters: CreateGoalParams,
      async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
        latestCtx = ctx;
        if (!currentGoal) currentGoal = readGoalFromSession(ctx);
        if (currentGoal?.status === "active" && !params.replace) {
          return errorResult(
            `Active goal already exists (${currentGoal.id}). Use update_goal or pass replace=true if replacement is intended.`,
          );
        }
        const goal = createGoalFromParams(params, defaultMaxContinuations);
        if (!goal) return errorResult("Goal objective cannot be empty.");
        persistGoal(goal);
        return goalResult(goal);
      },
    });

    pi.registerTool<typeof UpdateGoalParams>({
      name: "update_goal",
      label: "Update Goal",
      description:
        "Update the durable session goal status, progress summary, blocker, checklist, or continuation budget.",
      promptSnippet:
        "update_goal(goal_id?, status?, objective?, summary?, blocker?, tasks?, task_updates?, max_continuations?, note?) — update goal progress or terminal state",
      promptGuidelines: [
        "Use update_goal after making meaningful progress on an active goal.",
        "Set update_goal status=complete only after the user's objective is actually finished and validated against real evidence.",
        "If listed tasks are still pending or in progress, update_goal status=complete is treated as an active progress update so the runner keeps going.",
        "Set update_goal status=blocked with a concrete blocker when progress cannot continue without user input or an external state change.",
        "Keep update_goal status=active while useful autonomous work remains or evidence is weak.",
      ],
      parameters: UpdateGoalParams,
      async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
        latestCtx = ctx;
        if (!currentGoal) currentGoal = readGoalFromSession(ctx);
        if (!currentGoal)
          return errorResult("No goal exists. Use create_goal first.");
        if (params.goal_id && params.goal_id !== currentGoal.id) {
          return errorResult(
            `Stale goal id: expected ${currentGoal.id}, received ${params.goal_id}.`,
          );
        }
        const next = updateGoalFromParams(currentGoal, params);
        persistGoal(next);
        return goalResult(next);
      },
    });
  };
}

export default createGoalExtension();

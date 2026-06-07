import { StringEnum } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";

const GOAL_CUSTOM_TYPE = "oppi-goal";
const GOAL_CONTEXT_CUSTOM_TYPE = "oppi-goal-context";
const GOAL_CONTINUATION_CUSTOM_TYPE = "oppi-goal-continuation";
const GOAL_WIDGET_KEY = "goal";
const DEFAULT_MAX_TURNS = 100;
const DEFAULT_MAX_ELAPSED_MS = 8 * 60 * 60 * 1000;

type GoalStatus = "active" | "paused" | "complete" | "blocked" | "cleared";
type GoalTaskStatus = "pending" | "in_progress" | "completed";

export interface OppiGoalTask {
  id: string;
  title: string;
  status: GoalTaskStatus;
}

interface OppiGoalNativeSurface {
  version: 1;
  id: string;
  source: "widget";
  presentation: {
    style: "surfacePanel";
    title: string;
    subtitle?: string;
  };
  blocks: Array<
    | {
        type: "progress";
        id: string;
        label: string;
        value: number;
      }
    | {
        type: "activityList";
        id: string;
        rows: Array<{
          id: string;
          title: string;
          subtitle?: string;
          state: "queued" | "running" | "success" | "inactive";
          progress?: number;
        }>;
      }
  >;
  fallback: { lines: string[] };
}

interface ContextMessage {
  role?: unknown;
  content?: unknown;
  customType?: unknown;
}

interface TextContentLike {
  type: "text";
  text: string;
}

interface AssistantMessageLike {
  role?: unknown;
  content?: unknown;
  stopReason?: unknown;
  errorMessage?: unknown;
}

function asAssistantMessage(value: unknown): AssistantMessageLike | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const message = value as AssistantMessageLike;
  return message.role === "assistant" ? message : undefined;
}

function contentShowsProgress(content: unknown): boolean {
  if (typeof content === "string") return content.trim().length > 0;
  if (!Array.isArray(content)) return false;
  return content.some((part) => {
    if (typeof part !== "object" || part === null) return false;
    const record = part as { type?: unknown; text?: unknown };
    if (record.type === "text") {
      return typeof record.text === "string" && record.text.trim().length > 0;
    }
    return record.type === "toolCall";
  });
}

function goalContinuationBlocker(messages: readonly unknown[]): string | undefined {
  const assistantMessages = messages
    .map(asAssistantMessage)
    .filter((message): message is AssistantMessageLike => message !== undefined);
  const lastAssistant = assistantMessages.at(-1);
  if (!lastAssistant) {
    return "Goal continuation stopped because the agent turn produced no assistant response.";
  }
  if (lastAssistant.stopReason === "error") {
    const message =
      typeof lastAssistant.errorMessage === "string"
        ? compactText(lastAssistant.errorMessage, 180)
        : undefined;
    return message
      ? `Goal continuation stopped after an agent error: ${message}`
      : "Goal continuation stopped after an agent error.";
  }
  if (!contentShowsProgress(lastAssistant.content)) {
    return "Goal continuation stopped because the agent turn ended without visible progress.";
  }
  return undefined;
}

export interface OppiGoalState {
  version: 1;
  objective: string;
  status: GoalStatus;
  createdAt: number;
  updatedAt: number;
  turnCount: number;
  continuationCount: number;
  maxTurns: number;
  maxElapsedMs: number;
  lastSummary?: string;
  blocker?: string;
  tasks?: OppiGoalTask[];
}

const goalTaskStatusParams = StringEnum(
  ["pending", "in_progress", "completed"] as const,
  {
    description: "Checklist item status.",
  },
);

const goalStatusParams = StringEnum(
  ["active", "paused", "complete", "blocked", "cleared"] as const,
  {
    description:
      "Overall goal status, not checklist item status. Use taskUpdates[].status for individual task progress.",
  },
);

const goalTaskParams = Type.Object({
  id: Type.Optional(Type.String()),
  title: Type.String(),
  status: Type.Optional(goalTaskStatusParams),
});

const goalTaskUpdateParams = Type.Object({
  id: Type.Optional(Type.String()),
  index: Type.Optional(Type.Number()),
  title: Type.Optional(Type.String()),
  status: Type.Optional(goalTaskStatusParams),
});

const goalUpdateParams = Type.Object({
  status: Type.Optional(goalStatusParams),
  summary: Type.Optional(Type.String()),
  blocker: Type.Optional(Type.String()),
  tasks: Type.Optional(Type.Array(goalTaskParams)),
  taskUpdates: Type.Optional(Type.Array(goalTaskUpdateParams)),
});

const goalStatusReadParams = Type.Object({});

type GoalUpdateParams = Static<typeof goalUpdateParams>;

function now(): number {
  return Date.now();
}

function compactText(value: string, maxLength: number): string {
  const normalized = value.replace(/\s+/g, " ").trim();
  if (normalized.length <= maxLength) return normalized;
  return `${normalized.slice(0, Math.max(0, maxLength - 3)).trimEnd()}...`;
}

function fitLine(line: string, width?: number): string {
  if (typeof width !== "number" || !Number.isFinite(width)) return line;
  const maxWidth = Math.max(0, Math.trunc(width));
  if (maxWidth <= 0) return "";
  if (line.length <= maxWidth) return line;
  if (maxWidth <= 3) return ".".repeat(maxWidth);
  return `${line.slice(0, maxWidth - 3).trimEnd()}...`;
}

function fitLines(lines: string[], width?: number): string[] {
  return lines.map((line) => fitLine(line, width));
}

function elapsedLabel(elapsedMs: number): string {
  const totalSeconds = Math.max(0, Math.floor(elapsedMs / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function cloneState(state: OppiGoalState): OppiGoalState {
  return { ...state, tasks: state.tasks?.map((task) => ({ ...task })) };
}

function validTaskStatus(value: unknown): GoalTaskStatus | undefined {
  if (value === "pending" || value === "in_progress" || value === "completed") {
    return value;
  }
  return undefined;
}

function cleanTaskTitle(title: string): string | undefined {
  const cleaned = title.replace(/\s+/g, " ").trim();
  return cleaned.length > 0 ? cleaned : undefined;
}

function baseTaskId(title: string, index: number): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return slug || `task-${index + 1}`;
}

function uniqueTaskId(
  preferredId: string | undefined,
  title: string,
  index: number,
  usedIds: Set<string>,
): string {
  const cleanedPreferred = preferredId
    ?.toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
  const base = cleanedPreferred || baseTaskId(title, index);
  let candidate = base;
  let suffix = 2;
  while (usedIds.has(candidate)) {
    candidate = `${base}-${suffix}`;
    suffix += 1;
  }
  usedIds.add(candidate);
  return candidate;
}

function normalizeTasks(
  tasks: readonly {
    id?: string;
    title: string;
    status?: GoalTaskStatus;
  }[],
): OppiGoalTask[] | undefined {
  const usedIds = new Set<string>();
  const normalized: OppiGoalTask[] = [];

  tasks.forEach((task, index) => {
    const title = cleanTaskTitle(task.title);
    if (!title) return;
    normalized.push({
      id: uniqueTaskId(task.id, title, index, usedIds),
      title,
      status: task.status ?? "pending",
    });
  });

  return normalized.length > 0 ? normalized : undefined;
}

function validTasks(value: unknown): OppiGoalTask[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const candidates: Array<{
    id?: string;
    title: string;
    status?: GoalTaskStatus;
  }> = [];

  value.forEach((task) => {
    if (typeof task !== "object" || task === null) return;
    const record = task as {
      id?: unknown;
      title?: unknown;
      status?: unknown;
    };
    if (typeof record.title !== "string") return;
    candidates.push({
      id: typeof record.id === "string" ? record.id : undefined,
      title: record.title,
      status: validTaskStatus(record.status),
    });
  });

  return normalizeTasks(candidates);
}

function applyTaskUpdates(
  existingTasks: readonly OppiGoalTask[] | undefined,
  updates: readonly {
    id?: string;
    index?: number;
    title?: string;
    status?: GoalTaskStatus;
  }[],
): OppiGoalTask[] | undefined {
  const tasks = existingTasks?.map((task) => ({ ...task })) ?? [];

  updates.forEach((update) => {
    const title = update.title ? cleanTaskTitle(update.title) : undefined;
    const index =
      typeof update.index === "number" && Number.isFinite(update.index)
        ? Math.trunc(update.index) - 1
        : undefined;
    const existingIndex =
      update.id !== undefined
        ? tasks.findIndex((task) => task.id === update.id)
        : index !== undefined && index >= 0 && index < tasks.length
          ? index
          : -1;

    if (existingIndex >= 0) {
      tasks[existingIndex] = {
        ...tasks[existingIndex],
        title: title ?? tasks[existingIndex]!.title,
        status: update.status ?? tasks[existingIndex]!.status,
      };
      return;
    }

    if (title) {
      tasks.push({
        id: update.id || baseTaskId(title, tasks.length),
        title,
        status: update.status ?? "pending",
      });
    }
  });

  return normalizeTasks(tasks);
}

function isGoalCustomEntry(entry: unknown): entry is {
  type: "custom";
  customType: typeof GOAL_CUSTOM_TYPE;
  data?: OppiGoalState;
} {
  return (
    typeof entry === "object" &&
    entry !== null &&
    (entry as { type?: unknown }).type === "custom" &&
    (entry as { customType?: unknown }).customType === GOAL_CUSTOM_TYPE
  );
}

function validGoalState(value: unknown): OppiGoalState | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const record = value as Partial<OppiGoalState>;
  if (record.version !== 1) return undefined;
  if (
    typeof record.objective !== "string" ||
    record.objective.trim().length === 0
  ) {
    return undefined;
  }
  if (
    record.status !== "active" &&
    record.status !== "paused" &&
    record.status !== "complete" &&
    record.status !== "blocked" &&
    record.status !== "cleared"
  ) {
    return undefined;
  }
  return {
    version: 1,
    objective: record.objective,
    status: record.status,
    createdAt: typeof record.createdAt === "number" ? record.createdAt : now(),
    updatedAt: typeof record.updatedAt === "number" ? record.updatedAt : now(),
    turnCount: typeof record.turnCount === "number" ? record.turnCount : 0,
    continuationCount:
      typeof record.continuationCount === "number"
        ? record.continuationCount
        : 0,
    maxTurns:
      typeof record.maxTurns === "number" ? record.maxTurns : DEFAULT_MAX_TURNS,
    maxElapsedMs:
      typeof record.maxElapsedMs === "number"
        ? record.maxElapsedMs
        : DEFAULT_MAX_ELAPSED_MS,
    lastSummary:
      typeof record.lastSummary === "string" ? record.lastSummary : undefined,
    blocker: typeof record.blocker === "string" ? record.blocker : undefined,
    tasks: validTasks(record.tasks),
  };
}

export function latestGoalStateFromEntries(
  entries: readonly unknown[],
): OppiGoalState | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (!isGoalCustomEntry(entry)) continue;
    const state = validGoalState(entry.data);
    if (state) return state;
  }
  return undefined;
}

function goalStatusLabel(status: GoalStatus): string {
  switch (status) {
    case "active":
      return "Pursuing goal";
    case "paused":
      return "Goal paused";
    case "complete":
      return "Goal complete";
    case "blocked":
      return "Goal blocked";
    case "cleared":
      return "Goal cleared";
  }
}

export function renderGoalLines(
  state: OppiGoalState,
  timestamp = now(),
  width?: number,
): string[] {
  if (state.status === "cleared") return [];

  if (state.tasks && state.tasks.length > 0) {
    const completedCount = state.tasks.filter(
      (task) => task.status === "completed",
    ).length;
    const lines = [
      `${completedCount} of ${state.tasks.length} tasks completed`,
      ...state.tasks.slice(0, 7).map((task, index) => {
        const marker =
          task.status === "completed"
            ? "[x]"
            : task.status === "in_progress"
              ? "[~]"
              : "[ ]";
        return `  ${marker} ${index + 1}. ${compactText(task.title, 72)}`;
      }),
    ];
    if (state.tasks.length > 7) {
      lines.push(`  ... ${state.tasks.length - 7} more tasks`);
    }
    if (state.status !== "active") {
      lines.push(`  ${goalStatusLabel(state.status)}`);
      const note = state.blocker ?? state.lastSummary;
      if (note) lines.push(`  ${compactText(note, 78)}`);
    }
    return fitLines(lines, width);
  }

  const elapsed = elapsedLabel(timestamp - state.createdAt);
  const objective = compactText(state.objective, 78);
  const progress = `${state.turnCount}/${state.maxTurns} turns | ${elapsed}`;
  const lines = [
    `Goal: ${goalStatusLabel(state.status)}`,
    `  ${objective}`,
    `  ${progress}`,
  ];

  const note = state.blocker ?? state.lastSummary;
  if (note) {
    lines.push(`  ${compactText(note, 78)}`);
  }
  return fitLines(lines, width);
}

function taskSummaryLine(state: OppiGoalState): string | undefined {
  if (!state.tasks || state.tasks.length === 0) return undefined;
  const completedCount = state.tasks.filter(
    (task) => task.status === "completed",
  ).length;
  return `${completedCount} of ${state.tasks.length} tasks completed`;
}

function renderGoalNativeSurface(
  state: OppiGoalState,
): OppiGoalNativeSurface | undefined {
  if (!state.tasks || state.tasks.length === 0) return undefined;

  const lines = renderGoalLines(state);
  const completedCount = state.tasks.filter(
    (task) => task.status === "completed",
  ).length;
  const value = completedCount / state.tasks.length;

  return {
    version: 1,
    id: "widget:goal",
    source: "widget",
    presentation: {
      style: "surfacePanel",
      title: taskSummaryLine(state) ?? "Goal tasks",
      subtitle: compactText(state.objective, 96),
    },
    blocks: [
      {
        type: "progress",
        id: "goal-progress",
        label: taskSummaryLine(state) ?? "Goal progress",
        value,
      },
      {
        type: "activityList",
        id: "goal-tasks",
        rows: state.tasks.map((task, index) => ({
          id: task.id,
          title: `${index + 1}. ${task.title}`,
          state:
            task.status === "completed"
              ? "success"
              : task.status === "in_progress"
                ? "running"
                : "queued",
          progress:
            task.status === "completed"
              ? 1
              : task.status === "in_progress"
                ? 0.5
                : 0,
        })),
      },
    ],
    fallback: { lines },
  };
}

function shouldShowWidget(state: OppiGoalState): boolean {
  return (
    state.status === "active" ||
    state.status === "paused" ||
    state.status === "blocked"
  );
}

function isGoalActive(
  state: OppiGoalState | undefined,
): state is OppiGoalState {
  return state !== undefined && state.status === "active";
}

function goalContextMessage(state: OppiGoalState): string {
  const tasks = state.tasks
    ?.map((task, index) => `${index + 1}. [${task.status}] ${task.title}`)
    .join("\n");
  const taskInstructions = tasks
    ? `
Current tasks:
${tasks}
`
    : `
For multi-step work, call goal_update with a compact tasks list before or during the first turn.
`;

  return `[OPPI GOAL ACTIVE]
Objective: ${state.objective}
${taskInstructions}
Maintain task progress with goal_update taskUpdates. Use one-based indexes from the widget.
Prefer one in_progress task at a time and mark tasks completed as soon as they are done.

Continue working until this objective is genuinely complete.
Use goal_update with status "complete" when the objective is finished.
Use goal_update with status "blocked" only when the same blocker prevents progress.
If more work remains, keep working and do not stop with only a status update.`;
}

function continuationMessage(state: OppiGoalState): string {
  const progress = taskSummaryLine(state);
  return `[OPPI GOAL CONTINUATION]
Continue pursuing the active goal.

Objective: ${state.objective}
${progress ? `Progress: ${progress}\n` : ""}

Do useful next work now. If the goal is complete, call goal_update with status "complete".
If truly blocked, call goal_update with status "blocked" and name the blocker.`;
}

function messageText(message: ContextMessage): string {
  const content = message.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(
      (item): item is TextContentLike =>
        typeof item === "object" &&
        item !== null &&
        (item as { type?: unknown }).type === "text" &&
        typeof (item as { text?: unknown }).text === "string",
    )
    .map((item) => item.text)
    .join("\n");
}

type GoalInjectedMessageKind = "context" | "continuation" | "none";

function goalInjectedMessageKind(
  message: ContextMessage,
): GoalInjectedMessageKind {
  if (message.customType === GOAL_CONTEXT_CUSTOM_TYPE) return "context";
  if (message.customType === GOAL_CONTINUATION_CUSTOM_TYPE)
    return "continuation";

  const text = messageText(message);
  if (text.includes("[OPPI GOAL ACTIVE]")) return "context";
  if (text.includes("[OPPI GOAL CONTINUATION]")) return "continuation";
  return "none";
}

function filterGoalInjectedMessages<T extends ContextMessage>(
  messages: readonly T[],
  keepGoalMessages: boolean,
): T[] {
  let latestContextIndex = -1;
  let latestCurrentTurnContinuationIndex = -1;
  const lastAssistantIndex = messages.reduce(
    (lastIndex, message, index) =>
      message.role === "assistant" ? index : lastIndex,
    -1,
  );

  if (keepGoalMessages) {
    messages.forEach((message, index) => {
      const kind = goalInjectedMessageKind(message);
      if (kind === "context") latestContextIndex = index;
      if (kind === "continuation" && index > lastAssistantIndex) {
        latestCurrentTurnContinuationIndex = index;
      }
    });
  }

  return messages.filter((message, index) => {
    const kind = goalInjectedMessageKind(message);
    if (kind === "continuation") {
      return keepGoalMessages && index === latestCurrentTurnContinuationIndex;
    }
    if (kind === "context")
      return keepGoalMessages && index === latestContextIndex;
    return true;
  });
}

function sessionGoalEntries(ctx: ExtensionContext): readonly unknown[] {
  const manager = ctx.sessionManager as typeof ctx.sessionManager & {
    getBranch?: () => readonly unknown[];
  };
  return manager.getBranch?.() ?? ctx.sessionManager.getEntries();
}

function prepareGoalUpdateArguments(args: unknown): unknown {
  if (typeof args !== "object" || args === null || Array.isArray(args))
    return args;
  const input = args as Record<string, unknown>;
  if (input.status === "in_progress") {
    return { ...input, status: "active" };
  }
  return args;
}

export interface OppiGoalExtensionOptions {
  maxTurns?: number;
  maxElapsedMs?: number;
}

export function createOppiGoalExtension(
  pi: ExtensionAPI,
  options: OppiGoalExtensionOptions = {},
): void {
  let state: OppiGoalState | undefined;
  const maxTurns = options.maxTurns ?? DEFAULT_MAX_TURNS;
  const maxElapsedMs = options.maxElapsedMs ?? DEFAULT_MAX_ELAPSED_MS;

  function persist(): void {
    if (!state) return;
    pi.appendEntry(GOAL_CUSTOM_TYPE, cloneState(state));
  }

  function render(ctx: ExtensionContext): void {
    if (!state || !shouldShowWidget(state)) {
      ctx.ui.setWidget(GOAL_WIDGET_KEY, undefined);
      return;
    }
    const snapshot = cloneState(state);
    ctx.ui.setWidget(
      GOAL_WIDGET_KEY,
      () => ({
        render: (width = 88) => renderGoalLines(snapshot, now(), width),
        invalidate: () => {},
        renderNative: () => renderGoalNativeSurface(snapshot),
      }),
      {
        placement: "aboveEditor",
      },
    );
  }

  function setState(
    next: OppiGoalState,
    ctx?: ExtensionContext,
  ): OppiGoalState {
    state = { ...next, updatedAt: now() };
    persist();
    if (ctx) render(ctx);
    return state;
  }

  function startGoal(objective: string, ctx: ExtensionContext): OppiGoalState {
    const timestamp = now();
    return setState(
      {
        version: 1,
        objective,
        status: "active",
        createdAt: timestamp,
        updatedAt: timestamp,
        turnCount: 0,
        continuationCount: 0,
        maxTurns,
        maxElapsedMs,
      },
      ctx,
    );
  }

  function completeGoal(ctx: ExtensionContext, summary?: string): void {
    if (!state) return;
    setState(
      {
        ...state,
        status: "complete",
        lastSummary: summary?.trim() || state.lastSummary,
      },
      ctx,
    );
    ctx.ui.setWidget(GOAL_WIDGET_KEY, undefined);
  }

  function blockGoal(
    ctx: ExtensionContext,
    blocker: string | undefined,
    summary?: string,
  ): void {
    if (!state) return;
    setState(
      {
        ...state,
        status: "blocked",
        blocker: blocker?.trim() || summary?.trim() || state.blocker,
        lastSummary: summary?.trim() || state.lastSummary,
      },
      ctx,
    );
  }

  function clearGoal(ctx: ExtensionContext): void {
    if (state) {
      setState({ ...state, status: "cleared" }, ctx);
    }
    state = undefined;
    ctx.ui.setWidget(GOAL_WIDGET_KEY, undefined);
  }

  function pauseGoal(ctx: ExtensionContext): void {
    if (!state || state.status !== "active") return;
    setState({ ...state, status: "paused" }, ctx);
  }

  function resumeGoal(ctx: ExtensionContext): void {
    if (!state || state.status !== "paused") return;
    setState({ ...state, status: "active" }, ctx);
  }

  function statusText(): string {
    if (!state || state.status === "cleared") return "No active goal.";
    return renderGoalLines(state).join("\n");
  }

  function sendKickoff(objective: string, ctx: ExtensionContext): void {
    const prompt = `Pursue this goal until complete:\n\n${objective}`;
    try {
      if (ctx.isIdle()) {
        pi.sendUserMessage(prompt);
      } else {
        pi.sendUserMessage(prompt, { deliverAs: "followUp" });
      }
    } catch (error) {
      ctx.ui.notify(
        error instanceof Error ? error.message : String(error),
        "warning",
      );
    }
  }

  pi.registerCommand("goal", {
    description:
      "Pursue a goal until complete, with a persistent progress widget",
    handler: async (args, ctx) => {
      const trimmed = args.trim();
      const command = trimmed.toLowerCase();

      if (!trimmed || command === "status") {
        ctx.ui.notify(statusText(), "info");
        render(ctx);
        return;
      }
      if (command === "pause") {
        pauseGoal(ctx);
        return;
      }
      if (command === "resume") {
        resumeGoal(ctx);
        return;
      }
      if (command === "clear" || command === "stop") {
        clearGoal(ctx);
        return;
      }
      if (command === "complete" || command === "done") {
        completeGoal(ctx, "Marked complete by user.");
        return;
      }

      startGoal(trimmed, ctx);
      sendKickoff(trimmed, ctx);
    },
  });

  pi.registerTool({
    name: "goal_update",
    label: "Goal Update",
    description:
      "Update the active Oppi goal status, task checklist, summary, or blocker.",
    promptSnippet:
      "Update the active goal when task progress, completion, or blocking status changes.",
    promptGuidelines: [
      "Use goal_update to mark the active goal complete when the user objective is genuinely finished.",
      "Use goal_update with status blocked only when progress cannot continue without user input or an external state change.",
      "For multi-step work, set tasks to a compact checklist and then use taskUpdates with one-based indexes as each item changes status.",
    ],
    parameters: goalUpdateParams,
    prepareArguments: prepareGoalUpdateArguments,
    async execute(
      _toolCallId,
      params: GoalUpdateParams,
      _signal,
      _onUpdate,
      ctx,
    ) {
      if (!state || state.status === "cleared") {
        return {
          content: [{ type: "text" as const, text: "No active goal." }],
          details: { status: "none" },
        };
      }

      const summary = params.summary?.trim();
      const tasks = params.tasks
        ? normalizeTasks(params.tasks)
        : applyTaskUpdates(state.tasks, params.taskUpdates ?? []);
      const baseState = { ...state, tasks };

      switch (params.status) {
        case "complete":
          state = baseState;
          completeGoal(ctx, summary);
          break;
        case "blocked":
          state = baseState;
          blockGoal(ctx, params.blocker, summary);
          break;
        case "cleared":
          state = baseState;
          clearGoal(ctx);
          break;
        case "paused":
          setState(
            {
              ...baseState,
              status: "paused",
              lastSummary: summary || baseState.lastSummary,
            },
            ctx,
          );
          break;
        case "active":
        case undefined:
          setState(
            {
              ...baseState,
              status: "active",
              lastSummary: summary || baseState.lastSummary,
              blocker: undefined,
            },
            ctx,
          );
          break;
      }

      return {
        content: [{ type: "text" as const, text: statusText() }],
        details: state ? cloneState(state) : { status: "none" },
      };
    },
  });

  pi.registerTool({
    name: "goal_status",
    label: "Goal Status",
    description: "Read the active Oppi goal status.",
    parameters: goalStatusReadParams,
    async execute() {
      return {
        content: [{ type: "text" as const, text: statusText() }],
        details: state ? cloneState(state) : { status: "none" },
      };
    },
  });

  function restoreGoalState(ctx: ExtensionContext): void {
    state = latestGoalStateFromEntries(sessionGoalEntries(ctx));
    if (state?.status === "complete" || state?.status === "cleared") {
      state = undefined;
    }
    render(ctx);
  }

  pi.on("session_start", (_event, ctx) => {
    restoreGoalState(ctx);
  });

  pi.on("session_tree", (_event, ctx) => {
    restoreGoalState(ctx);
  });

  pi.on("context", (event) => {
    const messages = filterGoalInjectedMessages(
      event.messages as ContextMessage[],
      isGoalActive(state),
    );
    if (messages.length === event.messages.length) return;
    return { messages };
  });

  pi.on("before_agent_start", () => {
    if (!isGoalActive(state)) return;
    return {
      message: {
        customType: GOAL_CONTEXT_CUSTOM_TYPE,
        content: goalContextMessage(state),
        display: false,
      },
    };
  });

  pi.on("agent_end", (event, ctx) => {
    if (!isGoalActive(state)) return;

    const elapsed = now() - state.createdAt;
    const nextTurnCount = state.turnCount + 1;
    const countedState = { ...state, turnCount: nextTurnCount };
    const blocker = goalContinuationBlocker(event.messages);
    if (blocker) {
      state = countedState;
      blockGoal(ctx, blocker);
      return;
    }
    if (nextTurnCount >= state.maxTurns) {
      state = countedState;
      blockGoal(ctx, `Goal turn budget reached (${state.maxTurns}).`);
      return;
    }
    if (elapsed >= state.maxElapsedMs) {
      state = countedState;
      blockGoal(
        ctx,
        `Goal elapsed-time budget reached (${elapsedLabel(state.maxElapsedMs)}).`,
      );
      return;
    }
    if (ctx.hasPendingMessages()) {
      setState(countedState, ctx);
      return;
    }

    const next = setState(
      {
        ...state,
        turnCount: nextTurnCount,
        continuationCount: state.continuationCount + 1,
      },
      ctx,
    );

    pi.sendMessage(
      {
        customType: GOAL_CONTINUATION_CUSTOM_TYPE,
        content: continuationMessage(next),
        display: false,
      },
      { triggerTurn: true, deliverAs: "followUp" },
    );
  });

  pi.on("session_shutdown", (_event, ctx) => {
    ctx.ui.setWidget(GOAL_WIDGET_KEY, undefined);
  });
}

export default createOppiGoalExtension;

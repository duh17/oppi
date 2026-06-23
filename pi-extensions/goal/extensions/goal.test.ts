import { afterEach, describe, expect, it, vi } from "vitest";

import { createGoalExtension } from "./goal.js";

type Handler = (
  event: Record<string, unknown>,
  ctx: MockExtensionContext,
) => unknown;

type RegisteredTool = {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: unknown,
    ctx?: MockExtensionContext,
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    details?: Record<string, unknown>;
    isError?: boolean;
  }>;
};

type RegisteredCommand = {
  description?: string;
  handler: (args: string, ctx: MockExtensionContext) => Promise<void>;
};

interface MockPi {
  handlers: Map<string, Handler[]>;
  tools: Map<string, RegisteredTool>;
  commands: Map<string, RegisteredCommand>;
  appendEntry: ReturnType<typeof vi.fn>;
  sendMessage: ReturnType<typeof vi.fn>;
  registerTool(tool: RegisteredTool): void;
  registerCommand(name: string, command: RegisteredCommand): void;
  on(event: string, handler: Handler): void;
}

interface MockExtensionContext {
  cwd: string;
  hasUI: boolean;
  mode: "tui" | "rpc" | "json" | "print";
  sessionManager: {
    getBranch: ReturnType<typeof vi.fn>;
    getEntries: ReturnType<typeof vi.fn>;
    getSessionId: ReturnType<typeof vi.fn>;
    getSessionFile: ReturnType<typeof vi.fn>;
  };
  isIdle: ReturnType<typeof vi.fn>;
  hasPendingMessages: ReturnType<typeof vi.fn>;
  getContextUsage: ReturnType<typeof vi.fn>;
  compact: ReturnType<typeof vi.fn>;
  ui: {
    setWidget: ReturnType<typeof vi.fn>;
    setStatus: ReturnType<typeof vi.fn>;
    notify: ReturnType<typeof vi.fn>;
  };
}

function createMockPi(): MockPi {
  const handlers = new Map<string, Handler[]>();
  const tools = new Map<string, RegisteredTool>();
  const commands = new Map<string, RegisteredCommand>();
  return {
    handlers,
    tools,
    commands,
    appendEntry: vi.fn(),
    sendMessage: vi.fn(),
    registerTool(tool: RegisteredTool) {
      tools.set(tool.name, tool);
    },
    registerCommand(name: string, command: RegisteredCommand) {
      commands.set(name, command);
    },
    on(event: string, handler: Handler) {
      const eventHandlers = handlers.get(event) ?? [];
      eventHandlers.push(handler);
      handlers.set(event, eventHandlers);
    },
  };
}

function activeGoal(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    id: "goal-1",
    status: "active",
    objective: "Ship goal runner",
    tasks: [],
    createdAt: "2026-06-18T00:00:00.000Z",
    updatedAt: "2026-06-18T00:00:00.000Z",
    revision: 1,
    continuationCount: 0,
    maxContinuations: 3,
    ...overrides,
  };
}

function customGoalEntry(
  goal: Record<string, unknown>,
): Record<string, unknown> {
  return {
    type: "custom",
    customType: "oppi-goal",
    data: { version: 1, goal },
  };
}

function createMockContext(
  options: {
    branch?: Record<string, unknown>[];
    idle?: boolean;
    pending?: boolean;
    contextPercent?: number | null;
  } = {},
): MockExtensionContext {
  const branch = options.branch ?? [];
  return {
    cwd: "/workspace/oppi",
    hasUI: true,
    mode: "rpc",
    sessionManager: {
      getBranch: vi.fn(() => branch),
      getEntries: vi.fn(() => branch),
      getSessionId: vi.fn(() => "pi-session-1"),
      getSessionFile: vi.fn(() => "/tmp/session.jsonl"),
    },
    isIdle: vi.fn(() => options.idle ?? true),
    hasPendingMessages: vi.fn(() => options.pending ?? false),
    getContextUsage: vi.fn(() => ({
      tokens: 10,
      contextWindow: 100,
      percent: options.contextPercent ?? 10,
    })),
    compact: vi.fn(),
    ui: {
      setWidget: vi.fn(),
      setStatus: vi.fn(),
      notify: vi.fn(),
    },
  };
}

async function emit(
  pi: MockPi,
  eventName: string,
  ctx: MockExtensionContext,
): Promise<void> {
  for (const handler of pi.handlers.get(eventName) ?? []) {
    await handler(
      { type: eventName, systemPrompt: "base prompt", messages: [] },
      ctx,
    );
  }
}

async function startSession(
  pi: MockPi,
  ctx: MockExtensionContext,
): Promise<void> {
  for (const handler of pi.handlers.get("session_start") ?? []) {
    await handler({ type: "session_start", reason: "startup" }, ctx);
  }
}

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
});

describe("goal extension", () => {
  it("starts a slash-command goal and queues the first continuation", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext();
    await startSession(pi, ctx);

    await pi.commands
      .get("goal")
      ?.handler("Build the extension-only goal runner", ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(pi.appendEntry).toHaveBeenCalledTimes(2);
    const firstGoal = pi.appendEntry.mock.calls[0][1].goal;
    expect(firstGoal).toMatchObject({
      status: "active",
      objective: "Build the extension-only goal runner",
      continuationCount: 0,
    });
    const continuationGoal = pi.appendEntry.mock.calls[1][1].goal;
    expect(continuationGoal.continuationCount).toBe(1);
    expect(pi.sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        customType: "oppi-goal-continuation",
        content: expect.stringContaining(
          "Continue the active goal autonomously.",
        ),
        details: expect.objectContaining({ continuation: 1 }),
      }),
      { deliverAs: "followUp", triggerTurn: true },
    );
  });

  it("queues another continuation after an extension-triggered turn ends", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext();
    await startSession(pi, ctx);

    await pi.commands.get("goal")?.handler("Keep working", ctx);
    await vi.advanceTimersByTimeAsync(1);
    expect(pi.sendMessage).toHaveBeenCalledTimes(1);

    // Extension-triggered turns may not emit agent_start, so agent_end must clear
    // the queued marker before scheduling the next continuation.
    await emit(pi, "agent_end", ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(pi.sendMessage).toHaveBeenCalledTimes(2);
    const nextGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(nextGoal.continuationCount).toBe(2);
  });

  it("loads active goal state and renders elapsed timing in the native widget", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-18T00:05:00.000Z"));
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [
        customGoalEntry(
          activeGoal({
            tasks: [
              {
                id: "task-1",
                title: "Write tests",
                status: "in_progress",
                startedAt: "2026-06-18T00:03:00.000Z",
              },
              {
                id: "task-2",
                title: "Commit cleanup",
                status: "completed",
                elapsedMs: 0,
              },
            ],
          }),
        ),
      ],
      pending: true,
    });

    await startSession(pi, ctx);

    const widgetFactory = ctx.ui.setWidget.mock.calls[0][1] as (
      tui: unknown,
    ) => {
      renderNative: () => {
        presentation: { title: string; subtitle: string };
        blocks: Array<{
          rows: Array<{
            title: string;
            subtitle: string;
            state: string;
            children: Array<{ title: string; subtitle: string }>;
          }>;
        }>;
      };
    };
    const tui = {
      renderRequested: false,
      requestRender() {
        this.renderRequested = true;
      },
    };
    const native = widgetFactory(tui).renderNative();

    expect(native.presentation.title).toBe("Goal");
    expect(native.presentation.subtitle).toContain("Active");
    expect(native.presentation.subtitle).toContain("5m 0s");
    expect(native.blocks[0].rows[0]).toMatchObject({
      title: "Ship goal runner",
      subtitle: "Active · 0/3 continuations · 5m 0s elapsed",
      state: "running",
    });
    expect(native.blocks[0].rows[0].children).toHaveLength(2);
    expect(native.blocks[0].rows[0].children[0]).toMatchObject({
      title: "Write tests",
      subtitle: "in progress · 2m 0s",
    });
    expect(native.blocks[0].rows[0].children[1]).toMatchObject({
      title: "Commit cleanup",
      subtitle: "completed",
    });
    expect(ctx.ui.setStatus).toHaveBeenCalledWith("goal", "goal: Active 0/3");

    await vi.advanceTimersByTimeAsync(30_000);
    expect(tui.renderRequested).toBe(true);
  });

  it("waits for compaction instead of blocking when context usage is high", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1, maxContextPercent: 95 })(
      pi as never,
    );
    const ctx = createMockContext({
      branch: [customGoalEntry(activeGoal())],
      contextPercent: 99,
    });

    await startSession(pi, ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(pi.sendMessage).not.toHaveBeenCalled();
    expect(pi.appendEntry).not.toHaveBeenCalled();
    expect(ctx.compact).toHaveBeenCalledTimes(1);
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      "Goal waiting for compaction: context usage limit reached",
      "warning",
    );

    ctx.getContextUsage.mockReturnValue({
      tokens: 10,
      contextWindow: 100,
      percent: 10,
    });
    await emit(pi, "session_compact", ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const nextGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(nextGoal).toMatchObject({ status: "active", continuationCount: 1 });
  });

  it("does not start its own compaction while Pi compaction is in flight", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1, maxContextPercent: 95 })(
      pi as never,
    );
    const ctx = createMockContext({
      branch: [customGoalEntry(activeGoal())],
      contextPercent: 99,
    });

    await startSession(pi, ctx);
    await emit(pi, "session_before_compact", ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(ctx.compact).not.toHaveBeenCalled();
    expect(pi.sendMessage).not.toHaveBeenCalled();
    expect(pi.appendEntry).not.toHaveBeenCalled();

    ctx.getContextUsage.mockReturnValue({
      tokens: 10,
      contextWindow: 100,
      percent: null,
    });
    await emit(pi, "session_compact", ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(ctx.compact).not.toHaveBeenCalled();
    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const nextGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(nextGoal).toMatchObject({ status: "active", continuationCount: 1 });
  });

  it("blocks instead of continuing when the continuation budget is exhausted", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [
        customGoalEntry(
          activeGoal({ continuationCount: 1, maxContinuations: 1 }),
        ),
      ],
    });

    await startSession(pi, ctx);
    await vi.advanceTimersByTimeAsync(1);

    expect(pi.sendMessage).not.toHaveBeenCalled();
    const blockedGoal = pi.appendEntry.mock.calls[0][1].goal;
    expect(blockedGoal).toMatchObject({
      status: "blocked",
      blocker: "Continuation budget exhausted (1/1).",
    });
    expect(ctx.ui.notify).toHaveBeenCalledWith(
      "Goal blocked: continuation budget exhausted",
      "warning",
    );
  });

  it("does not continue paused, blocked, or complete goals", async () => {
    vi.useFakeTimers();
    for (const status of ["paused", "blocked", "complete"] as const) {
      const pi = createMockPi();
      createGoalExtension({ continuationDelayMs: 1 })(pi as never);
      const ctx = createMockContext({
        branch: [customGoalEntry(activeGoal({ status }))],
      });
      await startSession(pi, ctx);
      await emit(pi, "agent_end", ctx);
      await vi.advanceTimersByTimeAsync(5);
      expect(pi.sendMessage).not.toHaveBeenCalled();
    }
  });

  it("allows model-requested completion before the continuation budget is exhausted", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [
        customGoalEntry(
          activeGoal({ continuationCount: 1, maxContinuations: 3 }),
        ),
      ],
      pending: true,
    });
    await startSession(pi, ctx);

    await pi.tools
      .get("update_goal")
      ?.execute(
        "tc-complete-early",
        { status: "complete", summary: "Done with evidence." },
        undefined,
        undefined,
        ctx,
      );

    const updatedGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(updatedGoal.status).toBe("complete");
    expect(updatedGoal.completedAt).toBeDefined();
  });

  it("keeps going when completion leaves unfinished tasks", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [
        customGoalEntry(
          activeGoal({
            continuationCount: 1,
            maxContinuations: 3,
            tasks: [
              { id: "task-1", title: "Write tests", status: "completed" },
              { id: "task-2", title: "Run validation", status: "pending" },
            ],
          }),
        ),
      ],
      pending: true,
    });
    await startSession(pi, ctx);

    const result = await pi.tools
      .get("update_goal")
      ?.execute(
        "tc-complete-with-pending",
        { status: "complete", summary: "Implementation done." },
        undefined,
        undefined,
        ctx,
      );

    expect(result?.isError).toBeUndefined();
    const updatedGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(updatedGoal).toMatchObject({
      status: "active",
      continuationCount: 1,
      maxContinuations: 3,
      completedAt: undefined,
    });
    expect(updatedGoal.summary).toContain("Implementation done.");
    expect(updatedGoal.summary).toContain(
      "Completion deferred: unfinished tasks remain (Run validation).",
    );
  });

  it("tracks task start and completion elapsed time from status updates", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-06-18T00:00:00.000Z"));
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [
        customGoalEntry(
          activeGoal({
            tasks: [{ id: "task-1", title: "Write tests", status: "pending" }],
          }),
        ),
      ],
      pending: true,
    });
    await startSession(pi, ctx);

    vi.setSystemTime(new Date("2026-06-18T00:01:00.000Z"));
    await pi.tools
      .get("update_goal")
      ?.execute(
        "tc-start",
        { task_updates: [{ id: "task-1", status: "in_progress" }] },
        undefined,
        undefined,
        ctx,
      );
    const startedGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(startedGoal.tasks[0]).toMatchObject({
      status: "in_progress",
      startedAt: "2026-06-18T00:01:00.000Z",
    });

    vi.setSystemTime(new Date("2026-06-18T00:03:30.000Z"));
    await pi.tools
      .get("update_goal")
      ?.execute(
        "tc-complete",
        { task_updates: [{ id: "task-1", status: "completed" }] },
        undefined,
        undefined,
        ctx,
      );
    const completedGoal = pi.appendEntry.mock.calls.at(-1)?.[1].goal;
    expect(completedGoal.tasks[0]).toMatchObject({
      status: "completed",
      startedAt: "2026-06-18T00:01:00.000Z",
      completedAt: "2026-06-18T00:03:30.000Z",
      elapsedMs: 150_000,
    });
  });

  it("rejects stale goal updates", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [customGoalEntry(activeGoal())],
      pending: true,
    });
    await startSession(pi, ctx);

    const result = await pi.tools
      .get("update_goal")
      ?.execute(
        "tc-update",
        { goal_id: "old-goal", status: "complete" },
        undefined,
        undefined,
        ctx,
      );

    expect(result?.isError).toBe(true);
    expect(result?.content[0].text).toContain("Stale goal id");
    expect(pi.appendEntry).not.toHaveBeenCalled();
  });

  it("updates goal tasks and terminal status through the model tool", async () => {
    vi.useFakeTimers();
    const pi = createMockPi();
    createGoalExtension({ continuationDelayMs: 1 })(pi as never);
    const ctx = createMockContext({
      branch: [
        customGoalEntry(
          activeGoal({
            continuationCount: 3,
            maxContinuations: 3,
            tasks: [{ id: "task-1", title: "Write tests", status: "pending" }],
          }),
        ),
      ],
      pending: true,
    });
    await startSession(pi, ctx);

    const result = await pi.tools.get("update_goal")?.execute(
      "tc-update",
      {
        goal_id: "goal-1",
        status: "complete",
        summary: "Goal runner extension implemented and tested.",
        task_updates: [{ id: "task-1", status: "completed" }],
      },
      undefined,
      undefined,
      ctx,
    );

    expect(result?.isError).toBeUndefined();
    const updatedGoal = pi.appendEntry.mock.calls[0][1].goal;
    expect(updatedGoal).toMatchObject({
      status: "complete",
      summary: "Goal runner extension implemented and tested.",
    });
    expect(updatedGoal.tasks[0]).toMatchObject({ status: "completed" });
  });
});

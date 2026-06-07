import { describe, expect, it, vi } from "vitest";

import {
  createOppiGoalExtension,
  latestGoalStateFromEntries,
  renderGoalLines,
  type OppiGoalState,
} from "../../pi-extensions/oppi-goal.ts";

interface RegisteredCommand {
  description?: string;
  handler: (args: string, ctx: MockExtensionContext) => Promise<void>;
}

interface RegisteredTool {
  name: string;
  prepareArguments?: (args: unknown) => unknown;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal: AbortSignal | undefined,
    onUpdate: undefined,
    ctx: MockExtensionContext,
  ) => Promise<{ content: Array<{ type: string; text: string }>; details?: unknown }>;
}

interface MockPi {
  commands: Map<string, RegisteredCommand>;
  tools: Map<string, RegisteredTool>;
  handlers: Map<string, Array<(event: unknown, ctx: MockExtensionContext) => unknown>>;
  appendEntry: ReturnType<typeof vi.fn>;
  sendMessage: ReturnType<typeof vi.fn>;
  sendUserMessage: ReturnType<typeof vi.fn>;
}

interface MockExtensionContext {
  sessionManager: {
    getEntries: () => unknown[];
    getBranch: () => unknown[];
  };
  ui: {
    setWidget: ReturnType<typeof vi.fn>;
    notify: ReturnType<typeof vi.fn>;
  };
  isIdle: ReturnType<typeof vi.fn>;
  hasPendingMessages: ReturnType<typeof vi.fn>;
}

interface RenderedGoalWidget {
  lines?: string[];
  nativeSurface?: unknown;
}

type GoalWidgetContent =
  | string[]
  | undefined
  | ((
      tui: unknown,
      theme: unknown,
    ) => {
      render: (width?: number) => string[];
      invalidate?: () => void;
      renderNative?: () => unknown;
    });

function createMockPi(): MockPi {
  const commands = new Map<string, RegisteredCommand>();
  const tools = new Map<string, RegisteredTool>();
  const handlers = new Map<string, Array<(event: unknown, ctx: MockExtensionContext) => unknown>>();
  return {
    commands,
    tools,
    handlers,
    appendEntry: vi.fn(),
    sendMessage: vi.fn(),
    sendUserMessage: vi.fn(),
    registerCommand(name: string, command: RegisteredCommand) {
      commands.set(name, command);
    },
    registerTool(tool: RegisteredTool) {
      tools.set(tool.name, tool);
    },
    on(event: string, handler: (event: unknown, ctx: MockExtensionContext) => unknown) {
      const eventHandlers = handlers.get(event) ?? [];
      eventHandlers.push(handler);
      handlers.set(event, eventHandlers);
    },
  } as MockPi;
}

function createMockContext(entries: unknown[] = [], branchEntries = entries): MockExtensionContext {
  return {
    sessionManager: {
      getEntries: () => entries,
      getBranch: () => branchEntries,
    },
    ui: {
      setWidget: vi.fn(),
      notify: vi.fn(),
    },
    isIdle: vi.fn(() => true),
    hasPendingMessages: vi.fn(() => false),
  };
}

function defaultEventPayload(event: string): Record<string, unknown> {
  if (event !== "agent_end") return {};
  return {
    messages: [
      {
        role: "assistant",
        content: [{ type: "text", text: "Turn finished." }],
        stopReason: "stop",
      },
    ],
  };
}

async function emit(
  pi: MockPi,
  event: string,
  ctx: MockExtensionContext,
  payload: Record<string, unknown> = {},
): Promise<void> {
  for (const handler of pi.handlers.get(event) ?? []) {
    await handler({ type: event, ...defaultEventPayload(event), ...payload }, ctx);
  }
}

function renderLastGoalWidget(ctx: MockExtensionContext): RenderedGoalWidget {
  const calls = ctx.ui.setWidget.mock.calls as Array<[string, GoalWidgetContent, unknown?]>;
  let call: [string, GoalWidgetContent, unknown?] | undefined;
  for (let index = calls.length - 1; index >= 0; index -= 1) {
    const candidate = calls[index];
    if (candidate?.[0] === "goal") {
      call = candidate;
      break;
    }
  }
  const content = call?.[1];
  if (content === undefined || Array.isArray(content)) {
    return { lines: content };
  }
  const component = content({}, {});
  return {
    lines: component.render(88),
    nativeSurface: component.renderNative?.(),
  };
}

function activeState(objective = "Simplify queue projection"): OppiGoalState {
  return {
    version: 1,
    objective,
    status: "active",
    createdAt: Date.now(),
    updatedAt: Date.now(),
    turnCount: 0,
    continuationCount: 0,
    maxTurns: 100,
    maxElapsedMs: 8 * 60 * 60 * 1000,
  };
}

describe("oppi-goal extension helpers", () => {
  it("renders the active goal as generic widget lines", () => {
    const lines = renderGoalLines(activeState("Delete duplicate queue probing and keep going"));

    expect(lines[0]).toBe("Goal: Pursuing goal");
    expect(lines[1]).toContain("Delete duplicate queue probing");
    expect(lines[2]).toContain("0/100 turns");
  });

  it("bounds widget lines to the requested TUI width", () => {
    const lines = renderGoalLines(
      activeState(
        "Delete duplicate queue probing and keep going through every remaining validation step",
      ),
      Date.now(),
      32,
    );

    expect(lines.every((line) => line.length <= 32)).toBe(true);
    expect(lines.some((line) => line.endsWith("..."))).toBe(true);
  });

  it("restores the latest valid goal entry", () => {
    const oldState = activeState("Old goal");
    const latestState = { ...activeState("Latest goal"), turnCount: 3 };

    expect(
      latestGoalStateFromEntries([
        { type: "custom", customType: "oppi-goal", data: oldState },
        { type: "custom", customType: "other", data: latestState },
        { type: "custom", customType: "oppi-goal", data: latestState },
      ])?.objective,
    ).toBe("Latest goal");
  });
});

describe("oppi-goal extension", () => {
  it("starts a goal with a durable entry, widget, and kickoff message", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);

    await pi.commands.get("goal")?.handler("Simplify the runtime bridge", ctx);

    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({
        objective: "Simplify the runtime bridge",
        status: "active",
      }),
    );
    expect(ctx.ui.setWidget).toHaveBeenCalledWith("goal", expect.any(Function), {
      placement: "aboveEditor",
    });
    expect(renderLastGoalWidget(ctx).lines).toEqual(
      expect.arrayContaining(["Goal: Pursuing goal"]),
    );
    expect(pi.sendUserMessage).toHaveBeenCalledWith(
      expect.stringContaining("Simplify the runtime bridge"),
    );
  });

  it("re-emits the widget on session_start when an active goal exists", async () => {
    const pi = createMockPi();
    const ctx = createMockContext([
      { type: "custom", customType: "oppi-goal", data: activeState("Keep working") },
    ]);
    createOppiGoalExtension(pi as never);

    await emit(pi, "session_start", ctx);

    expect(ctx.ui.setWidget).toHaveBeenCalledWith("goal", expect.any(Function), {
      placement: "aboveEditor",
    });
    expect(renderLastGoalWidget(ctx).lines).toEqual(
      expect.arrayContaining(["Goal: Pursuing goal"]),
    );
  });

  it("restores goal state from the active branch instead of stale sibling entries", async () => {
    const pi = createMockPi();
    const branchState = activeState("Branch goal");
    const inactiveLatestState = activeState("Inactive latest goal");
    const ctx = createMockContext(
      [
        { type: "custom", customType: "oppi-goal", data: branchState },
        { type: "custom", customType: "oppi-goal", data: inactiveLatestState },
      ],
      [{ type: "custom", customType: "oppi-goal", data: branchState }],
    );
    createOppiGoalExtension(pi as never);

    await emit(pi, "session_start", ctx);

    const rendered = renderLastGoalWidget(ctx).lines?.join("\n") ?? "";
    expect(rendered).toContain("Branch goal");
    expect(rendered).not.toContain("Inactive latest goal");
  });

  it("refreshes or clears active goal state after tree navigation", async () => {
    const pi = createMockPi();
    const oldBranchState = activeState("Old branch goal");
    const newBranchState = activeState("New branch goal");
    const branchEntries = [{ type: "custom", customType: "oppi-goal", data: oldBranchState }];
    const ctx = createMockContext(
      [
        { type: "custom", customType: "oppi-goal", data: oldBranchState },
        { type: "custom", customType: "oppi-goal", data: newBranchState },
      ],
      branchEntries,
    );
    createOppiGoalExtension(pi as never);

    await emit(pi, "session_start", ctx);
    expect(renderLastGoalWidget(ctx).lines?.join("\n")).toContain("Old branch goal");

    branchEntries.splice(0, branchEntries.length);
    ctx.ui.setWidget.mockClear();
    pi.sendMessage.mockClear();
    await emit(pi, "session_tree", ctx);
    await emit(pi, "agent_end", ctx);

    expect(ctx.ui.setWidget).toHaveBeenCalledWith("goal", undefined);
    expect(pi.sendMessage).not.toHaveBeenCalled();

    branchEntries.push({ type: "custom", customType: "oppi-goal", data: newBranchState });
    await emit(pi, "session_tree", ctx);

    const rendered = renderLastGoalWidget(ctx).lines?.join("\n") ?? "";
    expect(rendered).toContain("New branch goal");
    expect(rendered).not.toContain("Old branch goal");
  });

  it("queues a hidden follow-up after agent_end while the goal is active", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Keep going", ctx);

    pi.appendEntry.mockClear();
    ctx.ui.setWidget.mockClear();
    await emit(pi, "agent_end", ctx);

    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({
        turnCount: 1,
        continuationCount: 1,
      }),
    );
    expect(pi.appendEntry.mock.calls.at(-1)?.[1]).not.toHaveProperty("continuationQueued");
    expect(pi.sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        customType: "oppi-goal-continuation",
        content: expect.stringContaining("Continue pursuing the active goal"),
        display: false,
      }),
      { triggerTurn: true, deliverAs: "followUp" },
    );
    expect(ctx.ui.setWidget).toHaveBeenCalledWith("goal", expect.any(Function), {
      placement: "aboveEditor",
    });
    expect(renderLastGoalWidget(ctx).lines).toEqual(
      expect.arrayContaining(["Goal: Pursuing goal"]),
    );
  });

  it("does not let stale queued persistence block a new continuation", async () => {
    const pi = createMockPi();
    const staleState = { ...activeState("Keep going"), continuationCount: 1, continuationQueued: true };
    const ctx = createMockContext([
      { type: "custom", customType: "oppi-goal", data: staleState },
    ]);
    createOppiGoalExtension(pi as never);

    await emit(pi, "session_start", ctx);
    pi.appendEntry.mockClear();
    pi.sendMessage.mockClear();

    await emit(pi, "agent_end", ctx);

    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({
        turnCount: 1,
        continuationCount: 2,
      }),
    );
    expect(pi.appendEntry.mock.calls.at(-1)?.[1]).not.toHaveProperty("continuationQueued");
    expect(pi.sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ customType: "oppi-goal-continuation" }),
      { triggerTurn: true, deliverAs: "followUp" },
    );
  });

  it("does not auto-continue over pending user messages", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    ctx.hasPendingMessages.mockReturnValue(true);
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Keep going", ctx);

    pi.sendMessage.mockClear();
    await emit(pi, "agent_end", ctx);

    expect(pi.sendMessage).not.toHaveBeenCalled();
    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({ turnCount: 1 }),
    );
  });

  it("blocks instead of looping after an empty agent error", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Keep going", ctx);

    pi.appendEntry.mockClear();
    pi.sendMessage.mockClear();
    await emit(pi, "agent_end", ctx, {
      messages: [
        {
          role: "assistant",
          content: [],
          stopReason: "error",
          errorMessage: "provider stream ended",
        },
      ],
    });

    expect(pi.sendMessage).not.toHaveBeenCalled();
    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({
        status: "blocked",
        turnCount: 1,
        blocker: expect.stringContaining("provider stream ended"),
      }),
    );
    expect(renderLastGoalWidget(ctx).lines).toEqual(
      expect.arrayContaining(["Goal: Goal blocked"]),
    );
  });

  it("keeps only current goal prompts in model context", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Keep going", ctx);
    const handler = pi.handlers.get("context")?.[0];

    const result = handler?.(
      {
        messages: [
          { customType: "oppi-goal-context", content: "old goal context" },
          { content: "normal message" },
          { customType: "oppi-goal-continuation", content: "stale continuation" },
          { role: "assistant", content: "previous response" },
          { customType: "oppi-goal-context", content: "latest goal context" },
          { customType: "oppi-goal-continuation", content: "current continuation" },
        ],
      },
      ctx,
    ) as { messages: Array<{ content: string }> } | undefined;

    expect(result?.messages.map((message) => message.content)).toEqual([
      "normal message",
      "previous response",
      "latest goal context",
      "current continuation",
    ]);
  });

  it("lets the model complete the goal and clears the widget", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Finish this", ctx);

    ctx.ui.setWidget.mockClear();
    const result = await pi.tools
      .get("goal_update")
      ?.execute("tool-1", { status: "complete", summary: "Done." }, undefined, undefined, ctx);

    expect(result?.content[0]?.text).toContain("Goal complete");
    expect(ctx.ui.setWidget).toHaveBeenCalledWith("goal", undefined);
    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({ status: "complete", lastSummary: "Done." }),
    );
  });

  it("keeps blocked goals visible and restorable without continuing", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Finish this", ctx);

    ctx.ui.setWidget.mockClear();
    pi.sendMessage.mockClear();
    const result = await pi.tools.get("goal_update")?.execute(
      "tool-1",
      { status: "blocked", blocker: "Waiting for credentials." },
      undefined,
      undefined,
      ctx,
    );

    expect(result?.content[0]?.text).toContain("Goal blocked");
    expect(renderLastGoalWidget(ctx).lines).toEqual(
      expect.arrayContaining(["Goal: Goal blocked", "  Waiting for credentials."]),
    );
    await emit(pi, "agent_end", ctx);
    expect(pi.sendMessage).not.toHaveBeenCalled();

    const blockedState = pi.appendEntry.mock.calls.at(-1)?.[1] as OppiGoalState;
    const restoredPi = createMockPi();
    const restoredCtx = createMockContext([
      { type: "custom", customType: "oppi-goal", data: blockedState },
    ]);
    createOppiGoalExtension(restoredPi as never);
    await emit(restoredPi, "session_start", restoredCtx);

    expect(renderLastGoalWidget(restoredCtx).lines).toEqual(
      expect.arrayContaining(["Goal: Goal blocked", "  Waiting for credentials."]),
    );
  });

  it("treats top-level status in_progress as active for common agent mistakes", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Ship goal tasks", ctx);
    const tool = pi.tools.get("goal_update");
    const params = tool?.prepareArguments?.({
      status: "in_progress",
      tasks: [{ title: "Inspect current extension packaging", status: "in_progress" }],
    }) as Record<string, unknown>;

    await tool?.execute("tool-1", params, undefined, undefined, ctx);

    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({
        status: "active",
        tasks: [expect.objectContaining({ status: "in_progress" })],
      }),
    );
  });

  it("renders durable tasks as a checklist and native activity surface", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Ship goal tasks", ctx);

    await pi.tools.get("goal_update")?.execute(
      "tool-1",
      {
        tasks: [
          { title: "Inspect current extension packaging", status: "completed" },
          { title: "Implement task persistence", status: "in_progress" },
          { title: "Run checks", status: "pending" },
        ],
      },
      undefined,
      undefined,
      ctx,
    );

    const widget = renderLastGoalWidget(ctx);
    expect(widget.lines?.[0]).toBe("1 of 3 tasks completed");
    expect(widget.lines).toContain("  [x] 1. Inspect current extension packaging");
    expect(widget.lines).toContain("  [~] 2. Implement task persistence");

    expect(widget.nativeSurface).toMatchObject({
      presentation: {
        style: "surfacePanel",
        title: "1 of 3 tasks completed",
      },
      blocks: [
        { type: "progress", value: 1 / 3 },
        {
          type: "activityList",
          rows: [
            expect.objectContaining({
              title: "1. Inspect current extension packaging",
              state: "success",
            }),
            expect.objectContaining({ title: "2. Implement task persistence", state: "running" }),
            expect.objectContaining({ title: "3. Run checks", state: "queued" }),
          ],
        },
      ],
    });
    expect(widget.nativeSurface).not.toHaveProperty("lifecycle");
    expect(widget.nativeSurface).not.toMatchObject({
      presentation: { placement: expect.any(String) },
    });
    expect(pi.appendEntry).toHaveBeenCalledWith(
      "oppi-goal",
      expect.objectContaining({
        tasks: expect.arrayContaining([
          expect.objectContaining({
            title: "Inspect current extension packaging",
            status: "completed",
          }),
        ]),
      }),
    );
  });

  it("updates checklist items by one-based widget index", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Ship goal tasks", ctx);
    await pi.tools.get("goal_update")?.execute(
      "tool-1",
      {
        tasks: [
          { title: "Inspect current extension packaging", status: "in_progress" },
          { title: "Run checks", status: "pending" },
        ],
      },
      undefined,
      undefined,
      ctx,
    );

    await pi.tools.get("goal_update")?.execute(
      "tool-2",
      {
        taskUpdates: [
          { index: 1, status: "completed" },
          { index: 2, status: "in_progress" },
        ],
      },
      undefined,
      undefined,
      ctx,
    );

    const widget = renderLastGoalWidget(ctx);
    expect(widget.lines?.[0]).toBe("1 of 2 tasks completed");
    expect(widget.lines).toContain("  [x] 1. Inspect current extension packaging");
    expect(widget.lines).toContain("  [~] 2. Run checks");
  });

  it("includes terminal goal status when completing a checklist goal", async () => {
    const pi = createMockPi();
    const ctx = createMockContext();
    createOppiGoalExtension(pi as never);
    await pi.commands.get("goal")?.handler("Ship goal tasks", ctx);
    await pi.tools.get("goal_update")?.execute(
      "tool-1",
      {
        tasks: [
          { title: "Inspect current extension packaging", status: "completed" },
          { title: "Run checks", status: "completed" },
        ],
      },
      undefined,
      undefined,
      ctx,
    );

    const result = await pi.tools
      .get("goal_update")
      ?.execute("tool-2", { status: "complete", summary: "Done." }, undefined, undefined, ctx);

    expect(result?.content[0]?.text).toContain("2 of 2 tasks completed");
    expect(result?.content[0]?.text).toContain("Goal complete");
  });
});

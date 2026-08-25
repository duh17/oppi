import type { AgentSession } from "@earendil-works/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";

import { SessionCommandCoordinator, type CommandSessionState } from "../src/session-commands.js";
import type { SdkBackend } from "../src/sdk-backend.js";
import type { Session } from "../src/types.js";

function makeSession(id = "s1"): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function makeCoordinator(
  agentSession: AgentSession,
  options: {
    sdkBackend?: Partial<SdkBackend>;
    reloadRuntimeConfig?: () => void;
    session?: Session;
    cacheMissTracker?: CommandSessionState["cacheMissTracker"];
  } = {},
): {
  coordinator: SessionCommandCoordinator;
  broadcast: ReturnType<typeof vi.fn>;
} {
  const activeState: CommandSessionState = {
    session: options.session ?? makeSession(),
    sdkBackend: {
      session: agentSession,
      ...options.sdkBackend,
    } as unknown as SdkBackend,
    cacheMissTracker: options.cacheMissTracker,
  };

  const broadcast = vi.fn();

  const coordinator = new SessionCommandCoordinator({
    getActiveSession: vi.fn(() => activeState),
    persistSessionNow: vi.fn(),
    broadcast,
    applyPiStateSnapshot: vi.fn(() => false),
    getContextWindowResolver: vi.fn(() => null),
    reloadRuntimeConfig: options.reloadRuntimeConfig,
  });

  return { coordinator, broadcast };
}

describe("SessionCommandCoordinator", () => {
  it.each([
    { persist: undefined, expectedOptions: undefined },
    { persist: false, expectedOptions: undefined },
    { persist: true, expectedOptions: { persist: true } },
  ])("routes set_model persistence intent to the SDK backend", async ({ persist, expectedOptions }) => {
    const setModel = vi.fn(async () => ({ success: true as const }));
    const { coordinator } = makeCoordinator({} as AgentSession, {
      sdkBackend: { setModel },
    });

    await coordinator.sendCommandAsync("s1", {
      type: "set_model",
      provider: "openai-codex",
      modelId: "gpt-5.6-sol",
      ...(persist !== undefined ? { persist } : {}),
    });

    if (expectedOptions) {
      expect(setModel).toHaveBeenCalledWith("openai-codex/gpt-5.6-sol", expectedOptions);
    } else {
      expect(setModel).toHaveBeenCalledWith("openai-codex/gpt-5.6-sol", undefined);
    }
  });

  it("allows reload and refreshes runtime config before SDK resources", async () => {
    const calls: string[] = [];
    const reloadResources = vi.fn(async (reloadConfig?: () => void) => {
      reloadConfig?.();
      calls.push("resources");
      return { success: true as const };
    });
    const reloadRuntimeConfig = vi.fn(() => calls.push("config"));
    const { coordinator } = makeCoordinator({} as AgentSession, {
      sdkBackend: { reloadResources },
      reloadRuntimeConfig,
    });

    expect(coordinator.isAllowedCommand("reload")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", { type: "reload" });

    expect(result).toEqual({ success: true });
    expect(reloadRuntimeConfig).toHaveBeenCalledOnce();
    expect(reloadResources).toHaveBeenCalledOnce();
    expect(calls).toEqual(["config", "resources"]);
  });

  it("rejects reload before config or Pi shutdown while a model turn is active", async () => {
    const reloadResources = vi.fn(async () => ({ success: true as const }));
    const reloadRuntimeConfig = vi.fn();
    const active = makeSession("busy-session");
    active.status = "busy";
    const busyCoordinator = makeCoordinator({} as AgentSession, {
      session: active,
      sdkBackend: { reloadResources },
      reloadRuntimeConfig,
    }).coordinator;

    await expect(
      busyCoordinator.sendCommandAsync("busy-session", { type: "reload" }),
    ).rejects.toThrow("reload requires an idle session");
    expect(reloadRuntimeConfig).not.toHaveBeenCalled();
    expect(reloadResources).not.toHaveBeenCalled();
    expect(busyCoordinator.isAllowedCommand("reload")).toBe(true);
  });

  it("does not admit a new model turn while reload is rebuilding", async () => {
    let finishReload: (() => void) | undefined;
    let isReloading = false;
    const pendingReload = new Promise<void>((resolve) => {
      finishReload = resolve;
    });
    const reloadResources = vi.fn(async () => {
      isReloading = true;
      await pendingReload;
      isReloading = false;
      return { success: true as const };
    });
    const piPrompt = vi.fn();
    const prompt = vi.fn((...args: unknown[]) => {
      if (isReloading) {
        throw new Error("prompt cannot start while reload is rebuilding the session");
      }
      piPrompt(...args);
    });
    const { coordinator } = makeCoordinator({} as AgentSession, {
      sdkBackend: {
        reloadResources,
        prompt,
        get isReloading() {
          return isReloading;
        },
      },
    });

    const reloadPromise = coordinator.sendCommandAsync("s1", { type: "reload" });
    expect(reloadResources).toHaveBeenCalledOnce();
    expect(() => coordinator.sendCommand("s1", { type: "prompt", message: "overlap" })).toThrow(
      "prompt cannot start while reload is rebuilding the session",
    );
    expect(piPrompt).not.toHaveBeenCalled();

    finishReload?.();
    await expect(reloadPromise).resolves.toEqual({ success: true });
    coordinator.sendCommand("s1", { type: "prompt", message: "after" });
    expect(piPrompt).toHaveBeenCalledOnce();
  });

  it("returns full-history cache and per-model usage from get_session_stats", async () => {
    const entries = [
      {
        type: "message",
        message: {
          role: "assistant",
          provider: "anthropic",
          model: "claude-sonnet",
          timestamp: 1_000,
          usage: {
            input: 1_000,
            output: 100,
            cacheRead: 69_000,
            cacheWrite: 0,
            cost: { input: 0.012, output: 0.002, cacheRead: 0.069, cacheWrite: 0, total: 0.083 },
          },
        },
      },
      {
        type: "message",
        message: {
          role: "assistant",
          provider: "anthropic",
          model: "claude-sonnet",
          timestamp: 310_700,
          usage: {
            input: 70_000,
            output: 200,
            cacheRead: 0,
            cacheWrite: 0,
            cost: { input: 0.84, output: 0.004, cacheRead: 0, cacheWrite: 0, total: 0.844 },
          },
        },
      },
      {
        type: "message",
        message: {
          role: "toolResult",
          usage: {
            input: 10,
            output: 5,
            cacheRead: 0,
            cacheWrite: 0,
            cost: { input: 0.01, output: 0.02, cacheRead: 0, cacheWrite: 0, total: 0.03 },
          },
        },
      },
      {
        type: "branch_summary",
        usage: {
          input: 20,
          output: 10,
          cacheRead: 0,
          cacheWrite: 0,
          cost: { input: 0.02, output: 0.02, cacheRead: 0, cacheWrite: 0, total: 0.04 },
        },
      },
      {
        type: "message",
        message: {
          role: "assistant",
          provider: "openai-codex",
          model: "gpt-5.6-sol",
          responseModel: "gpt-5.6-sol-2026-07-01",
          timestamp: 320_000,
          usage: {
            input: 10_000,
            output: 500,
            cacheRead: 20_000,
            cacheWrite: 0,
            cost: { input: 0.1, output: 0.02, cacheRead: 0.02, cacheWrite: 0, total: 0.14 },
          },
        },
      },
    ];
    const agentSession = {
      getSessionStats: () => ({
        tokens: { input: 81_030, output: 815, cacheRead: 89_000, cacheWrite: 0, total: 170_845 },
        cost: 1.137,
      }),
      systemPrompt: "system",
      sessionManager: { getEntries: () => entries },
      resourceLoader: {
        getAgentsFiles: () => ({ agentsFiles: [] }),
        getSkills: () => ({ skills: [] }),
        getExtensions: () => ({ extensions: [] }),
      },
    } as unknown as AgentSession;
    const { coordinator } = makeCoordinator(agentSession, {
      sdkBackend: {
        cacheMissModelPriceSource: { find: () => ({ cost: { cacheRead: 1 } }) },
      },
    });

    const result = await coordinator.sendCommandAsync("s1", { type: "get_session_stats" });

    expect(result).toMatchObject({
      cacheWaste: { missedTokens: 70_000, missedCost: expect.closeTo(0.77, 6), missCount: 1 },
      modelBreakdown: [
        {
          provider: "anthropic",
          model: "claude-sonnet",
          tokens: 140_300,
          cost: expect.closeTo(0.927, 6),
        },
        { provider: "openai-codex", model: "gpt-5.6-sol-2026-07-01", tokens: 30_500, cost: 0.14 },
        { model: "Tools & summaries", tokens: 45, cost: 0.07 },
      ],
    });
  });

  it("supports get_commands passthrough", async () => {
    const agentSession = {
      extensionRunner: {
        getRegisteredCommands: () => [
          {
            name: "remember",
            description: "Save note",
            sourceInfo: {
              path: "/ext/memory.js",
              source: "user",
              scope: "user",
              origin: "top-level",
            },
          },
        ],
      },
      promptTemplates: [
        {
          name: "plan",
          description: "Plan prompt",
          sourceInfo: {
            source: "project",
            path: "/repo/prompts/plan.md",
            scope: "project",
            origin: "top-level",
          },
          filePath: "/repo/prompts/plan.md",
        },
      ],
      resourceLoader: {
        getSkills: () => ({
          skills: [
            {
              name: "tmux",
              description: "Control tmux",
              sourceInfo: {
                source: "user",
                path: "/Users/me/.pi/agent/skills/tmux/SKILL.md",
                scope: "user",
                origin: "top-level",
              },
              filePath: "/Users/me/.pi/agent/skills/tmux/SKILL.md",
            },
          ],
        }),
      },
    } as unknown as AgentSession;

    const { coordinator, broadcast } = makeCoordinator(agentSession);

    expect(coordinator.isAllowedCommand("get_commands")).toBe(true);
    expect(coordinator.isAllowedCommand("share_session")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", { type: "get_commands" });

    expect(result).toEqual({
      commands: [
        {
          name: "reload",
          description: "Reload extensions, skills, prompts, and context files",
          source: "builtin",
        },
        {
          name: "share",
          description: "Share session as an auto-redacted secret GitHub gist",
          source: "builtin",
        },
        {
          name: "remember",
          description: "Save note",
          source: "extension",
          path: "/ext/memory.js",
        },
        {
          name: "plan",
          description: "Plan prompt",
          source: "prompt",
          location: "project",
          path: "/repo/prompts/plan.md",
        },
        {
          name: "skill:tmux",
          description: "Control tmux",
          source: "skill",
          location: "user",
          path: "/Users/me/.pi/agent/skills/tmux/SKILL.md",
        },
      ],
    });

    expect(broadcast).not.toHaveBeenCalled();
  });

  it("returns get_fork_messages payload as { messages: [...] }", async () => {
    const getUserMessagesForForking = vi.fn(() => [
      { entryId: "entry-1", text: "First user prompt" },
      { entryId: "entry-2", text: "Second user prompt" },
    ]);

    const agentSession = {
      getUserMessagesForForking,
    } as unknown as AgentSession;

    const { coordinator } = makeCoordinator(agentSession);

    expect(coordinator.isAllowedCommand("get_fork_messages")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", {
      type: "get_fork_messages",
    });

    expect(getUserMessagesForForking).toHaveBeenCalledTimes(1);
    expect(result).toEqual({
      messages: [
        { entryId: "entry-1", text: "First user prompt" },
        { entryId: "entry-2", text: "Second user prompt" },
      ],
    });
  });

  it("serializes get_session_tree with TUI-aligned default visibility and previews", async () => {
    const entry1 = {
      id: "entry-1",
      parentId: null,
      type: "message",
      timestamp: "2026-04-19T07:11:10.000Z",
      message: { role: "user", content: "Plan   rollout" },
    };
    const entry2 = {
      id: "entry-2",
      parentId: "entry-1",
      type: "message",
      timestamp: "2026-04-19T07:12:10.000Z",
      message: { role: "assistant", content: "Assistant answer\nextra" },
    };
    const entry3 = {
      id: "entry-3",
      parentId: "entry-1",
      type: "message",
      timestamp: "2026-04-19T07:13:10.000Z",
      message: {
        role: "user",
        content: [
          { type: "text", text: "Second branch" },
          { type: "image", data: "ignored" },
        ],
      },
    };
    const entry4 = {
      id: "entry-4",
      parentId: "entry-2",
      type: "compaction",
      timestamp: "2026-04-19T07:14:10.000Z",
      summary: "compacted",
      firstKeptEntryId: "entry-2",
      tokensBefore: 12_000,
    };
    const entry5 = {
      id: "entry-5",
      parentId: "entry-4",
      type: "message",
      timestamp: "2026-04-19T07:15:10.000Z",
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "tool-call-1",
            name: "read",
            arguments: {
              path: "/Users/testuser/workspace/oppi/clients/apple/Oppi/Features/Chat/ChatView.swift",
              offset: 10,
              limit: 5,
            },
          },
        ],
      },
    };
    const entry6 = {
      id: "entry-6",
      parentId: "entry-5",
      type: "message",
      timestamp: "2026-04-19T07:16:10.000Z",
      message: {
        role: "toolResult",
        toolCallId: "tool-call-1",
        toolName: "read",
        content: "file contents that should not be used as preview",
      },
    };
    const entry7 = {
      id: "entry-7",
      parentId: "entry-6",
      type: "session_info",
      timestamp: "2026-04-19T07:17:10.000Z",
      name: "Pinned title",
    };

    const byId = new Map<string, unknown>([
      [entry1.id, entry1],
      [entry2.id, entry2],
      [entry3.id, entry3],
      [entry4.id, entry4],
      [entry5.id, entry5],
      [entry6.id, entry6],
      [entry7.id, entry7],
    ]);

    const getTree = vi.fn(() => [
      {
        entry: entry1,
        children: [
          {
            entry: entry3,
            children: [],
          },
          {
            entry: entry2,
            children: [
              {
                entry: entry4,
                children: [
                  {
                    entry: entry5,
                    children: [
                      {
                        entry: entry6,
                        children: [
                          {
                            entry: entry7,
                            children: [],
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
        label: "Root label",
      },
    ]);

    const getLeafId = vi.fn(() => "entry-3");
    const getEntry = vi.fn((id: string) => byId.get(id));

    const agentSession = {
      sessionManager: {
        getTree,
        getLeafId,
        getEntry,
      },
    } as unknown as AgentSession;

    const { coordinator } = makeCoordinator(agentSession);

    expect(coordinator.isAllowedCommand("get_session_tree")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", {
      type: "get_session_tree",
    });

    expect(result).toEqual({
      leafId: "entry-3",
      nodes: [
        {
          id: "entry-1",
          parentId: null,
          type: "message",
          timestamp: "2026-04-19T07:11:10.000Z",
          depth: 0,
          isLeafPath: true,
          defaultVisible: true,
          matchesFilter: true,
          role: "user",
          textPreview: "Plan rollout",
          label: "Root label",
        },
        {
          id: "entry-3",
          parentId: "entry-1",
          type: "message",
          timestamp: "2026-04-19T07:13:10.000Z",
          depth: 1,
          isLeafPath: true,
          defaultVisible: true,
          matchesFilter: true,
          role: "user",
          textPreview: "Second branch",
        },
        {
          id: "entry-2",
          parentId: "entry-1",
          type: "message",
          timestamp: "2026-04-19T07:12:10.000Z",
          depth: 1,
          isLeafPath: false,
          defaultVisible: true,
          matchesFilter: true,
          role: "assistant",
          textPreview: "Assistant answer extra",
        },
        {
          id: "entry-4",
          parentId: "entry-2",
          type: "compaction",
          timestamp: "2026-04-19T07:14:10.000Z",
          depth: 2,
          isLeafPath: false,
          defaultVisible: true,
          matchesFilter: true,
          textPreview: "12k tokens",
        },
        {
          id: "entry-5",
          parentId: "entry-4",
          type: "message",
          timestamp: "2026-04-19T07:15:10.000Z",
          depth: 3,
          isLeafPath: false,
          defaultVisible: false,
          matchesFilter: false,
          role: "assistant",
        },
        {
          id: "entry-6",
          parentId: "entry-5",
          type: "message",
          timestamp: "2026-04-19T07:16:10.000Z",
          depth: 4,
          isLeafPath: false,
          defaultVisible: true,
          matchesFilter: true,
          role: "toolResult",
          textPreview:
            "[read: /Users/testuser/workspace/oppi/clients/apple/Oppi/Features/Chat/ChatView.swift:10-14]",
        },
        {
          id: "entry-7",
          parentId: "entry-6",
          type: "session_info",
          timestamp: "2026-04-19T07:17:10.000Z",
          depth: 5,
          isLeafPath: false,
          defaultVisible: false,
          matchesFilter: false,
          textPreview: "Pinned title",
        },
      ],
    });

    expect(getTree).toHaveBeenCalledTimes(1);
    expect(getLeafId).toHaveBeenCalledTimes(1);
  });

  it("marks all filter visibility without surfacing tool-call-only assistant nodes", async () => {
    const entry1 = {
      id: "entry-1",
      parentId: null,
      type: "message",
      timestamp: "2026-04-19T07:11:10.000Z",
      message: { role: "user", content: "Plan rollout" },
    };
    const entry2 = {
      id: "entry-2",
      parentId: "entry-1",
      type: "message",
      timestamp: "2026-04-19T07:12:10.000Z",
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "tool-call-1",
            name: "read",
            arguments: { path: "/tmp/file.txt" },
          },
        ],
      },
    };
    const entry3 = {
      id: "entry-3",
      parentId: "entry-2",
      type: "message",
      timestamp: "2026-04-19T07:13:10.000Z",
      message: {
        role: "toolResult",
        toolCallId: "tool-call-1",
        toolName: "read",
        content: "ignored",
      },
    };
    const entry4 = {
      id: "entry-4",
      parentId: "entry-3",
      type: "session_info",
      timestamp: "2026-04-19T07:14:10.000Z",
      name: "Pinned title",
    };

    const getTree = vi.fn(() => [
      {
        entry: entry1,
        children: [
          {
            entry: entry2,
            children: [
              {
                entry: entry3,
                children: [
                  {
                    entry: entry4,
                    children: [],
                  },
                ],
              },
            ],
          },
        ],
      },
    ]);

    const agentSession = {
      sessionManager: {
        getTree,
        getLeafId: vi.fn(() => "entry-4"),
        getEntry: vi.fn((id: string) => {
          switch (id) {
            case "entry-4":
              return entry4;
            case "entry-3":
              return entry3;
            case "entry-2":
              return entry2;
            case "entry-1":
              return entry1;
            default:
              return undefined;
          }
        }),
      },
    } as unknown as AgentSession;

    const { coordinator } = makeCoordinator(agentSession);
    const result = (await coordinator.sendCommandAsync("s1", {
      type: "get_session_tree",
      filterMode: "all",
    })) as {
      leafId: string | null;
      nodes: Array<{ id: string; matchesFilter: boolean }>;
    };

    expect(result.leafId).toBe("entry-4");
    expect(result.nodes.map((node) => [node.id, node.matchesFilter])).toEqual([
      ["entry-1", true],
      ["entry-2", false],
      ["entry-3", true],
      ["entry-4", true],
    ]);
  });

  it("resets live cache comparison after navigation creates a branch summary", async () => {
    const cacheMissTracker = {
      previous: {
        promptTokens: 70_000,
        modelKey: "anthropic/claude-sonnet",
        timestamp: 1_000,
        reportedCache: true,
      },
    };
    const navigateTree = vi.fn(async () => ({
      cancelled: false,
      summaryEntry: { id: "summary-1" },
    }));
    const { coordinator } = makeCoordinator({ navigateTree } as unknown as AgentSession, {
      cacheMissTracker,
    });

    await coordinator.sendCommandAsync("s1", {
      type: "navigate_tree",
      targetId: "entry-12",
      summarize: true,
    });

    expect(cacheMissTracker.previous).toBeUndefined();
  });

  it("forwards navigate_tree options to AgentSession.navigateTree", async () => {
    const navigateTree = vi.fn(async () => ({
      editorText: "Prefilled draft",
      cancelled: false,
      aborted: false,
      summaryEntry: { id: "summary-1" },
    }));

    const agentSession = {
      navigateTree,
    } as unknown as AgentSession;

    const { coordinator } = makeCoordinator(agentSession);

    expect(coordinator.isAllowedCommand("navigate_tree")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", {
      type: "navigate_tree",
      targetId: "entry-12",
      summarize: true,
      customInstructions: "Focus on TODOs",
      replaceInstructions: false,
      label: "Branch summary",
    });

    expect(navigateTree).toHaveBeenCalledTimes(1);
    expect(navigateTree).toHaveBeenCalledWith("entry-12", {
      summarize: true,
      customInstructions: "Focus on TODOs",
      replaceInstructions: false,
      label: "Branch summary",
    });
    expect(result).toEqual({
      editorText: "Prefilled draft",
      cancelled: false,
      aborted: false,
      summaryEntry: { id: "summary-1" },
    });
  });

  it("rejects navigate_tree when targetId is missing or blank", async () => {
    const navigateTree = vi.fn();
    const { coordinator } = makeCoordinator({ navigateTree } as unknown as AgentSession);

    await expect(
      coordinator.sendCommandAsync("s1", {
        type: "navigate_tree",
        targetId: "   ",
      }),
    ).rejects.toThrow("Invalid payload: expected targetId");

    expect(navigateTree).not.toHaveBeenCalled();
  });

  it("refreshes get_state after navigate_tree to sync branch identity", async () => {
    const { coordinator, broadcast } = makeCoordinator({} as AgentSession);

    const sendCommandAsync = vi.fn(async (_key: string, command: Record<string, unknown>) => {
      switch (command.type) {
        case "navigate_tree":
          return {
            editorText: "Follow-up prompt",
            cancelled: false,
            aborted: false,
          };
        case "get_state":
          return { unknown: "state-payload" };
        default:
          throw new Error(`Unexpected command: ${String(command.type)}`);
      }
    });

    await coordinator.forwardClientCommand(
      "s1",
      {
        type: "navigate_tree",
        targetId: "entry-42",
      },
      "req-nav-1",
      sendCommandAsync,
    );

    expect(sendCommandAsync).toHaveBeenCalledTimes(2);
    expect(sendCommandAsync.mock.calls.map(([, command]) => command.type)).toEqual([
      "navigate_tree",
      "get_state",
    ]);

    expect(broadcast).toHaveBeenCalledWith(
      "s1",
      expect.objectContaining({
        type: "command_result",
        command: "navigate_tree",
        requestId: "req-nav-1",
        success: true,
      }),
    );
  });
});

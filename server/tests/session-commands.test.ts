import type { AgentSession } from "@mariozechner/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";

import { SessionCommandCoordinator, type CommandSessionState } from "../src/session-commands.js";
import type { SdkBackend } from "../src/sdk-backend.js";
import type { Session, ServerMessage } from "../src/types.js";

function makeSession(id = "s1"): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

describe("SessionCommandCoordinator", () => {
  it("supports get_commands passthrough", async () => {
    const agentSession = {
      extensionRunner: {
        getRegisteredCommandsWithPaths: () => [
          {
            command: { name: "remember", description: "Save note" },
            extensionPath: "/ext/memory.js",
          },
        ],
      },
      promptTemplates: [
        {
          name: "plan",
          description: "Plan prompt",
          source: "project",
          filePath: "/repo/prompts/plan.md",
        },
      ],
      resourceLoader: {
        getSkills: () => ({
          skills: [
            {
              name: "tmux",
              description: "Control tmux",
              source: "user",
              filePath: "/Users/me/.pi/agent/skills/tmux/SKILL.md",
            },
          ],
        }),
      },
    } as unknown as AgentSession;

    const activeState: CommandSessionState = {
      session: makeSession(),
      sdkBackend: {
        session: agentSession,
      } as unknown as SdkBackend,
    };

    const broadcast = vi.fn((_key: string, _message: ServerMessage) => {});

    const coordinator = new SessionCommandCoordinator({
      getActiveSession: vi.fn(() => activeState),
      persistSessionNow: vi.fn(),
      broadcast,
      applyPiStateSnapshot: vi.fn(() => false),
      applyRememberedThinkingLevel: vi.fn(async () => false),
      persistThinkingPreference: vi.fn(),
      persistWorkspaceLastUsedModel: vi.fn(),
      getContextWindowResolver: vi.fn(() => null),
    });

    expect(coordinator.isAllowedCommand("get_commands")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", { type: "get_commands" });

    expect(result).toEqual({
      commands: [
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
});

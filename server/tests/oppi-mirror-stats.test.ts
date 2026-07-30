import { describe, expect, it } from "vitest";

import { sessionStatsWire } from "../../pi-extensions/oppi-mirror/extensions/oppi-mirror.ts";

describe("oppi mirror session stats", () => {
  it("includes full-history cache and per-model usage", () => {
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
    ];
    const ctx = {
      sessionManager: {
        getEntries: () => entries,
        getSessionFile: () => "/tmp/session.jsonl",
        getSessionId: () => "pi-session-1",
      },
      getContextUsage: () => ({ tokens: 70_200, contextWindow: 200_000 }),
      getSystemPrompt: () => "system",
      modelRegistry: { find: () => ({ cost: { cacheRead: 1 } }) },
    };
    const session = {
      resourceLoader: {
        getAgentsFiles: () => ({ agentsFiles: [] }),
        getSkills: () => ({ skills: [] }),
        getExtensions: () => ({ extensions: [] }),
      },
    };

    const stats = sessionStatsWire(ctx as never, session as never);

    expect(stats).toMatchObject({
      tokens: { input: 71_000, output: 300, cacheRead: 69_000, cacheWrite: 0, total: 140_300 },
      cost: expect.closeTo(0.927, 6),
      cacheWaste: { missedTokens: 70_000, missedCost: expect.closeTo(0.77, 6), missCount: 1 },
      modelBreakdown: [
        {
          provider: "anthropic",
          model: "claude-sonnet",
          tokens: 140_300,
          cost: expect.closeTo(0.927, 6),
        },
      ],
    });
  });

  it("includes tool and summary usage in totals and the cost breakdown", () => {
    const usage = (input: number, output: number, total: number) => ({
      input,
      output,
      cacheRead: 0,
      cacheWrite: 0,
      cost: { input: total / 2, output: total / 2, cacheRead: 0, cacheWrite: 0, total },
    });
    const ctx = {
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "toolResult", usage: usage(10, 5, 0.03) } },
          { type: "compaction", usage: usage(20, 10, 0.04) },
        ],
        getSessionFile: () => "/tmp/session.jsonl",
        getSessionId: () => "pi-session-1",
      },
      getContextUsage: () => undefined,
      getSystemPrompt: () => "system",
      modelRegistry: { find: () => undefined },
    };
    const session = {
      resourceLoader: {
        getAgentsFiles: () => ({ agentsFiles: [] }),
        getSkills: () => ({ skills: [] }),
        getExtensions: () => ({ extensions: [] }),
      },
    };

    const stats = sessionStatsWire(ctx as never, session as never);

    expect(stats).toMatchObject({
      tokens: { input: 30, output: 15, cacheRead: 0, cacheWrite: 0, total: 45 },
      cost: 0.07,
      modelBreakdown: [{ model: "Tools & summaries", tokens: 45, cost: 0.07 }],
    });
  });

  it("includes context composition for the iOS Context Breakdown", () => {
    const ctx = {
      sessionManager: {
        getEntries: () => [{ id: "entry-1" }],
        getSessionFile: () => "/tmp/session.jsonl",
        getSessionId: () => "pi-session-1",
      },
      getContextUsage: () => ({ tokens: 120, contextWindow: 1000 }),
      getSystemPrompt: () => "base prompt\nagent instructions\nskill list",
    };
    const session = {
      resourceLoader: {
        getAgentsFiles: () => ({
          agentsFiles: [{ path: "/repo/AGENTS.md", content: "agent instructions" }],
        }),
        getSkills: () => ({
          skills: [
            {
              name: "sample-skill",
              description: "Sample skill for stats.",
              baseDir: "/repo/.pi/skills/sample-skill",
              filePath: "/repo/.pi/skills/sample-skill/SKILL.md",
            },
          ],
        }),
        getExtensions: () => ({ extensions: [] }),
      },
    };

    const stats = sessionStatsWire(ctx as never, session as never) as {
      contextComposition?: {
        piSystemPromptChars: number;
        agentsFiles: Array<{ path: string; chars: number; tokens: number }>;
        agentsTokens: number;
        skillsListingTokens: number;
      };
    };

    expect(stats.contextComposition).toEqual(
      expect.objectContaining({
        piSystemPromptChars: "base prompt\nagent instructions\nskill list".length,
        agentsFiles: [
          expect.objectContaining({
            path: "/repo/AGENTS.md",
            chars: "agent instructions".length,
          }),
        ],
      }),
    );
    expect(stats.contextComposition?.agentsTokens).toBeGreaterThan(0);
    expect(stats.contextComposition?.skillsListingTokens).toBeGreaterThan(0);
  });
});

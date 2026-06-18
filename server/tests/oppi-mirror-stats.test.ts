import { describe, expect, it } from "vitest";

import { sessionStatsWire } from "../../pi-extensions/oppi-mirror/extensions/oppi-mirror.ts";

describe("oppi mirror session stats", () => {
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

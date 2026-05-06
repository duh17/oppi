import { describe, expect, it } from "vitest";

import { buildSessionSummary } from "./session-summary.js";
import type { Session } from "./types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

describe("buildSessionSummary", () => {
  it("filters absolute changed file paths from summaries", () => {
    const summary = buildSessionSummary(
      makeSession({
        changeStats: {
          mutatingToolCalls: 4,
          filesChanged: 4,
          changedFiles: ["src/app.ts", "/tmp/secret.txt", "~/Library/private.txt", "  "],
          addedLines: 10,
          removedLines: 1,
        },
      }),
    );

    expect(summary.changeStats?.changedFiles).toEqual(["src/app.ts"]);
    expect(summary.changeStats?.filesChanged).toBe(4);
    expect(summary.changeStats?.changedFilesOverflow).toBe(3);
  });

  it("excludes trace and internal change tracking fields", () => {
    const summary = buildSessionSummary(
      makeSession({
        warnings: ["local warning"],
        piSessionFile: "/Users/test/.pi/agent/sessions/s1.jsonl",
        piSessionFiles: ["/Users/test/.pi/agent/sessions/s1.jsonl"],
        piSessionId: "pi-internal-session-id",
        changeStats: {
          mutatingToolCalls: 2,
          filesChanged: 1,
          changedFiles: ["src/app.ts"],
          changedFilesOverflow: 3,
          addedLines: 10,
          removedLines: 4,
          _fileLineCounts: { "src/app.ts": 42 },
          _sessionCreatedFiles: ["src/app.ts"],
        },
      }),
    );

    expect(summary).not.toHaveProperty("warnings");
    expect(summary).not.toHaveProperty("piSessionFile");
    expect(summary).not.toHaveProperty("piSessionFiles");
    expect(summary).not.toHaveProperty("piSessionId");
    expect(summary.changeStats).toEqual({
      mutatingToolCalls: 2,
      filesChanged: 1,
      changedFiles: ["src/app.ts"],
      changedFilesOverflow: 3,
      addedLines: 10,
      removedLines: 4,
    });
    expect(summary.changeStats).not.toHaveProperty("_fileLineCounts");
    expect(summary.changeStats).not.toHaveProperty("_sessionCreatedFiles");
  });
});

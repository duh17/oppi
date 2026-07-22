import { describe, expect, it } from "vitest";

import { buildSessionSummary } from "../src/session-summary.js";
import type { Session } from "../src/types.js";

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
  it("includes live assistant reply timestamp when present", () => {
    const summary = buildSessionSummary(makeSession({ lastAgentReplyAt: 1_700_000_123_000 }));
    expect(summary.lastAgentReplyAt).toBe(1_700_000_123_000);
  });

  it("projects immutable saved-Agent identity and icon metadata", () => {
    const summary = buildSessionSummary(
      makeSession({
        launch: {
          source: "agent",
          agentId: "agent-reviewer",
          agentVersion: 4,
          agentIcon: { kind: "symbol", name: "checkmark.shield" },
          status: "accepted",
          requestedAt: 100,
        },
      }),
    );

    expect(summary).toMatchObject({
      agentId: "agent-reviewer",
      agentIcon: { kind: "symbol", name: "checkmark.shield" },
    });
    expect(summary).not.toHaveProperty("agentVersion");
  });

  it("omits Agent presentation metadata for ordinary sessions", () => {
    const summary = buildSessionSummary(makeSession());

    expect(summary).not.toHaveProperty("agentId");
    expect(summary).not.toHaveProperty("agentIcon");
  });

  it("preserves explicit control-session metadata in list summaries", () => {
    const summary = buildSessionSummary(
      makeSession({
        workspaceId: undefined,
        control: {
          domain: "agents",
          intent: "revise",
          targetId: "release-reviewer",
          targetName: "Release Reviewer",
        },
      }),
    );

    expect(summary.workspaceId).toBeUndefined();
    expect(summary.control).toEqual({
      domain: "agents",
      intent: "revise",
      targetId: "release-reviewer",
      targetName: "Release Reviewer",
    });
  });

  it("filters absolute changed file paths from summaries", () => {
    const summary = buildSessionSummary(
      makeSession({
        changeStats: {
          mutatingToolCalls: 4,
          compactionCount: 2,
          filesChanged: 4,
          changedFiles: ["src/app.ts", "/tmp/secret.txt", "~/Library/private.txt", "  "],
          addedLines: 10,
          removedLines: 1,
        },
      }),
    );

    expect(summary.changeStats?.changedFiles).toEqual(["src/app.ts"]);
    expect(summary.changeStats?.compactionCount).toBe(2);
    expect(summary.changeStats?.filesChanged).toBe(4);
    expect(summary.changeStats?.changedFilesOverflow).toBe(3);
  });

  it("excludes trace and internal change tracking fields while exposing generic Pi identity", () => {
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
    expect(summary.piSessionId).toBe("pi-internal-session-id");
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

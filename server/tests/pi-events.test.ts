import { describe, expect, it } from "vitest";

import { parsePiStateSnapshot } from "../src/pi-events.js";

describe("pi state snapshot parser", () => {
  it("parses known state snapshot shape", () => {
    const snapshot = parsePiStateSnapshot({
      sessionFile: "/tmp/session.json",
      sessionId: "s1",
      sessionName: "My Session",
      model: {
        provider: "anthropic",
        id: "claude-sonnet-4",
        name: "Claude Sonnet 4",
      },
      thinkingLevel: "medium",
      isStreaming: true,
      autoCompaction: false,
    });

    expect(snapshot).toEqual({
      sessionFile: "/tmp/session.json",
      sessionId: "s1",
      sessionName: "My Session",
      model: {
        provider: "anthropic",
        id: "claude-sonnet-4",
        name: "Claude Sonnet 4",
      },
      thinkingLevel: "medium",
      isStreaming: true,
      autoCompaction: false,
    });
  });

  it("returns null for non-object snapshots", () => {
    expect(parsePiStateSnapshot(null)).toBeNull();
    expect(parsePiStateSnapshot("nope")).toBeNull();
  });

  it("drops invalid nested model shapes", () => {
    const snapshot = parsePiStateSnapshot({
      sessionId: "s2",
      model: "invalid-model",
    });

    expect(snapshot).toEqual({
      sessionFile: undefined,
      sessionId: "s2",
      sessionName: undefined,
      model: undefined,
      thinkingLevel: undefined,
      isStreaming: undefined,
      autoCompaction: undefined,
    });
  });
});

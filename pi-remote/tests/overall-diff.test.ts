import { describe, expect, it } from "vitest";
import type { TraceEvent } from "../src/trace.js";
import { collectFileMutations } from "../src/overall-diff.js";

describe("overall-diff helpers", () => {
  it("collects edit/write mutations for the requested path", () => {
    const trace: TraceEvent[] = [
      {
        id: "tc-read",
        type: "toolCall",
        timestamp: "2026-02-11T01:00:00.000Z",
        tool: "read",
        args: { path: "file.txt" },
      },
      {
        id: "tc-edit",
        type: "toolCall",
        timestamp: "2026-02-11T01:00:01.000Z",
        tool: "edit",
        args: { path: "file.txt", oldText: "A", newText: "B" },
      },
      {
        id: "tc-write-other",
        type: "toolCall",
        timestamp: "2026-02-11T01:00:02.000Z",
        tool: "write",
        args: { path: "other.txt", content: "x" },
      },
      {
        id: "tc-write",
        type: "toolCall",
        timestamp: "2026-02-11T01:00:03.000Z",
        tool: "functions.write",
        args: { path: "file.txt", content: "C" },
      },
    ];

    expect(collectFileMutations(trace, "file.txt")).toEqual([
      { id: "tc-edit", kind: "edit", oldText: "A", newText: "B" },
      { id: "tc-write", kind: "write", content: "C" },
    ]);
  });

  it("returns empty list for non-toolCall events", () => {
    const trace: TraceEvent[] = [
      {
        id: "u1",
        type: "user",
        timestamp: "2026-02-11T01:00:00.000Z",
        text: "hello",
      },
      {
        id: "a1",
        type: "assistant",
        timestamp: "2026-02-11T01:00:01.000Z",
        text: "world",
      },
    ];

    expect(collectFileMutations(trace, "file.txt")).toEqual([]);
  });
});

import { describe, expect, it } from "vitest";
import type { TraceEvent } from "../src/trace.js";
import { collectFileMutations, computeDiffLines } from "../src/overall-diff.js";

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

  it("computes line-by-line diff output", () => {
    expect(computeDiffLines("A\nB\nC", "A\nX\nC")).toEqual([
      { kind: "context", text: "A" },
      { kind: "removed", text: "B" },
      { kind: "added", text: "X" },
      { kind: "context", text: "C" },
    ]);
  });

  it("handles repeated blocks deterministically", () => {
    const oldText = ["header", "dup", "dup", "tail"].join("\n");
    const newText = ["header", "dup", "changed", "tail"].join("\n");

    expect(computeDiffLines(oldText, newText)).toEqual([
      { kind: "context", text: "header" },
      { kind: "context", text: "dup" },
      { kind: "removed", text: "dup" },
      { kind: "added", text: "changed" },
      { kind: "context", text: "tail" },
    ]);
  });

  it("represents moved lines as remove+add for reviewer clarity", () => {
    const oldText = ["A", "B", "C", "D"].join("\n");
    const newText = ["A", "C", "B", "D"].join("\n");

    const diff = computeDiffLines(oldText, newText);

    expect(diff.some((line) => line.kind === "context" && line.text === "A")).toBe(true);
    expect(diff.some((line) => line.kind === "context" && line.text === "D")).toBe(true);
    expect(diff.some((line) => line.kind === "removed" && line.text === "B")).toBe(true);
    expect(diff.some((line) => line.kind === "added" && line.text === "B")).toBe(true);
  });

  it("handles large inputs without dropping line information", () => {
    const oldLines = Array.from({ length: 2500 }, (_, i) => `line-${i}`);
    const newLines = [...oldLines];
    newLines[1250] = "line-1250-updated";

    const diff = computeDiffLines(oldLines.join("\n"), newLines.join("\n"));

    expect(diff.some((line) => line.kind === "removed" && line.text === "line-1250")).toBe(true);
    expect(diff.some((line) => line.kind === "added" && line.text === "line-1250-updated")).toBe(
      true,
    );
  });
});

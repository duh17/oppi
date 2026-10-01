import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { readSessionTraceFromFiles } from "../src/trace.js";
import { readSessionTraceOutlineFromFiles } from "../src/trace-outline.js";
import { readSessionTracePageFromFiles } from "../src/trace-paging.js";

const timestamp = "2026-01-01T00:00:00.000Z";
let tmpDir: string | undefined;

afterEach(() => {
  if (tmpDir) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = undefined;
  }
});

function tempJsonlFiles(files: unknown[][]): string[] {
  tmpDir = mkdtempSync(join(tmpdir(), "trace-outline-test-"));
  return files.map((lines, index) => {
    const path = join(tmpDir ?? tmpdir(), `session-${index + 1}.jsonl`);
    writeFileSync(path, lines.map((line) => JSON.stringify(line)).join("\n"));
    return path;
  });
}

function messageEntry(
  id: string,
  parentId: string | null,
  role: string,
  content: unknown,
  extra: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    type: "message",
    id,
    parentId,
    timestamp,
    message: { role, content, ...extra },
  };
}

describe("trace outline projection", () => {
  it("carries registry facts and result diffs without retaining large result text", async () => {
    const registry = new MobileRendererRegistry();
    registry.register("change_document", {
      inputPresentation: { fields: { target: { role: "filePath" }, changes: { role: "edits" } } },
      outputPresentation: { kind: "diffOfEdits" },
      renderCall: (args) => [{ text: `Change ${args.target}` }],
      renderResult: () => [],
    });
    const args = { target: "Example.swift", changes: [{ oldText: "a", newText: "b\nc\nd" }] };
    const diff = '-1 a "quoted" {value}\n+1 b \\ revised';
    const paths = tempJsonlFiles([
      [
        messageEntry("a", null, "assistant", [
          { type: "toolCall", id: "edit", name: "change_document", arguments: args },
          { type: "toolCall", id: "image", name: "draw", arguments: {} },
        ]),
        messageEntry("r", "a", "toolResult", "x".repeat(500000), {
          toolCallId: "edit",
          toolName: "change_document",
          details: { diff },
        }),
        messageEntry("i", "r", "toolResult", "created", {
          toolCallId: "image",
          toolName: "draw",
          details: { image: { kind: "image", id: "asset", mimeType: "image/png" } },
        }),
      ],
    ]);
    const result = await readSessionTraceOutlineFromFiles(paths, { mobileRenderers: registry });
    expect(result.outline.entries[0]).toMatchObject({
      args,
      inputPresentation: registry.inputPresentation("change_document"),
      outputPresentation: { kind: "diffOfEdits" },
      details: { diff },
    });
    expect(result.outline.entries[1]?.details).toEqual({
      image: { kind: "image", id: "asset", mimeType: "image/png" },
    });
    expect(JSON.stringify(result.outline)).not.toContain("xxxxx");
  });
  it("returns an explicit empty snapshot when no trace files exist", async () => {
    const result = await readSessionTraceOutlineFromFiles([], {
      mobileRenderers: new MobileRendererRegistry(),
    });

    expect(result.outline).toMatchObject({
      traceVersion: "",
      entries: [],
      itemCount: 0,
      sourceCount: 0,
      jsonlBytes: 0,
    });
    expect(result.metrics.outlineEntryCount).toBe(0);
  });

  it("projects a multi-file trace into small outline rows", async () => {
    const paths = tempJsonlFiles([
      [
        messageEntry("u1", null, "user", "first prompt"),
        messageEntry("a1", "u1", "assistant", [
          { type: "text", text: "first answer" },
          { type: "toolCall", id: "tc-1", name: "bash", arguments: { command: "echo hi" } },
        ]),
      ],
      [
        messageEntry("r1", "a1", "toolResult", "x".repeat(500_000), {
          toolCallId: "tc-1",
          toolName: "bash",
          isError: true,
        }),
        {
          type: "compaction",
          id: "c1",
          parentId: "r1",
          timestamp,
          tokensBefore: 12345,
          summary: "old history",
        },
      ],
    ]);

    const result = await readSessionTraceOutlineFromFiles(paths, {
      mobileRenderers: new MobileRendererRegistry(),
    });

    expect(result.outline.sourceCount).toBe(2);
    expect(result.outline.entries).toMatchObject([
      { id: "u1", kind: "user", summary: "first prompt", isMessage: true, isTool: false },
      { id: "a1-text-0", kind: "assistant", summary: "first answer", isMessage: true },
      { id: "tc-1", kind: "tool", tool: "bash", summary: "$ echo hi", isTool: true, isError: true },
      { id: "c1", kind: "compaction", summary: "Context compacted (12,345 tokens)" },
    ]);
    expect(JSON.stringify(result.outline)).not.toContain("xxxxx");
    expect(result.metrics.rawEntryCount).toBe(4);
    expect(result.metrics.outlineEntryCount).toBe(4);
  });

  it("uses trace event-compatible IDs for mixed assistant blocks", async () => {
    const paths = tempJsonlFiles([
      [
        messageEntry("u1", null, "user", "prompt"),
        messageEntry("a1", "u1", "assistant", [
          { type: "text", text: "intro" },
          { type: "thinking", thinking: "plan" },
          { type: "text", text: "answer" },
          { type: "toolCall", name: "bash", arguments: { command: "pwd" } },
          { type: "text", text: "done" },
        ]),
      ],
    ]);

    const outline = await readSessionTraceOutlineFromFiles(paths, {
      mobileRenderers: new MobileRendererRegistry(),
    });
    const trace = readSessionTraceFromFiles(paths, { view: "full" }) ?? [];
    const outlineAssistantIDs = outline.outline.entries
      .filter((entry) => entry.id !== "u1")
      .map((entry) => entry.id);
    const traceAssistantIDs = trace.filter((entry) => entry.id !== "u1").map((entry) => entry.id);

    expect(traceAssistantIDs).toEqual([
      "a1-text-0",
      "a1-think-1",
      "a1-text-2",
      "a1-tool-3",
      "a1-text-4",
    ]);
    expect(outlineAssistantIDs).toEqual(traceAssistantIDs);
  });

  it("projects only the current branch so outline entries are jumpable", async () => {
    const paths = tempJsonlFiles([
      [
        messageEntry("u1", null, "user", "root prompt"),
        messageEntry("a-old", "u1", "assistant", "abandoned answer"),
        messageEntry("u2", "u1", "user", "current branch prompt"),
        messageEntry("a-current", "u2", "assistant", "current answer"),
      ],
    ]);

    const outline = await readSessionTraceOutlineFromFiles(paths, {
      mobileRenderers: new MobileRendererRegistry(),
    });
    const outlineIDs = outline.outline.entries.map((entry) => entry.id);

    expect(outlineIDs).toEqual(["u1", "u2", "a-current"]);
    for (const entryId of outlineIDs) {
      const page = readSessionTracePageFromFiles(paths, {
        aroundEntryId: entryId,
        targetEvents: 10,
      });
      expect(
        page.trace.map((event) => event.id),
        entryId,
      ).toContain(entryId);
    }
  });

  it("skips non-display session bookkeeping entries", async () => {
    const paths = tempJsonlFiles([
      [
        { type: "session", id: "session-header", timestamp },
        { type: "session_info", id: "info", parentId: null, timestamp, name: "Title" },
        messageEntry("u1", null, "user", "visible"),
      ],
    ]);

    const result = await readSessionTraceOutlineFromFiles(paths, {
      mobileRenderers: new MobileRendererRegistry(),
    });

    expect(result.outline.entries.map((entry) => entry.id)).toEqual(["u1"]);
  });
});

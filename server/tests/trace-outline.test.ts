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

function tempJsonlFiles(files: unknown[][], spacedRoles = false): string[] {
  tmpDir = mkdtempSync(join(tmpdir(), "trace-outline-test-"));
  return files.map((lines, index) => {
    const path = join(tmpDir ?? tmpdir(), `session-${index + 1}.jsonl`);
    writeFileSync(
      path,
      lines
        .map((line) => {
          const encoded = JSON.stringify(line);
          return spacedRoles ? encoded.replace('"role":', '"role": ') : encoded;
        })
        .join("\n"),
    );
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
  it.each([false, true])(
    "keeps optional metadata within a session budget (spaced roles: %s)",
    async (spacedRoles) => {
      const registry = new MobileRendererRegistry();
      const calls = Array.from({ length: 200 }, (_, index) => ({
        type: "toolCall",
        id: `write-${index}`,
        name: "write",
        arguments: {
          path: `Sources/File${index}.swift`,
          content: "PRIVATE_WRITTEN_CONTENT".repeat(5000),
        },
      }));
      const lines = [messageEntry("a", null, "assistant", calls)];
      for (let index = 0; index < calls.length; index++) {
        lines.push(
          messageEntry(`r-${index}`, index ? `r-${index - 1}` : "a", "toolResult", "done", {
            toolCallId: `write-${index}`,
            toolName: "write",
            details: { diff: "-1 a\n+1 " + "b".repeat(4000) },
          }),
        );
      }
      const result = await readSessionTraceOutlineFromFiles(tempJsonlFiles([lines], spacedRoles), {
        mobileRenderers: registry,
      });
      const encoded = JSON.stringify(result.outline);
      expect(result.outline.entries).toHaveLength(200);
      expect(result.outline.entries.every((entry) => entry.summary.includes("File"))).toBe(true);
      expect(encoded).not.toContain("PRIVATE_WRITTEN_CONTENT");
      const metadataBytes = result.outline.entries.reduce(
        (bytes, entry) =>
          bytes +
          Buffer.byteLength(JSON.stringify(entry.args ?? {})) +
          Buffer.byteLength(JSON.stringify(entry.details ?? {})),
        0,
      );
      expect(metadataBytes).toBeLessThan(66 * 1024);
      expect(Buffer.byteLength(encoded)).toBeLessThan(256 * 1024);
      expect(result.outline.entries.some((entry) => entry.args === undefined)).toBe(true);
    },
  );

  it.each([false, true])(
    "preserves result semantics after content budget eviction (spaced roles: %s)",
    async (spacedRoles) => {
      const registry = new MobileRendererRegistry();
      registry.register("runner", {
        inputPresentation: { fields: { script: { role: "command", language: "shell" } } },
        outputPresentation: { kind: "terminal" },
        renderCall: () => [{ text: "$ echo hello" }],
        renderResult: () => [],
      });
      const lines = [
        messageEntry("a", null, "assistant", [
          { type: "toolCall", id: "run", name: "runner", arguments: { script: "echo hello" } },
          {
            type: "toolCall",
            id: "expanded",
            name: "runner",
            arguments: { script: "echo formatted" },
          },
          { type: "toolCall", id: "voice", name: "voice_reply_mode", arguments: {} },
        ]),
      ];
      // These off-branch details still consume the retained-content budget.
      for (let index = 0; index < 20; index++) {
        lines.push(
          messageEntry(`fill-${index}`, index ? `fill-${index - 1}` : "a", "toolResult", "", {
            toolCallId: `unused-${index}`,
            details: { diff: "x".repeat(4000) },
          }),
        );
      }
      // Deliberately omit toolName: declaration authority is attached at row association.
      lines.push(
        messageEntry("run-result", "a", "toolResult", "text".repeat(100000), {
          toolCallId: "run",
          details: {
            patch: "p".repeat(5000),
            ignored: "NOT_RETAINED".repeat(10000),
            outputPresentation: { kind: "structured", settingEffect: "voiceReplyMode" },
            server: "Producer server",
            tool: "Producer action",
          },
        }),
      );
      lines.push(
        messageEntry("expanded-result", "run-result", "toolResult", "", {
          toolCallId: "expanded",
          details: {
            expandedText: "FORMATTED_BODY".repeat(10000),
            presentationFormat: "markdown",
          },
        }),
      );
      lines.push(
        messageEntry("voice-result", "expanded-result", "toolResult", "done", {
          toolCallId: "voice",
          details: { outputPresentation: { kind: "terminal" } },
        }),
      );
      const result = await readSessionTraceOutlineFromFiles(tempJsonlFiles([lines], spacedRoles), {
        mobileRenderers: registry,
      });
      expect(result.outline.entries).toHaveLength(3);
      expect(result.outline.entries[0]).toMatchObject({
        outputPresentation: { kind: "structured" },
        display: { title: "Producer action", group: "Producer server" },
      });
      expect(result.outline.entries[0]?.outputPresentation?.settingEffect).toBeUndefined();
      expect(result.outline.entries[0]?.details).toBeUndefined();
      expect(result.outline.entries[1]?.outputPresentation).toEqual({ kind: "structured" });
      expect(result.outline.entries[2]?.outputPresentation).toEqual({
        kind: "terminal",
        settingEffect: "voiceReplyMode",
      });
      expect(JSON.stringify(result.outline)).not.toContain("NOT_RETAINED");
      expect(JSON.stringify(result.outline)).not.toContain("FORMATTED_BODY");
      expect(Buffer.byteLength(JSON.stringify(result.outline))).toBeLessThan(8 * 1024);
    },
  );

  it("bounds sidecar summaries and result display labels", async () => {
    const registry = new MobileRendererRegistry();
    registry.register("verbose_tool", {
      renderCall: () => [{ text: "A long summary\n" + "x".repeat(4000) }],
      renderResult: () => [],
    });
    const result = await readSessionTraceOutlineFromFiles(
      tempJsonlFiles([
        [
          messageEntry("a", null, "assistant", [
            { type: "toolCall", id: "t", name: "verbose_tool", arguments: {} },
          ]),
          messageEntry("r", "a", "toolResult", "", {
            toolCallId: "t",
            details: { server: "s".repeat(10000), tool: "t".repeat(10000) },
          }),
        ],
      ]),
      { mobileRenderers: registry },
    );
    const row = result.outline.entries[0];
    expect(row?.summary.startsWith("A long summary ")).toBe(true);
    expect(row?.summary.length).toBe(160);
    expect(row?.summary).not.toContain("\n");
    expect(row?.display?.title.length).toBe(160);
    expect(row?.display?.group?.length).toBe(160);
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

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { parseJsonl } from "../src/trace.js";
import {
  readSessionTracePageFromFile,
  readSessionTracePageFromFiles,
} from "../src/trace-paging.js";

const timestamp = "2026-01-01T00:00:00.000Z";

let tmpDir: string | undefined;

afterEach(() => {
  if (tmpDir) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = undefined;
  }
});

function tempJsonl(lines: unknown[]): string {
  tmpDir = mkdtempSync(join(tmpdir(), "trace-paging-test-"));
  const path = join(tmpDir, "session.jsonl");
  writeFileSync(path, lines.map((line) => JSON.stringify(line)).join("\n"));
  return path;
}

function tempJsonlFiles(files: unknown[][]): string[] {
  tmpDir = mkdtempSync(join(tmpdir(), "trace-paging-test-"));
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

function textBlock(text: string): Array<Record<string, string>> {
  return [{ type: "text", text }];
}

function fixtureEntries(): unknown[] {
  return [
    messageEntry("u1", null, "user", "first prompt"),
    messageEntry("a1", "u1", "assistant", textBlock("old answer")),
    messageEntry("u2", "a1", "user", "run a command"),
    messageEntry("a2", "u2", "assistant", [
      { type: "toolCall", id: "tc-1", name: "bash", arguments: { command: "printf output" } },
    ]),
    messageEntry("r1", "a2", "toolResult", "abcdefghijklmnopqrstuvwxyz", {
      toolCallId: "tc-1",
      toolName: "bash",
    }),
    messageEntry("a3", "r1", "assistant", textBlock("done")),
  ];
}

describe("trace paging", () => {
  it("returns a latest page in chronological order without orphaning tool results", () => {
    const path = tempJsonl(fixtureEntries());

    const page = readSessionTracePageFromFile(path, {
      targetEvents: 2,
      previewBytes: 8,
    });

    expect(page.trace.map((event) => event.id)).toEqual(["tc-1", "result-r1", "a3-text-0"]);
    expect(page.page.hasOlder).toBe(true);
    expect(page.page.olderCursor).toEqual(expect.any(String));
    expect(page.page.traceVersion).toEqual(expect.any(String));
    expect(page.page.previewBytes).toBe(8);

    const result = page.trace.find((event) => event.type === "toolResult");
    expect(result?.toolCallId).toBe("tc-1");
    expect(page.trace.some((event) => event.id === result?.toolCallId)).toBe(true);
  });

  it("uses the default target size when targetEvents is omitted", () => {
    const path = tempJsonl(fixtureEntries());

    const page = readSessionTracePageFromFile(path, { previewBytes: 8 });

    expect(page.trace.map((event) => event.id)).toContain("result-r1");
    expect(page.page.previewBytes).toBe(8);
    expect(page.page.staleCursor).toBe(false);
  });

  it("bounds initial latest-page reads for large traces", () => {
    const padding = Array.from({ length: 80 }, (_, index) =>
      messageEntry(
        `pad-${index}`,
        index === 0 ? null : `pad-${index - 1}`,
        "user",
        `padding ${index} ${"x".repeat(200)}`,
      ),
    );
    const path = tempJsonl([...padding, ...fixtureEntries()]);

    const page = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      previewBytes: 8,
      maxInitialReadBytes: 1024,
    });

    expect(page.metrics.jsonlBytes).toBeGreaterThan(1024);
    expect(page.metrics.scannedBytes).toBeLessThanOrEqual(1024);
  });

  it("paginates across JSONL files without orphaning tool results split by file boundaries", () => {
    const paths = tempJsonlFiles([
      [
        messageEntry("u1", null, "user", "run a command"),
        messageEntry("a1", "u1", "assistant", [
          { type: "toolCall", id: "tc-cross-file", name: "bash", arguments: { command: "echo" } },
        ]),
      ],
      [
        messageEntry("r1", "a1", "toolResult", "abcdefghijklmnopqrstuvwxyz", {
          toolCallId: "tc-cross-file",
          toolName: "bash",
        }),
        messageEntry("a2", "r1", "assistant", textBlock("done")),
      ],
    ]);

    const page = readSessionTracePageFromFiles(paths, { targetEvents: 2, previewBytes: 8 });

    expect(page.trace.map((event) => event.id)).toEqual([
      "tc-cross-file",
      "result-r1",
      "a2-text-0",
    ]);
    expect(page.trace.find((event) => event.id === "result-r1")?.output).toBe("abcdefgh");
    expect(page.page.hasOlder).toBe(true);
  });

  it("uses the older cursor to return the previous chronological page", () => {
    const path = tempJsonl(fixtureEntries());
    const latest = readSessionTracePageFromFile(path, { targetEvents: 2, previewBytes: 8 });

    const older = readSessionTracePageFromFile(path, {
      cursor: latest.page.olderCursor ?? undefined,
      targetEvents: 2,
      previewBytes: 8,
    });

    expect(older.page.staleCursor).toBe(false);
    expect(older.trace.map((event) => event.id)).toEqual(["a1-text-0", "u2"]);
    expect(older.page.hasOlder).toBe(true);
    expect(older.page.olderCursor).toEqual(expect.any(String));
  });

  it("returns a bounded page around an outline entry id", () => {
    const path = tempJsonl(fixtureEntries());

    const around = readSessionTracePageFromFile(path, {
      aroundEntryId: "u2",
      targetEvents: 3,
      previewBytes: 8,
    });

    expect(around.page.staleCursor).toBe(false);
    expect(around.trace.map((event) => event.id)).toEqual([
      "a1-text-0",
      "u2",
      "tc-1",
      "result-r1",
    ]);
    expect(around.trace.some((event) => event.id === "a3-text-0")).toBe(false);
    expect(around.page.hasOlder).toBe(true);
    expect(around.page.olderCursor).toEqual(expect.any(String));
  });

  it("resolves synthetic outline ids and tool call ids to their raw JSONL entries", () => {
    const path = tempJsonl(fixtureEntries());

    const textPage = readSessionTracePageFromFile(path, {
      aroundEntryId: "a1-text-0",
      targetEvents: 1,
      previewBytes: 8,
    });
    expect(textPage.trace.map((event) => event.id)).toEqual(["a1-text-0"]);

    const toolPage = readSessionTracePageFromFile(path, {
      aroundEntryId: "tc-1",
      targetEvents: 3,
      previewBytes: 8,
    });
    expect(toolPage.trace.map((event) => event.id)).toEqual(["u2", "tc-1", "result-r1"]);
  });

  it("marks a cursor stale when the boundary entry no longer matches", () => {
    const path = tempJsonl(fixtureEntries());
    const latest = readSessionTracePageFromFile(path, { targetEvents: 2, previewBytes: 8 });

    writeFileSync(
      path,
      [
        messageEntry("replacement-u1", null, "user", "replacement"),
        messageEntry("replacement-a1", "replacement-u1", "assistant", textBlock("replacement")),
      ]
        .map((line) => JSON.stringify(line))
        .join("\n"),
    );

    const older = readSessionTracePageFromFile(path, {
      cursor: latest.page.olderCursor ?? undefined,
      targetEvents: 2,
      previewBytes: 8,
    });

    expect(older.page.staleCursor).toBe(true);
    expect(older.trace).toEqual([]);
    expect(older.page.hasOlder).toBe(false);
  });

  it("truncates large tool output previews and leaves the full trace path unchanged", () => {
    const entries = fixtureEntries();
    const path = tempJsonl(entries);

    const page = readSessionTracePageFromFile(path, {
      targetEvents: 2,
      previewBytes: 8,
    });
    const pagedResult = page.trace.find((event) => event.type === "toolResult");

    expect(pagedResult?.output).toBe("abcdefgh");
    expect(pagedResult?.outputTruncated).toBe(true);
    expect(pagedResult?.outputPreviewBytes).toBe(8);
    expect(pagedResult?.outputTotalBytes).toBe(26);

    const fullTrace = parseJsonl(entries.map((entry) => JSON.stringify(entry)).join("\n"), {
      view: "full",
    });
    const fullResult = fullTrace.find((event) => event.type === "toolResult");

    expect(fullResult?.output).toBe("abcdefghijklmnopqrstuvwxyz");
    expect(fullResult).not.toHaveProperty("outputTruncated");
  });

  it("does not return a tool result when its tool call is outside the suffix", () => {
    const path = tempJsonl([
      messageEntry("u1", null, "user", "start"),
      messageEntry("a1", "u1", "assistant", [
        {
          type: "toolCall",
          id: "tc-outside-suffix",
          name: "bash",
          arguments: { command: "echo hi", padding: "x".repeat(2_000) },
        },
      ]),
      messageEntry("r1", "a1", "toolResult", "hi", {
        toolCallId: "tc-outside-suffix",
        toolName: "bash",
      }),
    ]);

    const page = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      previewBytes: 8,
      maxInitialReadBytes: 220,
    });

    expect(page.trace.some((event) => event.type === "toolResult")).toBe(false);
  });

  it("keeps ask tool call and answer together", () => {
    const path = tempJsonl([
      messageEntry("u1", null, "user", "start"),
      messageEntry("a1", "u1", "assistant", textBlock("before ask")),
      messageEntry("a2", "a1", "assistant", [
        { type: "toolCall", id: "ask-1", name: "ask", arguments: { question: "Continue?" } },
      ]),
      messageEntry("r1", "a2", "toolResult", "yes", {
        toolCallId: "ask-1",
        toolName: "ask",
        details: { answers: [{ question: "Continue?", answer: "yes" }] },
      }),
    ]);

    const page = readSessionTracePageFromFile(path, {
      targetEvents: 1,
      previewBytes: 8,
    });

    expect(page.trace.map((event) => event.id)).toEqual(["ask-1", "result-r1"]);
    expect(page.trace[1]?.toolCallId).toBe("ask-1");
  });
});

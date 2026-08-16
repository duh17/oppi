import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  parseSessionJsonlHead,
  readSessionJsonlMeta,
} from "../src/session-jsonl-meta.js";

function jsonl(lines: unknown[]): string {
  return `${lines.map((line) => (typeof line === "string" ? line : JSON.stringify(line))).join("\n")}\n`;
}

describe("parseSessionJsonlHead", () => {
  it("extracts string user content as firstMessage", () => {
    const meta = parseSessionJsonlHead(
      jsonl([
        { type: "session", id: "s1" },
        { type: "message", message: { role: "user", content: "hello world" } },
      ]),
    );

    expect(meta.firstMessage).toBe("hello world");
    expect(meta.messageCount).toBe(1);
  });

  it("joins text-part arrays, including queued input_text and output_text", () => {
    const meta = parseSessionJsonlHead(
      jsonl([
        {
          type: "message",
          message: {
            role: "user",
            content: [
              { type: "input_text", text: "queued " },
              { type: "text", text: "hello " },
              { type: "output_text", text: "world" },
              { type: "image", text: "ignore" },
            ],
          },
        },
      ]),
    );

    expect(meta.firstMessage).toBe("queued hello world");
  });

  it("reads a top-level user record when there is no message wrapper", () => {
    const meta = parseSessionJsonlHead(jsonl([{ role: "user", content: "bare user line" }]));

    expect(meta.firstMessage).toBe("bare user line");
    expect(meta.messageCount).toBe(0);
  });

  it("skips a malformed line and continues scanning", () => {
    const meta = parseSessionJsonlHead(
      jsonl([
        { type: "session_info", name: "Keep me" },
        "{not json",
        { type: "message", message: { role: "user", content: "after the break" } },
      ]),
    );

    expect(meta.name).toBe("Keep me");
    expect(meta.firstMessage).toBe("after the break");
  });

  it("leaves firstMessage untruncated unless the caller sets a cap", () => {
    const longMessage = "x".repeat(250);
    const uncapped = parseSessionJsonlHead(
      jsonl([{ type: "message", message: { role: "user", content: longMessage } }]),
    );
    const capped = parseSessionJsonlHead(
      jsonl([{ type: "message", message: { role: "user", content: longMessage } }]),
      { firstMessageMaxChars: 200 },
    );

    expect(uncapped.firstMessage).toBe(longMessage);
    expect(capped.firstMessage).toBe("x".repeat(200));
  });

  it("extracts session name and the first model_change", () => {
    const meta = parseSessionJsonlHead(
      jsonl([
        { type: "model_change", provider: "anthropic", modelId: "claude-sonnet-4-5" },
        { type: "session_info", name: "  Review  " },
        { type: "model_change", provider: "openai", modelId: "gpt-5.6" },
      ]),
    );

    expect(meta.name).toBe("Review");
    expect(meta.model).toBe("anthropic/claude-sonnet-4-5");
  });
});

describe("readSessionJsonlMeta", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("reads only the caller-specified head budget", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-session-jsonl-meta-"));
    dirs.push(dir);
    const filePath = join(dir, "session.jsonl");
    const padding = `${"a".repeat(200)}\n`.repeat(80);
    writeFileSync(
      filePath,
      `${padding}${JSON.stringify({
        type: "message",
        message: { role: "user", content: "past the budget" },
      })}\n`,
    );

    const meta = readSessionJsonlMeta(filePath, { maxBytes: 1_024 });
    expect(meta.firstMessage).toBeUndefined();
  });

  it("returns empty metadata when the file cannot be read", () => {
    expect(readSessionJsonlMeta("/tmp/oppi-missing-session.jsonl", { maxBytes: 1024 })).toEqual({
      messageCount: 0,
      scannedLineCount: 0,
      scannedBytes: 0,
    });
  });
});

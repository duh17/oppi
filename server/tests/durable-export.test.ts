import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { exportDurableToHtml } from "../src/durable-export.js";

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("durable HTML export", () => {
  it("writes the conversation, a compaction summary, and a card through Pi's exporter", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-durable-export-"));
    dirs.push(dir);
    const outputPath = join(dir, "share.html");
    const at = (seconds: number) => new Date(Date.UTC(2026, 10, 20, 9, 0, seconds)).toISOString();

    const written = await exportDurableToHtml({
      cwd: "/work",
      outputPath,
      themeName: "no-such-theme",
      state: { systemPrompt: "SYSTEM PROMPT TEXT", tools: [] },
      entries: [
        {
          type: "message",
          id: "s",
          timestamp: at(0),
          message: { role: "system", content: [{ type: "text", text: "LEFT OUT" }] },
        },
        {
          type: "message",
          id: "u",
          timestamp: at(1),
          message: { role: "user", content: [{ type: "text", text: "QUESTION TEXT" }] },
        },
        { type: "compaction", id: "c", timestamp: at(2), summary: "SUMMARY TEXT" },
        {
          type: "custom",
          id: "card",
          timestamp: at(3),
          customType: "oppi.failure",
          data: { card: { title: "CARD TITLE", body: "CARD BODY" } },
        },
      ],
    });

    expect(written).toBe(outputPath);
    const html = readFileSync(outputPath, "utf8");
    // Pi's page embeds the session data base64-encoded.
    const embedded = [...html.matchAll(/[A-Za-z0-9+/=]{200,}/g)]
      .map((match) => Buffer.from(match[0], "base64").toString("utf8"))
      .join("\n");
    const page = `${html}\n${embedded}`;
    for (const text of ["QUESTION TEXT", "SUMMARY TEXT", "CARD TITLE", "CARD BODY"])
      expect(page).toContain(text);
    expect(page).not.toContain("LEFT OUT");
  });
});

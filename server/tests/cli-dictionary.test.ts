import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { runCli } from "../src/cli/runner.js";
import { renderHelpTopic, resolveHelpTopic } from "../src/cli/help.js";
import { ConfigStore } from "../src/storage/config-store.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

describe("oppi dictionary CLI", () => {
  it("describes a shared human and session primitive for the same Server Settings lists", () => {
    const topic = resolveHelpTopic(["dictionary"]);
    expect(topic).toBeDefined();
    const text = renderHelpTopic(topic!);
    expect(text).toContain("Server Settings");
    expect(text).toContain("sessions");
    expect(text).toContain("All Workspaces");
    expect(text).toContain("This Workspace");
    expect(text).toContain("hints, not replacements");
  });

  it("adds a literal phrase in a stable workspace id through the owner socket", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-cli-dictionary-"));
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "config.json"),
      JSON.stringify({
        ...ConfigStore.getDefaultConfig(dir),
        token: "test-owner-token",
        tls: { mode: "disabled" },
      }),
    );
    const seen: Array<{ method?: string; path?: string; body: string }> = [];
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        seen.push({
          method: req.method,
          path: req.url,
          body: Buffer.concat(chunks).toString("utf8"),
        });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            revision: 1,
            phrases: ["Yuwp"],
            provider: "http",
            added: 1,
            skipped: [],
          }),
        );
      });
    });
    try {
      await listenOnLocalApiFixture(server, dir);
      const result = await runCli(
        ["dictionary", "add", "--workspace", "stable-w1", "--phrase", "Yuwp"],
        { dataDir: dir, captureHuman: true, forceJson: true },
      );
      expect(result.ok).toBe(true);
      expect(result.json?.ok).toBe(true);
      expect(seen).toEqual([
        {
          method: "POST",
          path: "/dictation/dictionary/workspaces/stable-w1",
          body: '{"phrase":"Yuwp"}',
        },
      ]);
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("reads JSON and newline file batches, and pipes stdin batches in one request", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-cli-dictionary-bulk-"));
    writeFileSync(
      join(dir, "config.json"),
      JSON.stringify({
        ...ConfigStore.getDefaultConfig(dir),
        token: "test-owner-token",
        tls: { mode: "disabled" },
      }),
    );
    const seen: unknown[] = [];
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        seen.push(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            revision: 1,
            phrases: ["Yuwp", "Duh Ifone"],
            added: 1,
            skipped: [{ phrase: "Duh Ifone", reason: "duplicate" }],
          }),
        );
      });
    });
    try {
      await listenOnLocalApiFixture(server, dir);
      const jsonFile = join(dir, "json.txt");
      const linesFile = join(dir, "lines.txt");
      writeFileSync(jsonFile, '["Yuwp","Duh Ifone"]');
      writeFileSync(linesFile, "Yuwp\nDuh Ifone\n");
      const fileResult = await runCli(["dictionary", "add", "--file", jsonFile], {
        dataDir: dir,
        captureHuman: true,
        forceJson: true,
      });
      expect(fileResult.ok).toBe(true);
      expect(fileResult.json).toMatchObject({
        ok: true,
        data: { added: 1, skipped: [{ phrase: "Duh Ifone", reason: "duplicate" }] },
      });
      expect(fileResult.humanOutput).toContain("1 added, 1 skipped");
      const linesResult = await runCli(["dictionary", "add", "--file", linesFile], {
        dataDir: dir,
        captureHuman: true,
        forceJson: true,
      });
      expect(linesResult.ok).toBe(true);
      const child = spawn("bun", ["src/cli.ts", "dictionary", "add", "--phrases", "@-", "--json"], {
        cwd: join(import.meta.dirname, ".."),
        env: { ...process.env, OPPI_DATA_DIR: dir },
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      child.stdout.setEncoding("utf8").on("data", (text: string) => (stdout += text));
      child.stderr.setEncoding("utf8").on("data", (text: string) => (stderr += text));
      child.stdin.end("Yuwp\nDuh Ifone\n");
      const exit = await new Promise<number | null>((resolve) => child.on("close", resolve));
      expect({ exit, stderr }).toEqual({ exit: 0, stderr: "" });
      expect(JSON.parse(stdout)).toMatchObject({ ok: true, data: { added: 1 } });
      expect(seen).toEqual(Array.from({ length: 3 }, () => ({ phrases: ["Yuwp", "Duh Ifone"] })));
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

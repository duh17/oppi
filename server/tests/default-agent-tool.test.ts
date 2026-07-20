import { createServer as createHttpServer } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { classifyOppiToolCommand, runOppiToolCommand } from "../src/default-agent-tool.js";
import { Storage } from "../src/storage.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

describe("Default Agent Oppi tool command runner", () => {
  it("returns help for write commands without local API dispatch", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-help-"));
    try {
      const result = await runOppiToolCommand({
        dataDir,
        args: ["session", "delete", "--help"],
      });

      expect(result.ok).toBe(true);
      expect(result.data).toMatchObject({ help: { title: "Delete session" } });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("exposes the progressive session inspection workflow in agent-readable help", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-inspect-help-"));
    try {
      const result = await runOppiToolCommand({
        dataDir,
        args: ["session", "inspect", "--help"],
      });

      expect(result.ok).toBe(true);
      expect(result.data).toMatchObject({
        help: {
          usage: expect.stringContaining("--view <view>"),
          notes: expect.arrayContaining([
            expect.stringContaining("compact outline"),
            expect.stringContaining("messages/tools"),
          ]),
          examples: expect.arrayContaining([
            expect.objectContaining({
              command: "oppi session inspect sess_123 --view outline --json",
            }),
          ]),
        },
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("dispatches allowed read commands through the JSON CLI modules", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-"));
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      requests.push(`${req.method ?? "GET"} ${req.url ?? "/"}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          workspaces: [{ id: "ws-1", name: "Oppi" }],
        }),
      );
    });
    await listenOnLocalApiFixture(api, dataDir);

    try {
      const storage = new Storage(dataDir);
      storage.rotateToken();
      storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });

      const result = await runOppiToolCommand({ dataDir, args: ["workspace", "list"] });

      expect(result.ok).toBe(true);
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: true,
        data: { workspaces: [{ id: "ws-1", name: "Oppi" }] },
      });
      expect(requests).toEqual(["GET /workspaces"]);
    } finally {
      await new Promise<void>((resolve, reject) =>
        api.close((error) => (error ? reject(error) : resolve())),
      );
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("passes the agent cwd into session search workspace inference", async () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-cwd-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-tool-cwd-data-"));
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      requests.push(`${req.method ?? "GET"} ${url.pathname}${url.search}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      if (url.pathname === "/workspaces") {
        res.end(
          JSON.stringify({ workspaces: [{ id: "ws-1", name: "Oppi", hostMount: workspaceRoot }] }),
        );
        return;
      }
      if (url.pathname === "/workspaces/ws-1/worktrees") {
        res.end(
          JSON.stringify({ workspaceId: "ws-1", worktrees: [{ id: "main", path: workspaceRoot }] }),
        );
        return;
      }
      if (url.pathname === "/sessions/search") {
        res.end(JSON.stringify({ query: url.searchParams.get("q"), results: [], totalResults: 0 }));
        return;
      }
      res.end(JSON.stringify({}));
    });
    await listenOnLocalApiFixture(api, dataDir);

    try {
      const storage = new Storage(dataDir);
      storage.rotateToken();
      storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });

      const result = await runOppiToolCommand({
        dataDir,
        args: ["session", "search", "needle"],
        cwd: workspaceRoot,
      });

      expect(result.ok).toBe(true);
      expect(requests).toContain("GET /workspaces");
      expect(requests).toContain("GET /sessions/search?q=needle&workspaceId=ws-1");
    } finally {
      await new Promise<void>((resolve, reject) =>
        api.close((error) => (error ? reject(error) : resolve())),
      );
      rmSync(dataDir, { recursive: true, force: true });
      rmSync(workspaceRoot, { recursive: true, force: true });
    }
  });
});

describe("Default Agent Oppi tool command policy", () => {
  it("allows read-only app inspection commands", () => {
    for (const args of [
      ["status"],
      ["workspace", "list"],
      ["workspace", "get", "oppi"],
      ["worktree", "list", "--workspace", "oppi"],
      ["worktree", "get", "main", "--workspace", "oppi"],
      ["worktree", "status", "wt_feature", "--workspace", "oppi"],
      ["worktree", "preview", "wt_feature", "--workspace", "oppi", "--into", "main"],
      ["agent", "list"],
      ["agent", "get", "default"],
      ["session", "list"],
      ["session", "get", "sess-1"],
      ["session", "search", "regression", "--workspace", "oppi"],
      ["session", "inspect", "sess-1", "--turns", "1-3", "--view", "messages"],
      ["session", "read", "sess-1", "--tail", "10"],
      ["session", "inspect", "sess-1", "--view", "response"],
      ["session", "events", "sess-1"],
      ["session", "trace", "sess-1"],
      ["session", "changes", "sess-1"],
      ["session", "diff", "sess-1", "--path", "README.md"],
      ["session", "tool-output", "sess-1", "tool-1"],
      ["session", "trace-page", "sess-1"],
      ["session", "trace-outline", "sess-1"],
      ["schedule", "list"],
      ["schedule", "get", "sch-1"],
      ["schedule", "runs", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "read",
      });
    }
  });

  it("allows help for write and destructive commands", () => {
    for (const args of [
      ["session", "create", "--help"],
      ["session", "delete", "--help"],
      ["workspace", "delete", "--help"],
      ["agent", "archive", "--help"],
      ["worktree", "remove", "--help"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "read",
      });
    }
  });

  it("requires approval for mutating app commands", () => {
    for (const args of [
      ["workspace", "create", "--name", "Scratch", "--host-mount", "/tmp/scratch"],
      ["workspace", "update", "oppi", "--name", "Oppi"],
      ["agent", "create", "--name", "Reviewer"],
      ["agent", "update", "default", "--definition-json", '{"description":"Short"}'],
      ["session", "create", "--workspace", "oppi", "--prompt", "Review this"],
      ["session", "send", "sess-1", "--text", "hello"],
      ["session", "stop", "sess-1"],
      ["session", "resume", "sess-1"],
      ["session", "fork", "sess-1", "--entry", "entry-1"],
      ["worktree", "create", "--workspace", "oppi", "--branch", "feature/review"],
      ["worktree", "open", "--workspace", "oppi", "--branch", "feature/review"],
      ["worktree", "remove", "wt_feature-review-12345678", "--workspace", "oppi"],
      ["schedule", "create", "--workspace", "oppi", "--prompt", "daily", "--every", "1d"],
      ["schedule", "update", "sch-1", "--definition-json", '{"name":"Daily"}'],
      ["schedule", "run", "sch-1"],
      ["schedule", "pause", "sch-1"],
      ["schedule", "resume", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "approved-write",
      });
    }
  });

  it("keeps compact tool output while exposing complete structured approval details", () => {
    const prompt = "Review **all** changes.\n\n```sh\nrm -rf /not-executed\n```" + "x".repeat(770);
    const classification = classifyOppiToolCommand([
      "session",
      "create",
      "--workspace",
      "zs1JP9sA",
      "--model",
      "gpt-5.5",
      "--prompt",
      prompt,
    ]);

    expect(classification).toMatchObject({
      ok: true,
      kind: "approved-write",
      approvalDetails: {
        action: "oppi session create",
        target: { label: "Workspace", value: "zs1JP9sA" },
        arguments: ["--model", "gpt-5.5"],
        bodies: [{ label: "Prompt", value: prompt }],
      },
    });
    if (!classification.ok) return;
    expect(classification.displayCommand).toContain(`--prompt [${prompt.length} chars]`);
    expect(classification.displayCommand).not.toContain("rm -rf");
    expect(classification.approvalMessage).toContain("## Command");
    expect(classification.approvalMessage).toContain("## Workspace");
    expect(classification.approvalMessage).toContain("## Arguments");
    expect(classification.approvalMessage).toContain("## Prompt");
    expect(classification.approvalMessage).toContain(prompt);
    expect(classification.approvalMessage).toContain("~~~text");
  });

  it("shell-quotes approval arguments and keeps markdown-like values inert", () => {
    const classification = classifyOppiToolCommand([
      "session",
      "send",
      "session with spaces",
      "--text",
      "# Not a heading\n[link](oppi://session/unsafe)\n~~~",
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        action: "oppi session send",
        target: { label: "Session", value: "session with spaces" },
        bodies: [
          {
            label: "Message",
            value: "# Not a heading\n[link](oppi://session/unsafe)\n~~~",
          },
        ],
      },
    });
    if (!classification.ok) return;
    expect(classification.approvalMessage).toContain("session with spaces");
    expect(classification.approvalMessage).toContain("```text\n# Not a heading");
  });

  it("uses indented code when a body contains both Markdown fence styles", () => {
    const prompt = "```\n~~~";
    const classification = classifyOppiToolCommand([
      "session",
      "create",
      "--workspace",
      "oppi",
      "--prompt",
      prompt,
    ]);

    expect(classification).toMatchObject({ ok: true });
    if (!classification.ok) return;
    expect(classification.approvalMessage).toContain("## Prompt\n\n    ```\n    ~~~");
    expect(classification.approvalMessage).not.toContain("````text");
    expect(classification.approvalMessage).not.toContain("~~~~text");
  });

  it("rejects indirect bodies that cannot be inspected and executed as the same snapshot", () => {
    for (const args of [
      ["agent", "update", "default", "--definition", "agent.json"],
      ["schedule", "update", "sch-1", "--definition", "schedule.json"],
      ["session", "create", "--workspace", "oppi", "--prompt", "@-"],
      ["session", "send", "sess-1", "--text", "@-"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toEqual({
        ok: false,
        reason: expect.stringContaining("inline"),
      });
    }
  });

  it("separates a positional target from its workspace context", () => {
    const classification = classifyOppiToolCommand([
      "worktree",
      "remove",
      "wt_feature-review-12345678",
      "--workspace",
      "oppi",
      "--force",
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        target: { label: "Worktree", value: "wt_feature-review-12345678" },
        context: { label: "Workspace", value: "oppi" },
        arguments: ["--force"],
      },
    });
  });

  it("treats a long system prompt as a labeled body", () => {
    const systemPrompt = "Act safely.\n" + "x".repeat(500);
    const classification = classifyOppiToolCommand([
      "workspace",
      "update",
      "oppi",
      "--system-prompt",
      systemPrompt,
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        target: { label: "Workspace", value: "oppi" },
        bodies: [{ label: "System prompt", value: systemPrompt }],
      },
    });
  });

  it("shows every supplied body field instead of hiding effective input", () => {
    const definition = '{"description":"effective definition"}';
    const systemPrompt = "effective system prompt";
    const classification = classifyOppiToolCommand([
      "agent",
      "update",
      "default",
      "--prompt",
      "decoy prompt",
      "--definition-json",
      definition,
      "--system-prompt",
      systemPrompt,
    ]);

    expect(classification).toMatchObject({
      ok: true,
      approvalDetails: {
        bodies: [
          { label: "Prompt", value: "decoy prompt" },
          { label: "Definition", value: definition },
          { label: "System prompt", value: systemPrompt },
        ],
      },
    });
    if (!classification.ok) return;
    expect(classification.approvalMessage).toContain("## Prompt");
    expect(classification.approvalMessage).toContain("## Definition");
    expect(classification.approvalMessage).toContain("## System prompt");
  });

  it("rejects oversized inline definitions before approval", () => {
    const classification = classifyOppiToolCommand([
      "agent",
      "update",
      "default",
      "--definition-json",
      JSON.stringify({ description: "x".repeat(65_536) }),
    ]);

    expect(classification).toEqual({
      ok: false,
      reason: "--definition-json exceeds maximum size of 65536 bytes",
    });
  });

  it("requires approval for destructive non-reversible commands", () => {
    for (const args of [
      ["workspace", "delete", "oppi"],
      ["agent", "archive", "default"],
      ["session", "delete", "sess-1"],
      ["worktree", "remove", "wt_feature-review-12345678", "--workspace", "oppi", "--force"],
      ["schedule", "archive", "sch-1"],
    ]) {
      expect(classifyOppiToolCommand(args), args.join(" ")).toMatchObject({
        ok: true,
        kind: "approved-write",
      });
    }
  });
});

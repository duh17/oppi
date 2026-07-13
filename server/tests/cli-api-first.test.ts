import { execFile } from "node:child_process";
import { createServer as createHttpServer, type ServerResponse } from "node:http";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { ConfigStore } from "../src/storage/config-store.js";

const CLI = process.env.OPPI_TEST_CLI ?? resolve(__dirname, "../dist/src/cli.js");

function writeCliConfig(dataDir: string, port: number): void {
  mkdirSync(dataDir, { recursive: true });
  const config = {
    ...ConfigStore.getDefaultConfig(dataDir),
    host: "127.0.0.1",
    port,
    token: "test-owner-token",
    tls: { mode: "disabled" as const },
  };
  writeFileSync(join(dataDir, "config.json"), `${JSON.stringify(config, null, 2)}\n`);
}

function sessionStateDbFiles(dataDir: string): string[] {
  return readdirSync(dataDir).filter((name) => name.startsWith("session-state.db"));
}

async function runCli(args: string[], dataDir: string): Promise<string> {
  return await new Promise((resolveRun, rejectRun) => {
    execFile(
      "node",
      [CLI, ...args],
      { encoding: "utf-8", env: { ...process.env, OPPI_DATA_DIR: dataDir } },
      (error, stdout, stderr) => {
        if (error) {
          rejectRun(new Error(stderr || stdout || error.message));
          return;
        }
        resolveRun(stdout);
      },
    );
  });
}

type TraceOutlineFixtureEntry = {
  id: string;
  kind: string;
  summary: string;
  tool?: string;
  isError?: boolean;
};

async function runTraceOutlineCli(entries: TraceOutlineFixtureEntry[]): Promise<string> {
  const fixtureDataDir = mkdtempSync(join(tmpdir(), "oppi-cli-trace-outline-"));
  const api = createHttpServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    res.writeHead(200, { "Content-Type": "application/json" });
    if (url.pathname === "/sessions/sess-1") {
      res.end(JSON.stringify({ session: { id: "sess-1", workspaceId: "ws-1" } }));
      return;
    }
    if (url.pathname === "/workspaces/ws-1/sessions/sess-1/trace-outline") {
      res.end(
        JSON.stringify({
          session: { id: "sess-1", workspaceId: "ws-1" },
          outline: {
            traceVersion: "fixture",
            entries,
            itemCount: entries.length,
            sourceCount: entries.length > 0 ? 1 : 0,
            jsonlBytes: entries.length > 0 ? 100 : 0,
          },
          metrics: {},
        }),
      );
      return;
    }
    res.end(JSON.stringify({ error: `Unexpected route: ${url.pathname}` }));
  });

  try {
    await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("API fixture did not bind");
    writeCliConfig(fixtureDataDir, address.port);
    return await runCli(["session", "trace-outline", "sess-1"], fixtureDataDir);
  } finally {
    await new Promise<void>((resolveClose, rejectClose) =>
      api.close((error) => (error ? rejectClose(error) : resolveClose())),
    );
    rmSync(fixtureDataDir, { recursive: true, force: true });
  }
}

// ── Session orchestration fixtures (steer/abort/dialogs/respond/watch/wait) ──

interface OrchRequest {
  method: string;
  path: string;
  query: string;
  body?: Record<string, unknown>;
}

function sendJson(res: ServerResponse, data: unknown, status = 200): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

function stripAnsi(text: string): string {
  // eslint-disable-next-line no-control-regex
  return text.replace(/\x1b\[[0-9;]*m/g, "");
}

function runCliResult(
  args: string[],
  cliDataDir: string,
  stdin?: string,
): Promise<{ stdout: string; code: number }> {
  return new Promise((resolveRun) => {
    const child = execFile(
      "node",
      [CLI, ...args],
      { encoding: "utf-8", env: { ...process.env, OPPI_DATA_DIR: cliDataDir } },
      (error, stdout) => {
        const code =
          error && typeof (error as { code?: unknown }).code === "number"
            ? (error as { code: number }).code
            : error
              ? 1
              : 0;
        resolveRun({ stdout: stdout ?? "", code });
      },
    );
    if (stdin !== undefined) child.stdin?.end(stdin);
  });
}

async function withOrchApi<T>(
  handler: (res: ServerResponse, ctx: { path: string; body?: Record<string, unknown> }) => void,
  run: (ctx: { dataDir: string; requests: OrchRequest[] }) => Promise<T>,
): Promise<T> {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-orch-"));
  const requests: OrchRequest[] = [];
  const api = createHttpServer((req, res) => {
    void (async () => {
      const chunks: Buffer[] = [];
      for await (const chunk of req) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
      }
      const raw = Buffer.concat(chunks).toString("utf8");
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const body = raw ? (JSON.parse(raw) as Record<string, unknown>) : undefined;
      requests.push({
        method: req.method ?? "GET",
        path: url.pathname,
        query: url.search,
        ...(body ? { body } : {}),
      });
      handler(res, { path: url.pathname, ...(body ? { body } : {}) });
    })();
  });

  try {
    await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
    const address = api.address();
    if (!address || typeof address === "string") throw new Error("API fixture did not bind");
    writeCliConfig(dataDir, address.port);
    return await run({ dataDir, requests });
  } finally {
    await new Promise<void>((resolveClose, rejectClose) =>
      api.close((error) => (error ? rejectClose(error) : resolveClose())),
    );
    rmSync(dataDir, { recursive: true, force: true });
  }
}

describe("CLI app-state API boundary", () => {
  it("prints help without the decorative banner", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-help-"));
    try {
      const { stdout, code } = await runCliResult(["session", "--help"], dataDir);
      expect(code).toBe(0);
      expect(stdout).toContain("Oppi sessions");
      expect(stdout).not.toContain("╭");
      expect(stdout).not.toContain("π  oppi");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("serves workspace reads through the local API without opening session-state SQLite", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-api-first-"));
    const requests: string[] = [];
    const api = createHttpServer((req, res) => {
      requests.push(`${req.method ?? "GET"} ${req.url ?? "/"}`);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ workspaces: [{ id: "ws-1", name: "Oppi" }] }));
    });

    try {
      await new Promise<void>((resolveListen) => api.listen(0, "127.0.0.1", resolveListen));
      const address = api.address();
      if (!address || typeof address === "string") throw new Error("API fixture did not bind");
      writeCliConfig(dataDir, address.port);

      const stdout = await runCli(["workspace", "list", "--json"], dataDir);

      expect(JSON.parse(stdout)).toMatchObject({
        ok: true,
        data: { workspaces: [{ id: "ws-1", name: "Oppi" }] },
      });
      expect(requests).toEqual(["GET /workspaces"]);
      expect(sessionStateDbFiles(dataDir)).toEqual([]);
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("keeps session list, search, and trace JSON compact", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/recent") {
          sendJson(res, {
            serverNow: 123,
            sessions: [
              {
                id: "sess-1",
                status: "busy",
                name: "Review",
                workspaceId: "ws-1",
                workspaceName: "Oppi",
                worktreeId: "main",
                model: "test/model",
                runtime: "oppi",
                lastActivity: 100,
                messageCount: 4,
                changeStats: { changedFiles: Array.from({ length: 20 }, (_, i) => `file-${i}`) },
              },
            ],
          });
          return;
        }
        if (ctx.path === "/sessions/search") {
          sendJson(res, {
            query: "review",
            totalResults: 1,
            results: [
              {
                sessionId: "sess-1",
                workspaceId: "ws-1",
                title: "Review",
                snippet: "matched",
                rank: 0.9,
                updatedAtMs: 100,
                session: { id: "sess-1", changeStats: { changedFiles: ["garbage"] } },
              },
            ],
          });
          return;
        }
        if (ctx.path === "/sessions/sess-1/read" || ctx.path === "/sessions/sess-1/trace") {
          sendJson(res, {
            session: { id: "sess-1", workspaceId: "ws-1", changeStats: { changedFiles: ["x"] } },
            trace: [{ type: "assistant", text: "done" }],
          });
          return;
        }
        sendJson(res, { error: "unexpected route" }, 404);
      },
      async ({ dataDir }) => {
        const list = JSON.parse(
          (await runCliResult(["session", "list", "--json"], dataDir)).stdout,
        ).data;
        expect(list).toEqual({
          sessions: [
            {
              id: "sess-1",
              status: "busy",
              name: "Review",
              workspace_id: "ws-1",
              workspace_name: "Oppi",
              worktree_id: "main",
              model: "test/model",
              runtime: "oppi",
              last_activity: 100,
              message_count: 4,
              pending_asks: 0,
            },
          ],
        });

        const search = JSON.parse(
          (await runCliResult(["session", "search", "review", "--all", "--json"], dataDir)).stdout,
        ).data;
        expect(search).toEqual({
          query: "review",
          total_results: 1,
          results: [
            {
              session_id: "sess-1",
              workspace_id: "ws-1",
              title: "Review",
              snippet: "matched",
              rank: 0.9,
              updated_at_ms: 100,
            },
          ],
        });

        for (const command of ["read", "trace"]) {
          const data = JSON.parse(
            (await runCliResult(["session", command, "sess-1", "--json"], dataDir)).stdout,
          ).data as Record<string, unknown>;
          expect(data).toEqual({
            session_id: "sess-1",
            trace: [{ type: "assistant", text: "done" }],
          });
        }
      },
    );
  }, 20_000);

  it("renders trace outline messages and tool activity from the API snapshot", async () => {
    const stdout = await runTraceOutlineCli([
      { id: "u1", kind: "user", summary: "first prompt" },
      { id: "a1-text-0", kind: "assistant", summary: "first answer" },
      {
        id: "tc-1",
        kind: "tool",
        tool: "read",
        summary: "read server/src/trace.ts",
        isError: false,
      },
    ]);

    expect(stdout).toContain("Trace outline for sess-1 (3)");
    expect(stdout).toContain("u1  user  first prompt");
    expect(stdout).toContain("a1-text-0  assistant  first answer");
    expect(stdout).toContain("tc-1  tool  read server/src/trace.ts");
    expect(stdout).toContain("tool read");
  });

  it("states clearly when the API trace outline is genuinely empty", async () => {
    const stdout = await runTraceOutlineCli([]);

    expect(stdout).toContain("Trace outline for sess-1 (0)");
    expect(stdout).toContain("No trace entries found.");
  });

  it("maps send --steer / --follow-up and abort to runtime command types", async () => {
    await withOrchApi(
      (res) => sendJson(res, { messages: [] }),
      async ({ dataDir, requests }) => {
        await runCliResult(
          ["session", "send", "sess-1", "--text", "hi", "--steer", "--json"],
          dataDir,
        );
        await runCliResult(
          ["session", "send", "sess-1", "--text", "later", "--follow-up", "--json"],
          dataDir,
        );
        await runCliResult(["session", "abort", "sess-1", "--json"], dataDir);

        const commandTypes = requests
          .filter((request) => request.path === "/sessions/sess-1/command")
          .map((request) => request.body?.type);
        expect(commandTypes).toEqual(["steer", "follow_up", "abort"]);
      },
    );
  });

  it("returns only the stable snake_case session id from create JSON", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/workspaces/ws-1") {
          sendJson(res, { workspace: { id: "ws-1", name: "Oppi" } });
          return;
        }
        if (ctx.path === "/workspaces/ws-1/sessions") {
          sendJson(res, {
            session: { id: "created-1", workspaceId: "ws-1", status: "busy" },
            prompted: true,
          });
          return;
        }
        sendJson(res, { error: "unexpected route" }, 404);
      },
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          ["session", "create", "--workspace", "ws-1", "--prompt", "review", "--json"],
          dataDir,
        );
        expect(code).toBe(0);
        expect(JSON.parse(stdout)).toEqual({ ok: true, data: { session_id: "created-1" } });
      },
    );
  });

  it("reads create prompts from stdin when --prompt is @-", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/workspaces/ws-1") {
          sendJson(res, { workspace: { id: "ws-1", name: "Oppi" } });
          return;
        }
        if (ctx.path === "/workspaces/ws-1/sessions") {
          sendJson(res, { session: { id: "created-stdin", workspaceId: "ws-1" } });
          return;
        }
        sendJson(res, { error: "unexpected route" }, 404);
      },
      async ({ dataDir, requests }) => {
        const { code } = await runCliResult(
          ["session", "create", "--workspace", "ws-1", "--prompt", "@-", "--json"],
          dataDir,
          "prompt piped over stdin\n",
        );
        expect(code).toBe(0);
        expect(
          requests.find((request) => request.path === "/workspaces/ws-1/sessions")?.body,
        ).toMatchObject({ prompt: "prompt piped over stdin\n" });
      },
    );
  });

  it("resolves create stdin before the saved-Agent launch boundary", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/workspaces/ws-1") {
          sendJson(res, { workspace: { id: "ws-1", name: "Oppi" } });
          return;
        }
        if (ctx.path === "/agents/reviewer/sessions") {
          sendJson(res, {
            session: { id: "created-agent-stdin", workspaceId: "ws-1" },
          });
          return;
        }
        sendJson(res, { error: "unexpected route" }, 404);
      },
      async ({ dataDir, requests }) => {
        const { code } = await runCliResult(
          [
            "session",
            "create",
            "--agent",
            "reviewer",
            "--workspace",
            "ws-1",
            "--prompt",
            "@-",
            "--json",
          ],
          dataDir,
          "saved-Agent prompt from stdin\n",
        );
        expect(code).toBe(0);
        expect(
          requests.find((request) => request.path === "/agents/reviewer/sessions")?.body,
        ).toMatchObject({ prompt: { text: "saved-Agent prompt from stdin\n" } });
      },
    );
  });

  it("reads sent text from stdin when --text is @-", async () => {
    await withOrchApi(
      (res) => sendJson(res, { messages: [] }),
      async ({ dataDir, requests }) => {
        const { code } = await runCliResult(
          ["session", "send", "sess-1", "--text", "@-", "--json"],
          dataDir,
          "message piped over stdin\n",
        );
        expect(code).toBe(0);
        expect(requests[0]?.body).toMatchObject({
          type: "prompt",
          message: "message piped over stdin\n",
        });
      },
    );
  });

  it("hints at --steer/--follow-up when a plain prompt hits a busy session", async () => {
    await withOrchApi(
      (res) =>
        sendJson(
          res,
          {
            error:
              "Prompt requires an idle session; use steer or follow_up while a turn is streaming",
          },
          500,
        ),
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          ["session", "send", "sess-1", "--text", "hi", "--json"],
          dataDir,
        );
        expect(code).toBe(1);
        const envelope = JSON.parse(stdout) as { ok: boolean; error?: { message?: string } };
        expect(envelope.ok).toBe(false);
        expect(envelope.error?.message).toContain("idle session");
        expect(envelope.error?.message).toContain("--steer");
        expect(envelope.error?.message).toContain("--follow-up");
      },
    );
  });

  it("treats command error messages as CLI failures", async () => {
    await withOrchApi(
      (res) =>
        sendJson(res, {
          messages: [{ type: "error", error: "Prompt requires an idle session" }],
        }),
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          ["session", "send", "sess-1", "--text", "hi", "--json"],
          dataDir,
        );
        expect(code).toBe(1);
        const envelope = JSON.parse(stdout) as { ok: boolean; error?: { message?: string } };
        expect(envelope.ok).toBe(false);
        expect(envelope.error?.message).toContain("Prompt requires an idle session");
        expect(envelope.error?.message).toContain("--steer");
      },
    );
  });

  it("lists pending dialogs with prompt and option details", async () => {
    await withOrchApi(
      (res) =>
        sendJson(res, {
          dialogs: [
            {
              id: "ask-1",
              method: "ask",
              questions: [
                {
                  id: "approach",
                  question: "Which approach?",
                  options: [{ value: "unit", label: "Unit" }],
                },
              ],
              allowCustom: false,
            },
          ],
        }),
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(["session", "dialogs", "sess-1"], dataDir);
        expect(code).toBe(0);
        const text = stripAnsi(stdout);
        expect(text).toContain("Pending dialogs for sess-1 (1)");
        expect(text).toContain("ask-1");
        expect(text).toContain("Which approach?");
        expect(text).toContain("unit — Unit");
      },
    );
  });

  it("answers a single-question ask by building the answer JSON", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1/dialogs") {
          sendJson(res, {
            dialogs: [
              {
                id: "ask-1",
                method: "ask",
                questions: [
                  {
                    id: "approach",
                    question: "Which?",
                    options: [{ value: "unit", label: "Unit" }],
                  },
                ],
              },
            ],
          });
          return;
        }
        sendJson(res, { messages: [] });
      },
      async ({ dataDir, requests }) => {
        const { code } = await runCliResult(
          ["session", "respond", "sess-1", "--option", "unit", "--json"],
          dataDir,
        );
        expect(code).toBe(0);
        const command = requests.find((request) => request.path === "/sessions/sess-1/command");
        expect(command?.body).toEqual({
          type: "extension_ui_response",
          id: "ask-1",
          value: JSON.stringify({ approach: "unit" }),
        });
      },
    );
  });

  it("rejects an unknown ask option before posting a response", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1/dialogs") {
          sendJson(res, {
            dialogs: [
              {
                id: "ask-1",
                method: "ask",
                questions: [
                  {
                    id: "approach",
                    question: "Which?",
                    options: [{ value: "unit", label: "Unit" }],
                  },
                ],
                allowCustom: false,
              },
            ],
          });
          return;
        }
        sendJson(res, { messages: [] });
      },
      async ({ dataDir, requests }) => {
        const { stdout, code } = await runCliResult(
          ["session", "respond", "sess-1", "--option", "bogus", "--json"],
          dataDir,
        );
        expect(code).toBe(1);
        expect(JSON.parse(stdout)).toMatchObject({
          ok: false,
          error: { message: 'Unknown option "bogus" for question approach' },
        });
        expect(requests.filter((request) => request.path.endsWith("/command"))).toHaveLength(0);
      },
    );
  });

  it("rejects unsupported session flags before making an API request", async () => {
    await withOrchApi(
      (res) => sendJson(res, { error: "should not be called" }, 500),
      async ({ dataDir, requests }) => {
        const { stdout, code } = await runCliResult(
          ["session", "inspect", "sess-1", "--limit", "5", "--json"],
          dataDir,
        );
        expect(code).toBe(1);
        expect(JSON.parse(stdout)).toEqual({
          ok: false,
          error: { message: "Unsupported flag for 'session inspect': --limit" },
        });
        expect(requests).toEqual([]);
      },
    );
  });

  it("rejects conflicting inspect aliases before making an API request", async () => {
    await withOrchApi(
      (res) => sendJson(res, { error: "should not be called" }, 500),
      async ({ dataDir, requests }) => {
        const { stdout, code } = await runCliResult(
          ["session", "inspect", "sess-1", "--turn", "1", "--turns", "2", "--json"],
          dataDir,
        );
        expect(code).toBe(1);
        expect(JSON.parse(stdout)).toEqual({
          ok: false,
          error: { message: "Conflicting flags: --turn and --turns" },
        });
        expect(requests).toEqual([]);
      },
    );
  });

  it("emits compact inspect JSON without redundant turn or session aliases", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1") {
          sendJson(res, {
            session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" },
          });
          return;
        }
        if (ctx.path === "/workspaces/ws-1/sessions/sess-1/trace-outline") {
          sendJson(res, {
            outline: {
              entries: [
                { id: "u1", kind: "user", summary: "review" },
                { id: "a1", kind: "assistant", summary: "done" },
              ],
            },
          });
          return;
        }
        sendJson(res, { error: "unexpected route" }, 404);
      },
      async ({ dataDir }) => {
        const summaryRun = await runCliResult(
          ["session", "inspect", "sess-1", "--view", "summary", "--json"],
          dataDir,
        );
        expect(summaryRun.code).toBe(0);
        expect(Object.keys(JSON.parse(summaryRun.stdout).data).sort()).toEqual(["summary", "view"]);

        const outlineRun = await runCliResult(
          ["session", "inspect", "sess-1", "--view", "outline", "--json"],
          dataDir,
        );
        expect(outlineRun.code).toBe(0);
        const data = JSON.parse(outlineRun.stdout).data as Record<string, unknown>;
        expect(Object.keys(data).sort()).toEqual(["selected_turns", "summary", "text", "view"]);
        expect(data.selected_turns).toEqual([1]);
      },
    );
  });

  it("watch streams NDJSON transitions and resolves on idle", async () => {
    let polls = 0;
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1/events") {
          polls += 1;
          const status = polls >= 2 ? "ready" : "busy";
          sendJson(res, {
            session: { id: "sess-1", status, messageCount: polls },
            events:
              status === "ready"
                ? [{ type: "message_end", role: "assistant", content: "Build succeeds" }]
                : [{ type: "tool_start", tool: "bash" }],
            currentSeq: polls,
          });
          return;
        }
        sendJson(res, {});
      },
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          [
            "session",
            "watch",
            "sess-1",
            "--until",
            "idle",
            "--interval",
            "20ms",
            "--timeout",
            "5s",
            "--json",
          ],
          dataDir,
        );
        expect(code).toBe(0);
        const events = stdout
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line) as Record<string, unknown>);
        expect(events).toHaveLength(1);
        expect(events[0]).toMatchObject({
          event: "resolved",
          session_id: "sess-1",
          reason: "idle",
          prev: "busy",
          status: "ready",
        });
        expect(events[0]).not.toHaveProperty("pending_dialogs");
      },
    );
  });

  it("watch any-change resolves on new event activity without a status change", async () => {
    let polls = 0;
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1/events") {
          polls += 1;
          sendJson(res, {
            session: { id: "sess-1", status: "busy" },
            events: polls === 1 ? [] : [{ type: "tool_start", tool: "bash" }],
            currentSeq: polls,
          });
          return;
        }
        sendJson(res, { dialogs: [] });
      },
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          [
            "session",
            "watch",
            "sess-1",
            "--until",
            "any-change",
            "--interval",
            "20ms",
            "--timeout",
            "2s",
            "--json",
          ],
          dataDir,
        );
        expect(code).toBe(0);
        const events = stdout
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line) as Record<string, unknown>);
        expect(events).toHaveLength(1);
        expect(events[0]).toMatchObject({
          event: "resolved",
          reason: "change",
          status: "busy",
          tool_calls: 1,
        });
      },
    );
  });

  it("watch --all requires every session to currently meet a state condition", async () => {
    const polls = new Map<string, number>();
    await withOrchApi(
      (res, ctx) => {
        const match = ctx.path.match(/^\/sessions\/(s[12])\/events$/);
        if (match) {
          const id = match[1] ?? "";
          const poll = (polls.get(id) ?? 0) + 1;
          polls.set(id, poll);
          const statuses = id === "s1" ? ["ready", "busy", "ready"] : ["busy", "ready", "ready"];
          sendJson(res, {
            session: { id, status: statuses[Math.min(poll - 1, statuses.length - 1)] },
            events: [],
            currentSeq: poll,
          });
          return;
        }
        sendJson(res, {});
      },
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          [
            "session",
            "watch",
            "s1",
            "s2",
            "--until",
            "idle",
            "--all",
            "--interval",
            "20ms",
            "--timeout",
            "2s",
            "--json",
          ],
          dataDir,
        );
        expect(code).toBe(0);
        expect(polls).toEqual(
          new Map([
            ["s1", 3],
            ["s2", 3],
          ]),
        );
        expect(JSON.parse(stdout.trim().split("\n").at(-1) ?? "{}")).toMatchObject({
          event: "resolved",
          all: true,
          sessions: [
            { session_id: "s1", status: "ready" },
            { session_id: "s2", status: "ready" },
          ],
        });
      },
    );
  });

  it("keeps API failures as one parseable NDJSON error record", async () => {
    await withOrchApi(
      (res) => sendJson(res, { error: "fixture failure" }, 500),
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          ["session", "watch", "sess-1", "--timeout", "2s", "--json"],
          dataDir,
        );
        expect(code).toBe(1);
        const lines = stdout.trim().split("\n");
        expect(lines).toHaveLength(1);
        expect(JSON.parse(lines[0] ?? "{}")).toMatchObject({
          event: "error",
          message: "fixture failure",
          status: 500,
        });
      },
    );
  });

  it("watch exits nonzero with an NDJSON timeout when the condition is never met", async () => {
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1/events") {
          sendJson(res, { session: { id: "sess-1", status: "busy" }, events: [], currentSeq: 1 });
          return;
        }
        sendJson(res, {});
      },
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          [
            "session",
            "watch",
            "sess-1",
            "--until",
            "idle",
            "--interval",
            "20ms",
            "--timeout",
            "120ms",
            "--json",
          ],
          dataDir,
        );
        expect(code).toBe(1);
        const events = stdout
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line) as Record<string, unknown>);
        expect(events).toHaveLength(1);
        expect(events[0]).toMatchObject({ event: "timeout", condition: "idle" });
      },
    );
  });

  it("wait resolves to a terminal record when the session goes idle", async () => {
    let polls = 0;
    await withOrchApi(
      (res, ctx) => {
        if (ctx.path === "/sessions/sess-1/events") {
          polls += 1;
          sendJson(res, {
            session: { id: "sess-1", status: polls >= 2 ? "ready" : "busy" },
            events: [],
            currentSeq: polls,
          });
          return;
        }
        sendJson(res, {});
      },
      async ({ dataDir }) => {
        const { stdout, code } = await runCliResult(
          [
            "session",
            "wait",
            "sess-1",
            "--for",
            "idle",
            "--poll",
            "20ms",
            "--timeout",
            "5s",
            "--json",
          ],
          dataDir,
        );
        expect(code).toBe(0);
        expect(JSON.parse(stdout)).toMatchObject({
          ok: true,
          data: { session_id: "sess-1", reason: "idle", status: "ready" },
        });
      },
    );
  });
});

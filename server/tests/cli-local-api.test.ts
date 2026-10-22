/**
 * CLI integration tests: commands that talk to the local API (sessions, workspaces, and friends).
 * Each test uses a temp data dir via OPPI_DATA_DIR to avoid touching real config.
 */
import { describe, expect, it } from "vitest";
import { createServer as createHttpServer } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";
import { run, runAsync, seedConfiguredHost, useCliDataDir } from "./harness/cli-test-env.js";

useCliDataDir();

// ── Local API CLI ──

describe("oppi local API commands", () => {
  it("implements the spec-backed app-control CLI over local API routes", async () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-cli-workspace-"));
    const worktreeRoot = mkdtempSync(join(tmpdir(), "oppi-cli-worktree-"));
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-app-control-"));
    const requests: Array<{ method: string; path: string; body?: unknown }> = [];
    const api = createHttpServer((req, res) => {
      void (async () => {
        const chunks: Buffer[] = [];
        for await (const chunk of req) {
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
        }
        const rawBody = Buffer.concat(chunks).toString("utf8");
        const body = rawBody ? JSON.parse(rawBody) : undefined;
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        const method = req.method ?? "GET";
        requests.push({ method, path: `${url.pathname}${url.search}`, ...(body ? { body } : {}) });

        function json(payload: unknown): void {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify(payload));
        }

        if (method === "GET" && url.pathname === "/workspaces") {
          json({
            workspaces: [{ id: "ws-1", name: "Oppi", hostMount: workspaceRoot }],
            summaries: [],
            serverNow: 1,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1") {
          json({ workspace: { id: "ws-1", name: "Oppi", hostMount: workspaceRoot } });
          return;
        }
        if (method === "GET" && url.pathname === "/models") {
          json({
            models: [
              {
                id: "openrouter/anthropic/claude-sonnet-4-20250514",
                name: "Claude Sonnet 4 via OpenRouter",
                provider: "openrouter",
                authKind: "apiKey",
              },
              {
                id: "anthropic/claude-sonnet-4-20250514",
                name: "Claude Sonnet 4",
                provider: "anthropic",
                authKind: "subscription",
              },
              {
                id: "openai/gpt-5.3-codex",
                name: "GPT-5.3 Codex",
                provider: "openai",
                authKind: "apiKey",
              },
            ],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces") {
          json({
            workspace: {
              id: "ws-created",
              name: body?.name ?? "Created",
              hostMount: body?.hostMount,
            },
          });
          return;
        }
        if (method === "PUT" && url.pathname === "/workspaces/ws-1") {
          json({
            workspace: {
              id: "ws-1",
              name: body?.name ?? "Oppi",
              hostMount: body?.hostMount ?? "/tmp/oppi",
            },
          });
          return;
        }
        if (method === "DELETE" && url.pathname === "/workspaces/ws-1") {
          json({ ok: true });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/worktrees") {
          json({
            workspaceId: "ws-1",
            worktrees: [
              { id: "main", name: "main", path: workspaceRoot },
              { id: "wt-feature", name: "feature", path: worktreeRoot },
            ],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/worktrees") {
          json({
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: body?.branch ?? "feature/cli",
              branch: body?.branch ?? "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
          });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/worktrees/open") {
          json({
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: body?.branch ?? "feature/cli",
              branch: body?.branch ?? "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
          });
          return;
        }
        if (
          method === "GET" &&
          url.pathname === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678/status"
        ) {
          json({
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: "feature/cli",
              branch: "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
            status: { isGitRepo: true, branch: "feature/cli", dirtyCount: 0, untrackedCount: 0 },
          });
          return;
        }
        if (
          method === "POST" &&
          url.pathname === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678/preview"
        ) {
          json({
            workspaceId: "ws-1",
            preview: {
              worktree: { id: "wt_feature-cli-12345678", name: "feature/cli" },
              target: { ref: body?.into ?? "main", headSha: "target-sha" },
              source: { branch: "feature/cli", headSha: "source-sha" },
              mode: body?.mode ?? "merge",
              commitCount: 1,
              commits: [{ sha: "abc123", subject: "change" }],
              changedFiles: [{ status: "M", path: "README.md" }],
              alreadyMerged: false,
              fastForwardPossible: true,
              conflictCheck: "clean",
            },
          });
          return;
        }
        if (
          method === "DELETE" &&
          url.pathname === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678"
        ) {
          json({
            ok: true,
            workspaceId: "ws-1",
            worktree: {
              id: "wt_feature-cli-12345678",
              name: "feature/cli",
              branch: "feature/cli",
              path: "/tmp/oppi-data/worktrees/ws-1/wt_feature-cli-12345678",
              managedByOppi: true,
            },
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/recent") {
          json({
            sessions: [
              {
                id: "sess-recent",
                workspaceId: "ws-1",
                worktreeId: "main",
                status: "stopped",
                name: "Recent Demo",
              },
            ],
            serverNow: 2,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions") {
          json({
            workspaceId: "ws-1",
            sinceMs: Number(url.searchParams.get("sinceMs")),
            untilMs: Number(url.searchParams.get("untilMs")),
            serverNow: 2,
            active: [],
            stopped: [
              {
                id: "sess-1",
                workspaceId: "ws-1",
                worktreeId: "main",
                status: "stopped",
                name: "Demo",
              },
              {
                id: "/tmp/tui.jsonl",
                source: "tui",
                workspaceId: "ws-1",
                status: "stopped",
                name: "Terminal Demo",
                path: "/tmp/tui.jsonl",
                piSessionId: "pi-1",
              },
            ],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/sessions") {
          json({
            session: {
              id: "sess-created",
              workspaceId: "ws-1",
              status: "ready",
              model: body?.model,
            },
            prompted: true,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions") {
          json({
            sessions: [
              { id: "sess-1", workspaceId: "ws-1", status: "stopped" },
              { id: "sess-recent", workspaceId: "ws-1", status: "stopped" },
              { id: "sess-malformed", workspaceId: "ws-1", status: "stopped" },
              { id: "sess-leading", workspaceId: "ws-1", status: "stopped" },
              { id: "sess-data-url", workspaceId: "ws-1", status: "stopped" },
              { id: "sess-trailing-user", workspaceId: "ws-1", status: "stopped" },
              { id: "sess-agent-1", workspaceId: "ws-1", status: "ready" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/search") {
          json({
            query: url.searchParams.get("q"),
            totalResults: 1,
            results: [{ sessionId: "sess-1", snippet: "matched test output", rank: 0.9 }],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1") {
          json({ session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" } });
          return;
        }
        if (method === "GET" && url.pathname === "/agents") {
          json({ agents: [{ id: "agent-1", name: "Reviewer", status: "active", version: 1 }] });
          return;
        }
        if (method === "GET" && url.pathname === "/agents/agent-1") {
          json({
            agent: {
              id: "agent-1",
              name: "Reviewer",
              status: "active",
              version: 1,
              definition: { name: "Reviewer" },
            },
          });
          return;
        }
        if (method === "POST" && url.pathname === "/agents") {
          json({
            agent: {
              id: "agent-created",
              name: body?.name ?? "Created",
              status: "active",
              version: 1,
              definition: body,
            },
          });
          return;
        }
        if (method === "PATCH" && url.pathname === "/agents/agent-1") {
          json({
            agent: {
              id: "agent-1",
              name: "Reviewer",
              status: "active",
              version: 2,
              definition: body,
            },
          });
          return;
        }
        if (method === "DELETE" && url.pathname === "/agents/agent-1") {
          json({ agent: { id: "agent-1", name: "Reviewer", status: "archived", version: 2 } });
          return;
        }
        if (method === "POST" && url.pathname === "/agents/agent-1/sessions") {
          json({
            receipt: {
              accepted: true,
              agentId: "agent-1",
              agentVersion: 1,
              sessionId: "sess-agent-1",
              promptDispatch: "delivered",
            },
            session: { id: "sess-agent-1", workspaceId: "ws-1", status: "ready" },
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1/events") {
          json({
            events: [{ seq: 5, type: "session_updated" }],
            currentSeq: 5,
            catchUpComplete: true,
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-malformed/trace") {
          json({ session: { id: "sess-malformed", workspaceId: "ws-1", status: "stopped" } });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-leading/trace") {
          json({
            session: { id: "sess-leading", workspaceId: "ws-1", status: "stopped" },
            trace: [
              { type: "system", text: "Model: test-model" },
              { type: "compaction", text: "summary before prompt" },
              { type: "user", text: "first prompt" },
              { type: "assistant", text: "first answer" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-data-url/trace") {
          json({
            session: { id: "sess-data-url", workspaceId: "ws-1", status: "stopped" },
            trace: [
              {
                type: "user",
                text: "inspect this image\ndata:image/png;base64,QUJDREVGRw==",
              },
              { type: "assistant", text: "image inspected" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-trailing-user/trace") {
          json({
            session: { id: "sess-trailing-user", workspaceId: "ws-1", status: "stopped" },
            trace: [
              { type: "user", text: "first prompt" },
              { type: "assistant", text: "completed response" },
              { type: "user", text: "unanswered follow-up" },
            ],
          });
          return;
        }
        if (method === "GET" && url.pathname === "/sessions/sess-1/trace") {
          const fullTrace = [
            { type: "user", text: "hello" },
            { type: "assistant", text: "trace" },
            { type: "toolCall", tool: "bash", args: { command: "false" } },
            { type: "toolResult", toolName: "bash", output: "failed", isError: true },
            { type: "system", text: "Model: test-model" },
          ];
          const include = url.searchParams.get("include")?.split(",") ?? [];
          const trace =
            include.length === 0
              ? fullTrace
              : fullTrace.filter((event) => {
                  if (include.includes("messages") && ["user", "assistant"].includes(event.type)) {
                    return true;
                  }
                  if (include.includes("thinking") && event.type === "thinking") return true;
                  if (
                    include.includes("tools") &&
                    ["toolCall", "toolResult"].includes(event.type)
                  ) {
                    return true;
                  }
                  if (include.includes("system") && event.type === "system") return true;
                  return false;
                });
          json({
            session: { id: "sess-1", workspaceId: "ws-1", status: "stopped" },
            trace,
          });
          return;
        }
        if (method === "POST" && url.pathname === "/sessions/sess-1/command") {
          json({ messages: [{ type: "command_result", success: true }] });
          return;
        }
        if (method === "POST" && url.pathname === "/sessions/sess-1/stop") {
          json({ ok: true, session: { id: "sess-1", status: "stopped" } });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/sessions/sess-1/resume") {
          json({ session: { id: "sess-1", workspaceId: "ws-1", status: "ready" } });
          return;
        }
        if (method === "POST" && url.pathname === "/workspaces/ws-1/sessions/sess-1/fork") {
          json({
            session: { id: "sess-fork", workspaceId: "ws-1", status: "ready", name: body?.name },
          });
          return;
        }
        if (method === "DELETE" && url.pathname === "/workspaces/ws-1/sessions/sess-1") {
          json({ ok: true, deleted: true });
          return;
        }
        if (
          method === "GET" &&
          url.pathname === "/workspaces/ws-1/sessions/sess-1/tool-output/tool-1"
        ) {
          json({ toolCallId: "tool-1", output: "hello" });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions/sess-1/trace-page") {
          json({ entries: [], metrics: {} });
          return;
        }
        if (method === "GET" && url.pathname === "/workspaces/ws-1/sessions/sess-1/trace-outline") {
          json({
            outline: {
              traceVersion: "fixture",
              entries: [
                { id: "u1", kind: "user", summary: "hello" },
                { id: "a1", kind: "assistant", summary: "trace" },
                {
                  id: "tc-1",
                  kind: "tool",
                  tool: "bash",
                  summary: "$ false",
                  isError: true,
                },
                { id: "s1", kind: "system", summary: "Model: test-model" },
              ],
              itemCount: 4,
              sourceCount: 1,
              jsonlBytes: 500,
            },
            metrics: { rawEntryCount: 4 },
          });
          return;
        }
        if (method === "GET" && url.pathname === "/schedules") {
          json({
            schedules: [
              {
                id: "sch-1",
                status: "active",
                name: "Daily",
                action: {
                  type: "new_session",
                  workspaceId: "ws-1",
                  agentId: url.searchParams.get("agentId"),
                },
              },
            ],
          });
          return;
        }
        if (method === "POST" && url.pathname === "/schedules") {
          json({ schedule: { id: "sch-created", status: "active", name: body?.name } });
          return;
        }
        if (method === "PATCH" && url.pathname === "/schedules/sch-1") {
          json({ schedule: { id: "sch-1", status: "active", name: "Updated" } });
          return;
        }

        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: `${method} ${url.pathname} not handled` }));
      })().catch((error: unknown) => {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
      });
    });
    await listenOnLocalApiFixture(api, cliDir);
    const definitionPath = join(cliDir, "schedule.json");
    const workspaceDefinitionPath = join(cliDir, "workspace.json");
    const workspaceUpdatePath = join(cliDir, "workspace-update.json");
    const removedWorkspaceDefaultCreatePath = join(cliDir, "workspace-default-create.json");
    const removedWorkspaceDefaultUpdatePath = join(cliDir, "workspace-default-update.json");
    const agentDefinitionPath = join(cliDir, "agent.json");
    const agentUpdatePath = join(cliDir, "agent-update.json");
    writeFileSync(definitionPath, JSON.stringify({ name: "Updated" }));
    writeFileSync(workspaceDefinitionPath, JSON.stringify({ description: "Created from JSON" }));
    writeFileSync(workspaceUpdatePath, JSON.stringify({ description: "Updated from JSON" }));
    writeFileSync(
      removedWorkspaceDefaultCreatePath,
      JSON.stringify({ name: "Rejected", defaultModel: "openai/gpt-5.4" }),
    );
    writeFileSync(
      removedWorkspaceDefaultUpdatePath,
      JSON.stringify({ defaultModel: "openai/gpt-5.4" }),
    );
    writeFileSync(
      agentDefinitionPath,
      JSON.stringify({ description: "Reviews diffs", sessionDefaults: { model: "agent-model" } }),
    );
    writeFileSync(agentUpdatePath, JSON.stringify({ description: "Reviews risky diffs" }));

    try {
      expect(run(["init", "--yes", "--data-dir", cliDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);

      const cases: Array<{ args: string[]; expected: string[]; exact?: boolean }> = [
        { args: ["workspace", "list", "--json"], expected: ["GET /workspaces"] },
        { args: ["workspace", "get", "ws-1", "--json"], expected: ["GET /workspaces/ws-1"] },
        {
          args: [
            "workspace",
            "create",
            "--name",
            "Created",
            "--host-mount",
            "/tmp/created",
            "--definition",
            workspaceDefinitionPath,
            "--json",
          ],
          expected: ["POST /workspaces"],
        },
        {
          args: [
            "workspace",
            "update",
            "ws-1",
            "--name",
            "Updated Oppi",
            "--definition",
            workspaceUpdatePath,
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "PUT /workspaces/ws-1"],
        },
        {
          args: ["workspace", "delete", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1", "DELETE /workspaces/ws-1"],
        },
        {
          args: ["worktree", "list", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees"],
        },
        {
          args: ["worktree", "get", "main", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees"],
        },
        {
          args: [
            "worktree",
            "create",
            "--workspace",
            "ws-1",
            "--branch",
            "feature/cli",
            "--base",
            "main",
            "--json",
          ],
          expected: ["POST /workspaces/ws-1/worktrees"],
        },
        {
          args: ["worktree", "open", "--workspace", "ws-1", "--branch", "feature/cli", "--json"],
          expected: ["POST /workspaces/ws-1/worktrees/open"],
        },
        {
          args: ["worktree", "status", "wt_feature-cli-12345678", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/worktrees/wt_feature-cli-12345678/status"],
        },
        {
          args: [
            "worktree",
            "preview",
            "wt_feature-cli-12345678",
            "--workspace",
            "ws-1",
            "--into",
            "main",
            "--mode",
            "ff-only",
            "--json",
          ],
          expected: ["POST /workspaces/ws-1/worktrees/wt_feature-cli-12345678/preview"],
        },
        {
          args: [
            "worktree",
            "remove",
            "wt_feature-cli-12345678",
            "--workspace",
            "ws-1",
            "--force",
            "--json",
          ],
          expected: ["DELETE /workspaces/ws-1/worktrees/wt_feature-cli-12345678?force=true"],
        },
        { args: ["agent", "list", "--json"], expected: ["GET /agents"] },
        { args: ["agent", "get", "agent-1", "--json"], expected: ["GET /agents/agent-1"] },
        {
          args: [
            "agent",
            "create",
            "--name",
            "Reviewer",
            "--definition",
            agentDefinitionPath,
            "--json",
          ],
          expected: ["POST /agents"],
        },
        {
          args: ["agent", "update", "agent-1", "--definition", agentUpdatePath, "--json"],
          expected: ["PATCH /agents/agent-1"],
        },
        {
          args: [
            "agent",
            "create",
            "--definition-json",
            '{"name":"Inline Reviewer","description":"Inline create"}',
            "--json",
          ],
          expected: ["POST /agents"],
        },
        {
          args: [
            "agent",
            "update",
            "agent-1",
            "--definition-json",
            '{"description":"Inline update"}',
            "--json",
          ],
          expected: ["PATCH /agents/agent-1"],
        },
        { args: ["agent", "archive", "agent-1", "--json"], expected: ["DELETE /agents/agent-1"] },
        {
          args: ["session", "list", "--json"],
          expected: ["GET /sessions/recent?recentDays=3"],
        },
        {
          args: ["session", "list", "--workspace", "ws-1", "--json"],
          expected: ["GET /workspaces/ws-1/sessions?status=active%2Cstopped&sinceMs=*"],
        },
        {
          args: ["session", "get", "sess-1", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "GET /sessions/sess-1"],
        },
        {
          args: [
            "session",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "hello from model fuzz",
            "--model",
            "sonet",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "GET /models", "POST /workspaces/ws-1/sessions"],
        },
        {
          args: [
            "session",
            "start",
            "--workspace",
            "ws-1",
            "--prompt",
            "hello from start alias",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /workspaces/ws-1/sessions"],
        },
        {
          args: ["session", "read", "sess-1", "--tail", "1", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "GET /sessions/sess-1/trace?tail=1"],
        },
        {
          args: ["session", "events", "sess-1", "--since", "4", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "GET /sessions/sess-1/events?since=4"],
        },
        {
          args: ["session", "trace", "sess-1", "--include", "summary,tools", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1/trace?include=summary%2Ctools",
          ],
        },
        {
          args: ["session", "send", "sess-1", "--text", "hello", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "POST /sessions/sess-1/command"],
        },
        {
          args: ["session", "stop", "sess-1", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "POST /sessions/sess-1/stop"],
        },
        {
          args: [
            "session",
            "search",
            "test output",
            "--all",
            "--limit",
            "5",
            "--since",
            "2026-01-01",
            "--until",
            "2026-01-31",
            "--json",
          ],
          expected: [
            "GET /sessions/search?q=test+output&limit=5&since=2026-01-01&until=2026-01-31",
          ],
        },
        {
          args: ["session", "search", "--all", "--since", "2026-01-01", "--limit", "5", "--json"],
          expected: ["GET /sessions/search?limit=5&since=2026-01-01"],
        },
        {
          args: ["session", "inspect", "sess-1", "--turns", "all", "--view", "messages", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "GET /sessions/sess-1/trace"],
        },
        {
          args: ["session", "inspect", "sess-1", "--turn", "1", "--view", "messages", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "GET /sessions/sess-1/trace"],
        },
        {
          args: ["session", "inspect", "sess-1", "--view", "response", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1/trace?include=messages",
          ],
          exact: true,
        },
        {
          args: ["session", "inspect", "sess-1", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/trace-outline",
          ],
          exact: true,
        },
        {
          args: ["session", "inspect", "sess-1", "--view", "summary", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/trace-outline",
          ],
          exact: true,
        },
        {
          args: ["session", "resume", "sess-1", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "POST /workspaces/ws-1/sessions/sess-1/resume",
          ],
        },
        {
          args: ["session", "fork", "sess-1", "--entry", "entry-1", "--name", "Fork", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "POST /workspaces/ws-1/sessions/sess-1/fork",
          ],
        },
        {
          args: ["session", "delete", "sess-1", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "DELETE /workspaces/ws-1/sessions/sess-1",
          ],
        },
        {
          args: ["session", "tool-output", "sess-1", "tool-1", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/tool-output/tool-1",
          ],
        },
        {
          args: ["session", "trace-page", "sess-1", "--target-events", "80", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/trace-page?targetEvents=80",
          ],
        },
        {
          args: ["session", "trace-outline", "sess-1", "--json"],
          expected: [
            "GET /sessions?idPrefix=sess-1",
            "GET /sessions/sess-1",
            "GET /workspaces/ws-1/sessions/sess-1/trace-outline",
          ],
        },
        {
          args: [
            "session",
            "create",
            "--agent",
            "agent-1",
            "--workspace",
            "ws-1",
            "--prompt",
            "hello from agent",
            "--idempotency-key",
            "agent-cli-1",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /agents/agent-1/sessions"],
        },
        {
          args: [
            "schedule",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "daily check",
            "--cron",
            "0 7 * * *",
            "--tz",
            "America/Los_Angeles",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /schedules"],
        },
        {
          args: [
            "schedule",
            "create",
            "--workspace",
            "ws-1",
            "--agent",
            "agent-1",
            "--prompt",
            "agent daily check",
            "--every",
            "1d",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "POST /schedules"],
        },
        {
          args: [
            "schedule",
            "create",
            "--workspace",
            "ws-1",
            "--prompt",
            "gpt daily check",
            "--every",
            "1d",
            "--model",
            "gpt codex",
            "--json",
          ],
          expected: ["GET /workspaces/ws-1", "GET /models", "POST /schedules"],
        },
        {
          args: ["schedule", "list", "--agent", "agent-1", "--json"],
          expected: ["GET /schedules?agentId=agent-1"],
        },
        {
          args: ["schedule", "update", "sch-1", "--definition", definitionPath, "--json"],
          expected: ["PATCH /schedules/sch-1"],
        },
        {
          args: [
            "schedule",
            "update",
            "sch-1",
            "--definition-json",
            '{"name":"Inline schedule"}',
            "--json",
          ],
          expected: ["PATCH /schedules/sch-1"],
        },
        {
          args: ["schedule", "update", "sch-1", "--model", "gpt codex", "--json"],
          expected: ["GET /models", "PATCH /schedules/sch-1"],
        },
        {
          args: ["schedule", "update", "sch-1", "--clear-model", "--json"],
          expected: ["PATCH /schedules/sch-1"],
        },
        {
          args: ["wait", "session", "sess-1", "--status", "stopped", "--json"],
          expected: ["GET /sessions?idPrefix=sess-1", "GET /sessions/sess-1"],
        },
      ];

      for (const testCase of cases) {
        const before = requests.length;
        const { stdout, exitCode } = await runAsync(testCase.args, { OPPI_DATA_DIR: cliDir });
        expect(exitCode, testCase.args.join(" ")).toBe(0);
        expect(stdout, testCase.args.join(" ")).not.toBe("");
        expect(JSON.parse(stdout), testCase.args.join(" ")).toMatchObject({ ok: true });
        const seen = requests.slice(before).map((request) => `${request.method} ${request.path}`);
        for (const expected of testCase.expected) {
          if (expected.endsWith("*")) {
            expect(
              seen.some((request) => request.startsWith(expected.slice(0, -1))),
              testCase.args.join(" "),
            ).toBe(true);
          } else {
            expect(seen, testCase.args.join(" ")).toContain(expected);
          }
        }
        if (testCase.exact) {
          expect(seen, testCase.args.join(" ")).toEqual(testCase.expected);
        }
      }

      const beforeBadModel = requests.length;
      const badModel = await runAsync(
        [
          "session",
          "create",
          "--workspace",
          "ws-1",
          "--prompt",
          "hello",
          "--model",
          "not-a-model",
          "--json",
        ],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(badModel.exitCode).toBe(1);
      expect(JSON.parse(badModel.stdout)).toEqual({
        ok: false,
        error: {
          message:
            'Model "not-a-model" is not available. Available models: openrouter/anthropic/claude-sonnet-4-20250514, anthropic/claude-sonnet-4-20250514, openai/gpt-5.3-codex',
          available_models: [
            "openrouter/anthropic/claude-sonnet-4-20250514",
            "anthropic/claude-sonnet-4-20250514",
            "openai/gpt-5.3-codex",
          ],
        },
      });
      const badModelSeen = requests
        .slice(beforeBadModel)
        .map((request) => `${request.method} ${request.path}`);
      expect(badModelSeen).toEqual(["GET /workspaces/ws-1", "GET /models"]);

      const beforeInferredSearch = requests.length;
      const inferredSearch = await runAsync(
        ["session", "search", "test output", "--limit", "5", "--json"],
        { OPPI_DATA_DIR: cliDir },
        15_000,
        workspaceRoot,
      );
      expect(inferredSearch.exitCode).toBe(0);
      expect(JSON.parse(inferredSearch.stdout)).toMatchObject({ ok: true });
      const inferredSeen = requests
        .slice(beforeInferredSearch)
        .map((request) => `${request.method} ${request.path}`);
      expect(inferredSeen).toContain("GET /workspaces");
      expect(inferredSeen).toContain("GET /sessions/search?q=test+output&limit=5&workspaceId=ws-1");

      const beforeWorktreeInferredSearch = requests.length;
      const worktreeInferredSearch = await runAsync(
        ["session", "search", "test output", "--limit", "5", "--json"],
        { OPPI_DATA_DIR: cliDir },
        15_000,
        worktreeRoot,
      );
      expect(worktreeInferredSearch.exitCode).toBe(0);
      expect(JSON.parse(worktreeInferredSearch.stdout)).toMatchObject({ ok: true });
      const worktreeInferredSeen = requests
        .slice(beforeWorktreeInferredSearch)
        .map((request) => `${request.method} ${request.path}`);
      expect(worktreeInferredSeen).toContain("GET /workspaces/ws-1/worktrees");
      expect(worktreeInferredSeen).toContain(
        "GET /sessions/search?q=test+output&limit=5&workspaceId=ws-1",
      );

      const unscopedSearch = await runAsync(["session", "search", "test output", "--json"], {
        OPPI_DATA_DIR: cliDir,
      });
      expect(unscopedSearch.exitCode).toBe(1);
      expect(JSON.parse(unscopedSearch.stdout)).toMatchObject({
        ok: false,
        error: { message: "Could not infer workspace from cwd; pass --workspace or --all" },
      });

      const responseJson = await runAsync(
        ["session", "inspect", "sess-1", "--view", "response", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(responseJson.exitCode).toBe(0);
      expect(JSON.parse(responseJson.stdout)).toMatchObject({
        ok: true,
        data: {
          selected_turns: [1],
          view: "response",
          text: "trace",
        },
      });

      const responseHuman = await runAsync(["session", "inspect", "sess-1", "--view", "response"], {
        OPPI_DATA_DIR: cliDir,
      });
      expect(responseHuman.exitCode).toBe(0);
      expect(responseHuman.stdout.trim()).toBe("trace");

      const trailingResponse = await runAsync(
        ["session", "inspect", "sess-trailing-user", "--view", "response", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(trailingResponse.exitCode).toBe(0);
      expect(JSON.parse(trailingResponse.stdout)).toMatchObject({
        ok: true,
        data: {
          selected_turns: [1, 2],
          view: "response",
          text: "completed response",
        },
      });

      const inspectJson = await runAsync(
        ["session", "inspect", "sess-1", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(inspectJson.exitCode).toBe(0);
      const inspectEnvelope = JSON.parse(inspectJson.stdout) as {
        data?: {
          summary?: { counts?: { toolCalls?: number; toolErrors?: number } };
          text?: string;
        };
      };
      expect(inspectEnvelope.data?.summary?.counts?.toolCalls).toBe(1);
      expect(inspectEnvelope.data?.summary?.counts?.toolErrors).toBe(1);
      expect(inspectEnvelope.data?.text).toContain("assistant: trace");
      expect(inspectEnvelope.data?.text).not.toContain("failed");

      const inspectOutlineJson = await runAsync(
        ["session", "inspect", "sess-1", "--view", "outline", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(inspectOutlineJson.exitCode).toBe(0);
      const inspectOutlineEnvelope = JSON.parse(inspectOutlineJson.stdout) as {
        data?: { selected_turns?: number[]; text?: string };
      };
      expect(inspectOutlineEnvelope.data?.selected_turns).toEqual([1]);
      expect(inspectOutlineEnvelope.data?.text).toContain("Turn 1");
      expect(inspectOutlineEnvelope.data?.text).toContain("user: hello");
      expect(inspectOutlineEnvelope.data?.text).toContain("assistant: trace");
      expect(inspectOutlineEnvelope.data?.text).toContain("activity: 1 tool call · 1 error");
      expect(inspectOutlineEnvelope.data?.text).not.toContain("failed");

      const leadingInspectJson = await runAsync(
        ["session", "inspect", "sess-leading", "--turns", "1", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(leadingInspectJson.exitCode, leadingInspectJson.stdout).toBe(0);
      const leadingInspectEnvelope = JSON.parse(leadingInspectJson.stdout) as {
        data?: {
          selected_turns?: number[];
          summary?: { counts?: { turns?: number } };
          text?: string;
        };
      };
      expect(leadingInspectEnvelope.data?.selected_turns).toEqual([1]);
      expect(leadingInspectEnvelope.data?.summary?.counts?.turns).toBe(1);
      expect(leadingInspectEnvelope.data?.text).toContain("summary: summary before prompt");
      expect(leadingInspectEnvelope.data?.text).toContain("system: Model: test-model");
      expect(leadingInspectEnvelope.data?.text).toContain("user: first prompt");

      const dataUrlInspectJson = await runAsync(
        ["session", "inspect", "sess-data-url", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(dataUrlInspectJson.exitCode).toBe(0);
      const dataUrlInspectEnvelope = JSON.parse(dataUrlInspectJson.stdout) as {
        data?: { text?: string };
      };
      expect(dataUrlInspectEnvelope.data?.text).toContain("[inline image/png data omitted]");
      expect(dataUrlInspectEnvelope.data?.text).not.toContain("QUJDREVGRw==");

      for (const turns of ["1abc", "1-2x", "0", "2", "1-2", "2-1", "1,,1"]) {
        const invalidInspectTurns = await runAsync(
          ["session", "inspect", "sess-1", "--turns", turns, "--json"],
          { OPPI_DATA_DIR: cliDir },
        );
        expect(invalidInspectTurns.exitCode, turns).toBe(1);
        expect(JSON.parse(invalidInspectTurns.stdout), turns).toMatchObject({
          ok: false,
          error: {
            message: "--turns must be all, last, a number, a range, or a comma-separated list",
          },
        });
      }

      const malformedInspect = await runAsync(
        ["session", "inspect", "sess-malformed", "--view", "messages", "--json"],
        { OPPI_DATA_DIR: cliDir },
      );
      expect(malformedInspect.exitCode).toBe(1);
      expect(JSON.parse(malformedInspect.stdout)).toMatchObject({
        ok: false,
        error: { message: "Local API did not return a trace array" },
      });

      const workspaceHuman = await runAsync(["workspace", "list"], { OPPI_DATA_DIR: cliDir });
      expect(workspaceHuman.exitCode).toBe(0);
      expect(workspaceHuman.stdout).toContain("Workspaces (1)");
      expect(workspaceHuman.stdout).toContain("ws-1");
      expect(workspaceHuman.stdout).toContain("Oppi");
      expect(workspaceHuman.stdout).not.toContain("| ID");
      expect(workspaceHuman.stdout).not.toMatch(/\x1b\[[0-9;]*m/);

      const sessionsHuman = await runAsync(["session", "list", "--workspace", "ws-1"], {
        OPPI_DATA_DIR: cliDir,
      });
      expect(sessionsHuman.exitCode).toBe(0);
      expect(sessionsHuman.stdout).toContain("Sessions (2)");
      expect(sessionsHuman.stdout).toContain("Terminal Demo");
      expect(sessionsHuman.stdout).not.toContain("source tui");
      expect(sessionsHuman.stdout).not.toContain("source oppi");
      expect(sessionsHuman.stdout).not.toContain("| ID");
      expect(sessionsHuman.stdout).not.toMatch(/\x1b\[[0-9;]*m/);

      const workspaceCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/workspaces",
      );
      expect(workspaceCreateRequest?.body).toMatchObject({
        name: "Created",
        description: "Created from JSON",
        hostMount: "/tmp/created",
      });
      expect(workspaceCreateRequest?.body).not.toHaveProperty("defaultModel");
      const workspaceUpdateRequest = requests.find(
        (request) => request.method === "PUT" && request.path === "/workspaces/ws-1",
      );
      expect(workspaceUpdateRequest?.body).toMatchObject({
        name: "Updated Oppi",
        description: "Updated from JSON",
      });
      expect(workspaceUpdateRequest?.body).not.toHaveProperty("defaultModel");
      const sessionCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/workspaces/ws-1/sessions",
      );
      expect(sessionCreateRequest?.body).toMatchObject({
        prompt: "hello from model fuzz",
        model: "anthropic/claude-sonnet-4-20250514",
      });
      const forkRequest = requests.find(
        (request) =>
          request.method === "POST" && request.path === "/workspaces/ws-1/sessions/sess-1/fork",
      );
      expect(forkRequest?.body).toEqual({ entryId: "entry-1", name: "Fork" });
      const worktreeCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/workspaces/ws-1/worktrees",
      );
      expect(worktreeCreateRequest?.body).toEqual({ branch: "feature/cli", base: "main" });
      const worktreeOpenRequest = requests.find(
        (request) =>
          request.method === "POST" && request.path === "/workspaces/ws-1/worktrees/open",
      );
      expect(worktreeOpenRequest?.body).toEqual({ branch: "feature/cli" });
      const worktreePreviewRequest = requests.find(
        (request) =>
          request.method === "POST" &&
          request.path === "/workspaces/ws-1/worktrees/wt_feature-cli-12345678/preview",
      );
      expect(worktreePreviewRequest?.body).toEqual({ into: "main", mode: "ff-only" });

      const agentCreateRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/agents",
      );
      expect(agentCreateRequest?.body).toMatchObject({
        name: "Reviewer",
        description: "Reviews diffs",
        sessionDefaults: { model: "agent-model" },
      });
      expect(
        requests.find(
          (request) =>
            request.method === "POST" &&
            request.path === "/agents" &&
            (request.body as { name?: string }).name === "Inline Reviewer",
        )?.body,
      ).toEqual({ name: "Inline Reviewer", description: "Inline create" });
      expect(
        requests.find(
          (request) =>
            request.method === "PATCH" &&
            request.path === "/agents/agent-1" &&
            (request.body as { description?: string }).description === "Inline update",
        )?.body,
      ).toEqual({ description: "Inline update" });
      const agentSessionRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/agents/agent-1/sessions",
      );
      expect(agentSessionRequest?.body).toMatchObject({
        prompt: { text: "hello from agent" },
        target: { workspaceId: "ws-1" },
        idempotencyKey: "agent-cli-1",
      });
      const sendRequest = requests.find(
        (request) => request.method === "POST" && request.path === "/sessions/sess-1/command",
      );
      expect(sendRequest?.body).toMatchObject({ type: "prompt", message: "hello" });
      const scheduleCreateRequests = requests.filter(
        (request) => request.method === "POST" && request.path === "/schedules",
      );
      expect(scheduleCreateRequests[0]?.body).toMatchObject({
        name: expect.any(String),
        trigger: { type: "cron", expression: "0 7 * * *", timeZone: "America/Los_Angeles" },
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "daily check",
        },
      });
      expect(scheduleCreateRequests[1]?.body).toMatchObject({
        trigger: { type: "every", intervalMs: 86_400_000 },
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          agentId: "agent-1",
          prompt: "agent daily check",
        },
      });
      expect(scheduleCreateRequests[2]?.body).toMatchObject({
        trigger: { type: "every", intervalMs: 86_400_000 },
        action: {
          type: "new_session",
          workspaceId: "ws-1",
          prompt: "gpt daily check",
          model: "openai/gpt-5.3-codex",
        },
      });
      const updateRequest = requests.find(
        (request) => request.method === "PATCH" && request.path === "/schedules/sch-1",
      );
      expect(updateRequest?.body).toEqual({ name: "Updated" });
      expect(
        requests.find(
          (request) =>
            request.method === "PATCH" &&
            request.path === "/schedules/sch-1" &&
            (request.body as { name?: string }).name === "Inline schedule",
        )?.body,
      ).toEqual({ name: "Inline schedule" });
      expect(
        requests.find(
          (request) =>
            request.method === "PATCH" &&
            request.path === "/schedules/sch-1" &&
            (request.body as { action?: { model?: string } }).action?.model ===
              "openai/gpt-5.3-codex",
        )?.body,
      ).toEqual({ action: { model: "openai/gpt-5.3-codex" } });
      expect(
        requests.find(
          (request) =>
            request.method === "PATCH" &&
            request.path === "/schedules/sch-1" &&
            (request.body as { action?: { model?: null } }).action?.model === null,
        )?.body,
      ).toEqual({ action: { model: null } });

      for (const args of [
        [
          "workspace",
          "create",
          "--name",
          "Rejected",
          "--default-model",
          "openai/gpt-5.4",
          "--json",
        ],
        ["workspace", "update", "ws-1", "--default-model", "openai/gpt-5.4", "--json"],
        ["workspace", "create", "--definition", removedWorkspaceDefaultCreatePath, "--json"],
        [
          "workspace",
          "update",
          "ws-1",
          "--definition",
          removedWorkspaceDefaultUpdatePath,
          "--json",
        ],
      ]) {
        const before = requests.length;
        const result = await runAsync(args, { OPPI_DATA_DIR: cliDir });
        expect(result.exitCode, args.join(" ")).toBe(1);
        expect(JSON.parse(result.stdout)).toEqual({
          ok: false,
          error: {
            message:
              "Workspace default models are no longer supported; remove --default-model/defaultModel and configure Pi's defaultProvider and defaultModel in ~/.pi/agent/settings.json.",
          },
        });
        expect(requests, args.join(" ")).toHaveLength(before);
      }

      for (const testCase of [
        {
          args: [
            "agent",
            "update",
            "agent-1",
            "--definition",
            agentUpdatePath,
            "--definition-json",
            '{"description":"duplicate"}',
            "--json",
          ],
          message: "exactly one of --definition or --definition-json is required",
        },
        {
          args: ["agent", "update", "agent-1", "--definition-json", "not-json", "--json"],
          message: "--definition-json must be valid JSON",
        },
        {
          args: ["agent", "update", "agent-1", "--definition-json", "[]", "--json"],
          message: "definition must be a JSON object",
        },
        {
          args: ["schedule", "update", "sch-1", "--definition-json", "{}", "--json"],
          message: "definition update must not be empty",
        },
        {
          args: ["schedule", "update", "sch-1", "--model", "  ", "--json"],
          message: "--model requires a non-empty value",
        },
        {
          args: [
            "schedule",
            "update",
            "sch-1",
            "--definition-json",
            JSON.stringify({ name: "x".repeat(65_536) }),
            "--json",
          ],
          message: "--definition-json exceeds maximum size of 65536 bytes",
        },
      ]) {
        const before = requests.length;
        const result = await runAsync(testCase.args, { OPPI_DATA_DIR: cliDir });
        expect(result.exitCode, testCase.args.slice(0, 3).join(" ")).toBe(1);
        expect(JSON.parse(result.stdout).error.message).toContain(testCase.message);
        expect(requests).toHaveLength(before);
      }
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
      rmSync(workspaceRoot, { recursive: true, force: true });
      rmSync(worktreeRoot, { recursive: true, force: true });
    }
  }, 180_000);

  it("keeps concurrent read-only local API CLI calls from failing on SQLite locks", async () => {
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-concurrent-read-"));
    const api = createHttpServer((req, res) => {
      if (req.method === "GET" && req.url === "/workspaces") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ workspaces: [], summaries: [], serverNow: 1 }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: `${req.method ?? "GET"} ${req.url ?? "/"} not handled` }));
    });
    await listenOnLocalApiFixture(api, cliDir);

    try {
      expect(run(["init", "--yes", "--data-dir", cliDir]).exitCode).toBe(0);
      expect(
        run(["config", "set", "tls", '{"mode":"disabled"}'], { OPPI_DATA_DIR: cliDir }).exitCode,
      ).toBe(0);

      const results = await Promise.all(
        Array.from({ length: 10 }, () =>
          runAsync(["workspace", "list", "--json"], { OPPI_DATA_DIR: cliDir }),
        ),
      );
      const failures = results
        .map((result, index) => ({ index, ...result }))
        .filter((result) => result.exitCode !== 0);

      expect(failures).toEqual([]);
      for (const result of results) {
        expect(JSON.parse(result.stdout)).toMatchObject({ ok: true });
      }
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("schedule list --json fails fast on malformed successful API JSON", async () => {
    const cliDir = mkdtempSync(join(tmpdir(), "oppi-cli-local-api-"));
    const api = createHttpServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("not-json");
    });
    await listenOnLocalApiFixture(api, cliDir);

    try {
      seedConfiguredHost(cliDir);

      const { stdout, exitCode } = await runAsync(["schedule", "list", "--json"], {
        OPPI_DATA_DIR: cliDir,
      });

      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout)).toEqual({
        ok: false,
        error: { message: "Invalid JSON response from local API" },
      });
    } finally {
      await new Promise<void>((resolveClose, rejectClose) =>
        api.close((error) => (error ? rejectClose(error) : resolveClose())),
      );
      rmSync(cliDir, { recursive: true, force: true });
    }
  });
});

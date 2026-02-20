/**
 * Server integration tests — real HTTP server on a random port.
 *
 * Starts a real Server with a temp data dir, makes actual HTTP requests,
 * and tests auth, REST endpoints, and WebSocket connections.
 *
 * Does NOT spawn pi or containers — just the HTTP/WS layer.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { WebSocket } from "ws";

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let token: string;

function get(path: string, auth = true): Promise<Response> {
  const headers: Record<string, string> = {};
  if (auth) headers["Authorization"] = `Bearer ${token}`;
  return fetch(`${baseUrl}${path}`, { headers });
}

function post(path: string, body: unknown, auth = true): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (auth) headers["Authorization"] = `Bearer ${token}`;
  return fetch(`${baseUrl}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function put(path: string, body: unknown, auth = true): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (auth) headers["Authorization"] = `Bearer ${token}`;
  return fetch(`${baseUrl}${path}`, {
    method: "PUT",
    headers,
    body: JSON.stringify(body),
  });
}

function patch(path: string, body: unknown, auth = true): Promise<Response> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (auth) headers["Authorization"] = `Bearer ${token}`;
  return fetch(`${baseUrl}${path}`, {
    method: "PATCH",
    headers,
    body: JSON.stringify(body),
  });
}

function del(path: string, auth = true): Promise<Response> {
  const headers: Record<string, string> = {};
  if (auth) headers["Authorization"] = `Bearer ${token}`;
  return fetch(`${baseUrl}${path}`, { method: "DELETE", headers });
}

function connectGate(port: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ port, host: "127.0.0.1" }, () => resolve(socket));
    socket.on("error", reject);
  });
}

function sendGateMessage(
  socket: Socket,
  msg: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    const rl = createInterface({ input: socket });
    rl.once("line", (line) => {
      rl.close();
      resolve(JSON.parse(line));
    });
    socket.write(JSON.stringify(msg) + "\n");
  });
}

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-server-integration-"));
  storage = new Storage(dataDir);
  const port = 17750 + Math.floor(Math.random() * 1000);
  const proxyPort = 17850 + Math.floor(Math.random() * 1000);
  storage.updateConfig({ port, host: "127.0.0.1" });
  token = storage.ensurePaired();
  process.env.OPPI_AUTH_PROXY_PORT = String(proxyPort);
  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${port}`;
}, 15_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  // Small delay to let sockets drain before rmSync
  await new Promise((r) => setTimeout(r, 100));
  rmSync(dataDir, { recursive: true, force: true });
}, 10_000);

// ── Health ──

describe("health", () => {
  it("GET /health returns ok (no auth required)", async () => {
    const res = await get("/health", false);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(body.protocol).toBeTypeOf("number");
  });
});

// ── Auth ──

describe("auth", () => {
  it("rejects requests without auth header", async () => {
    const res = await get("/me", false);
    expect(res.status).toBe(401);
  });

  it("rejects requests with wrong token", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: "Bearer sk_wrong_token_123" },
    });
    expect(res.status).toBe(401);
  });

  it("accepts requests with correct token", async () => {
    const res = await get("/me");
    expect(res.status).toBe(200);
  });
});

// ── GET /me ──

describe("GET /me", () => {
  it("returns owner info", async () => {
    const res = await get("/me");
    const body = await res.json();
    expect(body.name).toBeTypeOf("string");
  });
});

// ── GET /server/info ──

describe("GET /server/info", () => {
  it("returns version, uptime, and capabilities", async () => {
    const res = await get("/server/info");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.version).toMatch(/^\d+\.\d+\.\d+$/);
    expect(body.uptime).toBeTypeOf("number");
    expect(body.os).toBeTypeOf("string");
  });
});

// ── Models ──

describe("GET /models", () => {
  it("returns model list", async () => {
    const res = await get("/models");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.models).toBeInstanceOf(Array);
  });
});

// ── Skills ──

describe("skills API", () => {
  it("GET /skills returns skill list", async () => {
    const res = await get("/skills");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.skills).toBeInstanceOf(Array);
  });
});

// ── Workspaces ──

describe("workspaces API", () => {
  it("GET /workspaces returns list", async () => {
    const res = await get("/workspaces");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspaces).toBeInstanceOf(Array);
  });

  it("POST /workspaces creates a workspace", async () => {
    const res = await post("/workspaces", { name: "test-ws", skills: [] });
    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.workspace.id).toBeTypeOf("string");
    expect(body.workspace.name).toBe("test-ws");
  });

  it("GET /workspaces/:id returns workspace detail", async () => {
    const createRes = await post("/workspaces", { name: "detail-test", skills: [] });
    const { workspace } = await createRes.json();

    const res = await get(`/workspaces/${workspace.id}`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspace.name).toBe("detail-test");
  });

  it("PUT /workspaces/:id updates workspace", async () => {
    const createRes = await post("/workspaces", { name: "before", skills: [] });
    const { workspace } = await createRes.json();

    const res = await put(`/workspaces/${workspace.id}`, { name: "after" });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspace.name).toBe("after");
  });

  it("DELETE /workspaces/:id removes workspace", async () => {
    const createRes = await post("/workspaces", { name: "delete-me", skills: [] });
    const { workspace } = await createRes.json();

    const delRes = await del(`/workspaces/${workspace.id}`);
    expect(delRes.status).toBe(200);

    const getRes = await get(`/workspaces/${workspace.id}`);
    expect(getRes.status).toBe(404);
  });

  it("GET /workspaces/:id/sessions returns sessions for workspace", async () => {
    const createRes = await post("/workspaces", { name: "sessions-test", skills: [] });
    const { workspace } = await createRes.json();

    const res = await get(`/workspaces/${workspace.id}/sessions`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.sessions).toBeInstanceOf(Array);
    expect(body.sessions.length).toBe(0);
  });
});

// ── Sessions (workspace-scoped) ──

describe("sessions API", () => {
  it("POST /workspaces/:id/sessions creates a session", async () => {
    const wsRes = await post("/workspaces", { name: "session-ws", skills: [] });
    const { workspace } = await wsRes.json();

    const res = await post(`/workspaces/${workspace.id}/sessions`, {
      prompt: "say hello",
      model: "anthropic/claude-sonnet-4-20250514",
    });
    // Session creation may fail (no pi executable in test) but should not 404
    expect(res.status).not.toBe(404);
  });
});

// ── WebSocket ──

describe("WebSocket", () => {
  it("rejects unauthenticated WS upgrade", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/stream`);
    const closed = await new Promise<boolean>((resolve) => {
      ws.on("error", () => resolve(true));
      ws.on("close", () => resolve(true));
      ws.on("open", () => {
        ws.close();
        resolve(false);
      });
    });
    expect(closed).toBe(true);
  });

  it("rejects WS upgrade to unknown path", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/nonexistent`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const closed = await new Promise<boolean>((resolve) => {
      ws.on("error", () => resolve(true));
      ws.on("close", () => resolve(true));
      ws.on("open", () => {
        ws.close();
        resolve(false);
      });
    });
    expect(closed).toBe(true);
  });

  it("accepts authenticated WS to /stream and receives stream_connected", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/stream`, {
      headers: { Authorization: `Bearer ${token}` },
    });

    const msg = await new Promise<Record<string, unknown> | null>((resolve) => {
      ws.on("message", (data) => {
        resolve(JSON.parse(data.toString()));
      });
      ws.on("error", () => resolve(null));
      setTimeout(() => resolve(null), 3000);
    });

    expect(msg).not.toBeNull();
    expect(msg!.type).toBe("stream_connected");
    expect(msg!.userName).toBeTypeOf("string");
    ws.close();
  });
});

// ── Policy ──

describe("policy API", () => {
  it("GET /policy/rules returns rules list", async () => {
    const res = await get("/policy/rules");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rules).toBeInstanceOf(Array);
  });

  it("PATCH /policy/rules/:id returns 404 for missing rule", async () => {
    const res = await fetch(`${baseUrl}/policy/rules/does-not-exist`, {
      method: "PATCH",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ description: "Updated" }),
    });

    expect(res.status).toBe(404);
    const body = await res.json();
    expect(body.error).toBe("Rule not found");
  });

  it("PATCH workspace fallback hot-reloads active gate session behavior", async () => {
    const wsRes = await post("/workspaces", { name: "policy-hot-reload", skills: [] });
    expect(wsRes.status).toBe(201);
    const wsBody = await wsRes.json();
    const workspace = wsBody.workspace as { id: string };

    const session = storage.createSession("policy-hot-reload-session");
    session.workspaceId = workspace.id;
    storage.saveSession(session);

    const internals = server as unknown as {
      gate: {
        createSessionSocket: (sessionId: string, workspaceId?: string) => Promise<number>;
        setSessionPolicy: (sessionId: string, policy: unknown) => void;
        resolveDecision: (
          requestId: string,
          action: "allow" | "deny",
          scope?: "once" | "session" | "workspace" | "global",
          expiresInMs?: number,
        ) => boolean;
        destroySessionSocket: (sessionId: string) => void;
        on: (event: "approval_needed", listener: (pending: { id: string; reason: string }) => void) => void;
        off: (event: "approval_needed", listener: (pending: { id: string; reason: string }) => void) => void;
      };
      sessions: {
        isActive: (sessionId: string) => boolean;
      };
    };

    const gate = internals.gate;
    const sessionsManager = internals.sessions;
    const originalIsActive = sessionsManager.isActive.bind(sessionsManager);
    sessionsManager.isActive = (sessionId: string) =>
      sessionId === session.id || originalIsActive(sessionId);

    const gatePort = await gate.createSessionSocket(session.id, workspace.id);
    const gateSocket = await connectGate(gatePort);

    let approvals = 0;
    const approvalListener = (pending: { id: string }) => {
      approvals += 1;
      setTimeout(() => {
        gate.resolveDecision(pending.id, "allow");
      }, 10);
    };

    try {
      const ack = await sendGateMessage(gateSocket, {
        type: "guard_ready",
        sessionId: session.id,
        extensionVersion: "1.0.0",
      });
      expect(ack.type).toBe("guard_ack");

      gate.on("approval_needed", approvalListener);

      const askRes = await patch(`/workspaces/${workspace.id}/policy`, { fallback: "ask" });
      expect(askRes.status).toBe(200);

      const firstDecision = await sendGateMessage(gateSocket, {
        type: "gate_check",
        tool: "edit",
        input: {
          path: "server/tests/legacy-stream-compat.test.ts",
          oldText: "placeholder-old",
          newText: "placeholder-new",
        },
        toolCallId: "tc-hot-reload-1",
      });
      expect(firstDecision.action).toBe("allow");
      expect(approvals).toBe(1);

      const allowRes = await patch(`/workspaces/${workspace.id}/policy`, { fallback: "allow" });
      expect(allowRes.status).toBe(200);

      const secondDecision = await sendGateMessage(gateSocket, {
        type: "gate_check",
        tool: "edit",
        input: {
          path: "server/tests/legacy-stream-compat.test.ts",
          oldText: "placeholder-old",
          newText: "placeholder-new",
        },
        toolCallId: "tc-hot-reload-2",
      });
      expect(secondDecision.action).toBe("allow");
      // Slim policy defaults unmatched requests to ask regardless of fallback.
      expect(approvals).toBe(2);
    } finally {
      gate.off("approval_needed", approvalListener);
      if (!gateSocket.destroyed) {
        gateSocket.destroy();
      }
      gate.destroySessionSocket(session.id);
      sessionsManager.isActive = originalIsActive;
    }
  });

  // ── Rules CRUD ──

  it("GET /policy/rules includes seeded preset rules", async () => {
    const res = await get("/policy/rules");
    expect(res.status).toBe(200);
    const body = await res.json();
    const presets = body.rules.filter((r: { source: string }) => r.source === "preset");
    expect(presets.length).toBeGreaterThan(0);
  });

  it("GET /policy/rules filters by scope", async () => {
    const res = await get("/policy/rules?scope=global");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rules.every((r: { scope: string }) => r.scope === "global")).toBe(true);
  });

  it("GET /policy/rules rejects invalid scope", async () => {
    const res = await get("/policy/rules?scope=invalid");
    expect(res.status).toBe(400);
  });

  it("GET /policy/rules filters by workspaceId", async () => {
    // Create a workspace so it has workspace-scoped rules
    const wsRes = await post("/workspaces", { name: "rules-filter-ws", skills: [] });
    expect(wsRes.status).toBe(201);
    const wsBody = await wsRes.json();
    const workspaceId = wsBody.workspace.id;

    const res = await get(`/policy/rules?workspaceId=${workspaceId}`);
    expect(res.status).toBe(200);
    const body = await res.json();
    // Should include globals + workspace-scoped rules for this workspace
    for (const rule of body.rules) {
      expect(["global", "workspace"].includes(rule.scope)).toBe(true);
      if (rule.scope === "workspace") {
        expect(rule.workspaceId).toBe(workspaceId);
      }
    }
  });

  it("GET /policy/rules rejects non-existent workspaceId", async () => {
    const res = await get("/policy/rules?workspaceId=NONEXISTENT");
    expect(res.status).toBe(404);
  });

  it("PATCH /policy/rules/:id updates decision and label", async () => {
    // Find a preset rule to update
    const listRes = await get("/policy/rules?scope=global");
    const listBody = await listRes.json();
    const target = listBody.rules.find((r: { source: string; decision: string }) =>
      r.source === "preset" && r.decision === "ask",
    );
    expect(target).toBeTruthy();

    const res = await patch(`/policy/rules/${target.id}`, {
      decision: "deny",
      label: "patched-label",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rule.decision).toBe("deny");
    expect(body.rule.label).toBe("patched-label");

    // Restore original
    await patch(`/policy/rules/${target.id}`, {
      decision: target.decision,
      label: target.label,
    });
  });

  it("PATCH /policy/rules/:id supports legacy effect/description fields", async () => {
    const listRes = await get("/policy/rules?scope=global");
    const listBody = await listRes.json();
    const target = listBody.rules[0];

    const originalLabel = target.label;
    const res = await patch(`/policy/rules/${target.id}`, {
      effect: "ask",
      description: "legacy-desc",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rule.decision).toBe("ask");
    expect(body.rule.label).toBe("legacy-desc");

    // Restore
    await patch(`/policy/rules/${target.id}`, {
      decision: target.decision,
      label: originalLabel,
    });
  });

  it("PATCH /policy/rules/:id validates decision values", async () => {
    const listRes = await get("/policy/rules?scope=global");
    const listBody = await listRes.json();
    const ruleId = listBody.rules[0].id;

    const res = await patch(`/policy/rules/${ruleId}`, { decision: "yolo" });
    expect(res.status).toBe(400);
  });

  it("PATCH /policy/rules/:id requires at least one patch field", async () => {
    const listRes = await get("/policy/rules?scope=global");
    const listBody = await listRes.json();
    const ruleId = listBody.rules[0].id;

    const res = await patch(`/policy/rules/${ruleId}`, {});
    expect(res.status).toBe(400);
  });

  it("PATCH /policy/rules/:id updates pattern and executable", async () => {
    const listRes = await get("/policy/rules?scope=global");
    const listBody = await listRes.json();
    const target = listBody.rules.find((r: { tool: string }) => r.tool === "bash");
    expect(target).toBeTruthy();

    const res = await patch(`/policy/rules/${target.id}`, {
      pattern: "npm run build*",
      executable: "npm",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rule.pattern).toBe("npm run build*");
    expect(body.rule.executable).toBe("npm");

    // Restore
    await patch(`/policy/rules/${target.id}`, {
      pattern: target.pattern || null,
      executable: target.executable || null,
    });
  });

  it("PATCH /policy/rules/:id clears fields with null", async () => {
    // Create a dedicated rule so we don't disturb shared presets
    const internals = server as unknown as {
      gate: { ruleStore: { add: (input: unknown) => { id: string } } };
    };
    const rule = internals.gate.ruleStore.add({
      tool: "bash",
      decision: "ask",
      executable: "make",
      pattern: "make deploy*",
      label: "Clear test rule",
      scope: "global",
      source: "manual",
    });

    const res = await patch(`/policy/rules/${rule.id}`, {
      executable: null,
      label: null,
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rule.executable).toBeUndefined();
    expect(body.rule.label).toBeUndefined();
    // Pattern should be preserved
    expect(body.rule.pattern).toBe("make deploy*");

    // Clean up
    await del(`/policy/rules/${rule.id}`);
  });

  it("DELETE /policy/rules/:id removes a rule", async () => {
    // Add a throwaway rule via the store directly, then delete via API
    const internals = server as unknown as {
      gate: { ruleStore: { add: (input: unknown) => { id: string } } };
    };
    const rule = internals.gate.ruleStore.add({
      tool: "bash",
      decision: "ask",
      pattern: "throwaway-delete-test*",
      label: "Delete me",
      scope: "global",
      source: "manual",
    });

    const res = await del(`/policy/rules/${rule.id}`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(body.deleted).toBe(rule.id);

    // Verify it's gone
    const listRes = await get("/policy/rules");
    const listBody = await listRes.json();
    expect(listBody.rules.find((r: { id: string }) => r.id === rule.id)).toBeUndefined();
  });

  it("DELETE /policy/rules/:id returns 404 for missing rule", async () => {
    const res = await del("/policy/rules/does-not-exist");
    expect(res.status).toBe(404);
  });

  it("GET /policy/audit returns audit entries", async () => {
    const res = await get("/policy/audit");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.entries).toBeInstanceOf(Array);
  });
});

// ── Permissions ──

describe("permissions API", () => {
  it("GET /permissions/pending returns pending list", async () => {
    const res = await get("/permissions/pending");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.pending).toBeInstanceOf(Array);
  });
});

// ── Extensions ──

describe("extensions API", () => {
  it("GET /extensions returns extension list", async () => {
    const res = await get("/extensions");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.extensions).toBeInstanceOf(Array);
  });
});

// ── Host directories ──

describe("host directories API", () => {
  it("GET /host/directories returns directory list", async () => {
    const res = await get("/host/directories");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.directories).toBeInstanceOf(Array);
  });
});

// ── Themes ──

describe("themes API", () => {
  const validTheme = {
    theme: {
      colors: {
        // Base (13)
        bg: "#1a1b26", bgDark: "#16161e", bgHighlight: "#292e42",
        fg: "#c0caf5", fgDim: "#a9b1d6", comment: "#565f89",
        blue: "#7aa2f7", cyan: "#7dcfff", green: "#9ece6a",
        orange: "#ff9e64", purple: "#bb9af7", red: "#f7768e",
        yellow: "#e0af68", thinkingText: "#a9b1d6",
        // User message (2)
        userMessageBg: "#292e42", userMessageText: "#c0caf5",
        // Tool state (5)
        toolPendingBg: "#1e2a4a", toolSuccessBg: "#1e2e1e", toolErrorBg: "#2e1e1e",
        toolTitle: "#c0caf5", toolOutput: "#a9b1d6",
        // Markdown (10)
        mdHeading: "#ffaa00", mdLink: "#0000ff", mdLinkUrl: "#666666",
        mdCode: "#00ffff", mdCodeBlock: "#00ff00", mdCodeBlockBorder: "#808080",
        mdQuote: "#808080", mdQuoteBorder: "#808080", mdHr: "#808080",
        mdListBullet: "#00ffff",
        // Diffs (3)
        toolDiffAdded: "#00ff00", toolDiffRemoved: "#ff0000", toolDiffContext: "#808080",
        // Syntax (9)
        syntaxComment: "#6A9955", syntaxKeyword: "#569CD6", syntaxFunction: "#DCDCAA",
        syntaxVariable: "#9CDCFE", syntaxString: "#CE9178", syntaxNumber: "#B5CEA8",
        syntaxType: "#4EC9B0", syntaxOperator: "#D4D4D4", syntaxPunctuation: "#D4D4D4",
        // Thinking (6)
        thinkingOff: "#505050", thinkingMinimal: "#6e6e6e", thinkingLow: "#5f87af",
        thinkingMedium: "#81a2be", thinkingHigh: "#b294bb", thinkingXhigh: "#d183e8",
      },
    },
  };

  it("GET /themes returns theme list", async () => {
    const res = await get("/themes");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.themes).toBeInstanceOf(Array);
  });

  it("GET /themes/:name returns 404 for nonexistent theme", async () => {
    const res = await get("/themes/nonexistent-theme");
    expect(res.status).toBe(404);
  });

  it("PUT /themes/:name creates a theme and GET returns it", async () => {
    const putRes = await put("/themes/test-dark", validTheme);
    expect([200, 201]).toContain(putRes.status);

    const getRes = await get("/themes/test-dark");
    expect(getRes.status).toBe(200);
    const body = await getRes.json();
    expect(body.theme).toBeDefined();
  });

  it("PUT /themes/:name rejects invalid theme", async () => {
    const res = await put("/themes/bad", { theme: { colors: { bg: "not-hex" } } });
    expect(res.status).toBe(400);
  });

  it("DELETE /themes/:name removes theme", async () => {
    await put("/themes/delete-me", validTheme);
    const delRes = await del("/themes/delete-me");
    expect(delRes.status).toBe(200);

    const getRes = await get("/themes/delete-me");
    expect(getRes.status).toBe(404);
  });
});

// ── User skills ──

describe("user skills API", () => {
  it("GET /me/skills returns skill list", async () => {
    const res = await get("/me/skills");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.skills).toBeInstanceOf(Array);
  });

  it("POST /me/skills is disabled", async () => {
    const res = await post("/me/skills", {
      name: "new-skill",
      sessionId: "session-123",
    });
    expect(res.status).toBe(403);
    await expect(res.json()).resolves.toEqual({
      error: "Skill editing is disabled on remote clients",
    });
  });

  it("PUT /me/skills/:name is disabled", async () => {
    const res = await put("/me/skills/search", {
      content: '---\nname: search\ndescription: "Updated"\n---\n# Updated',
    });
    expect(res.status).toBe(403);
    await expect(res.json()).resolves.toEqual({
      error: "Skill editing is disabled on remote clients",
    });
  });

  it("DELETE /me/skills/:name is disabled", async () => {
    const res = await del("/me/skills/search");
    expect(res.status).toBe(403);
    await expect(res.json()).resolves.toEqual({
      error: "Skill editing is disabled on remote clients",
    });
  });
});

// ── Device token ──

describe("device token API", () => {
  it("POST /me/device-token registers token", async () => {
    const res = await post("/me/device-token", {
      deviceToken: "fake-apns-token-abc123",
    });
    expect(res.status).toBe(200);
  });

  it("POST /me/device-token rejects missing token", async () => {
    const res = await post("/me/device-token", {});
    expect(res.status).toBe(400);
  });

  it("DELETE /me/device-token removes token", async () => {
    // Register first so there's something to delete
    await post("/me/device-token", { deviceToken: "to-delete" });
    const res = await del("/me/device-token");
    expect(res.status).toBe(200);
  });
});

// ── Workspace policy ──

describe("workspace policy", () => {
  it("GET /workspaces/:id/policy returns merged policy object", async () => {
    const createRes = await post("/workspaces", { name: "policy-check", skills: [] });
    expect(createRes.status).toBe(201);
    const { workspace } = await createRes.json();

    const res = await get(`/workspaces/${workspace.id}/policy`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspaceId).toBe(workspace.id);
    expect(body.effectivePolicy).toBeTypeOf("object");
    expect(Array.isArray(body.effectivePolicy.permissions)).toBe(true);
  });
});

// ── Workspace lifecycle (full CRUD flow) ──

describe("workspace lifecycle", () => {
  it("full CRUD: create → update → list → get → delete → 404", async () => {
    // Create
    const createRes = await post("/workspaces", { name: "lifecycle", skills: [] });
    expect(createRes.status).toBe(201);
    const { workspace } = await createRes.json();
    const id = workspace.id;

    // Update
    const updateRes = await put(`/workspaces/${id}`, { name: "lifecycle-updated" });
    expect(updateRes.status).toBe(200);

    // List contains it
    const listRes = await get("/workspaces");
    const { workspaces } = await listRes.json();
    expect(workspaces.some((w: { id: string }) => w.id === id)).toBe(true);

    // Get by ID
    const getRes = await get(`/workspaces/${id}`);
    const getBody = await getRes.json();
    expect(getBody.workspace.name).toBe("lifecycle-updated");

    // Delete
    const delRes = await del(`/workspaces/${id}`);
    expect(delRes.status).toBe(200);

    // 404 after delete
    const afterRes = await get(`/workspaces/${id}`);
    expect(afterRes.status).toBe(404);
  });

  it("still allows skill enable/disable through workspace updates", async () => {
    const skillsRes = await get("/skills");
    expect(skillsRes.status).toBe(200);
    const skillsBody = await skillsRes.json();
    const skillName = skillsBody.skills?.[0]?.name as string | undefined;
    expect(skillName).toBeTruthy();

    const createRes = await post("/workspaces", {
      name: "skill-toggle-workspace",
      skills: skillName ? [skillName] : [],
    });
    expect(createRes.status).toBe(201);
    const { workspace } = await createRes.json();

    const disableRes = await put(`/workspaces/${workspace.id}`, { skills: [] });
    expect(disableRes.status).toBe(200);
    const disableBody = await disableRes.json();
    expect(disableBody.workspace.skills).toEqual([]);

    const enableRes = await put(`/workspaces/${workspace.id}`, {
      skills: skillName ? [skillName] : [],
    });
    expect(enableRes.status).toBe(200);
    const enableBody = await enableRes.json();
    expect(enableBody.workspace.skills).toEqual(skillName ? [skillName] : []);
  });
});

// ── Per-session WebSocket ──

describe("per-session WebSocket", () => {
  it("connects to /workspaces/:wid/sessions/:sid/stream and receives connected", async () => {
    // Create workspace + session
    const wsRes = await post("/workspaces", { name: "ws-stream", skills: [] });
    const { workspace } = await wsRes.json();
    const sessRes = await post(`/workspaces/${workspace.id}/sessions`, {
      model: "anthropic/claude-sonnet-4-20250514",
    });
    const { session } = await sessRes.json();

    const ws = new WebSocket(
      `${baseUrl.replace("http", "ws")}/workspaces/${workspace.id}/sessions/${session.id}/stream`,
      { headers: { Authorization: `Bearer ${token}` } },
    );

    const msg = await new Promise<Record<string, unknown> | null>((resolve) => {
      ws.on("message", (data) => {
        resolve(JSON.parse(data.toString()));
      });
      ws.on("error", () => resolve(null));
      setTimeout(() => resolve(null), 3000);
    });

    expect(msg).not.toBeNull();
    expect(msg!.type).toBe("connected");
    expect(msg!.session).toBeDefined();
    expect((msg!.session as Record<string, unknown>).id).toBe(session.id);

    // Wait for close to complete to avoid EPIPE on teardown
    await new Promise<void>((resolve) => {
      ws.on("close", () => resolve());
      ws.close();
    });
  });

  it("rejects WS to nonexistent session", async () => {
    const wsRes = await post("/workspaces", { name: "ws-404", skills: [] });
    const { workspace } = await wsRes.json();

    const ws = new WebSocket(
      `${baseUrl.replace("http", "ws")}/workspaces/${workspace.id}/sessions/NONEXISTENT/stream`,
      { headers: { Authorization: `Bearer ${token}` } },
    );

    const closed = await new Promise<boolean>((resolve) => {
      ws.on("error", () => resolve(true));
      ws.on("close", () => resolve(true));
      ws.on("open", () => {
        ws.close();
        resolve(false);
      });
    });
    expect(closed).toBe(true);
  });

  it("rejects WS with mismatched workspace/session", async () => {
    // Create session in one workspace, try to connect via another
    const ws1Res = await post("/workspaces", { name: "ws-a", skills: [] });
    const { workspace: ws1 } = await ws1Res.json();
    const ws2Res = await post("/workspaces", { name: "ws-b", skills: [] });
    const { workspace: ws2 } = await ws2Res.json();

    const sessRes = await post(`/workspaces/${ws1.id}/sessions`, {
      model: "anthropic/claude-sonnet-4-20250514",
    });
    const { session } = await sessRes.json();

    const ws = new WebSocket(
      `${baseUrl.replace("http", "ws")}/workspaces/${ws2.id}/sessions/${session.id}/stream`,
      { headers: { Authorization: `Bearer ${token}` } },
    );

    const closed = await new Promise<boolean>((resolve) => {
      ws.on("error", () => resolve(true));
      ws.on("close", () => resolve(true));
      ws.on("open", () => {
        ws.close();
        resolve(false);
      });
    });
    expect(closed).toBe(true);
  });
});

// ── Error handling ──

describe("error handling", () => {
  it("returns 404 for unknown routes", async () => {
    const res = await get("/nonexistent/route");
    expect(res.status).toBe(404);
  });

  it("returns 404 for top-level /sessions (must be workspace-scoped)", async () => {
    const res = await get("/sessions");
    expect(res.status).toBe(404);
  });

  it("returns 404 for nonexistent workspace", async () => {
    const res = await get("/workspaces/NONEXISTENT");
    expect(res.status).toBe(404);
  });

  it("returns 404 for nonexistent session in workspace", async () => {
    const wsRes = await post("/workspaces", { name: "err-test", skills: [] });
    const { workspace } = await wsRes.json();
    const res = await get(`/workspaces/${workspace.id}/sessions/NONEXISTENT`);
    expect(res.status).toBe(404);
  });
});

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
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { WebSocket } from "ws";

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let token: string;

const authDeviceToken = "dt_test_auth_device_token";
const pushOnlyToken = "apns_test_push_only_token";

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

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-server-integration-"));
  storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    authDeviceTokens: [authDeviceToken],
    pushDeviceTokens: [pushOnlyToken],
  });
  token = storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${server.port}`;
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

  it("workspace fallback policy endpoint is not exposed", async () => {
    const wsRes = await post("/workspaces", { name: "policy-endpoint-check", skills: [] });
    expect(wsRes.status).toBe(201);
    const wsBody = await wsRes.json();
    const workspace = wsBody.workspace as { id: string };

    const patchRes = await patch(`/workspaces/${workspace.id}/policy`, { fallback: "allow" });
    expect(patchRes.status).toBe(404);

    const getRes = await get(`/workspaces/${workspace.id}/policy`);
    expect(getRes.status).toBe(404);
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
    const gate = (server as unknown as { gate: { ruleStore: import("../src/rules.js").RuleStore } }).gate;
    const rule = gate.ruleStore.add({
      tool: "bash", decision: "ask", executable: "make", pattern: "make test*",
      label: "original-label", scope: "global", source: "manual",
    });

    const res = await patch(`/policy/rules/${rule.id}`, {
      decision: "deny",
      label: "patched-label",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rule.decision).toBe("deny");
    expect(body.rule.label).toBe("patched-label");
    expect(body.rule.pattern).toBe("make test*");

    await del(`/policy/rules/${rule.id}`);
  });

  it("PATCH /policy/rules/:id validates decision values", async () => {
    const gate = (server as unknown as { gate: { ruleStore: import("../src/rules.js").RuleStore } }).gate;
    const rule = gate.ruleStore.add({
      tool: "bash", decision: "ask", label: "validate-test", scope: "global", source: "manual",
    });

    const res = await patch(`/policy/rules/${rule.id}`, { decision: "yolo" });
    expect(res.status).toBe(400);

    await del(`/policy/rules/${rule.id}`);
  });

  it("PATCH /policy/rules/:id requires at least one patch field", async () => {
    const gate = (server as unknown as { gate: { ruleStore: import("../src/rules.js").RuleStore } }).gate;
    const rule = gate.ruleStore.add({
      tool: "bash", decision: "ask", label: "empty-patch", scope: "global", source: "manual",
    });

    const res = await patch(`/policy/rules/${rule.id}`, {});
    expect(res.status).toBe(400);

    await del(`/policy/rules/${rule.id}`);
  });

  it("PATCH /policy/rules/:id updates pattern and executable", async () => {
    const gate = (server as unknown as { gate: { ruleStore: import("../src/rules.js").RuleStore } }).gate;
    const rule = gate.ruleStore.add({
      tool: "bash", decision: "ask", executable: "git", pattern: "git tag*",
      label: "pattern-test", scope: "global", source: "manual",
    });

    const res = await patch(`/policy/rules/${rule.id}`, {
      pattern: "npm run build*",
      executable: "npm",
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.rule.pattern).toBe("npm run build*");
    expect(body.rule.executable).toBe("npm");

    await del(`/policy/rules/${rule.id}`);
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

// ── Workspace policy routes ──

describe("workspace policy routes", () => {
  it("GET /workspaces/:id/policy returns 404", async () => {
    const createRes = await post("/workspaces", { name: "policy-check", skills: [] });
    expect(createRes.status).toBe(201);
    const { workspace } = await createRes.json();

    const res = await get(`/workspaces/${workspace.id}/policy`);
    expect(res.status).toBe(404);
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

// ── Per-session WebSocket (removed — use /stream) ──

describe("per-session WebSocket", () => {
  it("returns 404 (endpoint removed, use /stream instead)", async () => {
    const wsRes = await post("/workspaces", { name: "ws-gone", skills: [] });
    const { workspace } = await wsRes.json();
    const sessRes = await post(`/workspaces/${workspace.id}/sessions`, {
      model: "anthropic/claude-sonnet-4-20250514",
    });
    const { session } = await sessRes.json();

    const ws = new WebSocket(
      `${baseUrl.replace("http", "ws")}/workspaces/${workspace.id}/sessions/${session.id}/stream`,
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

// ── Auth Token Separation ──

describe("auth token separation", () => {
  it("accepts pair-issued auth device token", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${authDeviceToken}` },
    });
    expect(res.status).toBe(200);
  });

  it("rejects push-only device token for API auth", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${pushOnlyToken}` },
    });
    expect(res.status).toBe(401);
  });
});

// ── Pairing Token Flow ──

type PairingTestContext = {
  storage: Storage;
  baseUrl: string;
};

async function withIsolatedPairingServer(run: (ctx: PairingTestContext) => Promise<void>): Promise<void> {
  const pairingDataDir = mkdtempSync(join(tmpdir(), "oppi-pairing-integration-"));
  const pairingStorage = new Storage(pairingDataDir);
  pairingStorage.updateConfig({
    port: 0,
    host: "127.0.0.1",
  });
  pairingStorage.ensurePaired();

  const pairingServer = new Server(pairingStorage);
  await pairingServer.start();

  try {
    await run({
      storage: pairingStorage,
      baseUrl: `http://127.0.0.1:${pairingServer.port}`,
    });
  } finally {
    await pairingServer.stop().catch(() => {});
    await new Promise((r) => setTimeout(r, 100));
    rmSync(pairingDataDir, { recursive: true, force: true });
  }
}

describe("pairing token flow", () => {
  it("issues dt token and rejects replay", async () => {
    await withIsolatedPairingServer(async ({ storage: pairingStorage, baseUrl: pairingBaseUrl }) => {
      const pt = pairingStorage.issuePairingToken(90_000);

      const first = await fetch(`${pairingBaseUrl}/pair`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pairingToken: pt, deviceName: "test-iphone" }),
      });
      expect(first.status).toBe(200);
      const firstBody = (await first.json()) as { deviceToken: string };
      expect(firstBody.deviceToken.startsWith("dt_")).toBe(true);

      // Issued token works for auth
      const auth = await fetch(`${pairingBaseUrl}/me`, {
        headers: { Authorization: `Bearer ${firstBody.deviceToken}` },
      });
      expect(auth.status).toBe(200);

      // Replay rejected
      const replay = await fetch(`${pairingBaseUrl}/pair`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pairingToken: pt, deviceName: "test-iphone" }),
      });
      expect(replay.status).toBe(401);
    });
  }, 30_000);

  it("rejects expired pairing token", async () => {
    await withIsolatedPairingServer(async ({ storage: pairingStorage, baseUrl: pairingBaseUrl }) => {
      const pt = pairingStorage.issuePairingToken(1_000);
      await new Promise((r) => setTimeout(r, 1_100));

      const res = await fetch(`${pairingBaseUrl}/pair`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pairingToken: pt }),
      });
      expect(res.status).toBe(401);
    });
  });

  it("rejects missing pairingToken", async () => {
    await withIsolatedPairingServer(async ({ baseUrl: pairingBaseUrl }) => {
      const res = await fetch(`${pairingBaseUrl}/pair`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      expect(res.status).toBe(400);
    });
  });

  it("rate limits repeated invalid pairing attempts", async () => {
    await withIsolatedPairingServer(async ({ baseUrl: pairingBaseUrl }) => {
      let sawRateLimit = false;
      for (let i = 0; i < 8; i++) {
        const res = await fetch(`${pairingBaseUrl}/pair`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ pairingToken: `pt_invalid_${i}` }),
        });
        if (res.status === 429) {
          sawRateLimit = true;
          break;
        }
        expect(res.status).toBe(401);
      }
      expect(sawRateLimit).toBe(true);
    });
  });
});

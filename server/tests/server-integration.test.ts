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

function del(path: string, auth = true): Promise<Response> {
  const headers: Record<string, string> = {};
  if (auth) headers["Authorization"] = `Bearer ${token}`;
  return fetch(`${baseUrl}${path}`, { method: "DELETE", headers });
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

// ── Security profile ──

describe("security profile API", () => {
  it("GET /security/profile returns current profile", async () => {
    const res = await get("/security/profile");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.profile).toBeTypeOf("string");
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
        bg: "#000000", bgDark: "#111111", bgHighlight: "#222222",
        fg: "#ffffff", fgDim: "#cccccc", comment: "#888888",
        blue: "#0000ff", cyan: "#00ffff", green: "#00ff00",
        orange: "#ff8800", purple: "#8800ff", red: "#ff0000",
        yellow: "#ffff00",
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

// ── Security profile ──

describe("security profile mutation", () => {
  it("PUT /security/profile updates profile", async () => {
    const res = await put("/security/profile", { profile: "tailscale-permissive" });
    expect(res.status).toBe(200);
  });

  it("PUT /security/profile rejects invalid profile", async () => {
    const res = await put("/security/profile", { profile: "nonexistent-profile" });
    expect(res.status).toBe(400);
  });

  it("GET /policy/profile returns policy profile object", async () => {
    const res = await get("/policy/profile");
    expect(res.status).toBe(200);
    const body = await res.json();
    // profile is an object with runtime, preset, rules, etc.
    expect(body.profile).toBeTypeOf("object");
    expect(body.profile.runtime).toBeTypeOf("string");
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

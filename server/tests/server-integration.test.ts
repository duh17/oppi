/**
 * Server integration tests — real HTTP server on a random port.
 *
 * Starts a real Server with a temp data dir, makes actual HTTP requests,
 * and tests auth, REST endpoints, and WebSocket connections.
 *
 * Does NOT spawn pi or containers — just the HTTP/WS layer.
 */
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Server } from "../src/server.js";
import { materializeToolMediaContentBlocks } from "../src/session-attachments.js";
import {
  discoverLocalSessions,
  getPiSessionsRoot,
  listCatalogedLocalSessions,
} from "../src/local-sessions.js";
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
    tls: { mode: "disabled" },
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

  it("rejects malformed Authorization header variants", async () => {
    const variants = [
      "Bearer",
      "Bearer    ",
      "Bearer\t",
      "bearer sk_wrong_token_123",
      "Token sk_wrong_token_123",
    ];

    for (const value of variants) {
      const res = await fetch(`${baseUrl}/me`, {
        headers: { Authorization: value },
      });
      expect(res.status).toBe(401);
    }
  });

  it("rejects requests with wrong token", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: "Bearer sk_wrong_token_123" },
    });
    expect(res.status).toBe(401);
  });

  it("recovers from invalid->valid token attempts", async () => {
    const bad = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: "Bearer sk_wrong_token_123" },
    });
    expect(bad.status).toBe(401);

    const good = await get("/me");
    expect(good.status).toBe(200);
  });

  it("invalidates old owner token after rotation", async () => {
    const oldToken = token;
    const rotated = storage.rotateToken();
    token = rotated;

    const oldRes = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${oldToken}` },
    });
    expect(oldRes.status).toBe(401);

    const newRes = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${rotated}` },
    });
    expect(newRes.status).toBe(200);
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
    expect(body.runtimeUpdate).toBeTypeOf("object");
    expect(body.capabilities?.sessionStream?.version).toBe(1);
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
  it("GET /workspaces returns an empty list for a new install", async () => {
    const res = await get("/workspaces");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspaces).toEqual([]);
    expect(body.summaries).toEqual([]);
    expect(body.serverNow).toBeTypeOf("number");
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

  it("PUT /workspaces/:id clears system prompt with null", async () => {
    const createRes = await post("/workspaces", {
      name: "prompt-test",
      skills: [],
      systemPrompt: "Keep it",
      systemPromptMode: "append",
    });
    const { workspace } = await createRes.json();

    const res = await put(`/workspaces/${workspace.id}`, { systemPrompt: null });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspace.systemPrompt).toBeUndefined();
    expect(body.workspace.systemPromptMode).toBe("append");
  });

  it("GET /workspaces/:id/system-prompt/base returns a string payload", async () => {
    const createRes = await post("/workspaces", { name: "base-prompt", skills: [] });
    const { workspace } = await createRes.json();

    const res = await get(`/workspaces/${workspace.id}/system-prompt/base`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(typeof body.systemPrompt).toBe("string");
  });

  it("DELETE /workspaces/:id removes workspace", async () => {
    const createRes = await post("/workspaces", { name: "delete-me", skills: [] });
    const { workspace } = await createRes.json();

    const delRes = await del(`/workspaces/${workspace.id}`);
    expect(delRes.status).toBe(200);

    const getRes = await get(`/workspaces/${workspace.id}`);
    expect(getRes.status).toBe(404);
  });

  it("GET /workspaces/:id/sessions returns sectioned workspace sessions", async () => {
    const createRes = await post("/workspaces", { name: "sessions-test", skills: [] });
    const { workspace } = await createRes.json();

    const res = await get(
      `/workspaces/${workspace.id}/sessions?status=active,stopped&sinceMs=0&untilMs=${Date.now()}`,
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspaceId).toBe(workspace.id);
    expect(body.active).toBeInstanceOf(Array);
    expect(body.stopped).toBeInstanceOf(Array);
    expect(body.active.length).toBe(0);
    expect(body.stopped.length).toBe(0);
  });

  it("GET /workspaces/:id/sessions status=stopped excludes active sessions", async () => {
    const createRes = await post("/workspaces", { name: "stopped-scope-test", skills: [] });
    const { workspace } = await createRes.json();
    const now = Date.now();
    const sinceMs = now - 40 * 86_400_000;
    const untilMs = sinceMs + 86_400_000;

    storage.saveSession({
      id: `${workspace.id}-stopped-in-bucket`,
      workspaceId: workspace.id,
      workspaceName: workspace.name,
      status: "stopped",
      createdAt: sinceMs,
      lastActivity: sinceMs + 1_000,
      messageCount: 1,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    });
    storage.saveSession({
      id: `${workspace.id}-active-outside-bucket`,
      workspaceId: workspace.id,
      workspaceName: workspace.name,
      status: "busy",
      createdAt: now,
      lastActivity: now,
      messageCount: 1,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    });

    const res = await get(
      `/workspaces/${workspace.id}/sessions?status=stopped&sinceMs=${sinceMs}&untilMs=${untilMs}`,
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.stopped.map((session: { id: string }) => session.id)).toEqual([
      `${workspace.id}-stopped-in-bucket`,
    ]);
  });

  it("GET /workspaces/:id/attention returns an authoritative empty snapshot", async () => {
    const createRes = await post("/workspaces", { name: "attention-test", skills: [] });
    const { workspace } = await createRes.json();

    const res = await get(`/workspaces/${workspace.id}/attention`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.workspaceId).toBe(workspace.id);
    expect(body.serverNow).toBeTypeOf("number");
    expect(body.attention).toEqual({ asks: [] });
  });
});

// ── Workspace File Serving ──

describe("workspace file serving", () => {
  let wsId: string;
  let wsRoot: string;

  beforeAll(async () => {
    wsRoot = mkdtempSync(join(tmpdir(), "oppi-ws-files-"));
    mkdirSync(join(wsRoot, "output"), { recursive: true });
    // 1x1 red PNG (minimal valid PNG)
    const pngHeader = Buffer.from([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a, // signature
      0x00,
      0x00,
      0x00,
      0x0d,
      0x49,
      0x48,
      0x44,
      0x52, // IHDR chunk
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01, // 1x1
      0x08,
      0x02,
      0x00,
      0x00,
      0x00,
      0x90,
      0x77,
      0x53,
      0xde, // 8bit RGB + CRC
    ]);
    writeFileSync(join(wsRoot, "chart.png"), pngHeader);
    writeFileSync(join(wsRoot, "output", "figure.jpg"), Buffer.alloc(16, 0xab));
    writeFileSync(join(wsRoot, "secrets.env"), "SECRET=bad");

    const res = await post("/workspaces", {
      name: "file-test",
      skills: [],
      hostMount: wsRoot,
    });
    const body = await res.json();
    wsId = body.workspace.id;
  });

  afterAll(() => {
    rmSync(wsRoot, { recursive: true, force: true });
  });

  it("serves an image file with correct content-type", async () => {
    const res = await get(`/workspaces/${wsId}/raw/chart.png`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
    expect(res.headers.get("cache-control")).toBe("private, no-cache");
    const body = await res.arrayBuffer();
    expect(body.byteLength).toBeGreaterThan(0);
  });

  it("serves files in subdirectories", async () => {
    const res = await get(`/workspaces/${wsId}/raw/output/figure.jpg`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    const body = await res.arrayBuffer();
    expect(body.byteLength).toBe(16);
  });

  it("returns byte-identical content", async () => {
    const res = await get(`/workspaces/${wsId}/raw/output/figure.jpg`);
    const buf = Buffer.from(await res.arrayBuffer());
    expect(buf).toEqual(Buffer.alloc(16, 0xab));
  });

  it("serves non-image file extensions through raw", async () => {
    const res = await get(`/workspaces/${wsId}/raw/secrets.env`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("SECRET=bad");
  });

  it("returns 404 for nonexistent files", async () => {
    const res = await get(`/workspaces/${wsId}/raw/missing.png`);
    expect(res.status).toBe(404);
  });

  it("returns 404 for nonexistent workspace", async () => {
    const res = await get("/workspaces/BOGUS/raw/chart.png");
    expect(res.status).toBe(404);
    const body = await res.json();
    expect(body.error).toContain("not found");
  });

  it("blocks path traversal", async () => {
    const res = await get(`/workspaces/${wsId}/raw/../../../etc/passwd`);
    expect(res.status).toBe(404);
  });

  it("blocks symlinks escaping workspace root", async () => {
    const outsideFile = join(tmpdir(), `oppi-escape-target-${Date.now()}.png`);
    writeFileSync(outsideFile, "escaped");
    symlinkSync(outsideFile, join(wsRoot, "escape.png"));
    try {
      const res = await get(`/workspaces/${wsId}/raw/escape.png`);
      expect(res.status).toBe(404);
    } finally {
      rmSync(outsideFile, { force: true });
    }
  });

  it("rejects requests without auth", async () => {
    const res = await get(`/workspaces/${wsId}/raw/chart.png`, false);
    expect(res.status).toBe(401);
  });

  it("supports query-param token auth only for raw file reads", async () => {
    const legacyBrowse = await fetch(
      `${baseUrl}/workspaces/${wsId}/files/chart.png?mode=browse&token=${token}`,
    );
    expect(legacyBrowse.status).toBe(401);

    const res = await fetch(`${baseUrl}/workspaces/${wsId}/raw/chart.png?token=${token}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
  });
});

// ── Workspace File Browser (raw files, directory listing, search) ──

describe("workspace file browser", () => {
  let wsId: string;
  let wsRoot: string;

  beforeAll(async () => {
    wsRoot = mkdtempSync(join(tmpdir(), "oppi-ws-browser-"));
    mkdirSync(join(wsRoot, "src", "components"), { recursive: true });
    mkdirSync(join(wsRoot, "node_modules", "dep"), { recursive: true });
    mkdirSync(join(wsRoot, ".git", "objects"), { recursive: true });
    writeFileSync(join(wsRoot, "README.md"), "# Hello world");
    writeFileSync(join(wsRoot, "package.json"), '{"name":"test"}');
    writeFileSync(join(wsRoot, ".env"), "SECRET=bad");
    writeFileSync(join(wsRoot, "id_rsa"), "-----BEGIN RSA PRIVATE KEY-----");
    writeFileSync(join(wsRoot, "chart.png"), Buffer.alloc(16, 0xff));
    writeFileSync(join(wsRoot, "src", "index.ts"), "console.log('hi')");
    writeFileSync(
      join(wsRoot, "src", "components", "Button.tsx"),
      "export const Button = () => {}",
    );
    writeFileSync(join(wsRoot, "node_modules", "dep", "index.js"), "module.exports = {}");
    writeFileSync(join(wsRoot, ".git", "HEAD"), "ref: refs/heads/main");

    const res = await post("/workspaces", {
      name: "browser-test",
      skills: [],
      hostMount: wsRoot,
    });
    const body = await res.json();
    wsId = body.workspace.id;
  });

  afterAll(() => {
    rmSync(wsRoot, { recursive: true, force: true });
  });

  // ── Raw files ──

  it("raw route serves text files with correct content-type", async () => {
    const res = await get(`/workspaces/${wsId}/raw/README.md`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(res.headers.get("cache-control")).toBe("private, no-cache");
    const body = await res.text();
    expect(body).toBe("# Hello world");
  });

  it("raw route serves .ts files as text/plain", async () => {
    const res = await get(`/workspaces/${wsId}/raw/src/index.ts`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8");
  });

  it("raw route serves .json with application/json content-type", async () => {
    const res = await get(`/workspaces/${wsId}/raw/package.json`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json; charset=utf-8");
  });

  it("raw route serves images with image content-type", async () => {
    const res = await get(`/workspaces/${wsId}/raw/chart.png`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/png");
  });

  it("raw route blocks .env files", async () => {
    const res = await get(`/workspaces/${wsId}/raw/.env`);
    expect(res.status).toBe(403);
    const body = await res.json();
    expect(body.error).toContain("sensitive");
  });

  it("raw route blocks private keys", async () => {
    const res = await get(`/workspaces/${wsId}/raw/id_rsa`);
    expect(res.status).toBe(403);
  });

  it("raw route blocks .git directory contents", async () => {
    const res = await get(`/workspaces/${wsId}/raw/.git/HEAD`);
    expect(res.status).toBe(403);
  });

  it("raw route returns 404 for nonexistent files", async () => {
    const res = await get(`/workspaces/${wsId}/raw/missing.ts`);
    expect(res.status).toBe(404);
  });

  it("raw route blocks path traversal", async () => {
    const res = await get(`/workspaces/${wsId}/raw/../../../etc/passwd`);
    expect(res.status).toBe(404);
  });

  it("raw route serves workspace file bytes", async () => {
    const res = await get(`/workspaces/${wsId}/raw/README.md`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    await expect(res.text()).resolves.toBe("# Hello world");
  });

  it("raw route blocks sensitive files", async () => {
    const res = await get(`/workspaces/${wsId}/raw/.env`);
    expect(res.status).toBe(403);
  });

  // ── Directory listing ──

  it("lists workspace root directory", async () => {
    const res = await get(`/workspaces/${wsId}/contents`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.path).toBeTruthy();
    expect(body.entries).toBeInstanceOf(Array);
    expect(typeof body.truncated).toBe("boolean");

    const names = body.entries.map((e: { name: string }) => e.name);
    expect(names).toContain("src");
    expect(names).toContain("README.md");
    // IGNORE_DIRS filtered out
    expect(names).not.toContain("node_modules");
    expect(names).not.toContain(".git");
  });

  it("lists subdirectory entries", async () => {
    const res = await get(`/workspaces/${wsId}/contents/src`);
    expect(res.status).toBe(200);
    const body = await res.json();
    const names = body.entries.map((e: { name: string }) => e.name);
    expect(names).toContain("index.ts");
    expect(names).toContain("components");
  });

  it("contents route lists workspace directories", async () => {
    const res = await get(`/workspaces/${wsId}/contents/src`);
    expect(res.status).toBe(200);
    const body = await res.json();
    const names = body.entries.map((e: { name: string }) => e.name);
    expect(names).toContain("index.ts");
    expect(names).toContain("components");
  });

  it("directory entries have correct shape", async () => {
    const res = await get(`/workspaces/${wsId}/contents`);
    const body = await res.json();
    const readme = body.entries.find((e: { name: string }) => e.name === "README.md");
    expect(readme).toBeDefined();
    expect(readme.type).toBe("file");
    expect(readme.size).toBe(13); // "# Hello world"
    expect(readme.modifiedAt).toBeGreaterThan(0);
  });

  it("returns 404 for nonexistent directory", async () => {
    const res = await get(`/workspaces/${wsId}/contents/nonexistent`);
    expect(res.status).toBe(404);
  });

  it("directory listing blocks path traversal", async () => {
    const res = await get(`/workspaces/${wsId}/contents/../`);
    expect(res.status).toBe(404);
  });

  // ── File index ──

  it("paths route returns file index for client-side search", async () => {
    const res = await get(`/workspaces/${wsId}/paths`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.paths).toBeInstanceOf(Array);
    expect(typeof body.truncated).toBe("boolean");
    expect(body.paths).toContain("src/components/Button.tsx");
  });

  it("paths route returns 404 for nonexistent workspace", async () => {
    const res = await get("/workspaces/BOGUS/paths");
    expect(res.status).toBe(404);
  });

  // ── Auth ──

  it("all new endpoints require auth", async () => {
    const endpoints = [
      `/workspaces/${wsId}/contents`,
      `/workspaces/${wsId}/raw/README.md`,
      `/workspaces/${wsId}/paths`,
    ];
    for (const endpoint of endpoints) {
      const res = await get(endpoint, false);
      expect(res.status).toBe(401);
    }
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

  it("DELETE /workspaces/:id/sessions/:sessionId deletes metadata, traces, and attachments", async () => {
    const workspaceRoot = mkdtempSync(join(tmpdir(), "oppi-delete-session-ws-"));
    const piSessionsRoot = getPiSessionsRoot();
    mkdirSync(piSessionsRoot, { recursive: true });
    const piSessionDir = mkdtempSync(join(piSessionsRoot, "oppi-delete-session-e2e-"));
    const sessionId = `delete-e2e-${Date.now()}`;
    const jsonlPath = join(piSessionDir, "session.jsonl");
    const legacyJsonPath = join(dataDir, "sessions", `${sessionId}.json`);
    const workspaceAttachmentDir = join(workspaceRoot, ".pi", "attachments", sessionId, "turn-1");
    const generatedAttachmentDir = join(dataDir, "session-attachments", sessionId);

    try {
      const wsRes = await post("/workspaces", {
        name: "delete-session-ws",
        skills: [],
        hostMount: workspaceRoot,
      });
      expect(wsRes.status).toBe(201);
      const { workspace } = await wsRes.json();

      writeFileSync(
        jsonlPath,
        `${JSON.stringify({ type: "session", id: sessionId, cwd: workspaceRoot, timestamp: "2026-05-03T00:00:00.000Z" })}\n`,
      );
      await discoverLocalSessions(undefined, { dataDir });
      expect(
        listCatalogedLocalSessions(undefined, { dataDir }).sessions.some(
          (session) => session.path === jsonlPath,
        ),
      ).toBe(true);

      mkdirSync(join(dataDir, "sessions"), { recursive: true });
      writeFileSync(legacyJsonPath, JSON.stringify({ session: { id: sessionId } }));
      mkdirSync(workspaceAttachmentDir, { recursive: true });
      writeFileSync(join(workspaceAttachmentDir, "image-1.jpg"), Buffer.from("attached image"));

      const pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAACZFr56AAAADElEQVR42mP8z8AARQAIMQH+6k9QbQAAAABJRU5ErkJggg==";
      const generatedBlocks = materializeToolMediaContentBlocks({
        dataDir,
        sessionId,
        toolCallId: "tool-image",
        contents: [
          { type: "image", data: pngBase64, mimeType: "image/png", fileName: "chart.png" },
        ],
      });
      const generatedBlock = generatedBlocks[0];
      if (
        !generatedBlock ||
        typeof generatedBlock !== "object" ||
        !("id" in generatedBlock) ||
        typeof (generatedBlock as { id?: unknown }).id !== "string"
      ) {
        throw new Error("Expected generated image attachment block with id");
      }
      const generatedAttachmentId = (generatedBlock as { id: string }).id;
      expect(existsSync(generatedAttachmentDir)).toBe(true);

      storage.saveSession({
        id: sessionId,
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        status: "stopped",
        createdAt: Date.now(),
        lastActivity: Date.now(),
        messageCount: 1,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
        piSessionFile: jsonlPath,
        piSessionFiles: [jsonlPath],
      });

      const attachmentBeforeDelete = await get(
        `/workspaces/${workspace.id}/sessions/${sessionId}/attachments/${generatedAttachmentId}`,
      );
      expect(attachmentBeforeDelete.status).toBe(200);

      const deleteRes = await del(`/workspaces/${workspace.id}/sessions/${sessionId}`);
      expect(deleteRes.status).toBe(200);
      const body = await deleteRes.json();
      expect(body.deleted).toEqual({
        sqliteMetadata: true,
        localPiJsonlFiles: 1,
        workspaceAttachmentCopies: true,
        generatedMediaAttachments: true,
      });

      expect(storage.getSession(sessionId)).toBeUndefined();
      expect(existsSync(jsonlPath)).toBe(false);
      expect(existsSync(legacyJsonPath)).toBe(false);
      expect(existsSync(join(workspaceRoot, ".pi", "attachments", sessionId))).toBe(false);
      expect(existsSync(generatedAttachmentDir)).toBe(false);
      expect(
        listCatalogedLocalSessions(undefined, { dataDir }).sessions.some(
          (session) => session.path === jsonlPath,
        ),
      ).toBe(false);

      const sessionListRes = await get(
        `/workspaces/${workspace.id}/sessions?status=stopped&sinceMs=0&untilMs=${Date.now() + 1_000}`,
      );
      expect(sessionListRes.status).toBe(200);
      const sessionList = await sessionListRes.json();
      expect(
        sessionList.stopped.some(
          (session: { source?: string; path?: string }) =>
            session.source === "tui" && session.path === jsonlPath,
        ),
      ).toBe(false);
    } finally {
      rmSync(workspaceRoot, { recursive: true, force: true });
      rmSync(piSessionDir, { recursive: true, force: true });
    }
  });
});

// ── WebSocket ──

function waitForUpgradeRejection(
  ws: WebSocket,
): Promise<{ statusCode: number; headers: Record<string, string | string[] | undefined> }> {
  return new Promise((resolve, reject) => {
    const cleanup = (): void => {
      ws.off("unexpected-response", onUnexpectedResponse);
      ws.off("open", onOpen);
      ws.off("error", onError);
    };

    const onUnexpectedResponse = (
      _request: unknown,
      response: {
        statusCode?: number;
        headers: Record<string, string | string[] | undefined>;
        resume(): void;
      },
    ): void => {
      cleanup();
      response.resume();
      resolve({
        statusCode: response.statusCode ?? 0,
        headers: response.headers,
      });
    };

    const onOpen = (): void => {
      cleanup();
      ws.close();
      reject(new Error("Expected upgrade rejection but connection opened"));
    };

    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };

    ws.once("unexpected-response", onUnexpectedResponse);
    ws.once("open", onOpen);
    ws.once("error", onError);
  });
}

describe("WebSocket", () => {
  it("rejects unauthenticated WS upgrade with Bearer challenge", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/workspaces/test/stream`);
    const rejection = await waitForUpgradeRejection(ws);
    expect(rejection.statusCode).toBe(401);
    expect(rejection.headers["www-authenticate"]).toBe('Bearer realm="oppi"');
  });

  it("rejects WS upgrade with malformed Authorization header", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/workspaces/test/stream`, {
      headers: { Authorization: "bearer malformed" },
    });

    const rejection = await waitForUpgradeRejection(ws);
    expect(rejection.statusCode).toBe(401);
    expect(rejection.headers["www-authenticate"]).toBe('Bearer realm="oppi"');
  });

  it("rejects WS upgrade to unknown path", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/nonexistent`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const rejection = await waitForUpgradeRejection(ws);
    expect(rejection.statusCode).toBe(404);
  });

  it("rejects WS upgrade with mismatched Origin header", async () => {
    const ws = new WebSocket(
      `${baseUrl.replace("http", "ws")}/workspaces/test/sessions/test/stream`,
      {
        headers: {
          Authorization: `Bearer ${token}`,
          Origin: "http://evil.example.com",
        },
      },
    );
    const rejection = await waitForUpgradeRejection(ws);
    expect(rejection.statusCode).toBe(403);
  });

  it("rejects retired workspace WS path", async () => {
    const ws = new WebSocket(`${baseUrl.replace("http", "ws")}/workspaces/test/stream`, {
      headers: {
        Authorization: `Bearer ${token}`,
        Origin: baseUrl,
      },
    });
    const rejection = await waitForUpgradeRejection(ws);
    expect(rejection.statusCode).toBe(404);
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

  it("PUT /themes/:name is not part of the HTTP API", async () => {
    const res = await put("/themes/test-dark", { theme: {} });
    expect(res.status).toBe(404);
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

  it("DELETE /me/device-token is not part of the HTTP API", async () => {
    const res = await del("/me/device-token");
    expect(res.status).toBe(404);
  });
});

// ── Retired workspace routes ──

describe("retired workspace routes", () => {
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

// ── Split session WebSocket ──

describe("split session WebSocket", () => {
  it("opens the URL-bound session stream", async () => {
    const wsRes = await post("/workspaces", { name: "session-stream", skills: [] });
    const { workspace } = await wsRes.json();
    const sessRes = await post(`/workspaces/${workspace.id}/sessions`, {
      model: "anthropic/claude-sonnet-4-20250514",
    });
    const { session } = await sessRes.json();

    const ws = new WebSocket(
      `${baseUrl.replace("http", "ws")}/workspaces/${workspace.id}/sessions/${session.id}/stream`,
      { headers: { Authorization: `Bearer ${token}` } },
    );

    const firstMessage = await new Promise<Record<string, unknown>>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("session stream did not open")), 5000);
      ws.on("error", reject);
      ws.on("message", (data) => {
        clearTimeout(timeout);
        resolve(JSON.parse(data.toString()) as Record<string, unknown>);
      });
    });
    ws.close();

    expect(firstMessage.type).toBe("stream_connected");
  });
});

// ── Error handling ──

describe("error handling", () => {
  it("returns 404 for unknown routes", async () => {
    const res = await get("/nonexistent/route");
    expect(res.status).toBe(404);
  });

  it("returns 404 for removed GET /sessions list route", async () => {
    const res = await get("/sessions");
    expect(res.status).toBe(404);
  });

  it("GET /sessions/search returns empty results for unmatched query", async () => {
    const res = await get("/sessions/search?q=test&limit=10");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.results).toEqual([]);
    expect(body.totalResults).toBe(0);
  });

  it("GET /sessions/search without query returns empty results", async () => {
    const res = await get("/sessions/search");
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.results).toEqual([]);
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

async function withIsolatedPairingServer(
  run: (ctx: PairingTestContext) => Promise<void>,
): Promise<void> {
  const pairingDataDir = mkdtempSync(join(tmpdir(), "oppi-pairing-integration-"));
  const pairingStorage = new Storage(pairingDataDir);
  pairingStorage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "disabled" },
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
    await withIsolatedPairingServer(
      async ({ storage: pairingStorage, baseUrl: pairingBaseUrl }) => {
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

        // Replay rejected (even if caller identity fields differ)
        const replay = await fetch(`${pairingBaseUrl}/pair`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ pairingToken: pt, deviceName: "different-device" }),
        });
        expect(replay.status).toBe(401);
      },
    );
  }, 30_000);

  it("rejects expired pairing token", async () => {
    await withIsolatedPairingServer(
      async ({ storage: pairingStorage, baseUrl: pairingBaseUrl }) => {
        const pt = pairingStorage.issuePairingToken(1_000);
        await new Promise((r) => setTimeout(r, 1_100));

        const res = await fetch(`${pairingBaseUrl}/pair`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ pairingToken: pt }),
        });
        expect(res.status).toBe(401);
      },
    );
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

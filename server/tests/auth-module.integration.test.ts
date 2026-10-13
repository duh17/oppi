import { request as httpRequest } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import { localApiRequest } from "../src/cli/local-api-client.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

let dataDir = "";
let server: Server | undefined;

afterEach(async () => {
  vi.restoreAllMocks();
  await server?.stop().catch(() => {});
  server = undefined;
  if (dataDir) rmSync(dataDir, { recursive: true, force: true });
  dataDir = "";
});

/** Plain loopback listener: still a network listener, so the gate applies. */
async function startWithModule(module: { path?: string; source?: string }): Promise<Storage> {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-auth-module-"));
  const modulePath = module.path ?? join(dataDir, "auth.mjs");
  if (module.source !== undefined) writeFileSync(modulePath, module.source);
  const storage = new Storage(dataDir);
  storage.ensurePaired();
  storage.updateConfig({
    host: "127.0.0.1",
    port: 0,
    tls: { mode: "disabled" },
    auth: { module: modulePath },
  });
  server = new Server(storage);
  await server.start();
  return storage;
}

function networkGet(
  path: string,
  headers: Record<string, string> = {},
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(`http://127.0.0.1:${server!.port}${path}`, { headers }, (res) => {
      let data = "";
      res.on("data", (chunk: Buffer) => (data += chunk.toString("utf8")));
      res.on("end", () =>
        resolve({ status: res.statusCode ?? 0, body: JSON.parse(data || "null") }),
      );
    });
    req.on("error", reject);
    req.end();
  });
}

function upgradeStatus(headers: Record<string, string> = {}): Promise<number> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${server!.port}/app/events/stream`, { headers });
    ws.once("open", () => {
      ws.terminate();
      resolve(101);
    });
    ws.once("unexpected-response", (_request, response) => {
      response.resume();
      resolve(response.statusCode ?? 0);
    });
    ws.once("error", () => resolve(0));
  });
}

describe("auth.module", () => {
  it.each([
    ["a missing file", { path: "/nonexistent/oppi-auth-module.mjs" }],
    ["an import error", { source: "export const gate = ;" }],
    ["no usable export", { source: "export const other = () => ({ allow: true });" }],
    ["a non-function export", { source: "export const gate = { allow: true };" }],
  ])(
    "fails closed on %s: network 503, owner socket still works",
    async (_label, module) => {
      const stderr = vi.spyOn(process.stderr, "write");
      const storage = await startWithModule(module);

      expect(await networkGet("/health")).toEqual({
        status: 503,
        body: { error: "auth_module_unavailable" },
      });
      expect((await networkGet("/pair/approval-status")).status).toBe(503);
      expect(await upgradeStatus()).toBe(503);
      expect(await localApiRequest<{ user: string }>(storage, "/me")).toMatchObject({
        user: "owner",
      });

      const failure = stderr.mock.calls
        .map(([line]) => String(line))
        .find((line) => line.includes('"auth.module_load_failed"'));
      expect(JSON.parse(failure ?? "{}")).toMatchObject({
        level: "error",
        path: expect.any(String),
      });
    },
    30_000,
  );

  it("lets the gate refuse network HTTP and WebSocket requests before device auth", async () => {
    const storage = await startWithModule({
      source: `export async function gate(req) {
        if (req.headers["x-ticket"] === "ok") return { allow: true };
        if (req.transport === "ws") return { allow: false, status: 401 };
        return { allow: false, status: 451, reason: "no ticket for " + req.path };
      }`,
    });

    expect(await networkGet("/health")).toEqual({
      status: 451,
      body: { error: "no ticket for /health" },
    });
    expect(await upgradeStatus()).toBe(401);
    expect(await networkGet("/health", { "x-ticket": "ok" })).toEqual({
      status: 200,
      body: { ok: true, protocol: 2 },
    });
    // Admitted by the gate, the upgrade still needs a device token.
    expect(await upgradeStatus({ "x-ticket": "ok" })).toBe(401);
    expect(await localApiRequest<{ user: string }>(storage, "/me")).toMatchObject({
      user: "owner",
    });
  }, 30_000);

  it("refuses with 403 when the gate throws", async () => {
    await startWithModule({ source: `export function gate() { throw new Error("boom"); }` });
    expect(await networkGet("/health")).toEqual({ status: 403, body: { error: "Forbidden" } });
    expect(await upgradeStatus()).toBe(403);
  }, 30_000);
});

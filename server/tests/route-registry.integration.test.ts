import { request } from "node:http";
import { createConnection } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { WebSocket } from "ws";

import { apiRouteSpecs } from "../src/routes/registry.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

// The registry is what `oppi api` will publish, so its claims must be what the server does.
describe("route registry against the running server", () => {
  let dataDir = "";
  let server: Server;
  let token = "";

  beforeAll(async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-route-registry-"));
    const storage = new Storage(dataDir);
    token = storage.ensurePaired();
    storage.mutateConfig(() => ({ host: "127.0.0.1", port: 0, tls: { mode: "tailscale" } }));
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    server = new Server(storage);
    try {
      await server.start();
    } finally {
      process.env.PATH = originalPath;
    }
  });

  afterAll(async () => {
    await server?.stop().catch(() => {});
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("asks for credentials on exactly the routes registered as owner-only", async () => {
    const mismatches: string[] = [];
    for (const route of apiRouteSpecs) {
      const path = samplePath(route.path);
      const status =
        route.transport === "websocket" ? await upgrade(path) : await send(route.method, path);
      if ((status === 401) !== (route.auth === "owner")) {
        mismatches.push(`${route.method} ${route.path} (auth: ${route.auth}) answered ${status}`);
      }
    }
    expect(mismatches).toEqual([]);
  });

  it("answers 405 with Allow for an unregistered method and 404 for an unregistered path", async () => {
    const owner = { Authorization: `Bearer ${token}` };

    const wrongMethod = await sendFull("PATCH", "/agents", owner);
    expect(wrongMethod.status).toBe(405);
    expect(wrongMethod.allow?.split(", ").sort()).toEqual(["GET", "POST"]);

    expect((await sendFull("GET", "/agents/a/b/c", owner)).status).toBe(404);
  });

  it("lets the enabled UI test harness answer its unregistered /e2e/ui/ fixtures", async () => {
    const previous = process.env.OPPI_E2E_UI_HARNESS;
    process.env.OPPI_E2E_UI_HARNESS = "1";
    try {
      // The harness's own refusal (POST-only fixture), not the registry gate's 404.
      const res = await sendFull("GET", "/e2e/ui/reset-chat-style", {
        Authorization: `Bearer ${token}`,
      });
      expect(res).toEqual({ status: 405 });
    } finally {
      if (previous === undefined) delete process.env.OPPI_E2E_UI_HARNESS;
      else process.env.OPPI_E2E_UI_HARNESS = previous;
    }
  });

  function samplePath(template: string): string {
    return template.replace(/\{[A-Za-z0-9_]+\+?\}/g, "x");
  }

  /** The upgrade's HTTP status without credentials: 101 when it opened. */
  function upgrade(path: string): Promise<number> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://localhost${path}`, {
        createConnection: () => createConnection(server.socketPath),
      });
      ws.once("open", () => {
        ws.close();
        resolve(101);
      });
      ws.once("unexpected-response", (_req, res) => {
        res.resume();
        ws.terminate();
        resolve(res.statusCode ?? 0);
      });
      ws.once("error", reject);
    });
  }

  async function send(method: string, path: string): Promise<number> {
    return (await sendFull(method, path, {})).status;
  }

  function sendFull(
    method: string,
    path: string,
    headers: Record<string, string>,
  ): Promise<{ status: number; allow?: string }> {
    return new Promise((resolve, reject) => {
      const req = request({ socketPath: server.socketPath, method, path, headers }, (res) => {
        res.resume();
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            ...(typeof res.headers.allow === "string" ? { allow: res.headers.allow } : {}),
          }),
        );
      });
      req.on("error", reject);
      req.end();
    });
  }
});

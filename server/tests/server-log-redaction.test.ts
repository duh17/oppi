import { request as httpRequest } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

// Capture the real logger's serialized lines (redaction included) so the test
// sees exactly what would reach stderr.
const { lines } = vi.hoisted(() => ({ lines: [] as string[] }));

vi.mock("../src/logger.js", async (importOriginal) => {
  const original = await importOriginal<typeof import("../src/logger.js")>();
  return {
    ...original,
    createLogger: (options: Parameters<typeof original.createLogger>[0] = {}) =>
      original.createLogger({
        ...options,
        level: "debug",
        sink: (_level, line) => lines.push(line),
      }),
  };
});

// Opaque on purpose: these match none of the logger's secret patterns, so a raw token that
// server.ts logged would survive redaction and fail the assertions below.
const BEARER = "opaque-owner-credential-0123456789";
const DEVICE_BEARER = "opaque-device-credential-0123456789";

let dataDir: string;
let server: Server;
let baseUrl: string;

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-auth-log-"));
  const storage = new Storage(dataDir);
  storage.mutateConfig(() => ({ port: 0, host: "127.0.0.1", tls: { mode: "disabled" } }));
  storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${server.port}`;
}, 30_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 45_000);

beforeEach(() => {
  lines.length = 0;
});

function unauthorizedEntries(): Array<Record<string, unknown>> {
  return lines
    .map((line) => JSON.parse(line) as Record<string, unknown>)
    .filter((entry) => entry["event"] === "auth.unauthorized");
}

function httpStatus(path: string, method: string, authorization: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      `${baseUrl}${path}`,
      { method, headers: { Authorization: authorization } },
      (res) => {
        res.resume();
        res.on("end", () => resolve(res.statusCode ?? 0));
      },
    );
    req.on("error", reject);
    req.end();
  });
}

function upgradeStatus(path: string, authorization: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${baseUrl.replace(/^http:/, "ws:")}${path}`, {
      headers: { Authorization: authorization },
    });
    ws.once("unexpected-response", (_request, response) => {
      response.resume();
      resolve(response.statusCode ?? 0);
    });
    ws.once("open", () => {
      ws.terminate();
      reject(new Error("upgrade unexpectedly succeeded"));
    });
    ws.once("error", () => {});
  });
}

describe("auth log redaction", () => {
  it("logs auth presence for an HTTP 401 without bearer material", async () => {
    await expect(httpStatus("/workspaces/ws1/sessions", "POST", `Bearer ${BEARER}`)).resolves.toBe(
      401,
    );

    const entries = unauthorizedEntries();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      transport: "http",
      method: "POST",
      path: "/workspaces/ws1/sessions",
      authPresent: true,
    });
    const logged = lines.join("\n");
    expect(logged).not.toContain(BEARER);
    expect(logged).not.toContain("Bearer ");
  });

  it("logs auth presence for a websocket 401 without bearer material", async () => {
    await expect(
      upgradeStatus("/workspaces/ws1/sessions/s1/stream", `Bearer ${BEARER}`),
    ).resolves.toBe(401);

    const entries = unauthorizedEntries();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      transport: "ws",
      path: "/workspaces/ws1/sessions/s1/stream",
      authPresent: true,
    });
    const logged = lines.join("\n");
    expect(logged).not.toContain(BEARER);
    expect(logged).not.toContain("Bearer ");
  });

  it("logs a machine-readable 401 reason without leaking the bearer", async () => {
    await expect(httpStatus("/sessions", "GET", `Bearer ${DEVICE_BEARER}`)).resolves.toBe(401);

    const entries = unauthorizedEntries();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({ authPresent: true, reason: expect.any(String) });
    expect(lines.join("\n")).not.toContain(DEVICE_BEARER);
  });
});

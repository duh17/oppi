/**
 * Live integration test proving that targeted device revocation and migration
 * finalization immediately terminate already-authenticated WebSockets while
 * leaving unrelated devices connected.
 */
import { generateKeyPairSync } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket, type RawData } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { DevicePublicKey } from "../src/types.js";

function makeDeviceKey(): DevicePublicKey {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

function enroll(storage: Storage): { id: string; token: string } {
  const pairingToken = storage.issuePairingToken(60_000);
  const result = storage.enrollViaPairing(pairingToken, {
    publicKey: makeDeviceKey(),
    name: "WS close test device",
  });
  if (!result) throw new Error("enrollment failed");
  return { id: result.deviceId, token: result.accessToken };
}

class WsProbe {
  readonly opened: Promise<void>;
  readonly closed: Promise<{ code: number }>;
  private frames: Record<string, unknown>[] = [];

  constructor(readonly ws: WebSocket) {
    this.opened = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        ws.terminate();
        reject(new Error("timed out waiting for WebSocket open"));
      }, 15_000);
      ws.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      ws.once("unexpected-response", (_req, res) => {
        clearTimeout(timer);
        reject(new Error(`WS upgrade failed with HTTP ${res.statusCode ?? "unknown"}`));
      });
      ws.once("error", (error: Error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
    this.closed = new Promise<{ code: number }>((resolve) => {
      ws.once("close", (code) => resolve({ code }));
    });
    ws.on("message", (data) => {
      this.frames.push(JSON.parse(rawDataToString(data)) as Record<string, unknown>);
    });
  }

  hasFrame(type: string): boolean {
    return this.frames.some((frame) => frame["type"] === type);
  }

  async waitForFrame(type: string, timeoutMs = 10_000): Promise<Record<string, unknown>> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const frame = this.frames.find((candidate) => candidate["type"] === type);
      if (frame) return frame;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error(`timed out waiting for frame ${type}`);
  }
}

function rawDataToString(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let socketPath: string;
let ownerToken: string;
let probes: WsProbe[] = [];

beforeEach(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-auth-ws-close-"));
  storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "self-signed" },
  });
  ownerToken = storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `https://127.0.0.1:${server.port}`;
  socketPath = server.socketPath;
}, 30_000);

afterEach(async () => {
  for (const probe of probes) {
    probe.ws.terminate();
  }
  probes = [];
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 45_000);

function localRequest(
  path: string,
  method = "GET",
  token: string | undefined = ownerToken,
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      { socketPath, path, method, headers: { Authorization: `Bearer ${token}` } },
      (res) => {
        let data = "";
        res.on("data", (chunk: Buffer) => (data += chunk.toString("utf8")));
        res.on("end", () => {
          let body: unknown = null;
          try {
            body = JSON.parse(data);
          } catch {
            body = data;
          }
          resolve({ status: res.statusCode ?? 0, body });
        });
      },
    );
    req.on("error", reject);
    req.end();
  });
}

function networkGet(path: string, token: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      `${baseUrl}${path}`,
      {
        rejectUnauthorized: false,
        headers: { Authorization: `Bearer ${token}` },
      },
      (res) => {
        res.resume();
        res.on("end", () => resolve(res.statusCode ?? 0));
      },
    );
    req.on("error", reject);
    req.end();
  });
}

async function connectStream(token: string): Promise<WsProbe> {
  const wsUrl = `${baseUrl.replace(/^https:/, "wss:")}/app/events/stream`;
  const probe = new WsProbe(
    new WebSocket(wsUrl, {
      headers: { Authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
    }),
  );
  probes.push(probe);
  await probe.opened;
  await probe.waitForFrame("app_events_connected");
  return probe;
}

describe("authenticated WebSocket termination on revoke/finalize", { timeout: 30_000 }, () => {
  it("revoking a device closes only that device's sockets and leaves another device connected", async () => {
    const deviceA = enroll(storage);
    const deviceB = enroll(storage);

    const wsA = await connectStream(deviceA.token);
    const wsB = await connectStream(deviceB.token);

    const revoke = await localRequest(`/auth/devices/${deviceA.id}`, "DELETE");
    expect(revoke.status).toBe(200);

    const closed = await wsA.closed;
    expect(closed.code).toBe(1008);

    // Device B remains connected and functional.
    expect(wsB.ws.readyState).toBe(WebSocket.OPEN);
    expect(wsB.hasFrame("app_events_connected")).toBe(true);
  });

  it("rejects leftover dt_ on ordinary WebSocket upgrades even before finalization", async () => {
    const legacyToken = "dt_ws_finalize_legacy";
    storage.updateConfig({ authDeviceTokens: [legacyToken] });
    const device = enroll(storage);

    const wsUrl = `${baseUrl.replace(/^https:/, "wss:")}/app/events/stream`;
    const rejected = new WsProbe(
      new WebSocket(wsUrl, {
        headers: { Authorization: `Bearer ${legacyToken}` },
        rejectUnauthorized: false,
      }),
    );
    probes.push(rejected);
    await expect(rejected.opened).rejects.toThrow(/401|unexpected|error/);

    const deviceWs = await connectStream(device.token);
    expect(deviceWs.ws.readyState).toBe(WebSocket.OPEN);
  });

  it("finalization does not close sockets authenticated after the cutover", async () => {
    const legacyToken = "dt_ws_post_finalize_legacy";
    storage.updateConfig({ authDeviceTokens: [legacyToken] });
    await localRequest("/auth/finalize", "POST");

    // A legacy dt_ can no longer upgrade at all after finalization.
    const wsUrl = `${baseUrl.replace(/^https:/, "wss:")}/app/events/stream`;
    const rejected = new WsProbe(
      new WebSocket(wsUrl, {
        headers: { Authorization: `Bearer ${legacyToken}` },
        rejectUnauthorized: false,
      }),
    );
    probes.push(rejected);
    await expect(rejected.opened).rejects.toThrow(/401|unexpected|error/);
  });

  it("revoking a pending dt_ device removes its token without a live ordinary socket", async () => {
    const token = "dt_ws_pending_revoke";
    storage.updateConfig({ authDeviceTokens: [token] });
    const pending = storage.listDevices().find((device) => device.legacyTokenHash);
    expect(pending).toBeDefined();
    if (!pending) return;

    const revoke = await localRequest(`/auth/devices/${pending.id}`, "DELETE");
    expect(revoke.status).toBe(200);
    expect(storage.getAuthDeviceTokens()).not.toContain(token);
    expect(await networkGet("/me", token)).toBe(401);
  });

  it("first replacement at_ use still commits the matching leftover dt_", async () => {
    const oldToken = "dt_ws_migration_cutoff";
    const unrelatedToken = "dt_ws_unrelated";
    storage.updateConfig({ authDeviceTokens: [oldToken, unrelatedToken] });

    const migrated = storage.migrateLegacyDevice(oldToken, {
      publicKey: makeDeviceKey(),
      name: "Migrated socket",
    });
    expect(migrated).not.toBeNull();
    if (!migrated) return;

    expect(await networkGet("/me", migrated.accessToken)).toBe(200);
    expect(storage.getAuthDeviceTokens()).not.toContain(oldToken);
    expect(storage.getAuthDeviceTokens()).toContain(unrelatedToken);
    expect(await networkGet("/me", oldToken)).toBe(401);
    expect(await networkGet("/me", unrelatedToken)).toBe(401);
  });

  it("owner-token rotation closes every device network socket and leaves the local UDS usable", async () => {
    const deviceA = enroll(storage);
    const deviceB = enroll(storage);

    const wsA = await connectStream(deviceA.token);
    const wsB = await connectStream(deviceB.token);

    const rotate = await localRequest("/auth/rotate", "POST");
    expect(rotate.status).toBe(200);

    // Every remote device socket is severed immediately.
    for (const probe of [wsA, wsB]) {
      const closed = await probe.closed;
      expect(closed.code).toBe(1008);
    }

    // The owner-only Unix socket is untouched: a local request with the NEW
    // owner token still succeeds (mirror bridge lives on this same socket).
    const newOwnerToken = storage.getToken();
    expect(newOwnerToken).toBeDefined();
    expect(newOwnerToken).not.toBe(ownerToken);
    const list = await localRequest("/auth/devices", "GET", newOwnerToken);
    expect(list.status).toBe(200);

    // Rotation invalidated the old credentials: a device token can no longer
    // upgrade at all.
    const wsUrl = `${baseUrl.replace(/^https:/, "wss:")}/app/events/stream`;
    const rejected = new WsProbe(
      new WebSocket(wsUrl, {
        headers: { Authorization: `Bearer ${deviceA.token}` },
        rejectUnauthorized: false,
      }),
    );
    probes.push(rejected);
    await expect(rejected.opened).rejects.toThrow(/401|unexpected|error/);
  });
});

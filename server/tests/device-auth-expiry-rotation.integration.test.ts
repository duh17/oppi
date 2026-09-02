/**
 * Access-token expiry on persistent streams, handshake rejection of expired
 * at_, and staged dt_ retirement on ordinary HTTP/WS (migrate still works).
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
import { CLOCK_SKEW_MS } from "../src/storage/device-auth.js";
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
    name: "Expiry rotation test device",
  });
  if (!result) throw new Error("enrollment failed");
  return { id: result.deviceId, token: result.accessToken };
}

function shortenAccessTokens(storage: Storage, expiresAt: number): void {
  storage.updateConfig({
    authAccessTokens: (storage.getConfig().authAccessTokens ?? []).map((token) => ({
      ...token,
      expiresAt,
    })),
  });
}

class WsProbe {
  readonly opened: Promise<void>;
  readonly closed: Promise<{ code: number; reason: string }>;
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
    this.closed = new Promise<{ code: number; reason: string }>((resolve) => {
      ws.once("close", (code, reasonBuf) => {
        const reason =
          typeof reasonBuf === "string"
            ? reasonBuf
            : Buffer.isBuffer(reasonBuf)
              ? reasonBuf.toString("utf8")
              : "";
        resolve({ code, reason });
      });
    });
    ws.on("message", (data) => {
      this.frames.push(JSON.parse(rawDataToString(data)) as Record<string, unknown>);
    });
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
  dataDir = mkdtempSync(join(tmpdir(), "oppi-auth-expiry-"));
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

function networkPost(
  path: string,
  token: string | undefined,
  body: unknown,
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const req = httpsRequest(
      `${baseUrl}${path}`,
      {
        method: "POST",
        rejectUnauthorized: false,
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(payload),
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk: Buffer) => (data += chunk.toString("utf8")));
        res.on("end", () => {
          let parsed: unknown = data;
          try {
            parsed = JSON.parse(data);
          } catch {
            // Keep the raw body for non-JSON responses.
          }
          resolve({ status: res.statusCode ?? 0, body: parsed });
        });
      },
    );
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

function localGet(path: string, token: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        socketPath,
        path,
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

function websocketUpgradeStatus(token: string): Promise<number> {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${baseUrl.replace(/^https:/, "wss:")}/app/events/stream`, {
      headers: { Authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
    });
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

describe("access-token expiry and dt_ retirement", { timeout: 30_000 }, () => {
  it("rejects expired at_ on HTTP and new WebSocket handshakes", async () => {
    const device = enroll(storage);
    expect(await networkGet("/me", device.token)).toBe(200);

    shortenAccessTokens(storage, Date.now() - CLOCK_SKEW_MS - 1);

    expect(await networkGet("/me", device.token)).toBe(401);
    expect(await websocketUpgradeStatus(device.token)).toBe(401);
  });

  it("closes a live command/read stream with auth_expired when at_ expires", async () => {
    const device = enroll(storage);
    shortenAccessTokens(storage, Date.now() - CLOCK_SKEW_MS + 250);

    const live = await connectStream(device.token);
    const closed = await live.closed;
    expect(closed.code).toBe(4001);
    expect(closed.reason).toBe("auth_expired");
  });

  it("does not close an unrelated device socket when another token expires", async () => {
    const deviceA = enroll(storage);
    const deviceB = enroll(storage);
    storage.updateConfig({
      authAccessTokens: (storage.getConfig().authAccessTokens ?? []).map((token) =>
        token.deviceId === deviceA.id
          ? { ...token, expiresAt: Date.now() - CLOCK_SKEW_MS + 250 }
          : token,
      ),
    });

    const wsA = await connectStream(deviceA.token);
    const wsB = await connectStream(deviceB.token);
    const closedA = await wsA.closed;
    expect(closedA.code).toBe(4001);
    expect(wsB.ws.readyState).toBe(WebSocket.OPEN);
  });

  it("rejects leftover dt_ on ordinary HTTP and WebSocket routes", async () => {
    const legacyToken = "dt_ordinary_route_rejected";
    storage.updateConfig({ authDeviceTokens: [legacyToken] });

    expect(await networkGet("/me", legacyToken)).toBe(401);
    expect(await websocketUpgradeStatus(legacyToken)).toBe(401);
    expect(await localGet("/me", ownerToken)).toBe(200);
  });

  it("still migrates a leftover dt_ to at_ without re-pairing", async () => {
    const legacyToken = "dt_migrate_only";
    storage.updateConfig({ authDeviceTokens: [legacyToken] });

    const migrated = await networkPost("/auth/migrate", legacyToken, {
      devicePublicKey: makeDeviceKey(),
      deviceName: "Upgraded phone",
    });
    expect(migrated.status).toBe(200);
    const body = migrated.body as { accessToken?: string; deviceId?: string };
    expect(body.deviceId?.startsWith("dev_")).toBe(true);
    expect(body.accessToken?.startsWith("at_")).toBe(true);
    expect(await networkGet("/me", body.accessToken as string)).toBe(200);
    expect(await networkGet("/me", legacyToken)).toBe(401);
  });

  it("rejects pairing without a device public key and does not issue dt_", async () => {
    const pairingToken = storage.issuePairingToken(60_000);
    const res = await networkPost("/pair", undefined, { pairingToken });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "devicePublicKey required" });
    expect(storage.getAuthDeviceTokens()).toEqual([]);
  });
});

import { generateKeyPairSync } from "node:crypto";
import { request as httpRequest } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { WebSocket } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { DevicePublicKey } from "../src/types.js";

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let socketPath: string;
let ownerToken: string;
let accessToken: string;
const deviceToken = "dt_plaintext_must_fail";

function devicePublicKey(): DevicePublicKey {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

function networkRequest(
  path: string,
  options: { method?: string; token?: string; body?: unknown } = {},
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const body = options.body === undefined ? undefined : JSON.stringify(options.body);
    const req = httpRequest(
      `${baseUrl}${path}`,
      {
        method: options.method ?? "GET",
        headers: {
          ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
          ...(body
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) }
            : {}),
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
    if (body) req.write(body);
    req.end();
  });
}

function localRequest(path: string, token: string): Promise<number> {
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
    const ws = new WebSocket(`${baseUrl.replace(/^http:/, "ws:")}/app/events/stream`, {
      headers: { Authorization: `Bearer ${token}` },
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

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-device-auth-plaintext-"));
  storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "disabled" },
    authDeviceTokens: [deviceToken],
  });
  ownerToken = storage.ensurePaired();
  const enrolled = storage.enrollViaPairing(
    storage.issuePairingToken(),
    { publicKey: devicePublicKey(), name: "Plaintext negative test" },
  );
  if (!enrolled) throw new Error("enrollment failed");
  accessToken = enrolled.accessToken;

  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${server.port}`;
  socketPath = server.socketPath;
}, 30_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 45_000);

describe("plaintext network device-auth cutoff", () => {
  it("preserves plaintext health and owner-local Unix-socket access", async () => {
    expect((await networkRequest("/health")).status).toBe(200);
    expect((await networkRequest("/me", { token: ownerToken })).status).toBe(401);
    expect(await localRequest("/me", ownerToken)).toBe(200);
  });

  it("rejects pair, migrate, challenge, and refresh before route dispatch", async () => {
    const pairingToken = storage.issuePairingToken();
    const requests = [
      networkRequest("/pair", {
        method: "POST",
        body: { pairingToken, devicePublicKey: devicePublicKey() },
      }),
      networkRequest("/auth/migrate", {
        method: "POST",
        token: deviceToken,
        body: { devicePublicKey: devicePublicKey() },
      }),
      networkRequest("/auth/challenge", {
        method: "POST",
        body: { deviceId: "dev_plaintext" },
      }),
      networkRequest("/auth/refresh", {
        method: "POST",
        body: { deviceId: "dev_plaintext", nonce: "n", signature: "s" },
      }),
    ];

    for (const response of await Promise.all(requests)) {
      expect(response.status).toBe(403);
      expect(response.body).toEqual({ error: "HTTPS required" });
    }
    expect(storage.getConfig().pairingToken).toBe(pairingToken);
  });

  it("rejects dt_ and at_ on plaintext HTTP and WebSocket upgrades", async () => {
    expect((await networkRequest("/me", { token: deviceToken })).status).toBe(401);
    expect((await networkRequest("/me", { token: accessToken })).status).toBe(401);
    expect(await websocketUpgradeStatus(deviceToken)).toBe(401);
    expect(await websocketUpgradeStatus(accessToken)).toBe(401);
  });
});

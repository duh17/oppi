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

function devicePublicKey(): DevicePublicKey {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

function networkRequest(
  path: string,
  options: {
    method?: string;
    token?: string;
    body?: unknown;
    headers?: Record<string, string>;
  } = {},
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const body = options.body === undefined ? undefined : JSON.stringify(options.body);
    const req = httpRequest(
      `${baseUrl}${path}`,
      {
        method: options.method ?? "GET",
        headers: {
          ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
          ...(options.headers ?? {}),
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

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-proxy-trust-"));
  storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "disabled" },
    publicUrl: "https://oppi.example.com",
    proxy: { trustedPeers: ["127.0.0.1/32", "::1/128"] },
  });
  ownerToken = storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${server.port}`;
  socketPath = server.socketPath;
}, 30_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 45_000);

describe("trusted private HTTP proxy", () => {
  it("rejects pairing without the documented HTTPS assertion", async () => {
    const pairingToken = storage.issuePairingToken();
    const response = await networkRequest("/pair", {
      method: "POST",
      body: { pairingToken, devicePublicKey: devicePublicKey() },
    });
    expect(response.status).toBe(403);
    expect(response.body).toEqual({ error: "HTTPS required" });
    expect(storage.getConfig().pairingToken).toBe(pairingToken);
  });

  it("pairs through a trusted peer with X-Forwarded-Proto https", async () => {
    const pairingToken = storage.issuePairingToken();
    const response = await networkRequest("/pair", {
      method: "POST",
      headers: {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-For": "203.0.113.10",
        Origin: "https://oppi.example.com",
      },
      body: { pairingToken, devicePublicKey: devicePublicKey(), deviceName: "Proxy Phone" },
    });
    expect(response.status).toBe(200);
    const body = response.body as { accessToken?: string; deviceId?: string };
    expect(body.accessToken?.startsWith("at_")).toBe(true);

    const me = await networkRequest("/me", {
      token: body.accessToken,
      headers: { "X-Forwarded-Proto": "https", "X-Forwarded-For": "203.0.113.10" },
    });
    expect(me.status).toBe(200);
  });

  it("rejects owner tokens and the mirror bridge on the network listener", async () => {
    const owner = await networkRequest("/me", {
      token: ownerToken,
      headers: { "X-Forwarded-Proto": "https" },
    });
    expect(owner.status).toBe(401);

    const mirrorStatus = await new Promise<number>((resolve) => {
      const ws = new WebSocket(`${baseUrl.replace(/^http:/, "ws:")}/mirror/v1/bridge`, {
        headers: { "X-Forwarded-Proto": "https" },
      });
      ws.once("unexpected-response", (_request, response) => {
        response.resume();
        resolve(response.statusCode ?? 0);
      });
      ws.once("open", () => {
        ws.terminate();
        resolve(101);
      });
      ws.once("error", () => resolve(0));
    });
    expect(mirrorStatus).toBe(404);
    expect(socketPath.length).toBeGreaterThan(0);
  });

  it("isolates pairing rate limits by forwarded client IP", async () => {
    const attackerHeaders = {
      "X-Forwarded-Proto": "https",
      "X-Forwarded-For": "198.51.100.20",
    };
    for (let i = 0; i < 5; i += 1) {
      const failed = await networkRequest("/pair", {
        method: "POST",
        headers: attackerHeaders,
        body: { pairingToken: "pt_invalid", devicePublicKey: devicePublicKey() },
      });
      expect(failed.status).toBe(401);
    }
    const blocked = await networkRequest("/pair", {
      method: "POST",
      headers: attackerHeaders,
      body: { pairingToken: "pt_invalid", devicePublicKey: devicePublicKey() },
    });
    expect(blocked.status).toBe(429);

    const pairingToken = storage.issuePairingToken();
    const victim = await networkRequest("/pair", {
      method: "POST",
      headers: {
        "X-Forwarded-Proto": "https",
        "X-Forwarded-For": "198.51.100.21",
      },
      body: { pairingToken, devicePublicKey: devicePublicKey(), deviceName: "Victim" },
    });
    expect(victim.status).toBe(200);
  });
});

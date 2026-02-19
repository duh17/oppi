import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";
import { Server } from "../src/server.js";

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
const adminToken = "sk_test_pair_admin_token";

function postPair(body: unknown): Promise<Response> {
  return fetch(`${baseUrl}/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-pairing-token-"));
  storage = new Storage(dataDir);

  const port = 18900 + Math.floor(Math.random() * 800);
  const proxyPort = 19900 + Math.floor(Math.random() * 800);

  storage.updateConfig({
    host: "127.0.0.1",
    port,
    token: adminToken,
  });

  process.env.OPPI_AUTH_PROXY_PORT = String(proxyPort);
  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${port}`;
}, 15_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  await new Promise((r) => setTimeout(r, 100));
  rmSync(dataDir, { recursive: true, force: true });
}, 10_000);

describe("pairing token flow", () => {
  it("issues dt token and rejects replay", async () => {
    const pt = storage.issuePairingToken(90_000);

    const first = await postPair({ pairingToken: pt, deviceName: "test-iphone" });
    expect(first.status).toBe(200);
    const firstBody = await first.json() as { deviceToken: string };
    expect(firstBody.deviceToken.startsWith("dt_")).toBe(true);

    const auth = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${firstBody.deviceToken}` },
    });
    expect(auth.status).toBe(200);

    const replay = await postPair({ pairingToken: pt, deviceName: "test-iphone" });
    expect(replay.status).toBe(401);
  });

  it("rejects expired pairing token", async () => {
    const pt = storage.issuePairingToken(1_000);
    await new Promise((r) => setTimeout(r, 1_100));

    const res = await postPair({ pairingToken: pt });
    expect(res.status).toBe(401);
  });

  it("rejects missing pairingToken", async () => {
    const res = await postPair({});
    expect(res.status).toBe(400);
  });

  it("rate limits repeated invalid pairing attempts", async () => {
    let sawRateLimit = false;

    for (let i = 0; i < 8; i++) {
      const res = await postPair({ pairingToken: `pt_invalid_${i}` });
      if (res.status === 429) {
        sawRateLimit = true;
        break;
      }
      expect(res.status).toBe(401);
    }

    expect(sawRateLimit).toBe(true);
  });
});

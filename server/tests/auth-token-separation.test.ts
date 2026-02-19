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

const adminToken = "sk_test_admin_token";
const authDeviceToken = "dt_test_auth_device_token";
const pushDeviceToken = "apns_test_push_token";

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-auth-token-separation-"));
  storage = new Storage(dataDir);

  const port = 18600 + Math.floor(Math.random() * 800);
  const proxyPort = 19600 + Math.floor(Math.random() * 800);

  storage.updateConfig({
    host: "127.0.0.1",
    port,
    token: adminToken,
    authDeviceTokens: [authDeviceToken],
    pushDeviceTokens: [pushDeviceToken],
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

describe("auth token separation", () => {
  it("accepts pair-issued auth device token", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${authDeviceToken}` },
    });

    expect(res.status).toBe(200);
  });

  it("rejects push device token for API auth", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${pushDeviceToken}` },
    });

    expect(res.status).toBe(401);
  });

  it("still accepts admin token", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    });

    expect(res.status).toBe(200);
  });
});

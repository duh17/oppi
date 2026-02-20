import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";
import { Server } from "../src/server.js";

const legacyPushLikeToken = "apns_legacy_token_abc123";
const adminToken = "sk_test_admin_token_migration";

describe("config migration v3 token separation", () => {
  it("maps legacy deviceTokens to pushDeviceTokens only", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-config-migration-v3-validate-"));
    try {
      const defaults = Storage.getDefaultConfig(dir) as unknown as Record<string, unknown>;
      const legacy = {
        ...defaults,
        token: adminToken,
        deviceTokens: [legacyPushLikeToken],
      };

      const result = Storage.validateConfig(legacy, dir, false);

      expect(result.valid).toBe(true);
      expect(result.config?.pushDeviceTokens).toContain(legacyPushLikeToken);
      expect(result.config?.authDeviceTokens || []).not.toContain(legacyPushLikeToken);
      expect(result.warnings.some((w) => w.includes("config.deviceTokens is deprecated"))).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("legacy deviceTokens are non-auth after migration", () => {
  let dataDir: string;
  let storage: Storage;
  let server: Server;
  let baseUrl: string;

  beforeAll(async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-config-migration-v3-server-"));

    const defaults = Storage.getDefaultConfig(dataDir) as unknown as Record<string, unknown>;
    const legacy = {
      ...defaults,
      host: "127.0.0.1",
      port: 18700 + Math.floor(Math.random() * 800),
      token: adminToken,
      deviceTokens: [legacyPushLikeToken],
    };

    writeFileSync(join(dataDir, "config.json"), JSON.stringify(legacy, null, 2));

    storage = new Storage(dataDir);

    expect(storage.getPushDeviceTokens()).toContain(legacyPushLikeToken);
    expect(storage.getAuthDeviceTokens()).not.toContain(legacyPushLikeToken);

    const port = storage.getConfig().port;
    const proxyPort = 19700 + Math.floor(Math.random() * 800);
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

  it("rejects legacy push token for API auth", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${legacyPushLikeToken}` },
    });

    expect(res.status).toBe(401);
  });

  it("accepts admin token", async () => {
    const res = await fetch(`${baseUrl}/me`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    });

    expect(res.status).toBe(200);
  });
});

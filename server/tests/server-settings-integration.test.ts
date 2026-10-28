import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

// The real Server wiring behind the settings routes: its model runtime and its metrics latch.
describe("settings through a running server", () => {
  let dataDir: string;
  let storage: Storage;
  let server: Server;
  let baseUrl: string;
  let token: string;

  beforeEach(async () => {
    vi.stubEnv("OPPI_E2E_UI_HARNESS", "1");
    vi.stubEnv("OPPI_E2E_FAUX_PROVIDER", "1");
    vi.stubEnv("NODE_TLS_REJECT_UNAUTHORIZED", "0");
    dataDir = mkdtempSync(join(tmpdir(), "oppi-settings-integration-"));
    storage = new Storage(dataDir);
    storage.ensurePaired();
    const jwk = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({
      format: "jwk",
    }) as { x: string; y: string };
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
      name: "settings-integration",
    });
    if (!enrolled) throw new Error("enrollment failed");
    token = enrolled.accessToken;
    storage.mutateConfig(() => ({ host: "127.0.0.1", port: 0, tls: { mode: "self-signed" } }));
    server = new Server(storage);
    await server.start();
    baseUrl = `https://127.0.0.1:${server.port}`;
  }, 30_000);

  afterEach(async () => {
    await server.stop().catch(() => {});
    vi.unstubAllEnvs();
    rmSync(dataDir, { recursive: true, force: true });
  }, 30_000);

  function request(method: string, path: string, body?: unknown): Promise<Response> {
    return fetch(`${baseUrl}${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }

  it("reports the sampler that is running, not a config.json that says otherwise", async () => {
    // The sampler latched "off" at startup; the file now says "on" (as `oppi config set` would).
    storage.mutateConfig(() => ({ serverMetrics: { enabled: true, revision: 3 } }));

    const response = await request("GET", "/server/metrics/settings");
    expect(await response.json()).toEqual({ enabled: false, revision: 3 });

    // A refused stale write names the same state the GET does.
    const stale = await request("PUT", "/server/metrics/settings", {
      enabled: true,
      baseRevision: 2,
    });
    expect(stale.status).toBe(409);
    expect(((await stale.json()) as { current: unknown }).current).toEqual({
      enabled: false,
      revision: 3,
    });
  }, 30_000);
});

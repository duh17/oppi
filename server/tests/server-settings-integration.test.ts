import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { WebSocket } from "ws";

import { Server } from "../src/server.js";
import { SERVER_FEATURE_PRESETS } from "../src/server-features.js";
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

  it("turns durable sessions on and off for the running server with one save each", async () => {
    const capability = async () =>
      (
        (await (await request("GET", "/server/info")).json()) as {
          capabilities: { durableSessions?: { version: number } };
        }
      ).capabilities.durableSessions;
    expect(await capability()).toBeUndefined();

    const on = await request("PUT", "/server/durable-sessions/settings", {
      enabled: true,
      baseRevision: 0,
    });
    expect(await on.json()).toEqual({ enabled: true, revision: 1 });
    expect(await capability()).toEqual({ version: 1 });

    const off = await request("PUT", "/server/durable-sessions/settings", {
      enabled: false,
      baseRevision: 1,
    });
    expect(await off.json()).toEqual({ enabled: false, revision: 2 });
    expect(await capability()).toBeUndefined();
  }, 30_000);

  it("switches features: every one on by default, Plain Pi turns all off, one comes back, apps hear each change", async () => {
    const info = async () =>
      ((await (await request("GET", "/server/info")).json()) as { features: unknown }).features;
    expect(await info()).toEqual(SERVER_FEATURE_PRESETS.all);

    const events = await openAppEvents();
    try {
      const plain = await request("PUT", "/server/features", SERVER_FEATURE_PRESETS.plainPi);
      expect(await plain.json()).toEqual(SERVER_FEATURE_PRESETS.plainPi);
      expect(await info()).toEqual(SERVER_FEATURE_PRESETS.plainPi);
      await events.next("features_changed");

      const mcp = await request("PUT", "/server/features", { mcp: true });
      expect(await mcp.json()).toEqual({ ...SERVER_FEATURE_PRESETS.plainPi, mcp: true });
      await events.next("features_changed");

      // A save that changes nothing tells nobody; a name the server lacks changes nothing.
      await request("PUT", "/server/features", { mcp: true });
      const unknown = await request("PUT", "/server/features", { voice: false });
      expect(unknown.status).toBe(400);
      expect(await (await request("GET", "/server/features")).json()).toEqual({
        ...SERVER_FEATURE_PRESETS.plainPi,
        mcp: true,
      });
      await request("PUT", "/server/features", { terminal: true });
      expect(await events.next("features_changed")).toBeDefined();
      expect(events.count("features_changed")).toBe(3);
    } finally {
      events.close();
    }

    // Saved in config.json: a restarted server reads the same switches.
    expect(new Storage(dataDir).getConfig().features).toEqual({
      ...SERVER_FEATURE_PRESETS.plainPi,
      mcp: true,
      terminal: true,
    });
  }, 30_000);

  /** The app-event socket, with each frame's type in arrival order. */
  async function openAppEvents(): Promise<{
    next(type: string): Promise<Record<string, unknown>>;
    count(type: string): number;
    close(): void;
  }> {
    const ws = new WebSocket(`${baseUrl.replace(/^https:/, "wss:")}/app/events/stream`, {
      headers: { Authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
    });
    const frames: Record<string, unknown>[] = [];
    let read = 0;
    let wake: (() => void) | undefined;
    ws.on("message", (data) => {
      frames.push(JSON.parse(String(data)) as Record<string, unknown>);
      wake?.();
    });
    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", reject);
    });
    async function next(type: string): Promise<Record<string, unknown>> {
      for (;;) {
        const index = frames.findIndex((frame, at) => at >= read && frame.type === type);
        if (index >= 0) {
          read = index + 1;
          return frames[index]!;
        }
        await new Promise<void>((resolve) => (wake = resolve));
      }
    }
    // The stream says it is connected before any event can reach it.
    await next("app_events_connected");
    return {
      next,
      count: (type) => frames.filter((frame) => frame.type === type).length,
      close: () => ws.close(),
    };
  }
});

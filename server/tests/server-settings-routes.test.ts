import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createDurableSessionsSettingsRoutes } from "../src/routes/durable-sessions-settings.js";
import { createServerMetricsRoutes } from "../src/routes/server-metrics.js";
import type { RouteContext } from "../src/routes/types.js";
import { applySetting, readConfigSetting } from "../src/settings/config-settings.js";
import { Storage } from "../src/storage.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-settings-routes-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

async function call(
  dispatch: ReturnType<typeof createIdentityRoutes>,
  method: string,
  path: string,
  body?: unknown,
) {
  const res = makeResponse();
  const handled = await dispatch({
    method,
    path,
    url: new URL(`http://localhost${path}`),
    req: makeRequest(body),
    res: res as never,
  });
  expect(handled).toBe(true);
  return { status: res.statusCode, json: JSON.parse(res.body) as Record<string, unknown> };
}

describe("PUT /server/metrics/settings", () => {
  function metrics() {
    const control = {
      telemetryDir: dataDir,
      intervalMs: 30_000,
      isEnabled: () => readConfigSetting(storage.getConfig(), "serverMetrics").enabled,
      settings: () => readConfigSetting(storage.getConfig(), "serverMetrics"),
      apply: (patch: { enabled: boolean }, baseRevision: number | undefined) =>
        applySetting(storage, "serverMetrics", patch, baseRevision),
      latestSample: () => null,
    };
    const ctx = { serverMetrics: control, serverStartedAt: 1 } as unknown as RouteContext;
    const dispatch = createServerMetricsRoutes(ctx, createRouteHelpers());
    return (method: string, body?: unknown) =>
      call(dispatch as never, method, "/server/metrics/settings", body);
  }

  it("revisions saves; omitting baseRevision keeps last-writer-wins", async () => {
    const route = metrics();
    expect((await route("GET")).json).toEqual({ enabled: false, revision: 0 });
    expect((await route("PUT", { enabled: true })).json).toEqual({ enabled: true, revision: 1 });
    expect((await route("PUT", { enabled: false })).json).toEqual({ enabled: false, revision: 2 });
    expect(readConfigSetting(new Storage(dataDir).getConfig(), "serverMetrics")).toEqual({
      enabled: false,
      revision: 2,
    });
  });

  it("answers a stale baseRevision with 409 revision_conflict and leaves the switch alone", async () => {
    const route = metrics();
    await route("PUT", { enabled: true });

    expect(await route("PUT", { enabled: false, baseRevision: 0 })).toEqual({
      status: 409,
      json: {
        error: "Server Metrics setting changed",
        code: "revision_conflict",
        current: { enabled: true, revision: 1 },
      },
    });
    expect((await route("GET")).json).toEqual({ enabled: true, revision: 1 });
    expect((await route("PUT", { enabled: false, baseRevision: 1 })).json).toEqual({
      enabled: false,
      revision: 2,
    });
    expect((await route("PUT", { enabled: "no" })).status).toBe(400);
    expect((await route("PUT", { enabled: true, baseRevision: 1.5 })).status).toBe(400);
  });
});

describe("/server/durable-sessions/settings", () => {
  /** The route over a stand-in for the SessionManager's running switch, latched like the real one. */
  function durable(startedOn = false) {
    let running = startedOn;
    const sessions = {
      durableSessionsAvailable: () => running,
      setDurableSessionsAvailable: (enabled: boolean) => {
        running = enabled;
      },
    };
    const ctx = { storage, sessions } as unknown as RouteContext;
    const dispatch = createDurableSessionsSettingsRoutes(ctx, createRouteHelpers());
    const route = (method: string, body?: unknown) =>
      call(dispatch as never, method, "/server/durable-sessions/settings", body);
    return { route, running: () => running };
  }

  it("saves experimental.serverDurable with a revision and turns durable creates on without a restart", async () => {
    const { route, running } = durable();
    expect((await route("GET")).json).toEqual({ enabled: false, revision: 0 });

    expect((await route("PUT", { enabled: true, baseRevision: 0 })).json).toEqual({
      enabled: true,
      revision: 1,
    });
    expect(running()).toBe(true);
    const saved = new Storage(dataDir).getConfig().experimental;
    expect(saved).toMatchObject({ serverDurable: true, serverDurableRevision: 1 });

    expect((await route("PUT", { enabled: false })).json).toEqual({ enabled: false, revision: 2 });
    expect(running()).toBe(false);
  });

  it("keeps the other experimental settings it shares a block with", async () => {
    storage.mutateConfig(() => ({
      experimental: { durableExtensions: { disabled: ["codemode"] } },
    }));
    const { route } = durable();
    await route("PUT", { enabled: true });
    expect(new Storage(dataDir).getConfig().experimental).toEqual({
      serverDurable: true,
      serverDurableRevision: 1,
      durableExtensions: { disabled: ["codemode"] },
    });
  });

  it("answers a stale baseRevision with 409 and the running value, and changes nothing", async () => {
    const { route, running } = durable();
    await route("PUT", { enabled: true });

    expect(await route("PUT", { enabled: false, baseRevision: 0 })).toEqual({
      status: 409,
      json: {
        error: "Durable Sessions setting changed",
        code: "revision_conflict",
        current: { enabled: true, revision: 1 },
      },
    });
    expect(running()).toBe(true);
    expect((await route("PUT", { enabled: "yes" })).status).toBe(400);
    expect((await route("PUT", { enabled: true, baseRevision: -1 })).status).toBe(400);
    expect(running()).toBe(true);
  });

  it("reports what the running server does when config.json says otherwise", async () => {
    // `oppi config set experimental.serverDurable true` while the server runs: on at next restart.
    storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
    const { route } = durable(false);
    expect((await route("GET")).json).toEqual({ enabled: false, revision: 0 });
  });
});

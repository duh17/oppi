import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
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

import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createServerUpdateRoutes } from "../src/routes/server-update.js";
import type { RouteContext } from "../src/routes/types.js";
import { ServerUpdateService } from "../src/server-update.js";
import { SERVER_UPDATE_ERROR } from "../src/types/server-update.js";
import { getPackageInfo, packageRootDir } from "../src/version.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const originalPath = process.env.PATH;
const originalFakeRoot = process.env.FAKE_NPM_ROOT;
const originalFakeLatest = process.env.FAKE_NPM_LATEST;
const originalViewFail = process.env.FAKE_NPM_VIEW_FAIL;
const originalInstallFail = process.env.FAKE_NPM_INSTALL_FAIL;
const originalInstallSleep = process.env.FAKE_NPM_INSTALL_SLEEP;

function restoreEnv(): void {
  process.env.PATH = originalPath;
  for (const [key, value] of [
    ["FAKE_NPM_ROOT", originalFakeRoot],
    ["FAKE_NPM_LATEST", originalFakeLatest],
    ["FAKE_NPM_VIEW_FAIL", originalViewFail],
    ["FAKE_NPM_INSTALL_FAIL", originalInstallFail],
    ["FAKE_NPM_INSTALL_SLEEP", originalInstallSleep],
  ] as const) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

afterEach(() => {
  restoreEnv();
});

function writeFakeNpm(dir: string): string {
  const bin = join(dir, "bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(
    join(bin, "npm"),
    `#!/bin/sh
if [ "$1" = "root" ] && [ "$2" = "-g" ]; then
  printf '%s\\n' "\${FAKE_NPM_ROOT}"
  exit 0
fi
if [ "$1" = "view" ]; then
  if [ "\${FAKE_NPM_VIEW_FAIL:-}" = "1" ]; then
    echo "npm error 404 Not Found" >&2
    exit 1
  fi
  printf '%s\\n' "\${FAKE_NPM_LATEST:-0.99.0}"
  exit 0
fi
if [ "$1" = "install" ]; then
  if [ -n "\${FAKE_NPM_INSTALL_SLEEP:-}" ]; then
    sleep "\${FAKE_NPM_INSTALL_SLEEP}"
  fi
  if [ "\${FAKE_NPM_INSTALL_FAIL:-}" = "1" ]; then
    echo "npm error EACCES: permission denied" >&2
    echo "npm error mkdir /nope" >&2
    exit 1
  fi
  echo "added 1 package"
  exit 0
fi
echo "unexpected npm $*" >&2
exit 1
`,
    { mode: 0o755 },
  );
  return bin;
}

function makeGlobalLayout(dir: string): string {
  const pkg = packageRootDir();
  if (!pkg) throw new Error("missing package root");
  const globalRoot = join(dir, "lib", "node_modules");
  mkdirSync(globalRoot, { recursive: true });
  symlinkSync(pkg, join(globalRoot, "oppi-server"));
  return globalRoot;
}

function useFakeNpm(
  dir: string,
  options?: {
    global?: boolean;
    latest?: string;
    viewFail?: boolean;
    installFail?: boolean;
    installSleepSec?: string;
  },
): void {
  const bin = writeFakeNpm(dir);
  process.env.PATH = `${bin}:${originalPath ?? ""}`;
  if (options?.global) {
    process.env.FAKE_NPM_ROOT = makeGlobalLayout(dir);
  } else {
    process.env.FAKE_NPM_ROOT = join(dir, "missing-global");
  }
  if (options?.latest) process.env.FAKE_NPM_LATEST = options.latest;
  if (options?.viewFail) process.env.FAKE_NPM_VIEW_FAIL = "1";
  if (options?.installFail) process.env.FAKE_NPM_INSTALL_FAIL = "1";
  if (options?.installSleepSec) process.env.FAKE_NPM_INSTALL_SLEEP = options.installSleepSec;
}

function identityCtx(service: ServerUpdateService): RouteContext {
  return {
    storage: {
      getConfig: () => ({ configVersion: 1 }),
      listWorkspaces: () => [],
      listSessions: () => [],
    },
    sessions: { getActiveSessionIds: () => new Set() },
    sessionRuntimes: { getActiveSessionIds: () => new Set() },
    skillRegistry: { list: () => [] },
    getModelCatalog: () => [],
    serverStartedAt: Date.now(),
    serverVersion: getPackageInfo().version,
    piVersion: "0.0.0",
    serverUpdate: service,
  } as unknown as RouteContext;
}

describe("ServerUpdateService", () => {
  it("reports registry failure as unknown latest, not an error status", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-reg-"));
    try {
      useFakeNpm(dir, { viewFail: true });
      const service = new ServerUpdateService();
      const latest = await service.refreshLatest();
      expect(latest).toBeNull();
      const snap = service.snapshot();
      expect(snap.latestVersion).toBeNull();
      expect(snap.available).toBe(false);
      expect(snap.status).toBe("idle");
      expect(snap.installKind).toBe("other");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects a version that is not the last discovered latest", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-ver-"));
    try {
      useFakeNpm(dir, { global: true, latest: "9.9.9" });
      const service = new ServerUpdateService();
      expect(await service.refreshLatest()).toBe("9.9.9");
      const result = service.beginUpdate("1.0.0");
      expect(result.ok).toBe(false);
      if (result.ok) throw new Error("expected rejection");
      expect(result.code).toBe(SERVER_UPDATE_ERROR.versionNotLatest);
      expect(result.status).toBe(400);
      expect(service.snapshot().status).toBe("idle");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects updates when this process is not a global npm install", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-kind-"));
    try {
      useFakeNpm(dir, { latest: "9.9.9" });
      const service = new ServerUpdateService();
      expect(await service.refreshLatest()).toBe("9.9.9");
      const result = service.beginUpdate("9.9.9");
      expect(result.ok).toBe(false);
      if (result.ok) throw new Error("expected rejection");
      expect(result.code).toBe(SERVER_UPDATE_ERROR.installNotUpdatable);
      expect(result.status).toBe(400);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects a second update while npm install is running", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-busy-"));
    try {
      useFakeNpm(dir, { global: true, latest: "9.9.9", installSleepSec: "1" });
      const service = new ServerUpdateService();
      expect(await service.refreshLatest()).toBe("9.9.9");
      const first = service.beginUpdate("9.9.9");
      expect(first.ok).toBe(true);
      const second = service.beginUpdate("9.9.9");
      expect(second.ok).toBe(false);
      if (second.ok) throw new Error("expected rejection");
      expect(second.code).toBe(SERVER_UPDATE_ERROR.updateInProgress);
      expect(second.status).toBe(409);
      await vi.waitFor(
        () => {
          expect(["restarting", "failed"]).toContain(service.snapshot().status);
        },
        { timeout: 8_000, interval: 50 },
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("surfaces the npm error tail when install fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-fail-"));
    try {
      useFakeNpm(dir, { global: true, latest: "9.9.9", installFail: true });
      const service = new ServerUpdateService();
      expect(await service.refreshLatest()).toBe("9.9.9");
      const started = service.beginUpdate("9.9.9");
      expect(started.ok).toBe(true);
      await vi.waitFor(
        () => {
          expect(service.snapshot().status).toBe("failed");
        },
        { timeout: 8_000, interval: 50 },
      );
      const snap = service.snapshot();
      expect(snap.error).toMatch(/EACCES/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("marks restarting after a successful install without replacing this process", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-ok-"));
    try {
      useFakeNpm(dir, { global: true, latest: "9.9.9" });
      const service = new ServerUpdateService();
      expect(await service.refreshLatest()).toBe("9.9.9");
      const started = service.beginUpdate("9.9.9");
      expect(started.ok).toBe(true);
      await vi.waitFor(
        () => {
          expect(service.snapshot().status).toBe("restarting");
        },
        { timeout: 8_000, interval: 50 },
      );
      expect(service.snapshot().targetVersion).toBe("9.9.9");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects arbitrary and empty versions at the boundary", () => {
    const service = new ServerUpdateService();
    for (const version of ["latest", "", 1, null, undefined, { version: "1.0.0" }]) {
      const result = service.beginUpdate(version);
      expect(result.ok).toBe(false);
      if (result.ok) throw new Error("expected rejection");
      expect(result.code).toBe(SERVER_UPDATE_ERROR.invalidVersion);
    }
  });
});

describe("POST /server/update and GET /server/info", () => {
  it("includes update on GET /server/info without blocking on a failed registry", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-info-"));
    try {
      useFakeNpm(dir, { viewFail: true });
      const service = new ServerUpdateService();
      await service.refreshLatest();
      const dispatch = createIdentityRoutes(identityCtx(service), createRouteHelpers());
      const res = makeResponse();
      const handled = await dispatch({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: res as never,
      });
      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as {
        update: { latestVersion: string | null; status: string; installKind: string };
      };
      expect(body.update.latestVersion).toBeNull();
      expect(body.update.status).toBe("idle");
      expect(body.update.installKind).toBe("other");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("maps exact-version rejection through the HTTP route", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-http-"));
    try {
      useFakeNpm(dir, { global: true, latest: "9.9.9" });
      const service = new ServerUpdateService();
      await service.refreshLatest();
      const dispatch = createServerUpdateRoutes(identityCtx(service), createRouteHelpers());
      const res = makeResponse();
      const handled = await dispatch({
        method: "POST",
        path: "/server/update",
        url: new URL("http://localhost/server/update"),
        req: makeRequest({ version: "1.2.3" }),
        res: res as never,
      });
      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      const body = JSON.parse(res.body) as { code: string; error: string };
      expect(body.code).toBe(SERVER_UPDATE_ERROR.versionNotLatest);
      expect(body.error).toMatch(/9\.9\.9/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

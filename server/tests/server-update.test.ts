import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest } from "../src/cli/local-api-client.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createServerUpdateRoutes } from "../src/routes/server-update.js";
import type { RouteContext } from "../src/routes/types.js";
import {
  ServerUpdateService,
  restartUpdatedProcess,
  serveUpdatedProcess,
} from "../src/server-update.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { SERVER_UPDATE_ERROR } from "../src/types/server-update.js";
import type { ServerUpdateInfo } from "../src/types/server-update.js";
import { getPackageInfo } from "../src/version.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const originalPath = process.env.PATH;
const originalFakeRoot = process.env.FAKE_NPM_ROOT;
const originalFakeLatest = process.env.FAKE_NPM_LATEST;
const originalViewFail = process.env.FAKE_NPM_VIEW_FAIL;
const originalInstallFail = process.env.FAKE_NPM_INSTALL_FAIL;
const originalInstallSleep = process.env.FAKE_NPM_INSTALL_SLEEP;
const originalRootSleep = process.env.FAKE_NPM_ROOT_SLEEP;
const originalBuildFail = process.env.FAKE_NPM_BUILD_FAIL;
const originalNpmLog = process.env.FAKE_NPM_LOG;

// State that arrives through a fake-npm subprocess (npm view / npm root -g / npm install) needs
// a real deadline: vitest's 1 s waitFor default is shorter than a loaded host's process spawn.
const SUBPROCESS_WAIT = { timeout: 8_000, interval: 50 } as const;

function restoreEnv(): void {
  process.env.PATH = originalPath;
  for (const [key, value] of [
    ["FAKE_NPM_ROOT", originalFakeRoot],
    ["FAKE_NPM_LATEST", originalFakeLatest],
    ["FAKE_NPM_VIEW_FAIL", originalViewFail],
    ["FAKE_NPM_INSTALL_FAIL", originalInstallFail],
    ["FAKE_NPM_INSTALL_SLEEP", originalInstallSleep],
    ["FAKE_NPM_ROOT_SLEEP", originalRootSleep],
    ["FAKE_NPM_BUILD_FAIL", originalBuildFail],
    ["FAKE_NPM_LOG", originalNpmLog],
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
if [ -n "\${FAKE_NPM_LOG:-}" ]; then printf '%s %s\\n' "$*" "$(pwd -P)" >> "\${FAKE_NPM_LOG}"; fi
if [ "$1" = "run" ]; then
  if [ "\${FAKE_NPM_BUILD_FAIL:-}" = "1" ]; then
    echo "src/server.ts(1,7): error TS2322: Type 'string' is not assignable to type 'number'." >&2
    exit 2
  fi
  echo "built"
  exit 0
fi
if [ "$1" = "root" ] && [ "$2" = "-g" ]; then
  if [ -n "\${FAKE_NPM_ROOT_SLEEP:-}" ]; then sleep "\${FAKE_NPM_ROOT_SLEEP}"; fi
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

const PAST = new Date("2000-01-01T00:00:00Z");

/** A package directory with one source file last modified long before this process started. */
function writePackage(packageDir: string, version: string, buildScript = true): void {
  mkdirSync(join(packageDir, "src"), { recursive: true });
  const scripts = buildScript ? { "build:in-place": "tsc" } : {};
  writeFileSync(
    join(packageDir, "package.json"),
    JSON.stringify({ name: "oppi-server", version, scripts }),
  );
  writeFileSync(join(packageDir, "src", "cli.ts"), "export {};\n");
  utimesSync(join(packageDir, "src", "cli.ts"), PAST, PAST);
}

/**
 * `npm`: a registry install, a real directory in the global root.
 * `source`: an `npm link`, a global-root symlink to a checkout elsewhere.
 * Returns the package directory to hand the service.
 */
function makeGlobalLayout(dir: string, kind: "npm" | "source", version: string): string {
  const globalRoot = join(dir, "lib", "node_modules");
  mkdirSync(globalRoot, { recursive: true });
  process.env.FAKE_NPM_ROOT = globalRoot;
  if (kind === "npm") {
    const packageDir = join(globalRoot, "oppi-server");
    writePackage(packageDir, version);
    return packageDir;
  }
  const checkout = join(dir, "checkout", "server");
  writePackage(checkout, version);
  symlinkSync(checkout, join(globalRoot, "oppi-server"));
  return checkout;
}

function useFakeNpm(
  dir: string,
  options?: {
    global?: "npm" | "source";
    packageVersion?: string;
    latest?: string;
    viewFail?: boolean;
    installFail?: boolean;
    installSleepSec?: string;
    buildFail?: boolean;
  },
): string | undefined {
  const bin = writeFakeNpm(dir);
  process.env.PATH = `${bin}:${originalPath ?? ""}`;
  process.env.FAKE_NPM_LOG = join(dir, "npm.log");
  let packageDir: string | undefined;
  if (options?.global) {
    packageDir = makeGlobalLayout(dir, options.global, options.packageVersion ?? "0.0.1");
  } else {
    process.env.FAKE_NPM_ROOT = join(dir, "missing-global");
  }
  if (options?.buildFail) process.env.FAKE_NPM_BUILD_FAIL = "1";
  if (options?.latest) process.env.FAKE_NPM_LATEST = options.latest;
  if (options?.viewFail) process.env.FAKE_NPM_VIEW_FAIL = "1";
  if (options?.installFail) process.env.FAKE_NPM_INSTALL_FAIL = "1";
  if (options?.installSleepSec) process.env.FAKE_NPM_INSTALL_SLEEP = options.installSleepSec;
  return packageDir;
}

function npmCalls(dir: string): string[] {
  const path = join(dir, "npm.log");
  return existsSync(path) ? readFileSync(path, "utf8").trim().split("\n") : [];
}

async function resolvedService(packageDir: string | undefined): Promise<ServerUpdateService> {
  const service = new ServerUpdateService({ packageDir });
  service.start();
  await vi.waitFor(() => expect(service.infoSnapshot()).toBeDefined(), SUBPROCESS_WAIT);
  return service;
}

function identityCtx(service: ServerUpdateService): RouteContext {
  return {
    storage: {
      getConfig: () => ({ configVersion: 1 }),
      listWorkspaces: () => [],
      listSessions: () => [],
    },
    sessions: {
      getActiveSessionIds: () => new Set(),
      durableSessionsAvailable: () => false,
      conversationStreamAvailable: () => false,
    },
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
      const packageDir = useFakeNpm(dir, { global: "npm", latest: "9.9.9" });
      const service = new ServerUpdateService({ packageDir });
      expect(await service.refreshLatest()).toBe("9.9.9");
      const result = await service.beginUpdate("1.0.0");
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
      const result = await service.beginUpdate("9.9.9");
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
      const packageDir = useFakeNpm(dir, {
        global: "npm",
        latest: "9.9.9",
        installSleepSec: "1",
      });
      const service = new ServerUpdateService({ packageDir });
      expect(await service.refreshLatest()).toBe("9.9.9");
      const first = await service.beginUpdate("9.9.9");
      expect(first.ok).toBe(true);
      const second = await service.beginUpdate("9.9.9");
      expect(second.ok).toBe(false);
      if (second.ok) throw new Error("expected rejection");
      expect(second.code).toBe(SERVER_UPDATE_ERROR.updateInProgress);
      expect(second.status).toBe(409);
      await vi.waitFor(() => {
        expect(["restarting", "failed"]).toContain(service.snapshot().status);
      }, SUBPROCESS_WAIT);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("surfaces the npm error tail when install fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-fail-"));
    try {
      const packageDir = useFakeNpm(dir, { global: "npm", latest: "9.9.9", installFail: true });
      const service = new ServerUpdateService({ packageDir });
      expect(await service.refreshLatest()).toBe("9.9.9");
      const started = await service.beginUpdate("9.9.9");
      expect(started.ok).toBe(true);
      await vi.waitFor(() => {
        expect(service.snapshot().status).toBe("failed");
      }, SUBPROCESS_WAIT);
      const snap = service.snapshot();
      expect(snap.error).toMatch(/EACCES/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("marks restarting after a successful install without replacing this process", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-ok-"));
    try {
      const packageDir = useFakeNpm(dir, { global: "npm", latest: "9.9.9" });
      const service = new ServerUpdateService({ packageDir });
      expect(await service.refreshLatest()).toBe("9.9.9");
      const started = await service.beginUpdate("9.9.9");
      expect(started.ok).toBe(true);
      await vi.waitFor(() => {
        expect(service.snapshot().status).toBe("restarting");
      }, SUBPROCESS_WAIT);
      expect(service.snapshot().targetVersion).toBe("9.9.9");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("keeps serving after manual install through onRestart", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-manual-"));
    const execve = process.execve;
    try {
      const packageDir = useFakeNpm(dir, { global: "npm", latest: "9.9.9" });
      Object.defineProperty(process, "execve", { configurable: true, value: undefined });
      const stop = vi.fn(async () => {});
      const restore = vi.fn(async () => {});
      const service = new ServerUpdateService({
        packageDir,
        onRestart: (mode) => {
          void serveUpdatedProcess(mode, stop, restore);
        },
      });
      await service.refreshLatest();
      expect((await service.beginUpdate("9.9.9")).ok).toBe(true);
      await vi.waitFor(
        () => expect(service.snapshot().status).toBe("restart-needed"),
        SUBPROCESS_WAIT,
      );
      await new Promise((resolve) => setTimeout(resolve, 500));
      expect(stop).not.toHaveBeenCalled();
      expect(restore).not.toHaveBeenCalled();
    } finally {
      Object.defineProperty(process, "execve", { configurable: true, value: execve });
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("restores the real server with a restart-needed snapshot after failed foreground exec", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-recovery-"));
    const execve = process.execve;
    const home = process.env.HOME;
    const oppiDataDir = process.env.OPPI_DATA_DIR;
    const npmPrefix = process.env.npm_config_prefix;
    process.env.HOME = join(dir, "home");
    process.env.OPPI_DATA_DIR = join(dir, "data");
    process.env.npm_config_prefix = join(dir, "npm-prefix");
    mkdirSync(process.env.HOME, { recursive: true });
    mkdirSync(process.env.npm_config_prefix, { recursive: true });
    const storage = new Storage(join(dir, "data"));
    storage.ensurePaired();
    storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });
    let server: Server | undefined;
    let updatePackageDir: string | undefined;
    let updateStarted = false;
    let resolveRestore: (() => void) | undefined;
    let rejectRestore: ((error: unknown) => void) | undefined;
    const restored = new Promise<void>((resolve, reject) => {
      resolveRestore = resolve;
      rejectRestore = reject;
    });
    const onRestartAfterUpdate = (mode: "manual" | "reexec" | "launchd", targetVersion: string) => {
      void serveUpdatedProcess(
        mode,
        () => server?.stop() ?? Promise.resolve(),
        async () => {
          server = new Server(storage, {
            onRestartAfterUpdate,
            restartNeededVersion: targetVersion,
            updatePackageDir,
          });
          await server.start();
          resolveRestore?.();
        },
        (restartMode) => restartUpdatedProcess(restartMode, () => false),
      ).catch(rejectRestore);
    };
    try {
      Object.defineProperty(process, "execve", {
        configurable: true,
        value: () => {
          throw new Error("exec denied");
        },
      });
      updatePackageDir = useFakeNpm(dir, { global: "npm", latest: "9.9.9" });
      server = new Server(storage, { onRestartAfterUpdate, updatePackageDir });
      await server.start();
      await vi.waitFor(async () => {
        const info = await localApiRequest<{ update?: ServerUpdateInfo }>(storage, "/server/info");
        expect(info.update?.latestVersion).toBe("9.9.9");
        expect(info.update?.installKind).toBe("npm-global");
      }, SUBPROCESS_WAIT);
      const started = await localApiRequest<ServerUpdateInfo>(storage, "/server/update", {
        method: "POST",
        body: { version: "9.9.9" },
      });
      updateStarted = true;
      expect(started.status).toBe("installing");
      await restored;
      await expect(
        localApiRequest(storage, "/server/update", {
          method: "POST",
          body: { version: "9.9.9" },
        }),
      ).rejects.toMatchObject({ status: 409, code: SERVER_UPDATE_ERROR.updateInProgress });
      await vi.waitFor(async () => {
        const info = await localApiRequest<{ version: string; update?: ServerUpdateInfo }>(
          storage,
          "/server/info",
        );
        expect(info.version).toBe(getPackageInfo().version);
        expect(info.update).toMatchObject({ status: "restart-needed", targetVersion: "9.9.9" });
        // The restored server's start() also looks up npm; let that finish before the
        // finally block removes the fake npm directory and restores PATH.
        expect(info.update?.latestVersion).toBe("9.9.9");
      }, SUBPROCESS_WAIT);
    } finally {
      if (updateStarted) await restored.catch(() => {});
      await server?.stop().catch(() => {});
      Object.defineProperty(process, "execve", { configurable: true, value: execve });
      for (const [key, value] of [
        ["HOME", home],
        ["OPPI_DATA_DIR", oppiDataDir],
        ["npm_config_prefix", npmPrefix],
      ] as const) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  it("offers a linked checkout's rebuild only once its source changes", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-src-"));
    const running = getPackageInfo().version;
    try {
      const packageDir = useFakeNpm(dir, {
        global: "source",
        packageVersion: running,
        latest: "9.9.9",
      });
      if (!packageDir) throw new Error("missing checkout");
      const service = await resolvedService(packageDir);
      expect(service.snapshot()).toMatchObject({
        installKind: "source-link",
        latestVersion: running,
        available: false,
      });
      const unchanged = await service.beginUpdate(running);
      if (unchanged.ok) throw new Error("expected rejection");
      expect(unchanged.code).toBe(SERVER_UPDATE_ERROR.alreadyCurrent);

      // An edit after this process started makes the checkout newer than what runs.
      writeFileSync(join(packageDir, "src", "cli.ts"), "export const edited = 1;\n");
      // npm's 9.9.9 is not this install's update target.
      const npmVersion = await service.beginUpdate("9.9.9");
      if (npmVersion.ok) throw new Error("expected rejection");
      expect(npmVersion.code).toBe(SERVER_UPDATE_ERROR.versionNotLatest);
      expect((await service.beginUpdate(running)).ok).toBe(true);
      await vi.waitFor(() => expect(service.snapshot().status).toBe("restarting"), SUBPROCESS_WAIT);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("counts edits made after the running build but before this process started", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-src-prestart-"));
    try {
      const packageDir = useFakeNpm(dir, {
        global: "source",
        packageVersion: getPackageInfo().version,
      });
      if (!packageDir) throw new Error("missing checkout");
      // Built in 2000, edited a day later, restarted without a build.
      const built = join(packageDir, "dist", "src", "cli.js");
      mkdirSync(join(packageDir, "dist", "src"), { recursive: true });
      writeFileSync(built, "");
      utimesSync(built, PAST, PAST);
      const edited = new Date(PAST.getTime() + 86_400_000);
      utimesSync(join(packageDir, "src", "cli.ts"), edited, edited);
      const service = await resolvedService(packageDir);
      expect(service.snapshot()).toMatchObject({ installKind: "source-link", available: true });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("treats a global symlink to a package it cannot rebuild as not app-updatable", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-src-packed-"));
    try {
      const packageDir = useFakeNpm(dir, { global: "source", latest: "9.9.9" });
      if (!packageDir) throw new Error("missing checkout");
      writePackage(packageDir, "0.0.1", false);
      const service = await resolvedService(packageDir);
      expect(service.snapshot()).toMatchObject({ installKind: "other", available: false });
      const result = await service.beginUpdate("9.9.9");
      if (result.ok) throw new Error("expected rejection");
      expect(result.code).toBe(SERVER_UPDATE_ERROR.installNotUpdatable);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("counts a checkout version bump as a change", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-src-ver-"));
    try {
      const packageDir = useFakeNpm(dir, { global: "source", packageVersion: "0.0.1" });
      const service = await resolvedService(packageDir);
      expect(service.snapshot()).toMatchObject({
        installKind: "source-link",
        latestVersion: "0.0.1",
        available: true,
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rebuilds a linked checkout in place instead of installing from npm", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-src-ok-"));
    try {
      const packageDir = useFakeNpm(dir, {
        global: "source",
        packageVersion: "0.0.1",
        latest: "9.9.9",
      });
      const service = await resolvedService(packageDir);
      const started = await service.beginUpdate("0.0.1");
      expect(started.ok).toBe(true);
      await vi.waitFor(() => expect(service.snapshot().status).toBe("restarting"), SUBPROCESS_WAIT);
      expect(service.snapshot().targetVersion).toBe("0.0.1");
      const calls = npmCalls(dir);
      expect(calls.some((call) => call.startsWith("install"))).toBe(false);
      expect(calls).toContain(`run build:in-place ${realpathSync(packageDir ?? "")}`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("keeps serving and reports compiler output when the rebuild fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-src-fail-"));
    try {
      const packageDir = useFakeNpm(dir, {
        global: "source",
        packageVersion: "0.0.1",
        buildFail: true,
      });
      const onRestart = vi.fn();
      const service = new ServerUpdateService({ packageDir, onRestart });
      service.start();
      await vi.waitFor(() => expect(service.infoSnapshot()).toBeDefined(), SUBPROCESS_WAIT);
      expect((await service.beginUpdate("0.0.1")).ok).toBe(true);
      await vi.waitFor(() => expect(service.snapshot().status).toBe("failed"), SUBPROCESS_WAIT);
      expect(service.snapshot().error).toMatch(/TS2322/);
      await new Promise((resolve) => setTimeout(resolve, 500));
      expect(onRestart).not.toHaveBeenCalled();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects arbitrary and empty versions at the boundary", async () => {
    const service = new ServerUpdateService();
    for (const version of ["latest", "", 1, null, undefined, { version: "1.0.0" }]) {
      const result = await service.beginUpdate(version);
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
      process.env.FAKE_NPM_ROOT_SLEEP = "1";
      service.start();
      const dispatch = createIdentityRoutes(identityCtx(service), createRouteHelpers());
      const res = makeResponse();
      const startedAt = performance.now();
      const handled = await dispatch({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: res as never,
      });
      expect(handled).toBe(true);
      expect(performance.now() - startedAt).toBeLessThan(500);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { update?: ServerUpdateInfo };
      expect(body.update).toBeUndefined();
      await service.refreshLatest();
      await vi.waitFor(
        () => expect(service.infoSnapshot()?.installKind).toBe("other"),
        SUBPROCESS_WAIT,
      );
      const after = makeResponse();
      await dispatch({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: after as never,
      });
      expect((JSON.parse(after.body) as { update: ServerUpdateInfo }).update).toMatchObject({
        installKind: "other",
        latestVersion: null,
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("maps exact-version rejection through the HTTP route", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-update-http-"));
    try {
      const packageDir = useFakeNpm(dir, { global: "npm", latest: "9.9.9" });
      const service = new ServerUpdateService({ packageDir });
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

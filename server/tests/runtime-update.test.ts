import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Mock child_process at module level — ESM doesn't allow vi.spyOn on namespace exports.
// vi.hoisted runs before vi.mock hoisting, so the reference is available in the factory.
const { mockExecFile } = vi.hoisted(() => ({
  mockExecFile: vi.fn(),
}));
vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, execFile: mockExecFile };
});

// Import AFTER mock declaration so the mock takes effect.
import { RuntimeUpdateManager } from "../src/runtime-update.js";

// ── Helpers ──

/**
 * Build a fake runtime directory that resolveRuntimeDir() will recognise.
 * The dir gets package.json + node_modules/ so the existence checks pass.
 */
function makeFakeRuntimeDir(opts?: {
  deps?: Record<string, string>;
  optionalDeps?: Record<string, string>;
  installedVersions?: Record<string, string>;
  seedVersion?: string;
}): { dir: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "oppi-rt-test-"));
  const deps = opts?.deps ?? { "@earendil-works/pi-coding-agent": "^0.62.0" };
  const optDeps = opts?.optionalDeps ?? {};
  const pkgJson: Record<string, unknown> = {
    name: "oppi-server-runtime",
    version: "1.0.0",
    dependencies: deps,
  };
  if (Object.keys(optDeps).length > 0) {
    pkgJson.optionalDependencies = optDeps;
  }

  writeFileSync(join(dir, "package.json"), JSON.stringify(pkgJson));
  mkdirSync(join(dir, "node_modules"), { recursive: true });

  // Write installed package versions
  const installed = opts?.installedVersions ?? {};
  for (const [name, version] of Object.entries(installed)) {
    const pkgDir = join(dir, "node_modules", name);
    mkdirSync(pkgDir, { recursive: true });
    writeFileSync(join(pkgDir, "package.json"), JSON.stringify({ name, version }));
  }

  if (opts?.seedVersion) {
    writeFileSync(join(dir, ".seed-version"), opts.seedVersion);
  }

  return {
    dir,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

/**
 * Point resolveRuntimeDir() at our fake dir by manipulating process.argv[1].
 * The resolver walks up 3 levels from the CLI entrypoint, so we create:
 *   <runtimeDir>/dist/src/cli.js
 */
function pointResolverAt(runtimeDir: string): void {
  mkdirSync(join(runtimeDir, "dist", "src"), { recursive: true });
  writeFileSync(join(runtimeDir, "dist", "src", "cli.js"), "");
  process.argv[1] = join(runtimeDir, "dist", "src", "cli.js");
}

/**
 * Set up mockExecFile to invoke the callback with given args.
 * Optionally runs a side-effect function before calling back (e.g. to modify files).
 */
function mockInstallSuccess(sideEffect?: () => void): void {
  mockExecFile.mockImplementation(
    (_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      sideEffect?.();
      cb(null, "", "");
    },
  );
}

function mockInstallFailure(stderr: string, stdout = ""): void {
  mockExecFile.mockImplementation(
    (_bin: string, _args: string[], _opts: unknown, cb: Function) => {
      cb(new Error("install error"), stdout, stderr);
    },
  );
}

function npmVersionResponse(version: string): Response {
  return new Response(JSON.stringify({ version }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

// ── Test setup ──

let savedArgv1: string;
let savedHome: string | undefined;
let savedRuntimeBin: string | undefined;
let savedFetch: typeof global.fetch | undefined;

beforeEach(() => {
  savedArgv1 = process.argv[1];
  savedHome = process.env.HOME;
  savedRuntimeBin = process.env.OPPI_RUNTIME_BIN;
  savedFetch = global.fetch;
  global.fetch = vi.fn(async () => npmVersionResponse("0.62.0")) as typeof global.fetch;
  mockExecFile.mockReset();
});

afterEach(() => {
  process.argv[1] = savedArgv1;
  process.env.HOME = savedHome;
  if (savedRuntimeBin === undefined) {
    delete process.env.OPPI_RUNTIME_BIN;
  } else {
    process.env.OPPI_RUNTIME_BIN = savedRuntimeBin;
  }
  global.fetch = savedFetch as typeof global.fetch;
});

// ── Tests ──

describe("RuntimeUpdateManager", () => {
  describe("getStatus", () => {
    it("reports current version and default package name", async () => {
      const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
      const status = await manager.getStatus();

      expect(status.currentVersion).toBe("0.62.0");
      expect(status.packageName).toBe("@earendil-works/pi-coding-agent");
      expect(status.latestVersion).toBe("0.62.0");
      expect(status.updateAvailable).toBe(false);
      expect(status.checking).toBe(false);
      expect(status.updateInProgress).toBe(false);
      expect(status.restartRequired).toBe(false);
    });

    it("uses custom package name", async () => {
      const manager = new RuntimeUpdateManager({
        packageName: "@custom/agent",
        currentVersion: "1.0.0",
      });
      const status = await manager.getStatus();
      expect(status.packageName).toBe("@custom/agent");
    });

    it("reports runtimeDir when argv-based resolution succeeds", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir();
      try {
        pointResolverAt(dir);
        const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
        const status = await manager.getStatus();
        expect(status.runtimeDir).toBe(dir);
      } finally {
        cleanup();
      }
    });

    it("reports seedVersion from .seed-version file", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({ seedVersion: "25" });
      try {
        pointResolverAt(dir);
        const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
        const status = await manager.getStatus();
        expect(status.seedVersion).toBe("25");
      } finally {
        cleanup();
      }
    });

    it("reports undefined seedVersion when file is missing", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir();
      try {
        pointResolverAt(dir);
        const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
        const status = await manager.getStatus();
        expect(status.seedVersion).toBeUndefined();
      } finally {
        cleanup();
      }
    });

    it("reports runtimeDir=undefined when dir is missing", async () => {
      process.env.HOME = "/tmp/nonexistent-oppi-test-home";
      process.argv[1] = "/tmp/nonexistent-oppi-test/dist/src/cli.js";

      const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
      const status = await manager.getStatus();
      expect(status.runtimeDir).toBeUndefined();
      expect(status.canUpdate).toBe(false);
    });

    it("reports update availability from npm registry", async () => {
      global.fetch = vi.fn(async () => npmVersionResponse("0.63.0")) as typeof global.fetch;

      const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
      const status = await manager.getStatus({ force: true });

      expect(status.latestVersion).toBe("0.63.0");
      expect(status.pendingVersion).toBe("0.63.0");
      expect(status.updateAvailable).toBe(true);
    });
  });

  describe("resolveRuntimeDir (via getStatus)", () => {
    it("resolves from process.argv[1] by walking up 3 levels", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir();
      try {
        pointResolverAt(dir);
        const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
        const status = await manager.getStatus();
        expect(status.runtimeDir).toBe(dir);
      } finally {
        cleanup();
      }
    });

    it("requires both package.json and node_modules in argv-based candidate", async () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-rt-nomod-"));
      writeFileSync(join(dir, "package.json"), "{}");
      mkdirSync(join(dir, "dist", "src"), { recursive: true });
      writeFileSync(join(dir, "dist", "src", "cli.js"), "");

      try {
        process.argv[1] = join(dir, "dist", "src", "cli.js");
        process.env.HOME = "/tmp/nonexistent-oppi-test-home";

        const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
        const status = await manager.getStatus();
        expect(status.runtimeDir).toBeUndefined();
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });

    it("falls back to conventional ~/.config/oppi/server-runtime path", async () => {
      const fakeHome = mkdtempSync(join(tmpdir(), "oppi-rt-home-"));
      const conventional = join(fakeHome, ".config", "oppi", "server-runtime");
      mkdirSync(conventional, { recursive: true });
      writeFileSync(join(conventional, "package.json"), '{"name":"test"}');

      try {
        process.argv[1] = "/tmp/nonexistent-argv/dist/src/cli.js";
        process.env.HOME = fakeHome;

        const manager = new RuntimeUpdateManager({ currentVersion: "1.0.0" });
        const status = await manager.getStatus();
        expect(status.runtimeDir).toBe(conventional);
      } finally {
        rmSync(fakeHome, { recursive: true, force: true });
      }
    });
  });

  describe("updateRuntime", () => {
    it("returns error when runtime dir not found", async () => {
      process.env.HOME = "/tmp/nonexistent-oppi-test";
      process.argv[1] = "/tmp/nonexistent-oppi-test/cli.js";

      const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
      const result = await manager.updateRuntime();

      expect(result.ok).toBe(false);
      expect(result.error).toBe("runtime_dir_not_found");
      expect(result.restartRequired).toBe(false);
      expect(result.message).toContain("Runtime directory not found");
    });

    it("rejects concurrent updates", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);

        let finishInstall!: () => void;
        const installStarted = new Promise<void>((resolveStarted) => {
          mockExecFile.mockImplementation(
            (_bin: string, _args: string[], _opts: unknown, cb: Function) => {
              resolveStarted();
              finishInstall = () => cb(null, "", "");
            },
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });

        const first = manager.updateRuntime();
        await installStarted;

        const second = await manager.updateRuntime();
        expect(second.ok).toBe(false);
        expect(second.message).toBe("Update already in progress");

        finishInstall();
        await first;
      } finally {
        cleanup();
      }
    });

    it("reports updated packages when versions change", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0", "other-pkg": "^2.0.0" },
        installedVersions: {
          "some-pkg": "1.0.0",
          "other-pkg": "2.0.0",
        },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess(() => {
          // Simulate the install bumping some-pkg
          writeFileSync(
            join(dir, "node_modules", "some-pkg", "package.json"),
            JSON.stringify({ name: "some-pkg", version: "1.1.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(true);
        expect(result.restartRequired).toBe(true);
        expect(result.updatedPackages).toHaveLength(1);
        expect(result.updatedPackages![0]).toEqual({
          name: "some-pkg",
          from: "1.0.0",
          to: "1.1.0",
        });
        expect(result.message).toContain("Updated 1 package(s)");
        expect(result.message).toContain("Restart required");
      } finally {
        cleanup();
      }
    });

    it("pins pi runtime to the latest published version before install", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "@earendil-works/pi-coding-agent": "0.62.0" },
        installedVersions: { "@earendil-works/pi-coding-agent": "0.62.0" },
      });

      try {
        pointResolverAt(dir);
        global.fetch = vi.fn(async () => npmVersionResponse("0.63.0")) as typeof global.fetch;
        mockInstallSuccess(() => {
          writeFileSync(
            join(dir, "node_modules", "@earendil-works", "pi-coding-agent", "package.json"),
            JSON.stringify({ name: "@earendil-works/pi-coding-agent", version: "0.63.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();
        const pkgJson = JSON.parse(readFileSync(join(dir, "package.json"), "utf-8")) as {
          dependencies: Record<string, string>;
        };

        expect(pkgJson.dependencies["@earendil-works/pi-coding-agent"]).toBe("0.63.0");
        expect(result.ok).toBe(true);
        expect(result.pendingVersion).toBe("0.63.0");
        expect(result.updatedPackages).toContainEqual({
          name: "@earendil-works/pi-coding-agent",
          from: "0.62.0",
          to: "0.63.0",
        });
      } finally {
        cleanup();
      }
    });

    it("keeps direct pi companion packages aligned with the runtime package", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: {
          "@earendil-works/pi-coding-agent": "0.75.0",
          "@earendil-works/pi-ai": "0.75.0",
          "@earendil-works/pi-tui": "0.75.0",
        },
        installedVersions: {
          "@earendil-works/pi-coding-agent": "0.75.0",
          "@earendil-works/pi-ai": "0.75.0",
          "@earendil-works/pi-tui": "0.75.0",
        },
      });

      try {
        pointResolverAt(dir);
        global.fetch = vi.fn(async () => npmVersionResponse("0.75.4")) as typeof global.fetch;
        mockInstallSuccess(() => {
          for (const name of [
            "@earendil-works/pi-coding-agent",
            "@earendil-works/pi-ai",
            "@earendil-works/pi-tui",
          ]) {
            writeFileSync(
              join(dir, "node_modules", name, "package.json"),
              JSON.stringify({ name, version: "0.75.4" }),
            );
          }
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.75.0" });
        const result = await manager.updateRuntime();
        const pkgJson = JSON.parse(readFileSync(join(dir, "package.json"), "utf-8")) as {
          dependencies: Record<string, string>;
        };

        expect(pkgJson.dependencies["@earendil-works/pi-coding-agent"]).toBe("0.75.4");
        expect(pkgJson.dependencies["@earendil-works/pi-ai"]).toBe("0.75.4");
        expect(pkgJson.dependencies["@earendil-works/pi-tui"]).toBe("0.75.4");
        expect(result.updatedPackages).toEqual(
          expect.arrayContaining([
            { name: "@earendil-works/pi-coding-agent", from: "0.75.0", to: "0.75.4" },
            { name: "@earendil-works/pi-ai", from: "0.75.0", to: "0.75.4" },
            { name: "@earendil-works/pi-tui", from: "0.75.0", to: "0.75.4" },
          ]),
        );
      } finally {
        cleanup();
      }
    });

    it("migrates the runtime manifest from the legacy pi package name", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "@mariozechner/pi-coding-agent": "0.62.0" },
        installedVersions: { "@mariozechner/pi-coding-agent": "0.62.0" },
      });

      try {
        pointResolverAt(dir);
        global.fetch = vi.fn(async () => npmVersionResponse("0.62.0")) as typeof global.fetch;
        mockInstallSuccess(() => {
          mkdirSync(join(dir, "node_modules", "@earendil-works", "pi-coding-agent"), {
            recursive: true,
          });
          writeFileSync(
            join(dir, "node_modules", "@earendil-works", "pi-coding-agent", "package.json"),
            JSON.stringify({ name: "@earendil-works/pi-coding-agent", version: "0.62.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();
        const pkgJson = JSON.parse(readFileSync(join(dir, "package.json"), "utf-8")) as {
          dependencies: Record<string, string>;
        };

        expect(pkgJson.dependencies["@earendil-works/pi-coding-agent"]).toBe("0.62.0");
        expect(pkgJson.dependencies["@mariozechner/pi-coding-agent"]).toBeUndefined();
        expect(result.ok).toBe(true);
        expect(result.restartRequired).toBe(true);
        expect(result.pendingVersion).toBe("0.62.0");
        expect(result.message).toContain("Migrated runtime dependency");
      } finally {
        cleanup();
      }
    });

    it("reports all up to date when no versions changed", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess(); // No file changes

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(true);
        expect(result.restartRequired).toBe(false);
        expect(result.updatedPackages).toHaveLength(0);
        expect(result.message).toContain("up to date");
      } finally {
        cleanup();
      }
    });

    it("handles install failure gracefully", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallFailure("ERR! network timeout");

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(false);
        expect(result.error).toBe("install_failed");
        expect(result.restartRequired).toBe(false);
        expect(result.message).toContain("Update failed");
      } finally {
        cleanup();
      }
    });

    it("prefers stderr over stdout for error messages", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallFailure("npm ERR! 404 Not Found", "stdout noise");

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(false);
        // The execAsync function prefers stderr.trim() over stdout.trim()
        expect(result.message).toContain("npm ERR! 404 Not Found");
      } finally {
        cleanup();
      }
    });

    it("clears updateInProgress flag after failure", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallFailure("install failed");

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });

        // First update fails
        const result = await manager.updateRuntime();
        expect(result.ok).toBe(false);

        // Second update should NOT be rejected as "already in progress"
        const second = await manager.updateRuntime();
        expect(second.ok).toBe(false);
        expect(second.error).toBe("install_failed"); // Not "already in progress"
      } finally {
        cleanup();
      }
    });

    it("tracks lastUpdatedAt on status after successful update", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess();

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const before = Date.now();
        await manager.updateRuntime();
        const after = Date.now();

        const status = await manager.getStatus();
        expect(status.lastUpdatedAt).toBeGreaterThanOrEqual(before);
        expect(status.lastUpdatedAt).toBeLessThanOrEqual(after);
        expect(status.lastUpdateError).toBeUndefined();
      } finally {
        cleanup();
      }
    });

    it("tracks lastUpdateError on status after failed update", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallFailure("connection timed out");

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        const status = await manager.getStatus();
        expect(status.lastUpdateError).toBeDefined();
        expect(status.lastUpdateError).toContain("connection timed out");
      } finally {
        cleanup();
      }
    });

    it("sets restartRequired on status after packages were updated", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess(() => {
          writeFileSync(
            join(dir, "node_modules", "some-pkg", "package.json"),
            JSON.stringify({ name: "some-pkg", version: "1.2.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        const status = await manager.getStatus();
        expect(status.restartRequired).toBe(true);
      } finally {
        cleanup();
      }
    });
  });

  describe("resolvePackageManager (via updateRuntime)", () => {
    it("uses sibling npm next to OPPI_RUNTIME_BIN when available", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      const fakeBinDir = mkdtempSync(join(tmpdir(), "oppi-fakebin-"));
      try {
        pointResolverAt(dir);

        const fakeNode = join(fakeBinDir, "node");
        const fakeNpm = join(fakeBinDir, "npm");
        writeFileSync(fakeNode, "#!/bin/sh\nexit 0", { mode: 0o755 });
        writeFileSync(fakeNpm, "#!/bin/sh\nexit 0", { mode: 0o755 });
        process.env.OPPI_RUNTIME_BIN = fakeNode;

        let capturedBin = "";
        let capturedArgs: string[] = [];

        mockExecFile.mockImplementation(
          (bin: string, args: string[], _opts: unknown, cb: Function) => {
            capturedBin = bin;
            capturedArgs = args;
            cb(null, "", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        expect(capturedBin).toBe(fakeNpm);
        expect(capturedArgs).toContain("install");
        expect(capturedArgs).toContain("--omit=dev");
        expect(capturedArgs).toContain("--ignore-scripts");
        expect(capturedArgs).toContain("--no-audit");
        expect(capturedArgs).toContain("--no-fund");
      } finally {
        rmSync(fakeBinDir, { recursive: true, force: true });
        cleanup();
      }
    });

    it("always includes dependency hygiene flags for safety", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);

        let capturedArgs: string[] = [];
        mockExecFile.mockImplementation(
          (_bin: string, args: string[], _opts: unknown, cb: Function) => {
            capturedArgs = args;
            cb(null, "", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        expect(capturedArgs).toContain("--ignore-scripts");
        expect(capturedArgs).toContain("--no-audit");
        expect(capturedArgs).toContain("--no-fund");
      } finally {
        cleanup();
      }
    });

    it("includes install as the first arg", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);

        let capturedArgs: string[] = [];
        mockExecFile.mockImplementation(
          (_bin: string, args: string[], _opts: unknown, cb: Function) => {
            capturedArgs = args;
            cb(null, "", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        expect(capturedArgs[0]).toBe("install");
      } finally {
        cleanup();
      }
    });
  });

  describe("snapshotVersions (via updateRuntime diff)", () => {
    it("tracks versions from both dependencies and optionalDependencies", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "dep-a": "^1.0.0" },
        optionalDeps: { "opt-b": "^2.0.0" },
        installedVersions: {
          "dep-a": "1.0.0",
          "opt-b": "2.0.0",
        },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess(() => {
          writeFileSync(
            join(dir, "node_modules", "dep-a", "package.json"),
            JSON.stringify({ name: "dep-a", version: "1.1.0" }),
          );
          writeFileSync(
            join(dir, "node_modules", "opt-b", "package.json"),
            JSON.stringify({ name: "opt-b", version: "2.1.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(true);
        expect(result.updatedPackages).toHaveLength(2);

        const names = result.updatedPackages!.map((p) => p.name).sort();
        expect(names).toEqual(["dep-a", "opt-b"]);

        const depA = result.updatedPackages!.find((p) => p.name === "dep-a");
        expect(depA).toEqual({ name: "dep-a", from: "1.0.0", to: "1.1.0" });
      } finally {
        cleanup();
      }
    });

    it("ignores packages not installed in node_modules for the before snapshot", async () => {
      // dep-a is in package.json but NOT installed in node_modules
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "dep-a": "^1.0.0", "dep-b": "^2.0.0" },
        installedVersions: { "dep-b": "2.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess(() => {
          // Install dep-a fresh and bump dep-b
          mkdirSync(join(dir, "node_modules", "dep-a"), { recursive: true });
          writeFileSync(
            join(dir, "node_modules", "dep-a", "package.json"),
            JSON.stringify({ name: "dep-a", version: "1.0.0" }),
          );
          writeFileSync(
            join(dir, "node_modules", "dep-b", "package.json"),
            JSON.stringify({ name: "dep-b", version: "2.1.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(true);
        // dep-a had no before version, so it won't appear in the diff
        // Only dep-b should show as updated
        expect(result.updatedPackages).toHaveLength(1);
        expect(result.updatedPackages![0].name).toBe("dep-b");
      } finally {
        cleanup();
      }
    });

    it("handles scoped package names correctly", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "@earendil-works/pi-coding-agent": "^0.62.0" },
        installedVersions: { "@earendil-works/pi-coding-agent": "0.62.0" },
      });

      try {
        pointResolverAt(dir);
        mockInstallSuccess(() => {
          writeFileSync(
            join(dir, "node_modules", "@earendil-works", "pi-coding-agent", "package.json"),
            JSON.stringify({ name: "@earendil-works/pi-coding-agent", version: "0.63.0" }),
          );
        });

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(true);
        expect(result.updatedPackages).toHaveLength(1);
        expect(result.updatedPackages![0]).toEqual({
          name: "@earendil-works/pi-coding-agent",
          from: "0.62.0",
          to: "0.63.0",
        });
      } finally {
        cleanup();
      }
    });
  });

  describe("execAsync (via updateRuntime)", () => {
    it("passes cwd as the runtime directory", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);

        let capturedCwd = "";
        mockExecFile.mockImplementation(
          (_bin: string, _args: string[], opts: { cwd: string }, cb: Function) => {
            capturedCwd = opts.cwd;
            cb(null, "", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        expect(capturedCwd).toBe(dir);
      } finally {
        cleanup();
      }
    });

    it("sets a 120s timeout on the install command", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);

        let capturedTimeout = 0;
        mockExecFile.mockImplementation(
          (_bin: string, _args: string[], opts: { timeout: number }, cb: Function) => {
            capturedTimeout = opts.timeout;
            cb(null, "", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        await manager.updateRuntime();

        expect(capturedTimeout).toBe(120_000);
      } finally {
        cleanup();
      }
    });

    it("uses stdout when stderr is empty on error", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockExecFile.mockImplementation(
          (_bin: string, _args: string[], _opts: unknown, cb: Function) => {
            cb(new Error("generic"), "stdout has the details", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(false);
        expect(result.message).toContain("stdout has the details");
      } finally {
        cleanup();
      }
    });

    it("falls back to error.message when both stdout and stderr are empty", async () => {
      const { dir, cleanup } = makeFakeRuntimeDir({
        deps: { "some-pkg": "^1.0.0" },
        installedVersions: { "some-pkg": "1.0.0" },
      });

      try {
        pointResolverAt(dir);
        mockExecFile.mockImplementation(
          (_bin: string, _args: string[], _opts: unknown, cb: Function) => {
            cb(new Error("the underlying error"), "", "");
          },
        );

        const manager = new RuntimeUpdateManager({ currentVersion: "0.62.0" });
        const result = await manager.updateRuntime();

        expect(result.ok).toBe(false);
        expect(result.message).toContain("the underlying error");
      } finally {
        cleanup();
      }
    });
  });
});

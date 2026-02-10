/**
 * Workspace container lifecycle tests.
 *
 * Tests the SandboxManager workspace container tracking map — ensures
 * container IDs are stable per workspace, isRunningWorkspace reflects
 * the running set, and stop/cleanup correctly mutate tracking state.
 *
 * Uses vitest module mocking to intercept execSync/spawn calls that
 * would otherwise try to talk to a real Apple container runtime.
 */

import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Mock child_process before importing SandboxManager.
vi.mock("node:child_process", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    execSync: vi.fn((_cmd: string) => ""),
    spawn: vi.fn((_cmd: string, _args: string[]) => {
      return {
        pid: 9999,
        stdin: { write: vi.fn() },
        stdout: { on: vi.fn() },
        stderr: { on: vi.fn() },
        on: vi.fn(),
        kill: vi.fn(),
        killed: false,
      };
    }),
  };
});

import { SandboxManager } from "../src/sandbox.js";
import { execSync } from "node:child_process";

const mockedExecSync = vi.mocked(execSync);

let tmp: string;
let sandbox: SandboxManager;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "pi-remote-ws-container-test-"));
  sandbox = new SandboxManager({
    sandboxBaseDir: tmp,
    uvCacheDir: join(tmp, "uv-cache"),
    image: "test-image:latest",
  });
  vi.clearAllMocks();
});

afterEach(() => {
  rmSync(tmp, { recursive: true, force: true });
});

describe("SandboxManager workspace container tracking", () => {
  it("isRunningWorkspace returns false for untracked workspace", () => {
    expect(sandbox.isRunningWorkspace("u1", "w1")).toBe(false);
  });

  it("stopWorkspaceContainer is safe to call on untracked workspace", async () => {
    // Should not throw — just attempts to stop by conventional name.
    await sandbox.stopWorkspaceContainer("u1", "w1");
    expect(sandbox.isRunningWorkspace("u1", "w1")).toBe(false);
  });

  it("stopAll clears all tracked workspace containers", async () => {
    // Manually inject tracking entries (simulating ensureWorkspaceContainer).
    const running = (sandbox as unknown as { running: Map<string, { containerId: string }> }).running;
    running.set("u1/w1", { containerId: "pi-remote-ws-u1-w1" });
    running.set("u1/w2", { containerId: "pi-remote-ws-u1-w2" });

    expect(sandbox.isRunningWorkspace("u1", "w1")).toBe(true);
    expect(sandbox.isRunningWorkspace("u1", "w2")).toBe(true);

    await sandbox.stopAll();

    expect(sandbox.isRunningWorkspace("u1", "w1")).toBe(false);
    expect(sandbox.isRunningWorkspace("u1", "w2")).toBe(false);
    expect(running.size).toBe(0);
  });

  it("stopWorkspaceContainer removes only the targeted workspace", async () => {
    const running = (sandbox as unknown as { running: Map<string, { containerId: string }> }).running;
    running.set("u1/w1", { containerId: "pi-remote-ws-u1-w1" });
    running.set("u1/w2", { containerId: "pi-remote-ws-u1-w2" });

    await sandbox.stopWorkspaceContainer("u1", "w1");

    expect(sandbox.isRunningWorkspace("u1", "w1")).toBe(false);
    expect(sandbox.isRunningWorkspace("u1", "w2")).toBe(true);
  });

  it("cleanupOrphanedContainers stops containers not in tracking map", async () => {
    // Simulate `container list` output with two workspace containers.
    mockedExecSync.mockImplementation((cmd: string) => {
      if (typeof cmd === "string" && cmd === "container list") {
        return [
          "CONTAINER ID  IMAGE  COMMAND  CREATED  STATUS  PORTS  NAMES",
          "pi-remote-ws-u1-w1 test-image:latest  sh  2m ago  Up  -  pi-remote-ws-u1-w1",
          "pi-remote-ws-u1-orphan test-image:latest  sh  5m ago  Up  -  pi-remote-ws-u1-orphan",
        ].join("\n");
      }
      return "";
    });

    // Only track w1, so w1-orphan should be stopped.
    const running = (sandbox as unknown as { running: Map<string, { containerId: string }> }).running;
    running.set("u1/w1", { containerId: "pi-remote-ws-u1-w1" });

    await sandbox.cleanupOrphanedContainers();

    // Should have tried to stop the orphan.
    const stopCalls = mockedExecSync.mock.calls.filter(
      (call) => typeof call[0] === "string" && (call[0] as string).includes("container stop pi-remote-ws-u1-orphan"),
    );
    expect(stopCalls.length).toBeGreaterThan(0);
  });

  it("cleanupOrphanedContainers also catches legacy session containers", async () => {
    mockedExecSync.mockImplementation((cmd: string) => {
      if (typeof cmd === "string" && cmd === "container list") {
        return [
          "CONTAINER ID  IMAGE  COMMAND  CREATED  STATUS  PORTS  NAMES",
          "pi-remote-legacy-session test-image:latest  pi  2m ago  Up  -  pi-remote-legacy-session",
        ].join("\n");
      }
      return "";
    });

    await sandbox.cleanupOrphanedContainers();

    const stopCalls = mockedExecSync.mock.calls.filter(
      (call) => typeof call[0] === "string" && (call[0] as string).includes("container stop pi-remote-legacy-session"),
    );
    expect(stopCalls.length).toBeGreaterThan(0);
  });
});

describe("SandboxManager workspace path generation", () => {
  it("getWorkspaceDir returns expected path", () => {
    expect(sandbox.getWorkspaceDir("u1", "w1")).toBe(join(tmp, "u1", "w1"));
  });

  it("getSessionRootDir nests under workspace/sessions/", () => {
    expect(sandbox.getSessionRootDir("u1", "w1", "s1")).toBe(
      join(tmp, "u1", "w1", "sessions", "s1"),
    );
  });

  it("getWorkDir creates and returns workspace/workspace/ directory", () => {
    const workDir = sandbox.getWorkDir("u1", "s1", "w1");
    expect(workDir).toBe(join(tmp, "u1", "w1", "workspace"));
  });

  it("getWorkDir with legacy session-scoped fallback (no workspaceId)", () => {
    const workDir = sandbox.getWorkDir("u1", "s1");
    expect(workDir).toBe(join(tmp, "u1", "s1", "workspace"));
  });
});

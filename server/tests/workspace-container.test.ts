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
        stdin: { write: vi.fn(), writable: true },
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
  tmp = mkdtempSync(join(tmpdir(), "oppi-server-ws-container-test-"));
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
    expect(sandbox.isRunningWorkspace("w1")).toBe(false);
  });

  it("stopWorkspaceContainer is safe to call on untracked workspace", async () => {
    // Should not throw — just attempts to stop by conventional name.
    await sandbox.stopWorkspaceContainer("w1");
    expect(sandbox.isRunningWorkspace("w1")).toBe(false);
  });

  it("stopAll clears all tracked workspace containers", async () => {
    // Manually inject tracking entries (simulating ensureWorkspaceContainer).
    const running = (sandbox as unknown as { running: Map<string, { containerId: string }> }).running;
    running.set("w1", { containerId: "oppi-server-ws-w1" });
    running.set("w2", { containerId: "oppi-server-ws-w2" });

    expect(sandbox.isRunningWorkspace("w1")).toBe(true);
    expect(sandbox.isRunningWorkspace("w2")).toBe(true);

    await sandbox.stopAll();

    expect(sandbox.isRunningWorkspace("w1")).toBe(false);
    expect(sandbox.isRunningWorkspace("w2")).toBe(false);
    expect(running.size).toBe(0);
  });

  it("stopWorkspaceContainer removes only the targeted workspace", async () => {
    const running = (sandbox as unknown as { running: Map<string, { containerId: string }> }).running;
    running.set("w1", { containerId: "oppi-server-ws-w1" });
    running.set("w2", { containerId: "oppi-server-ws-w2" });

    await sandbox.stopWorkspaceContainer("w1");

    expect(sandbox.isRunningWorkspace("w1")).toBe(false);
    expect(sandbox.isRunningWorkspace("w2")).toBe(true);
  });

  it("cleanupOrphanedContainers stops containers not in tracking map", async () => {
    // Simulate `container list` output with two workspace containers.
    mockedExecSync.mockImplementation((cmd: string) => {
      if (typeof cmd === "string" && cmd === "container list") {
        return [
          "CONTAINER ID  IMAGE  COMMAND  CREATED  STATUS  PORTS  NAMES",
          "oppi-server-ws-w1 test-image:latest  sh  2m ago  Up  -  oppi-server-ws-w1",
          "oppi-server-ws-orphan test-image:latest  sh  5m ago  Up  -  oppi-server-ws-orphan",
        ].join("\n");
      }
      return "";
    });

    // Only track w1, so orphan should be stopped.
    const running = (sandbox as unknown as { running: Map<string, { containerId: string }> }).running;
    running.set("w1", { containerId: "oppi-server-ws-w1" });

    await sandbox.cleanupOrphanedContainers();

    // Should have tried to stop the orphan.
    const stopCalls = mockedExecSync.mock.calls.filter(
      (call) => typeof call[0] === "string" && (call[0] as string).includes("container stop oppi-server-ws-orphan"),
    );
    expect(stopCalls.length).toBeGreaterThan(0);
  });

  it("reuses canonical workspace container after restart", () => {
    mockedExecSync.mockImplementation((cmd: string) => {
      if (typeof cmd === "string" && cmd === "container list") {
        return [
          "CONTAINER ID  IMAGE  COMMAND  CREATED  STATUS  PORTS  NAMES",
          "oppi-server-ws-w1 test-image:latest  sh  2m ago  Up  -  oppi-server-ws-w1",
        ].join("\n");
      }
      return "";
    });

    const ensureWorkspaceContainer = (
      sandbox as unknown as {
        ensureWorkspaceContainer: (
          workspaceId: string,
          workMount: string,
          workspaceRootMount: string,
        ) => string;
      }
    ).ensureWorkspaceContainer;

    const containerId = ensureWorkspaceContainer.call(
      sandbox,
      "w1",
      "/tmp/work",
      "/tmp/workspace",
    );
    expect(containerId).toBe("oppi-server-ws-w1");
    expect(sandbox.isRunningWorkspace("w1")).toBe(true);
  });

  it("stopWorkspaceContainer tries canonical name when untracked", async () => {
    await sandbox.stopWorkspaceContainer("w1");

    const commands = mockedExecSync.mock.calls
      .map((call) => (typeof call[0] === "string" ? call[0] : ""))
      .join("\n");

    expect(commands).toContain("container stop oppi-server-ws-w1");
  });
});

describe("SandboxManager workspace path generation", () => {
  it("getWorkspaceDir returns expected path", () => {
    expect(sandbox.getWorkspaceDir("w1")).toBe(join(tmp, "w1"));
  });

  it("getSessionRootDir nests under workspace/sessions/", () => {
    expect(sandbox.getSessionRootDir("w1", "s1")).toBe(
      join(tmp, "w1", "sessions", "s1"),
    );
  });

  it("getWorkDir creates and returns workspace/workspace/ directory", () => {
    const workDir = sandbox.getWorkDir("w1");
    expect(workDir).toBe(join(tmp, "w1", "workspace"));
  });

});

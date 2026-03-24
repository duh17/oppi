/**
 * Live Gondolin VM integration test.
 *
 * Boots a real QEMU micro-VM and verifies:
 * 1. Bash command execution works inside the VM
 * 2. Host filesystem outside /workspace is not accessible
 * 3. Files written to /workspace are visible from host VFS
 * 4. Environment variables are set correctly
 *
 * Requires QEMU installed (brew install qemu).
 * First run downloads ~200MB guest assets (cached).
 * VM boot takes ~5-15s depending on cache state.
 *
 * Skipped automatically if QEMU is not available.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isQemuAvailable, GondolinManager, type VmFactoryOptions } from "../src/gondolin-manager.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import {
  createGondolinBashOps,
  createGondolinReadOps,
  createGondolinWriteOps,
  toGuestPath,
  GUEST_WORKSPACE,
} from "../src/gondolin-ops.js";

// ─── Skip if QEMU not available ───

let qemuAvailable = false;

beforeAll(async () => {
  qemuAvailable = await isQemuAvailable();
  if (!qemuAvailable) {
    console.log("[gondolin-live] Skipping: QEMU not installed");
  }
}, 10_000);

describe("Gondolin live VM", { timeout: 120_000 }, () => {
  let hostDir: string;
  let manager: GondolinManager;
  let vm: GondolinVm;

  beforeAll(async () => {
    if (!qemuAvailable) return;

    hostDir = mkdtempSync(join(tmpdir(), "gondolin-live-"));

    // Seed a test file on the host side
    writeFileSync(join(hostDir, "host-file.txt"), "hello from host");
    mkdirSync(join(hostDir, "subdir"));
    writeFileSync(join(hostDir, "subdir", "nested.txt"), "nested content");

    manager = new GondolinManager();

    const workspace = {
      id: "live-test",
      name: "Live Test",
      skills: [] as string[],
      runtime: "sandbox" as const,
      sandboxConfig: { allowedHosts: [] as string[] },
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    vm = await manager.ensureWorkspaceVm(workspace, hostDir);
  }, 90_000); // VM boot can take up to 60s on first run

  afterAll(async () => {
    if (manager) await manager.stopAll();
    if (hostDir) rmSync(hostDir, { recursive: true, force: true });
  }, 30_000);

  // ─── Bash operations ───

  it("executes a simple command", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec("echo hello-from-vm");
    expect(result.ok).toBe(true);
    expect(result.stdout.trim()).toBe("hello-from-vm");
  });

  it("runs commands in the guest /workspace directory", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec("pwd", { cwd: GUEST_WORKSPACE });
    expect(result.ok).toBe(true);
    expect(result.stdout.trim()).toBe(GUEST_WORKSPACE);
  });

  it("can see host files mounted at /workspace", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`cat ${GUEST_WORKSPACE}/host-file.txt`);
    expect(result.ok).toBe(true);
    expect(result.stdout.trim()).toBe("hello from host");
  });

  it("can see nested host files", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`cat ${GUEST_WORKSPACE}/subdir/nested.txt`);
    expect(result.ok).toBe(true);
    expect(result.stdout.trim()).toBe("nested content");
  });

  it("cannot access host files outside /workspace", async () => {
    if (!qemuAvailable) return;

    // /etc/hostname exists on host but not relevant — check that host-specific paths fail
    const result = await vm.exec(`cat /Users/test/secret.txt 2>&1 || true`);
    // The path shouldn't exist in the VM
    expect(result.stdout).toContain("No such file");
  });

  it("returns non-zero exit code for failed commands", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec("exit 42");
    expect(result.ok).toBe(false);
    expect(result.exitCode).toBe(42);
  });

  // ─── Read operations ───

  it("reads files via ReadOperations", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinReadOps(vm, hostDir);
    const content = await ops.readFile(join(hostDir, "host-file.txt"));
    expect(content.toString()).toBe("hello from host");
  });

  it("access succeeds for existing file", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinReadOps(vm, hostDir);
    await expect(ops.access(join(hostDir, "host-file.txt"))).resolves.toBeUndefined();
  });

  it("access throws for missing file", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinReadOps(vm, hostDir);
    await expect(ops.access(join(hostDir, "nonexistent.txt"))).rejects.toThrow(/ENOENT/);
  });

  // ─── Write operations ───

  it("writes files via WriteOperations", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinWriteOps(vm, hostDir);
    await ops.writeFile(join(hostDir, "vm-created.txt"), "written by VM");

    // Verify via VM read
    const readResult = await vm.exec(`cat ${GUEST_WORKSPACE}/vm-created.txt`);
    expect(readResult.stdout.trim()).toBe("written by VM");
  });

  it("creates directories via mkdir", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinWriteOps(vm, hostDir);
    await ops.mkdir(join(hostDir, "new", "deep", "dir"));

    const result = await vm.exec(`test -d ${GUEST_WORKSPACE}/new/deep/dir && echo exists`);
    expect(result.stdout.trim()).toBe("exists");
  });

  // ─── Bash operations via ops interface ───

  it("bash ops execute and stream output", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinBashOps(vm, hostDir);
    const chunks: Buffer[] = [];
    const result = await ops.exec("echo streaming-test", hostDir, {
      onData: (data) => chunks.push(data),
    });

    expect(result.exitCode).toBe(0);
    const output = Buffer.concat(chunks).toString();
    expect(output).toContain("streaming-test");
  });

  // ─── VM reuse ───

  it("reuses existing VM for same workspace", async () => {
    if (!qemuAvailable) return;

    expect(manager.isRunning("live-test")).toBe(true);

    // Getting VM again should return same instance (no new boot)
    const workspace = {
      id: "live-test",
      name: "Live Test",
      skills: [] as string[],
      runtime: "sandbox" as const,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
    const vm2 = await manager.ensureWorkspaceVm(workspace, hostDir);
    expect(vm2).toBe(vm);
  });
});

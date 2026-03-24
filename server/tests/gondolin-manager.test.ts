import { afterEach, describe, it, expect, vi } from "vitest";
import { GondolinManager, type VmFactory, type VmFactoryOptions } from "../src/gondolin-manager.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import type { Workspace } from "../src/types.js";

// ─── Helpers ───

function makeWorkspace(overrides: Partial<Workspace> & { id: string } = { id: "w1" }): Workspace & {
  runtime?: "host" | "sandbox";
  sandboxConfig?: { allowedHosts?: string[] };
} {
  const now = Date.now();
  return {
    name: "test",
    skills: [],
    systemPromptMode: "append" as const,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

function makeMockVm(): GondolinVm & { close: ReturnType<typeof vi.fn>; stopped: boolean } {
  const vm = {
    stopped: false,
    exec: vi.fn(() => ({
      exitCode: Promise.resolve(0),
      stdout: Buffer.alloc(0),
      stderr: Buffer.alloc(0),
      stdoutBuffer: Promise.resolve(Buffer.alloc(0)),
      ok: Promise.resolve(true),
      output: () => ({
        async *[Symbol.asyncIterator]() {
          /* empty */
        },
      }),
    })),
    close: vi.fn(async () => {
      vm.stopped = true;
    }),
  };
  return vm;
}

function makeFactory(): {
  factory: VmFactory;
  calls: VmFactoryOptions[];
  vms: Array<GondolinVm & { close(): Promise<void> }>;
} {
  const calls: VmFactoryOptions[] = [];
  const vms: Array<GondolinVm & { close(): Promise<void> }> = [];
  const factory: VmFactory = async (options) => {
    calls.push(options);
    const vm = makeMockVm();
    vms.push(vm);
    return vm;
  };
  return { factory, calls, vms };
}

// ─── GondolinManager ───

describe("GondolinManager", () => {
  let manager: GondolinManager;

  afterEach(async () => {
    if (manager) await manager.stopAll();
  });

  it("creates VM on first ensureWorkspaceVm call", async () => {
    const { factory, calls, vms } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    const vm = await manager.ensureWorkspaceVm(ws, "/home/user/project");

    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual({
      hostCwd: "/home/user/project",
      allowedHosts: ["*"],
    });
    expect(vm).toBe(vms[0]);
  });

  it("returns same VM for repeated calls with same workspace", async () => {
    const { factory, calls } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    const vm1 = await manager.ensureWorkspaceVm(ws, "/home/user/project");
    const vm2 = await manager.ensureWorkspaceVm(ws, "/home/user/project");

    expect(vm1).toBe(vm2);
    expect(calls).toHaveLength(1);
  });

  it("creates separate VMs for different workspaces", async () => {
    const { factory, calls, vms } = makeFactory();
    manager = new GondolinManager(factory);

    const ws1 = makeWorkspace({ id: "w1" });
    const ws2 = makeWorkspace({ id: "w2" });
    const vm1 = await manager.ensureWorkspaceVm(ws1, "/path/a");
    const vm2 = await manager.ensureWorkspaceVm(ws2, "/path/b");

    expect(vm1).not.toBe(vm2);
    expect(calls).toHaveLength(2);
    expect(vms).toHaveLength(2);
  });

  it("coalesces concurrent startup calls for same workspace", async () => {
    const { factory, calls } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    const [vm1, vm2, vm3] = await Promise.all([
      manager.ensureWorkspaceVm(ws, "/path"),
      manager.ensureWorkspaceVm(ws, "/path"),
      manager.ensureWorkspaceVm(ws, "/path"),
    ]);

    expect(vm1).toBe(vm2);
    expect(vm2).toBe(vm3);
    expect(calls).toHaveLength(1);
  });

  it("passes allowedHosts from sandboxConfig", async () => {
    const { factory, calls } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({
      id: "w1",
      sandboxConfig: { allowedHosts: ["api.example.com", "cdn.example.com"] },
    });
    await manager.ensureWorkspaceVm(ws, "/path");

    expect(calls[0].allowedHosts).toEqual(["api.example.com", "cdn.example.com"]);
  });

  it("defaults allowedHosts to wildcard", async () => {
    const { factory, calls } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    await manager.ensureWorkspaceVm(ws, "/path");

    expect(calls[0].allowedHosts).toEqual(["*"]);
  });
});

describe("stopWorkspaceVm", () => {
  it("stops and removes VM", async () => {
    const { factory, vms } = makeFactory();
    const manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    await manager.ensureWorkspaceVm(ws, "/path");

    expect(manager.isRunning("w1")).toBe(true);
    await manager.stopWorkspaceVm("w1");

    expect(manager.isRunning("w1")).toBe(false);
    expect(manager.getVm("w1")).toBeUndefined();
    expect(vms[0].close).toHaveBeenCalledOnce();
  });

  it("is a no-op for unknown workspace", async () => {
    const { factory } = makeFactory();
    const manager = new GondolinManager(factory);

    // Should not throw
    await expect(manager.stopWorkspaceVm("nonexistent")).resolves.toBeUndefined();
  });

  it("allows re-creating VM after stop", async () => {
    const { factory, calls } = makeFactory();
    const manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    const vm1 = await manager.ensureWorkspaceVm(ws, "/path");
    await manager.stopWorkspaceVm("w1");
    const vm2 = await manager.ensureWorkspaceVm(ws, "/path");

    expect(vm1).not.toBe(vm2);
    expect(calls).toHaveLength(2);

    await manager.stopAll();
  });
});

describe("stopAll", () => {
  it("stops all running VMs", async () => {
    const { factory, vms } = makeFactory();
    const manager = new GondolinManager(factory);

    const ws1 = makeWorkspace({ id: "w1" });
    const ws2 = makeWorkspace({ id: "w2" });
    await manager.ensureWorkspaceVm(ws1, "/a");
    await manager.ensureWorkspaceVm(ws2, "/b");

    expect(manager.isRunning("w1")).toBe(true);
    expect(manager.isRunning("w2")).toBe(true);

    await manager.stopAll();

    expect(manager.isRunning("w1")).toBe(false);
    expect(manager.isRunning("w2")).toBe(false);
    expect(vms[0].close).toHaveBeenCalledOnce();
    expect(vms[1].close).toHaveBeenCalledOnce();
  });

  it("handles stop errors gracefully", async () => {
    const factory: VmFactory = async () => ({
      exec: vi.fn() as unknown as GondolinVm["exec"],
      close: vi.fn(async () => {
        throw new Error("boom");
      }),
    });
    const manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    await manager.ensureWorkspaceVm(ws, "/path");

    // Should not throw despite stop() error
    await expect(manager.stopAll()).resolves.toBeUndefined();
    expect(manager.isRunning("w1")).toBe(false);
  });
});

describe("isRunning / getVm", () => {
  it("returns false / undefined before VM is created", () => {
    const { factory } = makeFactory();
    const manager = new GondolinManager(factory);

    expect(manager.isRunning("w1")).toBe(false);
    expect(manager.getVm("w1")).toBeUndefined();
  });

  it("returns true / VM after creation", async () => {
    const { factory, vms } = makeFactory();
    const manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    await manager.ensureWorkspaceVm(ws, "/path");

    expect(manager.isRunning("w1")).toBe(true);
    expect(manager.getVm("w1")).toBe(vms[0]);

    await manager.stopAll();
  });
});

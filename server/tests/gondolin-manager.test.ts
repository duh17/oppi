import { afterEach, describe, it, expect, vi } from "vitest";
import { lstatSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHttpHooks, ReadonlyProvider, VM } from "@earendil-works/gondolin";
import {
  buildVmHttpHooks,
  defaultVmFactory,
  GondolinManager,
  isQemuAvailable,
  shouldShadowSandboxWorkspacePath,
  withSandboxPiOverlayMounts,
  WORKSPACE_VM_IDLE_TEARDOWN_MS,
  type IdleTeardownScheduler,
  type VmFactory,
  type VmFactoryOptions,
} from "../src/gondolin-manager.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import type { Workspace } from "../src/types.js";

const SANDBOX_PI_OVERLAY_HOST_DIR = join(tmpdir(), "oppi-sandbox-pi-overlay");

vi.mock("@earendil-works/gondolin", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@earendil-works/gondolin")>();
  return {
    ...actual,
    VM: {
      ...actual.VM,
      create: vi.fn(),
    },
  };
});

// ─── Helpers ───

function makeWorkspace(overrides: Partial<Workspace> & { id: string } = { id: "w1" }): Workspace {
  const now = Date.now();
  return {
    name: "test",
    systemPromptMode: "append" as const,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

function makeMockVm(): GondolinVm & { close: ReturnType<typeof vi.fn>; stopped: boolean } {
  const vm = {
    stopped: false,
    fs: {
      access: vi.fn(async () => undefined),
      mkdir: vi.fn(async () => undefined),
      readFile: vi.fn(async () => Buffer.alloc(0)),
      writeFile: vi.fn(async () => undefined),
    },
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

describe("withSandboxPiOverlayMounts", () => {
  it("prepends a .pi overlay when skill mounts sit under workspace .pi", () => {
    const guestWorkspacePath = "/workspace/slug";
    const workspaceHostPi = join("/tmp/oppi-sandbox-ws", ".pi");
    const mounts = withSandboxPiOverlayMounts(guestWorkspacePath, [
      {
        hostPath: "/host/skills/review",
        guestPath: "/workspace/slug/.pi/skills/review",
      },
    ]);

    expect(mounts[0]).toEqual({
      hostPath: SANDBOX_PI_OVERLAY_HOST_DIR,
      guestPath: `${guestWorkspacePath}/.pi`,
    });
    expect(mounts[0]).not.toEqual(expect.objectContaining({ hostPath: workspaceHostPi }));
    expect(mounts).toEqual([
      {
        hostPath: SANDBOX_PI_OVERLAY_HOST_DIR,
        guestPath: `${guestWorkspacePath}/.pi`,
      },
      {
        hostPath: "/host/skills/review",
        guestPath: "/workspace/slug/.pi/skills/review",
      },
    ]);

    const overlay = lstatSync(SANDBOX_PI_OVERLAY_HOST_DIR);
    expect(overlay.isSymbolicLink()).toBe(false);
    expect(overlay.isDirectory()).toBe(true);
    expect(overlay.mode & 0o777).toBe(0o700);
    const uid = process.getuid?.();
    if (uid !== undefined) expect(overlay.uid).toBe(uid);
  });

  it("leaves mounts unchanged when no skill mounts live under workspace .pi", () => {
    const mounts = [
      { hostPath: "/host/extensions", guestPath: "/tmp/oppi-agent-extensions" },
    ];
    expect(withSandboxPiOverlayMounts("/workspace/slug", mounts)).toEqual(mounts);
  });

  it("leaves mounts unchanged when a .pi overlay is already present", () => {
    const existing = [
      { hostPath: "/host/pi", guestPath: "/workspace/slug/.pi" },
      { hostPath: "/host/skills/review", guestPath: "/workspace/slug/.pi/skills/review" },
    ];
    expect(withSandboxPiOverlayMounts("/workspace/slug", existing)).toEqual(existing);
  });
});

// ─── defaultVmFactory ───

describe("defaultVmFactory", () => {
  it("passes allowWebSockets: false into VM.create", async () => {
    const vm = {
      exec: vi.fn(async () => ({ stdout: "/bin/bash\n" })),
    };
    vi.mocked(VM.create).mockResolvedValue(vm as never);

    await defaultVmFactory({ hostCwd: "/tmp/oppi-sandbox-f6" });

    expect(VM.create).toHaveBeenCalledWith(
      expect.objectContaining({
        allowWebSockets: false,
        maxHttpBodyBytes: 64 * 1024 * 1024,
        maxHttpResponseBodyBytes: 64 * 1024 * 1024,
      }),
    );
  });

  it("overlays guest .pi so shadowed workspace .pi still exposes skill mounts", async () => {
    const vm = {
      exec: vi.fn(async () => ({ stdout: "/bin/bash\n" })),
    };
    vi.mocked(VM.create).mockResolvedValue(vm as never);

    const guestWorkspacePath = "/workspace/deep-research";
    const overlayGuestPath = `${guestWorkspacePath}/.pi`;
    const skillMount = {
      hostPath: "/tmp/oppi-skill-deep-research",
      guestPath: `${overlayGuestPath}/skills/deep-research`,
    };

    await defaultVmFactory({
      hostCwd: "/tmp/oppi-sandbox-ws",
      guestWorkspacePath,
      readonlyMounts: [skillMount],
    });

    const mounts = vi.mocked(VM.create).mock.calls.at(-1)?.[0]?.vfs?.mounts ?? {};
    expect(Object.keys(mounts)).toEqual(
      expect.arrayContaining([
        guestWorkspacePath,
        overlayGuestPath,
        skillMount.guestPath,
      ]),
    );
    expect(overlayGuestPath).toBe("/workspace/deep-research/.pi");
    const overlay = mounts[overlayGuestPath] as InstanceType<typeof ReadonlyProvider>;
    expect(overlay).toBeInstanceOf(ReadonlyProvider);
    expect(overlay.readonly).toBe(true);
  });

  it("does not invent a .pi overlay when no skill mounts live under it", async () => {
    const vm = {
      exec: vi.fn(async () => ({ stdout: "/bin/bash\n" })),
    };
    vi.mocked(VM.create).mockResolvedValue(vm as never);

    const guestWorkspacePath = "/workspace/deep-research";
    await defaultVmFactory({
      hostCwd: "/tmp/oppi-sandbox-ws",
      guestWorkspacePath,
      readonlyMounts: ["/tmp/oppi-agent-extensions"],
    });

    const mounts = vi.mocked(VM.create).mock.calls.at(-1)?.[0]?.vfs?.mounts ?? {};
    expect(Object.keys(mounts)).toEqual([guestWorkspacePath, "/tmp/oppi-agent-extensions"]);
    expect(mounts[`${guestWorkspacePath}/.pi`]).toBeUndefined();
  });
});

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
    expect(calls[0].hostCwd).toBe("/home/user/project");
    expect(calls[0].allowedHosts).toBeUndefined();
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

  it("leaves allowedHosts undefined by default to follow Gondolin", async () => {
    const { factory, calls } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    await manager.ensureWorkspaceVm(ws, "/path");

    expect(calls[0].allowedHosts).toBeUndefined();
  });

  it("labels the VM with the workspace id for gondolin list", async () => {
    const { factory, calls } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "ws-label" });
    await manager.ensureWorkspaceVm(ws, "/path");

    expect(calls[0].sessionLabel).toBe("ws-label");
  });
});

describe("workspace VM fingerprint reuse", () => {
  let manager: GondolinManager;

  afterEach(async () => {
    if (manager) await manager.stopAll();
  });

  it.each([
    {
      name: "allowedHosts",
      first: { sandboxConfig: { allowedHosts: ["api.example.com"] } },
      firstCwd: "/path",
      second: { sandboxConfig: { allowedHosts: ["cdn.example.com"] } },
      secondCwd: "/path",
    },
    {
      name: "hostCwd",
      first: {},
      firstCwd: "/path/a",
      second: {},
      secondCwd: "/path/b",
    },
  ])(
    "closes the old VM and boots a new one when $name changes",
    async ({ first, firstCwd, second, secondCwd }) => {
      const { factory, calls, vms } = makeFactory();
      manager = new GondolinManager(factory);

      const firstWs = makeWorkspace({ id: "w1", ...first });
      const firstVm = await manager.ensureWorkspaceVm(firstWs, firstCwd);
      const secondWs = makeWorkspace({ id: "w1", ...second });
      const secondVm = await manager.ensureWorkspaceVm(secondWs, secondCwd);

      expect(firstVm).toBe(vms[0]);
      expect(secondVm).toBe(vms[1]);
      expect(secondVm).not.toBe(firstVm);
      expect(vms[0].close).toHaveBeenCalledOnce();
      expect(calls).toHaveLength(2);
      expect(manager.getVm("w1")).toBe(vms[1]);
    },
  );

  it("reuses the VM when the fingerprint is unchanged", async () => {
    const { factory, calls, vms } = makeFactory();
    manager = new GondolinManager(factory);

    const firstWs = makeWorkspace({
      id: "w1",
      sandboxConfig: { allowedHosts: ["api.example.com"], env: { FOO: "1" } },
    });
    const mounts = [
      { hostPath: "/skills/b", guestPath: "/guest/b" },
      { hostPath: "/skills/a", guestPath: "/guest/a" },
    ];
    const firstVm = await manager.ensureWorkspaceVm(
      firstWs,
      "/path",
      undefined,
      mounts,
      { FOO: "1" },
      "/workspace/slug",
    );

    const secondWs = makeWorkspace({
      id: "w1",
      sandboxConfig: { allowedHosts: ["api.example.com"], env: { FOO: "1" } },
    });
    const reorderedMounts = [
      { hostPath: "/skills/a", guestPath: "/guest/a" },
      { hostPath: "/skills/b", guestPath: "/guest/b" },
    ];
    const secondVm = await manager.ensureWorkspaceVm(
      secondWs,
      "/path",
      undefined,
      reorderedMounts,
      { FOO: "1" },
      "/workspace/slug",
    );

    expect(secondVm).toBe(firstVm);
    expect(vms[0].close).not.toHaveBeenCalled();
    expect(calls).toHaveLength(1);
  });

  it("closes the old VM when extraEnv changes", async () => {
    const { factory, vms } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({ id: "w1" });
    const firstVm = await manager.ensureWorkspaceVm(ws, "/path", undefined, undefined, {
      FOO: "1",
    });
    const afterEnv = await manager.ensureWorkspaceVm(ws, "/path", undefined, undefined, {
      FOO: "2",
    });

    expect(afterEnv).not.toBe(firstVm);
    expect(vms[0].close).toHaveBeenCalledOnce();
    expect(manager.getVm("w1")).toBe(vms[1]);
  });

  it("reuses the live VM when only readonlyMounts differ", async () => {
    const { factory, calls, vms } = makeFactory();
    manager = new GondolinManager(factory);

    const ws = makeWorkspace({
      id: "w1",
      sandboxConfig: { allowedHosts: ["api.example.com"] },
    });
    const firstVm = await manager.ensureWorkspaceVm(
      ws,
      "/path",
      undefined,
      [{ hostPath: "/skills/agent-a", guestPath: "/workspace/slug/.pi/skills/a" }],
      { FOO: "1" },
      "/workspace/slug",
    );
    const secondVm = await manager.ensureWorkspaceVm(
      ws,
      "/path",
      undefined,
      [{ hostPath: "/skills/agent-b", guestPath: "/workspace/slug/.pi/skills/b" }],
      { FOO: "1" },
      "/workspace/slug",
    );

    expect(secondVm).toBe(firstVm);
    expect(vms[0].close).not.toHaveBeenCalled();
    expect(calls).toHaveLength(1);
    expect(manager.getVm("w1")).toBe(firstVm);
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

function makeIdleScheduler(): {
  schedule: IdleTeardownScheduler;
  fire: (index?: number) => Promise<void>;
  delays: number[];
  cancelled: boolean[];
} {
  const callbacks: Array<() => void | Promise<void>> = [];
  const delays: number[] = [];
  const cancelled: boolean[] = [];
  const schedule: IdleTeardownScheduler = (callback, delayMs) => {
    const index = callbacks.length;
    callbacks.push(callback);
    delays.push(delayMs);
    cancelled.push(false);
    return {
      cancel: () => {
        cancelled[index] = true;
      },
    };
  };
  return {
    schedule,
    fire: async (index = callbacks.length - 1) => {
      const callback = callbacks[index];
      if (!callback || cancelled[index]) return;
      await callback();
    },
    delays,
    cancelled,
  };
}

describe("workspace VM idle teardown", () => {
  it("closes the VM 15 minutes after the last busy session goes idle", async () => {
    const { factory, vms } = makeFactory();
    const scheduler = makeIdleScheduler();
    const manager = new GondolinManager(factory, {
      idleTeardownMs: WORKSPACE_VM_IDLE_TEARDOWN_MS,
      scheduleIdleTeardown: scheduler.schedule,
    });
    const ws = makeWorkspace({ id: "w1" });

    await manager.ensureWorkspaceVm(ws, "/path");
    manager.noteWorkspaceBusy("w1", "s1");
    manager.noteWorkspaceIdle("w1", "s1");

    expect(scheduler.delays).toEqual([WORKSPACE_VM_IDLE_TEARDOWN_MS]);
    expect(vms[0].close).not.toHaveBeenCalled();

    await scheduler.fire();

    expect(vms[0].close).toHaveBeenCalledOnce();
    expect(manager.isRunning("w1")).toBe(false);
  });

  it("cancels teardown when a session becomes busy before 15 minutes", async () => {
    const { factory, vms } = makeFactory();
    const scheduler = makeIdleScheduler();
    const manager = new GondolinManager(factory, {
      idleTeardownMs: WORKSPACE_VM_IDLE_TEARDOWN_MS,
      scheduleIdleTeardown: scheduler.schedule,
    });
    const ws = makeWorkspace({ id: "w1" });

    await manager.ensureWorkspaceVm(ws, "/path");
    manager.noteWorkspaceBusy("w1", "s1");
    manager.noteWorkspaceIdle("w1", "s1");
    manager.noteWorkspaceBusy("w1", "s1");

    await scheduler.fire();

    expect(scheduler.cancelled[0]).toBe(true);
    expect(vms[0].close).not.toHaveBeenCalled();
    expect(manager.isRunning("w1")).toBe(true);

    await manager.stopAll();
  });

  it("does not stop the VM when one session goes idle while another stays busy", async () => {
    const { factory, vms } = makeFactory();
    const scheduler = makeIdleScheduler();
    const manager = new GondolinManager(factory, {
      idleTeardownMs: WORKSPACE_VM_IDLE_TEARDOWN_MS,
      scheduleIdleTeardown: scheduler.schedule,
    });
    const ws = makeWorkspace({ id: "w1" });

    await manager.ensureWorkspaceVm(ws, "/path");
    manager.noteWorkspaceBusy("w1", "s1");
    manager.noteWorkspaceBusy("w1", "s2");
    manager.noteWorkspaceIdle("w1", "s1");

    expect(scheduler.delays).toEqual([]);
    await scheduler.fire();
    expect(vms[0].close).not.toHaveBeenCalled();
    expect(manager.isRunning("w1")).toBe(true);

    await manager.stopAll();
  });

  it("creates a new VM when ensureWorkspaceVm runs after idle teardown", async () => {
    const { factory, calls, vms } = makeFactory();
    const scheduler = makeIdleScheduler();
    const manager = new GondolinManager(factory, {
      idleTeardownMs: WORKSPACE_VM_IDLE_TEARDOWN_MS,
      scheduleIdleTeardown: scheduler.schedule,
    });
    const ws = makeWorkspace({ id: "w1" });

    const first = await manager.ensureWorkspaceVm(ws, "/path");
    manager.noteWorkspaceBusy("w1", "s1");
    manager.noteWorkspaceIdle("w1", "s1");
    await scheduler.fire();
    const second = await manager.ensureWorkspaceVm(ws, "/path");

    expect(first).toBe(vms[0]);
    expect(second).toBe(vms[1]);
    expect(second).not.toBe(first);
    expect(calls).toHaveLength(2);
    expect(manager.getVm("w1")).toBe(vms[1]);

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
      fs: {
        access: vi.fn(async () => undefined),
        mkdir: vi.fn(async () => undefined),
        readFile: vi.fn(async () => Buffer.alloc(0)),
        writeFile: vi.fn(async () => undefined),
      },
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

describe("sandbox workspace shadow policy", () => {
  it("hides common secret files and directories anywhere under the workspace mount", () => {
    const shadowed = [
      "/.env",
      "/app/.env.local",
      "/repo/.ssh/config",
      "/repo/.aws/credentials",
      "/repo/private.pem",
      "/repo/service.key",
    ];

    for (const path of shadowed) {
      expect(shouldShadowSandboxWorkspacePath({ op: "open", path })).toBe(true);
    }
  });

  it("hides children of /.config/gcloud, not only the directory exact path", () => {
    expect(
      shouldShadowSandboxWorkspacePath({
        op: "open",
        path: "/.config/gcloud/application_default_credentials.json",
      }),
    ).toBe(true);
  });

  it("hides case variants of .SSH", () => {
    expect(shouldShadowSandboxWorkspacePath({ op: "open", path: "/.SSH/id_rsa" })).toBe(true);
    expect(shouldShadowSandboxWorkspacePath({ op: "open", path: "/repo/.SSH/config" })).toBe(true);
  });

  it.each([
    ["/.pi/agent/auth.json"],
    ["/.git-credentials"],
    ["/repo/.git-credentials"],
    ["/.kube/config"],
    ["/app/.kube/config"],
    ["/.docker/config.json"],
    ["/app/.docker/config.json"],
    ["/.pgpass"],
    ["/home/.pgpass"],
    ["/certs/client.p12"],
    ["/certs/client.pfx"],
    ["/.CONFIG/gcloud/application_default_credentials.json"],
  ] as const)("hides credential path %s", (path) => {
    expect(shouldShadowSandboxWorkspacePath({ op: "open", path })).toBe(true);
  });

  it("does not hide ordinary project files", () => {
    const allowed = [
      "/README.md",
      "/src/config.ts",
      "/docs/keybindings.md",
      "/pem-notes.txt",
      "/.config/git/config",
      "/.docker/daemon.json",
    ];

    for (const path of allowed) {
      expect(shouldShadowSandboxWorkspacePath({ op: "open", path })).toBe(false);
    }
  });
});

describe("buildVmHttpHooks", () => {
  const publicHttpsProbe = {
    hostname: "example.com",
    ip: "93.184.216.34",
    family: 4 as const,
    port: 443,
    protocol: "https" as const,
  };

  it("passes omitted allowedHosts through to Gondolin's allow-all default", () => {
    const createHttpHooksSpy = vi.fn(createHttpHooks);

    buildVmHttpHooks(createHttpHooksSpy, {});

    expect(createHttpHooksSpy).toHaveBeenCalledWith({
      allowedHosts: undefined,
      secrets: undefined,
    });
  });

  it("passes an explicit empty allowedHosts list to Gondolin and denies all egress", async () => {
    const createHttpHooksSpy = vi.fn(createHttpHooks);

    const { httpHooks } = buildVmHttpHooks(createHttpHooksSpy, {
      allowedHosts: [],
    });

    expect(createHttpHooksSpy).toHaveBeenCalledWith({ allowedHosts: [], secrets: undefined });
    await expect(httpHooks.isIpAllowed?.(publicHttpsProbe)).resolves.toBe(false);
  });

  it("treats an empty allowedHosts list as deny-all via real createHttpHooks", async () => {
    const { httpHooks } = buildVmHttpHooks(createHttpHooks, {
      allowedHosts: [],
    });

    await expect(httpHooks.isIpAllowed?.(publicHttpsProbe)).resolves.toBe(false);
  });

  it("preserves Gondolin host allowlists when allowedHosts is non-empty", async () => {
    const { httpHooks } = buildVmHttpHooks(createHttpHooks, {
      allowedHosts: ["api.example.com"],
    });

    await expect(
      httpHooks.isIpAllowed?.({
        hostname: "api.example.com",
        ip: "93.184.216.34",
        family: 4,
        port: 443,
        protocol: "https",
      }),
    ).resolves.toBe(true);
    await expect(httpHooks.isIpAllowed?.(publicHttpsProbe)).resolves.toBe(false);
  });

  it.each([
    {
      name: "omitted hosts",
      secret: { value: "sk-test" },
    },
    {
      name: "empty hosts",
      secret: { value: "sk-test", hosts: [] },
    },
    {
      name: "wildcard hosts",
      secret: { value: "sk-test", hosts: ["*"] },
    },
    {
      name: "mixed wildcard hosts",
      secret: { value: "sk-test", hosts: ["api.example.com", "*"] },
    },
    {
      name: "whitespace-padded wildcard hosts",
      secret: { value: "sk-test", hosts: [" * "] },
    },
    {
      name: "blank hosts",
      secret: { value: "sk-test", hosts: ["  "] },
    },
  ])("fails closed for a secret with $name", ({ secret }) => {
    const createHttpHooksSpy = vi.fn(createHttpHooks);

    expect(() =>
      buildVmHttpHooks(createHttpHooksSpy, {
        secrets: {
          API_KEY: secret as { value: string; hosts: string[] },
        },
      }),
    ).toThrow(/explicit non-wildcard host list/);
    expect(createHttpHooksSpy).not.toHaveBeenCalled();
  });

  it("passes an empty secrets object through without inventing hosts", () => {
    const createHttpHooksSpy = vi.fn(createHttpHooks);

    buildVmHttpHooks(createHttpHooksSpy, { secrets: {} });

    expect(createHttpHooksSpy).toHaveBeenCalledWith({
      allowedHosts: undefined,
      secrets: {},
    });
  });

  it("forwards an explicit secret host list as-is", () => {
    const createHttpHooksSpy = vi.fn(createHttpHooks);

    buildVmHttpHooks(createHttpHooksSpy, {
      allowedHosts: ["other.example.com"],
      secrets: {
        API_KEY: { value: "sk-test", hosts: ["api.example.com"] },
      },
    });

    expect(createHttpHooksSpy).toHaveBeenCalledWith({
      allowedHosts: ["other.example.com"],
      secrets: {
        API_KEY: { hosts: ["api.example.com"], value: "sk-test" },
      },
    });
  });
});

describe("isQemuAvailable", () => {
  it("returns a boolean", async () => {
    const result = await isQemuAvailable();
    expect(typeof result).toBe("boolean");
  });
});

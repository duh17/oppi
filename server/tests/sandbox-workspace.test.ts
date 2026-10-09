/**
 * Integration tests for sandbox workspace CRUD and Gondolin VM lifecycle.
 *
 * Tests the REST API behavior for sandbox workspaces and the SDK backend
 * sandbox tool wiring path using a mocked Gondolin VM.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Storage } from "../src/storage.js";
import { ConfigStore } from "../src/storage/config-store.js";
import {
  WorkspaceStore,
  type WorkspaceMigrationFaultPhase,
} from "../src/storage/workspace-store.js";
import type { Workspace, CreateWorkspaceRequest } from "../src/types.js";
import {
  GondolinManager,
  type VmFactory,
  type VmFactoryOptions,
  isQemuAvailable,
} from "../src/gondolin-manager.js";
import type { GondolinVm, GondolinProcess, GondolinExecResult } from "../src/gondolin-ops.js";
import {
  createGondolinBashOps,
  createGondolinReadOps,
  createGondolinWriteOps,
  createGondolinEditOps,
} from "../src/gondolin-ops.js";

// ─── Helpers ───

let dataDir: string;

function createTempStorage(): Storage {
  dataDir = mkdtempSync(join(tmpdir(), "sandbox-test-"));
  return new Storage(dataDir);
}

function createMockProcess(
  overrides: {
    exitCode?: number;
    stdout?: string;
  } = {},
): GondolinProcess {
  const { exitCode = 0, stdout = "" } = overrides;
  const result: GondolinExecResult = {
    exitCode,
    stdout,
    stdoutBuffer: Buffer.from(stdout),
    ok: exitCode === 0,
  };
  return {
    then(onfulfilled, onrejected) {
      return Promise.resolve(result).then(onfulfilled, onrejected);
    },
    output() {
      return {
        async *[Symbol.asyncIterator]() {
          yield { stream: "stdout" as const, data: Buffer.from(stdout) };
        },
      };
    },
  };
}

function createMockVm(): GondolinVm & { close: ReturnType<typeof vi.fn> } {
  return {
    fs: {
      access: vi.fn(async () => undefined),
      mkdir: vi.fn(async () => undefined),
      readFile: vi.fn(async () => Buffer.from("")),
      writeFile: vi.fn(async () => undefined),
    },
    exec: vi.fn(() => createMockProcess()),
    close: vi.fn(async () => {}),
  };
}

function createMockFactory(
  vms: Array<GondolinVm & { close: ReturnType<typeof vi.fn> }>,
): VmFactory {
  let idx = 0;
  return async (_options: VmFactoryOptions) => {
    const vm = vms[idx++] ?? createMockVm();
    return vm;
  };
}

// ─── Workspace CRUD with runtime field ───

describe("Sandbox workspace CRUD", () => {
  let storage: Storage;

  beforeEach(() => {
    storage = createTempStorage();
  });

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("creates workspace with runtime=sandbox", () => {
    const ws = storage.createWorkspace({
      name: "sandbox-test",
      runtime: "sandbox",
      sandboxConfig: { allowedHosts: ["api.anthropic.com", "api.openai.com"] },
    } as CreateWorkspaceRequest);

    expect(ws.runtime).toBe("sandbox");
    expect(ws.sandboxConfig).toEqual({ allowedHosts: ["api.anthropic.com", "api.openai.com"] });
  });

  it("creates workspace with runtime=host (default behavior)", () => {
    const ws = storage.createWorkspace({
      name: "host-test",
      runtime: "host",
    } as CreateWorkspaceRequest);

    expect(ws.runtime).toBe("host");
    expect(ws.sandboxConfig).toBeUndefined();
  });

  it("creates workspace without runtime (backwards compat)", () => {
    const ws = storage.createWorkspace({
      name: "legacy-test",
    } as CreateWorkspaceRequest);

    expect(ws.runtime).toBeUndefined();
    expect(ws.sandboxConfig).toBeUndefined();
  });

  it("persists and reloads sandbox tools and config", () => {
    const ws = storage.createWorkspace({
      name: "persist-test",
      tools: ["read", "bash", "edit", "write", "web_search"],
      runtime: "sandbox",
      sandboxConfig: {
        allowedHosts: ["*.example.com"],
        env: { SEARXNG_URL: "http://192.168.127.1:8888" },
      },
    } as CreateWorkspaceRequest);

    const loaded = storage.getWorkspace(ws.id);
    expect(loaded).toBeDefined();
    expect(loaded!.runtime).toBe("sandbox");
    expect(loaded!.tools).toEqual(["read", "bash", "edit", "write", "web_search"]);
    expect(loaded!.sandboxConfig).toEqual({
      allowedHosts: ["*.example.com"],
      env: { SEARXNG_URL: "http://192.168.127.1:8888" },
    });
  });

  it("keeps only valid, unique MCP server picks, even without other sandbox settings", () => {
    const ws = storage.createWorkspace({
      name: "mcp-picks",
      runtime: "sandbox",
    } as CreateWorkspaceRequest);
    storage.updateWorkspace(ws.id, {
      sandboxConfig: { mcpServers: ["echo", "echo", "bad name", "../x", 5, "kypu-2"] } as never,
    });
    expect(storage.getWorkspace(ws.id)!.sandboxConfig).toEqual({ mcpServers: ["echo", "kypu-2"] });
  });

  it("updates runtime from host to sandbox", () => {
    const ws = storage.createWorkspace({
      name: "upgrade-test",
      runtime: "host",
    } as CreateWorkspaceRequest);

    storage.updateWorkspace(ws.id, {
      runtime: "sandbox",
      sandboxConfig: { allowedHosts: ["*"] },
    });

    const updated = storage.getWorkspace(ws.id);
    expect(updated!.runtime).toBe("sandbox");
    expect(updated!.sandboxConfig).toEqual({ allowedHosts: ["*"] });
  });

  it("lists workspaces preserving runtime field", () => {
    storage.createWorkspace({
      name: "sandbox-ws",
      runtime: "sandbox",
    } as CreateWorkspaceRequest);

    storage.createWorkspace({
      name: "host-ws",
      runtime: "host",
    } as CreateWorkspaceRequest);

    const list = storage.listWorkspaces();
    const sandboxWs = list.find((w) => w.name === "sandbox-ws");
    const hostWs = list.find((w) => w.name === "host-ws");

    expect(sandboxWs?.runtime).toBe("sandbox");
    expect(hostWs?.runtime).toBe("host");
  });
});

function workspaceFilePath(id: string): string {
  return join(dataDir, "workspaces", `${id}.json`);
}

describe("Sandbox empty-folder hostMount persistence", () => {
  let storage: Storage;

  beforeEach(() => {
    storage = createTempStorage();
  });

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("persists ~/sandbox/<slug> when creating a sandbox workspace with an empty folder", () => {
    const ws = storage.createWorkspace({
      name: "Empty Sandbox",
      runtime: "sandbox",
    } as CreateWorkspaceRequest);

    expect(ws.hostMount).toBe("~/sandbox/empty-sandbox");
    const raw = JSON.parse(readFileSync(workspaceFilePath(ws.id), "utf-8")) as {
      hostMount?: string;
    };
    expect(raw.hostMount).toBe("~/sandbox/empty-sandbox");
    expect(storage.getWorkspace(ws.id)?.hostMount).toBe("~/sandbox/empty-sandbox");
  });

  it("keeps a host workspace with an empty folder unset", () => {
    const blank = storage.createWorkspace({
      name: "Blank Host",
      runtime: "host",
      hostMount: "   ",
    } as CreateWorkspaceRequest);
    expect(blank.hostMount).toBeUndefined();

    const omitted = storage.createWorkspace({
      name: "Omitted Host",
    } as CreateWorkspaceRequest);
    expect(omitted.hostMount).toBeUndefined();
    expect(omitted.runtime).toBeUndefined();
  });

  it("keeps the persisted folder when the sandbox workspace is renamed", () => {
    const ws = storage.createWorkspace({
      name: "Original Name",
      runtime: "sandbox",
    } as CreateWorkspaceRequest);
    expect(ws.hostMount).toBe("~/sandbox/original-name");

    const renamed = storage.updateWorkspace(ws.id, { name: "Renamed Title" });
    expect(renamed?.name).toBe("Renamed Title");
    expect(renamed?.hostMount).toBe("~/sandbox/original-name");
    expect(storage.getWorkspace(ws.id)?.hostMount).toBe("~/sandbox/original-name");
  });

  it("re-persists ~/sandbox/<current-slug> when an update clears the sandbox folder", () => {
    const ws = storage.createWorkspace({
      name: "Custom Folder",
      runtime: "sandbox",
      hostMount: dataDir,
    } as CreateWorkspaceRequest);
    expect(ws.hostMount).toBe(dataDir);

    const cleared = storage.updateWorkspace(ws.id, { hostMount: null });
    expect(cleared?.hostMount).toBe("~/sandbox/custom-folder");
  });

  it("migrates a stored sandbox workspace missing hostMount once from its current name", () => {
    const ws = storage.createWorkspace({
      name: "Current Name",
      runtime: "host",
    } as CreateWorkspaceRequest);
    const path = workspaceFilePath(ws.id);
    const raw = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
    raw.runtime = "sandbox";
    delete raw.hostMount;
    writeFileSync(path, JSON.stringify(raw, null, 2));

    const loaded = storage.getWorkspace(ws.id);
    expect(loaded?.hostMount).toBe("~/sandbox/current-name");
    expect(loaded?.updatedAt).toBe(ws.updatedAt);

    const diskAfterFirst = readFileSync(path, "utf-8");
    expect(JSON.parse(diskAfterFirst)).toMatchObject({ hostMount: "~/sandbox/current-name" });

    const again = storage.getWorkspace(ws.id);
    expect(again?.hostMount).toBe("~/sandbox/current-name");
    expect(readFileSync(path, "utf-8")).toBe(diskAfterFirst);
  });

  it("listWorkspaces migrates missing sandbox hostMount from the current name", () => {
    const ws = storage.createWorkspace({
      name: "Listed Sandbox",
      runtime: "host",
    } as CreateWorkspaceRequest);
    const path = workspaceFilePath(ws.id);
    const raw = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
    raw.runtime = "sandbox";
    delete raw.hostMount;
    writeFileSync(path, JSON.stringify(raw, null, 2));

    const listed = storage.listWorkspaces().find((candidate) => candidate.id === ws.id);
    expect(listed?.hostMount).toBe("~/sandbox/listed-sandbox");
    expect((JSON.parse(readFileSync(path, "utf-8")) as { hostMount?: string }).hostMount).toBe(
      "~/sandbox/listed-sandbox",
    );
  });

  it("keeps unknown raw fields when filling sandbox hostMount on load", () => {
    const ws = storage.createWorkspace({
      name: "Raw Fields",
      runtime: "host",
    } as CreateWorkspaceRequest);
    const path = workspaceFilePath(ws.id);
    const raw = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
    raw.runtime = "sandbox";
    raw.futureField = { nested: true, label: "keep-me" };
    raw.systemPromptMode = "replace";
    delete raw.hostMount;
    writeFileSync(path, JSON.stringify(raw, null, 2));

    const loaded = storage.getWorkspace(ws.id);
    expect(loaded?.hostMount).toBe("~/sandbox/raw-fields");
    expect(loaded?.systemPromptMode).toBe("append");
    expect(JSON.parse(readFileSync(path, "utf-8"))).toEqual({
      ...raw,
      hostMount: "~/sandbox/raw-fields",
    });
  });

  it.each(["after_temp_write", "after_temp_fsync", "before_rename", "after_rename"] as const)(
    "preserves the original sandbox workspace file after a %s hostMount fill failure",
    (faultPhase) => {
      const ws = storage.createWorkspace({
        name: "Atomic Fill",
        runtime: "host",
      } as CreateWorkspaceRequest);
      const path = workspaceFilePath(ws.id);
      const raw = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
      raw.runtime = "sandbox";
      raw.futureField = "keep-me";
      delete raw.hostMount;
      const original = JSON.stringify(raw, null, 2);
      writeFileSync(path, original, { mode: 0o600 });

      const configStore = new ConfigStore(dataDir);
      const store = new WorkspaceStore(configStore, undefined, {
        faultInjector(phase: WorkspaceMigrationFaultPhase) {
          if (phase === faultPhase) throw new Error(`injected ${phase}`);
        },
      });

      expect(() => store.getWorkspace(ws.id)).toThrow(`injected ${faultPhase}`);
      expect(readFileSync(path, "utf-8")).toBe(original);
      expect(
        readdirSync(configStore.getWorkspacesDir()).filter((name) => name.endsWith(".tmp")),
      ).toEqual([]);

      const recovered = new WorkspaceStore(configStore);
      expect(recovered.getWorkspace(ws.id)?.hostMount).toBe("~/sandbox/atomic-fill");
      expect(JSON.parse(readFileSync(path, "utf-8"))).toEqual({
        ...raw,
        hostMount: "~/sandbox/atomic-fill",
      });
    },
  );
});

// ─── GondolinManager lifecycle with secrets ───

describe("GondolinManager secret forwarding", () => {
  it("passes secrets through to factory", async () => {
    const factoryArgs: VmFactoryOptions[] = [];
    const factory: VmFactory = async (options) => {
      factoryArgs.push(options);
      return createMockVm();
    };

    const manager = new GondolinManager(factory);
    const workspace: Workspace = {
      id: "ws-sec",
      name: "Secret Test",
      runtime: "sandbox",
      sandboxConfig: { allowedHosts: ["api.anthropic.com"] },
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    const secrets = {
      ANTHROPIC_API_KEY: { value: "sk-ant-xxx", hosts: ["api.anthropic.com"] },
    };

    await manager.ensureWorkspaceVm(workspace, "/tmp/ws", secrets);

    expect(factoryArgs).toHaveLength(1);
    expect(factoryArgs[0].secrets).toEqual(secrets);
    expect(factoryArgs[0].allowedHosts).toEqual(["api.anthropic.com"]);

    await manager.stopAll();
  });

  it("passes a named guest workspace mount when provided", async () => {
    const factoryArgs: VmFactoryOptions[] = [];
    const factory: VmFactory = async (options) => {
      factoryArgs.push(options);
      return createMockVm();
    };

    const manager = new GondolinManager(factory);
    const workspace: Workspace = {
      id: "ws-guest-path",
      name: "Guest Path",
      runtime: "sandbox",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    await manager.ensureWorkspaceVm(
      workspace,
      "/tmp/ws",
      undefined,
      undefined,
      undefined,
      "/workspace/guest-path",
    );

    expect(factoryArgs[0].guestWorkspacePath).toBe("/workspace/guest-path");

    await manager.stopAll();
  });

  it("works without secrets", async () => {
    const factoryArgs: VmFactoryOptions[] = [];
    const factory: VmFactory = async (options) => {
      factoryArgs.push(options);
      return createMockVm();
    };

    const manager = new GondolinManager(factory);
    const workspace: Workspace = {
      id: "ws-nosec",
      name: "No Secrets",
      runtime: "sandbox",
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    await manager.ensureWorkspaceVm(workspace, "/tmp/ws");

    expect(factoryArgs[0].secrets).toBeUndefined();
    expect(factoryArgs[0].allowedHosts).toBeUndefined(); // Gondolin default allow-all

    await manager.stopAll();
  });
});

// ─── Sandbox tool operations integration ───

describe("Sandbox tool operations with mock VM", () => {
  const localCwd = "/Users/test/workspace/project";

  it("bash ops: exec routes to VM with correct guest path", async () => {
    const vm = createMockVm();
    const ops = createGondolinBashOps(vm, localCwd);

    const chunks: Buffer[] = [];
    await ops.exec("echo hello", localCwd, {
      onData: (data) => chunks.push(data),
    });

    expect(vm.exec).toHaveBeenCalledOnce();
    const call = (vm.exec as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(call[0]).toEqual(["/bin/bash", "-lc", "echo hello"]);
    expect(call[1].cwd).toBe("/workspace");
  });

  it("read ops: readFile maps host path to guest", async () => {
    const readFile = vi.fn(async () => Buffer.from("file content"));
    const vm: GondolinVm = {
      fs: {
        access: vi.fn(async () => undefined),
        mkdir: vi.fn(async () => undefined),
        readFile,
        writeFile: vi.fn(async () => undefined),
      },
      exec: vi.fn(() => createMockProcess({ stdout: "file content" })),
    };
    const ops = createGondolinReadOps(vm, localCwd);

    const result = await ops.readFile(`${localCwd}/src/main.ts`);
    expect(result.toString()).toBe("file content");
    expect(readFile).toHaveBeenCalledWith("/workspace/src/main.ts");
  });

  it("read ops: access throws on non-existent file", async () => {
    const vm: GondolinVm = {
      fs: {
        access: vi.fn(async () => {
          throw new Error("missing");
        }),
        mkdir: vi.fn(async () => undefined),
        readFile: vi.fn(async () => Buffer.from("")),
        writeFile: vi.fn(async () => undefined),
      },
      exec: vi.fn(() => createMockProcess({ exitCode: 1 })),
    };
    const ops = createGondolinReadOps(vm, localCwd);

    await expect(ops.access(`${localCwd}/missing.txt`)).rejects.toThrow(/ENOENT/);
  });

  it("write ops: writeFile uses Gondolin fs", async () => {
    const vm = createMockVm();
    const ops = createGondolinWriteOps(vm, localCwd);

    await ops.writeFile(`${localCwd}/output.txt`, "hello world");

    expect(vm.fs.mkdir).toHaveBeenCalledWith("/workspace", { recursive: true });
    expect(vm.fs.writeFile).toHaveBeenCalledWith("/workspace/output.txt", "hello world", {
      encoding: "utf8",
    });
  });

  it("write ops: mkdir maps to guest path", async () => {
    const vm = createMockVm();
    const ops = createGondolinWriteOps(vm, localCwd);

    await ops.mkdir(`${localCwd}/new/dir`);

    expect(vm.fs.mkdir).toHaveBeenCalledWith("/workspace/new/dir", { recursive: true });
  });

  it("edit ops: readFile and writeFile delegate correctly", async () => {
    const readFile = vi.fn(async () => Buffer.from("original content"));
    const writeFile = vi.fn(async () => undefined);
    const vm: GondolinVm = {
      fs: {
        access: vi.fn(async () => undefined),
        mkdir: vi.fn(async () => undefined),
        readFile,
        writeFile,
      },
      exec: vi.fn((args: string[]) => {
        if (args[0] === "/bin/cat") {
          return createMockProcess({ stdout: "original content" });
        }
        return createMockProcess();
      }),
    };
    const ops = createGondolinEditOps(vm, localCwd);

    const content = await ops.readFile(`${localCwd}/file.ts`);
    expect(readFile).toHaveBeenCalledWith("/workspace/file.ts");
    expect(content.toString()).toBe("original content");

    // writeFile should work
    await ops.writeFile(`${localCwd}/file.ts`, "modified content");
    expect(writeFile).toHaveBeenCalledWith("/workspace/file.ts", "modified content", {
      encoding: "utf8",
    });
  });
});

// ─── QEMU availability check ───

describe("isQemuAvailable", () => {
  it("returns a boolean", async () => {
    const result = await isQemuAvailable();
    expect(typeof result).toBe("boolean");
  });
});

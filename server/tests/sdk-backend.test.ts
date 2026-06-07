import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve as resolvePath } from "node:path";
import { describe, expect, it, vi } from "vitest";
import * as PiSdk from "@earendil-works/pi-coding-agent";

import { hostMountValidationError } from "../src/host.js";
import * as GondolinManagerModule from "../src/gondolin-manager.js";
import {
  resolveSandboxGuestCwd,
  resolveSdkSessionCwd,
  resolveSdkSessionDisplayCwd,
  filterSdkLoadedExtensions,
  SdkBackend,
  type BuiltInExtensionContext,
} from "../src/sdk-backend.js";
import { SdkUiBridge } from "../src/sdk-ui-bridge.js";
import type { AskQuestion, ExtensionUINativeSurface, Session, Workspace } from "../src/types.js";

describe("resolveSdkSessionCwd", () => {
  it("defaults to home dir when workspace is missing", () => {
    expect(resolveSdkSessionCwd(undefined)).toBe(homedir());
  });

  it("expands tilde hostMount to an absolute path", () => {
    const workspace = { hostMount: "~/workspace/oppi" } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(resolvePath(homedir(), "workspace", "oppi"));
  });

  it("expands bare tilde hostMount", () => {
    const workspace = { hostMount: "~" } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(homedir());
  });

  it("keeps absolute hostMount unchanged", () => {
    const mount = resolvePath(homedir(), "workspace", "oppi");
    const workspace = { hostMount: mount } as Workspace;
    expect(resolveSdkSessionCwd(workspace)).toBe(mount);
  });
});

describe("resolveSdkSessionDisplayCwd", () => {
  it("uses a sandbox guest path instead of the host backing path", () => {
    const uniqueName = `Oppi Sandbox Display ${Date.now()}`;
    const slug = uniqueName.toLowerCase().replace(/[^a-z0-9-_]/g, "-");
    const workspace = {
      id: "ws-sandbox",
      name: uniqueName,
      runtime: "sandbox",
    } as Workspace;
    const hostBackingDir = resolvePath(homedir(), "sandbox", slug);

    try {
      expect(resolveSandboxGuestCwd(workspace)).toBe(`/workspace/${slug}`);
      expect(resolveSdkSessionDisplayCwd(workspace)).toBe(`/workspace/${slug}`);
      expect(resolveSdkSessionCwd(workspace)).toBe(hostBackingDir);
    } finally {
      rmSync(hostBackingDir, { recursive: true, force: true });
    }
  });

  it("keeps host workspaces on their resolved host cwd", () => {
    const mount = resolvePath(homedir(), "workspace", "oppi");
    const workspace = { hostMount: mount, runtime: "host" } as Workspace;

    expect(resolveSdkSessionDisplayCwd(workspace)).toBe(mount);
  });
});

describe("hostMountValidationError", () => {
  it("accepts an existing directory", () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-hostmount-ok-"));
    try {
      expect(hostMountValidationError(cwd)).toBeUndefined();
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("rejects a missing directory with recovery guidance", () => {
    const missing = join(tmpdir(), `oppi-hostmount-missing-${Date.now()}`);
    rmSync(missing, { recursive: true, force: true });

    const message = hostMountValidationError(missing);

    expect(message).toContain("Host working directory does not exist");
    expect(message).toContain(missing);
    expect(message).toContain("clear Host Working Directory for a blank workspace");
  });

  it("rejects a file path", () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-hostmount-file-"));
    const file = join(cwd, "not-a-directory");
    writeFileSync(file, "x");
    try {
      expect(hostMountValidationError(file)).toContain("Host working directory is not a directory");
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });
});

describe("filterSdkLoadedExtensions", () => {
  function ext(path: string, resolvedPath = path): { path: string; resolvedPath: string } {
    return { path, resolvedPath };
  }

  it("keeps global permission-gate outside workspace allowlists", () => {
    const permissionGate = "/home/user/.pi/agent/extensions/permission-gate.ts";
    const filtered = filterSdkLoadedExtensions(
      [ext(permissionGate), ext("/home/user/.pi/agent/extensions/memory.ts")],
      {
        workspaceExtensions: ["memory"],
        permissionGateEnabled: true,
        permissionGatePath: permissionGate,
      },
    );

    expect(filtered.map((item) => item.path)).toEqual([
      permissionGate,
      "/home/user/.pi/agent/extensions/memory.ts",
    ]);
  });

  it("filters project-local permission-gate when a global gate path is configured", () => {
    const globalGate = "/home/user/.pi/agent/extensions/permission-gate.ts";
    const projectGate = "/workspace/.pi/extensions/permission-gate.ts";
    const filtered = filterSdkLoadedExtensions([ext(projectGate), ext(globalGate)], {
      permissionGateEnabled: true,
      permissionGatePath: globalGate,
    });

    expect(filtered.map((item) => item.path)).toEqual([globalGate]);
  });

  it("filters permission-gate when disabled even if the workspace lists it", () => {
    const permissionGate = "/home/user/.pi/agent/extensions/permission-gate.ts";
    const filtered = filterSdkLoadedExtensions([ext(permissionGate)], {
      workspaceExtensions: ["permission-gate"],
      permissionGateEnabled: false,
      permissionGatePath: permissionGate,
    });

    expect(filtered).toEqual([]);
  });
});

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-test",
    workspaceId: "w1",
    status: "starting",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeBuiltInContext(): BuiltInExtensionContext {
  return {
    storage: {} as never,
  };
}

describe("SdkBackend sandbox", () => {
  it("does not forward provider auth secrets into the VM", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-sandbox-secrets-"));
    const skillDir = join(cwd, "skills", "sandbox-review");
    mkdirSync(skillDir, { recursive: true });
    writeFileSync(
      join(skillDir, "SKILL.md"),
      [
        "---",
        "name: sandbox-review",
        "description: Review sandbox behavior for tests.",
        "---",
        "Review the sandbox behavior.",
      ].join("\n"),
    );
    const qemuSpy = vi.spyOn(GondolinManagerModule, "isQemuAvailable").mockResolvedValue(true);
    const execResult = {
      exitCode: 0,
      stdout: "",
      stdoutBuffer: Buffer.alloc(0),
      ok: true,
    };
    const vm = {
      fs: {
        access: vi.fn(async () => undefined),
        mkdir: vi.fn(async () => undefined),
        readFile: vi.fn(async () => Buffer.alloc(0)),
        writeFile: vi.fn(async () => undefined),
      },
      exec: vi.fn(() =>
        Object.assign(Promise.resolve(execResult), { output: async function* () {} }),
      ),
    };
    const manager = {
      ensureWorkspaceVm: vi.fn(async () => vm),
    };
    const sdkBackendType = SdkBackend as unknown as { _gondolinManager?: typeof manager };
    const previousManager = sdkBackendType._gondolinManager;
    sdkBackendType._gondolinManager = manager;

    let backend: SdkBackend | undefined;

    try {
      backend = await SdkBackend.create({
        session: makeSession(),
        workspace: {
          id: "w1",
          name: "Sandbox Secrets Test",
          runtime: "sandbox",
          hostMount: cwd,
          sandboxConfig: { allowedHosts: ["api.example.com"] },
          extensions: [],
        } as Workspace,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
        skillPaths: [skillDir],
      });

      expect(manager.ensureWorkspaceVm).toHaveBeenCalled();
      expect(manager.ensureWorkspaceVm.mock.calls[0][2]).toEqual({});
      expect(manager.ensureWorkspaceVm.mock.calls[0][3]).toEqual([
        {
          hostPath: skillDir,
          guestPath: "/workspace/sandbox-secrets-test/.pi/skills/sandbox-review",
        },
      ]);

      const runtime = (
        backend as unknown as {
          runtime: {
            services: { cwd: string };
            session: {
              sessionManager: {
                getCwd: () => string;
                getHeader: () => { cwd: string } | null;
                getSessionDir: () => string;
              };
            };
          };
        }
      ).runtime;
      expect(runtime.services.cwd).toBe("/workspace/sandbox-secrets-test");
      expect(runtime.session.sessionManager.getCwd()).toBe("/workspace/sandbox-secrets-test");
      expect(runtime.session.sessionManager.getHeader()?.cwd).toBe(
        "/workspace/sandbox-secrets-test",
      );

      const targetSession = PiSdk.SessionManager.create(
        "/workspace/sandbox-secrets-test",
        runtime.session.sessionManager.getSessionDir(),
      );
      const targetSessionFile = targetSession.getSessionFile();
      const targetHeader = targetSession.getHeader();
      expect(targetSessionFile).toBeDefined();
      expect(targetHeader?.cwd).toBe("/workspace/sandbox-secrets-test");
      writeFileSync(targetSessionFile!, `${JSON.stringify(targetHeader)}\n`);

      await backend.switchSession(targetSessionFile!);

      expect(runtime.services.cwd).toBe("/workspace/sandbox-secrets-test");
      expect(runtime.session.sessionManager.getCwd()).toBe("/workspace/sandbox-secrets-test");
      expect(runtime.session.sessionManager.getHeader()?.cwd).toBe(
        "/workspace/sandbox-secrets-test",
      );
    } finally {
      if (backend) await backend.dispose();
      sdkBackendType._gondolinManager = previousManager;
      qemuSpy.mockRestore();
      rmSync(cwd, { recursive: true, force: true });
    }
  });
});

describe("SdkBackend built-in extensions", () => {
  it("registers explicitly enabled built-ins without file package paths", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-builtins-"));
    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "w1",
        name: "Built-ins Test",
        runtime: "host",
        hostMount: cwd,
        extensions: ["ask"],
      } as Workspace,
      builtInExtensionContext: makeBuiltInContext(),
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;
      const extensions = resourceLoader.getExtensions().extensions;

      expect(
        extensions.some((ext) => ext.path.startsWith("<inline:") && ext.tools.has("ask")),
      ).toBe(true);
      expect(extensions.some((ext) => ext.resolvedPath.includes("oppi-extensions"))).toBe(false);
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("loads subagents through the bundled native Pi extension", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-subagents-native-"));
    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "w1",
        name: "Subagents Native Test",
        runtime: "host",
        hostMount: cwd,
        extensions: ["subagents"],
      } as Workspace,
      builtInExtensionContext: makeBuiltInContext(),
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      const resourceLoader = (
        backend as unknown as {
          runtime: { services: { resourceLoader: PiSdk.ResourceLoader } };
        }
      ).runtime.services.resourceLoader;
      const extensions = resourceLoader.getExtensions().extensions;
      const subagents = extensions.find(
        (ext) => ext.resolvedPath.includes("oppi-subagents") && ext.tools.has("inspect_agent"),
      );

      expect(subagents?.path).toContain("pi-extensions/oppi-subagents");
      expect(subagents?.path).not.toContain("extension-wrappers");
      expect(subagents?.tools.has("spawn_agent")).toBe(true);
      expect(subagents?.tools.has("send_message")).toBe(true);
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("seeds the pi session thinking level from stored Oppi session state", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-thinking-seed-"));
    const backend = await SdkBackend.create({
      session: makeSession({ thinkingLevel: "high" }),
      workspace: {
        id: "w1",
        name: "Thinking Seed Test",
        runtime: "host",
        hostMount: cwd,
        extensions: [],
      } as Workspace,
      builtInExtensionContext: makeBuiltInContext(),
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      expect(backend.session.thinkingLevel).toBe("high");
    } finally {
      await backend.dispose();
      rmSync(cwd, { recursive: true, force: true });
    }
  });
});

describe("SdkBackend prompt templates", () => {
  it("loads project prompt templates into Oppi sessions", async () => {
    const cwd = mkdtempSync(join(tmpdir(), "oppi-prompts-"));
    mkdirSync(join(cwd, ".pi", "prompts"), { recursive: true });
    writeFileSync(
      join(cwd, ".pi", "prompts", "grill-me.md"),
      [
        "---",
        "description: Stress-test a plan one question at a time",
        "---",
        "Ask one question at a time.",
      ].join("\n"),
    );

    const backend = await SdkBackend.create({
      session: {
        id: "sess-prompts",
        workspaceId: "w1",
        status: "starting",
        createdAt: Date.now(),
        lastActivity: Date.now(),
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
      },
      workspace: {
        id: "w1",
        name: "Prompt Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      const runtime = (
        backend as unknown as {
          runtime: {
            session: { promptTemplates: Array<{ name: string }> };
            services: { resourceLoader: PiSdk.ResourceLoader };
          };
        }
      ).runtime;

      const discoveredPromptNames = runtime.services.resourceLoader
        .getPrompts()
        .prompts.map((prompt) => prompt.name);
      const sessionPromptNames = runtime.session.promptTemplates.map((prompt) => prompt.name);

      expect(discoveredPromptNames).toContain("grill-me");
      expect(sessionPromptNames).toContain("grill-me");
    } finally {
      await backend.dispose();
    }
  });
});

describe("SdkBackend.setModel", () => {
  function makeSetModelHarness() {
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;

    const modelRegistry = {
      refresh: vi.fn(),
      find: vi.fn(),
    };

    const piSession = {
      setModel: vi.fn(async () => {}),
      model: undefined as
        | {
            provider?: string;
            id?: string;
            name?: string;
          }
        | undefined,
      thinkingLevel: "medium",
    };

    const runtime = {
      session: piSession,
      services: {
        modelRegistry,
      },
    };

    const mutableBackend = backend as unknown as {
      runtime: typeof runtime;
    };

    mutableBackend.runtime = runtime;

    return { backend, modelRegistry, piSession };
  }

  it("rejects invalid model IDs", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();

    const result = await backend.setModel("claude-sonnet-4-5");

    expect(result).toEqual({ success: false, error: "Invalid model ID: claude-sonnet-4-5" });
    expect(modelRegistry.find).not.toHaveBeenCalled();
    expect(piSession.setModel).not.toHaveBeenCalled();
  });

  it("returns unknown model instead of throwing on missing provider/model", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();
    modelRegistry.find.mockReturnValue(undefined);

    const result = await backend.setModel("studio/qwen3-coder");

    expect(result).toEqual({ success: false, error: "Unknown model: studio/qwen3-coder" });
    expect(modelRegistry.find).toHaveBeenCalledWith("studio", "qwen3-coder");
    expect(piSession.setModel).not.toHaveBeenCalled();
  });

  it("refreshes the runtime model registry before resolving a requested model", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();
    const model = {
      provider: "omlx",
      id: "gemma-4-31b-bf16",
      name: "Gemma 4 31B",
    };
    modelRegistry.find.mockReturnValue(model);
    piSession.model = model;

    await backend.setModel("omlx/gemma-4-31b-bf16");

    expect(modelRegistry.refresh).toHaveBeenCalledTimes(1);
    expect(modelRegistry.find).toHaveBeenCalledWith("omlx", "gemma-4-31b-bf16");
    expect(modelRegistry.refresh.mock.invocationCallOrder[0]).toBeLessThan(
      modelRegistry.find.mock.invocationCallOrder[0] ?? Number.POSITIVE_INFINITY,
    );
  });

  it("sets models resolved from ModelRegistry (including custom providers)", async () => {
    const { backend, modelRegistry, piSession } = makeSetModelHarness();
    const model = {
      provider: "studio",
      id: "qwen3-coder",
      name: "Qwen3 Coder",
    };
    modelRegistry.find.mockReturnValue(model);
    piSession.model = model;

    const result = await backend.setModel("studio/qwen3-coder");

    expect(modelRegistry.find).toHaveBeenCalledWith("studio", "qwen3-coder");
    expect(piSession.setModel).toHaveBeenCalledWith(model);
    expect(result).toEqual({
      success: true,
      provider: "studio",
      id: "qwen3-coder",
      name: "Qwen3 Coder",
      thinkingLevel: "medium",
    });
  });
});

describe("SdkBackend.createPiSessionManager", () => {
  it("opens existing session files with the effective cwd override", () => {
    const cwd = "/workspace/clanker-farm";
    const session = {
      id: "sess-1",
      status: "starting",
      createdAt: 0,
      lastActivity: 0,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      piSessionFile: "/tmp/session.jsonl",
    } as Session;

    const persistedManager = { kind: "persisted" } as unknown as PiSdk.SessionManager;
    const inMemorySpy = vi.spyOn(PiSdk.SessionManager, "inMemory");
    const createSpy = vi.spyOn(PiSdk.SessionManager, "create");
    const openSpy = vi.spyOn(PiSdk.SessionManager, "open").mockReturnValue(persistedManager);

    try {
      const manager = (
        SdkBackend as unknown as {
          createPiSessionManager: (session: Session, cwd: string) => PiSdk.SessionManager;
        }
      ).createPiSessionManager(session, cwd);

      expect(manager).toBe(persistedManager);
      expect(openSpy).toHaveBeenCalledWith("/tmp/session.jsonl", undefined, cwd);
      expect(inMemorySpy).not.toHaveBeenCalled();
      expect(createSpy).not.toHaveBeenCalled();
    } finally {
      inMemorySpy.mockRestore();
      createSpy.mockRestore();
      openSpy.mockRestore();
    }
  });

  it("uses pi's in-memory session manager for incognito sessions", () => {
    const cwd = resolvePath(homedir(), "workspace", "oppi");
    const session = {
      id: "sess-1",
      status: "starting",
      createdAt: 0,
      lastActivity: 0,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      ephemeral: true,
    } as Session;

    const inMemoryManager = { kind: "in-memory" } as unknown as PiSdk.SessionManager;
    const persistedManager = { kind: "persisted" } as unknown as PiSdk.SessionManager;
    const inMemorySpy = vi.spyOn(PiSdk.SessionManager, "inMemory").mockReturnValue(inMemoryManager);
    const createSpy = vi.spyOn(PiSdk.SessionManager, "create").mockReturnValue(persistedManager);
    const openSpy = vi.spyOn(PiSdk.SessionManager, "open").mockReturnValue(persistedManager);

    try {
      const manager = (
        SdkBackend as unknown as {
          createPiSessionManager: (session: Session, cwd: string) => PiSdk.SessionManager;
        }
      ).createPiSessionManager(session, cwd);

      expect(manager).toBe(inMemoryManager);
      expect(inMemorySpy).toHaveBeenCalledWith(cwd);
      expect(createSpy).not.toHaveBeenCalled();
      expect(openSpy).not.toHaveBeenCalled();
    } finally {
      inMemorySpy.mockRestore();
      createSpy.mockRestore();
      openSpy.mockRestore();
    }
  });
});

describe("Oppi queue delivery defaults", () => {
  it("configures steering all and follow-up one-at-a-time for new sdk sessions", () => {
    const piSession = {
      setSteeringMode: vi.fn(),
      setFollowUpMode: vi.fn(),
    };

    (
      SdkBackend as unknown as {
        applyDefaultQueueModes: (session: typeof piSession) => void;
      }
    ).applyDefaultQueueModes(piSession);

    expect(piSession.setSteeringMode).toHaveBeenCalledWith("all");
    expect(piSession.setFollowUpMode).toHaveBeenCalledWith("one-at-a-time");
  });
});

describe("SdkBackend extension UI bridge", () => {
  interface CapturedRequest {
    id: string;
    method: string;
    title?: string;
    message?: string;
    options?: string[];
    questions?: AskQuestion[];
    allowCustom?: boolean;
    notifyType?: string;
    statusKey?: string;
    statusText?: string;
    widgetKey?: string;
    widgetLines?: string[];
    widgetPlacement?: string;
    nativeSurface?: ExtensionUINativeSurface;
    workingIndicator?: Record<string, unknown>;
    workingVisible?: boolean;
    hiddenThinkingLabel?: string;
    toolsExpanded?: boolean;
    text?: string;
  }

  interface HarnessResponse {
    value?: string;
    confirmed?: boolean;
    cancelled?: boolean;
  }

  function isExtensionUIRequestEvent(event: unknown): event is {
    type: "extension_ui_request";
    id: string;
    method: string;
    message?: string;
    options?: string[];
  } {
    if (typeof event !== "object" || event === null) {
      return false;
    }

    const record = event as Record<string, unknown>;
    return (
      record.type === "extension_ui_request" &&
      typeof record.id === "string" &&
      typeof record.method === "string"
    );
  }

  function makeCustomUIHarness(respond: (request: CapturedRequest) => HarnessResponse) {
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;

    const mutableBackend = backend as unknown as {
      disposed: boolean;
      uiBridge: SdkUiBridge;
      emitEvent: (event: unknown) => void;
    };

    mutableBackend.disposed = false;

    const requests: CapturedRequest[] = [];

    mutableBackend.emitEvent = (event: unknown) => {
      if (!isExtensionUIRequestEvent(event)) {
        return;
      }

      const record = event as Record<string, unknown>;
      const request: CapturedRequest = {
        id: event.id,
        method: event.method,
        title: typeof record.title === "string" ? record.title : undefined,
        message: event.message,
        options: event.options,
        questions:
          Array.isArray(record.questions) &&
          record.questions.every((value) => typeof value === "object" && value !== null)
            ? (record.questions as AskQuestion[])
            : undefined,
        allowCustom: typeof record.allowCustom === "boolean" ? record.allowCustom : undefined,
        notifyType: typeof record.notifyType === "string" ? record.notifyType : undefined,
        statusKey: typeof record.statusKey === "string" ? record.statusKey : undefined,
        statusText: typeof record.statusText === "string" ? record.statusText : undefined,
        widgetKey: typeof record.widgetKey === "string" ? record.widgetKey : undefined,
        widgetLines:
          Array.isArray(record.widgetLines) &&
          record.widgetLines.every((value) => typeof value === "string")
            ? (record.widgetLines as string[])
            : undefined,
        widgetPlacement:
          typeof record.widgetPlacement === "string" ? record.widgetPlacement : undefined,
        nativeSurface:
          record.nativeSurface && typeof record.nativeSurface === "object"
            ? (record.nativeSurface as ExtensionUINativeSurface)
            : undefined,
        workingIndicator:
          record.workingIndicator && typeof record.workingIndicator === "object"
            ? (record.workingIndicator as Record<string, unknown>)
            : undefined,
        workingVisible:
          typeof record.workingVisible === "boolean" ? record.workingVisible : undefined,
        hiddenThinkingLabel:
          typeof record.hiddenThinkingLabel === "string" ? record.hiddenThinkingLabel : undefined,
        toolsExpanded:
          typeof record.toolsExpanded === "boolean" ? record.toolsExpanded : undefined,
        text: typeof record.text === "string" ? record.text : undefined,
      };
      requests.push(request);

      const response = respond(request);
      queueMicrotask(() => {
        backend.respondToExtensionUIRequest({ id: request.id, ...response });
      });
    };
    mutableBackend.uiBridge = new SdkUiBridge(
      mutableBackend.emitEvent,
      () => mutableBackend.disposed,
    );

    const ui = (
      backend as unknown as {
        createExtensionUIContext: () => PiSdk.ExtensionUIContext;
      }
    ).createExtensionUIContext();

    return { backend, ui, requests };
  }

  it("forwards Pi notification, title, status, and string widget APIs", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.notify("Command allowed", "info");
    ui.setTitle("Review session");
    ui.setStatus("build", "Running checks");
    ui.setWidget("review", ["Review active"], { placement: "belowEditor" });
    ui.setWidget("review", undefined);

    expect(requests).toMatchObject([
      {
        method: "notify",
        message: "Command allowed",
        notifyType: "info",
      },
      {
        method: "setTitle",
        title: "Review session",
      },
      {
        method: "setStatus",
        statusKey: "build",
        statusText: "Running checks",
      },
      {
        method: "setWidget",
        widgetKey: "review",
        widgetLines: ["Review active"],
        widgetPlacement: "belowEditor",
      },
      {
        method: "setWidget",
        widgetKey: "review",
        widgetLines: undefined,
      },
    ]);
  });

  it("provides a snapshot theme on the UI context", () => {
    const { ui } = makeCustomUIHarness(() => ({ cancelled: true }));

    expect(ui.theme.bold("Review session active")).toBe("Review session active");
    expect(ui.theme.fg("warning", "Needs attention")).toBe("Needs attention");
    expect(ui.getAllThemes()).toEqual([]);
    expect(ui.getTheme("default")).toBeUndefined();
    expect(ui.setTheme("default")).toEqual({
      success: false,
      error: "Theme switching not supported in Oppi sessions",
    });
  });

  it("keeps Pi editor and terminal-only UI shims compatible with mobile sessions", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));
    let terminalInputCalled = false;

    const unsubscribe = ui.onTerminalInput(() => {
      terminalInputCalled = true;
    });
    unsubscribe();
    ui.setEditorText("draft from extension");
    ui.pasteToEditor("pasted from extension");
    ui.addAutocompleteProvider((current) => current);
    ui.setFooter(undefined);
    ui.setHeader(undefined);

    const editorFactory = (() => ({})) as Parameters<
      PiSdk.ExtensionUIContext["setEditorComponent"]
    >[0];
    ui.setEditorComponent(editorFactory);

    expect(requests).toMatchObject([
      {
        method: "set_editor_text",
        text: "draft from extension",
      },
      {
        method: "set_editor_text",
        text: "pasted from extension",
      },
    ]);
    expect(ui.getEditorText()).toBe("");
    expect(ui.getEditorComponent()).toBe(editorFactory);
    expect(terminalInputCalled).toBe(false);
  });

  it("forwards Pi working-row customizations into extension UI notifications", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.setWorkingMessage("Running checks");
    ui.setWorkingVisible(false);
    ui.setWorkingIndicator({ frames: ["●"], intervalMs: 250 });
    ui.setHiddenThinkingLabel("Private reasoning");
    ui.setToolsExpanded(true);

    expect(requests).toMatchObject([
      {
        method: "setWorkingMessage",
        message: "Running checks",
      },
      {
        method: "setWorkingVisible",
        workingVisible: false,
      },
      {
        method: "setWorkingIndicator",
        workingIndicator: { frames: ["●"], intervalMs: 250 },
      },
      {
        method: "setHiddenThinkingLabel",
        hiddenThinkingLabel: "Private reasoning",
      },
      {
        method: "setToolsExpanded",
        toolsExpanded: true,
      },
    ]);
    expect(ui.getToolsExpanded()).toBe(true);
  });

  it("renders component widgets into mobile-friendly line snapshots", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.setWidget("review", (_tui, theme) => ({
      render: () => [theme.fg("warning", "Review session active")],
    }));

    expect(requests).toHaveLength(1);
    expect(requests[0].method).toBe("setWidget");
    expect(requests[0].widgetLines).toEqual(["Review session active"]);
  });

  it("sanitizes terminal component widget snapshots before mobile projection", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.setWidget("links", () => ({
      render: () => ["Open \x1b]8;;oppi://session/child-1\x07child\x1b]8;;\x07 now"],
    }));

    expect(requests).toHaveLength(1);
    expect(requests[0].method).toBe("setWidget");
    expect(requests[0].widgetLines).toEqual(["Open child now"]);
  });

  it("forwards native surfaces from component widgets", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));
    let renderContext: { target: string; capabilities: string[] } | undefined;

    ui.setWidget("agents", () => ({
      render: () => ["● Agents", "  Running Explore files"],
      renderNative: (context) => {
        renderContext = context;
        return {
          version: 1,
          id: "widget:agents",
          source: "widget",
          presentation: { style: "surfacePanel", title: "Agents" },
          blocks: [
            {
              type: "activityList",
              id: "agents",
              rows: [
                {
                  id: "child-1",
                  title: "Explore files",
                  subtitle: "Running",
                  state: "running",
                  link: "oppi://session/child-1",
                },
              ],
            },
          ],
          fallback: { lines: ["● Agents", "  Running Explore files"] },
        };
      },
    }));

    expect(requests).toHaveLength(1);
    expect(renderContext).toEqual({
      target: "oppi-native-v1",
      capabilities: [
        "extension-native-ui:v1:text-fallback",
        "extension-native-ui:v1:surface-native",
      ],
      locale: undefined,
    });
    expect(requests[0].method).toBe("setWidget");
    expect(requests[0].widgetLines).toEqual(["● Agents", "  Running Explore files"]);
    expect(requests[0].nativeSurface?.id).toBe("widget:agents");
    expect(requests[0].nativeSurface?.blocks[0]?.type).toBe("activityList");
  });

  it("provides terminal dimensions to TUI component snapshots", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.setWidget("agents", (tui) => {
      const snapshotTui = tui as { terminal?: { columns?: number; rows?: number } };
      return {
        render: () => [
          `columns=${snapshotTui.terminal?.columns ?? "missing"}`,
          `rows=${snapshotTui.terminal?.rows ?? "missing"}`,
        ],
      };
    });

    expect(requests).toHaveLength(1);
    expect(requests[0].method).toBe("setWidget");
    expect(requests[0].widgetLines).toEqual(["columns=88", "rows=40"]);
  });

  it("re-renders component widgets when they request a render", async () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));
    let renderCount = 0;
    let requestRender: (() => void) | undefined;

    ui.setWidget("goal", (tui) => {
      requestRender = (tui as { requestRender: () => void }).requestRender;
      return {
        render: () => [`Goal tick ${renderCount}`],
      };
    });

    expect(requests).toHaveLength(1);
    expect(requests[0].widgetLines).toEqual(["Goal tick 0"]);

    renderCount = 1;
    requestRender?.();
    await Promise.resolve();

    expect(requests).toHaveLength(2);
    expect(requests[1].method).toBe("setWidget");
    expect(requests[1].widgetLines).toEqual(["Goal tick 1"]);
  });

  it("disposes component widgets when clearing them", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));
    let disposed = false;

    ui.setWidget("goal", () => ({
      render: () => ["Goal active"],
      dispose: () => {
        disposed = true;
      },
    }));
    ui.setWidget("goal", undefined);

    expect(disposed).toBe(true);
    expect(requests).toHaveLength(2);
    expect(requests[1].method).toBe("setWidget");
    expect(requests[1].widgetLines).toBeUndefined();
  });

  it("clears stale component widget projection when replacement factory throws", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.setWidget("goal", () => ({
      render: () => ["Goal active"],
    }));
    ui.setWidget("goal", () => {
      throw new Error("snapshot failed");
    });

    expect(requests).toHaveLength(3);
    expect(requests[0]).toMatchObject({
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: ["Goal active"],
    });
    expect(requests[1]).toMatchObject({
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: undefined,
    });
    expect(requests[2]).toMatchObject({
      method: "notify",
      notifyType: "warning",
      message: "Failed to render extension widget: snapshot failed",
    });
  });

  it("emits a direct ask request and parses structured answers", async () => {
    const answerPayload = { scope: "small", tools: ["jest", "vitest"] };
    const { ui, requests } = makeCustomUIHarness((request) => {
      if (request.method === "ask") {
        return { value: JSON.stringify(answerPayload) };
      }
      return { cancelled: true };
    });

    const ask = (
      ui as PiSdk.ExtensionUIContext & {
        ask: (
          questions: AskQuestion[],
          allowCustom?: boolean,
        ) => Promise<{ answers: Record<string, string | string[]>; allIgnored: boolean }>;
      }
    ).ask;

    const result = await ask(
      [
        {
          id: "scope",
          question: "Which scope?",
          options: [
            { value: "small", label: "Small" },
            { value: "large", label: "Large" },
          ],
        },
        {
          id: "tools",
          question: "Which tools?",
          options: [
            { value: "jest", label: "Jest" },
            { value: "vitest", label: "Vitest" },
          ],
          multiSelect: true,
        },
      ],
      false,
    );

    expect(requests).toHaveLength(1);
    expect(requests[0].method).toBe("ask");
    expect(requests[0].questions?.map((question) => question.id)).toEqual(["scope", "tools"]);
    expect(requests[0].allowCustom).toBe(false);
    expect(result).toEqual({ answers: answerPayload, allIgnored: false });
  });

  it("rejects empty ask requests before emitting UI events", async () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    const ask = (
      ui as PiSdk.ExtensionUIContext & {
        ask: (
          questions: AskQuestion[],
          allowCustom?: boolean,
        ) => Promise<{ answers: Record<string, string | string[]>; allIgnored: boolean }>;
      }
    ).ask;

    await expect(ask([], true)).rejects.toThrow(/ask UI requires at least one question/);
    expect(requests).toEqual([]);
  });

  it("rejects malformed ask responses instead of treating them as ignored", async () => {
    const { ui } = makeCustomUIHarness((request) => {
      if (request.method === "ask") {
        return { value: "not-json" };
      }
      return { cancelled: true };
    });

    const ask = (
      ui as PiSdk.ExtensionUIContext & {
        ask: (
          questions: AskQuestion[],
          allowCustom?: boolean,
        ) => Promise<{ answers: Record<string, string | string[]>; allIgnored: boolean }>;
      }
    ).ask;

    await expect(
      ask(
        [
          {
            id: "scope",
            question: "Which scope?",
            options: [
              { value: "small", label: "Small" },
              { value: "large", label: "Large" },
            ],
          },
        ],
        true,
      ),
    ).rejects.toThrow(/Malformed ask response:/);
  });

  it("does not invoke arbitrary custom TUI factories in Oppi sessions", async () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));
    let factoryCalled = false;

    const result = await ui.custom<string | undefined>(() => {
      factoryCalled = true;
      return { render: () => ["terminal-only"] };
    });

    expect(result).toBeUndefined();
    expect(factoryCalled).toBe(false);
    expect(requests).toHaveLength(0);
  });

  it("returns undefined for custom UI even if the factory would throw", async () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    const result = await ui.custom<string | undefined>(() => {
      throw new Error("terminal-only boom");
    });

    expect(result).toBeUndefined();
    expect(requests).toHaveLength(0);
  });
});

describe("SdkBackend.dispose", () => {
  function makeDisposeHarness() {
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;

    let resolveRuntimeDispose: (() => void) | null = null;
    const runtimeDisposePromise = new Promise<void>((resolve) => {
      resolveRuntimeDispose = resolve;
    });

    const runtime = {
      dispose: vi.fn(() => runtimeDisposePromise),
      session: {
        sessionId: "pi-session-1",
      },
    };

    const mutableBackend = backend as unknown as {
      disposed: boolean;
      uiBridge: { dispose: () => void };
      unsub: (() => void) | null;
      runtime: typeof runtime;
      shutdownCleanupPromise: Promise<void> | null;
      shutdownCleanupCompleted: boolean;
      shutdownCleanupListeners: Set<() => void>;
    };

    const pendingCancel = vi.fn();

    mutableBackend.disposed = false;
    mutableBackend.uiBridge = { dispose: pendingCancel };
    mutableBackend.unsub = vi.fn();
    mutableBackend.runtime = runtime;
    mutableBackend.shutdownCleanupPromise = null;
    mutableBackend.shutdownCleanupCompleted = false;
    mutableBackend.shutdownCleanupListeners = new Set();

    return {
      backend,
      runtime,
      pendingCancel,
      resolveRuntimeDispose: () => resolveRuntimeDispose?.(),
    };
  }

  it("waits for runtime teardown before resolving dispose", async () => {
    const { backend, runtime, pendingCancel, resolveRuntimeDispose } = makeDisposeHarness();

    let resolved = false;
    const disposePromise = backend.dispose().then(() => {
      resolved = true;
    });

    await new Promise((resolve) => setImmediate(resolve));

    expect(runtime.dispose).toHaveBeenCalledTimes(1);
    expect(pendingCancel).toHaveBeenCalledTimes(1);
    expect(resolved).toBe(false);

    resolveRuntimeDispose();
    await disposePromise;
    expect(resolved).toBe(true);
  });
});

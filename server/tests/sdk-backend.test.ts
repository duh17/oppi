import { homedir } from "node:os";
import { resolve as resolvePath } from "node:path";
import { describe, expect, it, vi } from "vitest";
import * as PiSdk from "@mariozechner/pi-coding-agent";

import { resolveSdkSessionCwd, SdkBackend } from "../src/sdk-backend.js";
import type { Session, Workspace } from "../src/types.js";

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

describe("SdkBackend.setModel", () => {
  function makeSetModelHarness() {
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;

    const modelRegistry = {
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
    });
  });
});

describe("SdkBackend.createPiSessionManager", () => {
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
      pendingExtensionResponses: Map<string, { cancel: () => void }>;
      unsub: (() => void) | null;
      runtime: typeof runtime;
      shutdownCleanupPromise: Promise<void> | null;
      shutdownCleanupCompleted: boolean;
      shutdownCleanupListeners: Set<() => void>;
    };

    const pendingCancel = vi.fn();

    mutableBackend.disposed = false;
    mutableBackend.pendingExtensionResponses = new Map([
      ["req-1", { cancel: pendingCancel }],
    ]);
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

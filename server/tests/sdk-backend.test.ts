import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve as resolvePath } from "node:path";
import { describe, expect, it, vi } from "vitest";
import * as PiSdk from "@earendil-works/pi-coding-agent";

import { hostMountValidationError } from "../src/host.js";
import { resolveSdkSessionCwd, SdkBackend } from "../src/sdk-backend.js";
import { SdkUiBridge } from "../src/sdk-ui-bridge.js";
import type { AskQuestion, Session, Workspace } from "../src/types.js";

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

describe("SdkBackend custom UI compatibility", () => {
  interface CapturedRequest {
    id: string;
    method: string;
    message?: string;
    options?: string[];
    questions?: AskQuestion[];
    allowCustom?: boolean;
    widgetLines?: string[];
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
        message: event.message,
        options: event.options,
        questions:
          Array.isArray(record.questions) &&
          record.questions.every((value) => typeof value === "object" && value !== null)
            ? (record.questions as AskQuestion[])
            : undefined,
        allowCustom: typeof record.allowCustom === "boolean" ? record.allowCustom : undefined,
        widgetLines:
          Array.isArray(record.widgetLines) &&
          record.widgetLines.every((value) => typeof value === "string")
            ? (record.widgetLines as string[])
            : undefined,
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

  it("renders component widgets into mobile-friendly line snapshots", () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    ui.setWidget("review", (_tui, theme) => ({
      render: () => [theme.fg("warning", "Review session active")],
    }));

    expect(requests).toHaveLength(1);
    expect(requests[0].method).toBe("setWidget");
    expect(requests[0].widgetLines).toEqual(["Review session active"]);
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

  it("routes keyboard-only custom selectors through compatibility controls", async () => {
    const selectResponses = ["↓ Down", "⏎ Enter"];
    const { ui, requests } = makeCustomUIHarness((request) => {
      if (request.method === "select") {
        return { value: selectResponses.shift() ?? "Cancel" };
      }

      return { cancelled: true };
    });

    const result = await ui.custom<string | undefined>((_tui, _theme, keybindings, done) => {
      const options = ["alpha", "beta"];
      let index = 0;

      const kb = keybindings as { matches: (data: string, keybinding: string) => boolean };

      return {
        render: () => [`selection: ${options[index]}`],
        handleInput: (data: string) => {
          if (kb.matches(data, "tui.select.down")) {
            index = Math.min(options.length - 1, index + 1);
            return;
          }

          if (kb.matches(data, "tui.select.up")) {
            index = Math.max(0, index - 1);
            return;
          }

          if (kb.matches(data, "tui.select.confirm")) {
            done(options[index]);
          }
        },
      };
    });

    expect(result).toBe("beta");
    expect(requests).toHaveLength(2);
    expect(requests[0].message).toContain("selection: alpha");
    expect(requests[1].message).toContain("selection: beta");
  });

  it("supports text entry in compatibility mode", async () => {
    const selectResponses = ["Type text…", "⏎ Enter"];
    const { ui, requests } = makeCustomUIHarness((request) => {
      if (request.method === "select") {
        return { value: selectResponses.shift() ?? "Cancel" };
      }
      if (request.method === "input") {
        return { value: "release" };
      }

      return { cancelled: true };
    });

    const result = await ui.custom<string | undefined>((_tui, _theme, keybindings, done) => {
      let value = "";
      const kb = keybindings as { matches: (data: string, keybinding: string) => boolean };

      return {
        render: () => [`typed: ${value}`],
        handleInput: (data: string) => {
          if (kb.matches(data, "tui.select.confirm")) {
            done(value);
            return;
          }

          value += data;
        },
      };
    });

    expect(result).toBe("release");
    expect(requests.some((request) => request.method === "input")).toBe(true);
  });

  it("returns undefined when compatibility dialog is cancelled", async () => {
    const { ui } = makeCustomUIHarness((request) => {
      if (request.method === "select") {
        return { cancelled: true };
      }
      return { cancelled: true };
    });

    const result = await ui.custom<string | undefined>(() => ({
      render: () => ["idle"],
    }));

    expect(result).toBeUndefined();
  });

  it("rethrows custom UI failures after emitting a warning notification", async () => {
    const { ui, requests } = makeCustomUIHarness(() => ({ cancelled: true }));

    await expect(
      ui.custom<string>(() => {
        throw new Error("compat boom");
      }),
    ).rejects.toThrow("compat boom");

    expect(
      requests.some(
        (request) =>
          request.method === "notify" &&
          request.message?.includes("Extension custom UI failed: compat boom") === true,
      ),
    ).toBe(true);
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

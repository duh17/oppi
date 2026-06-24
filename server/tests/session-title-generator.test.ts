import { beforeEach, describe, expect, it, vi } from "vitest";

const mockCompleteSimple = vi.hoisted(() => vi.fn());

vi.mock("../src/pi-model-auth-service.js", async () => {
  const actual = await vi.importActual<typeof import("../src/pi-model-auth-service.js")>(
    "../src/pi-model-auth-service.js",
  );
  return {
    ...actual,
    completeSimpleWithPiModel: mockCompleteSimple,
  };
});

import {
  normalizeTitle,
  DisabledProvider,
  ApiModelTitleProvider,
  SessionTitleGenerator,
  type SessionTitleGeneratorDeps,
  type TitleGenerationMetrics,
} from "../src/session-title-generator.js";

// ─── normalizeTitle ───

describe("normalizeTitle", () => {
  it("returns null for null/undefined/empty", () => {
    expect(normalizeTitle(null)).toBeNull();
    expect(normalizeTitle(undefined)).toBeNull();
    expect(normalizeTitle("")).toBeNull();
    expect(normalizeTitle("   ")).toBeNull();
  });

  it("takes first line only", () => {
    expect(normalizeTitle("Fix WebSocket Bug\nSome extra text")).toBe("Fix WebSocket Bug");
  });

  it("strips Title: prefix (case-insensitive)", () => {
    expect(normalizeTitle("Title: Fix WebSocket Bug")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("title: Fix WebSocket Bug")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("TITLE:  Fix WebSocket Bug")).toBe("Fix WebSocket Bug");
  });

  it("strips wrapping quotes (straight, curly, backticks)", () => {
    expect(normalizeTitle('"Fix WebSocket Bug"')).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("'Fix WebSocket Bug'")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("`Fix WebSocket Bug`")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("\u201cFix WebSocket Bug\u201d")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("\u2018Fix WebSocket Bug\u2019")).toBe("Fix WebSocket Bug");
  });

  it("strips wrapping brackets and parens", () => {
    expect(normalizeTitle("[Fix WebSocket Bug]")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("(Fix WebSocket Bug)")).toBe("Fix WebSocket Bug");
  });

  it("strips trailing punctuation", () => {
    expect(normalizeTitle("Fix WebSocket Bug.")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("Fix WebSocket Bug!")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("Fix WebSocket Bug?")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("Fix WebSocket Bug;")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("Fix WebSocket Bug:")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("Fix WebSocket Bug,")).toBe("Fix WebSocket Bug");
  });

  it("collapses whitespace", () => {
    expect(normalizeTitle("Fix   WebSocket   Bug")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("  Fix  WebSocket  Bug  ")).toBe("Fix WebSocket Bug");
  });

  it("caps at 48 chars at word boundary", () => {
    const long = "Investigate Really Long Session Title That Exceeds The Maximum Allowed Length";
    const result = normalizeTitle(long);
    expect(result).not.toBeNull();
    expect(result!.length).toBeLessThanOrEqual(48);
    // Should break at a word boundary
    expect(result).not.toMatch(/\s$/);
  });

  it("handles combined artifacts", () => {
    expect(normalizeTitle('Title: "Fix WebSocket Bug!"')).toBe("Fix WebSocket Bug");
  });

  it("preserves valid titles", () => {
    expect(normalizeTitle("Fix WebSocket Bug")).toBe("Fix WebSocket Bug");
    expect(normalizeTitle("Debug Auth Flow")).toBe("Debug Auth Flow");
  });

  it("returns null if nothing left after stripping", () => {
    expect(normalizeTitle('""')).toBeNull();
    expect(normalizeTitle("Title:")).toBeNull();
    expect(normalizeTitle("...")).toBeNull();
  });
});

// ─── DisabledProvider ───

describe("DisabledProvider", () => {
  it("returns null", async () => {
    const provider = new DisabledProvider();
    expect(provider.name).toBe("disabled");
    expect(await provider.generateTitle("fix the websocket bug")).toBeNull();
  });
});

// ─── ApiModelTitleProvider ───

describe("ApiModelTitleProvider", () => {
  it("returns null when model is not found", async () => {
    const mockRegistry = {
      find: vi.fn(() => undefined),
      getApiKey: vi.fn(),
    };
    const onMetrics = vi.fn();
    const provider = new ApiModelTitleProvider(
      "anthropic/nonexistent",
      mockRegistry as never,
      onMetrics,
    );
    const result = await provider.generateTitle("fix the websocket bug");
    expect(result).toBeNull();
    expect(onMetrics).toHaveBeenCalledWith(
      expect.objectContaining({ status: "error", model: "anthropic/nonexistent" }),
    );
  });

  it("reports metrics on error", async () => {
    const mockRegistry = {
      find: vi.fn(() => undefined),
      getApiKey: vi.fn(),
    };
    const onMetrics = vi.fn();
    const provider = new ApiModelTitleProvider("bad/model-id", mockRegistry as never, onMetrics);
    await provider.generateTitle("some message");
    expect(onMetrics).toHaveBeenCalledTimes(1);
    const metrics = onMetrics.mock.calls[0][0] as TitleGenerationMetrics;
    expect(metrics.status).toBe("error");
    expect(metrics.durationMs).toBeGreaterThanOrEqual(0);
    expect(metrics.tokens).toBe(0);
  });

  it("returns null for unparseable model ID", async () => {
    const mockRegistry = {
      find: vi.fn(() => undefined),
      getApiKey: vi.fn(),
    };
    const provider = new ApiModelTitleProvider("no-slash", mockRegistry as never);
    const result = await provider.generateTitle("fix the websocket bug");
    expect(result).toBeNull();
  });
});

// ─── SessionTitleGenerator (orchestrator) ───

describe("SessionTitleGenerator", () => {
  beforeEach(() => {
    mockCompleteSimple.mockReset();
  });

  function successfulModelRegistry() {
    return {
      find: vi.fn(() => ({ provider: "anthropic", id: "claude-haiku-3" })),
      getApiKeyAndHeaders: vi.fn(async () => ({ ok: true, apiKey: "test-key", headers: {} })),
    } as never;
  }

  function waitForMetrics(): {
    onMetrics: (metrics: TitleGenerationMetrics) => void;
    metrics: Promise<TitleGenerationMetrics>;
  } {
    let resolveMetrics!: (metrics: TitleGenerationMetrics) => void;
    const metrics = new Promise<TitleGenerationMetrics>((resolve) => {
      resolveMetrics = resolve;
    });
    return {
      onMetrics: (value) => resolveMetrics(value),
      metrics,
    };
  }

  function makeDeps(overrides?: Partial<SessionTitleGeneratorDeps>): SessionTitleGeneratorDeps {
    return {
      getConfig: () => ({ enabled: true, model: "anthropic/claude-haiku-3" }),
      modelRegistry: { find: vi.fn(() => undefined), getApiKey: vi.fn() } as never,
      getSession: vi.fn((id: string) => ({ id, name: undefined })),
      setSessionName: vi.fn(),
      broadcastSessionUpdate: vi.fn(),
      onMetrics: vi.fn(),
      ...overrides,
    };
  }

  it("skips when disabled", () => {
    const deps = makeDeps({
      getConfig: () => ({ enabled: false }),
    });
    const gen = new SessionTitleGenerator(deps);
    gen.tryGenerateTitle({ id: "s1", firstMessage: "fix the websocket reconnect bug" });
    // Should not even attempt — no async work
    expect(deps.setSessionName).not.toHaveBeenCalled();
  });

  it("skips when session already has a name", () => {
    const deps = makeDeps();
    const gen = new SessionTitleGenerator(deps);
    gen.tryGenerateTitle({
      id: "s1",
      name: "Existing Title",
      firstMessage: "fix the websocket reconnect bug",
    });
    expect(deps.setSessionName).not.toHaveBeenCalled();
  });

  it("skips when firstMessage is too short", () => {
    const deps = makeDeps();
    const gen = new SessionTitleGenerator(deps);
    gen.tryGenerateTitle({ id: "s1", firstMessage: "hi" });
    expect(deps.setSessionName).not.toHaveBeenCalled();
  });

  it("skips when no model configured", () => {
    const deps = makeDeps({
      getConfig: () => ({ enabled: true, model: undefined }),
    });
    const gen = new SessionTitleGenerator(deps);
    gen.tryGenerateTitle({ id: "s1", firstMessage: "fix the websocket reconnect bug" });
    expect(deps.setSessionName).not.toHaveBeenCalled();
  });

  it("sets generated titles through the Pi session name setter", async () => {
    mockCompleteSimple.mockResolvedValue({
      content: [{ type: "text", text: "Fix WebSocket Reconnect" }],
      usage: { input: 10, output: 4, cacheRead: 0 },
    });
    const { onMetrics, metrics } = waitForMetrics();
    let resolveBroadcast!: () => void;
    const broadcastCalled = new Promise<void>((resolve) => {
      resolveBroadcast = resolve;
    });
    const deps = makeDeps({
      modelRegistry: successfulModelRegistry(),
      onMetrics,
      setSessionName: vi.fn(),
      broadcastSessionUpdate: vi.fn(() => resolveBroadcast()),
    });
    const gen = new SessionTitleGenerator(deps);

    gen.tryGenerateTitle({ id: "s1", firstMessage: "fix the websocket reconnect bug" });
    await metrics;
    await broadcastCalled;

    expect(deps.setSessionName).toHaveBeenCalledWith("s1", "Fix WebSocket Reconnect");
    expect(deps.broadcastSessionUpdate).toHaveBeenCalledWith("s1");
  });

  it("skips setting a title if session name was set during generation", async () => {
    mockCompleteSimple.mockResolvedValue({
      content: [{ type: "text", text: "Fix WebSocket Reconnect" }],
      usage: { input: 10, output: 4, cacheRead: 0 },
    });
    const { onMetrics, metrics } = waitForMetrics();
    const deps = makeDeps({
      getSession: vi.fn(() => ({ id: "s1", name: "Already Named" })),
      modelRegistry: successfulModelRegistry(),
      onMetrics,
    });
    const gen = new SessionTitleGenerator(deps);

    gen.tryGenerateTitle({ id: "s1", firstMessage: "fix the websocket reconnect bug" });
    await metrics;

    expect(deps.setSessionName).not.toHaveBeenCalled();
    expect(deps.broadcastSessionUpdate).not.toHaveBeenCalled();
  });

  it("skips setting a title if session no longer exists", async () => {
    mockCompleteSimple.mockResolvedValue({
      content: [{ type: "text", text: "Fix WebSocket Reconnect" }],
      usage: { input: 10, output: 4, cacheRead: 0 },
    });
    const { onMetrics, metrics } = waitForMetrics();
    const deps = makeDeps({
      getSession: vi.fn(() => undefined),
      modelRegistry: successfulModelRegistry(),
      onMetrics,
    });
    const gen = new SessionTitleGenerator(deps);

    gen.tryGenerateTitle({ id: "s1", firstMessage: "fix the websocket reconnect bug" });
    await metrics;

    expect(deps.setSessionName).not.toHaveBeenCalled();
    expect(deps.broadcastSessionUpdate).not.toHaveBeenCalled();
  });
});

// ─── appendSessionMessage trigger ───

describe("appendSessionMessage trigger", () => {
  it("returns true when firstMessage is first captured", async () => {
    // Import the actual function
    const { appendSessionMessage } = await import("../src/session-protocol.js");
    const session: Record<string, unknown> = {
      id: "s1",
      status: "ready" as const,
      createdAt: Date.now(),
      lastActivity: Date.now(),
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };

    const result = appendSessionMessage(session as never, {
      role: "user",
      content: "fix the websocket reconnect state drift in the session manager",
      timestamp: Date.now(),
    });

    expect(result).toBe(true);
    expect(session.firstMessage).toBe(
      "fix the websocket reconnect state drift in the session manager",
    );
  });

  it("returns false for subsequent user messages", async () => {
    const { appendSessionMessage } = await import("../src/session-protocol.js");
    const session = {
      id: "s1",
      status: "ready" as const,
      createdAt: Date.now(),
      lastActivity: Date.now(),
      messageCount: 1,
      firstMessage: "first message",
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };

    const result = appendSessionMessage(session, {
      role: "user",
      content: "second message",
      timestamp: Date.now(),
    });

    expect(result).toBe(false);
    expect(session.firstMessage).toBe("first message");
  });

  it("returns false for assistant messages", async () => {
    const { appendSessionMessage } = await import("../src/session-protocol.js");
    const session: Record<string, unknown> = {
      id: "s1",
      status: "ready" as const,
      createdAt: Date.now(),
      lastActivity: Date.now(),
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };

    const result = appendSessionMessage(session as never, {
      role: "assistant",
      content: "I'll help you fix that",
      timestamp: Date.now(),
    });

    expect(result).toBe(false);
    expect(session.firstMessage).toBeUndefined();
  });
});

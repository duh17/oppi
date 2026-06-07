import { describe, expect, it, vi } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
import type { Session, Workspace } from "../src/types.js";

// ─── Factories ───

function makeWorkspace(overrides?: Partial<Workspace>): Workspace {
  return {
    id: "ws-1",
    name: "test-workspace",
    ...overrides,
  } as Workspace;
}

function makeSession(overrides?: Partial<Session>): Session {
  return {
    id: "sess-1",
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeRequestBody(body: Record<string, unknown>): IncomingMessage {
  const stream = new PassThrough();
  stream.end(JSON.stringify(body));
  // Cast PassThrough as IncomingMessage — only the readable stream interface matters
  return stream as unknown as IncomingMessage;
}

interface MockRouteContext {
  ctx: RouteContext;
  helpers: RouteHelpers;
  responses: Array<{ data: unknown; status: number }>;
  errors: Array<{ status: number; message: string }>;
  sessions: {
    startSession: ReturnType<typeof vi.fn>;
    sendPrompt: ReturnType<typeof vi.fn>;
    isActive: ReturnType<typeof vi.fn>;
    getActiveSessionIds: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
    forwardClientCommand: ReturnType<typeof vi.fn>;
    stopSession: ReturnType<typeof vi.fn>;
    getToolFullOutputPath: ReturnType<typeof vi.fn>;
    getCatchUp: ReturnType<typeof vi.fn>;
    refreshSessionState: ReturnType<typeof vi.fn>;
    runCommand: ReturnType<typeof vi.fn>;
  };
  storage: {
    getDataDir: ReturnType<typeof vi.fn>;
    getWorkspace: ReturnType<typeof vi.fn>;
    createSession: ReturnType<typeof vi.fn>;
    saveSession: ReturnType<typeof vi.fn>;
    getSession: ReturnType<typeof vi.fn>;
    deleteSession: ReturnType<typeof vi.fn>;
    listSessions: ReturnType<typeof vi.fn>;
  };
  sessionRuntimes: {
    getActiveSessionIds: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
    getPendingUIRequestMessages: ReturnType<typeof vi.fn>;
    isSessionConnected: ReturnType<typeof vi.fn>;
    isSessionLive: ReturnType<typeof vi.fn>;
    getSessionSnapshot: ReturnType<typeof vi.fn>;
    stopSession: ReturnType<typeof vi.fn>;
    stopSessionIfActive: ReturnType<typeof vi.fn>;
    refreshSessionState: ReturnType<typeof vi.fn>;
    getToolFullOutputPath: ReturnType<typeof vi.fn>;
    getCatchUp: ReturnType<typeof vi.fn>;
  };
  piTuiRuntime: {
    isSessionConnected: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
    stopSession: ReturnType<typeof vi.fn>;
    getToolFullOutputPath: ReturnType<typeof vi.fn>;
    getCatchUp: ReturnType<typeof vi.fn>;
  };
}

function createMockContext(workspace?: Workspace): MockRouteContext {
  const ws = workspace ?? makeWorkspace();
  const responses: Array<{ data: unknown; status: number }> = [];
  const errors: Array<{ status: number; message: string }> = [];

  const storage = {
    getDataDir: vi.fn().mockReturnValue("/tmp/oppi-routes-sessions-create-tests"),
    getWorkspace: vi.fn().mockReturnValue(ws),
    createSession: vi.fn().mockImplementation((name?: string, model?: string) =>
      makeSession({
        id: `sess-${Date.now()}`,
        name: name ?? undefined,
        model: model ?? "test-model",
      }),
    ),
    saveSession: vi.fn(),
    getSession: vi.fn(),
    deleteSession: vi.fn().mockReturnValue(true),
    listSessions: vi.fn().mockReturnValue([]),
  };

  const sessions = {
    startSession: vi
      .fn()
      .mockImplementation(async (sessionId: string) =>
        makeSession({ id: sessionId, status: "ready" }),
      ),
    sendPrompt: vi.fn().mockResolvedValue(undefined),
    isActive: vi.fn().mockReturnValue(false),
    getActiveSessionIds: vi.fn().mockReturnValue(new Set<string>()),
    getActiveSession: vi.fn().mockReturnValue(undefined),
    stopSession: vi.fn().mockResolvedValue(undefined),
    getToolFullOutputPath: vi.fn().mockReturnValue(undefined),
    getCatchUp: vi.fn().mockReturnValue({ events: [], currentSeq: 0, catchUpComplete: true }),
    refreshSessionState: vi.fn().mockResolvedValue(undefined),
    runCommand: vi.fn().mockResolvedValue(undefined),
    forwardClientCommand: vi.fn().mockResolvedValue(undefined),
  };

  const piTuiRuntime = {
    isSessionConnected: vi.fn(() => false),
    getActiveSession: vi.fn(() => undefined as Session | undefined),
    stopSession: vi.fn().mockResolvedValue(undefined),
    getToolFullOutputPath: vi.fn().mockReturnValue(undefined),
    getCatchUp: vi.fn().mockReturnValue({ events: [], currentSeq: 0, catchUpComplete: true }),
  };

  const sessionRuntimes = {
    getActiveSessionIds: vi.fn(() => sessions.getActiveSessionIds?.() ?? new Set<string>()),
    getActiveSession: vi.fn((sessionId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      if (session?.runtime === "pi-tui") {
        return piTuiRuntime.isSessionConnected(sessionId)
          ? piTuiRuntime.getActiveSession(sessionId)
          : undefined;
      }
      return sessions.getActiveSession(sessionId);
    }),
    getPendingUIRequestMessages: vi.fn(() => []),
    isSessionConnected: vi.fn((sessionId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      if (session?.runtime === "pi-tui") {
        return piTuiRuntime.isSessionConnected(sessionId) === true;
      }
      return sessions.isActive(sessionId) === true;
    }),
    isSessionLive: vi.fn((sessionId: string) => sessionRuntimes.isSessionConnected(sessionId)),
    getSessionSnapshot: vi.fn((sessionId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      if (session?.runtime === "pi-tui") {
        return piTuiRuntime.getActiveSession(sessionId) ?? session;
      }
      return sessions.getActiveSession(sessionId) ?? session;
    }),
    stopSession: vi.fn(async (sessionId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      if (session?.runtime === "pi-tui") {
        await piTuiRuntime.stopSession(sessionId);
        return;
      }
      await sessions.stopSession(sessionId);
    }),
    stopSessionIfActive: vi.fn(async (sessionId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      if (session?.runtime === "pi-tui") {
        if (piTuiRuntime.isSessionConnected(sessionId) === true) {
          await piTuiRuntime.stopSession(sessionId);
        }
        return;
      }
      if (sessions.isActive(sessionId)) {
        await sessions.stopSession(sessionId);
      }
    }),
    refreshSessionState: vi.fn((sessionId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      if (session?.runtime === "pi-tui") {
        return {
          sessionFile: session.piSessionFile,
          sessionId: session.piSessionId,
        };
      }
      return sessions.refreshSessionState(sessionId);
    }),
    getToolFullOutputPath: vi.fn((sessionId: string, toolCallId: string) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      return session?.runtime === "pi-tui"
        ? piTuiRuntime.getToolFullOutputPath(sessionId, toolCallId)
        : sessions.getToolFullOutputPath(sessionId, toolCallId);
    }),
    getCatchUp: vi.fn((sessionId: string, sinceSeq: number) => {
      const session = storage.getSession(sessionId) as Session | undefined;
      return session?.runtime === "pi-tui"
        ? piTuiRuntime.getCatchUp(sessionId, sinceSeq)
        : sessions.getCatchUp(sessionId, sinceSeq);
    }),
  };

  const ctx = {
    storage,
    sessions,
    sessionRuntimes,
    gate: {} as RouteContext["gate"],
    skillRegistry: {} as RouteContext["skillRegistry"],
    userSkillStore: {} as RouteContext["userSkillStore"],
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => ws,
    refreshModelCatalog: vi.fn().mockResolvedValue(undefined),
    getModelCatalog: vi.fn().mockReturnValue([]),
    getRuntimeUpdateStatus: vi.fn().mockResolvedValue({ upToDate: true }),
    runRuntimeUpdate: vi.fn().mockResolvedValue({ success: true }),
    serverStartedAt: Date.now(),
    serverVersion: "test",
    piVersion: "test",
  } as unknown as RouteContext;

  const helpers: RouteHelpers = {
    parseBody: async <T>(req: IncomingMessage): Promise<T> => {
      const chunks: Buffer[] = [];
      for await (const chunk of req) {
        chunks.push(chunk as Buffer);
      }
      const raw = Buffer.concat(chunks).toString("utf-8");
      return raw.length > 0 ? JSON.parse(raw) : ({} as T);
    },
    json: (res: ServerResponse, data: unknown, status?: number) => {
      responses.push({ data, status: status ?? 200 });
    },
    compressedJson: (req: IncomingMessage, res: ServerResponse, data: unknown, status?: number) => {
      responses.push({ data, status: status ?? 200 });
    },
    error: (res: ServerResponse, status: number, message: string) => {
      errors.push({ status, message });
    },
  };

  return { ctx, helpers, responses, errors, sessions, storage, sessionRuntimes, piTuiRuntime };
}

// ─── Tests ───

describe("POST /workspaces/:id/sessions", () => {
  async function dispatchCreate(
    mock: MockRouteContext,
    body: Record<string, unknown>,
  ): Promise<boolean> {
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const req = makeRequestBody(body);
    const res = {} as ServerResponse;
    const url = new URL("https://localhost/workspaces/ws-1/sessions");
    return dispatcher({ method: "POST", path: "/workspaces/ws-1/sessions", url, req, res });
  }

  it("creates session without prompt (existing behavior)", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { name: "test" });

    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);

    const response = mock.responses[0]!.data as { session: Session; prompted?: boolean };
    expect(response.session).toBeDefined();
    expect(response.prompted).toBeUndefined();

    // Should NOT start or prompt
    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();
  });

  it("creates session and dispatches prompt when prompt is provided", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { name: "quick ask", prompt: "What is 2+2?" });

    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);

    const response = mock.responses[0]!.data as { session: Session; prompted: boolean };
    expect(response.prompted).toBe(true);

    // Should start session then send prompt
    expect(mock.sessions.startSession).toHaveBeenCalledTimes(1);
    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);

    // Verify prompt text was passed through
    const promptCall = mock.sessions.sendPrompt.mock.calls[0]!;
    expect(promptCall[1]).toBe("What is 2+2?");
  });

  it("trims whitespace from prompt", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "  hello world  " });

    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);
    const promptCall = mock.sessions.sendPrompt.mock.calls[0]!;
    expect(promptCall[1]).toBe("hello world");
  });

  it("ignores empty/whitespace-only prompt", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "   " });

    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();

    // Should still create session normally
    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);

    const response = mock.responses[0]!.data as { session: Session; prompted?: boolean };
    expect(response.prompted).toBeUndefined();
  });

  it("returns prompted: false when startSession fails", async () => {
    const mock = createMockContext();
    mock.sessions.startSession.mockRejectedValue(new Error("workspace locked"));

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);

    const response = mock.responses[0]!.data as { session: Session; prompted: boolean };
    expect(response.prompted).toBe(false);

    // Should not have attempted sendPrompt
    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();
  });

  it("returns prompted: false when sendPrompt fails", async () => {
    const mock = createMockContext();
    mock.sessions.sendPrompt.mockRejectedValue(new Error("pi not ready"));

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);

    const response = mock.responses[0]!.data as { session: Session; prompted: boolean };
    expect(response.prompted).toBe(false);
  });

  it("sets firstMessage on session when prompt is provided", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "Tell me about TypeScript" });

    // saveSession should be called twice: once for initial create, once after prompt
    expect(mock.storage.saveSession).toHaveBeenCalledTimes(2);

    const secondSave = mock.storage.saveSession.mock.calls[1]![0] as Session;
    expect(secondSave.firstMessage).toBe("Tell me about TypeScript");
  });

  it("truncates firstMessage to 200 chars", async () => {
    const mock = createMockContext();
    const longPrompt = "x".repeat(500);

    await dispatchCreate(mock, { prompt: longPrompt });

    const secondSave = mock.storage.saveSession.mock.calls[1]![0] as Session;
    expect(secondSave.firstMessage).toHaveLength(200);
  });

  it("uses model from body when provided", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", model: "custom-model" });

    expect(mock.storage.createSession).toHaveBeenCalledWith(undefined, "custom-model");
  });

  it("uses workspace default model when request omits model", async () => {
    const mock = createMockContext(makeWorkspace({ defaultModel: "openai-codex/gpt-5.4" }));

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.storage.createSession).toHaveBeenCalledWith(undefined, "openai-codex/gpt-5.4");
  });

  it("omits model when request does not specify one so Pi settings choose", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.storage.createSession).toHaveBeenCalledWith(undefined, undefined);
  });

  it("inherits parent session model before workspace default", async () => {
    const mock = createMockContext(makeWorkspace({ defaultModel: "ds4/deepseek-v4-flash" }));
    mock.storage.getSession.mockReturnValue(
      makeSession({
        id: "parent-1",
        workspaceId: "ws-1",
        model: "openai-codex/gpt-5.5",
      }),
    );

    await dispatchCreate(mock, { prompt: "hello", parentSessionId: "parent-1" });

    expect(mock.storage.createSession).toHaveBeenCalledWith(undefined, "openai-codex/gpt-5.5");
  });

  it("passes workspace to startSession", async () => {
    const ws = makeWorkspace({ id: "ws-42" });
    const mock = createMockContext(ws);

    await dispatchCreate(mock, { prompt: "hello" });

    const startCall = mock.sessions.startSession.mock.calls[0]!;
    expect(startCall[1]).toBe(ws);
  });

  it("sets thinking level before sending prompt when thinking is provided", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", thinking: "high" });

    // forwardClientCommand should be called before sendPrompt
    expect(mock.sessions.forwardClientCommand).toHaveBeenCalledTimes(1);
    const fwdCall = mock.sessions.forwardClientCommand.mock.calls[0]!;
    expect(fwdCall[1]).toEqual({ type: "set_thinking_level", level: "high" });

    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);
  });

  it("persists thinking level on session object after forwardClientCommand", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", thinking: "high" });

    // The final saveSession call should include thinkingLevel on the session
    const lastSaveIndex = mock.storage.saveSession.mock.calls.length - 1;
    const savedSession = mock.storage.saveSession.mock.calls[lastSaveIndex]![0] as Session;
    expect(savedSession.thinkingLevel).toBe("high");
  });

  it("skips thinking level when not provided", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.sessions.forwardClientCommand).not.toHaveBeenCalled();
    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);
  });

  it("persists thinking level for promptless session creation", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { thinking: "high" });

    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.forwardClientCommand).not.toHaveBeenCalled();
    const lastSaveIndex = mock.storage.saveSession.mock.calls.length - 1;
    const savedSession = mock.storage.saveSession.mock.calls[lastSaveIndex]![0] as Session;
    expect(savedSession.thinkingLevel).toBe("high");
  });

  it("rejects legacy raw images on session creation", async () => {
    const mock = createMockContext();
    const images = [{ type: "image" as const, data: "base64data", mimeType: "image/jpeg" }];

    await dispatchCreate(mock, { prompt: "look at this", images });

    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();
    expect(mock.errors).toEqual([
      {
        status: 400,
        message:
          "Raw base64 image transport is not supported; upload images as chat attachments first",
      },
    ]);
  });

  it("passes attachments to sendPrompt when provided", async () => {
    const mock = createMockContext();
    const attachments = [
      {
        type: "attachment" as const,
        id: "att-1",
        source: "workspace" as const,
        name: "README.md",
        mimeType: "text/markdown",
        sizeBytes: 123,
        workspacePath: "README.md",
      },
    ];

    await dispatchCreate(mock, { prompt: "use this file", attachments });

    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);
    const promptCall = mock.sessions.sendPrompt.mock.calls[0]!;
    expect(promptCall[2]).toEqual({ attachments });
  });

  it("persists ephemeral flag for incognito sessions", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { name: "secret", ephemeral: true });

    expect(mock.storage.saveSession).toHaveBeenCalledTimes(1);
    const savedSession = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(savedSession.ephemeral).toBe(true);
  });

  it("keeps incognito prompt flow working", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "quietly", ephemeral: true });

    expect(mock.sessions.startSession).toHaveBeenCalledTimes(1);
    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);
    const firstSave = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(firstSave.ephemeral).toBe(true);
  });

  it("returns 404 for unknown workspace", async () => {
    const mock = createMockContext();
    mock.storage.getWorkspace.mockReturnValue(undefined);

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.errors).toHaveLength(1);
    expect(mock.errors[0]!.status).toBe(404);
    expect(mock.responses).toHaveLength(0);
  });

  it("persists parentSessionId when the parent belongs to the workspace", async () => {
    const mock = createMockContext();
    mock.storage.getSession.mockReturnValue(makeSession({ id: "parent-abc", workspaceId: "ws-1" }));

    await dispatchCreate(mock, { prompt: "child task", parentSessionId: "parent-abc" });

    // First saveSession is the initial create (with parentSessionId set)
    const firstSave = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(firstSave.parentSessionId).toBe("parent-abc");

    // Response should include the session
    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);
  });

  it("omits parentSessionId when not provided", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "standalone task" });

    const firstSave = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(firstSave.parentSessionId).toBeUndefined();
  });

  it("persists parentSessionId on session without prompt when the parent belongs to the workspace", async () => {
    const mock = createMockContext();
    mock.storage.getSession.mockReturnValue(makeSession({ id: "parent-xyz", workspaceId: "ws-1" }));

    await dispatchCreate(mock, { name: "child", parentSessionId: "parent-xyz" });

    expect(mock.storage.saveSession).toHaveBeenCalledTimes(1);
    const savedSession = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(savedSession.parentSessionId).toBe("parent-xyz");

    // Should NOT start or prompt
    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();
  });

  it("rejects parentSessionId from another workspace", async () => {
    const mock = createMockContext();
    mock.storage.getSession.mockReturnValue(
      makeSession({ id: "parent-foreign", workspaceId: "ws-2" }),
    );

    await dispatchCreate(mock, { name: "child", parentSessionId: "parent-foreign" });

    expect(mock.errors).toEqual([
      { status: 400, message: "Parent session does not belong to this workspace" },
    ]);
    expect(mock.storage.saveSession).not.toHaveBeenCalled();
    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();
  });

  it("coalesces local JSONL import with an existing Oppi session identity", async () => {
    const root = getPiSessionsRoot();
    const dir = mkdtempSync(join(root, "oppi-import-coalesce-"));
    const jsonl = join(dir, "session.jsonl");
    const workspace = makeWorkspace({ hostMount: dir });
    const mock = createMockContext(workspace);
    const existing = makeSession({
      id: "existing-session",
      workspaceId: "old-workspace",
      piSessionId: "pi-coalesce-1",
      piSessionFile: jsonl,
      piSessionFiles: [jsonl],
    });

    try {
      writeFileSync(
        jsonl,
        [
          JSON.stringify({
            type: "session",
            version: 3,
            id: "pi-coalesce-1",
            timestamp: "2026-05-03T00:00:00.000Z",
            cwd: dir,
          }),
          JSON.stringify({
            type: "message",
            id: "m1",
            parentId: null,
            timestamp: "2026-05-03T00:00:01.000Z",
            message: { role: "user", content: "existing hello" },
          }),
        ].join("\n") + "\n",
      );
      mock.storage.listSessions.mockReturnValue([existing]);

      await dispatchCreate(mock, { piSessionFile: jsonl });

      expect(mock.storage.createSession).not.toHaveBeenCalled();
      expect(mock.responses).toHaveLength(1);
      expect(mock.responses[0]!.status).toBe(200);
      const response = mock.responses[0]!.data as { session: Session };
      expect(response.session.id).toBe("existing-session");
      expect(existing.workspaceId).toBe("ws-1");
      expect(existing.workspaceName).toBe("test-workspace");
      expect(existing.firstMessage).toBe("existing hello");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("persists piSessionId when importing a local JSONL for the first time", async () => {
    const root = getPiSessionsRoot();
    const dir = mkdtempSync(join(root, "oppi-import-new-"));
    const jsonl = join(dir, "session.jsonl");
    const mock = createMockContext(makeWorkspace({ hostMount: dir }));

    try {
      writeFileSync(
        jsonl,
        `${JSON.stringify({ type: "session", version: 3, id: "pi-new-1", timestamp: "2026-05-03T00:00:00.000Z", cwd: dir })}\n`,
      );

      await dispatchCreate(mock, { piSessionFile: jsonl });

      expect(mock.responses).toHaveLength(1);
      expect(mock.responses[0]!.status).toBe(201);
      const saved = mock.storage.saveSession.mock.calls[0]![0] as Session;
      expect(saved.piSessionId).toBe("pi-new-1");
      expect(saved.piSessionFile).toBe(jsonl);
      expect(saved.runtime).toBe("pi-tui");
      expect(saved.status).toBe("stopped");
      expect(saved.mirror).toEqual({ status: "disconnected" });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("POST /workspaces/:id/sessions/:sessionId/fork", () => {
  async function dispatchFork(
    mock: MockRouteContext,
    body: Record<string, unknown>,
    sessionId = "source-1",
  ): Promise<boolean> {
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const req = makeRequestBody(body);
    const res = {} as ServerResponse;
    const url = new URL(`https://localhost/workspaces/ws-1/sessions/${sessionId}/fork`);
    return dispatcher({
      method: "POST",
      path: `/workspaces/ws-1/sessions/${sessionId}/fork`,
      url,
      req,
      res,
    });
  }

  it("creates timeline forks as independent root sessions, not child sessions", async () => {
    const mock = createMockContext();
    const source = makeSession({
      id: "source-1",
      workspaceId: "ws-1",
      workspaceName: "test-workspace",
      name: "Original",
      piSessionFile: "/tmp/source.jsonl",
      piSessionFiles: ["/tmp/older.jsonl", "/tmp/source.jsonl"],
      parentSessionId: "spawn-parent",
      thinkingLevel: "medium",
      contextWindow: 200_000,
    });
    const fork = makeSession({ id: "fork-1", name: "Fork: Original" });

    mock.storage.createSession.mockReturnValue(fork);
    mock.storage.getSession.mockImplementation((sessionId: string) => {
      if (sessionId === "source-1") return source;
      if (sessionId === "fork-1") return fork;
      return undefined;
    });

    await dispatchFork(mock, { entryId: "entry-user-1" });

    expect(mock.sessions.runCommand).toHaveBeenCalledWith("fork-1", {
      type: "fork",
      entryId: "entry-user-1",
    });

    const savedFork = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(savedFork.workspaceId).toBe("ws-1");
    expect(savedFork.piSessionFile).toBe("/tmp/source.jsonl");
    expect(savedFork.piSessionFiles).toEqual(["/tmp/older.jsonl", "/tmp/source.jsonl"]);
    expect(savedFork.thinkingLevel).toBe("medium");
    expect(savedFork.contextWindow).toBe(200_000);
    expect(savedFork.parentSessionId).toBeUndefined();

    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]!.status).toBe(201);
    const response = mock.responses[0]!.data as { session: Session };
    expect(response.session.id).toBe("fork-1");
  });
});

describe("POST /workspaces/:id/sessions/:sessionId/resume", () => {
  async function dispatchResume(mock: MockRouteContext, sessionId = "sess-1"): Promise<boolean> {
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const req = new PassThrough() as unknown as IncomingMessage;
    const res = {} as ServerResponse;
    const url = new URL(`https://localhost/workspaces/ws-1/sessions/${sessionId}/resume`);
    return dispatcher({
      method: "POST",
      path: `/workspaces/ws-1/sessions/${sessionId}/resume`,
      url,
      req,
      res,
    });
  }

  it("rejects resuming incognito sessions", async () => {
    const mock = createMockContext();
    mock.storage.getSession.mockReturnValue(
      makeSession({ id: "sess-1", workspaceId: "ws-1", ephemeral: true, status: "stopped" }),
    );

    await dispatchResume(mock);

    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.errors).toEqual([{ status: 400, message: "Incognito sessions cannot be resumed" }]);
  });

  it("does not promote active terminal mirror sessions when resuming", async () => {
    const mock = createMockContext();
    const mirrorSession = makeSession({
      id: "sess-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      mirror: { status: "disconnected" },
      status: "ready",
    });
    mock.storage.getSession.mockReturnValue(mirrorSession);
    mock.sessions.isActive.mockReturnValue(true);
    mock.sessions.getActiveSession.mockReturnValue(
      makeSession({ id: "sess-1", workspaceId: "ws-1", status: "ready" }),
    );
    const mirrorActive = { ...mirrorSession, mirror: { status: "connected" as const } };
    mock.piTuiRuntime.isSessionConnected.mockReturnValue(true);
    mock.piTuiRuntime.getActiveSession.mockReturnValue(mirrorActive);

    await dispatchResume(mock);

    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.getActiveSession).not.toHaveBeenCalled();
    expect(mock.responses).toHaveLength(1);
    expect((mock.responses[0]!.data as { session: Session }).session).toMatchObject({
      id: "sess-1",
      runtime: "pi-tui",
      mirror: { status: "connected" },
    });
  });

  it("resumes stopped disconnected mirror sessions as oppi imported sessions", async () => {
    const mock = createMockContext();
    const mirrorSession = makeSession({
      id: "sess-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      mirror: { status: "disconnected" },
      status: "stopped",
      piSessionFile: "/tmp/stopped-mirror.jsonl",
    });
    mock.storage.getSession.mockReturnValue(mirrorSession);
    mock.piTuiRuntime.isSessionConnected.mockReturnValue(false);
    mock.sessions.startSession.mockResolvedValue(
      makeSession({ id: "sess-1", workspaceId: "ws-1", runtime: "oppi", status: "ready" }),
    );

    await dispatchResume(mock);

    expect(mock.storage.saveSession).toHaveBeenCalledWith(
      expect.objectContaining({ id: "sess-1", runtime: "oppi", mirror: undefined }),
    );
    expect(mock.sessions.startSession).toHaveBeenCalledWith(
      "sess-1",
      expect.objectContaining({ id: "ws-1" }),
    );
    expect(mock.responses).toHaveLength(1);
    expect((mock.responses[0]!.data as { session: Session }).session).toMatchObject({
      id: "sess-1",
      runtime: "oppi",
      status: "ready",
    });
  });

  it("resumes ready disconnected mirror sessions as oppi imported sessions", async () => {
    const mock = createMockContext();
    const mirrorSession = makeSession({
      id: "sess-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      mirror: { status: "disconnected" },
      status: "ready",
      piSessionFile: "/tmp/ready-mirror.jsonl",
    });
    mock.storage.getSession.mockReturnValue(mirrorSession);
    mock.piTuiRuntime.isSessionConnected.mockReturnValue(false);
    mock.sessions.startSession.mockResolvedValue(
      makeSession({ id: "sess-1", workspaceId: "ws-1", runtime: "oppi", status: "ready" }),
    );

    await dispatchResume(mock);

    expect(mock.storage.saveSession).toHaveBeenCalledWith(
      expect.objectContaining({ id: "sess-1", runtime: "oppi", mirror: undefined }),
    );
    expect(mock.sessions.startSession).toHaveBeenCalledWith(
      "sess-1",
      expect.objectContaining({ id: "ws-1" }),
    );
    expect(mock.responses).toHaveLength(1);
    expect((mock.responses[0]!.data as { session: Session }).session).toMatchObject({
      id: "sess-1",
      runtime: "oppi",
      status: "ready",
    });
  });
});

describe("POST /workspaces/:id/sessions/:sessionId/stop", () => {
  async function dispatchStop(mock: MockRouteContext, sessionId = "sess-1"): Promise<boolean> {
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const req = new PassThrough() as unknown as IncomingMessage;
    const res = {} as ServerResponse;
    const url = new URL(`https://localhost/workspaces/ws-1/sessions/${sessionId}/stop`);
    return dispatcher({
      method: "POST",
      path: `/workspaces/ws-1/sessions/${sessionId}/stop`,
      url,
      req,
      res,
    });
  }

  it("stops connected pi-tui sessions through the mirror runtime", async () => {
    const mock = createMockContext();
    const session = makeSession({
      id: "sess-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      status: "busy",
    });
    mock.storage.getSession.mockReturnValue(session);
    mock.piTuiRuntime.isSessionConnected.mockReturnValue(true);

    await dispatchStop(mock);

    expect(mock.sessions.stopSession).not.toHaveBeenCalled();
    expect(mock.piTuiRuntime.stopSession).toHaveBeenCalledWith("sess-1");
    expect(mock.responses).toHaveLength(1);
    expect((mock.responses[0]!.data as { ok: boolean }).ok).toBe(true);
  });

  it("fails fast when a pi-tui session is no longer connected", async () => {
    const mock = createMockContext();
    const session = makeSession({
      id: "sess-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      status: "busy",
    });
    mock.storage.getSession.mockReturnValue(session);
    mock.piTuiRuntime.stopSession.mockRejectedValue(
      new Error("pi-tui is not connected; stop it from the terminal"),
    );

    await dispatchStop(mock);

    expect(mock.responses).toHaveLength(0);
    expect(mock.errors).toEqual([
      { status: 409, message: "pi-tui is not connected; stop it from the terminal" },
    ]);
  });
});

describe("workspace-scoped session route ownership", () => {
  const wrongWorkspaceRoutes = [
    {
      name: "session detail",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session",
    },
    {
      name: "session stop",
      method: "POST",
      path: "/workspaces/ws-1/sessions/foreign-session/stop",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session/stop",
    },
    {
      name: "session delete",
      method: "DELETE",
      path: "/workspaces/ws-1/sessions/foreign-session",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session",
    },
    {
      name: "session events",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session/events",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session/events?since=0",
    },
    {
      name: "tool output",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session/tool-output/tc-1",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session/tool-output/tc-1",
    },
    {
      name: "full tool output",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session/tool-output/tc-1",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session/tool-output/tc-1?full=true",
    },
    {
      name: "session raw file",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session/raw/file.txt",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session/raw/file.txt",
    },
    {
      name: "session diff",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session/diff",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session/diff?path=file.txt",
    },
  ] as const;

  it.each(wrongWorkspaceRoutes)(
    "rejects wrong-workspace $name route before side effects",
    async ({ method, path, url }) => {
      const mock = createMockContext();
      mock.storage.getSession.mockReturnValue(
        makeSession({ id: "foreign-session", workspaceId: "ws-2" }),
      );
      mock.storage.deleteSession = vi.fn().mockReturnValue(true);
      (mock.ctx as unknown as Record<string, unknown>).searchIndex = {
        deleteSession: vi.fn(),
      };
      const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
      const handled = await dispatcher({
        method,
        path,
        url: new URL(url),
        req: new PassThrough() as unknown as IncomingMessage,
        res: {} as ServerResponse,
      });

      expect(handled).toBe(true);
      expect(mock.errors).toEqual([
        { status: 400, message: "Session does not belong to this workspace" },
      ]);
      expect(mock.responses).toHaveLength(0);
      expect(mock.sessions.stopSession).not.toHaveBeenCalled();
      expect(mock.sessions.refreshSessionState).not.toHaveBeenCalled();
      expect(mock.sessions.getToolFullOutputPath).not.toHaveBeenCalled();
      expect(mock.sessions.getCatchUp).not.toHaveBeenCalled();
      expect(mock.storage.deleteSession).not.toHaveBeenCalled();
    },
  );
});

describe("DELETE /workspaces/:id/sessions/:sessionId", () => {
  async function dispatchDelete(mock: MockRouteContext, sessionId = "sess-1"): Promise<boolean> {
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const req = new PassThrough() as unknown as IncomingMessage;
    const res = {} as ServerResponse;
    const url = new URL(`https://localhost/workspaces/ws-1/sessions/${sessionId}`);
    return dispatcher({
      method: "DELETE",
      path: `/workspaces/ws-1/sessions/${sessionId}`,
      url,
      req,
      res,
    });
  }

  it("deletes referenced local pi JSONL traces so deleted sessions are not rediscovered", async () => {
    const mock = createMockContext();
    const piSessionsRoot = getPiSessionsRoot();
    mkdirSync(piSessionsRoot, { recursive: true });
    const dir = mkdtempSync(join(piSessionsRoot, "oppi-session-delete-"));
    const jsonlA = join(dir, "a.jsonl");
    const jsonlB = join(dir, "b.jsonl");
    writeFileSync(
      jsonlA,
      `${JSON.stringify({ type: "session", id: "sess-1", cwd: dir, timestamp: "2026-05-03T00:00:00.000Z" })}\n`,
    );
    writeFileSync(
      jsonlB,
      `${JSON.stringify({ type: "session", id: "sess-1b", cwd: dir, timestamp: "2026-05-03T00:01:00.000Z" })}\n`,
    );

    try {
      mock.storage.getSession.mockReturnValue(
        makeSession({
          id: "sess-1",
          workspaceId: "ws-1",
          piSessionFile: jsonlA,
          piSessionFiles: [jsonlA, jsonlB],
        }),
      );
      mock.storage.deleteSession = vi.fn().mockReturnValue(true);
      (mock.ctx as unknown as Record<string, unknown>).searchIndex = {
        deleteSession: vi.fn(),
      };
      await dispatchDelete(mock);

      expect(mock.ctx.sessionRuntimes.stopSessionIfActive).toHaveBeenCalledWith("sess-1");
      expect(mock.storage.deleteSession).toHaveBeenCalledWith("sess-1");
      expect(existsSync(jsonlA)).toBe(false);
      expect(existsSync(jsonlB)).toBe(false);
      expect(mock.responses).toEqual([
        {
          data: {
            ok: true,
            deleted: {
              sqliteMetadata: true,
              localPiJsonlFiles: 2,
              workspaceAttachmentCopies: false,
              generatedMediaAttachments: false,
            },
          },
          status: 200,
        },
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not unlink arbitrary non-local JSONL paths from session metadata", async () => {
    const mock = createMockContext();
    const dir = mkdtempSync(join(tmpdir(), "oppi-session-delete-non-local-"));
    const jsonl = join(dir, "outside-root.jsonl");
    writeFileSync(
      jsonl,
      `${JSON.stringify({ type: "session", id: "outside", cwd: dir, timestamp: "2026-05-03T00:00:00.000Z" })}\n`,
    );

    try {
      mock.storage.getSession.mockReturnValue(
        makeSession({
          id: "sess-1",
          workspaceId: "ws-1",
          piSessionFile: jsonl,
        }),
      );
      mock.storage.deleteSession = vi.fn().mockReturnValue(true);
      (mock.ctx as unknown as Record<string, unknown>).searchIndex = {
        deleteSession: vi.fn(),
      };

      await dispatchDelete(mock);

      expect(mock.storage.deleteSession).toHaveBeenCalledWith("sess-1");
      expect(existsSync(jsonl)).toBe(true);
      expect(mock.responses).toEqual([
        {
          data: {
            ok: true,
            deleted: {
              sqliteMetadata: true,
              localPiJsonlFiles: 0,
              workspaceAttachmentCopies: false,
              generatedMediaAttachments: false,
            },
          },
          status: 200,
        },
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

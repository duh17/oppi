import { describe, expect, it, vi } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

import { createSessionRoutes } from "./sessions.js";
import type { RouteContext, RouteHelpers } from "./types.js";
import type { Session, Workspace } from "../types.js";

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
    getActiveSession: ReturnType<typeof vi.fn>;
    forwardClientCommand: ReturnType<typeof vi.fn>;
    stopSession: ReturnType<typeof vi.fn>;
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
    getActiveSession: vi.fn().mockReturnValue(undefined),
    stopSession: vi.fn().mockResolvedValue(undefined),
    getToolFullOutputPath: vi.fn().mockReturnValue(undefined),
    getCatchUp: vi.fn().mockReturnValue({ events: [], currentSeq: 0, catchUpComplete: true }),
    refreshSessionState: vi.fn().mockResolvedValue(undefined),
    runCommand: vi.fn().mockResolvedValue(undefined),
    forwardClientCommand: vi.fn().mockResolvedValue(undefined),
  };

  const ctx = {
    storage,
    sessions,
    gate: {} as RouteContext["gate"],
    skillRegistry: {} as RouteContext["skillRegistry"],
    userSkillStore: {} as RouteContext["userSkillStore"],
    streamMux: {} as RouteContext["streamMux"],
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

  return { ctx, helpers, responses, errors, sessions, storage };
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

  it("omits model when request does not specify one so Pi settings choose", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello" });

    expect(mock.storage.createSession).toHaveBeenCalledWith(undefined, undefined);
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

  it("passes images to sendPrompt when provided", async () => {
    const mock = createMockContext();
    const images = [{ type: "image" as const, data: "base64data", mimeType: "image/jpeg" }];

    await dispatchCreate(mock, { prompt: "look at this", images });

    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);
    const promptCall = mock.sessions.sendPrompt.mock.calls[0]!;
    expect(promptCall[1]).toBe("look at this");
    expect(promptCall[2]).toEqual({ images });
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

  it("persists parentSessionId when provided", async () => {
    const mock = createMockContext();

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

  it("persists parentSessionId on session without prompt", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { name: "child", parentSessionId: "parent-xyz" });

    expect(mock.storage.saveSession).toHaveBeenCalledTimes(1);
    const savedSession = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(savedSession.parentSessionId).toBe("parent-xyz");

    // Should NOT start or prompt
    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.sessions.sendPrompt).not.toHaveBeenCalled();
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
    mock.storage.getSession
      .mockReturnValueOnce(source)
      .mockReturnValueOnce(source)
      .mockReturnValueOnce(fork);

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

  it("deletes the tracked pi jsonl files along with the Oppi session", async () => {
    const mock = createMockContext();
    const dir = mkdtempSync(join(tmpdir(), "oppi-session-delete-"));
    const jsonlA = join(dir, "a.jsonl");
    const jsonlB = join(dir, "b.jsonl");
    writeFileSync(jsonlA, '{"role":"user","content":"hello"}\n');
    writeFileSync(jsonlB, '{"role":"assistant","content":"hi"}\n');

    mock.storage.getSession.mockReturnValue(
      makeSession({
        id: "sess-1",
        piSessionFile: jsonlA,
        piSessionFiles: [jsonlA, jsonlB],
      }),
    );
    mock.storage.deleteSession = vi.fn().mockReturnValue(true);
    (mock.ctx as unknown as Record<string, unknown>).searchIndex = {
      deleteSession: vi.fn(),
    };
    (mock.ctx as unknown as Record<string, unknown>).streamMux = {
      recordUserStreamEvent: vi.fn(),
    };

    await dispatchDelete(mock);

    expect(mock.sessions.stopSession).toHaveBeenCalledWith("sess-1");
    expect(mock.storage.deleteSession).toHaveBeenCalledWith("sess-1");
    expect(existsSync(jsonlA)).toBe(false);
    expect(existsSync(jsonlB)).toBe(false);
    expect(mock.responses).toEqual([{ data: { ok: true }, status: 200 }]);
  });
});

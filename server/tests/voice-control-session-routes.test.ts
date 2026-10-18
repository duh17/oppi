import { describe, expect, it, vi } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { PassThrough } from "node:stream";

import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import type { Session, Workspace } from "../src/types.js";

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
  return stream as unknown as IncomingMessage;
}

interface MockRouteContext {
  ctx: RouteContext;
  helpers: RouteHelpers;
  responses: Array<{ data: unknown; status: number }>;
  errors: Array<{ status: number; message: string }>;
  sessions: {
    startSession: ReturnType<typeof vi.fn>;
    isActive: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
  };
  storage: {
    createSession: ReturnType<typeof vi.fn>;
    saveSession: ReturnType<typeof vi.fn>;
    getSession: ReturnType<typeof vi.fn>;
  };
  sessionRuntimes: {
    isSessionConnected: ReturnType<typeof vi.fn>;
    getActiveSession: ReturnType<typeof vi.fn>;
  };
  appEvents: {
    emitSessionCreated: ReturnType<typeof vi.fn>;
    emitSessionSummary: ReturnType<typeof vi.fn>;
  };
}

function createMockContext(): MockRouteContext {
  const ws = makeWorkspace();
  const responses: Array<{ data: unknown; status: number }> = [];
  const errors: Array<{ status: number; message: string }> = [];
  const appEvents = {
    emitSessionCreated: vi.fn(),
    emitSessionSummary: vi.fn(),
  };

  const storage = {
    getDataDir: vi.fn().mockReturnValue("/tmp/oppi-voice-control-routes"),
    getWorkspace: vi.fn().mockReturnValue(ws),
    getAgentDefinitionStore: vi.fn().mockReturnValue({
      getAgent: vi.fn().mockReturnValue(undefined),
    }),
    createSession: vi.fn().mockImplementation((name?: string, model?: string) =>
      makeSession({
        id: `voice-${Date.now()}`,
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
        makeSession({
          id: sessionId,
          name: "Voice Control",
          status: "ready",
          runtime: "oppi",
          workspaceId: undefined,
          control: undefined,
          voice: { purpose: "voice-control" },
        }),
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

  const sessionRuntimes = {
    getActiveSessionIds: vi.fn(() => new Set<string>()),
    getActiveSession: vi.fn(() => undefined),
    getPendingUIRequestMessages: vi.fn(() => []),
    isSessionConnected: vi.fn(() => false),
    getSessionSnapshot: vi.fn(() => undefined),
    stopSession: vi.fn().mockResolvedValue(undefined),
    stopSessionIfActive: vi.fn().mockResolvedValue(undefined),
    refreshSessionState: vi.fn().mockResolvedValue(undefined),
    getToolFullOutputPath: vi.fn().mockReturnValue(undefined),
    getCatchUp: vi.fn().mockReturnValue({ events: [], currentSeq: 0, catchUpComplete: true }),
  };

  const ctx = {
    storage,
    sessions,
    sessionRuntimes,
    appEvents,
    gate: {} as RouteContext["gate"],
    skillRegistry: {} as RouteContext["skillRegistry"],
    userSkillStore: {} as RouteContext["userSkillStore"],
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => ws,
    refreshModelCatalog: vi.fn().mockResolvedValue(undefined),
    getModelCatalog: vi.fn().mockReturnValue([]),
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

  return { ctx, helpers, responses, errors, sessions, storage, sessionRuntimes, appEvents };
}

async function dispatch(
  mock: MockRouteContext,
  method: string,
  path: string,
  body: Record<string, unknown> = {},
): Promise<boolean> {
  const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
  const req = makeRequestBody(body);
  const res = {} as ServerResponse;
  const url = new URL(`https://localhost${path}`);
  return dispatcher({ method, path, url, req, res });
}

describe("POST /voice-control-sessions", () => {
  it("creates a hidden purpose-checked voice-control session", async () => {
    const mock = createMockContext();

    expect(
      await dispatch(mock, "POST", "/voice-control-sessions", {
        purpose: "voice-control",
        name: "Voice Control",
      }),
    ).toBe(true);

    expect(mock.errors).toEqual([]);
    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]).toMatchObject({
      status: 201,
      data: {
        session: {
          workspaceId: undefined,
          control: undefined,
          voice: { purpose: "voice-control" },
          runtime: "oppi",
          name: "Voice Control",
        },
      },
    });
    expect(mock.appEvents.emitSessionCreated).not.toHaveBeenCalled();
    expect(mock.appEvents.emitSessionSummary).not.toHaveBeenCalled();
    expect(mock.sessions.startSession).toHaveBeenCalledOnce();
  });

  it("rejects create without the voice-control purpose", async () => {
    const mock = createMockContext();

    expect(await dispatch(mock, "POST", "/voice-control-sessions", {})).toBe(true);
    expect(mock.responses).toEqual([]);
    expect(mock.errors).toEqual([
      { status: 400, message: "Invalid voice-control session purpose" },
    ]);
    expect(mock.storage.createSession).not.toHaveBeenCalled();
  });

  it("rejects create when purpose is not voice-control", async () => {
    const mock = createMockContext();

    expect(
      await dispatch(mock, "POST", "/voice-control-sessions", {
        purpose: "control",
      }),
    ).toBe(true);
    expect(mock.errors).toEqual([
      { status: 400, message: "Invalid voice-control session purpose" },
    ]);
  });
});

describe("POST /voice-control-sessions/:id/resume", () => {
  it("resumes a declared voice-control session", async () => {
    const mock = createMockContext();
    const voice = makeSession({
      id: "voice-1",
      workspaceId: undefined,
      voice: { purpose: "voice-control" },
      runtime: "oppi",
    });
    mock.storage.getSession.mockReturnValue(voice);

    expect(
      await dispatch(mock, "POST", "/voice-control-sessions/voice-1/resume", {
        purpose: "voice-control",
      }),
    ).toBe(true);

    expect(mock.errors).toEqual([]);
    expect(mock.sessions.startSession).toHaveBeenCalledWith("voice-1", undefined);
    expect(mock.responses[0]).toMatchObject({
      status: 200,
      data: {
        session: {
          id: "voice-1",
          voice: { purpose: "voice-control" },
        },
      },
    });
  });

  it("rejects resume of a workspace or control session", async () => {
    const mock = createMockContext();
    mock.storage.getSession.mockReturnValueOnce(makeSession({ id: "ws-sess", workspaceId: "ws-1" }));

    expect(
      await dispatch(mock, "POST", "/voice-control-sessions/ws-sess/resume", {
        purpose: "voice-control",
      }),
    ).toBe(true);
    expect(mock.errors).toEqual([{ status: 400, message: "Session is not a voice-control session" }]);
    expect(mock.sessions.startSession).not.toHaveBeenCalled();

    mock.storage.getSession.mockReturnValueOnce(
      makeSession({
        id: "control-1",
        workspaceId: undefined,
        control: { domain: "agents", intent: "create" },
      }),
    );
    expect(
      await dispatch(mock, "POST", "/voice-control-sessions/control-1/resume", {
        purpose: "voice-control",
      }),
    ).toBe(true);
    expect(mock.errors.at(-1)).toEqual({
      status: 400,
      message: "Session is not a voice-control session",
    });
  });

  it("returns 404 when the voice-control session is missing", async () => {
    const mock = createMockContext();
    mock.storage.getSession.mockReturnValue(undefined);

    expect(
      await dispatch(mock, "POST", "/voice-control-sessions/missing/resume", {
        purpose: "voice-control",
      }),
    ).toBe(true);
    expect(mock.errors).toEqual([{ status: 404, message: "Session not found" }]);
  });
});

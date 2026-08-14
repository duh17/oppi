import { describe, expect, it, vi } from "vitest";
import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
import { Storage } from "../src/storage.js";
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
    getAgentDefinitionStore: ReturnType<typeof vi.fn>;
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
    getAgentDefinitionStore: vi.fn().mockReturnValue({
      getAgent: vi.fn().mockReturnValue({
        id: "oppi-default-agent",
        name: "Oppi",
        status: "active",
        version: 3,
        definition: { name: "Oppi", icon: { kind: "symbol", name: "sparkles" } },
        createdAt: 1,
        updatedAt: 1,
      }),
    }),
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

describe("POST /control-sessions", () => {
  async function dispatchCreate(
    mock: MockRouteContext,
    body: Record<string, unknown>,
  ): Promise<boolean> {
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const req = makeRequestBody(body);
    const res = {} as ServerResponse;
    const url = new URL("https://localhost/control-sessions");
    return dispatcher({ method: "POST", path: "/control-sessions", url, req, res });
  }

  it("creates a declared workspace-less control session", async () => {
    const mock = createMockContext();

    expect(
      await dispatchCreate(mock, {
        domain: "schedules",
        intent: "create",
        name: "Create Schedule",
        prompt: "Help me create a schedule.",
        model: "anthropic/claude-opus-4-8",
        thinking: "high",
      }),
    ).toBe(true);

    expect(mock.errors).toEqual([]);
    expect(mock.responses).toHaveLength(1);
    expect(mock.responses[0]).toMatchObject({
      status: 201,
      data: {
        prompted: true,
        session: {
          workspaceId: undefined,
          model: "anthropic/claude-opus-4-8",
          thinkingLevel: "high",
          control: { domain: "schedules", intent: "create" },
          launch: {
            agentId: "oppi-default-agent",
            agentVersion: 3,
            agentIcon: { kind: "symbol", name: "sparkles" },
          },
        },
      },
    });
    expect(mock.storage.createSession).toHaveBeenCalledWith(
      "Create Schedule",
      "anthropic/claude-opus-4-8",
    );
    expect(mock.sessions.startSession).toHaveBeenCalledWith(expect.any(String), undefined);
  });

  it("immediately serves a newly persisted control session through its trace route", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-control-session-route-"));

    try {
      const mock = createMockContext();
      const persistentStorage = new Storage(dataDir);
      mock.ctx.storage = persistentStorage;

      await dispatchCreate(mock, {
        domain: "agents",
        intent: "revise",
        targetId: "agent-1",
        targetName: "Reviewer",
        name: "Revise Reviewer",
        prompt: "Inspect and revise the Agent.",
      });

      const created = mock.responses[0]?.data as { session?: Session } | undefined;
      const sessionId = created?.session?.id;
      expect(sessionId).toBeTypeOf("string");
      expect(persistentStorage.getSession(sessionId!)?.control).toEqual({
        domain: "agents",
        intent: "revise",
        targetId: "agent-1",
        targetName: "Reviewer",
      });

      const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
      const tracePath = `/control-sessions/${sessionId}/trace-outline`;
      const traceRequest = new PassThrough();
      traceRequest.end();
      expect(
        await dispatcher({
          method: "GET",
          path: tracePath,
          url: new URL(`https://localhost${tracePath}`),
          req: traceRequest as unknown as IncomingMessage,
          res: {} as ServerResponse,
        }),
      ).toBe(true);

      expect(mock.errors).toEqual([]);
      expect(mock.responses[1]).toMatchObject({
        status: 200,
        data: {
          session: {
            id: sessionId,
            control: { domain: "agents", intent: "revise", targetId: "agent-1" },
          },
          outline: expect.any(Object),
        },
      });

      const freshStorage = new Storage(dataDir);
      expect(freshStorage.getSession(sessionId!)?.control?.targetName).toBe("Reviewer");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("reuses a control session when creation is retried with the same idempotency key", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-control-session-idempotency-"));

    try {
      const mock = createMockContext();
      const persistentStorage = new Storage(dataDir);
      mock.ctx.storage = persistentStorage;
      const body = {
        domain: "agents",
        intent: "revise",
        targetId: "agent-1",
        targetName: "Reviewer",
        prompt: "Inspect and revise the Agent.",
        launchIdempotencyKey: "ios-control-revision-1",
      };

      await dispatchCreate(mock, body);
      await dispatchCreate(mock, body);

      const first = mock.responses[0]?.data as { session?: Session } | undefined;
      const second = mock.responses[1]?.data as { session?: Session } | undefined;
      expect(first?.session?.id).toBeTypeOf("string");
      expect(second?.session?.id).toBe(first?.session?.id);
      expect(mock.responses.map((response) => response.status)).toEqual([201, 200]);
      expect(mock.sessions.startSession).toHaveBeenCalledOnce();
      expect(mock.sessions.sendPrompt).toHaveBeenCalledOnce();
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("recovers an expired idempotent control-session launch lease", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-control-session-recovery-"));

    try {
      const mock = createMockContext();
      const persistentStorage = new Storage(dataDir);
      mock.ctx.storage = persistentStorage;
      const body = {
        domain: "agents",
        intent: "revise",
        targetId: "agent-1",
        launchIdempotencyKey: "ios-control-recovery-1",
      };

      await dispatchCreate(mock, body);
      const created = mock.responses[0]?.data as { session?: Session } | undefined;
      const session = persistentStorage.getSession(created?.session?.id ?? "");
      expect(session).toBeDefined();
      session!.launch = {
        ...session!.launch,
        status: "launching",
        completedAt: undefined,
        lease: {
          owner: "abandoned-control-launch",
          acquiredAt: 1,
          expiresAt: 2,
        },
      };
      persistentStorage.saveSession(session!);
      mock.responses.splice(0);

      await dispatchCreate(mock, body);

      expect(mock.responses).toHaveLength(1);
      expect(mock.responses[0]).toMatchObject({
        status: 200,
        data: {
          session: {
            id: session!.id,
            launch: { status: "accepted", promptDispatch: "not_sent" },
          },
          launch: { existing: true },
        },
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("accepts Skill revision control sessions", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, {
      domain: "skills",
      intent: "revise",
      targetId: "skill_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      targetName: "review",
      prompt: "Inspect the selected skill file and wait for review comments.",
    });

    expect(mock.errors).toEqual([]);
    expect(mock.responses[0]).toMatchObject({
      status: 201,
      data: {
        session: {
          workspaceId: undefined,
          control: {
            domain: "skills",
            intent: "revise",
            targetId: "skill_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          },
        },
      },
    });
  });

  it("rejects unknown control domains and intents", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { domain: "themes", intent: "delete" });

    expect(mock.responses).toEqual([]);
    expect(mock.errors).toEqual([{ status: 400, message: "Invalid control session metadata" }]);
  });

  it.each([
    { domain: "agents" },
    { domain: "agents", intent: "create", targetId: "   " },
    { domain: "agents", intent: "create", targetName: "" },
    { domain: "agents", intent: "create", name: 42 },
    { domain: "agents", intent: "create", prompt: false },
    { domain: "agents", intent: "create", model: 42 },
    { domain: "agents", intent: "create", thinking: "maximum" },
    { domain: "agents", intent: "create", launchIdempotencyKey: 42 },
    { domain: "agents", intent: "create", launchIdempotencyKey: "   " },
  ])("rejects malformed control-session fields", async (body) => {
    const mock = createMockContext();

    await dispatchCreate(mock, body);

    expect(mock.responses).toEqual([]);
    expect(mock.errors).toEqual([{ status: 400, message: "Invalid control session metadata" }]);
    expect(mock.storage.createSession).not.toHaveBeenCalled();
  });
});

describe("control session route scope", () => {
  const scopedRoutes = [
    { method: "GET", suffix: "" },
    { method: "GET", suffix: "/trace-page" },
    { method: "GET", suffix: "/trace-outline" },
    { method: "GET", suffix: "/events" },
    { method: "GET", suffix: "/tool-output/tool-1" },
    { method: "GET", suffix: "/attachments/attachment-1" },
    { method: "POST", suffix: "/command" },
    { method: "POST", suffix: "/stop" },
    { method: "POST", suffix: "/resume" },
    { method: "DELETE", suffix: "" },
  ] as const;

  it.each([
    ["workspace session", makeSession({ id: "scoped", workspaceId: "ws-1" })],
    ["undeclared workspace-less session", makeSession({ id: "scoped", workspaceId: undefined })],
  ])("rejects every control route for a %s", async (_label, session) => {
    for (const route of scopedRoutes) {
      const mock = createMockContext();
      mock.storage.getSession.mockReturnValue(session);
      const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
      const path = `/control-sessions/scoped${route.suffix}`;

      const handled = await dispatcher({
        method: route.method,
        path,
        url: new URL(`https://localhost${path}`),
        req:
          route.suffix === "/command"
            ? makeRequestBody({ type: "reload" })
            : (new PassThrough() as unknown as IncomingMessage),
        res: {} as ServerResponse,
      });

      expect(handled, `${route.method} ${path}`).toBe(true);
      expect(mock.errors, `${route.method} ${path}`).toEqual([
        { status: 400, message: "Session is not a control session" },
      ]);
      expect(mock.responses).toEqual([]);
      expect(mock.sessions.startSession).not.toHaveBeenCalled();
      expect(mock.sessions.stopSession).not.toHaveBeenCalled();
      expect(mock.storage.deleteSession).not.toHaveBeenCalled();
    }
  });

  it.each([
    ["POST", "/sessions/control-1/command", { type: "reload" }],
    ["POST", "/sessions/control-1/stop", {}],
  ])(
    "rejects generic mutation route %s %s for declared control sessions",
    async (method, path, body) => {
      const mock = createMockContext();
      mock.storage.getSession.mockReturnValue(
        makeSession({
          id: "control-1",
          workspaceId: undefined,
          control: { domain: "agents", intent: "create" },
        }),
      );
      const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);

      expect(
        await dispatcher({
          method,
          path,
          url: new URL(`https://localhost${path}`),
          req: makeRequestBody(body),
          res: {} as ServerResponse,
        }),
      ).toBe(true);

      expect(mock.responses).toEqual([]);
      expect(mock.errors).toEqual([
        { status: 400, message: "Use the control-session route for control-session mutations" },
      ]);
      expect(mock.sessions.stopSession).not.toHaveBeenCalled();
    },
  );

  it("resumes a declared stopped control session without resolving a workspace", async () => {
    const mock = createMockContext();
    const session = makeSession({
      id: "control-1",
      workspaceId: undefined,
      status: "stopped",
      runtime: "oppi",
      control: { domain: "workspaces", intent: "revise", targetId: "ws-1" },
    });
    mock.storage.getSession.mockReturnValue(session);
    mock.sessions.startSession.mockResolvedValue({ ...session, status: "ready" });
    const dispatcher = createSessionRoutes(mock.ctx, mock.helpers);
    const path = "/control-sessions/control-1/resume";

    await dispatcher({
      method: "POST",
      path,
      url: new URL(`https://localhost${path}`),
      req: new PassThrough() as unknown as IncomingMessage,
      res: {} as ServerResponse,
    });

    expect(mock.sessions.startSession).toHaveBeenCalledWith("control-1", undefined);
    expect(mock.responses).toEqual([
      {
        status: 200,
        data: { session: expect.objectContaining({ id: "control-1", status: "ready" }) },
      },
    ]);
    expect(mock.errors).toEqual([]);
  });
});

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

  it.each([
    [{ parentSessionId: 42 }, "parentSessionId must be a non-empty string"],
    [{ parentSessionId: "   " }, "parentSessionId must be a non-empty string"],
    [{ allowNestedDelegation: "true" }, "allowNestedDelegation must be a boolean"],
  ])("rejects malformed delegation fields with HTTP 400", async (body, message) => {
    const mock = createMockContext();

    await dispatchCreate(mock, body);

    expect(mock.responses).toEqual([]);
    expect(mock.errors).toEqual([{ status: 400, message }]);
    expect(mock.storage.createSession).not.toHaveBeenCalled();
  });

  it("maps delegation policy rejections to HTTP 409", async () => {
    const mock = createMockContext();
    const nestedCaller = makeSession({
      id: "child-1",
      launch: { parentSessionId: "root-1", status: "accepted", requestedAt: 1 },
    });
    mock.storage.getSession.mockImplementation((sessionId: string) =>
      sessionId === nestedCaller.id ? nestedCaller : undefined,
    );

    await dispatchCreate(mock, { parentSessionId: nestedCaller.id });

    expect(mock.responses).toEqual([]);
    expect(mock.errors).toEqual([
      { status: 409, message: "Nested delegation is not authorized for this caller session" },
    ]);
    expect(mock.storage.createSession).not.toHaveBeenCalled();
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

  it("passes workspace to startSession", async () => {
    const ws = makeWorkspace({ id: "ws-42" });
    const mock = createMockContext(ws);

    await dispatchCreate(mock, { prompt: "hello" });

    const startCall = mock.sessions.startSession.mock.calls[0]!;
    expect(startCall[1]).toBe(ws);
  });

  it("seeds thinking level before starting a prompted session", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", thinking: "high" });

    expect(mock.sessions.forwardClientCommand).not.toHaveBeenCalled();
    expect(mock.sessions.startSession).toHaveBeenCalledTimes(1);
    expect(mock.sessions.sendPrompt).toHaveBeenCalledTimes(1);

    const firstSavedSession = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(firstSavedSession.thinkingLevel).toBe("high");
  });

  it("persists thinking level on the session object after prompted creation", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", thinking: "high" });

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

  it("persists max thinking level on session creation", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", thinking: "max" });

    expect(mock.errors).toEqual([]);
    const savedSession = mock.storage.saveSession.mock.calls[0]![0] as Session;
    expect(savedSession.thinkingLevel).toBe("max");
  });

  it("rejects invalid thinking levels on session creation", async () => {
    const mock = createMockContext();

    await dispatchCreate(mock, { prompt: "hello", thinking: "turbo" });

    expect(mock.storage.createSession).not.toHaveBeenCalled();
    expect(mock.sessions.startSession).not.toHaveBeenCalled();
    expect(mock.errors).toEqual([{ status: 400, message: "Invalid thinking level" }]);
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

    expect(mock.storage.saveSession).toHaveBeenCalledTimes(2);
    const savedSession = mock.storage.saveSession.mock.calls.at(-1)?.[0] as Session;
    expect(savedSession.ephemeral).toBe(true);
    expect(savedSession.launch).toMatchObject({ status: "accepted", promptDispatch: "not_sent" });
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

  it("creates timeline forks as independent sessions", async () => {
    const mock = createMockContext();
    const source = makeSession({
      id: "source-1",
      workspaceId: "ws-1",
      workspaceName: "test-workspace",
      name: "Original",
      piSessionFile: "/tmp/source.jsonl",
      piSessionFiles: ["/tmp/older.jsonl", "/tmp/source.jsonl"],
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

  it("marks disconnected pi-tui sessions stopped", async () => {
    const mock = createMockContext();
    const session = makeSession({
      id: "sess-1",
      workspaceId: "ws-1",
      runtime: "pi-tui",
      status: "busy",
      currentTurnStartedAt: Date.now(),
      mirror: {
        status: "disconnected",
        terminal: { lastSeenAt: Date.now() - 1_000 },
      },
    });
    mock.storage.getSession.mockReturnValue(session);

    await dispatchStop(mock);

    expect(mock.piTuiRuntime.stopSession).not.toHaveBeenCalled();
    expect(mock.storage.saveSession).toHaveBeenCalledOnce();
    expect(mock.responses).toHaveLength(1);
    expect(mock.errors).toEqual([]);
    expect((mock.responses[0]!.data as { ok: boolean }).ok).toBe(true);
    expect((mock.responses[0]!.data as { session: Session }).session).toMatchObject({
      id: "sess-1",
      runtime: "pi-tui",
      status: "stopped",
      mirror: {
        status: "disconnected",
        terminal: {
          disconnectReason: "oppi_stop_disconnected_terminal",
        },
      },
    });
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
    {
      name: "control session detail",
      method: "GET",
      path: "/workspaces/ws-1/sessions/foreign-session",
      url: "https://localhost/workspaces/ws-1/sessions/foreign-session",
    },
  ] as const;

  it.each(wrongWorkspaceRoutes)(
    "rejects wrong-workspace $name route before side effects",
    async ({ name, method, path, url }) => {
      const mock = createMockContext();
      mock.storage.getSession.mockReturnValue(
        name === "control session detail"
          ? makeSession({
              id: "foreign-session",
              workspaceId: undefined,
              control: { domain: "agents", intent: "create" },
            })
          : makeSession({ id: "foreign-session", workspaceId: "ws-2" }),
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

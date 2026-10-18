import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { VoiceCallController } from "../src/continuous-voice-call.js";
import {
  SessionLifecycleError,
  SessionLifecycleService,
  type SessionLifecycleServiceDeps,
} from "../src/session-lifecycle-service.js";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";
import {
  authenticatedVoiceDeviceId,
  isDeclaredVoiceControlSession,
} from "../src/voice-control-session.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Workspace",
    ...overrides,
  } as Workspace;
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeVoiceSession(overrides: Partial<Session> = {}): Session {
  return makeSession({
    id: "voice-1",
    workspaceId: undefined,
    runtime: "oppi",
    voice: { purpose: "voice-control" },
    ...overrides,
  });
}

function makeLifecycleService(
  options: {
    storedSession?: Session;
    started?: Session;
    live?: boolean;
    dataDir?: string;
    startSessionError?: Error;
  } = {},
) {
  const persistedSessions = new Map<string, Session>();
  if (options.storedSession) {
    persistedSessions.set(options.storedSession.id, structuredClone(options.storedSession));
  }
  const createSession = vi.fn((name?: string, model?: string, createOptions?: { id?: string }) =>
    makeSession({
      id: createOptions?.id ?? "voice-created",
      name,
      model,
      workspaceId: undefined,
    }),
  );
  const saveSession = vi.fn((session: Session) => {
    persistedSessions.set(session.id, structuredClone(session));
  });
  const getSession = vi.fn((sessionId: string) => {
    const session = persistedSessions.get(sessionId);
    return session ? structuredClone(session) : undefined;
  });
  const startSession = vi.fn(async () => {
    if (options.startSessionError) throw options.startSessionError;
    return options.started ?? makeVoiceSession({ status: "ready" });
  });
  const isSessionConnected = vi.fn(() => options.live === true);
  const getActiveSession = vi.fn(() => (options.live ? options.started : undefined));

  const deps: SessionLifecycleServiceDeps = {
    storage: {
      createSession,
      deleteSession: vi.fn(() => true),
      getDataDir: vi.fn(() => options.dataDir ?? join(tmpdir(), "oppi-voice-lifecycle")),
      getSession,
      getWorkspace: vi.fn(() => makeWorkspace()),
      listSessions: vi.fn(() =>
        Array.from(persistedSessions.values(), (session) => structuredClone(session)),
      ),
      saveSession,
      findSessionByLaunchIdempotencyKey: vi.fn(() => undefined),
      claimSessionLaunchRecovery: vi.fn(() => undefined),
    },
    sessions: {
      runCommand: vi.fn(async () => {}),
      sendPrompt: vi.fn(async () => {}),
      startSession,
      stopSession: vi.fn(async () => {}),
    },
    sessionRuntimes: {
      isSessionConnected,
      getSessionSnapshot: vi.fn(() => undefined),
      getActiveSession,
      refreshSessionState: vi.fn(async () => null),
      stopSession: vi.fn(async () => {}),
      stopSessionIfActive: vi.fn(async () => null),
    },
    ensureSessionContextWindow: (session) => ({
      ...session,
      contextWindow: session.contextWindow ?? 200_000,
    }),
  };

  return {
    service: new SessionLifecycleService(deps),
    createSession,
    saveSession,
    startSession,
    getPersistedSession: (sessionId: string) => persistedSessions.get(sessionId),
  };
}

function makeHandler(
  session: Session,
  voiceCalls = new VoiceCallController({ nextCallId: () => "call-1" }),
) {
  const outbound: import("../src/types.js").ServerMessage[] = [];
  const sessions = {
    sendPrompt: vi.fn(async () => {}),
    sendSteer: vi.fn(async () => {}),
    sendFollowUp: vi.fn(async () => {}),
    getMessageQueue: vi.fn(() => ({ version: 0, steering: [], followUp: [] })),
    setMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    sendAbort: vi.fn(async () => {}),
    stopSession: vi.fn(async () => {}),
    getActiveSession: vi.fn(() => undefined as Session | undefined),
    respondToUIRequest: vi.fn(() => true),
    forwardClientCommand: vi.fn(async () => {}),
  };
  const handler = new WsMessageHandler({
    sessions: sessions as unknown as WsMessageHandlerDeps["sessions"],
    ensureSessionContextWindow: (value) => value,
    voiceCalls,
  });
  return {
    handler,
    session,
    voiceCalls,
    sent: outbound,
    dispatch: (
      msg: import("../src/types.js").ClientMessage,
      meta: { connId?: string; authenticatedDeviceId?: string } = {
        connId: "connection-1",
        authenticatedDeviceId: "paired-device-1",
      },
    ) => handler.handleClientMessage(session, msg, (message) => outbound.push(message), meta),
  };
}

describe("hidden voice-control session purpose", () => {
  it("does not infer voice-control from a missing workspace or a control session", () => {
    expect(isDeclaredVoiceControlSession(makeSession({ workspaceId: undefined }))).toBe(false);
    expect(
      isDeclaredVoiceControlSession(
        makeSession({
          workspaceId: undefined,
          control: { domain: "agents", intent: "create" },
        }),
      ),
    ).toBe(false);
    expect(isDeclaredVoiceControlSession(makeVoiceSession())).toBe(true);
    expect(isDeclaredVoiceControlSession(makeVoiceSession({ workspaceId: "ws-1" }))).toBe(false);
  });

  it("gives voice-controller identity only to paired-device principals", () => {
    expect(authenticatedVoiceDeviceId({ kind: "owner" })).toBeUndefined();
    expect(authenticatedVoiceDeviceId({ kind: "device", deviceId: "paired-device-1" })).toBe(
      "paired-device-1",
    );
  });

  it("creates a hidden workspace-less voice-control session", async () => {
    const { service, saveSession, startSession } = makeLifecycleService();

    const result = await service.createVoiceControlSession();

    expect(isDeclaredVoiceControlSession(result.session)).toBe(true);
    expect(result.session.workspaceId).toBeUndefined();
    expect(result.session.control).toBeUndefined();
    expect(result.session.voice).toEqual({ purpose: "voice-control" });
    expect(result.session.runtime).toBe("oppi");
    expect(saveSession).toHaveBeenCalledWith(
      expect.objectContaining({
        voice: { purpose: "voice-control" },
        workspaceId: undefined,
      }),
    );
    expect(startSession).toHaveBeenCalledWith("voice-created", undefined);
  });

  it("resumes a declared voice-control session and rejects ordinary workspace or control sessions", async () => {
    const voice = makeVoiceSession({ status: "stopped" });
    const { service, startSession } = makeLifecycleService({
      started: makeVoiceSession({ status: "ready" }),
    });

    const resumed = await service.resumeVoiceControlSession(voice);
    expect(startSession).toHaveBeenCalledWith(voice.id, undefined);
    expect(resumed).toMatchObject({ owner: "oppi", startedSession: true });
    expect(isDeclaredVoiceControlSession(resumed.session)).toBe(true);

    await expect(service.resumeVoiceControlSession(makeSession())).rejects.toBeInstanceOf(
      SessionLifecycleError,
    );
    await expect(
      service.resumeVoiceControlSession(
        makeSession({
          workspaceId: undefined,
          control: { domain: "workspaces", intent: "create" },
        }),
      ),
    ).rejects.toMatchObject({ statusCode: 400, message: "Session is not a voice-control session" });
  });

  it("keeps the voice-control purpose across a SQLite reload and does not restore in-memory calls", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-restart-"));
    try {
      const writer = new Storage(dir);
      const lifecycle = new SessionLifecycleService({
        storage: writer,
        sessions: {
          runCommand: vi.fn(async () => {}),
          sendPrompt: vi.fn(async () => {}),
          startSession: vi.fn(async (sessionId: string) => {
            const session = writer.getSession(sessionId);
            if (!session) throw new Error("missing session");
            session.status = "ready";
            writer.saveSession(session);
            return session;
          }),
          stopSession: vi.fn(async () => {}),
        },
        sessionRuntimes: {
          isSessionConnected: () => false,
          getSessionSnapshot: () => undefined,
          getActiveSession: () => undefined,
          refreshSessionState: async () => null,
          stopSession: async () => {},
          stopSessionIfActive: async () => null,
        },
        ensureSessionContextWindow: (session) => session,
      });

      const created = await lifecycle.createVoiceControlSession({ name: "Voice Control" });
      const liveCalls = new VoiceCallController({ nextCallId: () => "call-before-restart" });
      const liveHandler = new WsMessageHandler({
        sessions: {
          sendPrompt: vi.fn(async () => {}),
          sendSteer: vi.fn(async () => {}),
          sendFollowUp: vi.fn(async () => {}),
          getMessageQueue: vi.fn(() => ({ version: 0, steering: [], followUp: [] })),
          setMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
          sendAbort: vi.fn(async () => {}),
          stopSession: vi.fn(async () => {}),
          getActiveSession: vi.fn(() => undefined),
          respondToUIRequest: vi.fn(() => true),
          forwardClientCommand: vi.fn(async () => {}),
        } as unknown as WsMessageHandlerDeps["sessions"],
        ensureSessionContextWindow: (session) => session,
        voiceCalls: liveCalls,
      });
      const beforeRestart: import("../src/types.js").ServerMessage[] = [];
      await liveHandler.handleClientMessage(
        created.session,
        { type: "voice_call_start", clientCallId: "client-call-1", requestId: "start-1" },
        (message) => beforeRestart.push(message),
        { connId: "connection-live", authenticatedDeviceId: "paired-device-1" },
      );
      expect(beforeRestart).toContainEqual(
        expect.objectContaining({ type: "voice_call_state", callId: "call-before-restart" }),
      );

      const reader = new Storage(dir);
      const persisted = reader.getSession(created.session.id);
      if (!persisted)
        throw new Error("Expected the voice-control session to survive SQLite reload");
      expect(isDeclaredVoiceControlSession(persisted)).toBe(true);
      expect(persisted.voice).toEqual({ purpose: "voice-control" });

      const restartedCalls = new VoiceCallController({ nextCallId: () => "call-after-restart" });
      expect(() => restartedCalls.snapshot("call-before-restart")).toThrow("Unknown voice call");

      const restartedLifecycle = new SessionLifecycleService({
        storage: reader,
        sessions: {
          runCommand: vi.fn(async () => {}),
          sendPrompt: vi.fn(async () => {}),
          startSession: vi.fn(async (sessionId: string) => {
            const session = reader.getSession(sessionId);
            if (!session) throw new Error("missing session");
            session.status = "ready";
            reader.saveSession(session);
            return session;
          }),
          stopSession: vi.fn(async () => {}),
        },
        sessionRuntimes: {
          isSessionConnected: () => false,
          getSessionSnapshot: () => undefined,
          getActiveSession: () => undefined,
          refreshSessionState: async () => null,
          stopSession: async () => {},
          stopSessionIfActive: async () => null,
        },
        ensureSessionContextWindow: (session) => session,
      });
      const resumed = await restartedLifecycle.resumeVoiceControlSession(persisted);
      expect(resumed.startedSession).toBe(true);
      expect(isDeclaredVoiceControlSession(resumed.session)).toBe(true);

      const restartedHandler = new WsMessageHandler({
        sessions: {
          sendPrompt: vi.fn(async () => {}),
          sendSteer: vi.fn(async () => {}),
          sendFollowUp: vi.fn(async () => {}),
          getMessageQueue: vi.fn(() => ({ version: 0, steering: [], followUp: [] })),
          setMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
          sendAbort: vi.fn(async () => {}),
          stopSession: vi.fn(async () => {}),
          getActiveSession: vi.fn(() => undefined),
          respondToUIRequest: vi.fn(() => true),
          forwardClientCommand: vi.fn(async () => {}),
        } as unknown as WsMessageHandlerDeps["sessions"],
        ensureSessionContextWindow: (session) => session,
        voiceCalls: restartedCalls,
      });
      const afterRestart: import("../src/types.js").ServerMessage[] = [];
      await restartedHandler.handleClientMessage(
        resumed.session,
        {
          type: "voice_call_attach",
          callId: "call-before-restart",
          requestId: "attach-stale",
        },
        (message) => afterRestart.push(message),
        { connId: "connection-restart", authenticatedDeviceId: "paired-device-1" },
      );
      expect(afterRestart).toContainEqual(
        expect.objectContaining({
          type: "command_result",
          command: "voice_call_attach",
          success: false,
          error: "Unknown voice call: call-before-restart",
        }),
      );

      afterRestart.length = 0;
      await restartedHandler.handleClientMessage(
        resumed.session,
        {
          type: "voice_call_start",
          clientCallId: "client-call-after-restart",
          requestId: "start-2",
        },
        (message) => afterRestart.push(message),
        { connId: "connection-restart", authenticatedDeviceId: "paired-device-1" },
      );
      expect(afterRestart).toContainEqual(
        expect.objectContaining({
          type: "voice_call_state",
          callId: "call-after-restart",
          controlSessionId: resumed.session.id,
          lifecycle: "active",
        }),
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("voice-control authorization and reconnect", () => {
  it("rejects voice_call_start on ordinary workspace and control sessions", async () => {
    const workspace = makeHandler(makeSession());
    await workspace.dispatch({
      type: "voice_call_start",
      clientCallId: "client-call-1",
      requestId: "voice-workspace",
    });
    expect(workspace.sent).toEqual([
      expect.objectContaining({
        type: "command_result",
        command: "voice_call_start",
        success: false,
        error: "Continuous voice requires a hidden voice-control session",
      }),
    ]);

    const control = makeHandler(
      makeSession({
        id: "control-1",
        workspaceId: undefined,
        control: { domain: "agents", intent: "create" },
      }),
    );
    await control.dispatch({
      type: "voice_call_start",
      clientCallId: "client-call-1",
      requestId: "voice-control",
    });
    expect(control.sent).toEqual([
      expect.objectContaining({
        type: "command_result",
        command: "voice_call_start",
        success: false,
        error: "Continuous voice requires a hidden voice-control session",
      }),
    ]);
  });

  it("starts, detaches, and reattaches a call only on a hidden voice-control session", async () => {
    const harness = makeHandler(makeVoiceSession());
    const meta = { connId: "connection-1", authenticatedDeviceId: "paired-device-1" };

    await harness.dispatch(
      { type: "voice_call_start", clientCallId: "client-call-1", requestId: "start" },
      meta,
    );
    expect(harness.sent).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        callId: "call-1",
        controlSessionId: "voice-1",
        lifecycle: "active",
        frontend: "attached",
        controllerLeaseEpoch: 1,
      }),
    );

    const started = harness.voiceCalls.snapshot("call-1");
    harness.sent.length = 0;
    await harness.dispatch(
      {
        type: "voice_call_detach",
        callId: "call-1",
        controllerLeaseEpoch: started.controllerLeaseEpoch,
        requestId: "detach",
      },
      meta,
    );
    expect(harness.sent).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        callId: "call-1",
        frontend: "detached",
      }),
    );

    harness.sent.length = 0;
    await harness.dispatch(
      {
        type: "voice_call_attach",
        callId: "call-1",
        lastEventSeq: 0,
        requestId: "attach",
      },
      { connId: "connection-2", authenticatedDeviceId: "paired-device-1" },
    );
    expect(harness.sent).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        callId: "call-1",
        frontend: "attached",
        controlSessionId: "voice-1",
      }),
    );
    expect(harness.voiceCalls.snapshot("call-1").controllerLeaseEpoch).toBeGreaterThan(
      started.controllerLeaseEpoch,
    );
  });

  it("rejects owner-token streams that have no paired-device identity", async () => {
    const harness = makeHandler(makeVoiceSession());
    await harness.dispatch(
      { type: "voice_call_start", clientCallId: "client-call-1", requestId: "owner" },
      { connId: "connection-owner" },
    );
    expect(harness.sent).toEqual([
      expect.objectContaining({
        type: "command_result",
        command: "voice_call_start",
        success: false,
        error: "Continuous voice requires an authenticated paired device",
      }),
    ]);
  });
});

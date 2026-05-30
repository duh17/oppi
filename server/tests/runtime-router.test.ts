import { describe, expect, it, vi } from "vitest";

import { SessionRuntimeRouter } from "../src/runtime-router.js";
import type { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import type { SessionManager } from "../src/sessions.js";
import type { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";
import type { WsSessionCommands } from "../src/ws-message-handler.js";

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

function makeCommands(): WsSessionCommands {
  return {
    sendPrompt: vi.fn(async () => {}),
    sendSteer: vi.fn(async () => {}),
    sendFollowUp: vi.fn(async () => {}),
    getMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    setMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    sendAbort: vi.fn(async () => {}),
    stopSession: vi.fn(async () => {}),
    getActiveSession: vi.fn(() => undefined),
    respondToUIRequest: vi.fn(() => false),
    forwardClientCommand: vi.fn(async () => {}),
  };
}

function makeRouter(session: Session, options: { mirrorConnected?: boolean } = {}) {
  const storage = {
    getSession: vi.fn(() => session),
    saveSession: vi.fn((updated: Session) => {
      Object.assign(session, structuredClone(updated));
    }),
  };
  const managedCommands = makeCommands();
  const managed = {
    ...managedCommands,
    startSession: vi.fn(async () => {
      session.status = "ready";
      return session;
    }),
  };
  const mirror = {
    ...makeCommands(),
    isSessionConnected: vi.fn(
      () => options.mirrorConnected ?? session.mirror?.status === "connected",
    ),
  };
  const router = new SessionRuntimeRouter(
    storage as unknown as Storage,
    managed as unknown as SessionManager,
    mirror as unknown as PiTuiMirrorRuntime,
  );

  return { router, storage, managed, mirror, session };
}

describe("SessionRuntimeRouter", () => {
  it("routes connected terminal mirror prompts to the mirror runtime", async () => {
    const session = makeSession({
      runtime: "pi-tui-mirror",
      mirror: { status: "connected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, managed, mirror } = makeRouter(session, { mirrorConnected: true });

    await router.sendPrompt("sess-1", "hello", { timestamp: 10 });

    expect(mirror.sendPrompt).toHaveBeenCalledWith("sess-1", "hello", { timestamp: 10 });
    expect(managed.startSession).not.toHaveBeenCalled();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
  });

  it("keeps stale connected terminal mirrors routed to the mirror runtime", async () => {
    const session = makeSession({
      runtime: "pi-tui-mirror",
      status: "busy",
      currentTurnStartedAt: 2,
      mirror: { status: "connected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, storage, managed, mirror } = makeRouter(session, { mirrorConnected: false });

    await router.sendPrompt("sess-1", "resume here", { timestamp: 10 });

    expect(storage.saveSession).not.toHaveBeenCalled();
    expect(session.runtime).toBe("pi-tui-mirror");
    expect(session.currentTurnStartedAt).toBe(2);
    expect(managed.startSession).not.toHaveBeenCalled();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
    expect(mirror.sendPrompt).toHaveBeenCalledWith("sess-1", "resume here", { timestamp: 10 });
  });

  it("keeps disconnected terminal mirrors terminal-owned instead of promoting", async () => {
    const session = makeSession({
      runtime: "pi-tui-mirror",
      status: "busy",
      currentTurnStartedAt: 2,
      mirror: { status: "disconnected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, storage, managed, mirror } = makeRouter(session, { mirrorConnected: false });

    await router.sendPrompt("sess-1", "resume here", { timestamp: 10 });

    expect(storage.saveSession).not.toHaveBeenCalled();
    expect(session.runtime).toBe("pi-tui-mirror");
    expect(session.currentTurnStartedAt).toBe(2);
    expect(managed.startSession).not.toHaveBeenCalled();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
    expect(mirror.sendPrompt).toHaveBeenCalledWith("sess-1", "resume here", { timestamp: 10 });
  });

  it("keeps stale mirror steer messages routed to the mirror runtime", async () => {
    const session = makeSession({
      runtime: "pi-tui-mirror",
      status: "busy",
      mirror: { status: "disconnected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, managed, mirror } = makeRouter(session);

    await router.sendSteer("sess-1", "actually continue", { requestId: "req-1" });

    expect(managed.startSession).not.toHaveBeenCalled();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
    expect(mirror.sendSteer).toHaveBeenCalledWith("sess-1", "actually continue", {
      requestId: "req-1",
    });
  });
});

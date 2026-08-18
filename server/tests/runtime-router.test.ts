import { describe, expect, it, vi } from "vitest";

import { SessionRuntimes } from "../src/runtime-router.js";
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

function makeRouter(
  session: Session,
  options: { mirrorConnected?: boolean; mirrorLeafId?: string } = {},
) {
  const storage = {
    getSession: vi.fn((sessionId: string) =>
      sessionId === "managed-1" ? makeSession({ id: "managed-1" }) : session,
    ),
    saveSession: vi.fn((updated: Session) => {
      Object.assign(session, structuredClone(updated));
    }),
  };
  const managedCommands = makeCommands();
  const managed = {
    ...managedCommands,
    isActive: vi.fn(() => session.runtime !== "pi-tui" && session.status !== "stopped"),
    isSessionConnected: vi.fn((sessionId: string) => sessionId === "managed-1"),
    getActiveSessionIds: vi.fn(() => new Set(["managed-1"])),
    getActiveSession: vi.fn((sessionId: string) =>
      sessionId === "managed-1" ? makeSession({ id: "managed-1" }) : undefined,
    ),
    getCurrentSeq: vi.fn(() => 11),
    getCatchUp: vi.fn(() => null),
    subscribe: vi.fn(() => () => {}),
    getPendingUIRequestMessages: vi.fn(() => []),
    getToolFullOutputPath: vi.fn(() => "/tmp/managed-full-output.txt"),
    getEventRing: vi.fn(() => ({ length: 1, capacity: 500 })),
    refreshSessionState: vi.fn(async () => ({ sessionFile: "/tmp/managed.jsonl" })),
    startSession: vi.fn(async () => {
      session.status = "ready";
      return session;
    }),
  };
  const mirrorConnected = options.mirrorConnected ?? session.mirror?.status === "connected";
  const mirror = {
    ...makeCommands(),
    getActiveSessionIds: vi.fn(() => (mirrorConnected ? new Set(["sess-1"]) : new Set<string>())),
    getActiveSession: vi.fn(() => session),
    getCurrentSeq: vi.fn(() => 22),
    getCatchUp: vi.fn(() => ({
      events: [],
      currentSeq: 22,
      session,
      catchUpComplete: true,
    })),
    subscribe: vi.fn(() => () => {}),
    getPendingUIRequestMessages: vi.fn(() => []),
    getToolFullOutputPath: vi.fn(() => "/tmp/mirror-full-output.txt"),
    getEventRing: vi.fn(() => ({ length: 2, capacity: 500 })),
    getSessionTraceState: vi.fn(() => ({
      sessionFile: session.piSessionFile,
      sessionId: session.id,
      ...(options.mirrorLeafId ? { leafId: options.mirrorLeafId } : {}),
    })),
    isSessionConnected: vi.fn(() => mirrorConnected),
  };
  const router = new SessionRuntimes(
    storage as unknown as Storage,
    managed as unknown as SessionManager,
    mirror as unknown as PiTuiMirrorRuntime,
  );

  return { router, storage, managed, mirror, session };
}

describe("SessionRuntimes", () => {
  it("routes connected terminal mirror prompts to the mirror runtime", async () => {
    const session = makeSession({
      runtime: "pi-tui",
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
      runtime: "pi-tui",
      status: "busy",
      currentTurnStartedAt: 2,
      mirror: { status: "connected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, storage, managed, mirror } = makeRouter(session, { mirrorConnected: false });

    await router.sendPrompt("sess-1", "resume here", { timestamp: 10 });

    expect(storage.saveSession).not.toHaveBeenCalled();
    expect(session.runtime).toBe("pi-tui");
    expect(session.currentTurnStartedAt).toBe(2);
    expect(managed.startSession).not.toHaveBeenCalled();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
    expect(mirror.sendPrompt).toHaveBeenCalledWith("sess-1", "resume here", { timestamp: 10 });
  });

  it("keeps disconnected terminal mirrors terminal-owned instead of promoting", async () => {
    const session = makeSession({
      runtime: "pi-tui",
      status: "busy",
      currentTurnStartedAt: 2,
      mirror: { status: "disconnected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, storage, managed, mirror } = makeRouter(session, { mirrorConnected: false });

    await router.sendPrompt("sess-1", "resume here", { timestamp: 10 });

    expect(storage.saveSession).not.toHaveBeenCalled();
    expect(session.runtime).toBe("pi-tui");
    expect(session.currentTurnStartedAt).toBe(2);
    expect(managed.startSession).not.toHaveBeenCalled();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
    expect(mirror.sendPrompt).toHaveBeenCalledWith("sess-1", "resume here", { timestamp: 10 });
  });

  it("keeps an in-flight command with the runtime owner selected at dispatch", async () => {
    const session = makeSession({
      runtime: "pi-tui",
      status: "busy",
      mirror: { status: "connected" },
      piSessionFile: "/tmp/session.jsonl",
    });
    const { router, managed, mirror } = makeRouter(session, { mirrorConnected: true });
    let finishPrompt: (() => void) | undefined;
    vi.mocked(mirror.sendPrompt).mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          finishPrompt = resolve;
        }),
    );

    const prompt = router.sendPrompt("sess-1", "stay on the selected owner", {
      requestId: "req-owner",
    });
    expect(finishPrompt).toBeDefined();

    session.runtime = "oppi";
    session.mirror = undefined;
    finishPrompt?.();
    await prompt;

    expect(mirror.sendPrompt).toHaveBeenCalledOnce();
    expect(managed.sendPrompt).not.toHaveBeenCalled();
  });

  it("keeps stale mirror steer messages routed to the mirror runtime", async () => {
    const session = makeSession({
      runtime: "pi-tui",
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

  it("unifies live active ids across Oppi and pi-tui runtimes", () => {
    const session = makeSession({ runtime: "pi-tui" });
    const { router } = makeRouter(session, { mirrorConnected: true });

    expect(router.getActiveSessionIds()).toEqual(new Set(["managed-1", "sess-1"]));
  });

  it("keeps disconnected pi-tui sessions out of live active ids", () => {
    const session = makeSession({ runtime: "pi-tui", mirror: { status: "disconnected" } });
    const { router } = makeRouter(session, { mirrorConnected: false });

    expect(router.getActiveSessionIds()).toEqual(new Set(["managed-1"]));
    expect(router.getActiveSession("sess-1")).toBeUndefined();
    expect(router.getSessionSnapshot("sess-1")).toBe(session);
  });

  it("routes mirror read-side lookups through the pi-tui runtime", async () => {
    const session = makeSession({
      runtime: "pi-tui",
      piSessionFile: "/tmp/mirror.jsonl",
    });
    const { router, managed, mirror } = makeRouter(session, { mirrorLeafId: "leaf-1" });

    expect(router.getCurrentSeq("sess-1")).toBe(22);
    expect(router.getCatchUp("sess-1", 10)?.currentSeq).toBe(22);
    expect(router.getToolFullOutputPath("sess-1", "tool-1")).toBe("/tmp/mirror-full-output.txt");
    await expect(router.refreshSessionState("sess-1")).resolves.toEqual({
      sessionFile: "/tmp/mirror.jsonl",
      sessionId: "sess-1",
      leafId: "leaf-1",
    });
    expect(managed.refreshSessionState).not.toHaveBeenCalled();
    expect(mirror.getCatchUp).toHaveBeenCalledWith("sess-1", 10);
  });

  it("best-effort delete stop skips disconnected pi-tui sessions", async () => {
    const session = makeSession({
      runtime: "pi-tui",
      mirror: { status: "disconnected" },
    });
    const { router, mirror } = makeRouter(session, { mirrorConnected: false });

    await router.stopSessionIfActive("sess-1");

    expect(mirror.stopSession).not.toHaveBeenCalled();
  });
});

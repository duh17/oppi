import { describe, expect, it, vi } from "vitest";

import type { ProgramStatusSync } from "../src/program-status.js";
import { SessionPushNotifier } from "../src/session-push-notifier.js";
import type { PushClient, SessionEventPushPayload } from "../src/push.js";
import type { SessionBroadcastEvent } from "../src/session-broadcast.js";
import type { Storage } from "../src/storage.js";
import type { ProgramStatus, Session } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makePush() {
  const sendSessionEventPush = vi.fn(async () => true);
  return {
    sendSessionEventPush,
    sendLiveActivityUpdate: vi.fn(async () => true),
    endLiveActivity: vi.fn(async () => true),
    shutdown: vi.fn(),
  } as unknown as PushClient & {
    sendSessionEventPush: ReturnType<
      typeof vi.fn<(...args: [string, SessionEventPushPayload]) => Promise<boolean>>
    >;
  };
}

type MockStorage = Storage & {
  getPushDeviceTokens: ReturnType<typeof vi.fn<() => string[]>>;
  getSession: ReturnType<typeof vi.fn<(id: string) => Session | undefined>>;
};

function makeStorage(tokens: string[], session: Session | undefined = makeSession()): MockStorage {
  return {
    getPushDeviceTokens: vi.fn(() => tokens),
    getSession: vi.fn((id: string) => (session?.id === id ? session : undefined)),
  } as unknown as MockStorage;
}

function makeNotifier(
  push: PushClient,
  storage: Storage,
  options: { connected?: boolean; now?: () => number } = {},
) {
  return new SessionPushNotifier(push, storage, {
    isClientConnected: () => options.connected ?? false,
    ...(options.now ? { now: options.now } : {}),
  });
}

function event(
  sessionId: string,
  eventPayload: SessionBroadcastEvent["event"],
): SessionBroadcastEvent {
  return {
    sessionId,
    event: eventPayload,
    durable: true,
  };
}

function change(
  previous: Partial<ProgramStatus> | undefined,
  current: Partial<ProgramStatus>,
): ProgramStatusSync {
  const prev = previous && ({ state: "working", since: 1, ...previous } as ProgramStatus);
  const next = { state: "working", since: 2, ...current } as ProgramStatus;
  return {
    previous: prev,
    current: next,
    changed: !prev || prev.state !== next.state || prev.message !== next.message,
  };
}

describe("SessionPushNotifier", () => {
  it("sends session-ended alerts to every registered APNs token", () => {
    const push = makePush();
    const storage = makeStorage(["token-a", "token-b"], makeSession({ name: "Deploy fix" }));
    const notifier = makeNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "completed" }));

    expect(push.sendSessionEventPush).toHaveBeenCalledTimes(2);
    expect(push.sendSessionEventPush).toHaveBeenNthCalledWith(1, "token-a", {
      sessionId: "s1",
      sessionName: "Deploy fix",
      event: "ended",
      reason: "completed",
    });
    expect(push.sendSessionEventPush).toHaveBeenNthCalledWith(2, "token-b", {
      sessionId: "s1",
      sessionName: "Deploy fix",
      event: "ended",
      reason: "completed",
    });
  });

  it("redacts non-retry error alert bodies before sending to APNs", () => {
    const push = makePush();
    const storage = makeStorage(["token-a"], makeSession({ name: "Bug hunt" }));
    const notifier = makeNotifier(push, storage);
    const rawError =
      "model crashed while reading /Users/alice/.ssh/id_rsa with bearer token sk_secret";

    notifier.handleSessionEvent(event("s1", { type: "error", error: rawError }));

    expect(push.sendSessionEventPush).toHaveBeenCalledWith("token-a", {
      sessionId: "s1",
      sessionName: "Bug hunt",
      event: "error",
      reason: "Open Oppi to review the session error.",
    });
    expect(JSON.stringify(push.sendSessionEventPush.mock.calls)).not.toContain(rawError);
  });

  it("ignores retry errors without loading the session", () => {
    const push = makePush();
    const storage = makeStorage(["token-a"]);
    const notifier = makeNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "error", error: "Retrying (3/5)" }));

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.sendSessionEventPush).not.toHaveBeenCalled();
  });

  it("ignores terminal events without regular APNs tokens before loading the session", () => {
    const push = makePush();
    const storage = makeStorage([]);
    const notifier = makeNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "done" }));

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.sendSessionEventPush).not.toHaveBeenCalled();
  });

  describe("program status pushes", () => {
    it.each([
      ["permission", "Waiting for your approval."],
      ["question", "Waiting for your answer."],
      ["auth", "Waiting for you to sign in."],
    ] as const)("pushes on entering blocked (%s) with a fixed body", (kind, reason) => {
      const push = makePush();
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(["token-a"], session));

      notifier.handleProgramStatusChange(
        session,
        change(
          { state: "working" },
          { state: "blocked", kind, message: "Allow rm -rf /Users/alice/secrets?" },
        ),
      );

      expect(push.sendSessionEventPush).toHaveBeenCalledWith("token-a", {
        sessionId: "s1",
        sessionName: "Deploy",
        event: "blocked",
        kind,
        reason,
      });
      // The dialog title lives in program status; it never reaches the lock screen.
      expect(JSON.stringify(push.sendSessionEventPush.mock.calls)).not.toContain("alice");
    });

    it("treats a blocked status without a kind as a question", () => {
      const push = makePush();
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(["token-a"], session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked" }),
      );

      expect(push.sendSessionEventPush).toHaveBeenCalledWith(
        "token-a",
        expect.objectContaining({ kind: "question", reason: "Waiting for your answer." }),
      );
    });

    it("pushes on entering done with a fixed body and no session or model text", () => {
      const push = makePush();
      const session = makeSession({
        name: "Fix login",
        lastMessage: "SECRET assistant output",
        firstMessage: "SECRET prompt",
      });
      const notifier = makeNotifier(push, makeStorage(["token-a"], session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "done", message: "Fix login" }),
      );

      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(1);
      expect(push.sendSessionEventPush).toHaveBeenCalledWith("token-a", {
        sessionId: "s1",
        sessionName: "Fix login",
        event: "done",
        reason: "The run finished.",
      });
      expect(JSON.stringify(push.sendSessionEventPush.mock.calls)).not.toContain("SECRET");
    });

    it("pushes no done for a delegated session, but still pushes its blocked", () => {
      const push = makePush();
      const child = makeSession({
        id: "child",
        launch: { status: "created", requestedAt: 1, parentSessionId: "parent" },
      });
      const notifier = makeNotifier(push, makeStorage(["token-a"], child));

      notifier.handleProgramStatusChange(child, change({ state: "working" }, { state: "done" }));
      expect(push.sendSessionEventPush).not.toHaveBeenCalled();

      notifier.handleProgramStatusChange(
        child,
        change({ state: "working" }, { state: "blocked", kind: "permission" }),
      );
      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(1);
      expect(push.sendSessionEventPush).toHaveBeenCalledWith(
        "token-a",
        expect.objectContaining({ sessionId: "child", event: "blocked" }),
      );
    });

    it("still pushes done for a top-level session that has launch metadata", () => {
      const push = makePush();
      const session = makeSession({ launch: { status: "created", requestedAt: 1 } });
      const notifier = makeNotifier(push, makeStorage(["token-a"], session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "done" }),
      );

      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(1);
    });

    it.each(["idle", "working", "error"] as const)("does not push on entering %s", (state) => {
      const push = makePush();
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(["token-a"], session));

      notifier.handleProgramStatusChange(session, change({ state: "done" }, { state }));

      expect(push.sendSessionEventPush).not.toHaveBeenCalled();
    });

    it("does not push for message-only changes or a first-ever status", () => {
      const push = makePush();
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(["token-a"], session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "done", message: "a" }, { state: "done", message: "b" }),
      );
      notifier.handleProgramStatusChange(session, change(undefined, { state: "done" }));

      expect(push.sendSessionEventPush).not.toHaveBeenCalled();
    });

    it("stays silent while an Apple client is connected", () => {
      const push = makePush();
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(["token-a"], session), { connected: true });

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: "Which?" }),
      );
      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));

      expect(push.sendSessionEventPush).not.toHaveBeenCalled();
    });

    it("keeps sending ended and error alerts while a client is connected", () => {
      const push = makePush();
      const notifier = makeNotifier(push, makeStorage(["token-a"]), { connected: true });

      notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "completed" }));

      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(1);
    });

    it("rate-limits per session and kind, then allows a later transition", () => {
      const push = makePush();
      const session = makeSession();
      let now = 1_000_000;
      const notifier = makeNotifier(push, makeStorage(["token-a"], session), {
        now: () => now,
      });
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      now += 10_000;
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(1);

      // A different kind, and a different session, are not throttled by that push.
      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: "Q?" }),
      );
      notifier.handleProgramStatusChange(makeSession({ id: "s2" }), toDone);
      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(3);

      now += 60_000;
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(4);
    });

    it("does not start the throttle when there is no device token", () => {
      const push = makePush();
      const session = makeSession();
      const tokens: string[] = [];
      const storage = makeStorage(tokens, session);
      const notifier = makeNotifier(push, storage);
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      tokens.push("token-a");
      notifier.handleProgramStatusChange(session, toDone);

      expect(push.sendSessionEventPush).toHaveBeenCalledTimes(1);
    });
  });
});

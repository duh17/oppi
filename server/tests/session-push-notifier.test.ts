import { describe, expect, it, vi } from "vitest";

import { SessionPushNotifier } from "../src/session-push-notifier.js";
import type { PushClient, SessionEventPushPayload } from "../src/push.js";
import type { SessionBroadcastEvent } from "../src/session-broadcast.js";
import type { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
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

describe("SessionPushNotifier", () => {
  it("sends session-ended alerts to every registered APNs token", () => {
    const push = makePush();
    const storage = makeStorage(["token-a", "token-b"], makeSession({ name: "Deploy fix" }));
    const notifier = new SessionPushNotifier(push, storage);

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
    const notifier = new SessionPushNotifier(push, storage);
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
    const notifier = new SessionPushNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "error", error: "Retrying (3/5)" }));

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.sendSessionEventPush).not.toHaveBeenCalled();
  });

  it("ignores terminal events without regular APNs tokens before loading the session", () => {
    const push = makePush();
    const storage = makeStorage([]);
    const notifier = new SessionPushNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "done" }));

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.sendSessionEventPush).not.toHaveBeenCalled();
  });
});

import { describe, expect, it, vi } from "vitest";

import type { ProgramStatusSync } from "../src/program-status.js";
import { SessionPushNotifier } from "../src/session-push-notifier.js";
import type { PushNotification, PushSender } from "../src/push/push-sender.js";
import type { Storage } from "../src/storage.js";
import type { ProgramStatus, PushRegistration, Session } from "../src/types.js";

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

/** Push registration of paired device "dev-<name>". */
function target(name: string): PushRegistration {
  return {
    deviceId: `dev-${name}`,
    keyId: `kid-${name}`,
    publicKey: "public-key",
    sendToken: `token-${name}`,
    registeredAt: 1,
  };
}

type MockPush = PushSender & {
  send: ReturnType<
    typeof vi.fn<(registration: PushRegistration, notification: PushNotification) => Promise<null>>
  >;
};

/** `devices` is read on every push, so tests can add a registration later. */
function makePush(devices: string[]): MockPush {
  return {
    registrations: vi.fn(() => devices.map(target)),
    send: vi.fn(async () => null),
  } as unknown as MockPush;
}

type MockStorage = Storage & {
  getSession: ReturnType<typeof vi.fn<(id: string) => Session | undefined>>;
};

function makeStorage(session: Session | undefined = makeSession()): MockStorage {
  return {
    getSession: vi.fn((id: string) => (session?.id === id ? session : undefined)),
  } as unknown as MockStorage;
}

function makeNotifier(
  push: PushSender,
  storage: Storage,
  options: { presentDevices?: Iterable<string>; now?: () => number } = {},
) {
  const present = new Set(options.presentDevices ?? []);
  return new SessionPushNotifier(push, storage, {
    isDevicePresent: (deviceId) => present.has(deviceId),
    hasWorkingChild: () => false,
    ...(options.now ? { now: options.now } : {}),
  });
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
  it("seals a failed run's Stopped alert, never the error text, for every registered device", () => {
    const push = makePush(["phone", "ipad"]);
    const session = makeSession({ name: "Bug hunt" });
    const notifier = makeNotifier(push, makeStorage(session));
    const rawError =
      "model crashed while reading /Users/alice/.ssh/id_rsa with bearer token sk_secret";

    notifier.handleProgramStatusChange(
      session,
      change({ state: "working" }, { state: "error", message: rawError }),
    );

    const expected: PushNotification = {
      event: "done",
      title: "Session Done",
      body: "Stopped with an error.",
      sessionId: "s1",
      workspaceId: "w1",
      subtitle: "Bug hunt",
    };
    expect(push.send.mock.calls).toEqual([
      [target("phone"), expected],
      [target("ipad"), expected],
    ]);
    expect(JSON.stringify(push.send.mock.calls)).not.toContain(rawError);
  });

  it("sends nothing and loads no session when no device has a push key", () => {
    const push = makePush([]);
    const storage = makeStorage();
    const notifier = makeNotifier(push, storage);

    notifier.handleProgramStatusChange(
      makeSession(),
      change({ state: "working" }, { state: "error", message: "boom" }),
    );

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.send).not.toHaveBeenCalled();
  });

  describe("program status pushes", () => {
    it.each([
      ["permission", "Needs Approval", "Waiting for your approval."],
      ["question", "Question", "Waiting for your answer."],
      ["auth", "Sign-in Needed", "Waiting for you to sign in."],
    ] as const)("pushes on entering blocked (%s) with fixed text", (kind, title, body) => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change(
          { state: "working" },
          { state: "blocked", kind, message: "Allow rm -rf /Users/alice/secrets?" },
        ),
      );

      expect(push.send).toHaveBeenCalledWith(target("phone"), {
        event: "blocked",
        kind,
        title,
        body,
        sessionId: "s1",
        workspaceId: "w1",
        subtitle: "Deploy",
      });
      // The dialog title lives in program status; v1 pushes never carry it.
      expect(JSON.stringify(push.send.mock.calls)).not.toContain("alice");
    });

    it("treats a blocked status without a kind as a question", () => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked" }),
      );

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ kind: "question", body: "Waiting for your answer." }),
      );
    });

    it.each([
      ["done", "Finished."],
      ["error", "Stopped with an error."],
      ["idle", "Stopped before finishing."],
    ] as const)("pushes one Stopped alert when a run ends as %s", (state, body) => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state }));

      expect(push.send).toHaveBeenCalledTimes(1);
      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ event: "done", title: "Session Done", body }),
      );
    });

    it("pushes on entering done with a fixed body and no model text", () => {
      const push = makePush(["phone"]);
      const session = makeSession({
        name: "Fix login",
        lastMessage: "SECRET assistant output",
        firstMessage: "SECRET prompt",
      });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "done", message: "Fix login" }),
      );

      expect(push.send).toHaveBeenCalledTimes(1);
      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({
          event: "done",
          title: "Session Done",
          body: "Finished.",
        }),
      );
      expect(JSON.stringify(push.send.mock.calls)).not.toContain("SECRET");
    });

    it("pushes no Stopped alert for a delegated session, but still pushes its blocked", () => {
      const push = makePush(["phone"]);
      const child = makeSession({
        id: "child",
        launch: { status: "created", requestedAt: 1, parentSessionId: "parent" },
      });
      const notifier = makeNotifier(push, makeStorage(child));

      notifier.handleProgramStatusChange(child, change({ state: "working" }, { state: "done" }));
      notifier.handleProgramStatusChange(
        child,
        change({ state: "working" }, { state: "error", message: "Connection error." }),
      );
      expect(push.send).not.toHaveBeenCalled();

      notifier.handleProgramStatusChange(
        child,
        change({ state: "working" }, { state: "blocked", kind: "permission" }),
      );
      expect(push.send).toHaveBeenCalledTimes(1);
      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ sessionId: "child", event: "blocked" }),
      );
    });

    it("holds a lead's done while a child works, and pushes the done after its last child", () => {
      const push = makePush(["phone"]);
      const lead = makeSession();
      const working = new Set(["s1"]);
      const notifier = new SessionPushNotifier(push, makeStorage(lead), {
        isDevicePresent: () => false,
        hasWorkingChild: (sessionId) => working.has(sessionId),
      });
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(lead, toDone);
      expect(push.send).not.toHaveBeenCalled();

      // A held done starts no throttle: the lead's final done right after still pushes.
      working.clear();
      notifier.handleProgramStatusChange(lead, toDone);
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("still pushes done for a top-level session that has launch metadata", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ launch: { status: "created", requestedAt: 1 } });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));

      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it.each([
      ["done", "working"],
      ["done", "idle"],
      ["idle", "done"],
      ["error", "idle"],
    ] as const)("does not push from %s to %s: no run stopped", (from, to) => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: from }, { state: to }));

      expect(push.send).not.toHaveBeenCalled();
    });

    it("does not push for message-only changes or a first-ever status", () => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "done", message: "a" }, { state: "done", message: "b" }),
      );
      notifier.handleProgramStatusChange(session, change(undefined, { state: "done" }));

      expect(push.send).not.toHaveBeenCalled();
    });

    it("skips only devices that are present: an open iPad does not silence the phone", () => {
      const push = makePush(["phone", "ipad"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session), {
        presentDevices: ["dev-ipad"],
      });

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: "Which?" }),
      );
      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));

      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual([
        "dev-phone",
        "dev-phone",
      ]);
    });

    it("stays silent while the only device is present, and pushes once it leaves", () => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const present = new Set(["dev-phone"]);
      const notifier = new SessionPushNotifier(push, makeStorage(session), {
        isDevicePresent: (deviceId) => present.has(deviceId),
        hasWorkingChild: () => false,
      });
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).not.toHaveBeenCalled();

      // A skipped push starts no throttle: the next transition after leaving still pushes.
      present.clear();
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("rate-limits per session and kind, then allows a later transition", () => {
      const push = makePush(["phone"]);
      const session = makeSession();
      let now = 1_000_000;
      const notifier = makeNotifier(push, makeStorage(session), { now: () => now });
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      now += 10_000;
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).toHaveBeenCalledTimes(1);

      // A different kind, and a different session, are not throttled by that push.
      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: "Q?" }),
      );
      notifier.handleProgramStatusChange(makeSession({ id: "s2" }), toDone);
      expect(push.send).toHaveBeenCalledTimes(3);

      now += 60_000;
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).toHaveBeenCalledTimes(4);
    });

    it("does not start the throttle when no device has a push key", () => {
      const devices: string[] = [];
      const push = makePush(devices);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      devices.push("phone");
      notifier.handleProgramStatusChange(session, toDone);

      expect(push.send).toHaveBeenCalledTimes(1);
    });
  });
});

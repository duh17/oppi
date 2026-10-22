import { afterEach, describe, expect, it, vi } from "vitest";

import type { ProgramStatusSync } from "../src/program-status.js";
import { SessionPushNotifier } from "../src/session-push-notifier.js";
import { encodePushPlaintextJSON } from "../src/push/envelope.js";
import type { PushNotification, PushSender } from "../src/push/push-sender.js";
import type { Storage } from "../src/storage.js";
import type { ProgramStatus, ProgramStatusKind, PushRegistration, Session } from "../src/types.js";

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
    events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
  };
}

type SendResult = Awaited<ReturnType<PushSender["send"]>>;
type MockPush = PushSender & {
  send: ReturnType<
    typeof vi.fn<
      (registration: PushRegistration, notification: PushNotification) => Promise<SendResult>
    >
  >;
};

/** `devices` is read on every push, so tests can add a registration later. */
function makePush(
  devices: string[],
  result: (deviceId: string) => SendResult = () => ({ status: "delivered" }) as SendResult,
): MockPush {
  return {
    registrations: vi.fn(() => devices.map(target)),
    send: vi.fn(async (registration: PushRegistration) => result(registration.deviceId)),
  } as unknown as MockPush;
}

type MockStorage = Storage & {
  getSession: ReturnType<typeof vi.fn<(id: string) => Session | undefined>>;
};

function makeStorage(...sessions: Session[]): MockStorage {
  const known = sessions.length > 0 ? sessions : [makeSession()];
  return {
    getSession: vi.fn((id: string) => known.find((session) => session.id === id)),
  } as unknown as MockStorage;
}

function makeNotifier(
  push: PushSender,
  storage: Storage,
  options: {
    presentDevices?: Iterable<string>;
    liveSessions?: () => Session[];
    now?: () => number;
  } = {},
) {
  const present = new Set(options.presentDevices ?? []);
  return new SessionPushNotifier(push, storage, {
    isDevicePresent: (deviceId) => present.has(deviceId),
    liveSessions: options.liveSessions ?? (() => []),
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

/** What the phone decrypts: the plaintext after the envelope fits it into 510 bytes. */
function sealed(notification: PushNotification | undefined) {
  if (!notification) throw new Error("nothing sent");
  return JSON.parse(
    encodePushPlaintextJSON({ v: 1, ts: Date.now(), ...notification }).toString("utf8"),
  ) as PushNotification;
}

const child = makeSession({
  id: "child",
  launch: { status: "created", requestedAt: 1, parentSessionId: "s1" },
});

describe("SessionPushNotifier", () => {
  describe("Needs you", () => {
    it.each([
      ["permission", "Needs Approval", "Waiting for your approval."],
      ["question", "Question", "Waiting for your answer."],
      ["auth", "Sign-in Needed", "Waiting for you to sign in."],
    ] as const)(
      "pushes on entering blocked (%s) with what it waits on, else fixed text",
      (kind, title, fixedBody) => {
        const push = makePush(["phone"]);
        const session = makeSession({ name: "Deploy" });
        const notifier = makeNotifier(push, makeStorage(session));
        const expected = (body: string) => ({
          event: "blocked",
          kind,
          title,
          body,
          sessionId: "s1",
          workspaceId: "w1",
          subtitle: "Deploy",
        });

        notifier.handleProgramStatusChange(
          session,
          change({ state: "working" }, { state: "blocked", kind, message: "Push to main?" }),
        );
        expect(push.send).toHaveBeenLastCalledWith(target("phone"), expected("Push to main?"));

        const later = makeNotifier(push, makeStorage(session));
        later.handleProgramStatusChange(
          session,
          change({ state: "working" }, { state: "blocked", kind }),
        );
        expect(push.send).toHaveBeenLastCalledWith(target("phone"), expected(fixedBody));
      },
    );

    it("keeps the session name and shortens a long question to fit", () => {
      const push = makePush(["phone"]);
      const session = makeSession({
        id: "7f9c2d1e-4b3a-4c8d-9e2f-1a2b3c4d5e6f",
        workspaceId: "8a7b6c5d-4e3f-4a1b-9c8d-7e6f5a4b3c2d",
        name: "\u540d".repeat(60),
      });
      const notifier = makeNotifier(push, makeStorage(session));
      const question = "\u554f".repeat(512);

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: question }),
      );

      const phone = sealed(push.send.mock.calls[0]?.[1]);
      expect(phone.subtitle).toBe("\u540d".repeat(32));
      expect(phone.body.endsWith("\u2026")).toBe(true);
      expect(question.startsWith(phone.body.slice(0, -1))).toBe(true);
      expect(phone.body.length).toBeGreaterThan(40);
      // Already fits: the envelope cuts nothing more.
      expect(phone).toMatchObject(push.send.mock.calls[0]?.[1] ?? {});
    });

    it("treats a blocked status without a kind as a question", () => {
      const push = makePush(["phone"]);
      const notifier = makeNotifier(push, makeStorage());

      notifier.handleProgramStatusChange(
        makeSession(),
        change({ state: "working" }, { state: "blocked" }),
      );

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ kind: "question", body: "Waiting for your answer." }),
      );
    });

    it("pushes for a delegated session too", () => {
      const push = makePush(["phone"]);
      const notifier = makeNotifier(push, makeStorage(child));

      notifier.handleProgramStatusChange(
        child,
        change({ state: "working" }, { state: "blocked", kind: "permission" }),
      );

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ sessionId: "child", event: "blocked" }),
      );
    });

    it("skips only present devices, and pushes once the device leaves", () => {
      const push = makePush(["phone", "ipad"]);
      const present = new Set(["dev-phone", "dev-ipad"]);
      const notifier = new SessionPushNotifier(push, makeStorage(), {
        isDevicePresent: (deviceId) => present.has(deviceId),
        liveSessions: () => [],
      });
      const toBlocked = change({ state: "working" }, { state: "blocked", kind: "question" });

      notifier.handleProgramStatusChange(makeSession(), toBlocked);
      expect(push.send).not.toHaveBeenCalled();

      // A skipped push starts no throttle: the next transition after leaving still pushes.
      present.delete("dev-phone");
      notifier.handleProgramStatusChange(makeSession(), toBlocked);
      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual(["dev-phone"]);
    });
  });

  describe("a device that stops being present", () => {
    const T0 = Date.parse("2026-10-17T12:00:00Z");
    const toBlocked = (since: number) =>
      change({ state: "working" }, { state: "blocked", kind: "permission", since });
    const blockedSession = (since: number, kind: ProgramStatusKind = "permission") =>
      makeSession({
        programStatus: { state: "blocked", kind, message: "Push to main?", since },
      });

    afterEach(() => vi.useRealTimers());

    function setup(devices: string[], present: string[], kind: ProgramStatusKind = "permission") {
      vi.useFakeTimers({ now: T0 });
      const push = makePush(devices);
      const session = blockedSession(T0, kind);
      const live = [session];
      const presentSet = new Set(present);
      const notifier = new SessionPushNotifier(push, makeStorage(session), {
        isDevicePresent: (id) => presentSet.has(id),
        liveSessions: () => live,
      });
      return { push, session, notifier, presentSet };
    }

    it("tells that device alone about a session that blocked while it was present", () => {
      const { push, session, notifier, presentSet } = setup(["phone", "ipad"], ["dev-phone"]);
      notifier.handleProgramStatusChange(session, toBlocked(T0));
      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual(["dev-ipad"]);

      vi.setSystemTime(T0 + 30_000);
      presentSet.delete("dev-phone");
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });

      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual([
        "dev-ipad",
        "dev-phone",
      ]);
      expect(push.send).toHaveBeenLastCalledWith(
        target("phone"),
        expect.objectContaining({ event: "blocked", kind: "permission", body: "Push to main?" }),
      );
    });

    it("does not alert a device twice for one blocked stretch", () => {
      const { push, session, notifier } = setup(["phone"], []);
      notifier.handleProgramStatusChange(session, toBlocked(T0));
      expect(push.send).toHaveBeenCalledTimes(1);

      vi.setSystemTime(T0 + 90_000);
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("skips a session blocked longer than two minutes ago, or no longer blocked", () => {
      const { push, session, notifier } = setup(["phone"], []);

      vi.setSystemTime(T0 + 121_000);
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      expect(push.send).not.toHaveBeenCalled();

      vi.setSystemTime(T0 + 119_000);
      session.programStatus = { state: "working", since: T0 + 100_000 };
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      expect(push.send).not.toHaveBeenCalled();
    });

    it("sends nothing to a device that did not list blocked", () => {
      const { push, notifier } = setup([], []);
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      expect(push.send).not.toHaveBeenCalled();
    });

    it("pushes a question only after a drop, and only if it blocked after the last frame", () => {
      const { push, notifier } = setup(["phone"], [], "question");
      // The app closed the stream: its own alert covers a question.
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: false });
      // The stream dropped, but the app had already seen the question.
      notifier.deviceLeft("dev-phone", { heardAt: T0, dropped: true });
      expect(push.send).not.toHaveBeenCalled();

      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("pushes an approval or sign-in on any leave: the app has no local alert for them", () => {
      for (const kind of ["permission", "auth"] as const) {
        const { push, notifier } = setup(["phone"], [], kind);
        notifier.deviceLeft("dev-phone", { heardAt: T0 + 5_000, dropped: false });
        expect(push.send).toHaveBeenCalledTimes(1);
        expect(push.send).toHaveBeenCalledWith(
          target("phone"),
          expect.objectContaining({ event: "blocked", kind }),
        );
      }
    });

    it("does not push an approval again within a minute of the last alert", () => {
      const { push, session, notifier } = setup(["phone"], []);
      vi.setSystemTime(T0 + 30_000);
      notifier.deviceLeft("dev-phone", { heardAt: T0, dropped: false });
      expect(push.send).toHaveBeenCalledTimes(1);

      // The app reopens and the session blocks anew; the phone leaves again 5 s later.
      session.programStatus = { state: "blocked", kind: "permission", since: T0 + 35_000 };
      vi.setSystemTime(T0 + 40_000);
      notifier.deviceLeft("dev-phone", { heardAt: T0 + 36_000, dropped: false });
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("does not alert again when it blocks anew within a minute of the earlier alert", () => {
      const { push, session, notifier, presentSet } = setup(["phone", "ipad"], ["dev-phone"]);
      vi.setSystemTime(T0 + 30_000);
      presentSet.delete("dev-phone");
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      expect(push.send).toHaveBeenCalledTimes(1);

      // Unblocked at +35 s, blocked again at +40 s: the phone was told 10 s ago.
      session.programStatus = { state: "blocked", kind: "permission", since: T0 + 40_000 };
      vi.setSystemTime(T0 + 40_000);
      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "permission", since: T0 + 40_000 }),
      );
      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual([
        "dev-phone",
        "dev-ipad",
      ]);
    });

    it("sends nothing, and schedules no retry, after stop", async () => {
      const unavailable = { status: "unavailable" } as SendResult;
      vi.useFakeTimers({ now: T0 });
      let finish: (value: SendResult) => void = () => {};
      const push = makePush(["phone"]);
      push.send.mockImplementationOnce(
        () => new Promise<SendResult>((resolve) => (finish = resolve)),
      );
      const session = blockedSession(T0);
      const notifier = new SessionPushNotifier(push, makeStorage(session), {
        isDevicePresent: () => false,
        liveSessions: () => [session],
      });
      // A send in flight when the server stops: its failure must not schedule a retry.
      notifier.deviceLeft("dev-phone", { heardAt: T0 - 1, dropped: true });
      notifier.stop();
      finish(unavailable);
      await vi.advanceTimersByTimeAsync(120_000);
      expect(push.send).toHaveBeenCalledTimes(1);

      notifier.deviceLeft("dev-phone", { heardAt: T0 - 2, dropped: true });
      expect(push.send).toHaveBeenCalledTimes(1);
    });
  });

  describe("a Needs you no relay accepted", () => {
    const T0 = Date.parse("2026-10-17T12:00:00Z");
    const unavailable = () => ({ status: "unavailable" }) as SendResult;

    afterEach(() => vi.useRealTimers());

    function setup(result: (deviceId: string) => SendResult) {
      vi.useFakeTimers({ now: T0 });
      const push = makePush(["phone", "ipad"], result);
      const session = makeSession({ programStatus: { state: "blocked", since: T0 } });
      const present = new Set<string>();
      const notifier = new SessionPushNotifier(push, makeStorage(session), {
        isDevicePresent: (id) => present.has(id),
        liveSessions: () => [session],
      });
      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", since: T0 }),
      );
      return { push, session, notifier, present };
    }

    it("is tried once more after a minute while still blocked", async () => {
      const { push } = setup(unavailable);
      await vi.advanceTimersByTimeAsync(0);
      expect(push.send).toHaveBeenCalledTimes(2);

      await vi.advanceTimersByTimeAsync(59_000);
      expect(push.send).toHaveBeenCalledTimes(2);
      await vi.advanceTimersByTimeAsync(1_000);
      expect(push.send).toHaveBeenCalledTimes(4);

      // Only once: the retry failing too schedules nothing further.
      await vi.advanceTimersByTimeAsync(10 * 60_000);
      expect(push.send).toHaveBeenCalledTimes(4);
    });

    it("is not retried once the session left blocked, or blocked again later", async () => {
      const resolved = setup(unavailable);
      await vi.advanceTimersByTimeAsync(0);
      resolved.session.programStatus = { state: "working", since: T0 + 10_000 };
      await vi.advanceTimersByTimeAsync(120_000);
      expect(resolved.push.send).toHaveBeenCalledTimes(2);

      const reblocked = setup(unavailable);
      await vi.advanceTimersByTimeAsync(0);
      reblocked.session.programStatus = { state: "blocked", since: T0 + 20_000 };
      await vi.advanceTimersByTimeAsync(120_000);
      expect(reblocked.push.send).toHaveBeenCalledTimes(2);
    });

    it("is not retried when some device was reached", async () => {
      const { push } = setup((id) =>
        id === "dev-phone" ? ({ status: "delivered" } as SendResult) : unavailable(),
      );
      await vi.advanceTimersByTimeAsync(120_000);
      expect(push.send).toHaveBeenCalledTimes(2);
    });

    it("is not retried to a device that became present, or after stop", async () => {
      const present = setup(unavailable);
      await vi.advanceTimersByTimeAsync(0);
      present.present.add("dev-phone");
      await vi.advanceTimersByTimeAsync(60_000);
      expect(present.push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual([
        "dev-phone",
        "dev-ipad",
        "dev-ipad",
      ]);

      const stopped = setup(unavailable);
      await vi.advanceTimersByTimeAsync(0);
      stopped.notifier.stop();
      await vi.advanceTimersByTimeAsync(120_000);
      expect(stopped.push.send).toHaveBeenCalledTimes(2);
    });
  });

  describe("failed runs", () => {
    it("pushes fixed text, never the error, to every device including present ones", () => {
      const push = makePush(["phone", "ipad"]);
      const session = makeSession({ name: "Bug hunt" });
      const notifier = makeNotifier(push, makeStorage(session), { presentDevices: ["dev-ipad"] });
      const rawError =
        "model crashed while reading /Users/alice/.ssh/id_rsa with bearer token sk_secret";

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "error", message: rawError }),
      );

      const expected: PushNotification = {
        event: "error",
        title: "Session Failed",
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

    it("pushes nothing for a delegated session's failure", () => {
      const push = makePush(["phone"]);
      const notifier = makeNotifier(push, makeStorage(child));

      notifier.handleProgramStatusChange(
        child,
        change({ state: "working" }, { state: "error", message: "Connection error." }),
      );

      expect(push.send).not.toHaveBeenCalled();
    });

    it.each([
      ["working", "done"],
      ["working", "idle"],
      ["blocked", "done"],
      ["done", "working"],
      ["idle", "error"],
      ["error", "idle"],
    ] as const)("pushes nothing from %s to %s", (from, to) => {
      const push = makePush(["phone"]);
      const notifier = makeNotifier(push, makeStorage());

      notifier.handleProgramStatusChange(makeSession(), change({ state: from }, { state: to }));

      expect(push.send).not.toHaveBeenCalled();
    });
  });

  it("pushes nothing for a message-only change or a first-ever status", () => {
    const push = makePush(["phone"]);
    const notifier = makeNotifier(push, makeStorage());

    notifier.handleProgramStatusChange(
      makeSession(),
      change({ state: "blocked", message: "a" }, { state: "blocked", message: "b" }),
    );
    notifier.handleProgramStatusChange(makeSession(), change(undefined, { state: "blocked" }));

    expect(push.send).not.toHaveBeenCalled();
  });

  it("rate-limits per session and alert, then allows a later transition", () => {
    const push = makePush(["phone"]);
    let now = 1_000_000;
    const notifier = makeNotifier(push, makeStorage(), { now: () => now });
    const toError = change({ state: "working" }, { state: "error" });

    notifier.handleProgramStatusChange(makeSession(), toError);
    now += 10_000;
    notifier.handleProgramStatusChange(makeSession(), toError);
    expect(push.send).toHaveBeenCalledTimes(1);

    // Another alert, and another session, are not throttled by that push.
    notifier.handleProgramStatusChange(
      makeSession(),
      change({ state: "working" }, { state: "blocked", kind: "question" }),
    );
    notifier.handleProgramStatusChange(makeSession({ id: "s2" }), toError);
    expect(push.send).toHaveBeenCalledTimes(3);

    now += 60_000;
    notifier.handleProgramStatusChange(makeSession(), toError);
    expect(push.send).toHaveBeenCalledTimes(4);
  });

  it("starts no throttle and loads no session when no device has a push key", () => {
    const devices: string[] = [];
    const push = makePush(devices);
    const storage = makeStorage();
    const notifier = makeNotifier(push, storage);
    const toError = change({ state: "working" }, { state: "error" });

    notifier.handleProgramStatusChange(makeSession(), toError);
    expect(storage.getSession).not.toHaveBeenCalled();
    devices.push("phone");
    notifier.handleProgramStatusChange(makeSession(), toError);

    expect(push.send).toHaveBeenCalledTimes(1);
  });

  describe("agent notify", () => {
    it("is offered to top-level sessions only while a device can receive it", () => {
      const devices: string[] = [];
      const notifier = makeNotifier(makePush(devices), makeStorage(makeSession(), child));

      expect(notifier.offersNotify("s1")).toBe(false);
      devices.push("phone");
      expect(notifier.offersNotify("s1")).toBe(true);
      expect(notifier.offersNotify("child")).toBe(false);
    });

    it("sends the agent's words to every device, present or not, and counts deliveries", async () => {
      const push = makePush(
        ["phone", "ipad", "old"],
        (deviceId) =>
          (deviceId === "dev-old"
            ? { status: "gone", prune: true }
            : { status: "delivered" }) as SendResult,
      );
      const session = makeSession({ name: "Relay work" });
      const notifier = makeNotifier(push, makeStorage(session), { presentDevices: ["dev-ipad"] });

      const outcome = await notifier.notify("s1", {
        title: "  Push relay\nfix landed ",
        body: "Read the summary in the session.\nTwo commits on main.",
      });

      expect(outcome).toEqual({ status: "sent", devices: 2 });
      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual([
        "dev-phone",
        "dev-ipad",
        "dev-old",
      ]);
      expect(push.send.mock.calls[0]?.[1]).toEqual({
        event: "notify",
        title: "Push relay fix landed",
        body: "Read the summary in the session.\nTwo commits on main.",
        sessionId: "s1",
        workspaceId: "w1",
        subtitle: "Relay work",
      });
    });

    it("fits plain text at the tool's limits whole, with the session name", async () => {
      const push = makePush(["phone"]);
      const session = makeSession({
        id: "7f9c2d1e-4b3a-4c8d-9e2f-1a2b3c4d5e6f",
        workspaceId: "8a7b6c5d-4e3f-4a1b-9c8d-7e6f5a4b3c2d",
        name: "Push relay fix and Live Activity cleanup",
      });
      const notifier = makeNotifier(push, makeStorage(session));
      const input = { title: "t".repeat(80), body: "b".repeat(200) };

      expect(await notifier.notify(session.id, input)).toEqual({ status: "sent", devices: 1 });
      expect(sealed(push.send.mock.calls[0]?.[1])).toMatchObject({
        ...input,
        subtitle: "Push relay fix and Live Activity cleanup",
      });
    });

    it("keeps the session name and shortens only the body when the text cannot fit", async () => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "名".repeat(60) });
      const notifier = makeNotifier(push, makeStorage(session));

      const outcome = await notifier.notify("s1", {
        title: "題".repeat(200),
        body: "本".repeat(1000),
      });

      expect(outcome).toEqual({ status: "sent", devices: 1, shortened: true });
      const phone = sealed(push.send.mock.calls[0]?.[1]);
      expect(phone.subtitle).toBe("名".repeat(32));
      expect(phone.title).toBe("題".repeat(53));
      expect(phone.body.length).toBeGreaterThan(20);
      // Already fits: the envelope cuts nothing more.
      expect(phone).toMatchObject(push.send.mock.calls[0]?.[1] ?? {});
    });

    it("answers off without sending when push is off or the session is delegated", async () => {
      const devices: string[] = [];
      const push = makePush(devices);
      const notifier = makeNotifier(push, makeStorage(makeSession(), child));

      expect(await notifier.notify("s1", { title: "t", body: "b" })).toEqual({ status: "off" });
      devices.push("phone");
      expect(await notifier.notify("child", { title: "t", body: "b" })).toEqual({ status: "off" });
      expect(push.send).not.toHaveBeenCalled();
    });

    it("sends once a minute per session and says when to try again", async () => {
      const push = makePush(["phone"]);
      let now = 1_000_000;
      const notifier = makeNotifier(push, makeStorage(), { now: () => now });

      await notifier.notify("s1", { title: "First", body: "b" });
      now += 45_500;
      expect(await notifier.notify("s1", { title: "Second", body: "b" })).toEqual({
        status: "throttled",
        retryAfterSeconds: 15,
      });
      // The Needs you alert is not throttled by it.
      notifier.handleProgramStatusChange(
        makeSession(),
        change({ state: "working" }, { state: "blocked", kind: "question" }),
      );
      now += 15_000;
      expect(await notifier.notify("s1", { title: "Third", body: "b" })).toEqual({
        status: "sent",
        devices: 1,
      });
      expect(push.send.mock.calls.map(([, sent]) => sent.title)).toEqual([
        "First",
        "Question",
        "Third",
      ]);
    });

    it("reports not delivered when no device took it, and lets the agent try again", async () => {
      let accept = false;
      const push = makePush(
        ["phone"],
        () => (accept ? { status: "delivered" } : { status: "throttled" }) as SendResult,
      );
      const notifier = makeNotifier(push, makeStorage());

      expect(await notifier.notify("s1", { title: "t", body: "b" })).toEqual({
        status: "not_delivered",
      });
      accept = true;
      expect(await notifier.notify("s1", { title: "t", body: "b" })).toEqual({
        status: "sent",
        devices: 1,
      });
    });
  });
});

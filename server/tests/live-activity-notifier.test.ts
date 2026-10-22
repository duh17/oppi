import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  LIVE_ACTIVITY_MAX_AGE_MS,
  LIVE_ACTIVITY_MISSING_TOKEN_RETRIES,
  LIVE_ACTIVITY_RESTORE_MAX_AGE_MS,
  LiveActivityNotifier,
  liveActivityCounts,
  type LiveActivityCounts,
} from "../src/live-activity-notifier.js";
import type { PersistedCard } from "../src/live-activity-state-store.js";
import type { PushSender } from "../src/push/push-sender.js";
import type { LiveActivityPush, LiveActivitySendResult } from "../src/push/relay-client.js";
import type { PushRegistration, Session } from "../src/types.js";

const phone: PushRegistration = {
  deviceId: "d_phone",
  keyId: "k",
  publicKey: "p",
  sendToken: "osp1.r.p.s",
  registeredAt: 0,
  liveActivity: true,
  events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
};

const ipad: PushRegistration = { ...phone, deviceId: "d_ipad", sendToken: "osp1.r.p.i" };

function session(id: string, state: string, parentSessionId?: string): Session {
  return {
    id,
    status: "busy",
    createdAt: 0,
    lastActivity: 0,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    programStatus: { state, since: 0 },
    ...(parentSessionId ? { launch: { parentSessionId } } : {}),
  } as unknown as Session;
}

describe("liveActivityCounts", () => {
  it("counts each thread once: needs you if any session in it is blocked, else running if any works", () => {
    expect(
      liveActivityCounts([
        session("a", "working"),
        session("b", "working"),
        session("c", "blocked"),
        session("d", "done"),
        session("e", "idle"),
        // A lead idling while its subagents work runs, once.
        session("lead", "idle"),
        session("lead-child-1", "working", "lead"),
        session("lead-child-2", "working", "lead"),
        session("lead-grandchild", "working", "lead-child-1"),
        // A blocked subagent makes its working lead's thread need you.
        session("child-1", "working", "a"),
        session("child-2", "blocked", "b"),
        // Finished subagents add nothing.
        session("child-3", "done", "e"),
        // Subagents of a session that is gone still count, once per missing parent.
        session("orphan-1", "working", "gone"),
        session("orphan-2", "working", "gone"),
      ]),
    ).toEqual({ running: 3, needsYou: 2 });
  });

  it("caps each count at the relay's bound", () => {
    const many = Array.from({ length: 120 }, (_, index) => session(`s${index}`, "working"));
    expect(liveActivityCounts(many)).toEqual({ running: 99, needsYou: 0 });
  });
});

describe("LiveActivityNotifier", () => {
  let counts: LiveActivityCounts;
  let present: boolean;
  let registrations: PushRegistration[];
  let sent: LiveActivityPush[];
  /** The device each entry of `sent` went to. */
  let sentTo: string[];
  /** Devices holding a live stream, besides all of them while `present`. */
  let presentIds: Set<string>;
  let answer: (push: LiveActivityPush) => LiveActivitySendResult;
  let notifier: LiveActivityNotifier;
  /** What the notifier saved: the card file that outlives a process. */
  let saved: Map<string, PersistedCard>;
  /** The relay never answers. */
  let hang: boolean;

  function build(): LiveActivityNotifier {
    const push = {
      registrations: () => registrations,
      sendLiveActivity: async (registration: PushRegistration, payload: LiveActivityPush) => {
        sent.push(payload);
        sentTo.push(registration.deviceId);
        if (hang) return new Promise<never>(() => undefined);
        return answer(payload);
      },
    } as unknown as Pick<PushSender, "registrations" | "sendLiveActivity">;
    return new LiveActivityNotifier(push, {
      isDevicePresent: (deviceId) => present || presentIds.has(deviceId),
      counts: () => counts,
      state: { load: () => new Map(saved), save: (cards) => void (saved = new Map(cards)) },
    });
  }

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse("2026-10-17T09:00:00Z") });
    counts = { running: 0, needsYou: 0 };
    present = false;
    registrations = [phone];
    sent = [];
    sentTo = [];
    presentIds = new Set();
    answer = () => ({ status: "delivered" });
    saved = new Map();
    hang = false;
    notifier = build();
  });

  afterEach(() => {
    notifier.stop();
    vi.useRealTimers();
  });

  /** The phone was present with nothing running, then left. */
  function leave(): void {
    present = false;
    notifier.presenceChanged(phone.deviceId);
  }

  function change(next: LiveActivityCounts): void {
    counts = next;
    notifier.countsChanged();
  }

  const events = () => sent.map((push) => `${push.event} ${push.running}/${push.needsYou}`);
  const eventsFor = (registration: PushRegistration) =>
    sent
      .filter((_, index) => sentTo[index] === registration.deviceId)
      .map((push) => `${push.event} ${push.running}/${push.needsYou}`);

  it("starts when work begins while the phone is away, then ends when nothing runs", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    expect(events()).toEqual(["start 1/0"]);

    await vi.advanceTimersByTimeAsync(60_000);
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    expect(events()).toEqual(["start 1/0", "end 0/0"]);
  });

  it("sends at most once a minute per device, and the latest counts win", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(10_000);
    change({ running: 2, needsYou: 1 });
    await vi.advanceTimersByTimeAsync(10_000);
    change({ running: 3, needsYou: 1 });
    expect(events()).toEqual(["start 1/0"]);

    await vi.advanceTimersByTimeAsync(39_999);
    expect(events()).toEqual(["start 1/0"]);
    await vi.advanceTimersByTimeAsync(1);
    expect(events()).toEqual(["start 1/0", "update 3/1"]);
  });

  it("sends nothing when the counts return to what the card shows before the minute is up", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(20_000);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(events()).toEqual(["start 1/0"]);
  });

  it("leaves a present phone's card to the app", async () => {
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(sent).toEqual([]);

    // Leaving long after the change: the app's card already shows these counts.
    leave();
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(sent).toEqual([]);
    change({ running: 1, needsYou: 1 });
    await vi.advanceTimersByTimeAsync(0);
    expect(events()).toEqual(["update 1/1"]);

    // Coming back cancels a pending send.
    change({ running: 2, needsYou: 1 });
    present = true;
    notifier.presenceChanged(phone.deviceId);
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(events()).toEqual(["update 1/1"]);
  });

  it("pushes a change made just before the phone left, which a suspended app may have missed", async () => {
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(30_000);
    leave();
    await vi.advanceTimersByTimeAsync(0);
    expect(events()).toEqual(["update 1/0"]);
  });

  it("waits for a new card's update token instead of starting a second card", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    // The phone has not reported the started card's token yet.
    answer = () => ({ status: "no_activity" });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "update 2/0"]);
    answer = () => ({ status: "delivered" });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "update 2/0", "update 2/0"]);
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(sent).toHaveLength(3);
  });

  it("tries one start for a card it cannot reach, then leaves it alone until the counts reach zero", async () => {
    // The person dismissed the app's card, or the phone ended it: the relay holds no token.
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    leave();
    // The relay refuses the start of a dismissed card as well.
    answer = () => ({ status: "no_activity" });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    const updates = Array.from(
      { length: LIVE_ACTIVITY_MISSING_TOKEN_RETRIES + 1 },
      () => "update 2/0",
    );
    expect(events()).toEqual([...updates, "start 2/0"]);
    change({ running: 3, needsYou: 1 });
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS);
    expect(events()).toEqual([...updates, "start 2/0"]);

    // Zero ends the dismissal at the relay; the next work gets a card.
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    answer = () => ({ status: "delivered" });
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual([...updates, "start 2/0", "end 0/0", "start 1/0"]);
  });

  it("starts a card for work that began while the app was backgrounded but connected", async () => {
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(30_000);
    // The app cannot start a card in the background; the relay holds no card token. The
    // relay refuses the updates and accepts the start.
    answer = (push) =>
      push.event === "update" ? { status: "no_activity" } : { status: "delivered" };
    leave();
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    const updates = Array.from(
      { length: LIVE_ACTIVITY_MISSING_TOKEN_RETRIES + 1 },
      () => "update 1/0",
    );
    expect(events()).toEqual([...updates, "start 1/0"]);

    // The new card is this server's: it updates and ends it like any other.
    answer = () => ({ status: "delivered" });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual([...updates, "start 1/0", "update 2/0", "end 0/0"]);
  });

  it("tries that start again after a failure, not after a refusal", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    answer = () => ({ status: "no_activity" });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync((LIVE_ACTIVITY_MISSING_TOKEN_RETRIES + 1) * 60_000);
    answer = (push) =>
      push.event === "update" ? { status: "no_activity" } : { status: "unavailable" };
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events().slice(-1)).toEqual(["start 2/0"]);
    answer = () => ({ status: "delivered" });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(events().slice(-2)).toEqual(["start 2/0", "start 2/0"]);
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(events().filter((entry) => entry.startsWith("start"))).toHaveLength(3);
  });

  it("restarts the card after Apple's 8 hours while work goes on", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS - 1);
    expect(events()).toEqual(["start 1/0"]);
    await vi.advanceTimersByTimeAsync(1);
    expect(events()).toEqual(["start 1/0", "end 0/0", "start 1/0"]);
  });

  it("restarts a card the app started before Apple's 8 hours run out", async () => {
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(3 * 60 * 60_000);
    // The card shows these counts; nothing changes for the rest of the day.
    leave();
    await vi.advanceTimersByTimeAsync(5 * 60 * 60_000 - 1);
    expect(sent).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(events()).toEqual(["end 0/0", "start 1/0"]);
    // And again 8 hours after that.
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS);
    expect(events()).toEqual(["end 0/0", "start 1/0", "end 0/0", "start 1/0"]);
  });

  it("dates a card it kept through a short zero blip by its own start", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(3 * 60 * 60_000);
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    // Zero, and work again, before the end may go out (a minute after the update).
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(20_000);
    change({ running: 1, needsYou: 0 });
    expect(events()).toEqual(["start 1/0", "update 2/0"]);
    // The app opens and leaves; the card, still the server's, is 3 hours and a bit old.
    present = true;
    notifier.presenceChanged(phone.deviceId);
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    leave();
    await vi.advanceTimersByTimeAsync(
      LIVE_ACTIVITY_MAX_AGE_MS - 3 * 60 * 60_000 - 10 * 60_000 - 20_001,
    );
    expect(events()).toEqual(["start 1/0", "update 2/0"]);
    await vi.advanceTimersByTimeAsync(1);
    expect(events()).toEqual(["start 1/0", "update 2/0", "end 0/0", "start 1/0"]);
  });

  it("starts no card over one it could not end", async () => {
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    leave();
    answer = (push) => (push.event === "end" ? { status: "no_activity" } : { status: "delivered" });
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS);
    expect(events()).toEqual(["end 0/0"]);
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(events()).toEqual(["end 0/0"]);
  });

  it("sends no more starts after the relay refused one, ends at zero, and starts the next work's card", async () => {
    answer = () => ({ status: "no_activity" });
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(events()).toEqual(["start 1/0"]);
    // A dismissed card's refusal lasts until an end says the counts reached zero.
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    change({ running: 3, needsYou: 1 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(events()).toEqual(["start 1/0"]);
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "end 0/0"]);
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(sent).toHaveLength(2);
    // The end cleared the dismissal at the relay: the next work shows a card again.
    answer = () => ({ status: "delivered" });
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "end 0/0", "start 1/0"]);
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "end 0/0", "start 1/0", "update 2/0"]);
  });

  it("retries after a relay outage and waits out a quota's Retry-After", async () => {
    answer = () => ({ status: "unavailable" });
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    answer = () => ({ status: "rejected", httpStatus: 429, retryAfterSeconds: 600 });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(events()).toEqual(["start 1/0", "start 1/0"]);
    answer = () => ({ status: "delivered" });
    await vi.advanceTimersByTimeAsync(599_000);
    expect(sent).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(events()).toEqual(["start 1/0", "start 1/0", "start 1/0"]);
  });

  it("ends the card within a minute of zero though an update's 429 asked for hours", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    expect(events()).toEqual(["start 1/0"]);
    // The day's quota is full: updates wait until midnight.
    answer = () => ({ status: "rejected", httpStatus: 429, retryAfterSeconds: 15 * 3600 });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "update 2/0"]);
    change({ running: 3, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    expect(sent).toHaveLength(2);

    answer = () => ({ status: "delivered" });
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "update 2/0", "end 0/0"]);
  });

  it("holds the 8-hour restart's start back until a 429 of its own kind has passed", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    // An update is refused for 2 hours an hour before the card's 8 run out; the counts then
    // return to what the card shows, so nothing waits on the update.
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS - 3600_000);
    answer = () => ({ status: "rejected", httpStatus: 429, retryAfterSeconds: 2 * 3600 });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    answer = () => ({ status: "delivered" });
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(3600_000 - 1);
    expect(events()).toEqual(["start 1/0", "update 2/0"]);
    // The end goes (it has its own limit); the start waits for the update's Retry-After.
    await vi.advanceTimersByTimeAsync(1);
    expect(events()).toEqual(["start 1/0", "update 2/0", "end 0/0"]);
    await vi.advanceTimersByTimeAsync(3600_000 - 1_000);
    expect(sent).toHaveLength(3);
    await vi.advanceTimersByTimeAsync(2_000);
    expect(events()).toEqual(["start 1/0", "update 2/0", "end 0/0", "start 1/0"]);
  });

  it("does not retry an end before the Retry-After of its own 429", async () => {
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    answer = () => ({ status: "rejected", httpStatus: 429, retryAfterSeconds: 3 * 3600 });
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "end 0/0"]);
    await vi.advanceTimersByTimeAsync(3 * 3600_000 - 1_000);
    expect(sent).toHaveLength(2);
    answer = () => ({ status: "delivered" });
    await vi.advanceTimersByTimeAsync(2_000);
    expect(events()).toEqual(["start 1/0", "end 0/0", "end 0/0"]);
  });

  it("ignores devices that do not accept Live Activities", async () => {
    registrations = [{ ...phone, liveActivity: undefined }];
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(sent).toEqual([]);
  });

  it("ends a card left from before a restart once sessions settle", async () => {
    notifier.start();
    await vi.advanceTimersByTimeAsync(59_999);
    expect(sent).toEqual([]);
    answer = () => ({ status: "no_activity" });
    await vi.advanceTimersByTimeAsync(1);
    expect(events()).toEqual(["end 0/0"]);
    // No card: nothing more until work starts.
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(sent).toHaveLength(1);
  });

  it("restarts a card it knows nothing about while work goes on: it may be near 8 hours", async () => {
    counts = { running: 2, needsYou: 1 };
    notifier.start();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["end 0/0", "start 2/1"]);
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS - 1);
    expect(sent).toHaveLength(2);
  });

  describe("across a server restart", () => {
    /** A new server process: the old notifier is gone, the saved cards stay. */
    function restart(): void {
      notifier.stop();
      notifier = build();
    }

    async function startCardAndRestart(cardAgeMs: number): Promise<void> {
      notifier.start();
      leave();
      change({ running: 1, needsYou: 0 });
      // The first send waits out the minute after start.
      await vi.advanceTimersByTimeAsync(60_000);
      expect(events()).toEqual(["start 1/0"]);
      await vi.advanceTimersByTimeAsync(cardAgeMs);
      restart();
      sent.length = 0;
      sentTo.length = 0;
      counts = { running: 2, needsYou: 1 };
      notifier.start();
    }

    it("updates the card the last process started, with no alert-bearing end and start", async () => {
      await startCardAndRestart(60 * 60_000);
      await vi.advanceTimersByTimeAsync(60_000);
      expect(events()).toEqual(["update 2/1"]);
      // The card still gets its 8-hour restart, counted from its real start.
      await vi.advanceTimersByTimeAsync(7 * 60 * 60_000 - 60_000 - 1);
      expect(events()).toEqual(["update 2/1"]);
      await vi.advanceTimersByTimeAsync(1);
      expect(events()).toEqual(["update 2/1", "end 0/0", "start 2/1"]);
    });

    it("keeps a restored card's real start when work resumes and the app comes and goes", async () => {
      await startCardAndRestart(60 * 60_000);
      // Sessions resume: the new process sees the counts rise from zero, which is not a card
      // starting. The app opens and leaves again.
      notifier.countsChanged();
      present = true;
      notifier.presenceChanged(phone.deviceId);
      await vi.advanceTimersByTimeAsync(10 * 60_000);
      leave();
      // The card started 1 hour before the restart: its 8 hours run out 7 hours after it.
      await vi.advanceTimersByTimeAsync(7 * 60 * 60_000 - 10 * 60_000 - 1);
      expect(events()).toEqual([]);
      await vi.advanceTimersByTimeAsync(1);
      expect(events()).toEqual(["end 0/0", "start 2/1"]);
    });

    it("keeps a device that was not restored from restarting at once when it leaves", async () => {
      // The iPad's app drives its card across the restart; the phone has a restored card.
      registrations = [phone, ipad];
      presentIds.add(ipad.deviceId);
      await startCardAndRestart(60 * 60_000);
      notifier.countsChanged();
      await vi.advanceTimersByTimeAsync(10 * 60_000);
      presentIds.delete(ipad.deviceId);
      notifier.presenceChanged(ipad.deviceId);
      // The iPad's card is dated by the restored card's start, 1 hour before the restart, so
      // its 8 hours run out 7 hours after it; so do the phone's, from its real start.
      await vi.advanceTimersByTimeAsync(7 * 60 * 60_000 - 10 * 60_000 - 1);
      expect(eventsFor(ipad)).toEqual([]);
      expect(eventsFor(phone)).toEqual(["update 2/1"]);
      await vi.advanceTimersByTimeAsync(1);
      expect(eventsFor(ipad)).toEqual(["end 0/0", "start 2/1"]);
      expect(eventsFor(phone)).toEqual(["update 2/1", "end 0/0", "start 2/1"]);
    });

    it("ends a card the last process started when the server is stopped before the reconcile", async () => {
      await startCardAndRestart(60 * 60_000);
      await notifier.endLiveCards(3_000);
      expect(events()).toEqual(["end 0/0"]);
      expect([...saved.keys()]).toEqual([]);
    });

    it("ends the card when nothing runs after the restart", async () => {
      await startCardAndRestart(60 * 60_000);
      counts = { running: 0, needsYou: 0 };
      await vi.advanceTimersByTimeAsync(60_000);
      expect(events()).toEqual(["end 0/0"]);
    });

    it("ends and restarts a card that is near 8 hours old", async () => {
      await startCardAndRestart(LIVE_ACTIVITY_RESTORE_MAX_AGE_MS);
      await vi.advanceTimersByTimeAsync(60_000);
      expect(events()).toEqual(["end 0/0", "start 2/1"]);
    });

    it("saves the card soon after it starts, so a crash keeps it", async () => {
      leave();
      change({ running: 1, needsYou: 0 });
      await vi.advanceTimersByTimeAsync(0);
      notifier.start();
      await vi.advanceTimersByTimeAsync(2_000);
      expect([...saved.keys()]).toEqual([phone.deviceId]);
      // Not a card: nothing saved once the card ended.
      change({ running: 0, needsYou: 0 });
      await vi.advanceTimersByTimeAsync(60_000 + 2_000);
      expect([...saved.keys()]).toEqual([]);
    });

    it("keeps the saved card through a second restart before the reconcile", async () => {
      await startCardAndRestart(60 * 60_000);
      // A second restart a moment later, before the reconcile.
      await vi.advanceTimersByTimeAsync(5_000);
      restart();
      sent.length = 0;
      sentTo.length = 0;
      notifier.start();
      await vi.advanceTimersByTimeAsync(60_000);
      expect(events()).toEqual(["update 2/1"]);
    });
  });

  describe("ending cards when the server stops", () => {
    async function liveCard(): Promise<void> {
      leave();
      change({ running: 2, needsYou: 0 });
      await vi.advanceTimersByTimeAsync(0);
      expect(events()).toEqual(["start 2/0"]);
    }

    it("ends a live card once, and leaves nothing for a restart to find", async () => {
      await liveCard();
      await notifier.endLiveCards(3_000);
      expect(events()).toEqual(["start 2/0", "end 0/0"]);
      expect([...saved.keys()]).toEqual([]);
      // Stopped: no timer sends anything more.
      change({ running: 0, needsYou: 0 });
      await vi.advanceTimersByTimeAsync(60 * 60_000);
      expect(sent).toHaveLength(2);
    });

    it("ends the card of a device that left with the app's card showing counts", async () => {
      present = true;
      notifier.presenceChanged(phone.deviceId);
      change({ running: 1, needsYou: 0 });
      await vi.advanceTimersByTimeAsync(5 * 60_000);
      leave();
      await notifier.endLiveCards(3_000);
      expect(events()).toEqual(["end 0/0"]);
    });

    it("leaves alone a device with no card, one the app drives, and one it knows nothing about", async () => {
      // No card.
      await notifier.endLiveCards(3_000);
      expect(sent).toEqual([]);
      // Unknown, as after a restart.
      notifier = build();
      notifier.start();
      await notifier.endLiveCards(3_000);
      expect(sent).toEqual([]);
      // The app drives the card.
      notifier = build();
      present = true;
      notifier.presenceChanged(phone.deviceId);
      change({ running: 1, needsYou: 0 });
      await notifier.endLiveCards(3_000);
      expect(sent).toEqual([]);
    });

    it("gives up after the time it was given when the relay does not answer", async () => {
      await liveCard();
      hang = true;
      let done = false;
      void notifier.endLiveCards(3_000).then(() => {
        done = true;
      });
      await vi.advanceTimersByTimeAsync(2_999);
      expect(done).toBe(false);
      await vi.advanceTimersByTimeAsync(1);
      expect(done).toBe(true);
    });

    it("sends the end of a revoked device's card before its registration goes", async () => {
      await liveCard();
      const ended = notifier.endCardOf(phone.deviceId, 3_000);
      // The send started now, while the registration is still there.
      expect(events()).toEqual(["start 2/0", "end 0/0"]);
      registrations = [];
      await ended;
    });

    it("is quiet for a revoked device without a card, and bounded when the relay hangs", async () => {
      await notifier.endCardOf(phone.deviceId, 3_000);
      expect(sent).toEqual([]);
      await liveCard();
      hang = true;
      let done = false;
      void notifier.endCardOf(phone.deviceId, 3_000).then(() => {
        done = true;
      });
      await vi.advanceTimersByTimeAsync(3_000);
      expect(done).toBe(true);
    });
  });
});

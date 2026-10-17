import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  LIVE_ACTIVITY_MAX_AGE_MS,
  LIVE_ACTIVITY_MISSING_TOKEN_RETRIES,
  LiveActivityNotifier,
  liveActivityCounts,
  type LiveActivityCounts,
} from "../src/live-activity-notifier.js";
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
};

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
  it("counts top-level running and waiting sessions; subagents never count", () => {
    expect(
      liveActivityCounts([
        session("a", "working"),
        session("b", "working"),
        session("c", "blocked"),
        session("d", "done"),
        session("e", "idle"),
        session("child-1", "working", "a"),
        session("child-2", "blocked", "a"),
      ]),
    ).toEqual({ running: 2, needsYou: 1 });
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
  let answer: (push: LiveActivityPush) => LiveActivitySendResult;
  let notifier: LiveActivityNotifier;

  beforeEach(() => {
    vi.useFakeTimers({ now: Date.parse("2026-10-17T09:00:00Z") });
    counts = { running: 0, needsYou: 0 };
    present = false;
    registrations = [phone];
    sent = [];
    answer = () => ({ status: "delivered" });
    const push = {
      registrations: () => registrations,
      sendLiveActivity: async (_registration: PushRegistration, payload: LiveActivityPush) => {
        sent.push(payload);
        return answer(payload);
      },
    } as unknown as Pick<PushSender, "registrations" | "sendLiveActivity">;
    notifier = new LiveActivityNotifier(push, {
      isDevicePresent: () => present,
      counts: () => counts,
    });
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

  it("leaves a card it cannot reach alone until the counts reach zero", async () => {
    // The person dismissed the app's card, or the phone ended it: the relay holds no token.
    present = true;
    notifier.presenceChanged(phone.deviceId);
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    leave();
    answer = () => ({ status: "no_activity" });
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60 * 60_000);
    const updates = Array.from(
      { length: LIVE_ACTIVITY_MISSING_TOKEN_RETRIES + 1 },
      () => "update 2/0",
    );
    expect(events()).toEqual(updates);
    change({ running: 3, needsYou: 1 });
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS);
    expect(events()).toEqual(updates);

    // Zero ends the dismissal at the relay; the next work gets a card.
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(0);
    answer = () => ({ status: "delivered" });
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual([...updates, "end 0/0", "start 1/0"]);
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

  it("does not retry a start the relay refused until the counts change, and ends at zero", async () => {
    answer = () => ({ status: "no_activity" });
    leave();
    change({ running: 1, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(events()).toEqual(["start 1/0"]);
    change({ running: 2, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "start 2/0"]);
    // A dismissed card's refusal lasts until an end says the counts reached zero.
    change({ running: 0, needsYou: 0 });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["start 1/0", "start 2/0", "end 0/0"]);
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(sent).toHaveLength(3);
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

  it("restarts a card left from before a restart while work goes on: it may be near 8 hours", async () => {
    counts = { running: 2, needsYou: 1 };
    notifier.start();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(events()).toEqual(["end 0/0", "start 2/1"]);
    await vi.advanceTimersByTimeAsync(LIVE_ACTIVITY_MAX_AGE_MS - 1);
    expect(sent).toHaveLength(2);
  });
});

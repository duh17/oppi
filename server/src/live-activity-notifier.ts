import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { PushSender } from "./push/push-sender.js";
import type { LiveActivityPush } from "./push/relay-client.js";
import type { PushRegistration, Session } from "./types.js";

const log = createLogger({ base: { component: "live_activity" } });

/** What the card shows. Top-level sessions only. */
export interface LiveActivityCounts {
  running: number;
  needsYou: number;
}

/** The relay's bound on each count; more shows as this. */
export const LIVE_ACTIVITY_MAX_COUNT = 99;
/** At most one Live Activity push a minute per device; the latest counts win. */
export const LIVE_ACTIVITY_MIN_INTERVAL_MS = 60_000;
/** Apple ends a Live Activity after 8 hours; the server starts a new one if work goes on. */
export const LIVE_ACTIVITY_MAX_AGE_MS = 8 * 60 * 60 * 1000;
/**
 * A suspended app can hold its streams open for about 90 seconds and miss what changed in
 * that time. A change this close before a device leaves gets pushed when it does.
 */
const LEAVE_GRACE_MS = 120_000;
/** After a failed send (relay or network down), try once more after this. */
const RETRY_AFTER_FAILURE_MS = 5 * 60_000;
/**
 * An update that finds no update token at the relay is tried again, once a minute, this many
 * times: the phone may still be reporting a new card's token. After that the card is out of
 * reach until the counts reach zero.
 */
export const LIVE_ACTIVITY_MISSING_TOKEN_RETRIES = 5;

/**
 * Running and waiting top-level sessions. Subagents (sessions with a parent) never count: the
 * card answers "what is on my plate", and a lead already counts while its children work.
 */
export function liveActivityCounts(sessions: Iterable<Session>): LiveActivityCounts {
  let running = 0;
  let needsYou = 0;
  for (const session of sessions) {
    if (session.launch?.parentSessionId) continue;
    const state = session.programStatus?.state;
    if (state === "working") running += 1;
    else if (state === "blocked") needsYou += 1;
  }
  return {
    running: Math.min(running, LIVE_ACTIVITY_MAX_COUNT),
    needsYou: Math.min(needsYou, LIVE_ACTIVITY_MAX_COUNT),
  };
}

function sameCounts(a: LiveActivityCounts | undefined, b: LiveActivityCounts): boolean {
  return a !== undefined && a.running === b.running && a.needsYou === b.needsYou;
}

function isEmpty(counts: LiveActivityCounts): boolean {
  return counts.running + counts.needsYou === 0;
}

const EMPTY: LiveActivityCounts = { running: 0, needsYou: 0 };

interface DeviceState {
  /**
   * `none`: no card, as far as this server knows. `unknown`: the phone drove the card while
   * present, or the server restarted. `live`: this server started the card. `lost`: the relay
   * holds no update token for the card (the person dismissed it, or the phone ended it), so
   * this server starts no card until the counts reach zero.
   */
  activity: "none" | "unknown" | "live" | "lost";
  /**
   * `live`: when this server started the card. `unknown`: the earliest the card can have
   * started, so its 8-hour restart comes no later than Apple's end.
   */
  startedAt?: number;
  /** Counts the card shows (or the relay last refused to start for); undefined: not known. */
  shown?: LiveActivityCounts;
  /** Updates in a row that found no update token. */
  missedUpdates: number;
  /** Unix seconds of the last event sent; each event goes out with a later one. */
  lastTimestamp: number;
  lastSentAt: number;
  /** No send before this: a failure or a relay `429`. */
  retryAt: number;
  timer?: ReturnType<typeof setTimeout>;
  sending: boolean;
  /** Something changed while a send was in flight. */
  dirty: boolean;
}

export interface LiveActivityNotifierOptions {
  /** True while this paired device holds a live stream: the app drives its card itself. */
  isDevicePresent: (deviceId: string) => boolean;
  /** Counts across the server's live sessions now. */
  counts: () => LiveActivityCounts;
  now?: () => number;
}

/**
 * Keeps each away phone's Live Activity in step with this server's counts through the push
 * relay (protocol/push/spec.md "Live Activity").
 *
 * Only devices whose registration accepts Live Activities, and only while they hold no live
 * stream: a present app updates its own card, so the server never drives the same activity.
 * A send goes out only when the counts the card shows differ from the current ones, at most
 * once a minute per device; the latest counts win. Nothing running or waiting ends the card,
 * and work starting while there is none starts one. A card is ended and started again before
 * Apple's 8 hours run out while work goes on.
 *
 * A start goes out only when this server knows there is no card: it ended the last one
 * (the relay delivered the `end`) or the counts reached zero. An update the relay cannot
 * deliver means the relay holds no token for the card: the phone may still be reporting a new
 * card's token, so the update is tried again a few times; after that the card is out of
 * reach (dismissed, or ended on the phone) and nothing more goes out until the counts reach
 * zero. Starting a card then could put a second card next to one the person can see, or
 * bring back one they dismissed.
 */
export class LiveActivityNotifier {
  private readonly devices = new Map<string, DeviceState>();
  private readonly now: () => number;
  /** The server starts with no live sessions. */
  private lastCounts: LiveActivityCounts = EMPTY;
  private lastCountsChangeAt = Number.NEGATIVE_INFINITY;
  /**
   * When the counts last went from zero to some. Both the app and this server end the card at
   * zero, so no card shown now started before this. Undefined until seen.
   */
  private countsRoseAt: number | undefined;
  private stopped = false;

  constructor(
    private readonly push: Pick<PushSender, "registrations" | "sendLiveActivity">,
    private readonly options: LiveActivityNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  /**
   * After a restart the server does not know what any card shows or when it started.
   * Reconcile each device once, a minute in so sessions settle first: a card left from before
   * the restart ends when nothing runs, and is restarted otherwise, since it may be near
   * Apple's 8 hours. The relay answers `no_activity`, at no quota cost, when there is no card.
   */
  start(): void {
    const now = this.now();
    for (const registration of this.registrations()) {
      const device = this.device(registration.deviceId);
      device.lastSentAt = now;
      this.schedule(registration.deviceId);
    }
  }

  stop(): void {
    this.stopped = true;
    for (const device of this.devices.values()) {
      if (device.timer) clearTimeout(device.timer);
      device.timer = undefined;
    }
  }

  /** A session's program status changed; the counts may have too. */
  countsChanged(): void {
    const counts = this.options.counts();
    const previous = this.lastCounts;
    if (!sameCounts(previous, counts)) {
      if (isEmpty(previous)) this.countsRoseAt = this.now();
      this.lastCounts = counts;
      this.lastCountsChangeAt = this.now();
    }
    const deviceIds = new Set(this.registrations().map((entry) => entry.deviceId));
    for (const deviceId of this.devices.keys()) {
      if (!deviceIds.has(deviceId)) this.forget(deviceId);
    }
    for (const deviceId of deviceIds) this.schedule(deviceId);
  }

  /** A device opened its first or closed its last live stream. */
  presenceChanged(deviceId: string): void {
    if (!this.registrations().some((entry) => entry.deviceId === deviceId)) return;
    const device = this.device(deviceId);
    if (this.options.isDevicePresent(deviceId)) {
      this.cancel(device);
      return;
    }
    // The app drove the card until now: it ends it at zero and shows the counts otherwise,
    // unless they changed while it may already have been suspended.
    const counts = this.options.counts();
    const recentChange = this.now() - this.lastCountsChangeAt < LEAVE_GRACE_MS;
    device.missedUpdates = 0;
    if (isEmpty(counts) && !recentChange) {
      device.activity = "none";
      device.shown = EMPTY;
      device.startedAt = undefined;
    } else {
      device.startedAt = this.earliestCardStart(device);
      device.activity = "unknown";
      device.shown = recentChange ? undefined : counts;
    }
    this.schedule(deviceId);
  }

  private registrations(): PushRegistration[] {
    return this.push.registrations().filter((entry) => entry.liveActivity === true);
  }

  private device(deviceId: string): DeviceState {
    let device = this.devices.get(deviceId);
    if (!device) {
      device = {
        activity: "unknown",
        missedUpdates: 0,
        lastTimestamp: 0,
        lastSentAt: Number.NEGATIVE_INFINITY,
        retryAt: 0,
        sending: false,
        dirty: false,
      };
      device.startedAt = this.earliestCardStart(device);
      this.devices.set(deviceId, device);
    }
    return device;
  }

  /**
   * The earliest a card the phone shows now can have started: not before the counts last rose
   * from zero, nor before this server last started one (a newer card replaces it), nor more
   * than 8 hours ago (Apple would have ended it). Restarting by this keeps a card up even when
   * the app started it, at the cost of an early restart now and then.
   */
  private earliestCardStart(device: DeviceState): number {
    return Math.max(
      this.countsRoseAt ?? Number.NEGATIVE_INFINITY,
      device.startedAt ?? Number.NEGATIVE_INFINITY,
      this.now() - LIVE_ACTIVITY_MAX_AGE_MS,
    );
  }

  private forget(deviceId: string): void {
    const device = this.devices.get(deviceId);
    if (device) this.cancel(device);
    this.devices.delete(deviceId);
  }

  private cancel(device: DeviceState): void {
    if (device.timer) clearTimeout(device.timer);
    device.timer = undefined;
  }

  /** The card may be at Apple's 8 hours: end it and start a new one. */
  private dueForRestart(device: DeviceState, now: number): boolean {
    return (
      (device.activity === "live" || device.activity === "unknown") &&
      device.startedAt !== undefined &&
      now - device.startedAt >= LIVE_ACTIVITY_MAX_AGE_MS
    );
  }

  /** Whether the card should change now, given what it shows. */
  private needsSend(device: DeviceState, counts: LiveActivityCounts, now: number): boolean {
    switch (device.activity) {
      case "none":
        // At zero after a refused start: an `end` ends a dismissal at the relay.
        return isEmpty(counts)
          ? !sameCounts(device.shown, EMPTY)
          : !sameCounts(device.shown, counts);
      case "lost":
        return isEmpty(counts);
      default:
        return (
          isEmpty(counts) || this.dueForRestart(device, now) || !sameCounts(device.shown, counts)
        );
    }
  }

  /** Arm the device's one timer for its next send, or for its card's 8-hour restart. */
  private schedule(deviceId: string): void {
    if (this.stopped) return;
    const device = this.device(deviceId);
    if (device.sending) {
      device.dirty = true;
      return;
    }
    this.cancel(device);
    if (this.options.isDevicePresent(deviceId)) return;
    const now = this.now();
    let at: number | undefined;
    if (this.needsSend(device, this.options.counts(), now)) {
      at = Math.max(now, device.lastSentAt + LIVE_ACTIVITY_MIN_INTERVAL_MS, device.retryAt);
    } else if (
      (device.activity === "live" || device.activity === "unknown") &&
      device.startedAt !== undefined
    ) {
      at = device.startedAt + LIVE_ACTIVITY_MAX_AGE_MS;
    }
    if (at === undefined) return;
    device.timer = setTimeout(() => void this.flush(deviceId), Math.max(0, at - now));
    device.timer.unref?.();
  }

  private async flush(deviceId: string): Promise<void> {
    const device = this.devices.get(deviceId);
    if (!device || this.stopped) return;
    device.timer = undefined;
    const registration = this.registrations().find((entry) => entry.deviceId === deviceId);
    if (!registration) {
      this.forget(deviceId);
      return;
    }
    if (this.options.isDevicePresent(deviceId)) return;
    const counts = this.options.counts();
    if (!this.needsSend(device, counts, this.now())) {
      this.schedule(deviceId);
      return;
    }
    device.sending = true;
    device.dirty = false;
    try {
      await this.drive(registration, device, counts);
    } catch (err: unknown) {
      log.warn("live_activity.send_failed", { error: safeErrorMessage(err) });
    } finally {
      device.sending = false;
      device.lastSentAt = this.now();
    }
    if (this.devices.get(deviceId) === device) this.schedule(deviceId);
  }

  /** One flush: the sends that bring the card to `counts`. */
  private async drive(
    registration: PushRegistration,
    device: DeviceState,
    counts: LiveActivityCounts,
  ): Promise<void> {
    if (isEmpty(counts)) {
      // Delivered, or no card: either way there is none now.
      if ((await this.send(registration, device, "end", EMPTY)) !== "failed") {
        this.settle(device, "none", EMPTY);
      }
      return;
    }
    if (device.activity === "none") {
      await this.begin(registration, device, counts);
      return;
    }
    if (this.dueForRestart(device, this.now())) {
      const ended = await this.send(registration, device, "end", EMPTY);
      if (ended === "delivered") {
        this.settle(device, "none", EMPTY);
        await this.begin(registration, device, counts);
      } else if (ended === "no_activity") {
        // No token to end: the card is out of reach. Starting one could sit next to it.
        this.settle(device, "lost", undefined);
      }
      return;
    }
    const result = await this.send(registration, device, "update", counts);
    if (result === "delivered") {
      device.shown = counts;
      device.missedUpdates = 0;
    } else if (result === "no_activity") {
      device.missedUpdates += 1;
      if (device.missedUpdates > LIVE_ACTIVITY_MISSING_TOKEN_RETRIES) {
        log.info("live_activity.card_out_of_reach");
        this.settle(device, "lost", undefined);
      }
    }
  }

  private settle(
    device: DeviceState,
    activity: "none" | "lost",
    shown: LiveActivityCounts | undefined,
  ): void {
    device.activity = activity;
    device.startedAt = undefined;
    device.shown = shown;
    device.missedUpdates = 0;
  }

  private async begin(
    registration: PushRegistration,
    device: DeviceState,
    counts: LiveActivityCounts,
  ): Promise<void> {
    const result = await this.send(registration, device, "start", counts);
    if (result === "delivered") {
      device.activity = "live";
      device.startedAt = this.now();
      device.shown = counts;
      device.missedUpdates = 0;
    } else if (result === "no_activity") {
      // No start token at the relay (the phone turned Live Activities off), or the person
      // dismissed the card. Try again when the counts change.
      this.settle(device, "none", counts);
    }
  }

  /**
   * Send one event. Failures set the device's retry time. Each event carries a later
   * timestamp than the device's last one, so a start right after an end is the newer event:
   * Apple ignores an event no newer than the one before.
   */
  private async send(
    registration: PushRegistration,
    device: DeviceState,
    event: LiveActivityPush["event"],
    counts: LiveActivityCounts,
  ): Promise<"delivered" | "no_activity" | "failed"> {
    const timestamp = Math.max(Math.floor(this.now() / 1000), device.lastTimestamp + 1);
    device.lastTimestamp = timestamp;
    const result = await this.push.sendLiveActivity(registration, {
      event,
      running: counts.running,
      needsYou: counts.needsYou,
      timestamp,
    });
    switch (result?.status) {
      case "delivered":
        return "delivered";
      case "no_activity":
        return "no_activity";
      case "rejected":
        device.retryAt =
          this.now() +
          (result.retryAfterSeconds !== undefined
            ? result.retryAfterSeconds * 1000
            : RETRY_AFTER_FAILURE_MS);
        return "failed";
      case "unavailable":
      case "failed":
        device.retryAt = this.now() + RETRY_AFTER_FAILURE_MS;
        return "failed";
      case "throttled":
        // Out of today's budget: the next change after the budget resets tries again.
        device.retryAt = this.now() + RETRY_AFTER_FAILURE_MS;
        return "failed";
      default:
        // Gone or no longer current: the registration is pruned or replaced.
        return "failed";
    }
  }
}

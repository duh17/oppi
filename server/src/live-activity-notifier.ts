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
   * present, or the server restarted. `live`: this server started the card at `startedAt`.
   */
  activity: "none" | "unknown" | "live";
  startedAt?: number;
  /** Counts the card shows (or the relay last refused to start for); undefined: not known. */
  shown?: LiveActivityCounts;
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
 * work starting while there is none starts one, and a card Apple ended after 8 hours is ended
 * and started again while work goes on. An update the relay cannot deliver (no live activity:
 * the phone ended or dismissed it, or Apple's 8 hours ran out) is followed by an end, which
 * takes an expired card off the Lock Screen, and a start.
 */
export class LiveActivityNotifier {
  private readonly devices = new Map<string, DeviceState>();
  private readonly now: () => number;
  private lastCounts: LiveActivityCounts = EMPTY;
  private lastCountsChangeAt = Number.NEGATIVE_INFINITY;
  private stopped = false;

  constructor(
    private readonly push: Pick<PushSender, "registrations" | "sendLiveActivity">,
    private readonly options: LiveActivityNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  /**
   * After a restart the server does not know what any card shows. Reconcile each device once,
   * a minute in so sessions settle first: a card left from before the restart ends when
   * nothing runs. The relay answers `no_activity`, at no quota cost, when there is no card.
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
    if (!sameCounts(this.lastCounts, counts)) {
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
    device.startedAt = undefined;
    if (isEmpty(counts) && !recentChange) {
      device.activity = "none";
      device.shown = EMPTY;
    } else {
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
        lastSentAt: Number.NEGATIVE_INFINITY,
        retryAt: 0,
        sending: false,
        dirty: false,
      };
      this.devices.set(deviceId, device);
    }
    return device;
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

  /** Whether the card should change now, given what it shows. */
  private needsSend(device: DeviceState, counts: LiveActivityCounts, now: number): boolean {
    if (device.activity === "none") return !isEmpty(counts) && !sameCounts(device.shown, counts);
    if (isEmpty(counts)) return true;
    if (
      device.activity === "live" &&
      device.startedAt !== undefined &&
      now - device.startedAt >= LIVE_ACTIVITY_MAX_AGE_MS
    ) {
      return true;
    }
    return !sameCounts(device.shown, counts);
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
    } else if (device.activity === "live" && device.startedAt !== undefined) {
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
      await this.end(registration, device);
      return;
    }
    if (device.activity === "none") {
      await this.begin(registration, device, counts);
      return;
    }
    if (
      device.activity === "live" &&
      device.startedAt !== undefined &&
      this.now() - device.startedAt >= LIVE_ACTIVITY_MAX_AGE_MS
    ) {
      if (await this.end(registration, device)) await this.begin(registration, device, counts);
      return;
    }
    const result = await this.send(registration, device, "update", counts);
    if (result === "delivered") {
      device.shown = counts;
    } else if (result === "no_activity") {
      if (await this.end(registration, device)) await this.begin(registration, device, counts);
    }
  }

  /** End the card. True once there is none (ended, or the relay had none). */
  private async end(registration: PushRegistration, device: DeviceState): Promise<boolean> {
    const result = await this.send(registration, device, "end", EMPTY);
    if (result !== "delivered" && result !== "no_activity") return false;
    device.activity = "none";
    device.startedAt = undefined;
    device.shown = EMPTY;
    return true;
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
    } else if (result === "no_activity") {
      // No start token at the relay: the phone turned Live Activities off. Try again when
      // the counts change.
      device.activity = "none";
      device.shown = counts;
    }
  }

  /** Send one event. Failures set the device's retry time. */
  private async send(
    registration: PushRegistration,
    device: DeviceState,
    event: LiveActivityPush["event"],
    counts: LiveActivityCounts,
  ): Promise<"delivered" | "no_activity" | "failed"> {
    const now = this.now();
    const result = await this.push.sendLiveActivity(registration, {
      event,
      running: counts.running,
      needsYou: counts.needsYou,
      timestamp: Math.floor(now / 1000),
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

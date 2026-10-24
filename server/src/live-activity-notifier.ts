import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { PushSender } from "./push/push-sender.js";
import type { LiveActivityPush } from "./push/relay-client.js";
import type { LiveActivityStateStore, PersistedCard } from "./live-activity-state-store.js";
import type { PushRegistration, Session } from "./types.js";

const log = createLogger({ base: { component: "live_activity" } });

/** What the card shows: counts of threads (a top-level session with its subagents), not sessions. */
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
 * A restarted server keeps updating a card it remembers while it is younger than this, and
 * ends and restarts it only when it is nearer Apple's 8 hours: the margin covers a card that
 * started earlier than the server noted.
 */
export const LIVE_ACTIVITY_RESTORE_MAX_AGE_MS = 7.5 * 60 * 60 * 1000;
/** Cards are written to disk this long after the last change, so one burst is one write. */
const PERSIST_DEBOUNCE_MS = 2_000;
/**
 * An update that finds no update token at the relay is tried again, once a minute, this many
 * times: the phone may still be reporting a new card's token. After that the card is out of
 * reach until the counts reach zero.
 */
export const LIVE_ACTIVITY_MISSING_TOKEN_RETRIES = 5;

/**
 * Threads that need you and threads that run. The card answers "what is on my plate", and a
 * subagent is part of its lead's thread, not another item on it.
 */
export function liveActivityCounts(sessions: Iterable<Session>): LiveActivityCounts {
  // A thread needs you while any session in it is blocked, else runs while any is working,
  // so a lead idling while its subagents work still counts as running, once.
  const byId = new Map<string, Session>();
  for (const session of sessions) byId.set(session.id, session);
  const threads = new Map<string, "working" | "blocked">();
  for (const session of byId.values()) {
    const state = session.programStatus?.state;
    if (state !== "working" && state !== "blocked") continue;
    const root = threadRoot(session, byId);
    if (threads.get(root) !== "blocked") threads.set(root, state);
  }
  let running = 0;
  let needsYou = 0;
  for (const state of threads.values()) {
    if (state === "blocked") needsYou += 1;
    else running += 1;
  }
  return {
    running: Math.min(running, LIVE_ACTIVITY_MAX_COUNT),
    needsYou: Math.min(needsYou, LIVE_ACTIVITY_MAX_COUNT),
  };
}

/** The thread's top-level session id, or the topmost ancestor id when that session is gone. */
function threadRoot(session: Session, byId: ReadonlyMap<string, Session>): string {
  let current = session;
  const seen = new Set<string>([current.id]);
  let parentId = current.launch?.parentSessionId;
  while (parentId) {
    const parent = byId.get(parentId);
    if (!parent || seen.has(parentId)) return parentId;
    seen.add(parentId);
    current = parent;
    parentId = current.launch?.parentSessionId;
  }
  return current.id;
}

/** Resolves when `work` does or after `ms`, whichever is first; `work` keeps running. */
async function within(work: Promise<unknown>, ms: number): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  await Promise.race([
    work,
    new Promise<void>((resolve) => {
      timer = setTimeout(resolve, ms);
    }),
  ]);
  clearTimeout(timer);
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
   * holds no update token for the card and refused a start (the person dismissed it, or the
   * phone ended it), so this server starts no card until the counts reach zero.
   */
  activity: "none" | "unknown" | "live" | "lost";
  /**
   * `live`: when this server started the card. `unknown`: the earliest the card can have
   * started, so its 8-hour restart comes no later than Apple's end.
   */
  startedAt?: number;
  /**
   * Counts the card shows: `EMPTY` with no card, the counts last delivered otherwise.
   * Undefined: not known (the card is lost, or a change may have reached it unseen).
   */
  shown?: LiveActivityCounts;
  /** Updates in a row that found no update token. */
  missedUpdates: number;
  lastSentAt: number;
  /**
   * No start or update before this: a failure or a relay `429`. Kept apart from `endRetryAt`:
   * the relay's daily limit that stops an update leaves room for the end, so a long wait on
   * an update must not hold the card's end back.
   */
  retryAt: number;
  /** No end before this: a failure or a relay `429` of an end. */
  endRetryAt: number;
  timer?: ReturnType<typeof setTimeout>;
  sending: boolean;
}

export interface LiveActivityNotifierOptions {
  /** True while this paired device holds a live stream: the app drives its card itself. */
  isDevicePresent: (deviceId: string) => boolean;
  /** Counts across the server's live sessions now. */
  counts: () => LiveActivityCounts;
  /** Where the cards survive a restart; without it a restart forgets them. */
  state?: LiveActivityStateStore;
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
 * card's token, so the update is tried again a few times. After that there is no card the
 * server can reach: work that began while the app was backgrounded but connected has none,
 * since the app cannot start one then. The server tries one `start`. The relay refuses it for
 * a dismissed card and for a server the phone did not list; then the card is lost and nothing
 * more goes out until the counts reach zero. A start the relay accepts cannot double a card
 * the person sees: the relay holds no token for that card, and the app replaces an older card
 * of the same slot with the newer one. A start after an `end` the relay could not deliver is
 * never tried, as the card may still be on the Lock Screen.
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
  /**
   * Whether a rise from zero is work starting. False after `start` restored a card: the new
   * process sees the counts rise from its own empty start as sessions resume, which says
   * nothing about the restored cards, so it must not re-date them. `start` seeds
   * `countsRoseAt` with the earliest restored start instead, which also dates the card of a
   * device that was not restored. True again once the counts have fallen to zero here, as the
   * cards then ended.
   */
  private countsRiseTrusted = true;
  private stopped = false;
  /** False until `start` has read the saved cards; nothing is written before that. */
  private stateLoaded = false;
  private persistTimer: ReturnType<typeof setTimeout> | undefined;
  private lastPersisted: string | undefined;

  constructor(
    private readonly push: Pick<PushSender, "registrations" | "sendLiveActivity">,
    private readonly options: LiveActivityNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  /**
   * After a restart the server does not know what any card shows. Reconcile each device once,
   * a minute in so sessions settle first: a card left from before the restart ends when
   * nothing runs, and is updated otherwise. The relay answers `no_activity`, at no quota cost,
   * when there is no card.
   *
   * A card saved by the last process keeps its start time while it is under 7.5 hours old, so
   * work that goes on gets an update, not an end and a start (whose alert lights the screen).
   * With nothing saved, or a card that old, the card may be near Apple's 8 hours: it is ended
   * and, while work goes on, restarted.
   */
  start(): void {
    const now = this.now();
    const saved = this.options.state?.load() ?? new Map<string, PersistedCard>();
    this.stateLoaded = true;
    const restoredStarts: number[] = [];
    for (const registration of this.registrations()) {
      const device = this.device(registration.deviceId);
      const card = saved.get(registration.deviceId);
      if (
        card &&
        device.activity === "unknown" &&
        card.startedAt <= now &&
        now - card.startedAt < LIVE_ACTIVITY_RESTORE_MAX_AGE_MS
      ) {
        device.startedAt = card.startedAt;
        device.activity = card.activity;
        restoredStarts.push(card.startedAt);
      }
      device.lastSentAt = now;
      this.schedule(registration.deviceId);
    }
    if (restoredStarts.length > 0) {
      this.countsRiseTrusted = false;
      this.countsRoseAt = Math.min(this.countsRoseAt ?? Infinity, ...restoredStarts);
    }
    this.persistSoon();
  }

  /** Cancel every timer and write the cards down. Sends nothing; see `endLiveCards`. */
  stop(): void {
    this.stopped = true;
    for (const device of this.devices.values()) {
      if (device.timer) clearTimeout(device.timer);
      device.timer = undefined;
    }
    this.persistNow();
  }

  /**
   * End each card this server may have up, once, within `timeoutMs` in all: for a server that
   * stops for good, which would leave the card showing stale counts. Skips a device the app
   * drives (present) and one with a send in flight. Stops the notifier first, so no timer
   * races these sends. Never throws.
   */
  async endLiveCards(timeoutMs: number): Promise<void> {
    this.stop();
    const registrations = this.registrations();
    const ends: Promise<void>[] = [];
    for (const [deviceId, device] of this.devices) {
      const registration = registrations.find((entry) => entry.deviceId === deviceId);
      if (registration && !this.options.isDevicePresent(deviceId) && this.cardMayBeUp(device)) {
        ends.push(this.endCard(registration, device));
      }
    }
    await within(Promise.all(ends), timeoutMs);
    this.persistNow();
  }

  /**
   * End one device's card, best effort, within `timeoutMs`: for a device that is being revoked,
   * whose registration is about to go. Call it before the registration is removed, since a
   * send checks the registration when it starts. Resolves when the end is done or the time is
   * up; never throws. The app is not asked whether it drives the card: the device is leaving.
   */
  async endCardOf(deviceId: string, timeoutMs: number): Promise<void> {
    const registration = this.registrations().find((entry) => entry.deviceId === deviceId);
    const device = this.devices.get(deviceId);
    if (!registration || !device || !this.cardMayBeUp(device)) return;
    await within(this.endCard(registration, device), timeoutMs);
  }

  /** Whether this server may have a card up on the device that still shows counts. */
  private cardMayBeUp(device: DeviceState): boolean {
    if (device.sending) return false;
    if (device.activity === "live") return true;
    return device.activity === "unknown" && device.shown !== undefined && !isEmpty(device.shown);
  }

  /** One `end`, outside the flush cycle. A card the relay has no token for is gone as well. */
  private async endCard(registration: PushRegistration, device: DeviceState): Promise<void> {
    device.sending = true;
    try {
      if ((await this.send(registration, device, "end", EMPTY)) !== "failed") {
        this.settle(device, "none", EMPTY);
      }
    } catch (err: unknown) {
      log.warn("live_activity.send_failed", { error: safeErrorMessage(err) });
    } finally {
      device.sending = false;
    }
    this.persistSoon();
  }

  /** Write the cards this server believes are up, soon; a burst of changes is one write. */
  private persistSoon(): void {
    if (!this.stateLoaded || !this.options.state || this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = undefined;
      this.persistNow();
    }, PERSIST_DEBOUNCE_MS);
    this.persistTimer.unref?.();
  }

  private persistNow(): void {
    if (this.persistTimer) clearTimeout(this.persistTimer);
    this.persistTimer = undefined;
    const store = this.options.state;
    if (!this.stateLoaded || !store) return;
    const cards = new Map<string, PersistedCard>();
    for (const [deviceId, device] of this.devices) {
      if (
        (device.activity === "live" || device.activity === "unknown") &&
        device.startedAt !== undefined
      ) {
        cards.set(deviceId, { activity: device.activity, startedAt: device.startedAt });
      }
    }
    const snapshot = JSON.stringify([...cards]);
    if (snapshot === this.lastPersisted) return;
    try {
      store.save(cards);
      this.lastPersisted = snapshot;
    } catch (err: unknown) {
      // A restart then falls back to ending and restarting the card.
      log.warn("live_activity.state_save_failed", { error: safeErrorMessage(err) });
    }
  }

  /** A session's program status changed; the counts may have too. */
  countsChanged(): void {
    const counts = this.options.counts();
    const previous = this.lastCounts;
    if (!sameCounts(previous, counts)) {
      // A card this server started and has not ended may have come through a short zero (no
      // end goes out within a minute of the last send): the work it counts is not new, and
      // dating later would let it reach Apple's 8 hours before the server restarts it.
      if (isEmpty(previous) && this.countsRiseTrusted && !this.anyCardLive()) {
        this.countsRoseAt = this.now();
      }
      if (isEmpty(counts)) this.countsRiseTrusted = true;
      this.lastCounts = counts;
      this.lastCountsChangeAt = this.now();
    }
    const deviceIds = new Set(this.registrations().map((entry) => entry.deviceId));
    for (const deviceId of this.devices.keys()) {
      if (!deviceIds.has(deviceId)) this.forget(deviceId);
    }
    for (const deviceId of deviceIds) this.schedule(deviceId);
  }

  /** Whether this server started a card that no delivered `end` has since removed. */
  private anyCardLive(): boolean {
    for (const device of this.devices.values()) if (device.activity === "live") return true;
    return false;
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
    this.persistSoon();
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
        lastSentAt: Number.NEGATIVE_INFINITY,
        retryAt: 0,
        endRetryAt: 0,
        sending: false,
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
    this.persistSoon();
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
        // Every route into `none` leaves `shown` empty: only work starting needs a send.
        return !isEmpty(counts);
      case "lost":
        return isEmpty(counts);
      default:
        return (
          isEmpty(counts) || this.dueForRestart(device, now) || !sameCounts(device.shown, counts)
        );
    }
  }

  /** Whether the send due now is an `end`: the counts are zero, or the 8-hour restart's end. */
  private sendsEnd(device: DeviceState, counts: LiveActivityCounts, now: number): boolean {
    return isEmpty(counts) || this.dueForRestart(device, now);
  }

  /** Arm the device's one timer for its next send, or for its card's 8-hour restart. */
  private schedule(deviceId: string): void {
    if (this.stopped) return;
    const device = this.device(deviceId);
    // A send in flight reschedules when it ends, with the counts it finds then.
    if (device.sending) return;
    this.cancel(device);
    if (this.options.isDevicePresent(deviceId)) return;
    const now = this.now();
    let at: number | undefined;
    if (this.needsSend(device, this.options.counts(), now)) {
      const counts = this.options.counts();
      const retryAt = this.sendsEnd(device, counts, now) ? device.endRetryAt : device.retryAt;
      at = Math.max(now, device.lastSentAt + LIVE_ACTIVITY_MIN_INTERVAL_MS, retryAt);
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
    try {
      await this.drive(registration, device, counts);
    } catch (err: unknown) {
      log.warn("live_activity.send_failed", { error: safeErrorMessage(err) });
    } finally {
      device.sending = false;
      device.lastSentAt = this.now();
    }
    this.persistSoon();
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
        // The start waits out a failure or `429` of its own kind; `schedule` sends it then.
        if (this.now() >= device.retryAt) await this.begin(registration, device, counts);
      } else if (ended === "no_activity") {
        // No token to end: the card is out of reach. Starting one could sit next to it.
        this.settle(device, "lost", undefined);
      }
      return;
    }
    if (device.missedUpdates > LIVE_ACTIVITY_MISSING_TOKEN_RETRIES) {
      // The relay holds no token for any card of ours: work that began while the app was
      // backgrounded but connected has none. One start; `begin` makes the card lost if the
      // relay refuses it (dismissed, or this server not listed).
      log.info("live_activity.card_missing_start");
      await this.begin(registration, device, counts);
      return;
    }
    const result = await this.send(registration, device, "update", counts);
    if (result === "delivered") {
      device.shown = counts;
      device.missedUpdates = 0;
    } else if (result === "no_activity") {
      device.missedUpdates += 1;
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
      // No start token at the relay (the phone turned Live Activities off), the person
      // dismissed the card, or the phone does not list this server. The relay refuses every
      // start until an `end` ends the dismissal, and each refused start still costs it a
      // request, so send nothing until the counts reach zero: `lost` ends the card then, and
      // the next work starts a new one.
      this.settle(device, "lost", undefined);
    }
  }

  /**
   * Send one event. Failures set the retry time of its kind (end, or start and update). The
   * relay stamps its time.
   */
  private async send(
    registration: PushRegistration,
    device: DeviceState,
    event: LiveActivityPush["event"],
    counts: LiveActivityCounts,
  ): Promise<"delivered" | "no_activity" | "failed"> {
    const result = await this.push.sendLiveActivity(registration, {
      event,
      running: counts.running,
      needsYou: counts.needsYou,
    });
    const retry = (ms: number): void => {
      // Keep the later time: a short failure must not shorten a day-long `429`.
      const at = this.now() + ms;
      if (event === "end") device.endRetryAt = Math.max(device.endRetryAt, at);
      else device.retryAt = Math.max(device.retryAt, at);
    };
    switch (result?.status) {
      case "delivered":
        return "delivered";
      case "no_activity":
        return "no_activity";
      case "rejected":
        retry(
          result.retryAfterSeconds !== undefined
            ? result.retryAfterSeconds * 1000
            : RETRY_AFTER_FAILURE_MS,
        );
        return "failed";
      case "unavailable":
      case "failed":
        retry(RETRY_AFTER_FAILURE_MS);
        return "failed";
      case "throttled":
        // Out of today's budget: the next change after the budget resets tries again.
        retry(RETRY_AFTER_FAILURE_MS);
        return "failed";
      default:
        // Gone or no longer current: the registration is pruned or replaced.
        return "failed";
    }
  }
}

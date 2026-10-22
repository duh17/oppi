/**
 * Seals one notification per paired device and hands it to the relay
 * (protocol/push/spec.md §5). A device without a push registration gets nothing: there is
 * no plaintext path.
 */

import { createHash, createHmac, type KeyObject } from "node:crypto";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { ServerMetricCollector } from "../server-metric-collector.js";
import type { PushEvent, PushRegistration, ServerConfig } from "../types.js";
import { type PushPlaintext, type PushSubject, sealPushEnvelope } from "./envelope.js";
import {
  type LiveActivityPush,
  type LiveActivitySendResult,
  RelayClient,
  type RelaySendResult,
} from "./relay-client.js";

const log = createLogger({ base: { component: "push" } });

/** Alerts expire at the relay's maximum TTL. */
const PUSH_TTL_SECONDS = 3600;

/**
 * Pushes one device may get from this server (protocol/push/spec.md §5), alerts and Live
 * Activity from one daily pool as at the relay, so the server stops asking before the relay
 * refuses. Live Activity starts and updates stop at `liveActivityPerDay`, leaving the rest to
 * alerts; a start needs two free slots (its own and its end's). Routine alerts stop at
 * `routinePerDay` and `routinePerMinute`; the rest is kept for alerts that wait on the user
 * (`blocked`, `pairing_approval`), so a busy day of failed runs, agent messages, and card
 * updates never hides an approval. An end is never refused for the day's `perDay` but has an
 * overdraft of `liveActivityEndOverdraft` more, as at the relay, so a failing end cannot
 * repeat all day; a card left up after its work finished stays wrong until Apple's 8 h limit.
 */
export const PUSH_DEVICE_BUDGET = {
  perDay: 100,
  routinePerDay: 90,
  liveActivityPerDay: 70,
  liveActivityEndOverdraft: 8,
  perMinute: 10,
  routinePerMinute: 8,
} as const;

type DeviceUsage = {
  /** UTC day `YYYY-MM-DD`, the relay's quota day. */
  day: string;
  /** Alerts and Live Activity pushes together. */
  dayCount: number;
  /** Alerts only; a Live Activity has no per-minute budget here (the notifier sends one a minute). */
  minuteStart: number;
  minuteCount: number;
  /** No alerts before this time: the relay answered 429 with Retry-After. */
  alertsPausedUntil: number;
  /** The same for a Live Activity start or update. */
  liveActivityPausedUntil: number;
  /** The same for an end, which the relay holds to a more generous daily limit. */
  endPausedUntil: number;
};

/**
 * In memory only: a restart starts a fresh budget, and the relay still enforces its own. An
 * alert counts when it is sent. A Live Activity push counts only once the relay has counted
 * it (it reached APNs, or the relay says the quota is full), so a relay that was unreachable
 * or refused before APNs costs nothing; the notifier sends one Live Activity push per device
 * at a time, so checking before and counting after cannot race. A `429` pauses only its own
 * kind: an update refused for the full day must not hold back an approval or the end that
 * removes the finished card.
 */
class DeviceBudget {
  private readonly usage = new Map<string, DeviceUsage>();

  takeAlert(deviceId: string, waitsOnUser: boolean, now: number): boolean {
    const usage = this.current(deviceId, now);
    if (now < usage.alertsPausedUntil) return false;
    if (now - usage.minuteStart >= 60_000) {
      usage.minuteStart = now;
      usage.minuteCount = 0;
    }
    const perDay = waitsOnUser ? PUSH_DEVICE_BUDGET.perDay : PUSH_DEVICE_BUDGET.routinePerDay;
    const perMinute = waitsOnUser
      ? PUSH_DEVICE_BUDGET.perMinute
      : PUSH_DEVICE_BUDGET.routinePerMinute;
    if (usage.dayCount >= perDay || usage.minuteCount >= perMinute) return false;
    usage.dayCount += 1;
    usage.minuteCount += 1;
    return true;
  }

  allowsLiveActivity(deviceId: string, event: LiveActivityPush["event"], now: number): boolean {
    const usage = this.current(deviceId, now);
    switch (event) {
      case "update":
        return (
          now >= usage.liveActivityPausedUntil &&
          usage.dayCount < PUSH_DEVICE_BUDGET.liveActivityPerDay
        );
      case "start":
        return (
          now >= usage.liveActivityPausedUntil &&
          usage.dayCount <= PUSH_DEVICE_BUDGET.liveActivityPerDay - 2
        );
      case "end":
        return (
          now >= usage.endPausedUntil &&
          usage.dayCount < PUSH_DEVICE_BUDGET.perDay + PUSH_DEVICE_BUDGET.liveActivityEndOverdraft
        );
    }
  }

  chargeLiveActivity(deviceId: string, now: number): void {
    this.current(deviceId, now).dayCount += 1;
  }

  pauseAlerts(deviceId: string, until: number): void {
    const usage = this.usage.get(deviceId);
    if (usage) usage.alertsPausedUntil = Math.max(usage.alertsPausedUntil, until);
  }

  pauseLiveActivity(deviceId: string, event: LiveActivityPush["event"], until: number): void {
    const usage = this.usage.get(deviceId);
    if (!usage) return;
    if (event === "end") usage.endPausedUntil = Math.max(usage.endPausedUntil, until);
    else usage.liveActivityPausedUntil = Math.max(usage.liveActivityPausedUntil, until);
  }

  private current(deviceId: string, now: number): DeviceUsage {
    const day = new Date(now).toISOString().slice(0, 10);
    let usage = this.usage.get(deviceId);
    if (!usage) {
      usage = {
        day,
        dayCount: 0,
        minuteStart: now,
        minuteCount: 0,
        alertsPausedUntil: 0,
        liveActivityPausedUntil: 0,
        endPausedUntil: 0,
      };
      this.usage.set(deviceId, usage);
    }
    if (usage.day !== day) {
      usage.day = day;
      usage.dayCount = 0;
    }
    return usage;
  }
}

/** The relay counted this send against the phone's Live Activity quota, or says it is full. */
function relayCountedLiveActivity(result: LiveActivitySendResult | { status: "failed" }): boolean {
  switch (result.status) {
    case "delivered":
      return true;
    case "unavailable":
      return result.charged;
    case "rejected":
      return result.httpStatus === 429;
    default:
      return false;
  }
}

/** What one push says, before its timestamp. */
export type PushNotification = {
  title: string;
  subtitle?: string;
  body: string;
} & PushSubject;

export interface PushSenderStorage {
  getConfig(): Pick<ServerConfig, "push">;
  getPushRegistrations(): PushRegistration[];
  removePushRegistration(deviceId: string, sendToken?: string): PushRegistration | null;
}

export interface PushSenderOptions {
  /** The server's Ed25519 identity key. */
  signingKey: KeyObject;
  metrics?: ServerMetricCollector;
  fetch?: typeof fetch;
  now?: () => number;
}

/** `[primary, standby]` when relay mode is on and configured; otherwise undefined. */
export function activePushRelays(config: Pick<ServerConfig, "push">): string[] | undefined {
  const push = config.push;
  if (push?.mode !== "relay" || !push.relays || push.relays.length === 0) return undefined;
  return push.relays;
}

/**
 * Tells the relay that these registrations' send permissions are no longer used (spec §5).
 * Resolves to the registrations whose release failed; the relay's DELETE is idempotent, so a
 * failure is real: that send token stays usable at the relay until the app revokes it.
 */
export async function releasePushPermissions(
  relays: readonly string[],
  registrations: PushRegistration[],
  fetchImpl?: typeof fetch,
): Promise<PushRegistration[]> {
  const client = new RelayClient(relays, { fetch: fetchImpl });
  const released = await Promise.all(
    registrations.map((registration) =>
      client.deletePermission(registration.sendToken).catch(() => false),
    ),
  );
  return registrations.filter((_, index) => !released[index]);
}

function sendTokenHash(sendToken: string): string {
  return createHash("sha256").update(sendToken, "utf8").digest("base64url");
}

/** Stable per device and session, unlinkable across devices (spec §5). */
export function pushCollapseId(sendToken: string, collapseKey: string): string {
  const key = createHash("sha256").update(sendToken, "utf8").digest();
  return createHmac("sha256", key)
    .update(`oppi-push-collapse-v1\n${collapseKey}`, "utf8")
    .digest()
    .subarray(0, 16)
    .toString("base64url");
}

/**
 * Session alerts collapse per session, an agent's message apart from them so a later question
 * never replaces what it asked the user to read; pairing pushes per approval or enrolled device.
 */
function pushCollapseKey(notification: PushNotification): string {
  switch (notification.event) {
    case "pairing_approval":
      return `pairing:${notification.approvalId}`;
    case "device_enrolled":
      return `device:${notification.deviceId}`;
    case "notify":
      return `notify:${notification.sessionId}`;
    default:
      return notification.sessionId;
  }
}

/** Copied field by field so only the plaintext fields reach the phone. */
function pushPlaintext(notification: PushNotification, ts: number): PushPlaintext {
  const text = {
    title: notification.title,
    ...(notification.subtitle ? { subtitle: notification.subtitle } : {}),
    body: notification.body,
  };
  switch (notification.event) {
    case "pairing_approval":
      return { v: 1, ts, event: notification.event, approvalId: notification.approvalId, ...text };
    case "device_enrolled":
      return { v: 1, ts, event: notification.event, deviceId: notification.deviceId, ...text };
    default:
      return {
        v: 1,
        ts,
        event: notification.event,
        ...(notification.kind ? { kind: notification.kind } : {}),
        sessionId: notification.sessionId,
        ...(notification.workspaceId ? { workspaceId: notification.workspaceId } : {}),
        ...text,
      };
  }
}

/** How many pruned send tokens the server remembers. One entry is a 32-byte hash. */
const GONE_SEND_TOKENS_MAX = 256;

export class PushSender {
  private readonly now: () => number;
  private readonly budget = new DeviceBudget();
  /**
   * The `push` config block as it was at startup. `ConfigStore.mutate` reloads `config.json`
   * on every locked write, so reading it live would apply a `push.mode` edit at a random later
   * moment instead of at the restart the docs promise. The per-device `events` and
   * `liveActivity` come from each registration, not from this block.
   */
  private readonly pushRelays: readonly string[] | undefined;
  /**
   * Hashes of send tokens the primary relay answered `410` for, oldest first. In memory: after
   * a restart the phone may register the dead token once more, and the next send's `410`
   * teaches the server again, so persisting would save one relay call and need a new config key.
   */
  private readonly goneSendTokens = new Set<string>();

  constructor(
    private readonly storage: PushSenderStorage,
    private readonly options: PushSenderOptions,
  ) {
    this.now = options.now ?? Date.now;
    const relays = activePushRelays(storage.getConfig());
    this.pushRelays = relays && [...relays];
  }

  /** Relay origins from startup config (a change to `push` needs a server restart). */
  relays(): readonly string[] | undefined {
    return this.pushRelays;
  }

  /** True when the primary relay retired this send token (`410`): registering it again is futile. */
  isSendTokenGone(sendToken: string): boolean {
    return this.goneSendTokens.has(sendTokenHash(sendToken));
  }

  /**
   * Registrations that can receive pushes now: none while push is off. With `event`, only the
   * phones that listed it.
   */
  registrations(event?: PushEvent): PushRegistration[] {
    if (!this.relays()) return [];
    const registrations = this.storage.getPushRegistrations();
    return event ? registrations.filter((entry) => entry.events.includes(event)) : registrations;
  }

  /**
   * Seal and send to one device within its budget. Prunes the registration when the primary
   * relay answers `410`. Never throws. Null, sending nothing, for a phone that did not list
   * the event: it could show only the fixed fallback, so the relay never carries it.
   */
  async send(
    registration: PushRegistration,
    notification: PushNotification,
  ): Promise<RelaySendResult | { status: "failed" } | { status: "throttled" } | null> {
    const relays = this.relays();
    if (
      !relays ||
      !registration.events.includes(notification.event) ||
      !this.isCurrent(registration)
    ) {
      return null;
    }
    const startedAt = this.now();
    const waitsOnUser =
      notification.event === "blocked" || notification.event === "pairing_approval";
    if (!this.budget.takeAlert(registration.deviceId, waitsOnUser, startedAt)) {
      log.info("push.device_budget_exhausted", { alert: notification.event });
      this.options.metrics?.record("server.push_result", 1, {
        result: "throttled",
        event: notification.event,
      });
      return { status: "throttled" };
    }

    let result: RelaySendResult | { status: "failed" };
    try {
      const envelope = sealPushEnvelope({
        recipientPublicKey: Buffer.from(registration.publicKey, "base64url"),
        plaintext: pushPlaintext(notification, this.now()),
        signingKey: this.options.signingKey,
      });
      result = await new RelayClient(relays, { fetch: this.options.fetch }).push(
        registration.sendToken,
        {
          envelope,
          collapseId: pushCollapseId(registration.sendToken, pushCollapseKey(notification)),
          ttl: PUSH_TTL_SECONDS,
        },
      );
    } catch (err: unknown) {
      log.warn("push.seal_or_send_failed", { error: safeErrorMessage(err) });
      result = { status: "failed" };
    }

    if (result.status === "rejected" && result.retryAfterSeconds !== undefined) {
      this.budget.pauseAlerts(registration.deviceId, this.now() + result.retryAfterSeconds * 1000);
    }
    this.settle(registration, result, startedAt, notification.event);
    return result;
  }

  /**
   * Send one Live Activity push to a device that accepts them, within its budget. Prunes
   * the registration on a primary `410`, like `send`. Never throws.
   */
  async sendLiveActivity(
    registration: PushRegistration,
    push: LiveActivityPush,
  ): Promise<LiveActivitySendResult | { status: "failed" } | { status: "throttled" } | null> {
    const relays = this.relays();
    if (!relays || !registration.liveActivity || !this.isCurrent(registration)) return null;
    const startedAt = this.now();
    const event = `live_activity_${push.event}`;
    if (!this.budget.allowsLiveActivity(registration.deviceId, push.event, startedAt)) {
      log.info("push.device_budget_exhausted", { alert: event });
      this.options.metrics?.record("server.push_result", 1, { result: "throttled", event });
      return { status: "throttled" };
    }
    let result: LiveActivitySendResult | { status: "failed" };
    try {
      result = await new RelayClient(relays, { fetch: this.options.fetch }).liveActivity(
        registration.sendToken,
        push,
      );
    } catch (err: unknown) {
      log.warn("push.seal_or_send_failed", { error: safeErrorMessage(err) });
      result = { status: "failed" };
    }
    if (relayCountedLiveActivity(result)) {
      this.budget.chargeLiveActivity(registration.deviceId, startedAt);
    }
    if (result.status === "rejected" && result.retryAfterSeconds !== undefined) {
      this.budget.pauseLiveActivity(
        registration.deviceId,
        push.event,
        this.now() + result.retryAfterSeconds * 1000,
      );
    }
    this.settle(registration, result, startedAt, event);
    return result;
  }

  /** False for a device revoked or re-registered since the caller listed registrations. */
  private isCurrent(registration: PushRegistration): boolean {
    return this.storage
      .getPushRegistrations()
      .some(
        (entry) =>
          entry.deviceId === registration.deviceId &&
          entry.keyId === registration.keyId &&
          entry.sendToken === registration.sendToken,
      );
  }

  /** Prune on a primary `410`, log what was not delivered, and record the result. */
  private settle(
    registration: PushRegistration,
    result: RelaySendResult | LiveActivitySendResult | { status: "failed" },
    startedAt: number,
    event: string,
  ): void {
    if (result.status === "gone" && result.prune) {
      this.storage.removePushRegistration(registration.deviceId, registration.sendToken);
      this.rememberGoneSendToken(registration.sendToken);
      log.info("push.registration_pruned", { device: registration.deviceId });
    } else if (result.status !== "delivered" && result.status !== "no_activity") {
      log.warn("push.not_delivered", {
        status: result.status,
        ...(result.status === "rejected"
          ? { httpStatus: result.httpStatus, error: result.error }
          : {}),
      });
    }
    this.options.metrics?.record("server.push_send_ms", this.now() - startedAt, {
      result: result.status,
    });
    this.options.metrics?.record("server.push_result", 1, { result: result.status, event });
  }

  private rememberGoneSendToken(sendToken: string): void {
    const hash = sendTokenHash(sendToken);
    this.goneSendTokens.delete(hash);
    this.goneSendTokens.add(hash);
    if (this.goneSendTokens.size > GONE_SEND_TOKENS_MAX) {
      const oldest = this.goneSendTokens.values().next().value;
      if (oldest !== undefined) this.goneSendTokens.delete(oldest);
    }
  }

  /** Best effort: tell the relay a forgotten registration's permission is no longer used. */
  releasePermission(registration: PushRegistration): void {
    const relays = this.relays();
    if (!relays) return;
    void releasePushPermissions(relays, [registration], this.options.fetch).then((failed) => {
      if (failed.length > 0)
        log.warn("push.permission_release_failed", { device: registration.deviceId });
    });
  }
}

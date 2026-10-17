/**
 * Seals one notification per paired device and hands it to the relay
 * (protocol/push/spec.md §5). A device without a push registration gets nothing: there is
 * no plaintext path.
 */

import { createHash, createHmac, type KeyObject } from "node:crypto";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { ServerMetricCollector } from "../server-metric-collector.js";
import type { PushRegistration, ServerConfig } from "../types.js";
import { type PushPlaintext, type PushSubject, sealPushEnvelope } from "./envelope.js";
import { RelayClient, type RelaySendResult } from "./relay-client.js";

const log = createLogger({ base: { component: "push" } });

/** Alerts expire at the relay's maximum TTL. */
const PUSH_TTL_SECONDS = 3600;

/**
 * Pushes one device may get from this server (protocol/push/spec.md §5). Matches the relay's
 * per-phone quota, so the server stops asking before the relay refuses. Routine alerts stop
 * at the lower numbers; the rest is kept for alerts that wait on the user (`blocked`,
 * `pairing_approval`), so a busy day of finished runs never hides an approval.
 */
export const PUSH_DEVICE_BUDGET = {
  perDay: 100,
  perMinute: 10,
  routinePerDay: 80,
  routinePerMinute: 8,
} as const;

type DeviceUsage = {
  /** UTC day `YYYY-MM-DD`, the relay's quota day. */
  day: string;
  dayCount: number;
  minuteStart: number;
  minuteCount: number;
  /** No sends before this time: the relay answered 429 with Retry-After. */
  pausedUntil: number;
};

/** In memory only: a restart starts a fresh budget, and the relay still enforces its own. */
class DeviceBudget {
  private readonly usage = new Map<string, DeviceUsage>();

  take(deviceId: string, waitsOnUser: boolean, now: number): boolean {
    const day = new Date(now).toISOString().slice(0, 10);
    let usage = this.usage.get(deviceId);
    if (!usage) {
      usage = { day, dayCount: 0, minuteStart: now, minuteCount: 0, pausedUntil: 0 };
      this.usage.set(deviceId, usage);
    }
    if (now < usage.pausedUntil) return false;
    if (usage.day !== day) {
      usage.day = day;
      usage.dayCount = 0;
    }
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

  pause(deviceId: string, until: number): void {
    const usage = this.usage.get(deviceId);
    if (usage) usage.pausedUntil = Math.max(usage.pausedUntil, until);
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
  relays: string[],
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

/** Stable per device and session, unlinkable across devices (spec §5). */
export function pushCollapseId(sendToken: string, collapseKey: string): string {
  const key = createHash("sha256").update(sendToken, "utf8").digest();
  return createHmac("sha256", key)
    .update(`oppi-push-collapse-v1\n${collapseKey}`, "utf8")
    .digest()
    .subarray(0, 16)
    .toString("base64url");
}

/** Session pushes collapse per session; pairing pushes per approval or enrolled device. */
function pushCollapseKey(notification: PushNotification): string {
  switch (notification.event) {
    case "pairing_approval":
      return `pairing:${notification.approvalId}`;
    case "device_enrolled":
      return `device:${notification.deviceId}`;
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

export class PushSender {
  private readonly now: () => number;
  private readonly budget = new DeviceBudget();

  constructor(
    private readonly storage: PushSenderStorage,
    private readonly options: PushSenderOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  /** Relay origins from the server's current config (the CLI asks for a restart after edits). */
  relays(): string[] | undefined {
    return activePushRelays(this.storage.getConfig());
  }

  /** Registrations that can receive pushes now: none while push is off. */
  registrations(): PushRegistration[] {
    return this.relays() ? this.storage.getPushRegistrations() : [];
  }

  /**
   * Seal and send to one device within its budget. Prunes the registration when the primary
   * relay answers `410`. Never throws.
   */
  async send(
    registration: PushRegistration,
    notification: PushNotification,
  ): Promise<RelaySendResult | { status: "failed" } | { status: "throttled" } | null> {
    const relays = this.relays();
    if (!relays) return null;
    // A device revoked or re-registered since the caller listed registrations gets nothing.
    const current = this.storage
      .getPushRegistrations()
      .some(
        (entry) =>
          entry.deviceId === registration.deviceId &&
          entry.keyId === registration.keyId &&
          entry.sendToken === registration.sendToken,
      );
    if (!current) return null;
    const startedAt = this.now();
    const waitsOnUser =
      notification.event === "blocked" || notification.event === "pairing_approval";
    if (!this.budget.take(registration.deviceId, waitsOnUser, startedAt)) {
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
      this.budget.pause(registration.deviceId, this.now() + result.retryAfterSeconds * 1000);
    }
    if (result.status === "gone" && result.prune) {
      this.storage.removePushRegistration(registration.deviceId, registration.sendToken);
      log.info("push.registration_pruned", { device: registration.deviceId });
    } else if (result.status !== "delivered") {
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
    this.options.metrics?.record("server.push_result", 1, {
      result: result.status,
      event: notification.event,
    });
    return result;
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

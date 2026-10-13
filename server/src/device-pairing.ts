/**
 * Device pairing after an approver said yes: the approval policy, pending approvals, and
 * enrollment with its alert.
 *
 * Approvers: `invite` consumes the outstanding `pt_` invite and reports how it was minted
 * (`/pair/tailscale` mints `tailscale` invites after its same-user whois proof);
 * `custom` asks the owner's `auth.module`. Every method then runs the same policy: when at
 * least one other active device exists, a long-lived invite (TTL over 90 s), a Tailscale
 * invite, or a custom pairing waits until an existing device signs an approval. Each
 * enrollment pushes a `device_enrolled` alert to the other devices and logs
 * `auth.device_enrolled`.
 *
 * Pending approvals live in memory: a restart forgets them and the waiting device gets 404.
 */

import { createHash, timingSafeEqual } from "node:crypto";

import type { AuthModule, CustomPairingRequest } from "./auth-module.js";
import { generateId } from "./id.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { fitPushBody } from "./push/envelope.js";
import type { PushNotification, PushSender } from "./push/push-sender.js";
import type { EnrollResult } from "./storage/device-auth.js";
import { sanitizeDisplayText, verifyDeviceSignature } from "./storage/device-auth.js";
import type { Storage } from "./storage.js";
import type {
  DevicePublicKey,
  PairingApprovalOutcome,
  PairingMethod,
  PairingTokenOrigin,
  PendingPairingApproval,
} from "./types.js";

const log = createLogger({ base: { component: "device_pairing" } });

/** Invites that live longer than this need an approval once another device is paired. */
export const SHORT_INVITE_MAX_TTL_MS = 90_000;
export const PAIRING_APPROVAL_TTL_MS = 120_000;
/** An approved device must collect its credential within this window. */
export const PAIRING_APPROVAL_CLAIM_MS = 60_000;
export const MAX_PENDING_PAIRING_APPROVALS = 8;
/** A custom approver's `source` is shown and logged; keep it one short line. */
export const MAX_CUSTOM_SOURCE_CODE_POINTS = 128;
/** How long a settled approval still answers the waiting device with its outcome. */
const SETTLED_RETENTION_MS = 60_000;

/** What an approver granted. `ttlMs` is the issued invite TTL for invite pairings. */
export interface PairingGrant {
  method: PairingMethod;
  source?: string;
  ttlMs?: number;
}

export interface PairingCandidate {
  publicKey: DevicePublicKey;
  name: string;
}

export type AdmitOutcome =
  | { kind: "enrolled"; result: EnrollResult }
  | { kind: "approval_required"; approvalId: string; pendingToken: string; expiresAt: number }
  | { kind: "busy" };

export type ApprovalStatus =
  | { kind: "pending"; expiresAt: number }
  | { kind: "enrolled"; result: EnrollResult }
  | { kind: "denied" }
  | { kind: "expired" }
  | { kind: "unknown" };

export type ApproveResult = "approved" | "not_found" | "bad_signature" | "inactive_device";

export interface PairingApprovalEvents {
  emitPairingApprovalRequested(approval: PendingPairingApproval): void;
  emitPairingApprovalSettled(approvalId: string, outcome: PairingApprovalOutcome): void;
}

export interface DevicePairingDeps {
  storage: Pick<Storage, "consumePairingToken" | "enrollDevice" | "listDevices">;
  push?: Pick<PushSender, "registrations" | "send">;
  events?: PairingApprovalEvents;
  authModule?: AuthModule;
  now?: () => number;
}

type ApprovalState = "pending" | "approved" | "denied" | "expired";

interface ApprovalEntry {
  approval: PendingPairingApproval;
  candidate: PairingCandidate;
  grant: PairingGrant;
  pendingTokenHash: Buffer;
  state: ApprovalState;
  approvedByDeviceId?: string;
  /** Approved: deadline to collect the credential. */
  claimBy?: number;
  /** Removed after this time. */
  retainUntil: number;
  expiryTimer?: ReturnType<typeof setTimeout>;
}

/** RFC 7638 JWK thumbprint (SHA-256, base64url) of a P-256 device key. */
export function deviceKeyThumbprint(publicKey: DevicePublicKey): string {
  // Required members in lexicographic order, no whitespace.
  const canonical = JSON.stringify({
    crv: publicKey.crv,
    kty: publicKey.kty,
    x: publicKey.x,
    y: publicKey.y,
  });
  return createHash("sha256").update(canonical, "utf8").digest("base64url");
}

/** Bytes an existing device signs to approve `approvalId` for the key `keyThumbprint`. */
export function pairingApprovalMessage(approvalId: string, keyThumbprint: string): Buffer {
  return Buffer.from(`oppi:pair-approve:v1.${approvalId}.${keyThumbprint}`, "utf8");
}

export function pairingNeedsApproval(grant: PairingGrant, otherActiveDevices: number): boolean {
  if (otherActiveDevices === 0) return false;
  if (grant.method !== "invite") return true;
  return grant.ttlMs === undefined || grant.ttlMs > SHORT_INVITE_MAX_TTL_MS;
}

function hashPendingToken(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}

function describePairing(method: PairingMethod, source: string | undefined): string {
  return source ? `${method}, ${source}` : method;
}

export class DevicePairing {
  private readonly approvals = new Map<string, ApprovalEntry>();
  /** Queue slots held by custom pairings while their module decides. */
  private reservedSlots = 0;
  private readonly now: () => number;

  constructor(private readonly deps: DevicePairingDeps) {
    this.now = deps.now ?? Date.now;
  }

  /**
   * Built-in `invite` approver plus the policy. The approval decision and the queue check run
   * inside the config lock that consumes the invite, so a full queue answers `busy` and leaves
   * the invite usable. Nothing awaits between that check and the insert.
   */
  pairWithInvite(
    pairingToken: string,
    candidate: PairingCandidate,
    clientIp: string | undefined,
  ): AdmitOutcome | { kind: "invalid" } {
    this.sweep(this.now());
    const grantFor = (origin: PairingTokenOrigin): PairingGrant => {
      const source = origin.method === "tailscale" ? (origin.source ?? clientIp) : clientIp;
      return { method: origin.method, ttlMs: origin.ttlMs, ...(source ? { source } : {}) };
    };
    const consumed = this.deps.storage.consumePairingToken(
      pairingToken,
      (origin, activeDeviceCount) =>
        !pairingNeedsApproval(grantFor(origin), activeDeviceCount) || this.hasQueueRoom(),
    );
    if (consumed.status === "invalid") return { kind: "invalid" };
    if (consumed.status === "refused") return this.busy(consumed.origin.method);
    return this.admit(candidate, grantFor(consumed.origin), { slotHeld: true });
  }

  get customApproverAvailable(): boolean {
    return this.deps.authModule?.pairingApproverAvailable === true;
  }

  /**
   * `custom` approver (the owner's `auth.module`) plus the policy. A custom pairing needs
   * approval whenever another device is active, so with a full queue the module is never asked
   * and its credential is not spent. The slot is held across the module's await.
   */
  async pairWithCustom(
    candidate: PairingCandidate,
    request: Omit<CustomPairingRequest, "method">,
  ): Promise<AdmitOutcome | { kind: "denied"; reason?: string }> {
    const authModule = this.deps.authModule;
    if (!authModule) return { kind: "denied" };
    this.sweep(this.now());
    const slotHeld = this.activeDeviceIds().size > 0;
    if (slotHeld && !this.hasQueueRoom()) return this.busy("custom");
    if (slotHeld) this.reservedSlots += 1;
    try {
      const decision = await authModule.approvePairing({ method: "custom", ...request });
      if (!decision.allow) {
        return { kind: "denied", ...(decision.reason ? { reason: decision.reason } : {}) };
      }
      const source =
        (decision.source && sanitizeDisplayText(decision.source, MAX_CUSTOM_SOURCE_CODE_POINTS)) ||
        request.clientIp;
      return this.admit(
        candidate,
        { method: "custom", ...(source ? { source } : {}) },
        { slotHeld },
      );
    } finally {
      if (slotHeld) this.reservedSlots -= 1;
    }
  }

  private hasQueueRoom(): boolean {
    const pending = [...this.approvals.values()].filter((e) => e.state === "pending").length;
    return pending + this.reservedSlots < MAX_PENDING_PAIRING_APPROVALS;
  }

  private busy(method: PairingMethod): { kind: "busy" } {
    log.warn("auth.pairing_approval_rejected", { reason: "too_many_pending", method });
    return { kind: "busy" };
  }

  /**
   * Enroll now, or queue for approval. `slotHeld` means the caller already checked the queue
   * (an invite, inside its consume lock) or reserved a slot (custom, across its await).
   */
  private admit(
    candidate: PairingCandidate,
    grant: PairingGrant,
    options: { slotHeld: boolean },
  ): AdmitOutcome {
    const now = this.now();
    this.sweep(now);
    if (!pairingNeedsApproval(grant, this.activeDeviceIds().size)) {
      return { kind: "enrolled", result: this.enroll(candidate, grant) };
    }
    if (!options.slotHeld && !this.hasQueueRoom()) return this.busy(grant.method);

    const approval: PendingPairingApproval = {
      id: `pa_${generateId(22)}`,
      deviceName: candidate.name,
      method: grant.method,
      ...(grant.source ? { source: grant.source } : {}),
      requestedAt: now,
      expiresAt: now + PAIRING_APPROVAL_TTL_MS,
      keyThumbprint: deviceKeyThumbprint(candidate.publicKey),
    };
    const pendingToken = `pw_${generateId(32)}`;
    const entry: ApprovalEntry = {
      approval,
      candidate,
      grant,
      pendingTokenHash: hashPendingToken(pendingToken),
      state: "pending",
      retainUntil: approval.expiresAt + SETTLED_RETENTION_MS,
    };
    entry.expiryTimer = setTimeout(() => this.sweep(this.now()), PAIRING_APPROVAL_TTL_MS + 50);
    entry.expiryTimer.unref?.();
    this.approvals.set(approval.id, entry);

    log.info("auth.pairing_approval_requested", {
      approval: approval.id,
      name: approval.deviceName,
      method: approval.method,
      source: approval.source,
    });
    this.deps.events?.emitPairingApprovalRequested({ ...approval });
    const requestSubject = {
      event: "pairing_approval" as const,
      approvalId: approval.id,
      title: "Approve New Device?",
    };
    this.pushToDevices(
      {
        ...requestSubject,
        body: fitPushBody(
          requestSubject,
          approval.deviceName,
          ` wants to pair (${describePairing(approval.method, approval.source)}).`,
        ),
      },
      () => true,
    );
    return {
      kind: "approval_required",
      approvalId: approval.id,
      pendingToken,
      expiresAt: approval.expiresAt,
    };
  }

  /**
   * The waiting device's poll. The first poll after approval enrolls it; that answer is
   * one-time. A wrong id or token is `unknown`.
   */
  status(approvalId: string, pendingToken: string): ApprovalStatus {
    const now = this.now();
    this.sweep(now);
    const entry = this.approvals.get(approvalId);
    if (!entry) return { kind: "unknown" };
    const candidateHash = hashPendingToken(pendingToken);
    if (!timingSafeEqual(candidateHash, entry.pendingTokenHash)) return { kind: "unknown" };

    switch (entry.state) {
      case "pending":
        return { kind: "pending", expiresAt: entry.approval.expiresAt };
      case "denied":
        return { kind: "denied" };
      case "expired":
        return { kind: "expired" };
      case "approved": {
        // The approval is only as good as its approver: revoked since approving, it lapses.
        const approver = entry.approvedByDeviceId;
        if (!approver || !this.activeDeviceIds().has(approver)) {
          entry.state = "expired";
          log.warn("auth.pairing_approval_approver_revoked", { approval: approvalId });
          return { kind: "expired" };
        }
        this.approvals.delete(approvalId);
        const result = this.enroll(entry.candidate, entry.grant, entry.approvedByDeviceId);
        return { kind: "enrolled", result };
      }
    }
  }

  /** Pending, unexpired approvals. */
  list(): PendingPairingApproval[] {
    this.sweep(this.now());
    return [...this.approvals.values()]
      .filter((entry) => entry.state === "pending")
      .map((entry) => ({ ...entry.approval }));
  }

  /**
   * An existing device approves with a P-256 signature over
   * `oppi:pair-approve:v1.<id>.<keyThumbprint>` by its enrolled key.
   */
  approve(approvalId: string, approverDeviceId: string, signature: unknown): ApproveResult {
    const now = this.now();
    this.sweep(now);
    const entry = this.approvals.get(approvalId);
    if (!entry || entry.state !== "pending") return "not_found";
    const approver = this.deps.storage
      .listDevices()
      .find((device) => device.id === approverDeviceId && device.revokedAt === undefined);
    if (!approver) return "inactive_device";
    const signatureBytes =
      typeof signature === "string" ? Buffer.from(signature, "base64url") : Buffer.alloc(0);
    if (
      signatureBytes.length !== 64 ||
      !verifyDeviceSignature(
        approver.publicKey,
        pairingApprovalMessage(entry.approval.id, entry.approval.keyThumbprint),
        signatureBytes,
      )
    ) {
      log.warn("auth.pairing_approval_bad_signature", {
        approval: approvalId,
        device: approverDeviceId,
      });
      return "bad_signature";
    }
    entry.state = "approved";
    entry.approvedByDeviceId = approver.id;
    entry.claimBy = now + PAIRING_APPROVAL_CLAIM_MS;
    entry.retainUntil = entry.claimBy + SETTLED_RETENTION_MS;
    clearTimeout(entry.expiryTimer);
    log.info("auth.pairing_approval_approved", { approval: approvalId, device: approver.id });
    this.deps.events?.emitPairingApprovalSettled(approvalId, "approved");
    return "approved";
  }

  deny(approvalId: string, deviceId: string): boolean {
    const now = this.now();
    this.sweep(now);
    const entry = this.approvals.get(approvalId);
    if (!entry || entry.state !== "pending") return false;
    entry.state = "denied";
    entry.retainUntil = now + SETTLED_RETENTION_MS;
    clearTimeout(entry.expiryTimer);
    log.warn("auth.pairing_approval_denied", { approval: approvalId, device: deviceId });
    this.deps.events?.emitPairingApprovalSettled(approvalId, "denied");
    return true;
  }

  dispose(): void {
    for (const entry of this.approvals.values()) clearTimeout(entry.expiryTimer);
    this.approvals.clear();
  }

  /** Expire pending approvals and unclaimed approvals, and forget old settled ones. */
  private sweep(now: number): void {
    for (const [id, entry] of this.approvals) {
      if (entry.state === "pending" && now >= entry.approval.expiresAt) {
        entry.state = "expired";
        clearTimeout(entry.expiryTimer);
        log.info("auth.pairing_approval_expired", { approval: id });
        this.deps.events?.emitPairingApprovalSettled(id, "expired");
      } else if (
        entry.state === "approved" &&
        entry.claimBy !== undefined &&
        now >= entry.claimBy
      ) {
        entry.state = "expired";
        log.info("auth.pairing_approval_unclaimed", { approval: id });
      }
      if (now >= entry.retainUntil) this.approvals.delete(id);
    }
  }

  private activeDeviceIds(): Set<string> {
    return new Set(
      this.deps.storage
        .listDevices()
        .filter((device) => device.revokedAt === undefined)
        .map((device) => device.id),
    );
  }

  private enroll(
    candidate: PairingCandidate,
    grant: PairingGrant,
    approvedByDeviceId?: string,
  ): EnrollResult {
    const result = this.deps.storage.enrollDevice({
      publicKey: candidate.publicKey,
      name: candidate.name,
      pairing: {
        method: grant.method,
        ...(grant.source ? { source: grant.source } : {}),
        ...(approvedByDeviceId ? { approvedByDeviceId } : {}),
      },
    });
    // Warn, like revocation: an unexpected enrollment is what an operator watches for.
    log.warn("auth.device_enrolled", {
      device: result.deviceId,
      name: candidate.name,
      method: grant.method,
      source: grant.source,
      ...(approvedByDeviceId ? { approvedBy: approvedByDeviceId } : {}),
    });
    const enrolledSubject = {
      event: "device_enrolled" as const,
      deviceId: result.deviceId,
      title: "New Device Paired",
    };
    this.pushToDevices(
      {
        ...enrolledSubject,
        body: fitPushBody(
          enrolledSubject,
          candidate.name,
          ` paired (${describePairing(grant.method, grant.source)}).`,
        ),
      },
      (deviceId) => deviceId !== result.deviceId,
    );
    return result;
  }

  /** One sealed push per active device with a push registration that `include` accepts. */
  private pushToDevices(
    notification: PushNotification,
    include: (deviceId: string) => boolean,
  ): void {
    const push = this.deps.push;
    if (!push) return;
    const active = this.activeDeviceIds();
    for (const registration of push.registrations()) {
      if (!active.has(registration.deviceId) || !include(registration.deviceId)) continue;
      void push.send(registration, notification).catch((error: unknown) => {
        log.warn("auth.pairing_push_failed", {
          event: notification.event,
          error: safeErrorMessage(error),
        });
      });
    }
  }
}

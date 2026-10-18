import { createHash } from "node:crypto";

import type { ExtensionUIResponse } from "./extension-ui-state.js";

export type VoiceApprovalRisk =
  | "voice_eligible"
  | "secondary_confirmation_required"
  | "voice_ineligible";

export interface VoiceControllerLease {
  callId: string;
  leaseId: string;
  epoch: number;
  deviceId: string;
  expiresAt: number;
}

export interface VoiceApprovalBinding {
  source: "structured_permission_gate";
  sessionId: string;
  requestId: string;
  actionDigest: string;
  targetRefs: readonly string[];
  policyRevision: string;
  risk: VoiceApprovalRisk;
  expiresAt: number;
  responses: Readonly<{
    approveOnce: Omit<ExtensionUIResponse, "type" | "id">;
    deny: Omit<ExtensionUIResponse, "type" | "id">;
  }>;
}

export interface VoiceApprovalChallenge {
  challengeId: string;
  callId: string;
  controllerLeaseId: string;
  controllerLeaseEpoch: number;
  deviceId: string;
  sessionId: string;
  requestId: string;
  actionDigest: string;
  targetRefs: readonly string[];
  nonce: string;
  issuedAt: number;
  expiresAt: number;
}

export interface VoiceApprovalReceipt {
  receiptId: string;
  challengeId: string;
  callId: string;
  controllerLeaseId: string;
  controllerLeaseEpoch: number;
  deviceId: string;
  sessionId: string;
  requestId: string;
  actionDigest: string;
  targetRefs: readonly string[];
  decision: VoiceApprovalDecision;
  receivedAt: number;
  validationOutcome: "accepted" | "rejected" | "non_authorizing";
  deliveryOutcome: "delivered" | "failed" | "not_attempted";
  reason?: string;
}

export type VoiceApprovalDecision = "approve_once" | "deny" | "tell_me_more" | "repeat";

export type VoiceApprovalSubmissionResult =
  | { kind: "delivered"; decision: "approve_once" | "deny" }
  | { kind: "retry"; reason: "tell_me_more" | "repeat" }
  | {
      kind: "rejected";
      reason:
        | "unknown_challenge"
        | "challenge_consumed"
        | "challenge_expired"
        | "challenge_mismatch"
        | "wrong_device"
        | "stale_controller_lease"
        | "action_changed"
        | "ambiguous_decision"
        | "delivery_failed";
    };

export interface VoiceApprovalBridgeDependencies {
  now?: () => number;
  activeControllerLease: (callId: string) => VoiceControllerLease | undefined;
  respondToUIRequest: (
    sessionId: string,
    response: ExtensionUIResponse,
  ) => boolean | Promise<boolean>;
  /** The host supplies a durable append-only sink; raw transcripts are never included. */
  appendReceipt: (receipt: VoiceApprovalReceipt) => void;
  nextChallengeId: () => string;
  nextNonce: () => string;
  nextReceiptId: () => string;
}

interface StoredChallenge {
  challenge: VoiceApprovalChallenge;
  consumed: boolean;
}

const MAX_CHALLENGE_LIFETIME_MS = 10_000;

/**
 * Deterministic authority bridge for spoken decisions.
 *
 * It accepts bindings only from a structured permission-gate producer, never
 * infers authority from extension dialog labels, and forwards successful
 * decisions through the existing extension UI response path.
 */
export class VoiceApprovalBridge {
  private readonly bindings = new Map<string, VoiceApprovalBinding>();
  private readonly challenges = new Map<string, StoredChallenge>();
  private readonly now: () => number;

  constructor(private readonly deps: VoiceApprovalBridgeDependencies) {
    this.now = deps.now ?? Date.now;
  }

  registerBinding(input: {
    source: "structured_permission_gate";
    sessionId: string;
    requestId: string;
    canonicalAction: Record<string, unknown>;
    targetRefs: readonly string[];
    policyRevision: string;
    risk: VoiceApprovalRisk;
    expiresAt: number;
    responses: {
      approveOnce: Omit<ExtensionUIResponse, "type" | "id">;
      deny: Omit<ExtensionUIResponse, "type" | "id">;
    };
  }): VoiceApprovalBinding {
    assertNonEmpty(input.sessionId, "sessionId");
    assertNonEmpty(input.requestId, "requestId");
    assertNonEmpty(input.policyRevision, "policyRevision");
    if (input.source !== "structured_permission_gate") {
      throw new Error("Voice approval requires a structured permission gate");
    }
    if (!Number.isFinite(input.expiresAt)) {
      throw new Error("Voice approval binding expiresAt must be finite");
    }
    if (input.targetRefs.length === 0 || input.targetRefs.some((value) => !value.trim())) {
      throw new Error("Voice approval binding requires canonical targets");
    }
    validateResponse(input.responses.approveOnce, "approveOnce");
    validateResponse(input.responses.deny, "deny");

    const targetRefs = Object.freeze([...input.targetRefs]);
    const digestInput = {
      version: 1,
      sessionId: input.sessionId,
      requestId: input.requestId,
      canonicalAction: input.canonicalAction,
      targetRefs,
      policyRevision: input.policyRevision,
      risk: input.risk,
      responses: input.responses,
    };
    const actionDigest = createHash("sha256").update(canonicalJson(digestInput)).digest("hex");
    const binding = Object.freeze({
      source: input.source,
      sessionId: input.sessionId,
      requestId: input.requestId,
      actionDigest,
      targetRefs,
      policyRevision: input.policyRevision,
      risk: input.risk,
      expiresAt: input.expiresAt,
      responses: Object.freeze({
        approveOnce: Object.freeze({ ...input.responses.approveOnce }),
        deny: Object.freeze({ ...input.responses.deny }),
      }),
    }) satisfies VoiceApprovalBinding;
    this.bindings.set(bindingKey(input.sessionId, input.requestId), binding);
    return binding;
  }

  issueChallenge(input: {
    callId: string;
    sessionId: string;
    requestId: string;
  }): VoiceApprovalChallenge {
    const now = this.now();
    const binding = this.bindings.get(bindingKey(input.sessionId, input.requestId));
    if (!binding || binding.expiresAt <= now) {
      throw new Error("Voice approval binding is missing or expired");
    }
    if (binding.risk === "secondary_confirmation_required") {
      throw new Error("Voice approval requires secondary confirmation");
    }
    if (binding.risk !== "voice_eligible") {
      throw new Error("Action is not voice eligible");
    }

    const lease = this.deps.activeControllerLease(input.callId);
    if (!lease || lease.callId !== input.callId || lease.expiresAt <= now) {
      throw new Error("Active voice controller lease is required");
    }

    const challengeId = this.deps.nextChallengeId().trim();
    const nonce = this.deps.nextNonce().trim();
    if (!challengeId || this.challenges.has(challengeId) || !nonce) {
      throw new Error("Voice approval challenge identity must be unique and non-empty");
    }
    const challenge = Object.freeze({
      challengeId,
      callId: input.callId,
      controllerLeaseId: lease.leaseId,
      controllerLeaseEpoch: lease.epoch,
      deviceId: lease.deviceId,
      sessionId: input.sessionId,
      requestId: input.requestId,
      actionDigest: binding.actionDigest,
      targetRefs: binding.targetRefs,
      nonce,
      issuedAt: now,
      expiresAt: Math.min(binding.expiresAt, lease.expiresAt, now + MAX_CHALLENGE_LIFETIME_MS),
    }) satisfies VoiceApprovalChallenge;
    this.challenges.set(challenge.challengeId, { challenge, consumed: false });
    return challenge;
  }

  async submitTranscript(
    input: {
      challengeId: string;
      callId: string;
      leaseEpoch: number;
      requestId: string;
      actionDigest: string;
      nonce: string;
      transcript: string;
    },
    authority: { authenticatedDeviceId: string },
  ): Promise<VoiceApprovalSubmissionResult> {
    const stored = this.challenges.get(input.challengeId);
    if (!stored) return { kind: "rejected", reason: "unknown_challenge" };
    if (stored.consumed) return { kind: "rejected", reason: "challenge_consumed" };

    const { challenge } = stored;
    const now = this.now();
    if (challenge.expiresAt <= now) {
      stored.consumed = true;
      return { kind: "rejected", reason: "challenge_expired" };
    }
    if (
      input.callId !== challenge.callId ||
      input.leaseEpoch !== challenge.controllerLeaseEpoch ||
      input.requestId !== challenge.requestId ||
      input.actionDigest !== challenge.actionDigest ||
      input.nonce !== challenge.nonce
    ) {
      return { kind: "rejected", reason: "challenge_mismatch" };
    }
    if (authority.authenticatedDeviceId !== challenge.deviceId) {
      return { kind: "rejected", reason: "wrong_device" };
    }

    const lease = this.deps.activeControllerLease(challenge.callId);
    if (
      !lease ||
      lease.callId !== challenge.callId ||
      lease.expiresAt <= now ||
      lease.leaseId !== challenge.controllerLeaseId ||
      lease.epoch !== challenge.controllerLeaseEpoch ||
      lease.deviceId !== authority.authenticatedDeviceId
    ) {
      return { kind: "rejected", reason: "stale_controller_lease" };
    }

    const binding = this.bindings.get(bindingKey(challenge.sessionId, challenge.requestId));
    if (
      !binding ||
      binding.actionDigest !== challenge.actionDigest ||
      binding.expiresAt <= now ||
      binding.risk !== "voice_eligible"
    ) {
      stored.consumed = true;
      return { kind: "rejected", reason: "action_changed" };
    }

    // Once the correct controller submits speech for an armed challenge, rotate
    // the nonce for every outcome. Ambiguity and detail requests cannot be
    // replayed later as authorization.
    stored.consumed = true;
    const decision = parseVoiceApprovalDecision(input.transcript);
    if (!decision) {
      this.appendReceipt(challenge, authority.authenticatedDeviceId, {
        validationOutcome: "rejected",
        deliveryOutcome: "not_attempted",
        decision: "repeat",
        reason: "ambiguous_decision",
      });
      return { kind: "rejected", reason: "ambiguous_decision" };
    }
    if (decision === "tell_me_more" || decision === "repeat") {
      this.appendReceipt(challenge, authority.authenticatedDeviceId, {
        validationOutcome: "non_authorizing",
        deliveryOutcome: "not_attempted",
        decision,
        reason: decision,
      });
      return { kind: "retry", reason: decision };
    }

    const mapped =
      decision === "approve_once" ? binding.responses.approveOnce : binding.responses.deny;
    const response: ExtensionUIResponse = {
      type: "extension_ui_response",
      id: binding.requestId,
      ...mapped,
    };
    const delivered = await this.deps.respondToUIRequest(binding.sessionId, response);
    this.appendReceipt(challenge, authority.authenticatedDeviceId, {
      validationOutcome: "accepted",
      deliveryOutcome: delivered ? "delivered" : "failed",
      decision,
      ...(!delivered ? { reason: "delivery_failed" } : {}),
    });
    return delivered
      ? { kind: "delivered", decision }
      : { kind: "rejected", reason: "delivery_failed" };
  }

  private appendReceipt(
    challenge: VoiceApprovalChallenge,
    deviceId: string,
    outcome: Pick<
      VoiceApprovalReceipt,
      "decision" | "validationOutcome" | "deliveryOutcome" | "reason"
    >,
  ): void {
    this.deps.appendReceipt({
      receiptId: this.deps.nextReceiptId(),
      challengeId: challenge.challengeId,
      callId: challenge.callId,
      controllerLeaseId: challenge.controllerLeaseId,
      controllerLeaseEpoch: challenge.controllerLeaseEpoch,
      deviceId,
      sessionId: challenge.sessionId,
      requestId: challenge.requestId,
      actionDigest: challenge.actionDigest,
      targetRefs: challenge.targetRefs,
      decision: outcome.decision,
      receivedAt: this.now(),
      validationOutcome: outcome.validationOutcome,
      deliveryOutcome: outcome.deliveryOutcome,
      ...(outcome.reason ? { reason: outcome.reason } : {}),
    });
  }
}

export function parseVoiceApprovalDecision(transcript: string): VoiceApprovalDecision | undefined {
  const normalized = transcript
    .normalize("NFKC")
    .trim()
    .toLowerCase()
    .replace(/[.!?,;:]+$/g, "")
    .replace(/\s+/g, " ");
  switch (normalized) {
    case "approve once":
      return "approve_once";
    case "deny":
      return "deny";
    case "tell me more":
      return "tell_me_more";
    case "repeat":
      return "repeat";
    default:
      return undefined;
  }
}

function bindingKey(sessionId: string, requestId: string): string {
  return `${sessionId}\0${requestId}`;
}

function assertNonEmpty(value: string, field: string): void {
  if (!value.trim()) throw new Error(`Voice approval ${field} must not be empty`);
}

function validateResponse(response: Omit<ExtensionUIResponse, "type" | "id">, field: string): void {
  const keys = Object.keys(response);
  const key = keys[0];
  if (keys.length !== 1 || (key !== "value" && key !== "confirmed" && key !== "cancelled")) {
    throw new Error(`Voice approval ${field} must contain one exact structured response`);
  }
  if (key === "value" && typeof response.value !== "string") {
    throw new Error(`Voice approval ${field} value must be a string`);
  }
  if (key === "confirmed" && typeof response.confirmed !== "boolean") {
    throw new Error(`Voice approval ${field} confirmed must be boolean`);
  }
  if (key === "cancelled" && typeof response.cancelled !== "boolean") {
    throw new Error(`Voice approval ${field} cancelled must be boolean`);
  }
}

function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value))
      throw new Error("Canonical approval actions require finite numbers");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item)).join(",")}]`;
  }
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`)
      .join(",")}}`;
  }
  throw new Error("Canonical approval actions must contain JSON values only");
}

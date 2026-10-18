import type {
  ServerMessage,
  VoiceApprovalRequiredMessage,
  VoiceApprovalResultMessage,
  VoiceCallDelegationSnapshot,
  VoiceCallDelegationState,
  VoiceCallDelegationUpdateKind,
  VoiceCallStateSnapshot,
  VoiceDelegationUpdateMessage,
} from "./types.js";
import type {
  VoiceApprovalChallenge,
  VoiceApprovalSubmissionResult,
  VoiceControllerLease,
} from "./voice-approval-bridge.js";
import type { VoiceDelegation, VoiceDelegationUpdate } from "./continuous-voice.js";

const DEFAULT_LEASE_DURATION_MS = 30_000;
const DEFAULT_RETENTION_GRACE_MS = 30_000;
const MAX_REPLAY_EVENTS = 128;
const MAX_RETAINED_CALLS = 256;
const MAX_DELEGATIONS_PER_CALL = 256;
const MAX_PENDING_APPROVALS_PER_CALL = 16;
const MAX_IDENTIFIER_LENGTH = 128;
const MAX_DELEGATION_TEXT_LENGTH = 10_000;
const MAX_UPDATE_TEXT_LENGTH = 2_000;
const MAX_APPROVAL_SUMMARY_LENGTH = 1_000;
const MAX_APPROVAL_TRANSCRIPT_LENGTH = 256;

export interface VoiceCallFrontendConnection {
  connectionId: string;
  authenticatedDeviceId: string;
  send: (message: ServerMessage) => void;
  sendAudio?: (pcm: Buffer) => void;
}

export interface VoiceCallAttachResult {
  state: VoiceCallStateSnapshot;
  replay: VoiceCallEventMessage[];
}

export interface VoiceCallApprovalAuthority {
  submitTranscript(
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
  ): VoiceApprovalSubmissionResult | Promise<VoiceApprovalSubmissionResult>;
}

export type VoiceCallEventMessage =
  | VoiceDelegationUpdateMessage
  | VoiceApprovalRequiredMessage
  | VoiceApprovalResultMessage;

export interface PersistedVoiceCall {
  callId: string;
  controlSessionId: string;
  clientCallId: string;
  ownerDeviceId: string;
  lifecycle: "active" | "ended";
  detachedAt?: number;
  controllerLeaseEpoch: number;
  controllerLeaseExpiresAt: number;
  eventSeq: number;
  startedAt: number;
  updatedAt: number;
  delegations: VoiceCallDelegationSnapshot[];
  events: VoiceCallEventMessage[];
}

export interface VoiceCallPersistence {
  load(): readonly PersistedVoiceCall[];
  save(calls: readonly PersistedVoiceCall[]): void;
}

interface MutableVoiceCall {
  callId: string;
  controlSessionId: string;
  clientCallId: string;
  ownerDeviceId: string;
  lifecycle: "active" | "ended";
  frontendConnection?: VoiceCallFrontendConnection;
  detachedAt?: number;
  controllerLeaseEpoch: number;
  controllerLeaseExpiresAt: number;
  eventSeq: number;
  startedAt: number;
  updatedAt: number;
  delegations: Map<string, MutableVoiceDelegation>;
  pendingApprovals: Map<string, PendingVoiceApproval>;
  events: VoiceCallEventMessage[];
  partialTranscript?: string;
}

type MutableVoiceDelegation = VoiceCallDelegationSnapshot;

interface PendingVoiceApproval {
  challenge: VoiceApprovalChallenge;
  summary: string;
  presentationEventSeq: number;
}

/**
 * Server-owned provider-neutral call control state.
 *
 * The durable Pi control session is identified separately from its current
 * media/frontend attachment. Dropping or replacing a frontend fences the old
 * lease generation without ending the call or discarding delegation state.
 */
export class VoiceCallController {
  private readonly calls = new Map<string, MutableVoiceCall>();
  private readonly callsByClientIdentity = new Map<string, string>();
  private readonly now: () => number;
  private readonly leaseDurationMs: number;
  private readonly retentionGraceMs: number;
  private readonly maxRetainedCalls: number;

  constructor(
    private readonly deps: {
      nextCallId: () => string;
      now?: () => number;
      leaseDurationMs?: number;
      retentionGraceMs?: number;
      maxRetainedCalls?: number;
      approvalAuthority?: VoiceCallApprovalAuthority;
      persistence?: VoiceCallPersistence;
      dispatchDelegation?: (controlSessionId: string, delegation: VoiceDelegation) => void;
    },
  ) {
    this.now = deps.now ?? Date.now;
    this.leaseDurationMs = deps.leaseDurationMs ?? DEFAULT_LEASE_DURATION_MS;
    if (!Number.isFinite(this.leaseDurationMs) || this.leaseDurationMs <= 0) {
      throw new Error("Voice controller lease duration must be positive and finite");
    }
    this.retentionGraceMs = deps.retentionGraceMs ?? DEFAULT_RETENTION_GRACE_MS;
    if (!Number.isFinite(this.retentionGraceMs) || this.retentionGraceMs <= 0) {
      throw new Error("Voice call retention grace must be positive and finite");
    }
    this.maxRetainedCalls = deps.maxRetainedCalls ?? MAX_RETAINED_CALLS;
    if (!Number.isSafeInteger(this.maxRetainedCalls) || this.maxRetainedCalls <= 0) {
      throw new Error("Voice call retention capacity must be a positive safe integer");
    }
    this.restorePersistedCalls();
  }

  startCall(
    input: { controlSessionId: string; clientCallId: string },
    frontend: VoiceCallFrontendConnection,
  ): VoiceCallAttachResult {
    assertIdentifier(input.controlSessionId, "controlSessionId");
    assertIdentifier(input.clientCallId, "clientCallId");
    validateFrontend(frontend);

    const identityKey = clientIdentityKey(
      input.controlSessionId,
      frontend.authenticatedDeviceId,
      input.clientCallId,
    );
    const existingId = this.callsByClientIdentity.get(identityKey);
    if (existingId) {
      const existing = this.requireCall(existingId);
      if (existing.lifecycle !== "active") {
        throw new Error("Voice call identity already belongs to an ended call");
      }
      return this.attachCall({ callId: existing.callId }, frontend);
    }

    this.pruneReclaimableCalls();
    for (const call of this.calls.values()) {
      if (
        call.lifecycle === "active" &&
        call.controlSessionId === input.controlSessionId &&
        call.ownerDeviceId === frontend.authenticatedDeviceId
      ) {
        // A fresh clientCallId after leave/reconnect must re-enter the live
        // call. Ended identities stay reserved and still cannot be reused.
        return this.attachCall({ callId: call.callId }, frontend);
      }
    }
    if (this.calls.size >= this.maxRetainedCalls) {
      throw new Error("Voice call capacity is reached");
    }

    const callId = this.deps.nextCallId().trim();
    if (!callId || callId.length > MAX_IDENTIFIER_LENGTH || this.calls.has(callId)) {
      throw new Error("Voice call identity must be unique and non-empty");
    }
    const now = this.now();
    const call: MutableVoiceCall = {
      callId,
      controlSessionId: input.controlSessionId,
      clientCallId: input.clientCallId,
      ownerDeviceId: frontend.authenticatedDeviceId,
      lifecycle: "active",
      frontendConnection: frontend,
      controllerLeaseEpoch: 1,
      controllerLeaseExpiresAt: now + this.leaseDurationMs,
      eventSeq: 1,
      startedAt: now,
      updatedAt: now,
      delegations: new Map(),
      pendingApprovals: new Map(),
      events: [],
    };
    this.calls.set(call.callId, call);
    this.callsByClientIdentity.set(identityKey, call.callId);
    this.persist();
    return { state: this.snapshot(call.callId), replay: [] };
  }

  attachCall(
    input: { callId: string; lastEventSeq?: number },
    frontend: VoiceCallFrontendConnection,
  ): VoiceCallAttachResult {
    validateFrontend(frontend);
    const call = this.requireActiveCall(input.callId);
    this.assertOwnerDevice(call, frontend.authenticatedDeviceId);
    const lastEventSeq = input.lastEventSeq;
    if (lastEventSeq !== undefined && (!Number.isSafeInteger(lastEventSeq) || lastEventSeq < 0)) {
      throw new Error("Voice call lastEventSeq must be a non-negative safe integer");
    }

    const now = this.now();
    if (
      call.frontendConnection?.connectionId !== frontend.connectionId ||
      call.controllerLeaseExpiresAt <= now
    ) {
      this.advanceLeaseGeneration(call);
    }
    call.frontendConnection = frontend;
    call.detachedAt = undefined;
    this.renewLease(call);
    this.pruneExpiredApprovals(call);

    const replay =
      lastEventSeq === undefined
        ? []
        : call.events
            .filter(
              (event) => event.eventSeq > lastEventSeq && this.isReplayableEvent(call, event, now),
            )
            .map(cloneEvent);
    this.persist();
    return { state: this.snapshot(call.callId), replay };
  }

  detachCall(
    input: { callId: string; controllerLeaseEpoch: number },
    frontend: Pick<VoiceCallFrontendConnection, "connectionId" | "authenticatedDeviceId">,
  ): VoiceCallStateSnapshot {
    const call = this.requireActiveCall(input.callId);
    this.assertController(call, input.controllerLeaseEpoch, frontend);
    this.detach(call);
    this.persist();
    return this.snapshot(call.callId);
  }

  keepAlive(
    input: { callId: string; controllerLeaseEpoch: number },
    frontend: Pick<VoiceCallFrontendConnection, "connectionId" | "authenticatedDeviceId">,
  ): VoiceCallStateSnapshot {
    const call = this.requireActiveCall(input.callId);
    this.assertController(call, input.controllerLeaseEpoch, frontend);
    call.eventSeq += 1;
    this.renewLease(call);
    this.persist();
    return this.snapshot(call.callId);
  }

  endCall(
    input: { callId: string; controllerLeaseEpoch: number },
    frontend: Pick<VoiceCallFrontendConnection, "connectionId" | "authenticatedDeviceId">,
  ): VoiceCallStateSnapshot {
    const call = this.requireActiveCall(input.callId);
    this.assertController(call, input.controllerLeaseEpoch, frontend);
    call.lifecycle = "ended";
    call.frontendConnection = undefined;
    call.controllerLeaseEpoch += 1;
    call.controllerLeaseExpiresAt = this.now();
    call.eventSeq += 1;
    call.updatedAt = this.now();
    call.pendingApprovals.clear();
    this.persist();
    return this.snapshot(call.callId);
  }

  disconnectConnection(connectionId: string): void {
    let changed = false;
    for (const call of this.calls.values()) {
      if (call.lifecycle === "active" && call.frontendConnection?.connectionId === connectionId) {
        this.detach(call);
        changed = true;
      }
    }
    if (changed) this.persist();
  }

  snapshot(callId: string): VoiceCallStateSnapshot {
    const call = this.requireCall(callId);
    this.pruneExpiredApprovals(call);
    return {
      callId: call.callId,
      controlSessionId: call.controlSessionId,
      lifecycle: call.lifecycle,
      frontend: call.frontendConnection ? "attached" : "detached",
      controllerLeaseEpoch: call.controllerLeaseEpoch,
      controllerLeaseExpiresAt: call.controllerLeaseExpiresAt,
      eventSeq: call.eventSeq,
      startedAt: call.startedAt,
      updatedAt: call.updatedAt,
      delegations: [...call.delegations.values()].map((delegation) => ({ ...delegation })),
      ...(call.partialTranscript !== undefined
        ? { partialTranscript: call.partialTranscript }
        : {}),
      pendingApprovals: [...call.pendingApprovals.values()].map(({ challenge, summary }) => ({
        challengeId: challenge.challengeId,
        requestId: challenge.requestId,
        summary,
        targetRefs: [...challenge.targetRefs],
        expiresAt: challenge.expiresAt,
      })),
    };
  }

  activeAttachedCallId(): string | undefined {
    const now = this.now();
    let found: string | undefined;
    for (const call of this.calls.values()) {
      if (
        call.lifecycle !== "active" ||
        !call.frontendConnection ||
        call.controllerLeaseExpiresAt <= now
      ) {
        continue;
      }
      if (found) return undefined;
      found = call.callId;
    }
    return found;
  }

  activeCallIdForControlSession(controlSessionId: string): string | undefined {
    for (const call of this.calls.values()) {
      if (call.lifecycle === "active" && call.controlSessionId === controlSessionId) {
        return call.callId;
      }
    }
    return undefined;
  }

  activeControllerLease(callId: string): VoiceControllerLease | undefined {
    const call = this.calls.get(callId);
    const now = this.now();
    if (
      !call ||
      call.lifecycle !== "active" ||
      !call.frontendConnection ||
      call.controllerLeaseExpiresAt <= now
    ) {
      return undefined;
    }
    return {
      callId: call.callId,
      leaseId: leaseId(call),
      epoch: call.controllerLeaseEpoch,
      deviceId: call.ownerDeviceId,
      expiresAt: call.controllerLeaseExpiresAt,
    };
  }

  setPartialTranscript(callId: string, text: string): VoiceCallStateSnapshot {
    const call = this.requireActiveCall(callId);
    const trimmed = text.trim();
    call.partialTranscript = trimmed || undefined;
    call.updatedAt = this.now();
    return this.snapshot(callId);
  }

  commitFrontendUtterance(input: {
    callId: string;
    controllerLeaseEpoch: number;
    frontendConnectionId: string;
    utteranceId: string;
    delegationId: string;
    request: string;
  }): VoiceDelegationUpdateMessage {
    const call = this.requireActiveCall(input.callId);
    const frontend = call.frontendConnection;
    if (
      input.controllerLeaseEpoch !== call.controllerLeaseEpoch ||
      !frontend ||
      frontend.connectionId !== input.frontendConnectionId ||
      call.controllerLeaseExpiresAt <= this.now()
    ) {
      throw new Error("Stale voice controller lease");
    }
    assertIdentifier(input.utteranceId, "utteranceId");
    assertIdentifier(input.delegationId, "delegationId");
    const request = input.request.trim();
    if (!request || request.length > MAX_DELEGATION_TEXT_LENGTH) {
      throw new Error("Voice delegation request must be non-empty and bounded");
    }
    if (call.delegations.has(input.delegationId)) {
      throw new Error(`Duplicate voice delegation: ${input.delegationId}`);
    }
    if (call.delegations.size >= MAX_DELEGATIONS_PER_CALL) {
      throw new Error("Voice delegation capacity is reached");
    }

    call.partialTranscript = undefined;
    const createdAt = this.now();
    const delegation = {
      callId: call.callId,
      delegationId: input.delegationId,
      utteranceId: input.utteranceId,
      request,
      createdAt,
    };
    this.deps.dispatchDelegation?.(call.controlSessionId, delegation);
    call.delegations.set(input.delegationId, {
      ...delegation,
      state: "delegated",
    });
    const message = this.emitDelegationUpdate(call, {
      delegationId: input.delegationId,
      utteranceId: input.utteranceId,
      kind: "delegated",
      text: request,
      createdAt,
    });
    this.persist();
    return message;
  }

  applyDelegationUpdate(
    callId: string,
    update: VoiceDelegationUpdate,
  ): VoiceDelegationUpdateMessage {
    const call = this.requireActiveCall(callId);
    const delegation = call.delegations.get(update.delegationId);
    if (!delegation) throw new Error(`Unknown voice delegation: ${update.delegationId}`);
    if (delegation.state === "completed") {
      throw new Error(`Voice delegation ${update.delegationId} is already completed`);
    }
    const text = update.text.trim();
    if (!text || text.length > MAX_UPDATE_TEXT_LENGTH) {
      throw new Error("Voice delegation update text must be non-empty and bounded");
    }

    delegation.state = delegationStateFor(update.kind);
    delegation.latestText = text;
    const message = this.emitDelegationUpdate(call, {
      delegationId: delegation.delegationId,
      utteranceId: delegation.utteranceId,
      kind: update.kind,
      text,
      createdAt: this.now(),
    });
    this.persist();
    return message;
  }

  presentApproval(
    callId: string,
    input: { challenge: VoiceApprovalChallenge; summary: string },
  ): VoiceApprovalRequiredMessage {
    const call = this.requireActiveCall(callId);
    if (!this.deps.approvalAuthority) {
      throw new Error("Voice approval authority is unavailable");
    }
    const summary = input.summary.trim();
    if (!summary || summary.length > MAX_APPROVAL_SUMMARY_LENGTH) {
      throw new Error("Voice approval summary must be non-empty and bounded");
    }
    const { challenge } = input;
    if (
      challenge.callId !== call.callId ||
      challenge.controllerLeaseId !== leaseId(call) ||
      challenge.controllerLeaseEpoch !== call.controllerLeaseEpoch ||
      challenge.deviceId !== call.ownerDeviceId
    ) {
      throw new Error("Voice approval challenge does not match the active controller lease");
    }
    if (challenge.expiresAt <= this.now()) {
      throw new Error("Voice approval challenge is expired");
    }
    this.pruneExpiredApprovals(call);
    if (call.pendingApprovals.has(challenge.challengeId)) {
      throw new Error(`Duplicate voice approval challenge: ${challenge.challengeId}`);
    }
    if (call.pendingApprovals.size >= MAX_PENDING_APPROVALS_PER_CALL) {
      throw new Error("Voice approval capacity is reached");
    }

    const message: VoiceApprovalRequiredMessage = {
      type: "voice_approval_required",
      callId: call.callId,
      controlSessionId: call.controlSessionId,
      eventSeq: this.nextEventSeq(call),
      challengeId: challenge.challengeId,
      requestId: challenge.requestId,
      summary,
      targetRefs: [...challenge.targetRefs],
      expiresAt: challenge.expiresAt,
    };
    call.pendingApprovals.set(challenge.challengeId, {
      challenge,
      summary,
      presentationEventSeq: message.eventSeq,
    });
    this.publish(call, message);
    this.persist();
    return cloneEvent(message);
  }

  async submitApprovalTranscript(
    input: {
      callId: string;
      controllerLeaseEpoch: number;
      challengeId: string;
      transcript: string;
    },
    frontend: Pick<VoiceCallFrontendConnection, "connectionId" | "authenticatedDeviceId">,
  ): Promise<VoiceApprovalSubmissionResult> {
    const call = this.requireActiveCall(input.callId);
    this.assertController(call, input.controllerLeaseEpoch, frontend);
    assertIdentifier(input.challengeId, "challengeId");
    const transcript = input.transcript.trim();
    if (!transcript || transcript.length > MAX_APPROVAL_TRANSCRIPT_LENGTH) {
      throw new Error("Voice approval transcript must be non-empty and bounded");
    }
    const pending = call.pendingApprovals.get(input.challengeId);
    if (!pending) throw new Error("Voice approval challenge is not pending");
    if (pending.challenge.expiresAt <= this.now()) {
      call.pendingApprovals.delete(input.challengeId);
      this.persist();
      throw new Error("Voice approval challenge is expired");
    }
    if (!this.deps.approvalAuthority) {
      throw new Error("Voice approval authority is unavailable");
    }

    // Remove before authority delivery so transport retries cannot replay an
    // authorizing transcript even if the downstream response path fails.
    call.pendingApprovals.delete(input.challengeId);
    const challenge = pending.challenge;
    const result = await this.deps.approvalAuthority.submitTranscript(
      {
        challengeId: challenge.challengeId,
        callId: challenge.callId,
        leaseEpoch: challenge.controllerLeaseEpoch,
        requestId: challenge.requestId,
        actionDigest: challenge.actionDigest,
        nonce: challenge.nonce,
        transcript,
      },
      { authenticatedDeviceId: frontend.authenticatedDeviceId },
    );
    const message: VoiceApprovalResultMessage = {
      type: "voice_approval_result",
      callId: call.callId,
      controlSessionId: call.controlSessionId,
      eventSeq: this.nextEventSeq(call),
      challengeId: challenge.challengeId,
      outcome: result.kind,
      ...(result.kind === "delivered" ? { decision: result.decision } : {}),
      ...(result.kind !== "delivered" ? { reason: result.reason } : {}),
    };
    this.publish(call, message);
    this.persist();
    return result;
  }

  private emitDelegationUpdate(
    call: MutableVoiceCall,
    input: {
      delegationId: string;
      utteranceId: string;
      kind: VoiceCallDelegationUpdateKind;
      text: string;
      createdAt: number;
    },
  ): VoiceDelegationUpdateMessage {
    const message: VoiceDelegationUpdateMessage = {
      type: "voice_delegation_update",
      callId: call.callId,
      controlSessionId: call.controlSessionId,
      eventSeq: this.nextEventSeq(call),
      ...input,
    };
    this.publish(call, message);
    return cloneEvent(message);
  }

  private publish(call: MutableVoiceCall, message: VoiceCallEventMessage): void {
    call.events.push(cloneEvent(message));
    if (call.events.length > MAX_REPLAY_EVENTS) call.events.shift();
    const frontend = call.frontendConnection;
    if (!frontend) return;
    try {
      frontend.send(cloneEvent(message));
    } catch {
      // A failed transport cannot roll back durable control state. Fence that
      // attachment and let the same paired device reconnect to the snapshot.
      if (call.frontendConnection?.connectionId === frontend.connectionId) {
        this.detach(call);
      }
    }
  }

  private nextEventSeq(call: MutableVoiceCall): number {
    call.eventSeq += 1;
    call.updatedAt = this.now();
    return call.eventSeq;
  }

  private renewLease(call: MutableVoiceCall): void {
    const now = this.now();
    call.controllerLeaseExpiresAt = now + this.leaseDurationMs;
    call.updatedAt = now;
  }

  private detach(call: MutableVoiceCall): void {
    const now = this.now();
    call.frontendConnection = undefined;
    call.detachedAt = now;
    this.advanceLeaseGeneration(call);
    call.controllerLeaseExpiresAt = now;
    call.updatedAt = now;
  }

  private advanceLeaseGeneration(call: MutableVoiceCall): void {
    // Approval challenges are bound to one exact lease generation. A reconnect
    // must obtain a fresh challenge rather than presenting an unusable stale one.
    call.pendingApprovals.clear();
    call.controllerLeaseEpoch += 1;
    call.eventSeq += 1;
  }

  private restorePersistedCalls(): void {
    const persistence = this.deps.persistence;
    if (!persistence) return;
    const records = persistence.load();
    if (records.length === 0) return;
    for (const record of records) {
      const call = hydratePersistedCall(record);
      if (this.calls.has(call.callId)) {
        throw new Error("Voice call identity must be unique and non-empty");
      }
      if (call.lifecycle === "active") {
        this.detach(call);
      }
      this.calls.set(call.callId, call);
      this.callsByClientIdentity.set(
        clientIdentityKey(call.controlSessionId, call.ownerDeviceId, call.clientCallId),
        call.callId,
      );
    }
    this.persist();
  }

  private persist(): void {
    this.deps.persistence?.save(this.serializeCalls());
  }

  private serializeCalls(): PersistedVoiceCall[] {
    return [...this.calls.values()].map((call) => ({
      callId: call.callId,
      controlSessionId: call.controlSessionId,
      clientCallId: call.clientCallId,
      ownerDeviceId: call.ownerDeviceId,
      lifecycle: call.lifecycle,
      ...(call.detachedAt !== undefined ? { detachedAt: call.detachedAt } : {}),
      controllerLeaseEpoch: call.controllerLeaseEpoch,
      controllerLeaseExpiresAt: call.controllerLeaseExpiresAt,
      eventSeq: call.eventSeq,
      startedAt: call.startedAt,
      updatedAt: call.updatedAt,
      delegations: [...call.delegations.values()].map((delegation) => ({ ...delegation })),
      events: call.events.map(cloneEvent),
    }));
  }

  private isReplayableEvent(
    call: MutableVoiceCall,
    event: VoiceCallEventMessage,
    now: number,
  ): boolean {
    if (event.type !== "voice_approval_required") return true;
    const pending = call.pendingApprovals.get(event.challengeId);
    return (
      pending !== undefined &&
      pending.presentationEventSeq === event.eventSeq &&
      pending.challenge.expiresAt > now
    );
  }

  private pruneExpiredApprovals(call: MutableVoiceCall): void {
    const now = this.now();
    for (const [challengeId, pending] of call.pendingApprovals) {
      if (pending.challenge.expiresAt <= now) call.pendingApprovals.delete(challengeId);
    }
  }

  private assertOwnerDevice(call: MutableVoiceCall, deviceId: string): void {
    if (call.ownerDeviceId !== deviceId) {
      throw new Error("Voice call belongs to a different paired device");
    }
  }

  private assertController(
    call: MutableVoiceCall,
    controllerLeaseEpoch: number,
    frontend: Pick<VoiceCallFrontendConnection, "connectionId" | "authenticatedDeviceId">,
  ): void {
    this.assertOwnerDevice(call, frontend.authenticatedDeviceId);
    if (
      !Number.isSafeInteger(controllerLeaseEpoch) ||
      controllerLeaseEpoch <= 0 ||
      controllerLeaseEpoch !== call.controllerLeaseEpoch ||
      call.frontendConnection?.connectionId !== frontend.connectionId ||
      call.controllerLeaseExpiresAt <= this.now()
    ) {
      throw new Error("Stale voice controller lease");
    }
  }

  private pruneReclaimableCalls(): void {
    if (this.calls.size < this.maxRetainedCalls) return;
    const now = this.now();
    let changed = false;
    for (const [callId, call] of this.calls) {
      const staleDetached =
        call.lifecycle === "active" &&
        !call.frontendConnection &&
        call.detachedAt !== undefined &&
        call.detachedAt + this.retentionGraceMs <= now;
      const staleExpiredAttachment =
        call.lifecycle === "active" &&
        call.frontendConnection !== undefined &&
        call.controllerLeaseExpiresAt + this.retentionGraceMs <= now;
      if (call.lifecycle !== "ended" && !staleDetached && !staleExpiredAttachment) continue;
      this.calls.delete(callId);
      this.callsByClientIdentity.delete(
        clientIdentityKey(call.controlSessionId, call.ownerDeviceId, call.clientCallId),
      );
      changed = true;
      if (this.calls.size < this.maxRetainedCalls) break;
    }
    if (changed) this.persist();
  }

  private requireActiveCall(callId: string): MutableVoiceCall {
    const call = this.requireCall(callId);
    if (call.lifecycle !== "active") throw new Error("Voice call has ended");
    return call;
  }

  private requireCall(callId: string): MutableVoiceCall {
    assertIdentifier(callId, "callId");
    const call = this.calls.get(callId);
    if (!call) throw new Error(`Unknown voice call: ${callId}`);
    return call;
  }
}

/** Deterministic transport/frontend fixture for provider-free controller tests. */
export class DeterministicVoiceCallFrontend {
  readonly messages: ServerMessage[] = [];
  readonly audio: Buffer[] = [];
  readonly connection: VoiceCallFrontendConnection;

  constructor(input: { connectionId: string; authenticatedDeviceId: string }) {
    this.connection = {
      ...input,
      send: (message) => this.messages.push(structuredClone(message)),
      sendAudio: (pcm) => this.audio.push(Buffer.from(pcm)),
    };
  }
}

function delegationStateFor(kind: VoiceDelegationUpdate["kind"]): VoiceCallDelegationState {
  switch (kind) {
    case "acknowledgement":
      return "acknowledged";
    case "progress":
      return "working";
    case "blocked":
      return "blocked";
    case "final":
      return "completed";
  }
}

function hydratePersistedCall(record: PersistedVoiceCall): MutableVoiceCall {
  assertIdentifier(record.callId, "callId");
  assertIdentifier(record.controlSessionId, "controlSessionId");
  assertIdentifier(record.clientCallId, "clientCallId");
  assertIdentifier(record.ownerDeviceId, "authenticatedDeviceId");
  if (record.lifecycle !== "active" && record.lifecycle !== "ended") {
    throw new Error("Voice call lifecycle must be active or ended");
  }
  if (!Number.isSafeInteger(record.controllerLeaseEpoch) || record.controllerLeaseEpoch <= 0) {
    throw new Error("Voice controller lease epoch must be a positive safe integer");
  }
  if (!Number.isFinite(record.controllerLeaseExpiresAt)) {
    throw new Error("Voice controller lease expiry must be finite");
  }
  if (!Number.isSafeInteger(record.eventSeq) || record.eventSeq < 0) {
    throw new Error("Voice call eventSeq must be a non-negative safe integer");
  }
  if (!Number.isFinite(record.startedAt) || !Number.isFinite(record.updatedAt)) {
    throw new Error("Voice call timestamps must be finite");
  }
  if (record.detachedAt !== undefined && !Number.isFinite(record.detachedAt)) {
    throw new Error("Voice call detachedAt must be finite");
  }
  if (!Array.isArray(record.delegations) || record.delegations.length > MAX_DELEGATIONS_PER_CALL) {
    throw new Error("Voice delegation capacity is reached");
  }
  if (!Array.isArray(record.events) || record.events.length > MAX_REPLAY_EVENTS) {
    throw new Error("Voice call replay is bounded");
  }

  const delegations = new Map<string, MutableVoiceDelegation>();
  for (const delegation of record.delegations) {
    assertIdentifier(delegation.delegationId, "delegationId");
    assertIdentifier(delegation.utteranceId, "utteranceId");
    const request = delegation.request.trim();
    if (!request || request.length > MAX_DELEGATION_TEXT_LENGTH) {
      throw new Error("Voice delegation request must be non-empty and bounded");
    }
    if (delegations.has(delegation.delegationId)) {
      throw new Error(`Duplicate voice delegation: ${delegation.delegationId}`);
    }
    delegations.set(delegation.delegationId, {
      delegationId: delegation.delegationId,
      utteranceId: delegation.utteranceId,
      request,
      state: delegation.state,
      createdAt: delegation.createdAt,
      ...(delegation.latestText !== undefined ? { latestText: delegation.latestText } : {}),
    });
  }

  return {
    callId: record.callId,
    controlSessionId: record.controlSessionId,
    clientCallId: record.clientCallId,
    ownerDeviceId: record.ownerDeviceId,
    lifecycle: record.lifecycle,
    ...(record.detachedAt !== undefined ? { detachedAt: record.detachedAt } : {}),
    controllerLeaseEpoch: record.controllerLeaseEpoch,
    controllerLeaseExpiresAt: record.controllerLeaseExpiresAt,
    eventSeq: record.eventSeq,
    startedAt: record.startedAt,
    updatedAt: record.updatedAt,
    delegations,
    pendingApprovals: new Map(),
    events: record.events.map(hydratePersistedEvent),
  };
}

function hydratePersistedEvent(event: VoiceCallEventMessage): VoiceCallEventMessage {
  if (!event || typeof event !== "object") {
    throw new Error("Voice call replay event is invalid");
  }
  if (
    event.type !== "voice_delegation_update" &&
    event.type !== "voice_approval_required" &&
    event.type !== "voice_approval_result"
  ) {
    throw new Error("Voice call replay event is invalid");
  }
  if (!Number.isSafeInteger(event.eventSeq) || event.eventSeq < 0) {
    throw new Error("Voice call eventSeq must be a non-negative safe integer");
  }
  assertIdentifier(event.callId, "callId");
  assertIdentifier(event.controlSessionId, "controlSessionId");
  return cloneEvent(event);
}

function clientIdentityKey(
  controlSessionId: string,
  deviceId: string,
  clientCallId: string,
): string {
  return `${controlSessionId}\0${deviceId}\0${clientCallId}`;
}

function leaseId(call: Pick<MutableVoiceCall, "callId" | "controllerLeaseEpoch">): string {
  return `${call.callId}:${call.controllerLeaseEpoch}`;
}

function assertIdentifier(value: string, field: string): void {
  if (!value.trim() || value.length > MAX_IDENTIFIER_LENGTH) {
    throw new Error(`Voice call ${field} must be non-empty and bounded`);
  }
}

function validateFrontend(frontend: VoiceCallFrontendConnection): void {
  assertIdentifier(frontend.connectionId, "connectionId");
  assertIdentifier(frontend.authenticatedDeviceId, "authenticatedDeviceId");
}

function cloneEvent<T extends VoiceCallEventMessage>(event: T): T {
  return structuredClone(event);
}

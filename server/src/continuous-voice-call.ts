import type {
  ServerMessage,
  VoiceCallDelegationSnapshot,
  VoiceCallDelegationState,
  VoiceCallDelegationUpdateKind,
  VoiceCallStateSnapshot,
  VoiceDelegationUpdateMessage,
} from "./types.js";

const DEFAULT_LEASE_DURATION_MS = 30_000;
const DEFAULT_RETENTION_GRACE_MS = 30_000;
const MAX_REPLAY_EVENTS = 128;
const MAX_RETAINED_CALLS = 256;
const MAX_DELEGATIONS_PER_CALL = 256;
const MAX_IDENTIFIER_LENGTH = 128;
const MAX_DELEGATION_TEXT_LENGTH = 10_000;
const MAX_UPDATE_TEXT_LENGTH = 2_000;

/** One thing the caller said, sent to the call's session as a message. */
export interface VoiceDelegation {
  callId: string;
  delegationId: string;
  utteranceId: string;
  request: string;
  createdAt: number;
}

export interface VoiceDelegationUpdate {
  delegationId: string;
  kind: "progress" | "final" | "blocked";
  text: string;
}

/** Owner tokens stay valid for ordinary APIs but never become voice controllers. */
export function authenticatedVoiceDeviceId(
  principal: { kind: "owner" } | { kind: "device"; deviceId: string },
): string | undefined {
  return principal.kind === "device" ? principal.deviceId : undefined;
}

export interface VoiceCallFrontendConnection {
  connectionId: string;
  authenticatedDeviceId: string;
  send: (message: ServerMessage) => void;
  sendAudio?: (pcm: Buffer) => void;
}

export interface VoiceCallAttachResult {
  state: VoiceCallStateSnapshot;
  replay: VoiceDelegationUpdateMessage[];
}

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
  events: VoiceDelegationUpdateMessage[];
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
  events: VoiceDelegationUpdateMessage[];
  partialTranscript?: string;
}

type MutableVoiceDelegation = VoiceCallDelegationSnapshot;

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
  /** Frontend connections whose access token expired; they may finish a call but not take one. */
  private readonly authExpiredConnections = new Set<string>();
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
    this.assertConnectionAuthorized(frontend);

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
    this.assertConnectionAuthorized(frontend);
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

    const replay =
      lastEventSeq === undefined
        ? []
        : call.events.filter((event) => event.eventSeq > lastEventSeq).map(cloneEvent);
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
    this.persist();
    return this.snapshot(call.callId);
  }

  /**
   * The connection's access token expired. A reconnect would restart the call's
   * voice backend, so a connection that is the live controller of an active call
   * stays open; it can no longer start or attach a call. Returns false once it
   * holds no live call, and the caller closes it.
   */
  holdPastAuthExpiry(connectionId: string): boolean {
    const now = this.now();
    for (const call of this.calls.values()) {
      if (
        call.lifecycle === "active" &&
        call.frontendConnection?.connectionId === connectionId &&
        call.controllerLeaseExpiresAt > now
      ) {
        this.authExpiredConnections.add(connectionId);
        return true;
      }
    }
    this.authExpiredConnections.delete(connectionId);
    return false;
  }

  /** The connection is the attached frontend of an active call. */
  isCallConnection(connectionId: string): boolean {
    for (const call of this.calls.values()) {
      if (call.lifecycle === "active" && call.frontendConnection?.connectionId === connectionId) {
        return true;
      }
    }
    return false;
  }

  /** Held past its token for a call: it may carry only that call. */
  isAuthExpired(connectionId: string): boolean {
    return this.authExpiredConnections.has(connectionId);
  }

  disconnectConnection(connectionId: string): void {
    this.authExpiredConnections.delete(connectionId);
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
      // Installed phones decode this non-optionally and never see a challenge.
      pendingApprovals: [],
    };
  }

  activeCallIdForControlSession(controlSessionId: string): string | undefined {
    for (const call of this.calls.values()) {
      if (call.lifecycle === "active" && call.controlSessionId === controlSessionId) {
        return call.callId;
      }
    }
    return undefined;
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

  /** The newest thing the caller said that the session has not finished answering. */
  latestOpenDelegationId(callId: string): string | undefined {
    const call = this.calls.get(callId);
    if (!call || call.lifecycle !== "active") return undefined;
    let latest: string | undefined;
    for (const delegation of call.delegations.values()) {
      if (delegation.state !== "completed") latest = delegation.delegationId;
    }
    return latest;
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

  private publish(call: MutableVoiceCall, message: VoiceDelegationUpdateMessage): void {
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

  private assertConnectionAuthorized(frontend: VoiceCallFrontendConnection): void {
    if (this.authExpiredConnections.has(frontend.connectionId)) {
      throw new Error("Access expired on this connection; reconnect to start a call");
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

function delegationStateFor(kind: VoiceDelegationUpdate["kind"]): VoiceCallDelegationState {
  switch (kind) {
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

  const events: VoiceDelegationUpdateMessage[] = [];
  for (const event of record.events) {
    const hydrated = hydratePersistedEvent(event);
    if (hydrated) events.push(hydrated);
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
    events,
  };
}

function hydratePersistedEvent(
  event: VoiceDelegationUpdateMessage,
): VoiceDelegationUpdateMessage | undefined {
  if (!event || typeof event !== "object") {
    throw new Error("Voice call replay event is invalid");
  }
  // A call file written before spoken approval was removed still holds approval events
  // nothing sends or replays: drop them rather than refusing to load the call.
  if (event.type !== "voice_delegation_update") {
    if (event.type === "voice_approval_required" || event.type === "voice_approval_result") {
      return undefined;
    }
    throw new Error("Voice call replay event is invalid");
  }
  // Same for the voice_update tool's acknowledgement kind: current phones cannot decode it.
  if ((event.kind as string) === "acknowledgement") return undefined;
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

function assertIdentifier(value: string, field: string): void {
  if (!value.trim() || value.length > MAX_IDENTIFIER_LENGTH) {
    throw new Error(`Voice call ${field} must be non-empty and bounded`);
  }
}

function validateFrontend(frontend: VoiceCallFrontendConnection): void {
  assertIdentifier(frontend.connectionId, "connectionId");
  assertIdentifier(frontend.authenticatedDeviceId, "authenticatedDeviceId");
}

function cloneEvent<T extends VoiceDelegationUpdateMessage>(event: T): T {
  return structuredClone(event);
}

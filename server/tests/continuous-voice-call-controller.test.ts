import { describe, expect, it, vi } from "vitest";

import {
  DeterministicVoiceCallFrontend,
  VoiceCallController,
  type PersistedVoiceCall,
  type VoiceCallPersistence,
} from "../src/continuous-voice-call.js";
import type { VoiceApprovalChallenge } from "../src/voice-approval-bridge.js";

function makeHarness(
  options: {
    leaseDurationMs?: number;
    maxRetainedCalls?: number;
    retentionGraceMs?: number;
  } = {},
) {
  let now = 1_000;
  let callSequence = 0;
  const approvalSubmissions: Array<{ input: unknown; authority: unknown }> = [];
  const controller = new VoiceCallController({
    now: () => now,
    nextCallId: () => `call-${++callSequence}`,
    leaseDurationMs: options.leaseDurationMs ?? 30_000,
    maxRetainedCalls: options.maxRetainedCalls,
    retentionGraceMs: options.retentionGraceMs,
    approvalAuthority: {
      submitTranscript: (input, authority) => {
        approvalSubmissions.push({ input, authority });
        return { kind: "delivered", decision: "approve_once" };
      },
    },
  });

  const frontend = (
    connectionId: string,
    authenticatedDeviceId = "paired-device-a",
  ): DeterministicVoiceCallFrontend =>
    new DeterministicVoiceCallFrontend({ connectionId, authenticatedDeviceId });

  return {
    controller,
    frontend,
    approvalSubmissions,
    setNow(value: number) {
      now = value;
    },
  };
}

function challenge(overrides: Partial<VoiceApprovalChallenge> = {}): VoiceApprovalChallenge {
  return {
    challengeId: "challenge-1",
    callId: "call-1",
    controllerLeaseId: "call-1:1",
    controllerLeaseEpoch: 1,
    deviceId: "paired-device-a",
    sessionId: "target-session-1",
    requestId: "approval-request-1",
    actionDigest: "digest-1",
    targetRefs: ["file:server/src/server.ts"],
    nonce: "nonce-1",
    issuedAt: 1_000,
    expiresAt: 9_000,
    ...overrides,
  };
}

describe("continuous voice call controller", () => {
  it("holds an expired connection open only while it controls a live call", () => {
    const { controller, frontend, setNow } = makeHarness();
    const phone = frontend("connection-a");
    const call = controller.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      phone.connection,
    ).state;

    expect(controller.holdPastAuthExpiry("connection-other")).toBe(false);
    expect(controller.holdPastAuthExpiry("connection-a")).toBe(true);
    // Past its token, the connection finishes this call but cannot take another.
    expect(() =>
      controller.startCall(
        { controlSessionId: "voice-2", clientCallId: "client-2" },
        phone.connection,
      ),
    ).toThrow("Access expired");
    expect(() => controller.attachCall({ callId: call.callId }, phone.connection)).toThrow(
      "Access expired",
    );

    // Keepalives keep the hold; a lapsed lease ends it.
    setNow(20_000);
    controller.keepAlive(call, phone.connection);
    setNow(40_000);
    expect(controller.holdPastAuthExpiry("connection-a")).toBe(true);
    setNow(80_000);
    expect(controller.holdPastAuthExpiry("connection-a")).toBe(false);
  });

  it("stops holding an expired connection once its call moves away or ends", () => {
    const { controller, frontend } = makeHarness();
    const first = frontend("connection-a");
    const call = controller.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      first.connection,
    ).state;
    expect(controller.holdPastAuthExpiry("connection-a")).toBe(true);

    const second = frontend("connection-b");
    const moved = controller.attachCall({ callId: call.callId }, second.connection).state;
    expect(controller.holdPastAuthExpiry("connection-a")).toBe(false);

    expect(controller.holdPastAuthExpiry("connection-b")).toBe(true);
    controller.endCall(moved, second.connection);
    expect(controller.holdPastAuthExpiry("connection-b")).toBe(false);
  });

  it("dispatches a committed utterance to the hidden voice-control session", () => {
    const dispatched: Array<{ sessionId: string; request: string }> = [];
    const controller = new VoiceCallController({
      now: () => 1_000,
      nextCallId: () => "call-1",
      dispatchDelegation: (sessionId, delegation) => {
        dispatched.push({ sessionId, request: delegation.request });
      },
    });
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const started = controller.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-1" },
      frontend.connection,
    );
    controller.commitFrontendUtterance({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontendConnectionId: frontend.connection.connectionId,
      utteranceId: "utterance-1",
      delegationId: "delegation-1",
      request: "list open sessions",
    });
    expect(dispatched).toEqual([{ sessionId: "voice-session-1", request: "list open sessions" }]);
    expect(controller.snapshot(started.state.callId).delegations).toHaveLength(1);
    expect(controller.activeCallIdForControlSession("voice-session-1")).toBe("call-1");
  });

  it("keeps the control call and independent delegations across media loss and reconnect", () => {
    const harness = makeHarness();
    const first = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      first.connection,
    );

    harness.controller.commitFrontendUtterance({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontendConnectionId: first.connection.connectionId,
      utteranceId: "utterance-1",
      delegationId: "delegation-1",
      request: "Inspect the reconnect race",
    });
    harness.controller.commitFrontendUtterance({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontendConnectionId: first.connection.connectionId,
      utteranceId: "utterance-2",
      delegationId: "delegation-2",
      request: "Run the focused tests",
    });
    harness.controller.applyDelegationUpdate(started.state.callId, {
      delegationId: "delegation-1",
      kind: "progress",
      text: "The race is reproduced.",
    });
    const beforeDisconnectSeq = harness.controller.snapshot(started.state.callId).eventSeq;

    harness.controller.disconnectConnection(first.connection.connectionId);
    harness.controller.applyDelegationUpdate(started.state.callId, {
      delegationId: "delegation-2",
      kind: "final",
      text: "The focused tests pass.",
    });

    const detached = harness.controller.snapshot(started.state.callId);
    expect(detached.lifecycle).toBe("active");
    expect(detached.frontend).toBe("detached");
    expect(detached.controlSessionId).toBe("control-session-1");
    expect(detached.delegations).toEqual([
      expect.objectContaining({ delegationId: "delegation-1", state: "working" }),
      expect.objectContaining({ delegationId: "delegation-2", state: "completed" }),
    ]);

    const second = harness.frontend("connection-2");
    const reattached = harness.controller.attachCall(
      { callId: started.state.callId, lastEventSeq: beforeDisconnectSeq },
      second.connection,
    );

    expect(reattached.state.frontend).toBe("attached");
    expect(reattached.state.controllerLeaseEpoch).toBeGreaterThan(
      started.state.controllerLeaseEpoch,
    );
    expect(reattached.replay).toContainEqual(
      expect.objectContaining({
        type: "voice_delegation_update",
        delegationId: "delegation-2",
        kind: "final",
      }),
    );
    expect(reattached.state.delegations).toContainEqual(
      expect.objectContaining({ delegationId: "delegation-2", state: "completed" }),
    );

    expect(() =>
      harness.controller.commitFrontendUtterance({
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontendConnectionId: first.connection.connectionId,
        utteranceId: "stale-utterance",
        delegationId: "stale-delegation",
        request: "This must be fenced",
      }),
    ).toThrow("Stale voice controller lease");
  });

  it("rejects committed utterances after the controller lease expires", () => {
    const harness = makeHarness();
    const frontend = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );

    harness.setNow(started.state.controllerLeaseExpiresAt);

    expect(() =>
      harness.controller.commitFrontendUtterance({
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontendConnectionId: frontend.connection.connectionId,
        utteranceId: "expired-utterance",
        delegationId: "expired-delegation",
        request: "This expired controller must be fenced",
      }),
    ).toThrow("Stale voice controller lease");
  });

  it("treats exact lease expiry as a generation boundary for same-connection attach", () => {
    const harness = makeHarness();
    const frontend = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );

    harness.setNow(started.state.controllerLeaseExpiresAt);
    const reacquired = harness.controller.attachCall(
      { callId: started.state.callId },
      frontend.connection,
    );

    expect(reacquired.state.controllerLeaseEpoch).toBe(started.state.controllerLeaseEpoch + 1);
    expect(() =>
      harness.controller.keepAlive(
        {
          callId: started.state.callId,
          controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        },
        frontend.connection,
      ),
    ).toThrow("Stale voice controller lease");
  });

  it("fences a previous frontend generation and rejects device takeover", () => {
    const harness = makeHarness();
    const first = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      first.connection,
    );
    const replacement = harness.frontend("connection-2");
    const attached = harness.controller.attachCall(
      { callId: started.state.callId },
      replacement.connection,
    );

    expect(() =>
      harness.controller.endCall(
        {
          callId: started.state.callId,
          controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        },
        first.connection,
      ),
    ).toThrow("Stale voice controller lease");

    const otherDevice = harness.frontend("connection-3", "paired-device-b");
    expect(() =>
      harness.controller.attachCall({ callId: started.state.callId }, otherDevice.connection),
    ).toThrow("Voice call belongs to a different paired device");

    expect(harness.controller.activeControllerLease(started.state.callId)).toMatchObject({
      callId: started.state.callId,
      epoch: attached.state.controllerLeaseEpoch,
      deviceId: "paired-device-a",
    });

    const detached = harness.controller.detachCall(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: attached.state.controllerLeaseEpoch,
      },
      replacement.connection,
    );
    expect(detached).toMatchObject({ lifecycle: "active", frontend: "detached" });
    expect(harness.controller.activeControllerLease(started.state.callId)).toBeUndefined();

    const finalFrontend = harness.frontend("connection-4");
    const finalAttachment = harness.controller.attachCall(
      { callId: started.state.callId, lastEventSeq: detached.eventSeq },
      finalFrontend.connection,
    );
    const ended = harness.controller.endCall(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: finalAttachment.state.controllerLeaseEpoch,
      },
      finalFrontend.connection,
    );
    expect(ended).toMatchObject({ lifecycle: "ended", frontend: "detached" });
  });

  it("routes an armed approval through authenticated controller authority only once", async () => {
    const harness = makeHarness();
    const frontend = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );
    const armed = challenge({
      controllerLeaseId: `${started.state.callId}:${started.state.controllerLeaseEpoch}`,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
    });

    harness.controller.presentApproval(started.state.callId, {
      challenge: armed,
      summary: "Allow one focused test command?",
    });

    expect(frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_approval_required",
        callId: started.state.callId,
        challengeId: "challenge-1",
        summary: "Allow one focused test command?",
        targetRefs: ["file:server/src/server.ts"],
      }),
    );

    const result = await harness.controller.submitApprovalTranscript(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        challengeId: "challenge-1",
        transcript: "approve once",
      },
      frontend.connection,
    );

    expect(result).toEqual({ kind: "delivered", decision: "approve_once" });
    expect(harness.approvalSubmissions).toEqual([
      {
        input: {
          challengeId: "challenge-1",
          callId: started.state.callId,
          leaseEpoch: started.state.controllerLeaseEpoch,
          requestId: "approval-request-1",
          actionDigest: "digest-1",
          nonce: "nonce-1",
          transcript: "approve once",
        },
        authority: { authenticatedDeviceId: "paired-device-a" },
      },
    ]);
    expect(frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_approval_result",
        challengeId: "challenge-1",
        outcome: "delivered",
        decision: "approve_once",
      }),
    );

    await expect(
      harness.controller.submitApprovalTranscript(
        {
          callId: started.state.callId,
          controllerLeaseEpoch: started.state.controllerLeaseEpoch,
          challengeId: "challenge-1",
          transcript: "approve once",
        },
        frontend.connection,
      ),
    ).rejects.toThrow("Voice approval challenge is not pending");
  });

  it("removes expired and detached lease-scoped approval presentations", () => {
    const harness = makeHarness();
    const first = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      first.connection,
    );
    const approval = challenge({
      challengeId: "challenge-expired",
      controllerLeaseId: `${started.state.callId}:${started.state.controllerLeaseEpoch}`,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      expiresAt: 2_000,
    });
    harness.controller.presentApproval(started.state.callId, {
      challenge: approval,
      summary: "Allow one focused test command?",
    });

    harness.setNow(approval.expiresAt);
    expect(harness.controller.snapshot(started.state.callId).pendingApprovals).toEqual([]);

    harness.setNow(2_500);
    const secondApproval = challenge({
      challengeId: "challenge-detached",
      controllerLeaseId: `${started.state.callId}:${started.state.controllerLeaseEpoch}`,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      issuedAt: 2_500,
      expiresAt: 8_000,
    });
    harness.controller.presentApproval(started.state.callId, {
      challenge: secondApproval,
      summary: "Allow one focused test command?",
    });
    harness.controller.disconnectConnection(first.connection.connectionId);

    const replacement = harness.frontend("connection-2");
    const reattached = harness.controller.attachCall(
      { callId: started.state.callId },
      replacement.connection,
    );
    expect(reattached.state.pendingApprovals).toEqual([]);
  });

  it("replays approval presentation only while its exact challenge is pending", () => {
    const harness = makeHarness();
    const first = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      first.connection,
    );
    const pending = challenge({
      controllerLeaseId: `${started.state.callId}:${started.state.controllerLeaseEpoch}`,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      expiresAt: 8_000,
    });
    harness.controller.presentApproval(started.state.callId, {
      challenge: pending,
      summary: "Allow one focused test command?",
    });

    const stillPending = harness.controller.attachCall(
      { callId: started.state.callId, lastEventSeq: started.state.eventSeq },
      first.connection,
    );
    expect(stillPending.state.pendingApprovals).toEqual([
      expect.objectContaining({ challengeId: pending.challengeId }),
    ]);
    expect(stillPending.replay).toContainEqual(
      expect.objectContaining({
        type: "voice_approval_required",
        challengeId: pending.challengeId,
      }),
    );

    harness.controller.disconnectConnection(first.connection.connectionId);
    const replacement = harness.frontend("connection-2");
    const afterDetach = harness.controller.attachCall(
      { callId: started.state.callId, lastEventSeq: started.state.eventSeq },
      replacement.connection,
    );
    expect(afterDetach.state.pendingApprovals).toEqual([]);
    expect(afterDetach.replay).not.toContainEqual(
      expect.objectContaining({ type: "voice_approval_required" }),
    );
  });

  it("does not replay expired or resolved approval presentations", async () => {
    const harness = makeHarness();
    const frontend = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );
    const expiring = challenge({
      challengeId: "challenge-expiring",
      controllerLeaseId: `${started.state.callId}:${started.state.controllerLeaseEpoch}`,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      expiresAt: 2_000,
    });
    harness.controller.presentApproval(started.state.callId, {
      challenge: expiring,
      summary: "Allow an expiring command?",
    });

    harness.setNow(expiring.expiresAt);
    const afterExpiry = harness.controller.attachCall(
      { callId: started.state.callId, lastEventSeq: started.state.eventSeq },
      frontend.connection,
    );
    expect(afterExpiry.state.pendingApprovals).toEqual([]);
    expect(afterExpiry.replay).not.toContainEqual(
      expect.objectContaining({ type: "voice_approval_required" }),
    );

    const resolved = challenge({
      challengeId: "challenge-resolved",
      controllerLeaseId: `${afterExpiry.state.callId}:${afterExpiry.state.controllerLeaseEpoch}`,
      controllerLeaseEpoch: afterExpiry.state.controllerLeaseEpoch,
      issuedAt: 2_000,
      expiresAt: 8_000,
    });
    harness.controller.presentApproval(started.state.callId, {
      challenge: resolved,
      summary: "Allow one resolved command?",
    });
    await harness.controller.submitApprovalTranscript(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: afterExpiry.state.controllerLeaseEpoch,
        challengeId: resolved.challengeId,
        transcript: "approve once",
      },
      frontend.connection,
    );

    const afterResolution = harness.controller.attachCall(
      { callId: started.state.callId, lastEventSeq: afterExpiry.state.eventSeq },
      frontend.connection,
    );
    expect(afterResolution.state.pendingApprovals).toEqual([]);
    expect(afterResolution.replay).not.toContainEqual(
      expect.objectContaining({ type: "voice_approval_required" }),
    );
    expect(afterResolution.replay).toContainEqual(
      expect.objectContaining({
        type: "voice_approval_result",
        challengeId: resolved.challengeId,
      }),
    );
  });

  it("attaches a new clientCallId to the existing active call for the same session and device", () => {
    const harness = makeHarness();
    const firstFrontend = harness.frontend("connection-1");
    const first = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      firstFrontend.connection,
    );

    const secondFrontend = harness.frontend("connection-2");
    const second = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-2" },
      secondFrontend.connection,
    );

    expect(second.state.callId).toBe(first.state.callId);
    expect(second.state.frontend).toBe("attached");
    expect(second.state.controllerLeaseEpoch).toBeGreaterThan(first.state.controllerLeaseEpoch);
    expect(() =>
      harness.controller.keepAlive(
        {
          callId: first.state.callId,
          controllerLeaseEpoch: first.state.controllerLeaseEpoch,
        },
        firstFrontend.connection,
      ),
    ).toThrow("Stale voice controller lease");
  });

  it("makes call start idempotent before expiry and reacquires after exact expiry", () => {
    const harness = makeHarness();
    const frontend = harness.frontend("connection-1");
    const first = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );
    harness.setNow(first.state.controllerLeaseExpiresAt - 1);
    const retry = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );

    expect(retry.state.callId).toBe(first.state.callId);
    expect(retry.state.controllerLeaseEpoch).toBe(first.state.controllerLeaseEpoch);
    expect(retry.replay).toEqual([]);

    harness.setNow(retry.state.controllerLeaseExpiresAt);
    const reacquired = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );
    expect(reacquired.state.callId).toBe(first.state.callId);
    expect(reacquired.state.controllerLeaseEpoch).toBe(first.state.controllerLeaseEpoch + 1);
    expect(() =>
      harness.controller.keepAlive(
        {
          callId: first.state.callId,
          controllerLeaseEpoch: first.state.controllerLeaseEpoch,
        },
        frontend.connection,
      ),
    ).toThrow("Stale voice controller lease");
  });

  it("retains a detached call under capacity pressure through reconnect grace", () => {
    const harness = makeHarness({ maxRetainedCalls: 2, retentionGraceMs: 100 });
    const firstFrontend = harness.frontend("connection-1");
    const first = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      firstFrontend.connection,
    );
    harness.controller.commitFrontendUtterance({
      callId: first.state.callId,
      controllerLeaseEpoch: first.state.controllerLeaseEpoch,
      frontendConnectionId: firstFrontend.connection.connectionId,
      utteranceId: "utterance-1",
      delegationId: "delegation-1",
      request: "Keep this delegation across reconnect",
    });
    const beforeDisconnectSeq = harness.controller.snapshot(first.state.callId).eventSeq;
    const liveFrontend = harness.frontend("connection-2");
    harness.controller.startCall(
      { controlSessionId: "control-session-2", clientCallId: "client-call-2" },
      liveFrontend.connection,
    );

    harness.controller.disconnectConnection(firstFrontend.connection.connectionId);
    harness.controller.applyDelegationUpdate(first.state.callId, {
      delegationId: "delegation-1",
      kind: "progress",
      text: "Work continued while detached.",
    });

    expect(() =>
      harness.controller.startCall(
        { controlSessionId: "control-session-3", clientCallId: "client-call-3" },
        harness.frontend("connection-3").connection,
      ),
    ).toThrow("Voice call capacity is reached");

    const replacement = harness.frontend("connection-4");
    const reattached = harness.controller.attachCall(
      { callId: first.state.callId, lastEventSeq: beforeDisconnectSeq },
      replacement.connection,
    );
    expect(reattached.state.delegations).toContainEqual(
      expect.objectContaining({ delegationId: "delegation-1", state: "working" }),
    );
    expect(reattached.replay).toContainEqual(
      expect.objectContaining({
        type: "voice_delegation_update",
        delegationId: "delegation-1",
        kind: "progress",
      }),
    );
  });

  it("reclaims a detached call after grace and cleans its client identity", () => {
    const harness = makeHarness({ maxRetainedCalls: 2, retentionGraceMs: 100 });
    const firstFrontend = harness.frontend("connection-1");
    const first = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      firstFrontend.connection,
    );
    const liveFrontend = harness.frontend("connection-2");
    const live = harness.controller.startCall(
      { controlSessionId: "control-session-2", clientCallId: "client-call-2" },
      liveFrontend.connection,
    );
    harness.controller.disconnectConnection(firstFrontend.connection.connectionId);

    harness.setNow(1_100);
    const recovered = harness.controller.startCall(
      { controlSessionId: "control-session-3", clientCallId: "client-call-3" },
      harness.frontend("connection-3").connection,
    );

    expect(recovered.state.callId).toBe("call-3");
    expect(() => harness.controller.snapshot(first.state.callId)).toThrow("Unknown voice call");
    expect(harness.controller.activeControllerLease(live.state.callId)).toBeDefined();

    harness.controller.disconnectConnection("connection-3");
    harness.setNow(1_200);
    const restartedIdentity = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      harness.frontend("connection-4").connection,
    );
    expect(restartedIdentity.state.callId).toBe("call-4");
  });

  it("reclaims an expired open attachment only after grace without evicting live authority", () => {
    const harness = makeHarness({
      leaseDurationMs: 100,
      maxRetainedCalls: 2,
      retentionGraceMs: 50,
    });
    const staleFrontend = harness.frontend("connection-stale");
    const stale = harness.controller.startCall(
      { controlSessionId: "control-session-stale", clientCallId: "client-call-stale" },
      staleFrontend.connection,
    );
    const liveFrontend = harness.frontend("connection-live");
    const live = harness.controller.startCall(
      { controlSessionId: "control-session-live", clientCallId: "client-call-live" },
      liveFrontend.connection,
    );

    harness.setNow(stale.state.controllerLeaseExpiresAt - 1);
    harness.controller.keepAlive(
      { callId: live.state.callId, controllerLeaseEpoch: live.state.controllerLeaseEpoch },
      liveFrontend.connection,
    );
    const startThird = () =>
      harness.controller.startCall(
        { controlSessionId: "control-session-3", clientCallId: "client-call-3" },
        harness.frontend("connection-3").connection,
      );

    harness.setNow(stale.state.controllerLeaseExpiresAt);
    expect(startThird).toThrow("Voice call capacity is reached");
    harness.setNow(stale.state.controllerLeaseExpiresAt + 49);
    expect(startThird).toThrow("Voice call capacity is reached");

    harness.setNow(stale.state.controllerLeaseExpiresAt + 50);
    const recovered = startThird();
    expect(recovered.state.callId).toBe("call-3");
    expect(() => harness.controller.snapshot(stale.state.callId)).toThrow("Unknown voice call");
    expect(harness.controller.activeControllerLease(live.state.callId)).toBeDefined();
  });

  it("restores call identity, delegations, and replay after process loss and fences the old lease", () => {
    const store = new MemoryVoiceCallStore();
    let now = 1_000;
    const first = new VoiceCallController({
      now: () => now,
      nextCallId: () => "call-persisted",
      persistence: store,
      approvalAuthority: {
        submitTranscript: () => ({ kind: "delivered", decision: "approve_once" }),
      },
    });
    const attached = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    first.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-call-1" },
      attached.connection,
    );
    first.commitFrontendUtterance({
      callId: "call-persisted",
      controllerLeaseEpoch: 1,
      frontendConnectionId: "connection-1",
      utteranceId: "utterance-1",
      delegationId: "delegation-1",
      request: "Inspect the reconnect path",
    });
    first.applyDelegationUpdate("call-persisted", {
      delegationId: "delegation-1",
      kind: "acknowledgement",
      text: "Working on it.",
    });
    first.presentApproval("call-persisted", {
      challenge: challenge({
        callId: "call-persisted",
        controllerLeaseId: "call-persisted:1",
        controllerLeaseEpoch: 1,
      }),
      summary: "Allow one test command?",
    });
    const beforeRestart = first.snapshot("call-persisted");
    expect(beforeRestart.frontend).toBe("attached");
    expect(beforeRestart.pendingApprovals).toHaveLength(1);

    now = 5_000;
    const restarted = new VoiceCallController({
      now: () => now,
      nextCallId: () => "call-should-not-mint",
      persistence: store,
    });
    const restored = restarted.snapshot("call-persisted");
    expect(restored.lifecycle).toBe("active");
    expect(restored.frontend).toBe("detached");
    expect(restored.controlSessionId).toBe("voice-session-1");
    expect(restored.controllerLeaseEpoch).toBeGreaterThan(beforeRestart.controllerLeaseEpoch);
    expect(restored.controllerLeaseExpiresAt).toBe(now);
    expect(restored.pendingApprovals).toEqual([]);
    expect(restored.delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-1",
        state: "acknowledged",
        latestText: "Working on it.",
      }),
    ]);
    expect(restarted.activeControllerLease("call-persisted")).toBeUndefined();

    const stale = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    expect(() =>
      restarted.detachCall(
        {
          callId: "call-persisted",
          controllerLeaseEpoch: beforeRestart.controllerLeaseEpoch,
        },
        stale.connection,
      ),
    ).toThrow("Stale voice controller lease");

    const reconnect = new DeterministicVoiceCallFrontend({
      connectionId: "connection-2",
      authenticatedDeviceId: "paired-device-a",
    });
    const attachedAgain = restarted.attachCall(
      { callId: "call-persisted", lastEventSeq: 1 },
      reconnect.connection,
    );
    expect(attachedAgain.state.frontend).toBe("attached");
    expect(attachedAgain.replay).toContainEqual(
      expect.objectContaining({
        type: "voice_delegation_update",
        delegationId: "delegation-1",
        kind: "acknowledgement",
      }),
    );
    expect(attachedAgain.replay.some((event) => event.type === "voice_approval_required")).toBe(
      false,
    );
  });

  it("reports the single attached live call and stays silent when that is ambiguous", () => {
    const harness = makeHarness();
    expect(harness.controller.activeAttachedCallId()).toBeUndefined();

    const first = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      harness.frontend("connection-1").connection,
    );
    expect(harness.controller.activeAttachedCallId()).toBe(first.state.callId);

    harness.controller.startCall(
      { controlSessionId: "control-session-2", clientCallId: "client-call-2" },
      harness.frontend("connection-2", "paired-device-b").connection,
    );
    expect(harness.controller.activeAttachedCallId()).toBeUndefined();
  });

  it("keeps ended-call identity after restart so the same client call cannot be reused", () => {
    const store = new MemoryVoiceCallStore();
    const first = new VoiceCallController({
      now: () => 1_000,
      nextCallId: () => "call-ended",
      persistence: store,
    });
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const started = first.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-call-ended" },
      frontend.connection,
    );
    first.endCall(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      },
      frontend.connection,
    );

    const restarted = new VoiceCallController({
      now: () => 2_000,
      nextCallId: () => "call-should-not-mint",
      persistence: store,
    });
    expect(restarted.snapshot("call-ended").lifecycle).toBe("ended");
    expect(() =>
      restarted.startCall(
        { controlSessionId: "voice-session-1", clientCallId: "client-call-ended" },
        frontend.connection,
      ),
    ).toThrow("Voice call identity already belongs to an ended call");
  });
});

class MemoryVoiceCallStore implements VoiceCallPersistence {
  private records: PersistedVoiceCall[] = [];

  load(): PersistedVoiceCall[] {
    return structuredClone(this.records);
  }

  save(calls: readonly PersistedVoiceCall[]): void {
    this.records = structuredClone(calls);
  }
}

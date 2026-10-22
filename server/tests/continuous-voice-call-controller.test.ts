import { describe, expect, it, vi } from "vitest";

import {
  VoiceCallController,
  type PersistedVoiceCall,
  type VoiceCallPersistence,
} from "../src/continuous-voice-call.js";
import { DeterministicVoiceCallFrontend } from "./helpers/deterministic-voice-call-frontend.js";

function makeHarness(
  options: {
    leaseDurationMs?: number;
    maxRetainedCalls?: number;
    retentionGraceMs?: number;
    detachedCallTtlMs?: number;
  } = {},
) {
  let now = 1_000;
  let callSequence = 0;
  const controller = new VoiceCallController({
    now: () => now,
    nextCallId: () => `call-${++callSequence}`,
    leaseDurationMs: options.leaseDurationMs ?? 30_000,
    maxRetainedCalls: options.maxRetainedCalls,
    retentionGraceMs: options.retentionGraceMs,
    detachedCallTtlMs: options.detachedCallTtlMs,
  });

  const frontend = (
    connectionId: string,
    authenticatedDeviceId = "paired-device-a",
  ): DeterministicVoiceCallFrontend =>
    new DeterministicVoiceCallFrontend({ connectionId, authenticatedDeviceId });

  return {
    controller,
    frontend,
    setNow(value: number) {
      now = value;
    },
  };
}

describe("continuous voice call controller", () => {
  it("ends a detached call left past the rejoin window so a new start is fresh", () => {
    const harness = makeHarness({ detachedCallTtlMs: 60_000 });
    const first = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      first.connection,
    );
    harness.controller.commitFrontendUtterance({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontendConnectionId: "connection-1",
      utteranceId: "utterance-1",
      delegationId: "delegation-1",
      request: "an old request",
    });
    harness.controller.disconnectConnection("connection-1");

    // Inside the window the same device still rejoins the call and its delegations.
    harness.setNow(1_000 + 59_000);
    const rejoined = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-2" },
      harness.frontend("connection-2").connection,
    );
    expect(rejoined.state.callId).toBe("call-1");
    expect(rejoined.state.delegations).toHaveLength(1);
    harness.controller.disconnectConnection("connection-2");

    // Days later it is a different conversation: the old call ends, the new start is empty.
    harness.setNow(1_000 + 59_000 + 3 * 24 * 60 * 60 * 1000);
    const fresh = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-3" },
      harness.frontend("connection-3").connection,
    );
    expect(fresh.state.callId).toBe("call-2");
    expect(fresh.state.delegations).toEqual([]);
    expect(harness.controller.snapshot("call-1").lifecycle).toBe("ended");
    expect(harness.controller.activeCallIdForControlSession("control-session-1")).toBe("call-2");
  });

  it("refuses to re-attach a stale detached call by id and ends it", () => {
    const harness = makeHarness({ detachedCallTtlMs: 60_000 });
    const first = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      first.connection,
    );
    harness.controller.disconnectConnection("connection-1");
    harness.setNow(1_000 + 60_000);

    expect(() =>
      harness.controller.attachCall(
        { callId: started.state.callId },
        harness.frontend("connection-2").connection,
      ),
    ).toThrow("Voice call has ended");
    expect(harness.controller.snapshot(started.state.callId).lifecycle).toBe("ended");
  });

  it("keeps accepting utterances past the delegation cap by dropping the oldest", () => {
    const harness = makeHarness();
    const phone = harness.frontend("connection-1");
    const started = harness.controller.startCall(
      { controlSessionId: "control-session-1", clientCallId: "client-call-1" },
      phone.connection,
    );
    const say = (n: number) =>
      harness.controller.commitFrontendUtterance({
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontendConnectionId: "connection-1",
        utteranceId: `utterance-${n}`,
        delegationId: `delegation-${n}`,
        request: `request ${n}`,
      });
    for (let n = 1; n <= 256; n += 1) say(n);
    // Delegation 2 is answered; 1 is still open. The oldest *settled* one goes first.
    harness.controller.applyDelegationUpdate(started.state.callId, {
      delegationId: "delegation-2",
      kind: "final",
      text: "done",
    });

    expect(() => say(257)).not.toThrow();
    const ids = harness.controller
      .snapshot(started.state.callId)
      .delegations.map((d) => d.delegationId);
    expect(ids).toHaveLength(256);
    expect(ids).toContain("delegation-1");
    expect(ids).not.toContain("delegation-2");
    expect(ids.at(-1)).toBe("delegation-257");

    // With nothing settled, the oldest open one is dropped rather than the caller's words.
    expect(() => say(258)).not.toThrow();
    const after = harness.controller
      .snapshot(started.state.callId)
      .delegations.map((d) => d.delegationId);
    expect(after).toHaveLength(256);
    expect(after).not.toContain("delegation-1");
    expect(after.at(-1)).toBe("delegation-258");
    expect(harness.controller.latestOpenDelegationId(started.state.callId)).toBe("delegation-258");
  });

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

  it("dispatches a committed utterance to the call's session", () => {
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

    const detached = harness.controller.detachCall(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: attached.state.controllerLeaseEpoch,
      },
      replacement.connection,
    );
    expect(detached).toMatchObject({ lifecycle: "active", frontend: "detached" });

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
    harness.controller.startCall(
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
    expect(harness.controller.snapshot(live.state.callId).frontend).toBe("attached");
  });

  it("restores call identity, delegations, and replay after process loss and fences the old lease", () => {
    const store = new MemoryVoiceCallStore();
    let now = 1_000;
    const first = new VoiceCallController({
      now: () => now,
      nextCallId: () => "call-persisted",
      persistence: store,
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
      kind: "progress",
      text: "Working on it.",
    });
    const beforeRestart = first.snapshot("call-persisted");
    expect(beforeRestart.frontend).toBe("attached");

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
    expect(restored.delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-1",
        state: "working",
        latestText: "Working on it.",
      }),
    ]);

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
        kind: "progress",
      }),
    );
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

  quarantine(reason: unknown): void {
    throw reason;
  }
}

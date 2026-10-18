import { describe, expect, it } from "vitest";

import {
  DeterministicVoiceCallFrontend,
  VoiceCallController,
} from "../src/continuous-voice-call.js";
import { VoiceApprovalBridge } from "../src/voice-approval-bridge.js";
import { VoicePermissionGate } from "../src/voice-permission-gate.js";

function makeHarness() {
  let now = 1_000;
  const responses: Array<{ sessionId: string; response: unknown }> = [];
  const receipts: unknown[] = [];
  let controller!: VoiceCallController;
  const bridge = new VoiceApprovalBridge({
    now: () => now,
    activeControllerLease: (callId) => controller.activeControllerLease(callId),
    respondToUIRequest: (sessionId, response) => {
      responses.push({ sessionId, response });
      return true;
    },
    appendReceipt: (receipt) => receipts.push(receipt),
    nextChallengeId: () => "challenge-1",
    nextNonce: () => "nonce-1",
    nextReceiptId: () => "receipt-1",
  });
  controller = new VoiceCallController({
    now: () => now,
    nextCallId: () => "call-1",
    leaseDurationMs: 30_000,
    approvalAuthority: bridge,
  });
  const gate = new VoicePermissionGate({
    now: () => now,
    bridge,
    calls: controller,
  });
  return {
    controller,
    bridge,
    gate,
    responses,
    receipts,
    setNow(value: number) {
      now = value;
    },
  };
}

function offer(
  overrides: Partial<Parameters<VoicePermissionGate["expectNextConfirm"]>[0]> = {},
): Parameters<VoicePermissionGate["expectNextConfirm"]>[0] {
  return {
    source: "structured_permission_gate",
    sessionId: "session-1",
    canonicalAction: {
      kind: "oppi_command",
      args: ["session", "stop", "worker-1"],
    },
    targetRefs: ["session:worker-1"],
    policyRevision: "7",
    risk: "voice_eligible",
    expiresAt: 8_000,
    responses: {
      approveOnce: { confirmed: true },
      deny: { confirmed: false },
    },
    summary: "Stop worker-1?",
    ...overrides,
  };
}

describe("voice permission gate", () => {
  it("presents a structured Oppi binding to the single attached call and delivers one decision", async () => {
    const harness = makeHarness();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    harness.controller.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );

    harness.gate.expectNextConfirm(offer());
    harness.gate.observeRequest("session-1", { id: "request-1", method: "confirm" });

    expect(frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_approval_required",
        challengeId: "challenge-1",
        summary: "Stop worker-1?",
        targetRefs: ["session:worker-1"],
      }),
    );

    const presented = frontend.messages.find(
      (message) => message.type === "voice_approval_required",
    );
    expect(presented && "eventSeq" in presented ? presented.eventSeq : undefined).toBeGreaterThan(
      0,
    );

    const result = await harness.controller.submitApprovalTranscript(
      {
        callId: "call-1",
        controllerLeaseEpoch: 1,
        challengeId: "challenge-1",
        transcript: "approve once",
      },
      frontend.connection,
    );
    expect(result).toEqual({ kind: "delivered", decision: "approve_once" });
    expect(harness.responses).toEqual([
      {
        sessionId: "session-1",
        response: {
          type: "extension_ui_response",
          id: "request-1",
          confirmed: true,
        },
      },
    ]);
    expect(harness.receipts).toContainEqual(
      expect.objectContaining({
        receiptId: "receipt-1",
        requestId: "request-1",
        decision: "approve_once",
        deliveryOutcome: "delivered",
      }),
    );
    expect(JSON.stringify(harness.receipts)).not.toMatch(/approve once/i);
  });

  it("does not infer authority from an ordinary confirm title", async () => {
    const harness = makeHarness();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    harness.controller.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );

    harness.gate.observeRequest("session-1", {
      id: "looks-like-approval",
      method: "confirm",
      title: "Approve Oppi command",
      message: "Run the requested Oppi CLI command?",
    });

    expect(frontend.messages.some((message) => message.type === "voice_approval_required")).toBe(
      false,
    );
    expect(harness.controller.snapshot("call-1").pendingApprovals).toEqual([]);
  });

  it("keeps destructive Oppi commands off the voice-only path", async () => {
    const harness = makeHarness();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    harness.controller.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-call-1" },
      frontend.connection,
    );

    harness.gate.expectNextConfirm(
      offer({
        risk: "secondary_confirmation_required",
        canonicalAction: {
          kind: "oppi_command",
          args: ["session", "delete", "worker-1"],
        },
      }),
    );
    harness.gate.observeRequest("session-1", { id: "request-1", method: "confirm" });

    expect(frontend.messages.some((message) => message.type === "voice_approval_required")).toBe(
      false,
    );
  });

  it("does not present when zero or more than one call is attached", async () => {
    const first = makeHarness();
    first.gate.expectNextConfirm(offer());
    first.gate.observeRequest("session-1", { id: "request-1", method: "confirm" });
    expect(first.responses).toEqual([]);

    let callSequence = 0;
    let now = 1_000;
    const responses: unknown[] = [];
    let controller!: VoiceCallController;
    const bridge = new VoiceApprovalBridge({
      now: () => now,
      activeControllerLease: (callId) => controller.activeControllerLease(callId),
      respondToUIRequest: () => {
        responses.push("delivered");
        return true;
      },
      appendReceipt: () => undefined,
      nextChallengeId: () => "challenge-1",
      nextNonce: () => "nonce-1",
      nextReceiptId: () => "receipt-1",
    });
    controller = new VoiceCallController({
      now: () => now,
      nextCallId: () => `call-${++callSequence}`,
      approvalAuthority: bridge,
    });
    const gate = new VoicePermissionGate({ now: () => now, bridge, calls: controller });
    controller.startCall(
      { controlSessionId: "voice-session-1", clientCallId: "client-a" },
      new DeterministicVoiceCallFrontend({
        connectionId: "connection-1",
        authenticatedDeviceId: "paired-device-a",
      }).connection,
    );
    controller.startCall(
      { controlSessionId: "voice-session-2", clientCallId: "client-b" },
      new DeterministicVoiceCallFrontend({
        connectionId: "connection-2",
        authenticatedDeviceId: "paired-device-b",
      }).connection,
    );
    gate.expectNextConfirm(offer());
    gate.observeRequest("session-1", { id: "request-1", method: "confirm" });
    expect(responses).toEqual([]);
    expect(controller.snapshot("call-1").pendingApprovals).toEqual([]);
    expect(controller.snapshot("call-2").pendingApprovals).toEqual([]);
  });
});

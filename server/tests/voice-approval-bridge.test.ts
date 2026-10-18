import { describe, expect, it, vi } from "vitest";

import {
  VoiceApprovalBridge,
  type VoiceApprovalBinding,
  type VoiceControllerLease,
} from "../src/continuous-voice.js";

function makeHarness() {
  let now = 1_000;
  let currentLease: VoiceControllerLease | undefined = {
    callId: "call-1",
    leaseId: "lease-1",
    epoch: 3,
    deviceId: "paired-iphone",
    expiresAt: 10_000,
  };
  const responses: Array<{ sessionId: string; response: unknown }> = [];
  const receipts: unknown[] = [];
  let challengeSequence = 0;
  let nonceSequence = 0;
  let receiptSequence = 0;
  const bridge = new VoiceApprovalBridge({
    now: () => now,
    activeControllerLease: (callId) => (currentLease?.callId === callId ? currentLease : undefined),
    respondToUIRequest: (sessionId, response) => {
      responses.push({ sessionId, response });
      return true;
    },
    appendReceipt: (receipt) => receipts.push(receipt),
    nextChallengeId: () => `challenge-${++challengeSequence}`,
    nextNonce: () => `nonce-${++nonceSequence}`,
    nextReceiptId: () => `receipt-${++receiptSequence}`,
  });

  const register = (
    overrides: Partial<Parameters<VoiceApprovalBridge["registerBinding"]>[0]> = {},
  ): VoiceApprovalBinding =>
    bridge.registerBinding({
      source: "structured_permission_gate",
      sessionId: "session-1",
      requestId: "request-1",
      canonicalAction: {
        kind: "oppi_command",
        args: ["session", "stop", "worker-1"],
      },
      targetRefs: ["session:worker-1"],
      policyRevision: "policy-7",
      risk: "voice_eligible",
      expiresAt: 8_000,
      responses: {
        approveOnce: { confirmed: true },
        deny: { confirmed: false },
      },
      ...overrides,
    });

  return {
    bridge,
    register,
    responses,
    receipts,
    setNow(value: number) {
      now = value;
    },
    setLease(value: VoiceControllerLease | undefined) {
      currentLease = value;
    },
  };
}

function submission(
  challenge: ReturnType<VoiceApprovalBridge["issueChallenge"]>,
  transcript: string,
) {
  return {
    challengeId: challenge.challengeId,
    callId: challenge.callId,
    leaseEpoch: challenge.controllerLeaseEpoch,
    requestId: challenge.requestId,
    actionDigest: challenge.actionDigest,
    nonce: challenge.nonce,
    transcript,
  };
}

describe("voice approval authority boundary", () => {
  it("routes one exact decision through the existing structured UI response path", async () => {
    const harness = makeHarness();
    harness.register();
    const challenge = harness.bridge.issueChallenge({
      callId: "call-1",
      sessionId: "session-1",
      requestId: "request-1",
    });

    const result = await harness.bridge.submitTranscript(submission(challenge, "Approve once."), {
      authenticatedDeviceId: "paired-iphone",
    });

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
        deviceId: "paired-iphone",
        decision: "approve_once",
        validationOutcome: "accepted",
        deliveryOutcome: "delivered",
      }),
    );

    expect(
      await harness.bridge.submitTranscript(submission(challenge, "Approve once"), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "rejected", reason: "challenge_consumed" });
    expect(harness.responses).toHaveLength(1);
  });

  it.each([
    ["Sure, that seems fine", "ambiguous_decision"],
    ["approve everything", "ambiguous_decision"],
    ["deny and approve once", "ambiguous_decision"],
  ] as const)("fails closed for untrusted transcript %j", async (transcript, reason) => {
    const harness = makeHarness();
    harness.register();
    const challenge = harness.bridge.issueChallenge({
      callId: "call-1",
      sessionId: "session-1",
      requestId: "request-1",
    });

    expect(
      await harness.bridge.submitTranscript(submission(challenge, transcript), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "rejected", reason });
    expect(harness.responses).toEqual([]);
  });

  it("does not let the voice frontend approve from the wrong device or a stale lease", async () => {
    const harness = makeHarness();
    harness.register();
    const wrongDeviceChallenge = harness.bridge.issueChallenge({
      callId: "call-1",
      sessionId: "session-1",
      requestId: "request-1",
    });

    expect(
      await harness.bridge.submitTranscript(submission(wrongDeviceChallenge, "approve once"), {
        authenticatedDeviceId: "other-device",
      }),
    ).toEqual({ kind: "rejected", reason: "wrong_device" });

    harness.setLease({
      callId: "call-1",
      leaseId: "lease-2",
      epoch: 4,
      deviceId: "paired-iphone",
      expiresAt: 10_000,
    });
    expect(
      await harness.bridge.submitTranscript(submission(wrongDeviceChallenge, "approve once"), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "rejected", reason: "stale_controller_lease" });
    expect(harness.responses).toEqual([]);
  });

  it.each([
    {
      label: "structured action",
      replacement: {
        canonicalAction: {
          kind: "oppi_command",
          args: ["session", "stop", "worker-2"],
        },
        targetRefs: ["session:worker-2"],
      },
    },
    {
      label: "risk classification",
      replacement: { risk: "secondary_confirmation_required" as const },
    },
  ])("invalidates a challenge when the $label changes", async ({ replacement }) => {
    const harness = makeHarness();
    harness.register();
    const challenge = harness.bridge.issueChallenge({
      callId: "call-1",
      sessionId: "session-1",
      requestId: "request-1",
    });

    harness.register(replacement);

    expect(
      await harness.bridge.submitTranscript(submission(challenge, "approve once"), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "rejected", reason: "action_changed" });
    expect(harness.responses).toEqual([]);
  });

  it("does not infer approval authority from an ordinary extension dialog", async () => {
    const harness = makeHarness();
    expect(() =>
      harness.bridge.registerBinding({
        source: "extension_dialog",
        sessionId: "session-1",
        requestId: "looks-like-approval",
        canonicalAction: { label: "Allow once" },
        targetRefs: ["session:worker-1"],
        policyRevision: "policy-7",
        risk: "voice_eligible",
        expiresAt: 8_000,
        responses: {
          approveOnce: { confirmed: true },
          deny: { confirmed: false },
        },
      } as never),
    ).toThrow("structured permission gate");
    expect(harness.responses).toEqual([]);
  });

  it("keeps stronger and unreviewable actions out of voice-only approval", async () => {
    const harness = makeHarness();
    harness.register({ risk: "secondary_confirmation_required" });
    expect(() =>
      harness.bridge.issueChallenge({
        callId: "call-1",
        sessionId: "session-1",
        requestId: "request-1",
      }),
    ).toThrow("secondary confirmation");

    harness.register({ risk: "voice_ineligible" });
    expect(() =>
      harness.bridge.issueChallenge({
        callId: "call-1",
        sessionId: "session-1",
        requestId: "request-1",
      }),
    ).toThrow("not voice eligible");
    expect(harness.responses).toEqual([]);
  });

  it("treats repeat and tell-me-more as non-authorizing decisions requiring a fresh challenge", async () => {
    const harness = makeHarness();
    harness.register();
    const challenge = harness.bridge.issueChallenge({
      callId: "call-1",
      sessionId: "session-1",
      requestId: "request-1",
    });

    expect(
      await harness.bridge.submitTranscript(submission(challenge, "tell me more"), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "retry", reason: "tell_me_more" });
    expect(harness.responses).toEqual([]);
    expect(
      await harness.bridge.submitTranscript(submission(challenge, "approve once"), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "rejected", reason: "challenge_consumed" });
  });

  it("expires bindings and controller leases without settling the underlying request", async () => {
    const harness = makeHarness();
    harness.register();
    const challenge = harness.bridge.issueChallenge({
      callId: "call-1",
      sessionId: "session-1",
      requestId: "request-1",
    });
    harness.setNow(11_000);

    expect(
      await harness.bridge.submitTranscript(submission(challenge, "deny"), {
        authenticatedDeviceId: "paired-iphone",
      }),
    ).toEqual({ kind: "rejected", reason: "challenge_expired" });
    expect(harness.responses).toEqual([]);
  });
});

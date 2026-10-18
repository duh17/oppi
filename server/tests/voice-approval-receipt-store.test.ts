import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import type { VoiceApprovalReceipt } from "../src/voice-approval-bridge.js";
import {
  FileVoiceApprovalReceiptStore,
  voiceApprovalReceiptStorePath,
} from "../src/voice-approval-receipt-store.js";

function receipt(overrides: Partial<VoiceApprovalReceipt> = {}): VoiceApprovalReceipt {
  return {
    receiptId: "receipt-1",
    challengeId: "challenge-1",
    callId: "call-1",
    controllerLeaseId: "call-1:1",
    controllerLeaseEpoch: 1,
    deviceId: "paired-device-a",
    sessionId: "session-1",
    requestId: "request-1",
    actionDigest: "digest-1",
    targetRefs: ["session:worker-1"],
    decision: "approve_once",
    receivedAt: 1_000,
    validationOutcome: "accepted",
    deliveryOutcome: "delivered",
    ...overrides,
  };
}

describe("FileVoiceApprovalReceiptStore", () => {
  it("appends receipts without transcripts and reloads them after process loss", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-approval-receipts-"));
    try {
      const path = voiceApprovalReceiptStorePath(dir);
      const first = new FileVoiceApprovalReceiptStore(path);
      first.append(receipt());
      first.append(
        receipt({
          receiptId: "receipt-2",
          challengeId: "challenge-2",
          decision: "deny",
          receivedAt: 2_000,
        }),
      );

      const raw = readFileSync(path, "utf8");
      expect(raw).not.toMatch(/transcript/i);
      expect(raw.split("\n").filter(Boolean)).toHaveLength(2);

      const restarted = new FileVoiceApprovalReceiptStore(path);
      expect(restarted.load()).toEqual([
        expect.objectContaining({ receiptId: "receipt-1", decision: "approve_once" }),
        expect.objectContaining({ receiptId: "receipt-2", decision: "deny" }),
      ]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("starts empty when missing and refuses a receipt that carries a transcript", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-approval-receipts-missing-"));
    try {
      const path = voiceApprovalReceiptStorePath(dir);
      const store = new FileVoiceApprovalReceiptStore(path);
      expect(store.load()).toEqual([]);
      expect(() =>
        store.append({
          ...receipt(),
          transcript: "approve once",
        } as VoiceApprovalReceipt & { transcript: string }),
      ).toThrow("transcript");
      expect(store.load()).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("fails closed when the receipt log is unreadable", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-voice-approval-receipts-corrupt-"));
    try {
      const path = voiceApprovalReceiptStorePath(dir);
      writeFileSync(path, "{not-jsonl\n", { mode: 0o600 });
      expect(() => new FileVoiceApprovalReceiptStore(path).load()).toThrow(
        "Voice approval receipt store is unreadable",
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

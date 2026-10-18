import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import type { VoiceApprovalReceipt } from "./voice-approval-bridge.js";

const MAX_RECEIPTS = 10_000;
const MAX_LINE_CHARS = 16_384;

export function voiceApprovalReceiptStorePath(dataDir: string): string {
  return join(dataDir, "voice-approval-receipts.jsonl");
}

/**
 * Append-only audit sink for spoken approval outcomes.
 *
 * Receipts never include raw transcripts. A corrupt log fails closed on read.
 */
export class FileVoiceApprovalReceiptStore {
  constructor(private readonly path: string) {}

  append(receipt: VoiceApprovalReceipt): void {
    const sanitized = sanitizeReceipt(receipt);
    const line = `${JSON.stringify(sanitized)}\n`;
    if (line.length > MAX_LINE_CHARS) {
      throw new Error("Voice approval receipt is too large");
    }
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    appendFileSync(this.path, line, { mode: 0o600, flush: true });
  }

  load(): VoiceApprovalReceipt[] {
    if (!existsSync(this.path)) return [];
    let text: string;
    try {
      text = readFileSync(this.path, "utf8");
    } catch {
      throw new Error("Voice approval receipt store is unreadable");
    }
    const lines = text.split("\n").filter((line) => line.length > 0);
    if (lines.length > MAX_RECEIPTS) {
      throw new Error("Voice approval receipt store capacity is reached");
    }
    return lines.map((line, index) => parseReceiptLine(line, index));
  }
}

function sanitizeReceipt(receipt: VoiceApprovalReceipt): VoiceApprovalReceipt {
  const record = receipt as VoiceApprovalReceipt & { transcript?: unknown };
  if ("transcript" in record && record.transcript !== undefined) {
    throw new Error("Voice approval receipts must not include a transcript");
  }
  if (!receipt || typeof receipt !== "object") {
    throw new Error("Voice approval receipt is invalid");
  }
  if (typeof receipt.receiptId !== "string" || !receipt.receiptId.trim()) {
    throw new Error("Voice approval receipt is invalid");
  }
  if (typeof receipt.challengeId !== "string" || !receipt.challengeId.trim()) {
    throw new Error("Voice approval receipt is invalid");
  }
  if (typeof receipt.callId !== "string" || !receipt.callId.trim()) {
    throw new Error("Voice approval receipt is invalid");
  }
  if (typeof receipt.actionDigest !== "string" || !receipt.actionDigest.trim()) {
    throw new Error("Voice approval receipt is invalid");
  }
  return {
    receiptId: receipt.receiptId,
    challengeId: receipt.challengeId,
    callId: receipt.callId,
    controllerLeaseId: receipt.controllerLeaseId,
    controllerLeaseEpoch: receipt.controllerLeaseEpoch,
    deviceId: receipt.deviceId,
    sessionId: receipt.sessionId,
    requestId: receipt.requestId,
    actionDigest: receipt.actionDigest,
    targetRefs: [...receipt.targetRefs],
    decision: receipt.decision,
    receivedAt: receipt.receivedAt,
    validationOutcome: receipt.validationOutcome,
    deliveryOutcome: receipt.deliveryOutcome,
    ...(receipt.reason ? { reason: receipt.reason } : {}),
  };
}

function parseReceiptLine(line: string, index: number): VoiceApprovalReceipt {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new Error("Voice approval receipt store is unreadable");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`Voice approval receipt ${index} is invalid`);
  }
  return sanitizeReceipt(parsed as VoiceApprovalReceipt);
}

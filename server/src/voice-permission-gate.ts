import { createLogger } from "./logger.js";
import type { VoiceCallController } from "./continuous-voice-call.js";
import type { VoiceApprovalBridge, VoiceApprovalRisk } from "./voice-approval-bridge.js";

const log = createLogger({ base: { component: "voice_permission_gate" } });

export interface VoicePermissionGateOffer {
  source: "structured_permission_gate";
  sessionId: string;
  canonicalAction: Record<string, unknown>;
  targetRefs: readonly string[];
  policyRevision: string;
  risk: VoiceApprovalRisk;
  expiresAt: number;
  responses: {
    approveOnce: { confirmed: true };
    deny: { confirmed: false };
  };
  summary: string;
}

export interface VoicePermissionGateRequest {
  id: string;
  method: string;
  title?: string;
  message?: string;
}

/**
 * Trusted origin for spoken approval bindings.
 *
 * Only an explicit structured offer can arm the next confirm on that session.
 * Dialog titles and messages are ignored.
 */
export class VoicePermissionGate {
  private readonly offers = new Map<string, VoicePermissionGateOffer>();
  private readonly now: () => number;

  constructor(
    private readonly deps: {
      now?: () => number;
      bridge: VoiceApprovalBridge;
      calls: Pick<VoiceCallController, "activeAttachedCallId" | "presentApproval">;
    },
  ) {
    this.now = deps.now ?? Date.now;
  }

  expectNextConfirm(offer: VoicePermissionGateOffer): void {
    const sessionId = offer.sessionId.trim();
    if (!sessionId) throw new Error("Voice permission gate sessionId must not be empty");
    if (offer.source !== "structured_permission_gate") {
      throw new Error("Voice approval requires a structured permission gate");
    }
    if (offer.expiresAt <= this.now()) return;
    this.offers.set(sessionId, offer);
  }

  observeRequest(sessionId: string, request: VoicePermissionGateRequest): void {
    const offer = this.offers.get(sessionId);
    if (!offer) return;
    if (request.method !== "confirm") return;
    this.offers.delete(sessionId);
    if (offer.expiresAt <= this.now()) return;

    try {
      this.deps.bridge.registerBinding({
        source: "structured_permission_gate",
        sessionId: offer.sessionId,
        requestId: request.id,
        canonicalAction: offer.canonicalAction,
        targetRefs: offer.targetRefs,
        policyRevision: offer.policyRevision,
        risk: offer.risk,
        expiresAt: offer.expiresAt,
        responses: offer.responses,
      });
      if (offer.risk !== "voice_eligible") return;
      const callId = this.deps.calls.activeAttachedCallId();
      if (!callId) return;
      const challenge = this.deps.bridge.issueChallenge({
        callId,
        sessionId: offer.sessionId,
        requestId: request.id,
      });
      this.deps.calls.presentApproval(callId, {
        challenge,
        summary: offer.summary,
      });
    } catch (error) {
      log.warn("voice_permission_gate.present_failed", {
        sessionId,
        requestId: request.id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
}

import type { ScheduleApprovalRef } from "./types.js";

export type ScheduledMutationOrigin = "interactive" | "scheduled" | "background";

export type ScheduledMutationDecision =
  | { allowed: true; reason: "interactive" }
  | { allowed: true; reason: "accepted_approval_ref"; approvalRefId: string }
  | { allowed: false; reason: "missing_accepted_approval_ref" }
  | { allowed: false; reason: "expired_approval_ref"; approvalRefId: string };

export interface ScheduledMutationPolicyInput {
  origin: ScheduledMutationOrigin;
  approvalRefs?: readonly ScheduleApprovalRef[];
  nowMs?: number;
}

/**
 * Scheduled and background mutations fail closed unless a Pi extension supplied
 * an accepted opaque approval ref. Oppi does not interpret roles, scopes, tools,
 * or capabilities from the ref; active tool behavior remains extension-owned.
 */
export function decideScheduledMutation(
  input: ScheduledMutationPolicyInput,
): ScheduledMutationDecision {
  if (input.origin === "interactive") {
    return { allowed: true, reason: "interactive" };
  }

  const nowMs = input.nowMs ?? Date.now();
  const acceptedRefs = (input.approvalRefs ?? []).filter(isAcceptedApprovalRef);
  const liveRef = acceptedRefs.find((ref) => !isExpiredApprovalRef(ref, nowMs));
  if (liveRef) {
    return {
      allowed: true,
      reason: "accepted_approval_ref",
      approvalRefId: approvalRefAuditId(liveRef),
    };
  }

  const expiredRef = acceptedRefs.find((ref) => isExpiredApprovalRef(ref, nowMs));
  if (expiredRef) {
    return {
      allowed: false,
      reason: "expired_approval_ref",
      approvalRefId: approvalRefAuditId(expiredRef),
    };
  }

  return { allowed: false, reason: "missing_accepted_approval_ref" };
}

export function liveAcceptedApprovalRefAuditIds(
  approvalRefs: readonly ScheduleApprovalRef[] | undefined,
  nowMs = Date.now(),
): string[] {
  return (approvalRefs ?? [])
    .filter((ref) => isAcceptedApprovalRef(ref) && !isExpiredApprovalRef(ref, nowMs))
    .map(approvalRefAuditId);
}

function isAcceptedApprovalRef(ref: ScheduleApprovalRef): boolean {
  if (typeof ref === "string") return ref.trim().length > 0;
  if (!ref || typeof ref !== "object") return false;
  return ref.status === undefined || ref.status === "accepted";
}

function isExpiredApprovalRef(ref: ScheduleApprovalRef, nowMs: number): boolean {
  if (typeof ref === "string") return false;
  if (!ref || typeof ref !== "object") return false;
  return ref.status === "expired" || (ref.expiresAt !== undefined && ref.expiresAt <= nowMs);
}

export function approvalRefAuditId(ref: ScheduleApprovalRef): string {
  if (typeof ref === "string") return ref;
  if (typeof ref.id === "string" && ref.id.length > 0) return ref.id;
  if (typeof ref.ref === "string" && ref.ref.length > 0) return ref.ref;
  return "opaque-approval-ref";
}

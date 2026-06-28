// ─── Agent Schedules ───

/**
 * Opaque approval reference issued and interpreted by a Pi extension.
 * Oppi persists this for schedules and runs so clients can explain why a
 * scheduled mutation is allowed, but Oppi does not inspect capabilities,
 * permissions, roles, or scopes inside the ref.
 */
export type ScheduleApprovalRef = string | ScheduleApprovalRefEnvelope;

export interface ScheduleApprovalRefEnvelope {
  /** Opaque extension-owned token or payload. Oppi stores it but does not interpret it. */
  ref?: unknown;
  /** Stable display/audit handle when the extension provides one. */
  id?: string;
  status?: "accepted" | "rejected" | "expired" | "revoked";
  acceptedAt?: number;
  expiresAt?: number;
  display?: ScheduleApprovalDisplayMetadata;
  provenance?: ScheduleApprovalProvenanceMetadata;
}

export interface ScheduleApprovalDisplayMetadata {
  title?: string;
  summary?: string;
  extensionDisplayName?: string;
  extensionScopeId?: string;
}

export interface ScheduleApprovalProvenanceMetadata {
  sessionId?: string;
  requestId?: string;
  extensionScopeId?: string;
  extensionDisplayName?: string;
  recordedAt?: number;
}

export interface AgentSchedule {
  id: string;
  workspaceId: string;
  name?: string;
  prompt: string;
  enabled: boolean;
  createdAt: number;
  updatedAt: number;
  approvalRefs: ScheduleApprovalRef[];
}

export interface AgentScheduleRun {
  id: string;
  scheduleId: string;
  workspaceId: string;
  status: "queued" | "running" | "succeeded" | "failed" | "blocked";
  createdAt: number;
  updatedAt: number;
  sessionId?: string;
  approvalRefs: ScheduleApprovalRef[];
}

export interface ServerAgentExtensionAuditEventEnvelope {
  id: string;
  createdAt: number;
  eventType: string;
  workspaceId?: string;
  scheduleId?: string;
  runId?: string;
  sessionId?: string;
  approvalRefId?: string;
  display?: ScheduleApprovalDisplayMetadata;
  provenance?: ScheduleApprovalProvenanceMetadata;
  details?: Record<string, unknown>;
}

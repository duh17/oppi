import type { Session } from "../types.js";

export interface WorkspaceSessionSnapshotListOptions {
  recentDays?: number;
  status?: Session["status"];
  beforeLastActivity?: number;
  beforeSessionId?: string;
  limit?: number;
  nowMs?: number;
  maxLimit?: number;
}

export interface WorkspaceSessionSnapshotListResult {
  sessions: Session[];
  totalCount: number;
  filteredCount: number;
  remainingCount: number;
  cutoffMs?: number;
  appliedLimit: number;
}

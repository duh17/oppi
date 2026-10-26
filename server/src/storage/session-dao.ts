export interface WorkspaceSessionSummarySnapshot {
  workspaceId: string;
  activeCount: number;
  stoppedCount: number;
  hasErrorRoot: boolean;
  latestActivity?: number;
}

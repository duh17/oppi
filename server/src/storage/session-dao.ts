export interface WorkspaceSessionSummarySnapshot {
  workspaceId: string;
  activeCount: number;
  stoppedCount: number;
  hasErrorRoot: boolean;
  latestActivity?: number;
}

export interface WorkspaceStoppedTimeBucketSnapshot {
  bucketId: string;
  bucketKind: "day" | "month";
  startMs: number;
  endMs: number;
  itemCount: number;
  latestActivity?: number;
}

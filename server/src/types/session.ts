// ─── Sessions ───

export interface TokenUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

export interface SessionSummaryChangeStats {
  /** Count of mutating file tool calls (edit/write) observed in this session. */
  mutatingToolCalls: number;
  /** Number of successful compaction cycles observed in this session. */
  compactionCount?: number;
  /** Unique file count mutated by edit/write tools. */
  filesChanged: number;
  /** Deduplicated file paths changed in this session (bounded sample). */
  changedFiles: string[];
  /** Count of additional changed files not included in changedFiles sample. */
  changedFilesOverflow?: number;
  /** Best-effort aggregate line additions (from edit/write args). */
  addedLines: number;
  /** Best-effort aggregate line removals (from edit/write args). */
  removedLines: number;
}

export type SessionRuntimeKind = "oppi" | "pi-tui";

export interface PiTuiMirrorTerminalInfo {
  bridgeId?: string;
  hostname?: string;
  pid?: number;
  cwd?: string;
  connectedAt?: number;
  lastSeenAt?: number;
  disconnectedAt?: number;
  disconnectReason?: string;
}

export interface PiTuiMirrorSessionMetadata {
  status: "connected" | "disconnected";
  terminal?: PiTuiMirrorTerminalInfo;
  capabilities?: string[];
  protocolVersion?: number;
}

export interface SessionChangeStats extends SessionSummaryChangeStats {
  /**
   * @internal Per-file line count tracking for accurate write deltas.
   * Maps file path → last known line count so repeated writes to the same
   * file compute a delta instead of counting the full content as added.
   * Persisted to disk but ignored by iOS (unknown Codable keys are skipped).
   */
  _fileLineCounts?: Record<string, number>;
  /**
   * @internal Paths of files first created (written from scratch) in this session.
   * For these files, line removals from edits reduce addedLines instead of
   * incrementing removedLines, because the pre-session baseline is 0 — you
   * can't "remove" lines that never existed.
   */
  _sessionCreatedFiles?: string[];
}

export interface Session {
  id: string;
  workspaceId?: string; // workspace that owns this session
  workspaceName?: string; // denormalized for display
  worktreeId?: string; // workspace checkout that owns this session; absent sessions use main
  name?: string;
  status: "starting" | "ready" | "busy" | "stopping" | "stopped" | "error";
  createdAt: number;
  lastActivity: number;
  /** Timestamp (ms) of the latest live assistant message_end observed by this server. */
  lastAgentReplyAt?: number;
  /** Timestamp (ms) when the currently active agent turn began. */
  currentTurnStartedAt?: number;
  model?: string;

  // Stats
  messageCount: number;
  tokens: TokenUsage;
  cost: number;
  changeStats?: SessionChangeStats;

  // Context usage (pi TUI-style)
  contextTokens?: number; // input+output+cacheRead+cacheWrite from last message
  contextWindow?: number; // model's total context window

  // Preview
  firstMessage?: string; // first user message (immutable once set)
  lastMessage?: string;

  // Health
  warnings?: string[]; // bootstrap/session warnings surfaced to iOS

  // Agent config state (synced from pi get_state)
  thinkingLevel?: string; // "off" | "minimal" | "low" | "medium" | "high" | "xhigh"

  // Runtime ownership. New sessions persist this explicitly as "oppi" or "pi-tui".
  runtime?: SessionRuntimeKind;
  mirror?: PiTuiMirrorSessionMetadata;

  // Trace metadata (used for trace recovery/replay)
  // Local pi JSONL paths under ~/.pi/agent/sessions are deleted with the Oppi
  // session so deleted sessions are not rediscovered as importable local sessions.
  piSessionFile?: string; // latest absolute JSONL path reported by pi get_state
  piSessionFiles?: string[]; // all observed session JSONL paths for this session
  piSessionId?: string; // pi internal session UUID reported by get_state

  // Privacy / persistence
  ephemeral?: boolean; // true for in-memory pi sessions (incognito mode)
}

/**
 * Session projection for workspace lists and cross-session status surfaces.
 *
 * This is the cold lane for mobile UI. It intentionally excludes trace paths,
 * warnings, and other non-list metadata so high-frequency live events do not
 * have to broadcast full `Session` snapshots.
 */
export interface SessionSummary {
  id: string;
  workspaceId?: string;
  workspaceName?: string;
  worktreeId?: string;
  name?: string;
  status: Session["status"];
  createdAt: number;
  lastActivity: number;
  lastAgentReplyAt?: number;
  currentTurnStartedAt?: number;
  model?: string;
  messageCount: number;
  tokens: TokenUsage;
  cost: number;
  changeStats?: SessionSummaryChangeStats;
  contextTokens?: number;
  contextWindow?: number;
  firstMessage?: string;
  lastMessage?: string;
  thinkingLevel?: string;
  runtime?: SessionRuntimeKind;
  mirror?: PiTuiMirrorSessionMetadata;
  /** Pi internal session UUID for generic session identity matching. */
  piSessionId?: string;
  ephemeral?: boolean;
  /** Cold-list ask badge count; omitted outside list endpoints. */
  pendingAskCount?: number;
}

export interface SessionMessage {
  id: string;
  sessionId: string;
  role: "user" | "assistant" | "system";
  content: string;
  timestamp: number;

  // For assistant messages
  model?: string;
  tokens?: { input: number; output: number; cacheRead?: number; cacheWrite?: number };
  cost?: number;
}

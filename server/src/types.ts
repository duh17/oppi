/**
 * Core types for oppi-server.
 */

// ─── Workspaces ───

export type WorkspaceSystemPromptMode = "append" | "replace";

export interface Workspace {
  id: string;
  name: string; // "coding", "research"
  description?: string; // shown in workspace picker
  icon?: string; // SF Symbol name or emoji

  // Skills — which skills to sync into the session
  skills: string[]; // ["searxng", "fetch", "ast-grep"]

  // Permissions
  allowedPaths?: { path: string; access: "read" | "readwrite" }[]; // Extra dirs beyond workspace
  allowedExecutables?: string[]; // Extra executables auto-allowed for this workspace (e.g. ["node", "python3"])

  // Context
  systemPrompt?: string; // Workspace prompt text (appended or replacement depending on mode)
  systemPromptMode: WorkspaceSystemPromptMode;
  hostMount?: string; // Host directory to mount as /work (e.g. "~/workspace/oppi")
  defaultModel?: string; // Optional default model for new sessions in this workspace

  // Extensions
  // Undefined = discovered pi extensions only. Defined = authoritative allowlist.
  extensions?: string[]; // Extension allowlist (host extensions + Oppi names like ask/subagents/voice)

  // Git status
  gitStatusEnabled?: boolean; // Show git status context bar (default: true)

  // Runtime
  /** Workspace runtime mode. "host" = direct execution, "sandbox" = Gondolin micro-VM. */
  runtime?: "host" | "sandbox";
  /** Sandbox configuration (only used when runtime is "sandbox"). */
  sandboxConfig?: {
    /** Allowed egress hosts for network access. Default: ["*"] (all). */
    allowedHosts?: string[];
    /** Extra environment variables injected into the sandbox VM. */
    env?: Record<string, string>;
  };

  // Metadata
  createdAt: number;
  updatedAt: number;
}

// ─── Sessions ───

export interface SessionChangeStats {
  /** Count of mutating file tool calls (edit/write) observed in this session. */
  mutatingToolCalls: number;
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
  workspaceId?: string; // which workspace spawned this session
  workspaceName?: string; // denormalized for display
  name?: string;
  status: "starting" | "ready" | "busy" | "stopping" | "stopped" | "error";
  createdAt: number;
  lastActivity: number;
  /** Timestamp (ms) when the currently active agent turn began. */
  currentTurnStartedAt?: number;
  model?: string;

  // Stats
  messageCount: number;
  tokens: { input: number; output: number; cacheRead: number; cacheWrite: number };
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

  // Trace metadata (used for trace recovery/replay)
  // Local pi JSONL paths under ~/.pi/agent/sessions are deleted with the Oppi
  // session so deleted sessions are not rediscovered as importable local sessions.
  piSessionFile?: string; // latest absolute JSONL path reported by pi get_state
  piSessionFiles?: string[]; // all observed session JSONL paths for this session
  piSessionId?: string; // pi internal session UUID reported by get_state

  // Privacy / persistence
  ephemeral?: boolean; // true for in-memory pi sessions (incognito mode)

  // Parent-child tree (spawn_agent)
  parentSessionId?: string; // set when spawned by another session
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

// ─── Server Config ───

export type PolicyDecision = "allow" | "ask" | "block";

export interface PolicyMatch {
  tool?: string;
  executable?: string;
  commandMatches?: string;
  pathMatches?: string;
  pathWithin?: string;
  domain?: string;
}

export interface PolicyPermission {
  id: string;
  decision: PolicyDecision;

  label?: string;
  reason?: string;
  match: PolicyMatch;
}

/**
 * Named heuristics — complex detection logic that can't be expressed as globs.
 * Each key maps to the action taken when the heuristic triggers.
 * Set to `false` to disable a heuristic entirely.
 */
export interface PolicyHeuristics {
  /** Detect `| sh`, `| bash` — arbitrary code execution via pipe. Default: "ask" */
  pipeToShell?: PolicyDecision | false;
  /** Detect curl -d, wget --post-data, etc. — outbound data transfer. Default: "ask" */
  dataEgress?: PolicyDecision | false;
  /** Detect $API_KEY, $SECRET in curl URLs — credential leakage. Default: "ask" */
  secretEnvInUrl?: PolicyDecision | false;
  /** Detect reads of ~/.ssh/, ~/.aws/, .env, etc. via cat/head/read. Default: "block" */
  secretFileAccess?: PolicyDecision | false;
}

export interface PolicyConfig {
  schemaVersion: 1;
  mode?: string;
  description?: string;
  fallback: PolicyDecision;
  guardrails: PolicyPermission[];
  permissions: PolicyPermission[];
  /** Named heuristics for complex pattern detection. Omit to use defaults. */
  heuristics?: PolicyHeuristics;
}

export type TlsMode = "auto" | "tailscale" | "cloudflare" | "self-signed" | "manual" | "disabled";

export interface TlsConfig {
  mode: TlsMode;
  certPath?: string;
  keyPath?: string;
  caPath?: string;
}

export interface UploadStoreConfig {
  mode?: "local";
  path?: string;
  maxFileBytes?: number;
  maxTurnBytes?: number;
  unusedTtlMs?: number;
  retainedTtlMs?: number;
  allowedMimeTypes?: string[];
}

export interface ServerConfig {
  configVersion?: number;
  port: number;
  host: string;
  dataDir: string;
  sessionIdleTimeoutMs: number;
  workspaceIdleTimeoutMs: number;
  maxSessionsPerWorkspace: number;
  maxSessionsGlobal: number;
  /** Permission approval timeout in milliseconds. Set to 0 to disable expiry. */
  approvalTimeoutMs?: number;
  /** Set to false to disable the permission gate. All tool calls run without approval. */
  permissionGate?: boolean;

  /** PATH entries used for runtime tool execution. */
  runtimePathEntries?: string[];
  /** Additional runtime environment variables. */
  runtimeEnv?: Record<string, string>;

  /** Transport security (HTTPS/WSS). */
  tls?: TlsConfig;

  /** Declarative global policy config (guardrails + permissions). */
  policy?: PolicyConfig;

  // Owner/admin bearer token
  token?: string;

  // One-time pairing token bootstrap state
  pairingToken?: string;
  pairingTokenExpiresAt?: number;

  // Device auth state (issued during pairing)
  authDeviceTokens?: string[];

  // Push notification state (written by iOS client registration)
  pushDeviceTokens?: string[];
  liveActivityToken?: string;

  /**
   * Auto-title configuration. When enabled, generates concise task titles
   * for sessions using a configurable model provider.
   */
  autoTitle?: {
    enabled: boolean;
    model?: string; // "provider/model-id" (e.g. "anthropic/claude-haiku-3")
  };

  /**
   * ASR / dictation pipeline configuration. Controls remote dictation routing
   * by pointing Oppi at an STT backend endpoint.
   */
  asr?: {
    sttEndpoint?: string;
  };

  /** Local upload store config for chat attachments. */
  uploadStore?: UploadStoreConfig;

  /**
   * Server-managed extension configuration and lightweight persisted state.
   */
  extensions?: {
    voice?: {
      defaultVoiceId?: string;
    };
    subagents?: SubagentConfig;
  };
}

export interface SubagentModelProfileConfig {
  /** Human-readable summary of what this profile is for. */
  description?: string;
  /** Model to use when this profile is selected and spawn_agent omits model. */
  model?: string;
  /** Thinking level to use when this profile is selected and spawn_agent omits thinking. */
  thinking?: string;
  /** Extra instructions injected ahead of the child prompt for this profile. */
  guidelines?: string[];
}

export interface SubagentModelPolicyConfig {
  /** Approved full model IDs for subagents. Empty/omitted means any available model. */
  approvedModels?: string[];
  /** Default model when spawn_agent omits model. */
  defaultModel?: string;
  /** Default thinking level when spawn_agent omits thinking. */
  defaultThinking?: string;
  /** Named presets such as discovery/research/coding/review. */
  profiles?: Record<string, SubagentModelProfileConfig>;
}

export interface SubagentConfig {
  /** How many levels deep agents can spawn other agents.
   *  1 = parent→child only (no grandchildren). 2 = allows grandchildren.
   *  Default: 1 */
  maxDepth: number;
  /** Whether children automatically stop after completing their work.
   *  When true, a child that finishes and goes idle is stopped immediately.
   *  When false, children stay alive until childIdleTimeoutMs expires.
   *  Default: false */
  autoStopWhenDone: boolean;
  /** How long (ms) a child session stays alive after completing its work
   *  when autoStopWhenDone is false. Matches typical prompt-cache TTL so
   *  follow-up messages can reuse the cached context.
   *  Default: 300000 (5 min) */
  childIdleTimeoutMs: number;
  /** How long (ms) to wait for a child to start producing output before
   *  giving up. Covers VM boot time, model loading, and first LLM call.
   *  Default: 60000 (60s) */
  startupGraceMs: number;
  /** Default timeout (ms) for spawn_agent(wait=true) when the caller
   *  doesn't specify timeout_seconds.
   *  Default: 1800000 (30 min) */
  defaultWaitTimeoutMs: number;
  /** Optional model governance for subagents: approved model IDs,
   *  default model/thinking, and named usage profiles. */
  modelPolicy?: SubagentModelPolicyConfig;
}

// ─── API Types ───

export interface ApiError {
  error: string;
  code?: string;
}

// ─── Shared UI payload types ───

export interface StyledSegment {
  text: string;
  style?: "bold" | "muted" | "dim" | "accent" | "success" | "warning" | "error";
}

// ─── Git status ───

export interface GitFileStatus {
  /** Two-char status code from `git status --porcelain` (e.g. " M", "??", "A ") */
  status: string;
  /** File path relative to repo root */
  path: string;
  /** Lines added vs HEAD (null for binary/untracked) */
  addedLines: number | null;
  /** Lines removed vs HEAD (null for binary/untracked) */
  removedLines: number | null;
}

export interface GitCommitSummary {
  /** Short SHA (7-char) */
  sha: string;
  /** Commit subject line */
  message: string;
  /** ISO timestamp */
  date: string;
}

export interface GitCommitFileInfo {
  /** File path relative to repo root */
  path: string;
  /** Change status (M=modified, A=added, D=deleted, etc.) */
  status: string;
  /** Lines added (null for binary files) */
  addedLines: number | null;
  /** Lines removed (null for binary files) */
  removedLines: number | null;
}

export interface GitCommitDetail {
  /** Short SHA (7-char) */
  sha: string;
  /** Commit subject line */
  message: string;
  /** ISO timestamp */
  date: string;
  /** Author name and email */
  author: string;
  /** Files changed in this commit */
  files: GitCommitFileInfo[];
  /** Total lines added */
  addedLines: number;
  /** Total lines removed */
  removedLines: number;
}

export interface GitStatus {
  /** Whether the directory is a git repo */
  isGitRepo: boolean;
  /** Current branch name (null if detached HEAD) */
  branch: string | null;
  /** Short SHA of HEAD */
  headSha: string | null;
  /** Commits ahead of upstream (null if no upstream) */
  ahead: number | null;
  /** Commits behind upstream (null if no upstream) */
  behind: number | null;
  /** Number of dirty (uncommitted) files */
  dirtyCount: number;
  /** Number of untracked files */
  untrackedCount: number;
  /** Number of staged files */
  stagedCount: number;
  /** Individual file statuses (capped to first 500) */
  files: GitFileStatus[];
  /** Total file count if capped */
  totalFiles: number;
  /** Total lines added vs HEAD (tracked files only) */
  addedLines: number;
  /** Total lines removed vs HEAD (tracked files only) */
  removedLines: number;
  /** Number of stash entries */
  stashCount: number;
  /** Most recent commit subject line */
  lastCommitMessage: string | null;
  /** ISO timestamp of most recent commit */
  lastCommitDate: string | null;
  /** Recent commits (newest first, capped at 20) */
  recentCommits: GitCommitSummary[];
}

export interface WorkspaceReviewFile {
  /** Relative file path from repo root. */
  path: string;
  /** Two-char status code derived from `git status --porcelain`. */
  status: string;
  /** Lines added vs HEAD (null for binary/untracked). */
  addedLines: number | null;
  /** Lines removed vs HEAD (null for binary/untracked). */
  removedLines: number | null;
  /** File has staged changes in the index. */
  isStaged: boolean;
  /** File has unstaged changes in the working tree. */
  isUnstaged: boolean;
  /** File is untracked. */
  isUntracked: boolean;
  /** File path was touched by the selected session. */
  selectedSessionTouched: boolean;
}

export interface WorkspaceReviewFilesResponse {
  workspaceId: string;
  isGitRepo: boolean;
  branch: string | null;
  headSha: string | null;
  ahead: number | null;
  behind: number | null;
  changedFileCount: number;
  stagedFileCount: number;
  unstagedFileCount: number;
  untrackedFileCount: number;
  addedLines: number;
  removedLines: number;
  selectedSessionId?: string;
  selectedSessionTouchedCount: number;
  files: WorkspaceReviewFile[];
}

export interface WorkspaceReviewDiffSpan {
  start: number;
  end: number;
  kind: "changed";
}

export interface WorkspaceReviewDiffLine {
  kind: "context" | "added" | "removed";
  text: string;
  oldLine: number | null;
  newLine: number | null;
  spans?: WorkspaceReviewDiffSpan[];
}

export interface WorkspaceReviewDiffHunk {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  lines: WorkspaceReviewDiffLine[];
}

export interface WorkspaceReviewDiffResponse {
  workspaceId: string;
  path: string;
  baselineText: string;
  currentText: string;
  addedLines: number;
  removedLines: number;
  hunks: WorkspaceReviewDiffHunk[];
  /** Number of trace mutations (session overall-diff only). */
  revisionCount?: number;
  /** Cache key for client-side caching (session overall-diff only). */
  cacheKey?: string;
}

export type WorkspaceReviewSessionAction = "review" | "reflect" | "prepare_commit";

export interface CreateWorkspaceReviewSessionRequest {
  action: WorkspaceReviewSessionAction;
  paths: string[];
  selectedSessionId?: string;
}

export interface WorkspaceReviewSessionResponse {
  action: WorkspaceReviewSessionAction;
  selectedPathCount: number;
  session: Session;
  visiblePrompt: string;
  filePaths: string[];
}

export type ReviewCommentAuthor = "human" | "agent";
export type ReviewCommentStatus = "staged" | "sent" | "open" | "resolved" | "dismissed";
export type ReviewCommentSeverity = "error" | "warning" | "info";
export type ReviewCommentReferenceSource =
  | "git_diff"
  | "file"
  | "timeline_text"
  | "tool_output"
  | "terminal_output"
  | "image"
  | "unknown";

export interface ReviewCommentReference {
  source: ReviewCommentReferenceSource;
  label?: string;
  path?: string;
  side?: "old" | "new" | "file";
  startLine?: number;
  endLine?: number;
  selectedText?: string;
  languageHint?: string;
  toolCallId?: string;
  timelineItemId?: string;
  url?: string;
}

export interface ReviewCommentAttachment {
  id: string;
  kind: "image";
  mimeType: string;
  width?: number;
  height?: number;
  storageKey: string;
}

export interface ReviewComment {
  id: string;
  workspaceId: string;
  sessionId?: string;
  turnId?: string;
  author: ReviewCommentAuthor;
  status: ReviewCommentStatus;
  severity?: ReviewCommentSeverity;
  body: string;
  attachments?: ReviewCommentAttachment[];
  reference: ReviewCommentReference;
  createdAt: number;
  updatedAt: number;
  sentAt?: number;
}

export interface CreateReviewCommentRequest {
  sessionId?: string;
  author?: ReviewCommentAuthor;
  status?: ReviewCommentStatus;
  severity?: ReviewCommentSeverity;
  body: string;
  attachments?: ReviewCommentAttachment[];
  reference: ReviewCommentReference;
}

export interface UpdateReviewCommentRequest {
  status?: ReviewCommentStatus;
  severity?: ReviewCommentSeverity | null;
  body?: string;
}

export interface AttachReviewCommentsToTurnRequest {
  ids: string[];
  sessionId?: string;
  turnId?: string;
}

// ─── Workspace File Browser ───

export interface FileEntry {
  name: string;
  type: "file" | "directory";
  size: number;
  /** Milliseconds since epoch. */
  modifiedAt: number;
  /** Workspace-relative path (present in search results). */
  path?: string;
}

/** Directory listing response shape (GET /workspaces/:id/files/<dir>/). */
export interface DirectoryListingResponse {
  path: string;
  entries: FileEntry[];
  truncated: boolean;
}

/** File search response shape (GET /workspaces/:id/files?search=<q>). */
export interface FileSearchResponse {
  query: string;
  entries: FileEntry[];
  truncated: boolean;
}

/** Flat file index for client-side fuzzy search (GET /workspaces/:id/file-index). */
export interface FileIndexResponse {
  /** Workspace-relative file paths (no directories, no ignored/sensitive paths). */
  paths: string[];
  truncated: boolean;
}

// ─── Local Sessions ───

/** A pi TUI session discovered on the host (not yet managed by oppi). */
export interface LocalSession {
  /** Absolute path to the JSONL file. */
  path: string;
  /** Pi session UUID from the JSONL header. */
  piSessionId: string;
  /** Working directory where the session was started. */
  cwd: string;
  /** User-defined display name (from /name command), if set. */
  name?: string;
  /** First user message preview. */
  firstMessage?: string;
  /** Last model used (provider/modelId format). */
  model?: string;
  /** Number of user+assistant messages. */
  messageCount: number;
  /** Session creation timestamp (ms). */
  createdAt: number;
  /** File last-modified timestamp (ms). */
  lastModified: number;
}

export interface CreateWorkspaceRequest {
  name: string;
  description?: string;
  icon?: string;
  skills: string[];
  allowedPaths?: { path: string; access: "read" | "readwrite" }[];
  allowedExecutables?: string[];
  systemPrompt?: string;
  systemPromptMode?: WorkspaceSystemPromptMode;
  hostMount?: string;
  defaultModel?: string;
  extensions?: string[];
  gitStatusEnabled?: boolean;
  runtime?: "host" | "sandbox";
  sandboxConfig?: { allowedHosts?: string[]; env?: Record<string, string> };
}

export interface UpdateWorkspaceRequest {
  name?: string;
  description?: string | null;
  icon?: string | null;
  skills?: string[];
  allowedPaths?: { path: string; access: "read" | "readwrite" }[];
  allowedExecutables?: string[];
  systemPrompt?: string | null;
  systemPromptMode?: WorkspaceSystemPromptMode;
  hostMount?: string | null;
  defaultModel?: string | null;
  extensions?: string[];
  gitStatusEnabled?: boolean;
  runtime?: "host" | "sandbox";
  sandboxConfig?: { allowedHosts?: string[]; env?: Record<string, string> } | null;
}

export function telemetryUploadsEnabledFromEnv(mode = process.env.OPPI_TELEMETRY_MODE): boolean {
  const raw = mode?.trim().toLowerCase() ?? "";
  if (!raw) {
    return true;
  }

  switch (raw) {
    case "internal":
    case "debug":
    case "test":
    case "qa":
    case "staging":
    case "dev":
    case "development":
    case "enabled":
    case "on":
    case "true":
    case "1":
      return true;
    case "public":
    case "release":
    case "prod":
    case "production":
    case "off":
    case "disabled":
    case "none":
    case "false":
    case "0":
      return false;
    default:
      return false;
  }
}

export interface MetricKitPayloadItem {
  /** "metric" (MXMetricPayload) or "diagnostic" (MXDiagnosticPayload). */
  kind: "metric" | "diagnostic";
  /** Window start of telemetry sample (ms since epoch). */
  windowStartMs: number;
  /** Window end of telemetry sample (ms since epoch). */
  windowEndMs: number;
  /** Low-cardinality summary suitable for dashboards/alerts. */
  summary: Record<string, string>;
  /** Sanitized raw payload JSON for later inspection/replay. */
  raw: Record<string, unknown> | string;
}

export interface MetricKitUploadRequest {
  generatedAt: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  payloads: MetricKitPayloadItem[];
}

export type ChatMetricUnit = "ms" | "count" | "ratio";

export interface ChatMetricDefinition {
  unit: ChatMetricUnit;
  description: string;
}

/**
 * Single source of truth for chat metric contracts.
 *
 * Add new metrics here first, then emit from clients and surface in dashboards.
 */
export const CHAT_METRIC_REGISTRY = {
  "chat.ttft_ms": {
    unit: "ms",
    description: "Time-to-first-token latency for a user turn.",
  },
  "chat.catchup_ms": {
    unit: "ms",
    description: "Catch-up replay latency when (re)subscribing to a session stream.",
  },
  "chat.catchup_ring_miss": {
    unit: "count",
    description: "Count of catch-up ring misses that required a fallback path.",
  },
  "chat.timeline_apply_ms": {
    unit: "ms",
    description: "Reducer apply latency (threshold-gated, only emitted when >= 4ms).",
  },
  "chat.timeline_layout_ms": {
    unit: "ms",
    description: "Timeline layout latency (threshold-gated, only emitted when >= 2ms).",
  },
  // Removed: chat.ws_decode_ms (high-volume noise, build 21)
  "chat.session_load_ms": {
    unit: "ms",
    description: "End-to-end session load latency from tap to content visible.",
  },
  "chat.jank_pct": {
    unit: "ratio",
    description: "Percentage of render cycles exceeding 16ms frame budget during streaming.",
  },
  "chat.timeline_hitch": {
    unit: "count",
    description: "Frame budget hitch detected during collection view apply cycle.",
  },
  "chat.coalescer_flush_events": {
    unit: "count",
    description: "Event count flushed per coalescer batch.",
  },
  "chat.coalescer_flush_bytes": {
    unit: "count",
    description: "Payload byte count flushed per coalescer batch.",
  },
  "chat.full_reload_ms": {
    unit: "ms",
    description: "Latency for full timeline reload fallback path.",
  },
  "chat.fresh_content_lag_ms": {
    unit: "ms",
    description: "Lag between new content arrival and visible timeline freshness.",
  },
  "chat.cache_load_ms": {
    unit: "ms",
    description: "Client-side cache load latency.",
  },
  "chat.reducer_load_ms": {
    unit: "ms",
    description: "Reducer reconstruction/load latency from cached state.",
  },
  "chat.ws_wait_for_connected_ms": {
    unit: "ms",
    description: "Client wait for /stream to reach connected before session subscribe.",
  },
  "chat.command_send_ms": {
    unit: "ms",
    description: "Client command send path duration until WebSocket send returns.",
  },
  "chat.command_roundtrip_ms": {
    unit: "ms",
    description:
      "Client command request/response duration until correlated command_result resolves.",
  },
  "chat.command_resolve_lag_ms": {
    unit: "ms",
    description: "Client lag from command_result frame receipt to command waiter resolution.",
  },
  // Removed: chat.stream_open_ms — p50=0ms, never measures real latency
  "chat.subscribe_gate_ms": {
    unit: "ms",
    description: "Client-observed full subscription gate latency for session commands.",
  },
  "chat.queue_sync_ms": {
    unit: "ms",
    description: "Latency for initial queue snapshot refresh (get_queue command).",
  },
  "chat.resubscribe_ms": {
    unit: "ms",
    description: "Client resubscribe duration after reconnect or not-subscribed recovery.",
  },
  "chat.silent_resubscribe_count": {
    unit: "count",
    description: "Silent resubscribe attempts triggered by not-subscribed recovery.",
  },
  "chat.subscription_race_count": {
    unit: "count",
    description: "Recovered not-subscribed race detections on the client stream.",
  },
  "chat.message_queue_ack_ms": {
    unit: "ms",
    description: "Latency from message queue send to server acknowledgement.",
  },
  "chat.message_queue_stale_drop": {
    unit: "count",
    description: "Messages dropped from queue due to stale session state.",
  },
  "chat.message_queue_start_miss": {
    unit: "count",
    description: "Queue messages sent before session start was confirmed.",
  },
  "chat.session_message_count": {
    unit: "count",
    description: "Per-session cumulative message count snapshot.",
  },
  "chat.session_input_tokens": {
    unit: "count",
    description: "Per-session cumulative input token count snapshot.",
  },
  "chat.session_output_tokens": {
    unit: "count",
    description: "Per-session cumulative output token count snapshot.",
  },
  // Removed: chat.session_total_tokens — 100% redundant (input + output)
  "chat.session_mutating_tool_calls": {
    unit: "count",
    description: "Per-session cumulative mutating tool call count snapshot.",
  },
  "chat.session_files_changed": {
    unit: "count",
    description: "Per-session cumulative unique changed file count snapshot.",
  },
  "chat.session_added_lines": {
    unit: "count",
    description: "Per-session cumulative added line count snapshot.",
  },
  "chat.session_removed_lines": {
    unit: "count",
    description: "Per-session cumulative removed line count snapshot.",
  },
  "chat.session_context_tokens": {
    unit: "count",
    description: "Latest session context token usage snapshot.",
  },
  "chat.session_context_window": {
    unit: "count",
    description: "Latest session context window size snapshot.",
  },
  "chat.voice_prewarm_ms": {
    unit: "ms",
    description: "Voice pipeline prewarm latency.",
  },
  "chat.voice_setup_ms": {
    unit: "ms",
    description: "Voice capture/setup latency.",
  },
  "chat.voice_first_result_ms": {
    unit: "ms",
    description: "Voice first-result latency.",
  },
  "chat.voice_playback_start_ms": {
    unit: "ms",
    description:
      "Audio playback startup latency for voice replies and replayable voice media. Tags: source, mode, status.",
  },
  "chat.voice_playback_error": {
    unit: "count",
    description: "Audio playback failure count. Tags: source, phase, error_kind.",
  },
  "chat.voice_remote_chunk_upload_ms": {
    unit: "ms",
    description: "Remote ASR chunk upload/request latency.",
  },
  "chat.voice_remote_chunk_audio_ms": {
    unit: "ms",
    description: "Audio duration covered by each uploaded remote ASR chunk.",
  },
  "chat.voice_remote_chunk_bytes": {
    unit: "count",
    description: "Encoded WAV byte size for each remote ASR chunk.",
  },
  "chat.voice_remote_chunk_chars": {
    unit: "count",
    description: "Character count returned per successful remote ASR chunk.",
  },
  "chat.voice_remote_chunk_error": {
    unit: "count",
    description: "Count of remote ASR chunk upload/transcription errors.",
  },
  // ── Dictation session metrics ──
  "chat.dictation_setup_ms": {
    unit: "ms",
    description: "Server dictation session setup latency (WS connect + ready).",
  },
  "chat.dictation_first_result_ms": {
    unit: "ms",
    description: "Time from recording start to first transcription result.",
  },
  "chat.dictation_finalize_ms": {
    unit: "ms",
    description: "Server-side finalization latency (stop to final text).",
  },
  "chat.dictation_session_ms": {
    unit: "ms",
    description: "Total dictation session duration from start to stop.",
  },
  "chat.dictation_audio_duration_ms": {
    unit: "ms",
    description: "Audio recording duration within a dictation session.",
  },
  "chat.dictation_result_updates": {
    unit: "count",
    description: "Number of transcript update events during a dictation session.",
  },
  "chat.dictation_preview_final_delta": {
    unit: "ratio",
    description:
      "Edit distance ratio between preview and final transcript (0=identical, 1=completely different).",
  },
  "chat.dictation_error": {
    unit: "count",
    description: "Dictation error count. Tags: phase, error_kind.",
  },
  "chat.dictation_cancel": {
    unit: "count",
    description: "Dictation session cancellation count.",
  },

  "chat.cell_configure_ms": {
    unit: "ms",
    description:
      "Cell configure latency for tool rows. Tags: expanded, content_type, tool, output_bytes.",
  },
  "chat.render_strategy_ms": {
    unit: "ms",
    description:
      "Internal render strategy time for tool row content. Tags: mode, input_bytes, language.",
  },

  "chat.markdown_streaming_ms": {
    unit: "ms",
    description:
      "Streaming markdown full-cycle render cost (parse + build + view apply). Tags: surface, segments.",
  },

  // ── App-level UX latency ──
  "chat.app_launch_ms": {
    unit: "ms",
    description: "Cold/warm app launch to first meaningful content visible.",
  },
  "chat.session_switch_ms": {
    unit: "ms",
    description: "Session switch latency: tap session row to chat content visible. Tags: cached.",
  },
  "chat.permission_overlay_ms": {
    unit: "ms",
    description: "Permission overlay display to user tap (allow/deny). Tags: action.",
  },
  "chat.share_export_ms": {
    unit: "ms",
    description:
      "Share sheet export rendering duration (offscreen render to shareable format). Tags: format, content_type.",
  },
  "chat.share_prepare_ms": {
    unit: "ms",
    description:
      "Shared-session redaction preflight duration. Tags: status, blocked, can_publish, findings, replacements, emails, phones, user_paths, ip_addresses, jwt_bearer, names, skills.",
  },
  "chat.share_publish_ms": {
    unit: "ms",
    description:
      "Shared-session publish duration. Tags: status, findings, replacements, emails, phones, user_paths, ip_addresses, jwt_bearer, names, skills.",
  },
  "chat.share_error": {
    unit: "count",
    description: "Shared-session request failure count. Tags: action, error_kind.",
  },
  "chat.quick_session_create_ms": {
    unit: "ms",
    description:
      "Quick session creation duration. Tags: source, status, selection, has_message, has_attachments, has_repo_refs, has_model.",
  },
  "chat.quick_session_error": {
    unit: "count",
    description: "Quick session failure count. Tags: source, selection, error_kind.",
  },
  "chat.tool_update_count": {
    unit: "count",
    description:
      "Ephemeral tool update messages received by the active chat session. Tags: tool, has_segments.",
  },

  // ── Session list rendering ──
  "chat.session_list_compute_ms": {
    unit: "ms",
    description:
      "Session list viewData computation latency. Tags: active_count, stopped_count, workspace_id.",
  },
  "chat.session_list_body_rate": {
    unit: "count",
    description:
      "Session list body evaluation count per 5-second window. High values indicate store churn.",
  },
  "chat.session_list_row_compute_ms": {
    unit: "ms",
    description:
      "Aggregate per-row computation latency for visible session rows. Tags: row_count, workspace_id.",
  },

  // ── Device resource samples (10s interval) ──
  "device.cpu_pct": {
    unit: "count",
    description:
      "Device CPU usage percentage (0-100+) computed from Mach task_info deltas over 10s window.",
  },
  "device.memory_mb": {
    unit: "count",
    description: "Device physical memory footprint in MB (phys_footprint from task_vm_info).",
  },
  "device.memory_available_mb": {
    unit: "count",
    description: "Available memory headroom in MB before jetsam (os_proc_available_memory).",
  },
  "device.thermal_state": {
    unit: "count",
    description: "Device thermal state: 0=nominal, 1=fair, 2=serious, 3=critical.",
  },
} as const satisfies Readonly<Record<string, ChatMetricDefinition>>;

export type ChatMetricName = keyof typeof CHAT_METRIC_REGISTRY;

export const CHAT_METRIC_NAME_VALUES = Object.freeze(
  Object.keys(CHAT_METRIC_REGISTRY) as ChatMetricName[],
);

export interface ChatMetricSample {
  ts: number;
  metric: ChatMetricName;
  value: number;
  unit: ChatMetricUnit;
  sessionId?: string;
  workspaceId?: string;
  tags?: Record<string, string>;
}

export interface ChatMetricUploadRequest {
  generatedAt: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  samples: ChatMetricSample[];
}

// ─── WebSocket Messages ───

export interface ImageAttachment {
  data: string; // base64
  mimeType: string; // image/jpeg, image/png, etc.
}

export type AttachmentKind = "image" | "text" | "pdf" | "audio" | "video" | "archive" | "unknown";

export type AttachmentSource = "upload" | "workspace";

export interface ChatAttachmentRef {
  type: "attachment";
  id: string;
  source: AttachmentSource;
  name: string;
  mimeType: string;
  sizeBytes: number;
  sha256?: string;
  kind?: AttachmentKind;
  workspacePath?: string;
}

export type MessageQueueKind = "steer" | "follow_up";

export interface MessageQueueItem {
  id: string;
  message: string;
  images?: ImageAttachment[];
  attachments?: ChatAttachmentRef[];
  createdAt: number;
}

export interface MessageQueueState {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

export interface MessageQueueDraftItem {
  id?: string;
  message: string;
  images?: ImageAttachment[];
  attachments?: ChatAttachmentRef[];
  createdAt?: number;
}

export interface ShareSessionRedactionPolicy {
  secrets?: boolean;
  emails?: boolean;
  phones?: boolean;
  userPaths?: boolean;
  ipAddresses?: boolean;
  jwtAndBearer?: boolean;
  namesHeuristic?: boolean;
  skills?: boolean;
}

export type TurnCommand = "prompt" | "steer" | "follow_up";
export type TurnAckStage = "accepted" | "dispatched" | "started";

/**
 * Client → Server messages.
 *
 * All messages may include an optional `requestId` for response correlation.
 * Commands return a `command_result` with the same requestId.
 */
export type ClientMessage = // ── Stream subscriptions (multiplexed user stream) ──
  (
    | {
        type: "subscribe";
        sessionId: string;
        level?: "full" | "notifications";
        /** Optional per-session durable sequence cursor for catch-up replay. */
        sinceSeq?: number;
        /** Monotonic client subscription generation used to ignore stale lifecycle messages. */
        subscriptionGeneration?: number;
        requestId?: string;
      }
    | {
        type: "unsubscribe";
        sessionId: string;
        /** Must match the active subscription generation when provided. */
        subscriptionGeneration?: number;
        requestId?: string;
      }
    // ── Prompting ──
    | {
        type: "prompt";
        message: string;
        images?: ImageAttachment[];
        attachments?: ChatAttachmentRef[];
        streamingBehavior?: "steer" | "followUp";
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "steer";
        message: string;
        images?: ImageAttachment[];
        attachments?: ChatAttachmentRef[];
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "follow_up";
        message: string;
        images?: ImageAttachment[];
        attachments?: ChatAttachmentRef[];
        requestId?: string;
        clientTurnId?: string;
      }
    | { type: "abort"; requestId?: string }
    | { type: "stop"; requestId?: string } // Abort current turn (alias for mobile UX)
    | { type: "stop_session"; requestId?: string } // Kill session process entirely
    // ── State ──
    | { type: "get_state"; requestId?: string }
    | { type: "get_messages"; requestId?: string }
    | { type: "get_session_stats"; requestId?: string }
    // ── Message queue ──
    | { type: "get_queue"; requestId?: string }
    | {
        type: "set_queue";
        baseVersion: number;
        steering: MessageQueueDraftItem[];
        followUp: MessageQueueDraftItem[];
        requestId?: string;
      }
    // ── Model ──
    | { type: "set_model"; provider: string; modelId: string; requestId?: string }
    | { type: "cycle_model"; requestId?: string }
    | { type: "get_available_models"; requestId?: string }
    // ── Thinking ──
    | {
        type: "set_thinking_level";
        level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
        requestId?: string;
      }
    | { type: "cycle_thinking_level"; requestId?: string }
    // ── Session ──
    | { type: "reload"; requestId?: string }
    | { type: "new_session"; requestId?: string }
    | { type: "set_session_name"; name: string; requestId?: string }
    | { type: "compact"; customInstructions?: string; requestId?: string }
    | { type: "set_auto_compaction"; enabled: boolean; requestId?: string }
    | { type: "fork"; entryId: string; requestId?: string }
    | { type: "get_fork_messages"; requestId?: string }
    | {
        type: "get_session_tree";
        filterMode?: "default" | "no-tools" | "user-only" | "labeled-only" | "all";
        requestId?: string;
      }
    | {
        type: "navigate_tree";
        targetId: string;
        summarize?: boolean;
        customInstructions?: string;
        replaceInstructions?: boolean;
        label?: string;
        requestId?: string;
      }
    | { type: "switch_session"; sessionPath: string; requestId?: string }
    // ── Queue modes ──
    | { type: "set_steering_mode"; mode: "all" | "one-at-a-time"; requestId?: string }
    | { type: "set_follow_up_mode"; mode: "all" | "one-at-a-time"; requestId?: string }
    // ── Retry ──
    | { type: "set_auto_retry"; enabled: boolean; requestId?: string }
    | { type: "abort_retry"; requestId?: string }
    // ── Bash ──
    | { type: "abort_bash"; requestId?: string }
    // ── Commands ──
    | { type: "get_commands"; requestId?: string }
    | {
        type: "share_session";
        action?: "prepare" | "publish";
        redactionPolicy?: ShareSessionRedactionPolicy;
        requestId?: string;
      }
    // ── File suggestions ──
    | { type: "get_file_suggestions"; query: string; requestId?: string }
    // ── Permission gate ──
    | {
        type: "permission_response";
        id: string;
        action: "allow" | "deny";
        scope?: "once" | "session" | "global";
        /** Optional TTL for learned rule persistence (milliseconds). Ignored for scope="once". */
        expiresInMs?: number;
        requestId?: string;
      }
    // ── Extension UI dialog responses ──
    | {
        type: "extension_ui_response";
        id: string;
        value?: string;
        confirmed?: boolean;
        cancelled?: boolean;
        requestId?: string;
      }
    // ── Dictation (multiplexed over /stream) ──
    | { type: "dictation_start" }
    | { type: "dictation_stop" }
    | { type: "dictation_cancel" }
  ) & {
    /**
     * Optional target session for multiplexed user streams.
     */
    sessionId?: string;
  };

/** Structured option for the ask extension UI. */
export interface AskOption {
  value: string;
  label: string;
  description?: string;
}

/** A single question in an ask request, with its own options and selection mode. */
export interface AskQuestion {
  id: string;
  question: string;
  options: AskOption[];
  multiSelect?: boolean;
}

// Server → Client
export type ServerMessage = // ── Connection ──
  (
    | { type: "connected"; session: Session; currentSeq?: number }
    | { type: "stream_connected"; userName: string; asrAvailable?: boolean }
    | { type: "state"; session: Session }
    | { type: "session_ended"; reason: string }
    | { type: "session_deleted"; sessionId: string }
    | { type: "stop_requested"; source: "user" | "timeout" | "server"; reason?: string }
    | { type: "stop_confirmed"; source: "user" | "timeout" | "server"; reason?: string }
    | { type: "stop_failed"; source: "user" | "timeout" | "server"; reason: string }
    | { type: "error"; error: string; code?: string; fatal?: boolean }
    // ── Agent lifecycle ──
    | { type: "agent_start" }
    | { type: "agent_end" }
    | { type: "message_end"; role: "user" | "assistant"; content: string }
    // ── Streaming ──
    | { type: "text_delta"; delta: string }
    | { type: "thinking_delta"; delta: string }
    | {
        type: "audio_stream";
        kind: "audio-stream";
        id: string;
        event: "metadata" | "chunk" | "done" | "error";
        mimeType: "audio/wav" | "audio/pcm; codecs=s16le";
        sampleRate?: number;
        channels?: number;
        chunkIndex?: number;
        audioBase64?: string;
        text?: string;
        durationSeconds?: number;
        metrics?: Record<string, unknown>;
        delivery?: "voiceMessage" | "directSpeak";
      }
    // ── Tool execution ──
    | {
        type: "tool_start";
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | {
        type: "tool_update";
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | {
        type: "tool_output";
        output: string;
        isError?: boolean;
        toolCallId?: string;
        /** "append" (default) or "replace" — replace means output is a bounded tail preview. */
        mode?: "append" | "replace";
        /** True when the server truncated output to a tail preview. */
        truncated?: boolean;
        /** Total bytes of full output on the server (hint for UI). */
        totalBytes?: number;
        /** Optional structured details for in-flight tool presentation updates. */
        details?: unknown;
      }
    | {
        type: "tool_end";
        tool: string;
        toolCallId?: string;
        details?: unknown;
        isError?: boolean;
        resultSegments?: StyledSegment[];
      }
    // ── Message queue ──
    | { type: "queue_state"; queue: MessageQueueState }
    | {
        type: "queue_item_started";
        kind: MessageQueueKind;
        item: MessageQueueItem;
        queueVersion: number;
      }
    // ── Turn delivery acknowledgements (idempotent send contract) ──
    | {
        type: "turn_ack";
        command: TurnCommand;
        clientTurnId: string;
        stage: TurnAckStage;
        requestId?: string;
        duplicate?: boolean;
      }
    // ── Command responses (keyed by requestId for correlation) ──
    | {
        type: "command_result";
        command: string;
        requestId?: string;
        success: boolean;
        data?: unknown;
        error?: string;
      }
    // ── Compaction ──
    | { type: "compaction_start"; reason: string }
    | {
        type: "compaction_end";
        aborted: boolean;
        willRetry: boolean;
        summary?: string;
        tokensBefore?: number;
      }
    // ── Retry ──
    | {
        type: "retry_start";
        attempt: number;
        maxAttempts: number;
        delayMs: number;
        errorMessage: string;
      }
    | { type: "retry_end"; success: boolean; attempt: number; finalError?: string }
    // ── Permission gate ──
    | {
        type: "permission_request";
        id: string;
        sessionId: string;
        tool: string;
        input: Record<string, unknown>;
        displaySummary: string;
        reason: string;
        timeoutAt: number;
        expires?: boolean;
      }
    | { type: "permission_expired"; id: string; reason: string }
    | { type: "permission_cancelled"; id: string }
    // ── Extension UI forwarding ──
    | {
        type: "extension_ui_request";
        id: string;
        sessionId: string;
        method: string;
        title?: string;
        options?: string[];
        message?: string;
        placeholder?: string;
        prefill?: string;
        timeout?: number;
        timeoutAt?: number;
        // ── Ask extension fields (method: "ask") ──
        questions?: AskQuestion[];
        allowCustom?: boolean;
      }
    | {
        type: "extension_ui_notification";
        method: string;
        message?: string;
        notifyType?: string;
        statusKey?: string;
        statusText?: string;
        title?: string;
        text?: string;
        widgetKey?: string;
        widgetLines?: string[];
        widgetPlacement?: string;
      }
    // ── Git status (workspace-level, pushed after file-mutating tool calls) ──
    | {
        type: "git_status";
        workspaceId: string;
        status: GitStatus;
      }
    // ── Dictation ──
    | {
        type: "dictation_ready";
        sttProvider?: string;
        sttModel?: string;
      }
    | {
        type: "dictation_result";
        text: string;
        committedText?: string;
        activeText?: string;
        snap?: boolean;
      }
    | {
        type: "dictation_final";
        text: string;
        committedText?: string;
        activeText?: string;
      }
    | { type: "dictation_error"; error: string; fatal: boolean }
  ) & {
    seq?: number;
    /**
     * Session scope for multiplexed user streams.
     * Per-session streams may omit this field.
     */
    sessionId?: string;
    /**
     * User-wide multiplexed stream sequence cursor.
     */
    streamSeq?: number;
  };

// ─── Push ───

export interface RegisterDeviceTokenRequest {
  /** APNs device token (hex string from iOS) */
  deviceToken: string;
  /** "apns" for regular push, "liveactivity" for Live Activity push token */
  tokenType?: "apns" | "liveactivity";
}

// ─── Pairing / Invite ───

export type InviteScheme = "http" | "https";

export interface InviteData {
  host: string;
  port: number;
  scheme?: InviteScheme;
  token: string;
  pairingToken?: string;
  name: string;
  tlsCertFingerprint?: string;
}

export interface InvitePayloadV3 extends InviteData {
  v: 3;
  fingerprint?: string;
}

export interface SignedInviteEnvelopeV3 {
  v: 3;
  signedPayload: string;
  publicKey: string;
  signature: string;
}

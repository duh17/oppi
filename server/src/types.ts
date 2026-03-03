/**
 * Core types for oppi-server.
 */

// ─── Workspaces ───

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
  systemPrompt?: string; // Additional instructions appended to base prompt
  hostMount?: string; // Host directory to mount as /work (e.g. "~/workspace/oppi")

  // Memory
  memoryEnabled?: boolean; // Enable remember/recall memory extension
  memoryNamespace?: string; // Same namespace => shared memory across workspaces

  // Extensions
  extensions?: string[]; // Extension names from ~/.pi/agent/extensions

  // Git status
  gitStatusEnabled?: boolean; // Show git status context bar (default: true)

  // Defaults
  defaultModel?: string; // Override server default for this workspace
  lastUsedModel?: string; // Sticky: last model used in any session (auto-updated)

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
  /** Best-effort aggregate line removals (from edit args). */
  removedLines: number;
}

export interface Session {
  id: string;
  workspaceId?: string; // which workspace spawned this session
  workspaceName?: string; // denormalized for display
  name?: string;
  status: "starting" | "ready" | "busy" | "stopping" | "stopped" | "error";
  createdAt: number;
  lastActivity: number;
  model?: string;

  // Stats
  messageCount: number;
  tokens: { input: number; output: number };
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
  piSessionFile?: string; // latest absolute JSONL path reported by pi get_state
  piSessionFiles?: string[]; // all observed session JSONL paths for this session
  piSessionId?: string; // pi internal session UUID reported by get_state
}

export interface SessionMessage {
  id: string;
  sessionId: string;
  role: "user" | "assistant" | "system";
  content: string;
  timestamp: number;

  // For assistant messages
  model?: string;
  tokens?: { input: number; output: number };
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

export interface ServerConfig {
  configVersion?: number;
  port: number;
  host: string;
  dataDir: string;
  defaultModel: string;
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

  // Per-model thinking preferences (synced from iOS)
  thinkingLevelByModel?: Record<string, string>;
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
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
  extensions?: string[];
  defaultModel?: string;
  gitStatusEnabled?: boolean;
}

export interface UpdateWorkspaceRequest {
  name?: string;
  description?: string;
  icon?: string;
  skills?: string[];
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
  extensions?: string[];
  defaultModel?: string;
  gitStatusEnabled?: boolean;
}

export interface ClientLogUploadEntry {
  timestamp: number;
  level: "debug" | "info" | "warning" | "error";
  category: string;
  message: string;
  metadata?: Record<string, string>;
}

export interface ClientLogUploadRequest {
  generatedAt: number;
  trigger?: string;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  entries: ClientLogUploadEntry[];
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
    description: "Reducer apply latency for timeline state updates.",
  },
  "chat.timeline_layout_ms": {
    unit: "ms",
    description: "Timeline layout/render latency after state application.",
  },
  "chat.ws_decode_ms": {
    unit: "ms",
    description: "WebSocket message decode latency.",
  },
  "chat.coalescer_flush_events": {
    unit: "count",
    description: "Event count flushed per coalescer batch.",
  },
  "chat.coalescer_flush_bytes": {
    unit: "count",
    description: "Payload byte count flushed per coalescer batch.",
  },
  "chat.inbound_queue_depth": {
    unit: "count",
    description: "Inbound queue depth observed while processing stream events.",
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
  "chat.ws_connect_ms": {
    unit: "ms",
    description: "WebSocket connection establishment latency.",
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
  "plot.axis_visible_tick_count": {
    unit: "count",
    description: "Visible axis tick count after plot normalization.",
  },
  "plot.legend_item_count": {
    unit: "count",
    description: "Legend item count after plot normalization.",
  },
  "plot.scroll_enabled": {
    unit: "ratio",
    description: "Whether horizontal plot scrolling was enabled (0 or 1).",
  },
  "plot.auto_adjustments": {
    unit: "count",
    description: "Count of automatic plot adjustments applied by renderer.",
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

export type MessageQueueKind = "steer" | "follow_up";

export interface MessageQueueItem {
  id: string;
  message: string;
  images?: ImageAttachment[];
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
  createdAt?: number;
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
        requestId?: string;
      }
    | {
        type: "unsubscribe";
        sessionId: string;
        requestId?: string;
      }
    // ── Prompting ──
    | {
        type: "prompt";
        message: string;
        images?: ImageAttachment[];
        streamingBehavior?: "steer" | "followUp";
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "steer";
        message: string;
        images?: ImageAttachment[];
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "follow_up";
        message: string;
        images?: ImageAttachment[];
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
    | { type: "new_session"; requestId?: string }
    | { type: "set_session_name"; name: string; requestId?: string }
    | { type: "compact"; customInstructions?: string; requestId?: string }
    | { type: "set_auto_compaction"; enabled: boolean; requestId?: string }
    | { type: "fork"; entryId: string; requestId?: string }
    | { type: "get_fork_messages"; requestId?: string }
    | { type: "switch_session"; sessionPath: string; requestId?: string }
    // ── Queue modes ──
    | { type: "set_steering_mode"; mode: "all" | "one-at-a-time"; requestId?: string }
    | { type: "set_follow_up_mode"; mode: "all" | "one-at-a-time"; requestId?: string }
    // ── Retry ──
    | { type: "set_auto_retry"; enabled: boolean; requestId?: string }
    | { type: "abort_retry"; requestId?: string }
    // ── Bash ──
    | { type: "bash"; command: string; requestId?: string }
    | { type: "abort_bash"; requestId?: string }
    // ── Commands ──
    | { type: "get_commands"; requestId?: string }
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
  ) & {
    /**
     * Optional target session for multiplexed user streams.
     */
    sessionId?: string;
  };

// Server → Client
export type ServerMessage = // ── Connection ──
  (
    | { type: "connected"; session: Session; currentSeq?: number }
    | { type: "stream_connected"; userName: string }
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
    // ── Tool execution ──
    | {
        type: "tool_start";
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | { type: "tool_output"; output: string; isError?: boolean; toolCallId?: string }
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
      }
    | {
        type: "extension_ui_notification";
        method: string;
        message?: string;
        notifyType?: string;
        statusKey?: string;
        statusText?: string;
      }
    // ── Git status (workspace-level, pushed after file-mutating tool calls) ──
    | {
        type: "git_status";
        workspaceId: string;
        status: GitStatus;
      }
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

export interface PairDeviceRequest {
  pairingToken: string;
  deviceName?: string;
}

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

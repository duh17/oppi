import type { IconChoice } from "./icon.js";

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

/**
 * OSC 7501 program status vocabulary. One server-derived value per session; lifecycle
 * `Session.status` keeps driving controls (stop, resume, open) while status surfaces
 * read this.
 */
export type ProgramStatusState = "idle" | "working" | "done" | "blocked" | "error";
export type ProgramStatusKind = "permission" | "question" | "auth";

export interface ProgramStatus {
  state: ProgramStatusState;
  /** Blocked only. */
  kind?: ProgramStatusKind;
  /** One line; never prompts or model output. */
  message?: string;
  /** Epoch ms when this state began. */
  since: number;
}

export type SessionRuntimeKind = "oppi" | "pi-tui";

/** Agent engine a create request selects. Omitted means classic. */
export type SessionEngine = "classic" | "durable";

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

export type ControlSessionDomain = "agents" | "schedules" | "skills" | "workspaces";
export type ControlSessionIntent = "create" | "revise";

export interface ControlSessionMetadata {
  domain: ControlSessionDomain;
  intent: ControlSessionIntent;
  targetId?: string;
  targetName?: string;
}

export type AgentConfigurationFailureCode =
  | "agent_workspace_incompatible"
  | "agent_workspace_unavailable"
  | "agent_tools_unavailable"
  | "agent_extensions_unavailable"
  | "agent_skills_unavailable";

export interface AgentConfigurationFailureDetails {
  targetWorkspaceId?: string;
  targetWorkspaceName?: string;
  allowedWorkspaceIds?: string[];
  requiredRuntime?: "host" | "sandbox";
  actualRuntime?: "host" | "sandbox";
  workspaceError?: string;
  missingTools?: string[];
  unavailableExtensions?: string[];
  unavailableSkills?: string[];
}

export interface AgentConfigurationFailure {
  code: AgentConfigurationFailureCode;
  retryable: false;
  details: AgentConfigurationFailureDetails;
}

export interface SessionLaunchMetadata {
  source?: "human" | "agent" | "schedule" | "workspace-wrapper" | "api" | "cli";
  agentId?: string;
  agentVersion?: number;
  /** Immutable launch-time presentation snapshot; never used for execution identity. */
  agentIcon?: IconChoice;
  parentSessionId?: string;
  /**
   * This session may create children, and the authorization propagates down
   * the delegation subtree: children inherit the grant, so explicitly
   * requested grandchild (or deeper) sessions can be created without
   * re-authorizing at each level.
   */
  allowsNestedDelegation?: boolean;
  /** Client-supplied key used to make agent launch retries create at most one session. */
  idempotencyKey?: string;
  /** Stop this session as soon as a turn settles with no pending user-reply dialog. */
  autoStop?: boolean;
  schedule?: {
    scheduleId: string;
    runId: string;
    scheduledForMs?: number;
    slotKey: string;
    scheduleVersion?: number;
  };
  target?: {
    workspaceId?: string;
    worktreeId?: string;
    runtime?: "sandbox" | "host";
    server?: true;
    displayCwd?: string;
  };
  model?: string;
  /** Required launch models must resolve exactly enough to start; Pi fallback is forbidden. */
  modelPolicy?: "required";
  thinkingLevel?: string;
  tools?: {
    allowed?: string[];
    excluded?: string[];
    noTools?: "all" | "builtin";
  };
  status: "launching" | "accepted" | "failed" | "created";
  promptDispatch?: "delivered" | "not_sent";
  promptError?: string;
  /** Typed terminal launch failure retained for audit and idempotent retry policy. */
  failure?: AgentConfigurationFailure;
  requestedAt: number;
  completedAt?: number;
  lease?: {
    owner: string;
    acquiredAt: number;
    expiresAt: number;
  };
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
  /**
   * Server-derived OSC 7501 program status. Persisted so a stopped session keeps its
   * last run outcome (done/error/idle) across a server restart.
   */
  programStatus?: ProgramStatus;
  model?: string;

  // Stats
  messageCount: number;
  tokens: TokenUsage;
  cost: number;
  changeStats?: SessionChangeStats;

  // Context usage (pi TUI-style)
  contextTokens?: number; // context size from last message usage (see NormalizedUsage.contextTokens)
  contextWindow?: number; // model's total context window

  // Preview
  firstMessage?: string; // first user message (immutable once set)
  lastMessage?: string;

  // Health
  warnings?: string[]; // bootstrap/session warnings surfaced to iOS

  // Agent config state (synced from pi get_state)
  thinkingLevel?: string;

  // Runtime ownership. New sessions persist this explicitly as "oppi" or "pi-tui".
  runtime?: SessionRuntimeKind;
  mirror?: PiTuiMirrorSessionMetadata;

  /**
   * Durable-engine enrollment, set only when the create request asked for
   * `engine: "durable"`; the binding is saved before first submission. Full
   * `Session` payloads carry it as is. `SessionSummary` projects enrollment as
   * `engine` and, for the control conversation only, `serverDurable.role`.
   * `role: "control"` marks the one workspace-less control conversation per data directory.
   */
  serverDurable?: { conversationId?: number; role?: "control" };

  // Trace metadata (used for trace recovery/replay)
  // Local pi JSONL paths under ~/.pi/agent/sessions are deleted with the Oppi
  // session so deleted sessions are not rediscovered as importable local sessions.
  piSessionFile?: string; // latest absolute JSONL path reported by pi get_state
  piSessionFiles?: string[]; // all observed session JSONL paths for this session

  // Agent launch metadata. Session rows own launch idempotency; there is no
  // separate launch record table.
  launch?: SessionLaunchMetadata;

  // Server-scoped Oppi configuration session. Never infer this from a missing workspace.
  control?: ControlSessionMetadata;

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
  programStatus?: ProgramStatus;
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
  /** Saved-Agent identity projected for presentation and generic fallback semantics. */
  agentId?: string;
  /** Immutable launch-time icon snapshot; malformed values remain decode-safe. */
  agentIcon?: IconChoice;
  control?: ControlSessionMetadata;
  ephemeral?: boolean;
  /** Launching session; clients build session threads from this edge. */
  parentSessionId?: string;
  /** Present only for durable-engine sessions; omitted means classic. */
  engine?: "durable";
  /**
   * Control-conversation marker on list rows. Omitted for every other session;
   * the conversation id is not projected.
   */
  serverDurable?: { role: "control" };
  /** Cold-list ask badge count; omitted outside list endpoints. */
  pendingAskCount?: number;
}

/**
 * Cross-session primitive recorded when one session drives another through the
 * Oppi CLI. Launch edges are not recorded here: they stay derived from
 * `parentSessionId` + `createdAt` so each fact has one owner.
 */
export type SessionInteractionKind = "prompt" | "steer" | "follow_up" | "abort" | "stop" | "resume";

export interface SessionInteraction {
  id: number;
  at: number;
  fromSessionId: string;
  toSessionId: string;
  kind: SessionInteractionKind;
}

/** Session outside a thread that exchanged interactions with it. */
export interface SessionThreadCounterpart {
  id: string;
  name?: string;
  status?: Session["status"];
  /** Workspace route for opening the counterpart; absent for control sessions. */
  workspaceId?: string;
  model?: string;
  rootSessionId: string;
  rootName?: string;
}

/** Pi's prompt-cache warmer for a live session. */
export interface SessionPromptCacheWarmer {
  state: "inactive" | "scheduled" | "refreshing";
  /**
   * Pi's pending decision for the scheduled refresh. Pi arms a timer after
   * every request and decides then; "stop" means the cache will expire.
   */
  action?: "warm" | "stop";
  nextWarmAt?: number;
  /** Why nothing is scheduled. */
  reason?: string;
}

/**
 * Best-effort prompt-cache freshness. `ttlMs` is the model's lifetime for the
 * retention tier requests use; `lastRequestAt` is the latest reply. Providers
 * can evict earlier, so clients present this as an estimate.
 */
export interface SessionPromptCacheStatus {
  retention: "short" | "long";
  ttlMs?: number;
  lastRequestAt?: number;
  warmer?: SessionPromptCacheWarmer;
}

/** `GET /sessions/:id/thread` response. */
export interface SessionThreadResponse {
  rootSessionId: string;
  sessions: SessionSummary[];
  interactions: SessionInteraction[];
  counterparts: SessionThreadCounterpart[];
  /** Keyed by session id; omitted for sessions without a known cache lifetime. */
  promptCache?: Record<string, SessionPromptCacheStatus>;
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

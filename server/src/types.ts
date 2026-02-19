/**
 * Core types for oppi-server.
 */

import type { StyledSegment } from "./mobile-renderer.js";

// ─── Workspaces ───

export interface WorkspacePolicyConfig {
  permissions: PolicyPermission[];
}

export interface Workspace {
  id: string;
  name: string; // "coding", "research"
  description?: string; // shown in workspace picker
  icon?: string; // SF Symbol name or emoji

  // Runtime — where pi runs
  runtime: "host" | "container"; // "host" = directly on Mac, "container" = Apple container

  // Skills — which skills to sync into the session
  skills: string[]; // ["searxng", "fetch", "ast-grep"]

  // Permissions
  policy?: WorkspacePolicyConfig; // workspace additive permissions (merged onto global policy)
  allowedPaths?: { path: string; access: "read" | "readwrite" }[]; // Extra dirs beyond workspace
  allowedExecutables?: string[]; // Dev runtimes auto-allowed in host mode (e.g. ["node", "python3"])

  // Context
  systemPrompt?: string; // Additional instructions appended to base prompt
  hostMount?: string; // Host directory to mount as /work (e.g. "~/workspace/oppi")

  // Memory
  memoryEnabled?: boolean; // Enable remember/recall memory extension
  memoryNamespace?: string; // Same namespace => shared memory across workspaces

  // Extensions
  extensions?: string[]; // Extension names from ~/.pi/agent/extensions

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
  /** Deduplicated file paths changed in this session. */
  changedFiles: string[];
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
  lastMessage?: string;

  // Health
  warnings?: string[]; // bootstrap/runtime warnings surfaced to iOS

  // Agent config state (synced from pi get_state)
  thinkingLevel?: string; // "off" | "minimal" | "low" | "medium" | "high" | "xhigh"

  // Runtime metadata (used for trace recovery/replay)
  runtime?: "host" | "container";
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
export type PolicyRisk = "low" | "medium" | "high" | "critical";

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
  risk?: PolicyRisk;
  label?: string;
  reason?: string;
  immutable?: boolean;
  match: PolicyMatch;
}

export interface PolicyConfig {
  schemaVersion: 1;
  mode?: string;
  description?: string;
  fallback: PolicyDecision;
  guardrails: PolicyPermission[];
  permissions: PolicyPermission[];
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
  /** Source CIDRs allowed to connect to HTTP/WS endpoints. */
  allowedCidrs: string[];

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

export interface CreateSessionRequest {
  name?: string;
  model?: string;
  workspaceId?: string;
}

export interface AllowedPathEntry {
  path: string;
  access: "read" | "readwrite";
}

export interface CreateWorkspaceRequest {
  name: string;
  description?: string;
  icon?: string;
  runtime?: "host" | "container";
  skills: string[];
  policy?: WorkspacePolicyConfig;
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
  extensions?: string[];
  defaultModel?: string;
}

export interface UpdateWorkspaceRequest {
  name?: string;
  description?: string;
  icon?: string;
  runtime?: "host" | "container";
  skills?: string[];
  policy?: WorkspacePolicyConfig;
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
  extensions?: string[];
  defaultModel?: string;
}

export interface CreateSessionResponse {
  session: Session;
}

export interface ListSessionsResponse {
  sessions: Session[];
}

export interface SessionDetailResponse {
  session: Session;
  messages: SessionMessage[];
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

// ─── WebSocket Messages ───

export interface ImageAttachment {
  data: string; // base64
  mimeType: string; // image/jpeg, image/png, etc.
}

export type TurnCommand = "prompt" | "steer" | "follow_up";
export type TurnAckStage = "accepted" | "dispatched" | "started";

/**
 * Client → Server messages.
 *
 * All messages may include an optional `requestId` for response correlation.
 * Commands forwarded to pi RPC return an `rpc_result` with the same requestId.
 */
export type ClientMessage = // ── Stream subscriptions (multiplexed user stream) ──
(| {
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
      scope?: "once" | "session" | "workspace" | "global";
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

// ─── RPC Response Payloads ───

/** Full model info from pi RPC. */
export interface PiModel {
  id: string;
  name: string;
  api: string;
  provider: string;
  baseUrl?: string;
  reasoning?: boolean;
  input?: string[];
  contextWindow?: number;
  maxTokens?: number;
  cost?: { input: number; output: number; cacheRead: number; cacheWrite: number };
}

/** Full session state from pi RPC get_state. */
export interface PiState {
  model: PiModel | null;
  thinkingLevel: string;
  isStreaming: boolean;
  isCompacting: boolean;
  steeringMode: string;
  followUpMode: string;
  sessionFile?: string;
  sessionId?: string;
  sessionName?: string;
  autoCompactionEnabled: boolean;
  messageCount: number;
  pendingMessageCount: number;
}

/** Session token/cost stats from pi RPC. */
export interface PiSessionStats {
  sessionFile: string;
  sessionId: string;
  userMessages: number;
  assistantMessages: number;
  toolCalls: number;
  toolResults: number;
  totalMessages: number;
  tokens: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    total: number;
  };
  cost: number;
}

/** Command entry from pi RPC get_commands. */
export interface PiCommand {
  name: string;
  description?: string;
  source: "extension" | "prompt" | "skill";
  location?: "user" | "project" | "path";
  path?: string;
}

// Server → Client
export type ServerMessage = // ── Connection ──
(| { type: "connected"; session: Session; currentSeq?: number }
  | { type: "stream_connected"; userName: string }
  | { type: "state"; session: Session }
  | { type: "session_ended"; reason: string }
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
  | { type: "tool_start"; tool: string; args: Record<string, unknown>; toolCallId?: string; callSegments?: StyledSegment[] }
  | { type: "tool_output"; output: string; isError?: boolean; toolCallId?: string }
  | { type: "tool_end"; tool: string; toolCallId?: string; details?: unknown; isError?: boolean; resultSegments?: StyledSegment[] }
  // ── Turn delivery acknowledgements (idempotent send contract) ──
  | {
      type: "turn_ack";
      command: TurnCommand;
      clientTurnId: string;
      stage: TurnAckStage;
      requestId?: string;
      duplicate?: boolean;
    }
  // ── RPC responses (keyed by requestId for correlation) ──
  | {
      type: "rpc_result";
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
      risk: "low" | "medium" | "high" | "critical";
      reason: string;
      timeoutAt: number;
      expires?: boolean;
      resolutionOptions?: {
        allowSession: boolean;
        allowAlways: boolean;
        alwaysDescription?: string;
        denyAlways: boolean;
      };
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

export interface PairDeviceResponse {
  deviceToken: string;
}

export interface InviteData {
  host: string;
  port: number;
  token: string;
  pairingToken?: string;
  name: string;
}

export interface InvitePayloadV3 extends InviteData {
  v: 3;
  fingerprint?: string;
}

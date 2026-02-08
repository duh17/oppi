/**
 * Core types for pi-remote.
 */

// ─── User & Auth ───

export interface User {
  id: string;
  name: string;
  token: string;
  createdAt: number;
  lastSeen?: number;
  /** APNs device tokens (hex string). Multiple devices in future. */
  deviceTokens?: string[];
  /** ActivityKit push token for Live Activity updates (hex string). */
  liveActivityToken?: string;
}

// ─── Workspaces ───

export interface Workspace {
  id: string;
  userId: string;
  name: string;              // "coding", "research"
  description?: string;      // shown in workspace picker
  icon?: string;             // SF Symbol name or emoji

  // Runtime — where pi runs
  runtime: "host" | "container";  // "host" = directly on Mac, "container" = Apple container

  // Skills — which skills to sync into the session
  skills: string[];          // ["searxng", "fetch", "ast-grep"]

  // Permissions
  policyPreset: string;      // "container" | "restricted"

  // Context
  systemPrompt?: string;     // Additional instructions appended to base prompt
  hostMount?: string;        // Host directory to mount as /work (e.g. "~/workspace/pios")

  // Memory
  memoryEnabled?: boolean;   // Enable remember/recall memory extension
  memoryNamespace?: string;  // Same namespace => shared memory across workspaces

  // Defaults
  defaultModel?: string;     // Override server default for this workspace

  // Metadata
  createdAt: number;
  updatedAt: number;
}

// ─── Sessions ───

export interface Session {
  id: string;
  userId: string;
  workspaceId?: string;      // which workspace spawned this session
  workspaceName?: string;    // denormalized for display
  name?: string;
  status: "starting" | "ready" | "busy" | "stopped" | "error";
  createdAt: number;
  lastActivity: number;
  model?: string;

  // Stats
  messageCount: number;
  tokens: { input: number; output: number };
  cost: number;

  // Context usage (pi TUI-style)
  contextTokens?: number;   // input+output+cacheRead+cacheWrite from last message
  contextWindow?: number;   // model's total context window

  // Preview
  lastMessage?: string;

  // Health
  warnings?: string[];       // bootstrap/runtime warnings surfaced to iOS

  // Runtime metadata (used for trace recovery/replay)
  runtime?: "host" | "container";
  piSessionFile?: string;    // latest absolute JSONL path reported by pi get_state
  piSessionFiles?: string[]; // all observed session JSONL paths for this session
  piSessionId?: string;      // pi internal session UUID reported by get_state
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

export interface ServerConfig {
  port: number;
  host: string;
  dataDir: string;
  defaultModel: string;
  sessionTimeout: number; // Auto-stop after idle (ms)
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

export interface CreateWorkspaceRequest {
  name: string;
  description?: string;
  icon?: string;
  runtime?: "host" | "container";
  skills: string[];
  policyPreset?: string;
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
  defaultModel?: string;
}

export interface UpdateWorkspaceRequest {
  name?: string;
  description?: string;
  icon?: string;
  runtime?: "host" | "container";
  skills?: string[];
  policyPreset?: string;
  systemPrompt?: string;
  hostMount?: string;
  memoryEnabled?: boolean;
  memoryNamespace?: string;
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

// ─── WebSocket Messages ───

export interface ImageAttachment {
  data: string;      // base64
  mimeType: string;  // image/jpeg, image/png, etc.
}

/**
 * Client → Server messages.
 *
 * All messages may include an optional `requestId` for response correlation.
 * Commands forwarded to pi RPC return an `rpc_result` with the same requestId.
 */
export type ClientMessage =
  // ── Prompting ──
  | { type: "prompt"; message: string; images?: ImageAttachment[]; streamingBehavior?: "steer" | "followUp"; requestId?: string }
  | { type: "steer"; message: string; images?: ImageAttachment[]; requestId?: string }
  | { type: "follow_up"; message: string; images?: ImageAttachment[]; requestId?: string }
  | { type: "abort"; requestId?: string }
  | { type: "stop"; requestId?: string }  // Alias for mobile UX
  // ── State ──
  | { type: "get_state"; requestId?: string }
  | { type: "get_messages"; requestId?: string }
  | { type: "get_session_stats"; requestId?: string }
  // ── Model ──
  | { type: "set_model"; provider: string; modelId: string; requestId?: string }
  | { type: "cycle_model"; requestId?: string }
  | { type: "get_available_models"; requestId?: string }
  // ── Thinking ──
  | { type: "set_thinking_level"; level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh"; requestId?: string }
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
  | { type: "permission_response"; id: string; action: "allow" | "deny"; requestId?: string }
  // ── Extension UI dialog responses ──
  | { type: "extension_ui_response"; id: string; value?: string; confirmed?: boolean; cancelled?: boolean; requestId?: string };

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
export type ServerMessage =
  // ── Connection ──
  | { type: "connected"; session: Session }
  | { type: "state"; session: Session }
  | { type: "session_ended"; reason: string }
  | { type: "error"; error: string }
  // ── Agent lifecycle ──
  | { type: "agent_start" }
  | { type: "agent_end" }
  // ── Streaming ──
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  // ── Tool execution ──
  | { type: "tool_start"; tool: string; args: Record<string, unknown>; toolCallId?: string }
  | { type: "tool_output"; output: string; isError?: boolean; toolCallId?: string }
  | { type: "tool_end"; tool: string; toolCallId?: string }
  // ── RPC responses (keyed by requestId for correlation) ──
  | { type: "rpc_result"; command: string; requestId?: string; success: boolean; data?: unknown; error?: string }
  // ── Compaction ──
  | { type: "compaction_start"; reason: string }
  | { type: "compaction_end"; aborted: boolean; willRetry: boolean; summary?: string; tokensBefore?: number }
  // ── Retry ──
  | { type: "retry_start"; attempt: number; maxAttempts: number; delayMs: number; errorMessage: string }
  | { type: "retry_end"; success: boolean; attempt: number; finalError?: string }
  // ── Permission gate ──
  | {
      type: "permission_request";
      id: string;
      sessionId: string;
      tool: string;
      input: Record<string, unknown>;
      displaySummary: string;
      risk: string;
      reason: string;
      timeoutAt: number;
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
    };

// ─── Push ───

export interface RegisterDeviceTokenRequest {
  /** APNs device token (hex string from iOS) */
  deviceToken: string;
  /** "apns" for regular push, "liveactivity" for Live Activity push token */
  tokenType?: "apns" | "liveactivity";
}

// ─── Invite ───

export interface InviteData {
  host: string;
  port: number;
  token: string;
  name: string;
}

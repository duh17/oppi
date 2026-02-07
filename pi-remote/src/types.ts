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

// Client → Server
export type ClientMessage =
  | { type: "prompt"; message: string; images?: ImageAttachment[]; streamingBehavior?: "steer" | "followUp" }
  | { type: "steer"; message: string }
  | { type: "follow_up"; message: string }
  | { type: "abort" }
  // Alias for mobile UX terminology.
  | { type: "stop" }
  | { type: "get_state" }
  // Permission gate
  | { type: "permission_response"; id: string; action: "allow" | "deny" }
  // Extension UI dialog responses
  | { type: "extension_ui_response"; id: string; value?: string; confirmed?: boolean; cancelled?: boolean };

// Server → Client
export type ServerMessage =
  | { type: "connected"; session: Session }
  | { type: "state"; session: Session }
  | { type: "agent_start" }
  | { type: "agent_end" }
  | { type: "text_delta"; delta: string }
  | { type: "thinking_delta"; delta: string }
  | { type: "tool_start"; tool: string; args: Record<string, unknown> }
  | { type: "tool_output"; output: string; isError?: boolean }
  | { type: "tool_end"; tool: string }
  | { type: "error"; error: string }
  | { type: "session_ended"; reason: string }
  // Permission gate
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
  // Extension UI forwarding
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

/**
 * Core types for pi-remote
 */

// ─── User & Auth ───

export interface User {
  id: string;
  name: string;
  token: string;
  createdAt: number;
  lastSeen?: number;
}

// ─── Sessions ───

export interface Session {
  id: string;
  userId: string;
  name?: string;
  status: "starting" | "ready" | "busy" | "stopped" | "error";
  createdAt: number;
  lastActivity: number;
  model?: string;
  
  // Stats
  messageCount: number;
  tokens: { input: number; output: number };
  cost: number;
  
  // Preview
  lastMessage?: string;
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
  sandboxScript: string;
  sandboxBaseDir: string;  // Base dir for user sandboxes
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

// Client → Server
export type ClientMessage =
  | { type: "prompt"; message: string; images?: ImageAttachment[] }
  | { type: "abort" }
  | { type: "get_state" }
  // Permission gate responses
  | { type: "permission_response"; id: string; action: "allow" | "deny" };

export interface ImageAttachment {
  data: string;      // base64
  mimeType: string;  // image/jpeg, image/png, etc.
}

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
  // Permission gate messages
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
  | { type: "permission_cancelled"; id: string };

// ─── Invite ───

export interface InviteData {
  host: string;
  port: number;
  token: string;
  name: string; // Server name for display
}

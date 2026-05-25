import type { ServerMessage, Session, SubagentConfig } from "./model-types.js";

export interface SubagentsContext {
  workspaceId: string;
  sessionId: string;
  spawnChild(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
    activeTools?: string[];
    profileName?: string;
  }): Promise<Session>;
  spawnDetached(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
    activeTools?: string[];
    profileName?: string;
  }): Promise<Session>;
  listChildren(): Session[];
  getSession(sessionId: string): Session | undefined;
  listWorkspaceSessions(): Session[];
  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void;
  getAvailableModelIds(): string[];
  stopSession(sessionId: string): Promise<void>;
  resumeSession(sessionId: string): Promise<Session>;
  sendMessage(sessionId: string, message: string, behavior?: "steer" | "followUp"): Promise<void>;
}

export interface SendMessageDetails {
  agentId: string;
  name?: string;
  status: string;
  deliveredAs: "prompt" | "steer" | "follow_up";
}

export interface SpawnAgentDetails {
  agentId: string;
  name: string;
  status: string;
  model?: string;
  detached?: boolean;
  waited?: boolean;
  cost?: number;
  durationMs?: number;
}

export interface InspectAgentDetails {
  sessionId: string;
  level: "overview" | "turn" | "tool";
  turnCount?: number;
  toolCount?: number;
  errorCount?: number;
}

export interface SubagentsFactoryOptions {
  childMode?: boolean;
  subagentConfig?: SubagentConfig;
}

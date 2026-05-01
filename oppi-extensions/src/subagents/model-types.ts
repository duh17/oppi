export interface SessionChangeStats {
  mutatingToolCalls: number;
  filesChanged: number;
  addedLines: number;
  removedLines: number;
  changedFiles: string[];
  changedFilesOverflow?: number;
}

export interface SessionTokens {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
}

export interface Session {
  id: string;
  status: string;
  createdAt: number;
  lastActivity: number;
  messageCount: number;
  tokens: SessionTokens;
  cost: number;
  workspaceId: string;
  workspaceName?: string;
  name?: string;
  model?: string;
  parentSessionId?: string;
  firstMessage?: string;
  lastMessage?: string;
  piSessionFile?: string;
  changeStats?: SessionChangeStats;
}

export type ServerMessage =
  | { type: "session_ended"; reason: string }
  | { type: "state"; session: Session };

export interface SubagentModelProfileConfig {
  description?: string;
  model?: string;
  thinking?: string;
  guidelines?: string[];
}

export interface SubagentModelPolicyConfig {
  approvedModels?: string[];
  defaultModel?: string;
  defaultThinking?: string;
  profiles?: Record<string, SubagentModelProfileConfig>;
}

export interface SubagentConfig {
  maxDepth: number;
  autoStopWhenDone: boolean;
  childIdleTimeoutMs: number;
  startupGraceMs: number;
  defaultWaitTimeoutMs: number;
  modelPolicy?: SubagentModelPolicyConfig;
}

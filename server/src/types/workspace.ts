import type { IconChoice } from "./icon.js";

// ─── Workspaces ───

export type WorkspaceSystemPromptMode = "append";
export type WorkspaceRuntimeMode = "host" | "sandbox";

export interface WorkspaceSandboxConfig {
  /** Allowed egress hosts for network access. Omitted = Gondolin default allow-all; [] = deny all. */
  allowedHosts?: string[];
  /** Extra environment variables injected into the sandbox VM. */
  env?: Record<string, string>;
}

export interface WorkspaceMutableConfig {
  name: string; // "coding", "research"
  description?: string; // shown in workspace picker
  icon: IconChoice;

  // Context
  systemPrompt?: string; // Workspace prompt text appended to the Pi prompt
  systemPromptMode: WorkspaceSystemPromptMode;
  hostMount?: string; // Host directory to mount as /work (e.g. "~/workspace/oppi")
  defaultModel?: string; // Optional default model for new sessions in this workspace

  // Tool allowlist is only a sandbox VM security policy. Host runtime uses Pi defaults.
  tools?: string[];

  // Git status
  gitStatusEnabled?: boolean; // Show git status context bar (default: true)

  // Runtime
  /** Workspace runtime mode. "host" = direct execution, "sandbox" = Gondolin micro-VM. */
  runtime?: WorkspaceRuntimeMode;
  /** Sandbox configuration (only used when runtime is "sandbox"). */
  sandboxConfig?: WorkspaceSandboxConfig;
}

export interface Workspace extends WorkspaceMutableConfig {
  id: string;
  createdAt: number;
  updatedAt: number;
}

export interface WorkspaceGitSummary {
  isGitRepo: boolean;
  changedCount: number;
  ahead: number | null;
  behind: number | null;
}

export interface WorkspaceListSummary {
  workspaceId: string;
  activeCount: number;
  stoppedCount: number;
  hasAttention: boolean;
  hasErrorRoot: boolean;
  latestActivity?: number;
  gitSummary?: WorkspaceGitSummary;
}

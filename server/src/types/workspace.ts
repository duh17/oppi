// ─── Workspaces ───

export type WorkspaceSystemPromptMode = "append" | "replace";
export type WorkspaceAllowedPathAccess = "read" | "readwrite";
export type WorkspaceRuntimeMode = "host" | "sandbox";

export interface WorkspaceAllowedPath {
  path: string;
  access: WorkspaceAllowedPathAccess;
}

export interface WorkspaceSandboxConfig {
  /** Allowed egress hosts for network access. Default: ["*"] (all). */
  allowedHosts?: string[];
  /** Extra environment variables injected into the sandbox VM. */
  env?: Record<string, string>;
}

export interface WorkspaceMutableConfig {
  name: string; // "coding", "research"
  description?: string; // shown in workspace picker
  icon?: string; // SF Symbol name or emoji

  // Skills — which skills to sync into the session
  skills: string[]; // ["searxng", "fetch", "ast-grep"]

  // Permissions
  allowedPaths?: WorkspaceAllowedPath[]; // Extra dirs beyond workspace
  allowedExecutables?: string[]; // Extra executables auto-allowed for this workspace (e.g. ["node", "python3"])

  // Context
  systemPrompt?: string; // Workspace prompt text (appended or replacement depending on mode)
  systemPromptMode: WorkspaceSystemPromptMode;
  hostMount?: string; // Host directory to mount as /work (e.g. "~/workspace/oppi")
  defaultModel?: string; // Optional default model for new sessions in this workspace

  // Tools and extensions
  // Undefined = pi default tools. Defined = authoritative allowlist.
  tools?: string[]; // Tool allowlist (e.g. read/bash/edit/write + extension tools)
  // Undefined = discovered pi extensions only. Defined = authoritative allowlist.
  extensions?: string[]; // Extension allowlist (host extensions + Oppi names like ask/subagents/voice)

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

export interface WorkspaceListSummary {
  workspaceId: string;
  activeCount: number;
  stoppedCount: number;
  hasAttention: boolean;
  hasErrorRoot: boolean;
  latestActivity?: number;
}

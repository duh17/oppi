import type { WorkspaceSystemPromptMode } from "./workspace.js";

export interface CreateWorkspaceRequest {
  name: string;
  description?: string;
  icon?: string;
  skills: string[];
  allowedPaths?: { path: string; access: "read" | "readwrite" }[];
  allowedExecutables?: string[];
  systemPrompt?: string;
  systemPromptMode?: WorkspaceSystemPromptMode;
  hostMount?: string;
  defaultModel?: string;
  tools?: string[];
  extensions?: string[];
  gitStatusEnabled?: boolean;
  runtime?: "host" | "sandbox";
  sandboxConfig?: { allowedHosts?: string[]; env?: Record<string, string> };
}

export interface UpdateWorkspaceRequest {
  name?: string;
  description?: string | null;
  icon?: string | null;
  skills?: string[];
  allowedPaths?: { path: string; access: "read" | "readwrite" }[];
  allowedExecutables?: string[];
  systemPrompt?: string | null;
  systemPromptMode?: WorkspaceSystemPromptMode;
  hostMount?: string | null;
  defaultModel?: string | null;
  tools?: string[];
  extensions?: string[];
  gitStatusEnabled?: boolean;
  runtime?: "host" | "sandbox";
  sandboxConfig?: { allowedHosts?: string[]; env?: Record<string, string> } | null;
}

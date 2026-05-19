import type {
  WorkspaceMutableConfig,
  WorkspaceSandboxConfig,
  WorkspaceSystemPromptMode,
} from "./workspace.js";

export interface CreateWorkspaceRequest extends Omit<WorkspaceMutableConfig, "systemPromptMode"> {
  systemPromptMode?: WorkspaceSystemPromptMode;
}

type NullableWorkspaceUpdateKey =
  | "description"
  | "icon"
  | "systemPrompt"
  | "hostMount"
  | "defaultModel"
  | "sandboxConfig";

export interface UpdateWorkspaceRequest extends Partial<
  Omit<WorkspaceMutableConfig, NullableWorkspaceUpdateKey>
> {
  description?: string | null;
  icon?: string | null;
  systemPrompt?: string | null;
  hostMount?: string | null;
  defaultModel?: string | null;
  sandboxConfig?: WorkspaceSandboxConfig | null;
}

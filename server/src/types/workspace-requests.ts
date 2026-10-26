import type {
  WorkspaceMutableConfig,
  WorkspaceSandboxConfig,
  WorkspaceSystemPromptMode,
} from "./workspace.js";

export interface CreateWorkspaceRequest extends Omit<
  WorkspaceMutableConfig,
  "systemPromptMode" | "icon" | "hostMount" | "runtime"
> {
  icon?: WorkspaceMutableConfig["icon"];
  /** Empty or omitted: Oppi creates and stores a folder for the workspace. */
  hostMount?: string;
  /** Omitted: "host". */
  runtime?: WorkspaceMutableConfig["runtime"];
  systemPromptMode?: WorkspaceSystemPromptMode;
}

type NullableWorkspaceUpdateKey =
  "description" | "systemPrompt" | "hostMount" | "sandboxConfig" | "tools";

export interface UpdateWorkspaceRequest extends Partial<
  Omit<WorkspaceMutableConfig, NullableWorkspaceUpdateKey>
> {
  description?: string | null;
  /** `null` clears the list: every tool is allowed. */
  tools?: string[] | null;
  icon?: WorkspaceMutableConfig["icon"];
  systemPrompt?: string | null;
  hostMount?: string | null;
  sandboxConfig?: WorkspaceSandboxConfig | null;
}

import type {
  WorkspaceMutableConfig,
  WorkspaceSandboxConfig,
  WorkspaceSystemPromptMode,
} from "./workspace.js";

export interface CreateWorkspaceRequest extends Omit<WorkspaceMutableConfig, "systemPromptMode"> {
  /** Ignored compatibility field from older Oppi clients. Pi settings own skill discovery. */
  skills?: string[];
  /** Ignored compatibility field from older Oppi clients. Pi settings own extension discovery. */
  extensions?: string[];
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
  /** Ignored compatibility field from older Oppi clients. Pi settings own skill discovery. */
  skills?: string[];
  /** Ignored compatibility field from older Oppi clients. Pi settings own extension discovery. */
  extensions?: string[];
  description?: string | null;
  icon?: string | null;
  systemPrompt?: string | null;
  hostMount?: string | null;
  defaultModel?: string | null;
  sandboxConfig?: WorkspaceSandboxConfig | null;
}

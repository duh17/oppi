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
  /** Ignored compatibility field from older Oppi clients. Pi settings own skill discovery. */
  skills?: string[];
  /** Ignored compatibility field from older Oppi clients. Pi settings own extension discovery. */
  extensions?: string[];
  systemPromptMode?: WorkspaceSystemPromptMode;
}

type NullableWorkspaceUpdateKey = "description" | "systemPrompt" | "hostMount" | "sandboxConfig";

export interface UpdateWorkspaceRequest extends Partial<
  Omit<WorkspaceMutableConfig, NullableWorkspaceUpdateKey>
> {
  /** Ignored compatibility field from older Oppi clients. Pi settings own skill discovery. */
  skills?: string[];
  /** Ignored compatibility field from older Oppi clients. Pi settings own extension discovery. */
  extensions?: string[];
  description?: string | null;
  icon?: WorkspaceMutableConfig["icon"];
  systemPrompt?: string | null;
  hostMount?: string | null;
  sandboxConfig?: WorkspaceSandboxConfig | null;
}

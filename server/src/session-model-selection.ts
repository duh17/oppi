import type { Workspace } from "./types.js";

export type InitialChatModelSource =
  | "request"
  | "subagent"
  | "sourceSession"
  | "workspaceDefault"
  | "piSettings";

export interface InitialChatModelSelection {
  /** Canonical provider/model-id when Oppi chooses an explicit initial model. Undefined means defer to Pi settings/trace fallback. */
  model?: string;
  /** Where the selected model came from. */
  source: InitialChatModelSource;
}

export interface InitialChatModelInput {
  /** Direct client/tool override. Highest precedence. */
  requestModel?: string | null;
  /** Effective subagent model after profile/model-policy resolution. */
  subagentModel?: string | null;
  /** Model inherited from a parent, origin, selected, or fork source session. */
  sourceSessionModel?: string | null;
  /** Workspace whose default should apply when no explicit/source model wins. */
  workspace?: Pick<Workspace, "defaultModel"> | null;
  /** Disable workspace defaults for flows where Pi should restore from an existing trace. */
  includeWorkspaceDefault?: boolean;
}

export function normalizeInitialModelId(value: string | null | undefined): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * Resolve the initial chat model for newly-created Oppi sessions.
 *
 * Oppi intentionally does not own a top-level server default model. When no
 * explicit, inherited, or workspace model applies, the model is left undefined
 * so the Pi SDK can use the normal Pi settings/trace/provider fallback.
 */
export function resolveInitialChatModel(input: InitialChatModelInput): InitialChatModelSelection {
  const requested = normalizeInitialModelId(input.requestModel);
  if (requested) return { model: requested, source: "request" };

  const subagent = normalizeInitialModelId(input.subagentModel);
  if (subagent) return { model: subagent, source: "subagent" };

  const sourceSession = normalizeInitialModelId(input.sourceSessionModel);
  if (sourceSession) return { model: sourceSession, source: "sourceSession" };

  if (input.includeWorkspaceDefault !== false) {
    const workspaceDefault = normalizeInitialModelId(input.workspace?.defaultModel);
    if (workspaceDefault) return { model: workspaceDefault, source: "workspaceDefault" };
  }

  return { source: "piSettings" };
}

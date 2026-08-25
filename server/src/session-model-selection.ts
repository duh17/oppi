export type InitialChatModelSource = "request" | "sourceSession" | "piSettings";

export interface InitialChatModelSelection {
  /** Canonical provider/model-id when Oppi chooses an explicit initial model. Undefined means defer to Pi settings/trace fallback. */
  model?: string;
  /** Where the selected model came from. */
  source: InitialChatModelSource;
}

export interface InitialChatModelInput {
  /** Direct client/tool override. Highest precedence. */
  requestModel?: string | null;
  /** Model inherited from an origin, selected, or fork source session. */
  sourceSessionModel?: string | null;
}

export function normalizeInitialModelId(value: string | null | undefined): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * Resolve the initial chat model for newly-created Oppi sessions.
 *
 * Oppi does not own a default model. When no explicit or inherited model applies,
 * the model stays undefined so Pi can use its settings, trace, and provider fallback.
 */
export function resolveInitialChatModel(input: InitialChatModelInput): InitialChatModelSelection {
  const requested = normalizeInitialModelId(input.requestModel);
  if (requested) return { model: requested, source: "request" };

  const sourceSession = normalizeInitialModelId(input.sourceSessionModel);
  if (sourceSession) return { model: sourceSession, source: "sourceSession" };

  return { source: "piSettings" };
}

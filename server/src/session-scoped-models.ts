import type { ResolveModelScopeResult } from "@earendil-works/pi-coding-agent";

import { isThinkingLevel, type ThinkingLevel } from "./thinking-levels.js";

/**
 * Turn Pi enabledModels patterns such as `anthropic/*:high` into createAgentSession
 * scopedModels. Empty or missing patterns stay unset so Pi uses the full catalog.
 */
export async function resolveEnabledScopedModels(
  patterns: string[] | undefined,
  resolve: (patterns: string[]) => Promise<ResolveModelScopeResult>,
): Promise<{
  scopedModels?: ResolveModelScopeResult["scopedModels"];
  diagnostics: ResolveModelScopeResult["diagnostics"];
}> {
  if (!patterns?.length) {
    return { diagnostics: [] };
  }

  const result = await resolve(patterns);
  return {
    scopedModels: result.scopedModels.length > 0 ? result.scopedModels : undefined,
    diagnostics: result.diagnostics,
  };
}

function scopedModelId(model: { provider: string; id: string }): string {
  return `${model.provider}/${model.id}`;
}

function scopedEntryMatches(
  entry: { model: { provider: string; id: string } },
  resolvedModel: { provider: string; id: string } | undefined,
  sessionModel: string | undefined,
): boolean {
  const canonical = scopedModelId(entry.model);
  if (resolvedModel) {
    return resolvedModel.provider === entry.model.provider && resolvedModel.id === entry.model.id;
  }
  const requested = sessionModel?.trim();
  if (!requested) return false;
  return requested === canonical || requested === entry.model.id;
}

/**
 * Pi's createAgentSession calls findInitialModel with scopedModels:[] whenever
 * options.model is set, and Oppi usually passes session.model. Apply the
 * matching scoped thinking pin on new session create, and seed the first scoped
 * model when session.model is unset.
 *
 * Explicit session/launch thinking, required launch models, and resumed
 * transcripts stay as-is.
 */
export function resolveInitialScopedSessionPins<
  TModel extends { provider: string; id: string },
>(input: {
  scopedModels?: Array<{ model: TModel; thinkingLevel?: ThinkingLevel }>;
  resolvedModel?: TModel;
  sessionModel?: string;
  explicitThinkingLevel?: string;
  requiredLaunchModel?: boolean;
  isResume?: boolean;
}): {
  model?: TModel;
  thinkingLevel?: ThinkingLevel;
} {
  const scoped = input.scopedModels ?? [];
  const explicitThinking = input.explicitThinkingLevel
    ? isThinkingLevel(input.explicitThinkingLevel)
      ? input.explicitThinkingLevel
      : undefined
    : undefined;

  let model = input.resolvedModel;
  if (
    !model &&
    !input.sessionModel?.trim() &&
    !input.requiredLaunchModel &&
    !input.isResume &&
    scoped.length > 0
  ) {
    model = scoped[0].model;
  }

  let thinkingLevel = explicitThinking;
  if (!thinkingLevel && !input.isResume && scoped.length > 0) {
    const match =
      scoped.find((entry) => scopedEntryMatches(entry, model, input.sessionModel)) ??
      (!input.sessionModel?.trim() ? scoped[0] : undefined);
    if (match?.thinkingLevel && isThinkingLevel(match.thinkingLevel)) {
      thinkingLevel = match.thinkingLevel;
    }
  }

  return { model, thinkingLevel };
}

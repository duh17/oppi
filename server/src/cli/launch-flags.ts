import type { ThinkingLevel } from "../thinking-levels.js";

export type ResolvedCliModel = {
  canonicalId: string;
  thinkingLevel?: ThinkingLevel;
};

export type CliToolPolicy = {
  tools?: string[];
  excludeTools?: string[];
  noTools?: "all" | "builtin";
};

export function parseCsvList(value: string): string[] {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

export function resolveNoToolsFlag(flags: Record<string, string>): "all" | "builtin" | undefined {
  const noTools = Object.hasOwn(flags, "no-tools");
  const noBuiltin = Object.hasOwn(flags, "no-builtin-tools");
  if (noTools && noBuiltin) {
    throw new Error("--no-tools and --no-builtin-tools cannot be used together");
  }
  if (noTools) return "all";
  if (noBuiltin) return "builtin";
  return undefined;
}

export function resolveThinkingFromFlags(
  flags: Record<string, string>,
  modelThinking?: ThinkingLevel,
): string | undefined {
  if (Object.hasOwn(flags, "thinking")) return flags.thinking;
  return modelThinking;
}

export function resolveToolPolicyFromFlags(flags: Record<string, string>): CliToolPolicy {
  const noTools = resolveNoToolsFlag(flags);
  const tools = Object.hasOwn(flags, "tools") ? parseCsvList(flags.tools ?? "") : undefined;
  const excludeTools = Object.hasOwn(flags, "exclude-tools")
    ? parseCsvList(flags["exclude-tools"] ?? "")
    : undefined;
  return {
    ...(tools !== undefined ? { tools } : {}),
    ...(excludeTools !== undefined ? { excludeTools } : {}),
    ...(noTools ? { noTools } : {}),
  };
}

export function hasSessionDefaultFlags(flags: Record<string, string>): boolean {
  return ["model", "thinking", "tools", "exclude-tools", "no-tools", "no-builtin-tools"].some(
    (key) => Object.hasOwn(flags, key),
  );
}

export function applySessionDefaultFlags(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
  resolvedModel?: ResolvedCliModel,
): Record<string, unknown> {
  const thinking = resolveThinkingFromFlags(flags, resolvedModel?.thinkingLevel);
  const policy = resolveToolPolicyFromFlags(flags);
  const hasOverlay =
    resolvedModel !== undefined ||
    thinking !== undefined ||
    policy.tools !== undefined ||
    policy.excludeTools !== undefined ||
    policy.noTools !== undefined;
  if (!hasOverlay) return definition;

  const current = isRecord(definition.sessionDefaults) ? { ...definition.sessionDefaults } : {};
  if (resolvedModel) current.model = resolvedModel.canonicalId;
  if (thinking !== undefined) current.thinkingLevel = thinking;
  if (policy.tools !== undefined) current.tools = policy.tools;
  if (policy.excludeTools !== undefined) current.excludeTools = policy.excludeTools;
  if (policy.noTools !== undefined) current.noTools = policy.noTools;
  return { ...definition, sessionDefaults: current };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

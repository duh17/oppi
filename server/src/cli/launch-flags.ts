import type { ThinkingLevel } from "../thinking-levels.js";
import { isRecord } from "../json-shape.js";

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

const AGENT_EDITOR_FLAGS = [
  "name",
  "description",
  "icon",
  "icon-image",
  "instructions",
  "instructions-file",
  "instructions-mode",
  "core",
  "ask",
  "no-ask",
  "notify",
  "no-notify",
  "subagent",
  "no-subagent",
  "plugins",
  "mcp",
  "skills",
  "context-files",
  "no-context-files",
  "session-history",
  "no-session-history",
  "allowed-workspaces",
  "required-runtime",
  "required-engine",
  "clear-description",
  "clear-icon",
  "clear-instructions",
  "clear-plugins",
  "clear-mcp",
  "clear-skills",
  "clear-allowed-workspaces",
  "clear-required-runtime",
  "clear-required-engine",
] as const;

/** A saved Agent's `sessionDefaults` holds a model and a thinking level, nothing else. */
export function hasAgentModelFlags(flags: Record<string, string>): boolean {
  return ["model", "thinking"].some((key) => Object.hasOwn(flags, key));
}

export function hasAgentDefinitionFlags(flags: Record<string, string>): boolean {
  return hasAgentModelFlags(flags) || AGENT_EDITOR_FLAGS.some((key) => Object.hasOwn(flags, key));
}

/**
 * The model and thinking level a saved Agent launches with. A saved Agent's capabilities are its
 * own: a launch cannot widen or narrow them, so no tool-policy flag applies here.
 */
export function applyAgentModelFlags(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
  resolvedModel?: ResolvedCliModel,
): Record<string, unknown> {
  const thinking = resolveThinkingFromFlags(flags, resolvedModel?.thinkingLevel);
  if (resolvedModel === undefined && thinking === undefined) return definition;
  const current = isRecord(definition.sessionDefaults) ? { ...definition.sessionDefaults } : {};
  if (resolvedModel) current.model = resolvedModel.canonicalId;
  if (thinking !== undefined) current.thinkingLevel = thinking;
  return { ...definition, sessionDefaults: current };
}

/**
 * `all` clears the selection (the Agent follows everything), `none` selects nothing, else the CSV
 * names. An empty value is refused: it reads as "everything" to anyone who meant "nothing".
 */
export function parseAgentSelectionFlag(value: string): string[] | null {
  const trimmed = value.trim();
  if (!trimmed) {
    throw new Error(
      "an empty value is neither none nor all: pass 'none' for no choice, or 'all' for every one",
    );
  }
  if (trimmed === "all") return null;
  if (trimmed === "none") return [];
  return parseCsvList(trimmed);
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

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { properLockfile } from "./pi-lockfile.js";
import { importPiDist } from "./pi-private.js";
import { PI_DISCOVERY_TOOL_NAMES } from "./pi-tool-names.js";

const [piTools, piSettings, piSystemPrompt] = await Promise.all([
  importPiDist("core/tools/index.js", ["allToolNames", "createToolDefinition"]),
  importPiDist("core/settings-manager.js", [
    "DEFAULT_TOOL_NAMES",
    "applyToolModifiers",
    "isToolModifier",
  ]),
  importPiDist("core/system-prompt.js", ["buildSystemPromptSections"]),
]);

export const PI_GLOBAL_SYSTEM_PROMPT_PATH = "~/.pi/agent/SYSTEM.md";

/** Pi's built-in tools (`allToolNames`), in Pi's order. */
export const PI_BUILTIN_TOOL_NAMES = piTools.allToolNames as ReadonlySet<string>;

/** The tools Pi selects when `defaultTools` is unset (`DEFAULT_TOOL_NAMES`). */
export const PI_DEFAULT_TOOL_NAMES = piSettings.DEFAULT_TOOL_NAMES as readonly string[];

/** The tools Pi's own extensions register off, which `defaultTools` turns on. */
export const PI_OPTIONAL_TOOL_NAMES = PI_DISCOVERY_TOOL_NAMES;

/** Pi's built-in tools an Oppi host can run: every one but PowerShell, as no host is Windows. */
const SETTING_TOOL_NAMES = new Set(
  [...PI_BUILTIN_TOOL_NAMES].filter((name) => name !== "powershell"),
);

export type PiSystemPromptSource = "file" | "default";

export interface PiSystemPromptSnapshot {
  source: PiSystemPromptSource;
  path: typeof PI_GLOBAL_SYSTEM_PROMPT_PATH;
  resolvedPath?: string;
  content: string;
}

export interface PiDefaultToolsSnapshot {
  defaultTools: string[] | null;
}

export class PiGlobalConfigError extends Error {
  readonly code: "validation" | "malformed";

  constructor(code: "validation" | "malformed", message: string) {
    super(message);
    this.name = "PiGlobalConfigError";
    this.code = code;
  }
}

export function readPiSystemPrompt(agentDir: string): PiSystemPromptSnapshot {
  const resolvedPath = join(agentDir, "SYSTEM.md");
  if (!existsSync(resolvedPath)) {
    return {
      source: "default",
      path: PI_GLOBAL_SYSTEM_PROMPT_PATH,
      content: buildPiDefaultSystemPromptTemplate(),
    };
  }
  return {
    source: "file",
    path: PI_GLOBAL_SYSTEM_PROMPT_PATH,
    resolvedPath,
    content: readFileSync(resolvedPath, "utf8"),
  };
}

export function readPiDefaultTools(agentDir: string): PiDefaultToolsSnapshot {
  const settings = readGlobalSettingsObject(agentDir);
  if (settings === undefined || !("defaultTools" in settings)) {
    return { defaultTools: null };
  }
  return { defaultTools: parseDefaultTools(settings.defaultTools) };
}

/**
 * Every tool name Pi's `defaultTools` governs here: Pi's built-in tools, the `codemode` and
 * `tool_search` extensions Pi registers off, and the names the live setting turns on. An Agent
 * that states its own Pi tool set denies the rest of these; one that states none follows it.
 */
export function piToolNames(setting: readonly string[] | null): string[] {
  return [...new Set([...PI_BUILTIN_TOOL_NAMES, ...PI_OPTIONAL_TOOL_NAMES, ...(setting ?? [])])];
}

/**
 * The Pi Tools setting resolved the way Pi resolves it (`SettingsManager.getDefaultTools`): plain
 * names replace Pi's defaults, and `+name` / `-name` entries edit the result in order. This is the
 * live selection the Pi Tools page shows, which a migration copies into an Agent's own set.
 */
export function resolvedPiDefaultTools(agentDir: string): string[] {
  const { defaultTools } = readPiDefaultTools(agentDir);
  const entries = defaultTools ?? [];
  const isModifier = piSettings.isToolModifier as (entry: string) => boolean;
  const applyModifiers = piSettings.applyToolModifiers as (
    base: readonly string[],
    entries: readonly string[],
  ) => string[];
  const plain = entries.filter((entry) => !isModifier(entry));
  const base =
    defaultTools === null || (plain.length === 0 && entries.length > 0)
      ? [...PI_DEFAULT_TOOL_NAMES]
      : plain;
  return applyModifiers(base, entries);
}

/**
 * `optionalToolNames` are tools loaded extensions register off (Pi's `codemode`, `tool_search`).
 * Entries may carry Pi's `+name` / `-name` modifiers, which change Pi's standard selection.
 */
export function writePiDefaultTools(
  agentDir: string,
  defaultTools: string[] | null,
  optionalToolNames: readonly string[] = [],
): PiDefaultToolsSnapshot {
  const validated = validateDefaultTools(defaultTools, optionalToolNames);
  let snapshot: PiDefaultToolsSnapshot = { defaultTools: validated };
  // Match Pi FileSettingsStorage.withLock so Oppi and Pi serialize settings.json writes.
  // ServerResourceService.withMutationLock only serializes Oppi writers.
  withPiGlobalSettingsLock(agentDir, (raw) => {
    const current = parseSettingsObject(raw);
    if (validated === null) {
      if (!("defaultTools" in current)) {
        snapshot = { defaultTools: null };
        return undefined;
      }
      delete current.defaultTools;
      snapshot = { defaultTools: null };
    } else {
      current.defaultTools = validated;
      snapshot = { defaultTools: validated };
    }
    return JSON.stringify(current, null, 2);
  });
  return snapshot;
}

/**
 * The part of Pi's default system prompt that `SYSTEM.md` replaces (Pi uses the file in place of
 * its preamble, tools, rules, and docs sections), built by Pi itself for its default tools.
 */
function buildPiDefaultSystemPromptTemplate(): string {
  const createToolDefinition = piTools.createToolDefinition as (
    name: string,
    cwd: string,
  ) => { promptSnippet?: string; promptGuidelines?: string[] };
  const buildSections = piSystemPrompt.buildSystemPromptSections as (options: {
    cwd: string;
    selectedTools: string[];
    toolSnippets: Record<string, string>;
    toolGuidelines: Record<string, string[]>;
  }) => Record<string, string>;
  const toolSnippets: Record<string, string> = {};
  const toolGuidelines: Record<string, string[]> = {};
  for (const name of PI_DEFAULT_TOOL_NAMES) {
    const definition = createToolDefinition(name, "/");
    // As `AgentSession` reads them: a snippet as one line, empty guidelines left out.
    const snippet = definition.promptSnippet?.replace(/\s+/g, " ").trim();
    if (snippet) toolSnippets[name] = snippet;
    if (definition.promptGuidelines?.length) toolGuidelines[name] = definition.promptGuidelines;
  }
  const sections = buildSections({
    cwd: "/",
    selectedTools: [...PI_DEFAULT_TOOL_NAMES],
    toolSnippets,
    toolGuidelines,
  });
  return [sections.preamble, sections.tools, sections.rules, sections.docs]
    .filter((section) => section !== undefined)
    .join("\n\n");
}

function readGlobalSettingsObject(agentDir: string): Record<string, unknown> | undefined {
  const settingsPath = join(agentDir, "settings.json");
  if (!existsSync(settingsPath)) return undefined;
  return parseSettingsObject(readFileSync(settingsPath, "utf8"));
}

function parseSettingsObject(raw: string | undefined): Record<string, unknown> {
  if (raw === undefined) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(stripBom(raw));
  } catch (cause: unknown) {
    throw new PiGlobalConfigError(
      "malformed",
      `Pi settings are malformed: ${cause instanceof Error ? cause.message : String(cause)}`,
    );
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new PiGlobalConfigError("malformed", "Pi settings are malformed");
  }
  return parsed as Record<string, unknown>;
}

function withPiGlobalSettingsLock(
  agentDir: string,
  fn: (current: string | undefined) => string | undefined,
): void {
  const settingsPath = join(agentDir, "settings.json");
  const dir = dirname(settingsPath);
  let release: (() => void) | undefined;
  try {
    const fileExists = existsSync(settingsPath);
    if (fileExists) {
      release = acquirePiSettingsLock(settingsPath);
    }
    const current = fileExists ? readFileSync(settingsPath, "utf8") : undefined;
    const next = fn(current);
    if (next !== undefined) {
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true });
      }
      if (!release) {
        release = acquirePiSettingsLock(settingsPath);
      }
      writeFileSync(settingsPath, next, "utf8");
    }
  } finally {
    release?.();
  }
}

function acquirePiSettingsLock(settingsPath: string): () => void {
  const maxAttempts = 10;
  const delayMs = 20;
  let lastError: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return properLockfile.lockSync(settingsPath, { realpath: false });
    } catch (error: unknown) {
      const code =
        typeof error === "object" && error !== null && "code" in error
          ? String(error.code)
          : undefined;
      if (code !== "ELOCKED" || attempt === maxAttempts) {
        throw error;
      }
      lastError = error;
      const start = Date.now();
      while (Date.now() - start < delayMs) {
        // Sleep synchronously to match FileSettingsStorage.
      }
    }
  }
  throw lastError ?? new Error("Failed to acquire settings lock");
}

function parseDefaultTools(value: unknown): string[] {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new PiGlobalConfigError(
      "malformed",
      "defaultTools must be an array of built-in Pi tool names",
    );
  }
  return [...value];
}

function validateDefaultTools(
  value: string[] | null,
  optionalToolNames: readonly string[],
): string[] | null {
  if (value === null) return null;
  const invalid = (): PiGlobalConfigError =>
    new PiGlobalConfigError(
      "validation",
      "defaultTools must be null or an array of built-in Pi tool names or optional tools Pi registers off",
    );
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw invalid();
  }
  const optional = new Set(optionalToolNames);
  const isKnown = (name: string): boolean => SETTING_TOOL_NAMES.has(name) || optional.has(name);
  if (
    value.some((entry) =>
      entry.startsWith("+") || entry.startsWith("-") ? !isKnown(entry.slice(1)) : !isKnown(entry),
    )
  ) {
    throw invalid();
  }
  return [...value];
}

function stripBom(value: string): string {
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
}

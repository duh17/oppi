import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createBashToolDefinition,
  createEditToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  getDocsPath,
  getExamplesPath,
  getReadmePath,
} from "@earendil-works/pi-coding-agent";

export const PI_GLOBAL_SYSTEM_PROMPT_PATH = "~/.pi/agent/SYSTEM.md";
export const PI_BUILTIN_TOOL_NAMES = [
  "read",
  "bash",
  "edit",
  "write",
  "grep",
  "find",
  "ls",
] as const;

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

const BUILTIN_TOOL_NAME_SET = new Set<string>(PI_BUILTIN_TOOL_NAMES);
const DEFAULT_PROMPT_TOOL_NAMES = ["read", "bash", "edit", "write"] as const;
const piLockfile = createRequire(
  fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")),
)("proper-lockfile") as {
  lockSync: (file: string, options?: { realpath?: boolean }) => () => void;
};

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

export function writePiDefaultTools(
  agentDir: string,
  defaultTools: string[] | null,
): PiDefaultToolsSnapshot {
  const validated = validateDefaultTools(defaultTools);
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

function buildPiDefaultSystemPromptTemplate(): string {
  const tools = DEFAULT_PROMPT_TOOL_NAMES.map((name) => {
    const definition = defaultPromptToolDefinition(name);
    return { name, snippet: definition.promptSnippet, guidelines: definition.promptGuidelines };
  });
  const toolsList = tools
    .filter((tool) => tool.snippet)
    .map((tool) => `- ${tool.name}: ${tool.snippet}`)
    .join("\n");

  const guidelinesList: string[] = [];
  const seen = new Set<string>();
  const addGuideline = (guideline: string): void => {
    const normalized = guideline.trim();
    if (normalized.length === 0 || seen.has(normalized)) return;
    seen.add(normalized);
    guidelinesList.push(normalized);
  };

  addGuideline("Use bash for file operations like ls, rg, find");
  for (const tool of tools) {
    for (const guideline of tool.guidelines ?? []) addGuideline(guideline);
  }
  addGuideline("Be concise in your responses");
  addGuideline("Show file paths clearly when working with files");

  const readmePath = getReadmePath();
  const docsPath = getDocsPath();
  const examplesPath = getExamplesPath();
  return `You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
${toolsList}

In addition to the tools above, you may have access to other custom tools depending on the project.

Guidelines:
${guidelinesList.map((guideline) => `- ${guideline}`).join("\n")}

Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
- Main documentation: ${readmePath}
- Additional docs: ${docsPath}
- Examples: ${examplesPath} (extensions, custom tools, SDK)
- When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
- When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), environment variables (docs/environment-variables.md)
- When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
- Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)`;
}

function defaultPromptToolDefinition(name: (typeof DEFAULT_PROMPT_TOOL_NAMES)[number]): {
  name: string;
  promptSnippet?: string;
  promptGuidelines?: string[];
} {
  switch (name) {
    case "read":
      return createReadToolDefinition("/");
    case "bash":
      return createBashToolDefinition("/");
    case "edit":
      return createEditToolDefinition("/");
    case "write":
      return createWriteToolDefinition("/");
  }
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
      return piLockfile.lockSync(settingsPath, { realpath: false });
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

function validateDefaultTools(value: string[] | null): string[] | null {
  if (value === null) return null;
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new PiGlobalConfigError(
      "validation",
      "defaultTools must be null or an array of built-in Pi tool names",
    );
  }
  if (value.some((name) => !BUILTIN_TOOL_NAME_SET.has(name))) {
    throw new PiGlobalConfigError(
      "validation",
      "defaultTools must be null or an array of built-in Pi tool names",
    );
  }
  return [...value];
}

function stripBom(value: string): string {
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
}

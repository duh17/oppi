import { isAbsolute, sep } from "node:path";

/**
 * Pi's own agent configuration files: the only part of the owner's home the
 * editor may write (`/files/current?origin=pi`). The rest of the home stays
 * read-only, so the allowlist names files, not a root.
 *
 * - `SYSTEM.md`: Pi's global system prompt (`~/.pi/agent/SYSTEM.md`).
 * - `prompts/` Markdown files: Pi's global prompt templates.
 *
 * A path is Pi-agent-relative. This is the *lexical* answer: `..`, `.`,
 * dot-segments, empty segments, and host-absolute paths are refused, and
 * `inspectFileForEdit` asks the same function again about the canonical path it
 * resolved (`allowsCanonical`), so a symlink inside the agent directory cannot
 * reach a file this list does not name.
 */
export const PI_AGENT_SYSTEM_PROMPT_FILE = "SYSTEM.md";
export const PI_AGENT_PROMPTS_DIRECTORY = "prompts";
const PROMPT_TEMPLATE_SUFFIX = ".md";

/** The allowlist's answer for a Pi-agent-relative path: the path, or null. */
export function piAgentEditablePath(requestedPath: string): string | null {
  if (!requestedPath || requestedPath.includes("\0")) return null;
  const normalized = requestedPath.replaceAll("\\", "/");
  if (normalized.endsWith(sep)) return null;
  if (isAbsolute(normalized) || normalized.startsWith("~")) return null;
  // Every segment must be a plain name: no traversal, no `.`, no `.git`.
  if (normalized.split("/").some((segment) => segment === "" || segment.startsWith("."))) {
    return null;
  }
  if (normalized === PI_AGENT_SYSTEM_PROMPT_FILE) return normalized;
  if (
    normalized.startsWith(`${PI_AGENT_PROMPTS_DIRECTORY}/`) &&
    normalized.endsWith(PROMPT_TEMPLATE_SUFFIX)
  ) {
    return normalized;
  }
  return null;
}

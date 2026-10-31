import { isAbsolute, sep } from "node:path";

/**
 * Pi's own agent configuration files: the only part of the owner's home the
 * editor may write (`/files/current?origin=pi`). The rest of the home stays
 * read-only, so the allowlist names files, not a root.
 *
 * - `SYSTEM.md`: Pi's global system prompt (`~/.pi/agent/SYSTEM.md`).
 * - `prompts/**`: Pi's global prompt templates (`~/.pi/agent/prompts/`).
 *
 * A path is Pi-agent-relative. `..`, `.`, empty segments, and host-absolute
 * paths are refused here; resolution also refuses a final-component symlink and
 * anything whose realpath leaves the agent directory (`inspectFileForEdit`), so
 * this list narrows that root to these files rather than widening anything.
 */
export const PI_AGENT_SYSTEM_PROMPT_FILE = "SYSTEM.md";
export const PI_AGENT_PROMPTS_DIRECTORY = "prompts";

/** The allowlist's answer for a Pi-agent-relative path: the path, or null. */
export function piAgentEditablePath(requestedPath: string): string | null {
  if (!requestedPath || requestedPath.includes("\0")) return null;
  const normalized = requestedPath.replaceAll("\\", "/");
  if (normalized.endsWith(sep)) return null;
  if (isAbsolute(normalized) || normalized.startsWith("~")) return null;
  // Every segment must be a plain name: no traversal, no `.`, no `//`.
  if (
    normalized.split("/").some((segment) => segment === "" || segment === "." || segment === "..")
  ) {
    return null;
  }
  if (normalized === PI_AGENT_SYSTEM_PROMPT_FILE) return normalized;
  if (normalized.startsWith(`${PI_AGENT_PROMPTS_DIRECTORY}/`)) return normalized;
  return null;
}

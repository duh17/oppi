/**
 * A saved Agent's declaration: what it may do, not how Pi is wired to do it.
 *
 * An Agent states intent — Pi tool names, plugin names, MCP servers and tools, Skill names,
 * context toggles. It never names Pi's wiring: no `builtin:*` extension IDs, no
 * `mcp__<server>__<tool>` strings, no host Skill paths. `agent-capabilities.ts` is the one owner
 * that turns this into a session, for both engines.
 */
import type { IconChoice } from "./types.js";
import type { ThinkingLevel } from "./thinking-levels.js";
import { isRecord } from "./json-shape.js";

/** One MCP server's tools: `"all"`, or the exact tool names it may call. */
export type AgentMcpTools = "all" | readonly string[];

/**
 * MCP access, keyed by a server's `mcp.json` name (`"gmail"`, `"chrome-devtools"`); the server
 * matches by namespace, so the hyphen and underscore spellings are the same server. Omitted
 * means every configured server; `{}` means none. An Agent that cannot edit files must state it:
 * it never inherits every server by omission.
 */
export type AgentMcpSelection = Readonly<Record<string, AgentMcpTools>>;

export interface AgentCapabilities {
  /**
   * The Pi tools this Agent's sessions start with, named the way Pi's `defaultTools` names them
   * (`read`, `bash`, `codemode`, a tool a plugin registers off). Omitted follows the server's Pi
   * Tools setting; a list is this Agent's own set. Extension tools — a plugin's, an MCP server's —
   * stay enabled either way, so this is not an allow list for everything a session can reach.
   *
   * An Agent whose set leaves out both `edit` and `write` cannot change files: it must then state
   * `plugins` and `mcp`, and the tools of the plugins it does not name stay out of its sessions.
   */
  readonly tools?: readonly string[];
  /** Ask the person a question. Default true. */
  readonly ask?: boolean;
  /** Send a push when a result is ready. Default true. */
  readonly notify?: boolean;
  /** Delegate to child sessions. Default true. */
  readonly subagent?: boolean;
  /** Tool-providing plugins by name. Omitted: every enabled plugin. */
  readonly plugins?: readonly string[];
  /** MCP servers and tools. Omitted: every configured server; `{}`: none. */
  readonly mcp?: AgentMcpSelection;
}

/** What the session reads besides the Agent's own prompt. */
export interface AgentContext {
  /** Skill names (a Skill's folder name). Omitted: Pi discovery. */
  readonly skills?: readonly string[];
  /** The workspace's `AGENTS.md` and prompt. Default true; the only switch either engine reads. */
  readonly contextFiles?: boolean;
  /** `history://` and `agent://` reads. Default true. */
  readonly sessionHistory?: boolean;
}

export interface AgentInstructions {
  /** `replace` replaces the base assistant prompt only; `context.contextFiles` governs AGENTS.md. */
  readonly mode: "append" | "replace";
  readonly text: string;
}

export interface AgentLaunchConstraints {
  readonly allowedWorkspaceIds?: readonly string[];
  readonly requiredRuntime?: "host" | "sandbox";
  /** Every launch runs on this engine: an omitted engine becomes it, another is refused. */
  readonly requiredEngine?: "durable";
}

export interface AgentSessionDefaults {
  readonly model?: string;
  readonly thinkingLevel?: ThinkingLevel;
}

/** A saved Agent, as stored and as launched. */
export interface AgentDefinition {
  readonly name: string;
  readonly icon?: IconChoice;
  readonly description?: string;
  readonly instructions?: AgentInstructions;
  readonly sessionDefaults?: AgentSessionDefaults;
  readonly capabilities?: AgentCapabilities;
  readonly context?: AgentContext;
  readonly launchConstraints?: AgentLaunchConstraints;
}

/** One configured MCP server, as this launch would load it. */
export interface AgentMcpServerFact {
  readonly name: string;
  readonly enabled: boolean;
  /** The server's own exposure, then each of its per-tool overrides. */
  readonly exposures: readonly ("direct" | "codemode" | "deferred" | "hidden")[];
  /** The tool names its last-known list reports, when one is cached; else empty. */
  readonly tools: readonly string[];
}

/** The v1 keys a definition may still carry: the shape `migrateAgentDefinitionV1` rewrites. */
const AGENT_V1_RESOURCE_KEY = "resources";
const AGENT_V1_TOOL_POLICY_KEYS = ["tools", "excludeTools", "noTools"] as const;

/**
 * True when a stored definition is in the v1 shape: Pi wiring (`resources`, or a tool policy in
 * `sessionDefaults`) instead of the capabilities it replaced. The one reader of the old shape is
 * `agent-definition-migration.ts`; everything else refuses such a definition, so a row the
 * migration could not rewrite can never run with v1 wiring read as "everything allowed".
 */
export function isAgentDefinitionV1(value: unknown): boolean {
  if (!isRecord(value)) return false;
  if (AGENT_V1_RESOURCE_KEY in value) return true;
  if ("capabilities" in value || "context" in value) return false;
  const defaults = value.sessionDefaults;
  return isRecord(defaults) && AGENT_V1_TOOL_POLICY_KEYS.some((key) => key in defaults);
}

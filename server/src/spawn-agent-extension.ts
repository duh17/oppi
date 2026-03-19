/**
 * spawn_agent — first-party extension for spawning child sessions.
 *
 * Registers three LLM-callable tools:
 *   spawn_agent    — create a new session in the current workspace
 *   check_agents   — poll child session status
 *   inspect_agent  — progressive-disclosure trace inspection
 *
 * Injected as an in-process factory extension (like autoresearch).
 * Uses direct SessionManager methods — no HTTP round-trip needed.
 */

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import * as fs from "node:fs";
import { Type, type Static } from "@sinclair/typebox";
import type { Session } from "./types.js";

// ---------------------------------------------------------------------------
// Context interface — thin abstraction over SessionManager
// ---------------------------------------------------------------------------

export interface SpawnAgentContext {
  /** Workspace this session belongs to. */
  workspaceId: string;
  /** This session's ID (the parent). */
  sessionId: string;
  /** Create a child session, start it, and send its first prompt. */
  spawnChild(params: {
    name?: string;
    model?: string;
    thinking?: string;
    prompt: string;
  }): Promise<Session>;
  /** List direct child sessions of the current session. */
  listChildren(): Session[];
  /** Get a session by ID (for inspect_agent trace access and tree walks). */
  getSession(sessionId: string): Session | undefined;
  /** List all sessions in the workspace (for tree cost aggregation). */
  listWorkspaceSessions(): Session[];
}

// ---------------------------------------------------------------------------
// Tree utilities
// ---------------------------------------------------------------------------

/** Maximum spawn depth. 0 = root (no spawning), 1 = parent→child, 2 = parent→child→grandchild. */
const MAX_SPAWN_DEPTH = 2;

/** Walk parentSessionId chain upward to compute depth. Root = 0. */
function getSpawnDepth(ctx: SpawnAgentContext): number {
  let depth = 0;
  let currentId: string | undefined = ctx.sessionId;
  while (currentId) {
    const session = ctx.getSession(currentId);
    if (!session?.parentSessionId) break;
    depth++;
    currentId = session.parentSessionId;
  }
  return depth;
}

/** Find the root session ID of the spawn tree. */
function getRootSessionId(ctx: SpawnAgentContext): string {
  let currentId = ctx.sessionId;
  while (true) {
    const session = ctx.getSession(currentId);
    if (!session?.parentSessionId) return currentId;
    currentId = session.parentSessionId;
  }
}

/** Collect all descendant sessions of a given root (breadth-first). */
function getDescendants(rootId: string, allSessions: Session[]): Session[] {
  const descendants: Session[] = [];
  const queue = [rootId];
  while (queue.length > 0) {
    const parentId = queue.shift();
    if (!parentId) continue;
    for (const s of allSessions) {
      if (s.parentSessionId === parentId) {
        descendants.push(s);
        queue.push(s.id);
      }
    }
  }
  return descendants;
}

interface TreeCostSummary {
  totalSessions: number;
  totalCost: number;
  totalTokensInput: number;
  totalTokensOutput: number;
  totalMessages: number;
  busyCount: number;
  stoppedCount: number;
  errorCount: number;
}

function computeTreeCost(rootId: string, allSessions: Session[]): TreeCostSummary {
  const root = allSessions.find((s) => s.id === rootId);
  const descendants = getDescendants(rootId, allSessions);
  const tree = root ? [root, ...descendants] : descendants;

  return {
    totalSessions: tree.length,
    totalCost: tree.reduce((s, t) => s + t.cost, 0),
    totalTokensInput: tree.reduce((s, t) => s + t.tokens.input, 0),
    totalTokensOutput: tree.reduce((s, t) => s + t.tokens.output, 0),
    totalMessages: tree.reduce((s, t) => s + t.messageCount, 0),
    busyCount: tree.filter((t) => t.status === "busy" || t.status === "starting").length,
    stoppedCount: tree.filter((t) => t.status === "stopped" || t.status === "ready").length,
    errorCount: tree.filter((t) => t.status === "error").length,
  };
}

// ---------------------------------------------------------------------------
// Tool schemas
// ---------------------------------------------------------------------------

const spawnAgentParams = Type.Object({
  message: Type.String({
    description: "The task prompt for the child agent.",
  }),
  name: Type.Optional(
    Type.String({
      description:
        "Display name for the child session. Defaults to a truncated version of the message.",
    }),
  ),
  model: Type.Optional(
    Type.String({
      description:
        "Model override for the child session (e.g. 'anthropic/claude-sonnet-4-20250514'). Inherits from parent if omitted.",
    }),
  ),
  thinking: Type.Optional(
    Type.String({
      description:
        "Thinking level override: off, minimal, low, medium, high, xhigh. Inherits from parent if omitted.",
    }),
  ),
});

const checkAgentsParams = Type.Object({});

const inspectAgentParams = Type.Object({
  id: Type.String({
    description: "Session ID of the child agent to inspect.",
  }),
  turn: Type.Optional(
    Type.Number({
      description: "Turn number to drill into (1-based). Omit for overview of all turns.",
    }),
  ),
  tool: Type.Optional(
    Type.Number({
      description:
        "Tool index within the turn (1-based). Requires turn. Shows full args and output.",
    }),
  ),
});

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

interface SpawnAgentDetails {
  agentId: string;
  name: string;
  status: string;
  model?: string;
}

interface CheckAgentsDetails {
  agents: AgentSummary[];
}

interface AgentSummary {
  id: string;
  name?: string;
  status: string;
  model?: string;
  cost: number;
  messageCount: number;
  durationMs: number;
  firstMessage?: string;
}

interface InspectAgentDetails {
  sessionId: string;
  level: "overview" | "turn" | "tool";
  turnCount?: number;
  toolCount?: number;
  errorCount?: number;
}

// ---------------------------------------------------------------------------
// Session helpers
// ---------------------------------------------------------------------------

function sessionToSummary(s: Session): AgentSummary {
  return {
    id: s.id,
    name: s.name ?? undefined,
    status: s.status,
    model: s.model ?? undefined,
    cost: s.cost,
    messageCount: s.messageCount,
    durationMs: Date.now() - s.createdAt,
    firstMessage: s.firstMessage ?? undefined,
  };
}

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const remaining = seconds % 60;
  return remaining > 0 ? `${minutes}m${remaining}s` : `${minutes}m`;
}

function formatCost(cost: number): string {
  if (cost === 0) return "$0";
  if (cost < 0.01) return `$${cost.toFixed(4)}`;
  return `$${cost.toFixed(2)}`;
}

const STATUS_ICONS: Record<string, string> = {
  starting: "⏳",
  ready: "⏸",
  busy: "⏳",
  stopping: "⏹",
  stopped: "✓",
  error: "✗",
};

// ---------------------------------------------------------------------------
// JSONL trace parser
// ---------------------------------------------------------------------------

interface JContentBlock {
  type: string;
  text?: string;
  thinking?: string;
  name?: string;
  arguments?: Record<string, unknown>;
  id?: string;
}

interface ParsedToolCall {
  index: number;
  name: string;
  argsPreview: string;
  fullArgs: Record<string, unknown>;
  isError: boolean;
  outputPreview: string;
  fullOutput: string;
}

interface ParsedTurn {
  turnNumber: number;
  userMessage: string;
  toolCalls: ParsedToolCall[];
  assistantText: string;
  errorCount: number;
}

function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return text.slice(0, max) + "…";
}

function shortenPath(p: string): string {
  const home = process.env.HOME ?? "";
  if (p.startsWith(home)) return `~${p.slice(home.length)}`;
  const m = p.match(/workspace\/[^/]+\/(.+)/);
  return m?.[1] ?? p;
}

function formatToolArgs(name: string, args: Record<string, unknown>): string {
  switch (name) {
    case "bash": {
      const cmd = String(args.command ?? "");
      const line1 = cmd.split("\n")[0] ?? "";
      return line1.length > 80 ? line1.slice(0, 77) + "..." : line1;
    }
    case "read": {
      const p = shortenPath(String(args.path ?? args.file_path ?? ""));
      const parts = [p];
      if (args.offset) parts.push(`:${args.offset}`);
      if (args.limit) parts.push(`+${args.limit}`);
      return parts.join("");
    }
    case "write": {
      const p = shortenPath(String(args.path ?? args.file_path ?? ""));
      const lines = String(args.content ?? "").split("\n").length;
      return `${p} (${lines} lines)`;
    }
    case "edit":
      return shortenPath(String(args.path ?? args.file_path ?? ""));
    default: {
      const first = Object.values(args).find((v) => typeof v === "string");
      return first ? String(first).slice(0, 60) : JSON.stringify(args).slice(0, 60);
    }
  }
}

function parseJsonlTrace(path: string): ParsedTurn[] {
  let raw: string;
  try {
    raw = fs.readFileSync(path, "utf-8");
  } catch {
    return [];
  }

  const lines = raw.trim().split("\n");
  const entries: Array<{ type: string; message?: Record<string, unknown> }> = [];
  for (const line of lines) {
    try {
      entries.push(JSON.parse(line));
    } catch {
      /* skip malformed */
    }
  }

  const turns: ParsedTurn[] = [];
  let current: ParsedTurn | null = null;
  const pending = new Map<string, ParsedToolCall>();

  for (const entry of entries) {
    if (entry.type !== "message" || !entry.message) continue;
    const msg = entry.message as {
      role: string;
      content?: JContentBlock[];
      toolCallId?: string;
      toolName?: string;
      isError?: boolean;
    };
    const content = Array.isArray(msg.content) ? msg.content : [];

    if (msg.role === "user") {
      const text = content
        .filter((b) => b.type === "text" && b.text)
        .map((b) => b.text ?? "")
        .join("\n");
      current = {
        turnNumber: turns.length + 1,
        userMessage: text,
        toolCalls: [],
        assistantText: "",
        errorCount: 0,
      };
      turns.push(current);
      continue;
    }

    if (msg.role === "toolResult") {
      const resultText = content
        .filter((b) => b.type === "text" && b.text)
        .map((b) => b.text ?? "")
        .join("\n");
      const callId = msg.toolCallId ?? "";
      const tc = pending.get(callId);
      if (tc) {
        tc.isError = msg.isError ?? false;
        tc.outputPreview = truncate(resultText, 200);
        tc.fullOutput = resultText;
        if (tc.isError && current) current.errorCount++;
        pending.delete(callId);
      }
      continue;
    }

    if (msg.role === "assistant") {
      if (!current) {
        current = {
          turnNumber: 1,
          userMessage: "(session start)",
          toolCalls: [],
          assistantText: "",
          errorCount: 0,
        };
        turns.push(current);
      }

      for (const block of content) {
        if (block.type === "text" && block.text?.trim()) {
          current.assistantText = block.text;
        } else if (block.type === "toolCall" && block.name) {
          const idx = current.toolCalls.length + 1;
          const tc: ParsedToolCall = {
            index: idx,
            name: block.name,
            argsPreview: formatToolArgs(block.name, block.arguments ?? {}),
            fullArgs: block.arguments ?? {},
            isError: false,
            outputPreview: "",
            fullOutput: "",
          };
          current.toolCalls.push(tc);
          if (block.id) pending.set(block.id, tc);
        }
      }
    }
  }

  return turns;
}

// ---------------------------------------------------------------------------
// Trace renderers (three levels)
// ---------------------------------------------------------------------------

function renderOverview(turns: ParsedTurn[]): string {
  const totalTools = turns.reduce((s, t) => s + t.toolCalls.length, 0);
  const totalErrors = turns.reduce((s, t) => s + t.errorCount, 0);

  const filesChanged = new Set<string>();
  const toolCounts: Record<string, number> = {};
  for (const t of turns) {
    for (const tc of t.toolCalls) {
      toolCounts[tc.name] = (toolCounts[tc.name] ?? 0) + 1;
      if (tc.name === "write" || tc.name === "edit") {
        const path = tc.argsPreview.split(" ")[0] ?? "";
        if (path) filesChanged.add(path);
      }
    }
  }

  const out: string[] = [];
  out.push(
    `${turns.length} turns, ${totalTools} tool calls, ${totalErrors} errors, ${filesChanged.size} files changed`,
  );

  if (Object.keys(toolCounts).length > 0) {
    const breakdown = Object.entries(toolCounts)
      .sort((a, b) => b[1] - a[1])
      .map(([n, c]) => `${n}:${c}`)
      .join("  ");
    out.push(`Tools: ${breakdown}`);
  }
  out.push("");

  for (const t of turns) {
    const groups: Record<string, number> = {};
    for (const tc of t.toolCalls) {
      groups[tc.name] = (groups[tc.name] ?? 0) + 1;
    }
    const toolSummary =
      Object.keys(groups).length > 0
        ? Object.entries(groups)
            .map(([n, c]) => (c > 1 ? `${n}x${c}` : n))
            .join(", ")
        : "text only";

    const errMark =
      t.errorCount > 0 ? ` <- ${t.errorCount} error${t.errorCount > 1 ? "s" : ""}` : "";

    const prompt = t.userMessage.slice(0, 60).replace(/\n/g, " ");
    out.push(`  Turn ${t.turnNumber}: [${toolSummary}]${errMark}`);
    out.push(`    "${prompt}${t.userMessage.length > 60 ? "..." : ""}"`);
  }

  const last = turns[turns.length - 1];
  if (last?.assistantText) {
    out.push("");
    out.push(`Last response: "${truncate(last.assistantText.replace(/\n/g, " "), 200)}"`);
  }

  return out.join("\n");
}

function renderTurnDetail(turns: ParsedTurn[], n: number): string {
  const turn = turns.find((t) => t.turnNumber === n);
  if (!turn) return `Turn ${n} not found. ${turns.length} turns available (1-${turns.length}).`;

  const out: string[] = [];
  out.push(
    `Turn ${turn.turnNumber} (${turn.toolCalls.length} tool calls, ${turn.errorCount} errors)`,
  );
  out.push(`Prompt: "${truncate(turn.userMessage.replace(/\n/g, " "), 200)}"`);
  out.push("");

  for (const tc of turn.toolCalls) {
    const err = tc.isError ? " ERROR" : "";
    out.push(`  [${tc.index}] ${tc.name}: ${tc.argsPreview}${err}`);
    if (tc.isError && tc.outputPreview) {
      for (const el of tc.outputPreview.split("\n").slice(0, 3)) {
        out.push(`       ${el.slice(0, 120)}`);
      }
    }
  }

  if (turn.assistantText) {
    out.push("");
    out.push(`Response: "${truncate(turn.assistantText, 500)}"`);
  }

  return out.join("\n");
}

function renderToolDetail(turns: ParsedTurn[], n: number, toolIdx: number): string {
  const turn = turns.find((t) => t.turnNumber === n);
  if (!turn) return `Turn ${n} not found.`;

  const tc = turn.toolCalls.find((t) => t.index === toolIdx);
  if (!tc)
    return `Tool [${toolIdx}] not found in turn ${n}. ${turn.toolCalls.length} tools available (1-${turn.toolCalls.length}).`;

  const out: string[] = [];
  out.push(`Turn ${n}, Tool [${tc.index}]`);
  out.push(`Name: ${tc.name}`);
  out.push(`Error: ${tc.isError}`);
  out.push("");

  out.push("Arguments:");
  for (const [k, v] of Object.entries(tc.fullArgs)) {
    const val = typeof v === "string" ? v : JSON.stringify(v);
    if (val.length > 500) {
      out.push(`  ${k}: (${val.length} chars) ${val.slice(0, 200)}...`);
    } else {
      out.push(`  ${k}: ${val}`);
    }
  }

  out.push("");
  const outputLines = tc.fullOutput.split("\n");
  const MAX_LINES = 80;
  out.push(`Output (${tc.fullOutput.length} chars, ${outputLines.length} lines):`);
  if (outputLines.length > MAX_LINES) {
    out.push(`  ... (${outputLines.length - MAX_LINES} lines omitted)`);
  }
  for (const l of outputLines.slice(-MAX_LINES)) {
    out.push(`  ${l}`);
  }

  return out.join("\n");
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createSpawnAgentFactory(ctx: SpawnAgentContext): ExtensionFactory {
  return (pi) => {
    // Track spawned children in this session for quick lookup
    const spawnedIds: string[] = [];

    // ─── spawn_agent ───

    pi.registerTool<typeof spawnAgentParams, SpawnAgentDetails>({
      name: "spawn_agent",
      label: "Spawn Agent",
      description:
        "Create a new agent session in the current workspace. The child session runs " +
        "independently with its own context window. The user monitors spawned sessions " +
        "from their phone. Use for parallelizable tasks, delegation, or specialized work " +
        "that benefits from a fresh context.",
      promptSnippet:
        "spawn_agent(message, name?, model?, thinking?) — spawn an independent child agent session",
      promptGuidelines: [
        "Use spawn_agent for tasks that can run independently without blocking the current conversation.",
        "Give each spawned agent a clear, self-contained task description with all needed context.",
        "The child agent cannot see the parent's conversation history — include relevant context in the message.",
        "Use check_agents to poll child status, inspect_agent to drill into a child's execution trace.",
        "Git safety: multiple agents share the same working directory. For small, file-isolated tasks (different files, no overlapping edits), parallel spawning is safe. For larger refactors that touch many files, use git worktrees or run agents sequentially.",
        `Max spawn depth is ${MAX_SPAWN_DEPTH}. Avoid spawning agents from within spawned agents unless the task genuinely requires hierarchical decomposition.`,
      ],
      parameters: spawnAgentParams,

      async execute(
        _toolCallId: string,
        params: Static<typeof spawnAgentParams>,
        signal: AbortSignal | undefined,
        onUpdate,
      ) {
        const name = params.name || params.message.slice(0, 80);

        // Depth check: prevent unbounded recursive spawning
        const currentDepth = getSpawnDepth(ctx);
        if (currentDepth >= MAX_SPAWN_DEPTH) {
          return {
            content: [
              {
                type: "text" as const,
                text:
                  `Cannot spawn: max depth reached (${MAX_SPAWN_DEPTH}). ` +
                  `This session is at depth ${currentDepth} in the spawn tree. ` +
                  `Do the work directly instead of delegating further.`,
              },
            ],
            details: { agentId: "", name, status: "error" },
          };
        }

        onUpdate?.({
          content: [{ type: "text", text: `Creating session "${name}"...` }],
          details: {
            agentId: "",
            name,
            status: "creating",
            model: params.model,
          },
        });

        try {
          const session = await ctx.spawnChild({
            name,
            model: params.model,
            thinking: params.thinking,
            prompt: params.message,
          });

          spawnedIds.push(session.id);

          const text =
            `Spawned agent "${session.name ?? name}" (${session.id}).\n` +
            `Status: ${session.status}, Model: ${session.model ?? "inherited"}\n` +
            `The session is now running independently. Use check_agents to monitor progress.`;

          return {
            content: [{ type: "text", text }],
            details: {
              agentId: session.id,
              name: session.name ?? name,
              status: session.status,
              model: session.model,
            },
          };
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          return {
            content: [{ type: "text", text: `Failed to spawn agent: ${msg}` }],
            details: { agentId: "", name, status: "error" },
          };
        }
      },
    });

    // ─── check_agents ───

    pi.registerTool<typeof checkAgentsParams, CheckAgentsDetails>({
      name: "check_agents",
      label: "Check Agents",
      description:
        "Check the status of child agent sessions spawned from this session. " +
        "Returns each child's status, cost, message count, and duration.",
      promptSnippet: "check_agents() — poll status of spawned child sessions",
      parameters: checkAgentsParams,

      async execute() {
        const children = ctx.listChildren();
        const agents = children.map(sessionToSummary);

        if (agents.length === 0) {
          return {
            content: [{ type: "text", text: "No child sessions found." }],
            details: { agents: [] },
          };
        }

        const lines = agents.map((a) => {
          const icon = STATUS_ICONS[a.status] ?? "?";
          const duration = formatDuration(a.durationMs);
          const cost = formatCost(a.cost);
          const name = a.name ?? a.id.slice(0, 8);
          // Show grandchild count if this child has its own children
          const allSessions = ctx.listWorkspaceSessions();
          const grandchildren = allSessions.filter((s) => s.parentSessionId === a.id);
          const gcMark = grandchildren.length > 0 ? ` (+${grandchildren.length} children)` : "";
          return `${icon} ${name}  [${a.status.toUpperCase()}]  ${a.messageCount} msgs  ${cost}  ${duration}${gcMark}`;
        });

        const busyCount = agents.filter(
          (a) => a.status === "busy" || a.status === "starting",
        ).length;
        const doneCount = agents.filter(
          (a) => a.status === "stopped" || a.status === "ready",
        ).length;
        const errorCount = agents.filter((a) => a.status === "error").length;

        const summary = [
          `${agents.length} child session${agents.length !== 1 ? "s" : ""}`,
          busyCount > 0 ? `${busyCount} working` : null,
          doneCount > 0 ? `${doneCount} done` : null,
          errorCount > 0 ? `${errorCount} error` : null,
        ]
          .filter(Boolean)
          .join(", ");

        // Tree-wide cost aggregation
        const rootId = getRootSessionId(ctx);
        const allSessions = ctx.listWorkspaceSessions();
        const treeCost = computeTreeCost(rootId, allSessions);

        const treeLine =
          `Tree total: ${treeCost.totalSessions} sessions, ` +
          `${treeCost.totalMessages} msgs, ` +
          `${formatCost(treeCost.totalCost)}`;

        const text = `${summary}\n\n${lines.join("\n")}\n\n${treeLine}`;

        return {
          content: [{ type: "text", text }],
          details: { agents },
        };
      },
    });

    // ─── inspect_agent ───

    pi.registerTool<typeof inspectAgentParams, InspectAgentDetails>({
      name: "inspect_agent",
      label: "Inspect Agent",
      description:
        "Inspect a child agent's execution trace with progressive disclosure. " +
        "Three levels: (1) overview — all turns with tool counts and error markers, " +
        "(2) turn detail — tool list with condensed args and error previews, " +
        "(3) tool detail — full arguments and output. Works on active or stopped sessions.",
      promptSnippet:
        "inspect_agent(id) overview | inspect_agent(id, turn) drill into turn | inspect_agent(id, turn, tool) full output",
      promptGuidelines: [
        "Start with inspect_agent(id) to get the overview. Look for error markers to find problems.",
        "Drill into specific turns with inspect_agent(id, turn: N) only when you need details.",
        "Use inspect_agent(id, turn: N, tool: M) to see full tool output — only when investigating a specific issue.",
        "The trace is live — you can inspect active sessions to see progress so far.",
      ],
      parameters: inspectAgentParams,

      async execute(_toolCallId: string, params: Static<typeof inspectAgentParams>) {
        // Look up the session
        const session = ctx.getSession(params.id);
        if (!session) {
          return {
            content: [{ type: "text", text: `Session not found: ${params.id}` }],
            details: { sessionId: params.id, level: "overview" },
          };
        }

        // Verify it's a child of this session
        if (session.parentSessionId !== ctx.sessionId) {
          // Also allow inspecting any session in the workspace for flexibility
          const children = ctx.listChildren();
          const isChild = children.some((c) => c.id === params.id);
          if (!isChild) {
            return {
              content: [
                {
                  type: "text",
                  text: `Session ${params.id} is not a child of this session. Use check_agents() to list children.`,
                },
              ],
              details: { sessionId: params.id, level: "overview" },
            };
          }
        }

        // Get the JSONL trace path
        const tracePath = session.piSessionFile;
        if (!tracePath) {
          return {
            content: [
              {
                type: "text",
                text: `No trace file available for session ${params.id}. The session may still be starting.`,
              },
            ],
            details: { sessionId: params.id, level: "overview" },
          };
        }

        // Parse the trace
        const turns = parseJsonlTrace(tracePath);
        if (turns.length === 0) {
          return {
            content: [
              {
                type: "text",
                text: `Trace is empty for session ${params.id}. The session may still be starting.`,
              },
            ],
            details: { sessionId: params.id, level: "overview" },
          };
        }

        // Render at the appropriate level
        let text: string;
        let level: "overview" | "turn" | "tool";

        if (params.turn !== undefined && params.tool !== undefined) {
          text = renderToolDetail(turns, params.turn, params.tool);
          level = "tool";
        } else if (params.turn !== undefined) {
          text = renderTurnDetail(turns, params.turn);
          level = "turn";
        } else {
          text = renderOverview(turns);
          level = "overview";
        }

        const totalTools = turns.reduce((s, t) => s + t.toolCalls.length, 0);
        const totalErrors = turns.reduce((s, t) => s + t.errorCount, 0);

        return {
          content: [{ type: "text", text }],
          details: {
            sessionId: params.id,
            level,
            turnCount: turns.length,
            toolCount: totalTools,
            errorCount: totalErrors,
          },
        };
      },
    });
  };
}

/**
 * subagents — first-party extension for managing child sessions.
 *
 * Root and detached sessions get:
 *   spawn_agent, stop_agent, send_message, inspect_agent
 *
 * Child sessions get the non-spawning subset:
 *   send_message, inspect_agent
 *
 * Injected as an in-process first-party factory extension.
 * Uses direct SessionManager methods — no HTTP round-trip needed.
 */

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import * as fs from "node:fs";
import { Type, type Static } from "typebox";
import type { ServerMessage, Session, SubagentConfig } from "../src/types.js";
import { defaultSubagentConfig } from "../src/storage/config-store.js";

// ---------------------------------------------------------------------------
// Context interface — thin abstraction over SessionManager
// ---------------------------------------------------------------------------

export interface SubagentsContext {
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
  /** Create an independent session in the same workspace — no parent-child relationship. */
  spawnDetached(params: {
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
  /** Subscribe to a child session's ServerMessage stream. Returns unsubscribe fn. */
  subscribe(sessionId: string, callback: (msg: ServerMessage) => void): () => void;
  /** Return available model IDs from the catalog (for spawn_agent model validation). */
  getAvailableModelIds(): string[];
  /** Stop a session by ID. Used by stop_agent to terminate child sessions. */
  stopSession(sessionId: string): Promise<void>;
  /** Resume a stopped session (restart its SDK process). */
  resumeSession(sessionId: string): Promise<Session>;
  /**
   * Send a message to a session. Semantics depend on session state:
   * - Idle session: sends as a prompt (starts a new turn).
   * - Busy session + behavior="steer": injected mid-turn, delivered after
   *   current tool calls finish, before the next LLM call.
   * - Busy session + behavior="followUp" (default): queued, delivered after
   *   the agent finishes its entire current turn.
   */
  sendMessage(sessionId: string, message: string, behavior?: "steer" | "followUp"): Promise<void>;
}

// ---------------------------------------------------------------------------
// Tree utilities
// ---------------------------------------------------------------------------

// MAX_SPAWN_DEPTH is now configurable via SubagentConfig.maxDepth.
// Kept as a fallback default if config is not provided.

/** Walk parentSessionId chain upward to compute depth. Root = 0. */
function getSpawnDepth(ctx: SubagentsContext): number {
  let depth = 0;
  let currentId: string | undefined = ctx.sessionId;
  const visited = new Set<string>();
  while (currentId) {
    if (visited.has(currentId)) break; // Circular reference detected
    visited.add(currentId);
    const session = ctx.getSession(currentId);
    if (!session?.parentSessionId) break;
    depth++;
    currentId = session.parentSessionId;
  }
  return depth;
}

/** Find the root session ID of the spawn tree. */
function getRootSessionId(ctx: SubagentsContext): string {
  let currentId = ctx.sessionId;
  const visited = new Set<string>();
  while (true) {
    if (visited.has(currentId)) return currentId; // Circular reference detected
    visited.add(currentId);
    const session = ctx.getSession(currentId);
    if (!session?.parentSessionId) return currentId;
    currentId = session.parentSessionId;
  }
}

/** Collect all descendant sessions of a given root (breadth-first). */
function getDescendants(rootId: string, allSessions: Session[]): Session[] {
  const descendants: Session[] = [];
  const visited = new Set<string>([rootId]);
  const queue = [rootId];
  while (queue.length > 0) {
    const parentId = queue.shift();
    if (!parentId) continue;
    for (const s of allSessions) {
      if (s.parentSessionId === parentId && !visited.has(s.id)) {
        visited.add(s.id);
        descendants.push(s);
        queue.push(s.id);
      }
    }
  }
  return descendants;
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
        "Model override for the child session (e.g. 'anthropic/claude-sonnet-4-6'). Inherits from parent if omitted.",
    }),
  ),
  thinking: Type.Optional(
    Type.String({
      description:
        "Thinking level override: off, minimal, low, medium, high, xhigh. Inherits from parent if omitted.",
    }),
  ),
  detached: Type.Optional(
    Type.Boolean({
      description:
        "If true, create an independent session (no parent-child link). " +
        "The session gets full capabilities including its own spawn_agent, " +
        "and is monitored via the app. Default: false (child session in the spawn tree).",
    }),
  ),
  wait: Type.Optional(
    Type.Boolean({
      description:
        "If true, block until the child session finishes and return its final result. " +
        "Default: false (fire-and-forget).",
    }),
  ),
  timeout_seconds: Type.Optional(
    Type.Number({
      description:
        "Maximum seconds to wait for the child to finish (only when wait=true). Default: 1800 (30 minutes).",
      minimum: 1,
    }),
  ),
});

const stopAgentParams = Type.Object({
  id: Type.String({
    description: "Session ID of the child agent to stop.",
  }),
});

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
  response: Type.Optional(
    Type.Boolean({
      description:
        "If true, return the full assistant response text (no truncation). " +
        "With turn: returns that turn's response. Without turn: returns the last turn's response.",
    }),
  ),
});

const sendMessageParams = Type.Object({
  id: Type.String({
    description: "Session ID of the target agent.",
  }),
  message: Type.String({
    description: "The message to send to the agent.",
  }),
  behavior: Type.Optional(
    Type.Union([Type.Literal("steer"), Type.Literal("followUp")], {
      description:
        "How to deliver the message when the target is busy. " +
        "'steer' (default): inject mid-turn — delivered after current tool calls " +
        "finish, before the next LLM call. Use for course corrections. " +
        "'followUp': queue until the agent finishes its entire current turn, " +
        "then deliver as the next message. Use for 'do this next'. " +
        "Ignored when the target is idle (always sends as a new prompt).",
    }),
  ),
});

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

interface SendMessageDetails {
  agentId: string;
  name?: string;
  status: string;
  deliveredAs: "prompt" | "steer" | "follow_up";
}

interface SpawnAgentDetails {
  agentId: string;
  name: string;
  status: string;
  model?: string;
  detached?: boolean;
  waited?: boolean;
  cost?: number;
  durationMs?: number;
}

interface StopAgentDetails {
  agentId: string;
  name?: string;
  status: string;
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
      const p = shortenPath(String(args.path ?? ""));
      const parts = [p];
      if (args.offset) parts.push(`:${args.offset}`);
      if (args.limit) parts.push(`+${args.limit}`);
      return parts.join("");
    }
    case "write": {
      const p = shortenPath(String(args.path ?? ""));
      const lines = String(args.content ?? "").split("\n").length;
      return `${p} (${lines} lines)`;
    }
    case "edit":
      return shortenPath(String(args.path ?? ""));
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
    out.push(`Response: "${truncate(turn.assistantText, 5000)}"`);
  }

  return out.join("\n");
}

function renderFullResponse(turns: ParsedTurn[], turnNumber?: number): string {
  if (turnNumber !== undefined) {
    const turn = turns.find((t) => t.turnNumber === turnNumber);
    if (!turn)
      return `Turn ${turnNumber} not found. ${turns.length} turns available (1-${turns.length}).`;
    if (!turn.assistantText) return `Turn ${turnNumber} has no assistant response text.`;
    return turn.assistantText;
  }
  // No turn specified: return last turn's response
  const last = turns[turns.length - 1];
  if (!last?.assistantText) return "No assistant response found in trace.";
  return last.assistantText;
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
// Child completion helpers
// ---------------------------------------------------------------------------

/** Terminal session statuses — the child is done. */
function isTerminal(status: string): boolean {
  return status === "stopped" || status === "error";
}

function isSessionBusy(session: Session | undefined): boolean {
  return session?.status === "busy" || session?.status === "starting";
}

interface WaitResult {
  status: string;
  lastMessage?: string;
  cost: number;
  changeStats?: Session["changeStats"];
  messageCount: number;
  durationMs: number;
  timedOut: boolean;
}

function appendChangeStatsLines(
  lines: string[],
  changeStats: Session["changeStats"] | undefined,
): void {
  if (!changeStats || changeStats.filesChanged <= 0) {
    return;
  }

  lines.push(
    `Changes: ${changeStats.filesChanged} file${changeStats.filesChanged !== 1 ? "s" : ""}, +${changeStats.addedLines}/-${changeStats.removedLines} lines`,
  );
  if (changeStats.changedFiles.length > 0) {
    for (const filePath of changeStats.changedFiles.slice(0, 10)) {
      lines.push(`  ${shortenPath(filePath)}`);
    }
    if (changeStats.changedFilesOverflow && changeStats.changedFilesOverflow > 0) {
      lines.push(`  ... and ${changeStats.changedFilesOverflow} more`);
    }
  }
}

function appendLastResponseLines(
  lines: string[],
  session: Session | undefined,
  fallbackLastMessage?: string,
): void {
  const tracePath = session?.piSessionFile;
  if (tracePath) {
    const turns = parseJsonlTrace(tracePath);
    const lastTurn = turns[turns.length - 1];
    if (lastTurn?.assistantText) {
      lines.push("");
      lines.push("Last response:");
      lines.push(lastTurn.assistantText);
      return;
    }
  }

  if (fallbackLastMessage) {
    lines.push("");
    lines.push("Last message:");
    lines.push(fallbackLastMessage);
  }
}

function buildChildCompletionText(
  ctx: SubagentsContext,
  childId: string,
  childName: string,
  durationMs: number,
  options?: {
    timedOut?: boolean;
    timeoutMs?: number;
    fallbackLastMessage?: string;
  },
): { text: string; status: string; cost: number; durationMs: number } {
  const session = ctx.getSession(childId);
  const lines: string[] = [];
  const status = session?.status ?? "unknown";
  const cost = session?.cost ?? 0;

  lines.push(`Agent "${childName}" (${childId}) finished: ${status.toUpperCase()}`);
  lines.push(
    `${session?.messageCount ?? 0} messages, ${formatCost(cost)}, ${formatDuration(durationMs)}`,
  );

  if (options?.timedOut) {
    lines.push(
      `WARNING: Timed out after ${formatDuration(options.timeoutMs ?? durationMs)}. The child may still be running.`,
    );
  }

  appendChangeStatsLines(lines, session?.changeStats);
  appendLastResponseLines(
    lines,
    session,
    options?.fallbackLastMessage ?? session?.lastMessage ?? undefined,
  );

  return {
    text: lines.join("\n"),
    status,
    cost,
    durationMs,
  };
}

/**
 * Block until child reaches terminal status. Streams lightweight progress
 * updates to the parent via onUpdate. Respects AbortSignal and timeout.
 */
function waitForChildCompletion(
  ctx: SubagentsContext,
  childId: string,
  timeoutMs: number,
  signal: AbortSignal | undefined,
  onUpdate?: (update: {
    content: Array<{ type: "text"; text: string }>;
    details: SpawnAgentDetails;
  }) => void,
  childName?: string,
): Promise<WaitResult> {
  return new Promise<WaitResult>((resolve) => {
    const startTime = Date.now();
    let lastStatus = "";
    let lastMsgCount = 0;
    let resolved = false;
    // Declared here so cleanup() can close over it before subscribe() assigns it.
    let unsubscribe: () => void = () => {};

    const cleanup = (): void => {
      resolved = true;
      clearTimeout(timeoutTimer);
      unsubscribe();
      signal?.removeEventListener("abort", onAbort);
    };

    const finalize = (timedOut: boolean): void => {
      if (resolved) return;
      const session = ctx.getSession(childId);
      cleanup();
      resolve({
        status: session?.status ?? "unknown",
        lastMessage: session?.lastMessage ?? undefined,
        cost: session?.cost ?? 0,
        changeStats: session?.changeStats,
        messageCount: session?.messageCount ?? 0,
        durationMs: Date.now() - startTime,
        timedOut,
      });
    };

    /** Emit progress update if status or message count changed. */
    const emitProgress = (session: Session): void => {
      const statusChanged = session.status !== lastStatus;
      const msgCountChanged = session.messageCount !== lastMsgCount;
      if (!statusChanged && !msgCountChanged) return;

      lastStatus = session.status;
      lastMsgCount = session.messageCount;

      const elapsed = formatDuration(Date.now() - startTime);
      const cost = formatCost(session.cost);
      const name = childName ?? childId.slice(0, 8);
      const progressText = `[${name}] ${session.status} — ${session.messageCount} msgs, ${cost}, ${elapsed}`;

      onUpdate?.({
        content: [{ type: "text", text: progressText }],
        details: {
          agentId: childId,
          name: childName ?? childId.slice(0, 8),
          status: session.status,
        },
      });
    };

    // Subscribe to child events BEFORE the fast-path terminal check to eliminate
    // the TOCTOU window where the child completes between check and subscribe.
    // Drives both terminal detection AND progress updates.
    unsubscribe = ctx.subscribe(childId, (msg: ServerMessage) => {
      if (resolved) return;
      if (msg.type === "session_ended") {
        finalize(false);
        return;
      }
      if (msg.type === "state") {
        if (isTerminal(msg.session.status)) {
          finalize(false);
        } else {
          emitProgress(msg.session);
        }
      }
    });

    // Check if already terminal (fast path) — after subscribe so any
    // transition that occurs concurrently is caught by the subscriber above.
    const initial = ctx.getSession(childId);
    if (initial && isTerminal(initial.status)) {
      unsubscribe();
      resolve({
        status: initial.status,
        lastMessage: initial.lastMessage ?? undefined,
        cost: initial.cost,
        changeStats: initial.changeStats,
        messageCount: initial.messageCount,
        durationMs: 0,
        timedOut: false,
      });
      return;
    }

    const onAbort = (): void => finalize(false);
    signal?.addEventListener("abort", onAbort, { once: true });

    const timeoutTimer = setTimeout(() => {
      if (!resolved) finalize(true);
    }, timeoutMs);
  });
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Workspace-scoped helpers
// ---------------------------------------------------------------------------

/** Check if a session is in the same workspace. */
function isInWorkspace(ctx: SubagentsContext, sessionId: string): boolean {
  return ctx.listWorkspaceSessions().some((s) => s.id === sessionId);
}

/** Build agent-origin preamble for inter-session messages. */
function buildAgentPreamble(ctx: SubagentsContext): string {
  const sender = ctx.getSession(ctx.sessionId);
  const name = sender?.name;
  return name ? `[From agent "${name}" (${ctx.sessionId})]` : `[From agent ${ctx.sessionId}]`;
}

// ---------------------------------------------------------------------------
// Factory options
// ---------------------------------------------------------------------------

export interface SubagentsFactoryOptions {
  /** If true, only register send_message + inspect_agent (no spawn/stop). */
  childMode?: boolean;
  /** Subagent lifecycle config. Falls back to defaults if not provided. */
  subagentConfig?: SubagentConfig;
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createSubagentsFactory(
  ctx: SubagentsContext,
  options?: SubagentsFactoryOptions,
): ExtensionFactory {
  return (pi) => {
    const childMode = options?.childMode ?? false;
    const subagentConfig = options?.subagentConfig ?? defaultSubagentConfig();
    const completionWatchers = new Map<string, () => void>();

    const clearCompletionWatcher = (childId: string): void => {
      const cleanup = completionWatchers.get(childId);
      if (cleanup) cleanup();
    };

    const armChildCompletionHook = (childId: string, childName: string): void => {
      clearCompletionWatcher(childId);

      let finished = false;
      let unsubscribe: () => void = () => {};

      const cleanup = (): void => {
        if (finished) return;
        finished = true;
        unsubscribe();
        completionWatchers.delete(childId);
      };

      const finalize = (): void => {
        if (finished) return;

        const result = buildChildCompletionText(
          ctx,
          childId,
          childName,
          Math.max(0, Date.now() - (ctx.getSession(childId)?.createdAt ?? Date.now())),
        );
        const parentSession = ctx.getSession(ctx.sessionId);

        cleanup();

        if (isSessionBusy(parentSession)) {
          pi.sendMessage(
            {
              customType: "subagent_result",
              content: result.text,
              display: true,
              details: {
                agentId: childId,
                name: childName,
                status: result.status,
                cost: result.cost,
                durationMs: result.durationMs,
              },
            },
            { deliverAs: "followUp", triggerTurn: true },
          );
          return;
        }

        pi.sendMessage({
          customType: "subagent_result",
          content: result.text,
          display: true,
          details: {
            agentId: childId,
            name: childName,
            status: result.status,
            cost: result.cost,
            durationMs: result.durationMs,
          },
        });
      };

      unsubscribe = ctx.subscribe(childId, (msg: ServerMessage) => {
        if (finished) return;
        if (msg.type === "session_ended") {
          finalize();
          return;
        }
        if (msg.type === "state" && isTerminal(msg.session.status)) {
          finalize();
        }
      });

      completionWatchers.set(childId, cleanup);

      const initial = ctx.getSession(childId);
      if (initial && isTerminal(initial.status)) {
        finalize();
      }
    };

    pi.on("session_shutdown", () => {
      for (const cleanup of completionWatchers.values()) {
        cleanup();
      }
      completionWatchers.clear();
    });

    // ─── spawn_agent (root/detached only) ───

    if (!childMode) {
      pi.registerTool<typeof spawnAgentParams, SpawnAgentDetails>({
        name: "spawn_agent",
        label: "Spawn Agent",
        description:
          "Create a new agent session in the current workspace. The child session runs " +
          "independently with its own context window. The user monitors spawned sessions " +
          "from their phone. Use for parallelizable tasks, delegation, or specialized work " +
          "that benefits from a fresh context. Set wait=true to block until the child " +
          "finishes and get its result inline.",
        promptSnippet:
          "spawn_agent(message, name?, model?, thinking?, detached?, wait?, timeout_seconds?) — spawn a child agent session",
        promptGuidelines: [
          "Spawning starts a fresh context — the child must rediscover files and context you already have. Don't spawn when you already know the exact changes and could do them faster inline.",
          "Use spawn_agent for tasks that can run independently without blocking the current conversation.",
          "Give each spawned agent a clear, self-contained task description with all needed context.",
          "The child agent cannot see the parent's conversation history — include relevant context in the message.",
          "Fire-and-forget children automatically send a subagent_result message when they finish. Use inspect_agent to drill into a child's execution trace when you need details.",
          "Set wait=true when you need the child's result before continuing (sequential dependency). Default is fire-and-forget.",
          "wait=true blocks your context window until the child finishes. Use fire-and-forget when the work can complete in the background.",
          "Git safety: multiple agents share the same working directory. For small, file-isolated tasks (different files, no overlapping edits), parallel spawning is safe. For larger refactors that touch many files, use git worktrees or run agents sequentially.",
          "Child sessions cannot spawn their own agents. Use detached=true to create a fully independent session with its own spawn capability.",
          "Model selection: omit model to inherit from parent (usually best). Only specify a model when the user explicitly requests one.",
          "Thinking selection: omit to inherit from parent (usually best). Only override when the user explicitly requests a specific thinking level.",
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
          if (currentDepth >= subagentConfig.maxDepth) {
            return {
              content: [
                {
                  type: "text" as const,
                  text:
                    `Cannot spawn: max depth reached (${subagentConfig.maxDepth}). ` +
                    `This session is at depth ${currentDepth} in the spawn tree. ` +
                    `Do the work directly instead of delegating further.`,
                },
              ],
              details: { agentId: "", name, status: "error" },
            };
          }

          // Model validation: reject unknown model IDs early
          if (params.model) {
            const available = ctx.getAvailableModelIds();
            if (available.length > 0 && !available.includes(params.model)) {
              return {
                content: [
                  {
                    type: "text" as const,
                    text:
                      `Unknown model "${params.model}". Available models:\n` +
                      available
                        .sort()
                        .map((id) => `  - ${id}`)
                        .join("\n"),
                  },
                ],
                details: { agentId: "", name, status: "error" },
              };
            }
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
            if ("fork" in params || "entryId" in params) {
              return {
                content: [
                  {
                    type: "text" as const,
                    text:
                      "spawn_agent does not support fork. " +
                      "Start a fresh child and include the needed context in the message instead.",
                  },
                ],
                details: { agentId: "", name, status: "error" },
                isError: true,
              };
            }

            const spawnParams = {
              name,
              model: params.model,
              thinking: params.thinking,
              prompt: params.message,
            };
            const session = params.detached
              ? await ctx.spawnDetached(spawnParams)
              : await ctx.spawnChild(spawnParams);
            const isDetached = params.detached ?? false;

            // ─── Fire-and-forget (default) ───
            if (!params.wait) {
              if (!isDetached) {
                armChildCompletionHook(session.id, session.name ?? name);
              }

              const lines = [
                `Spawned ${isDetached ? "detached " : ""}agent "${session.name ?? name}" (${session.id}).`,
                `Status: ${session.status}, Model: ${session.model ?? "inherited"}`,
              ];
              if (isDetached) {
                lines.push(
                  "This is an independent session — not in the spawn tree. " +
                    "It has full capabilities and is monitored via the app.",
                );
              } else {
                lines.push(
                  "The session is now running independently. You'll get a subagent_result message when it finishes.",
                );
              }

              return {
                content: [{ type: "text", text: lines.join("\n") }],
                details: {
                  agentId: session.id,
                  name: session.name ?? name,
                  status: session.status,
                  model: session.model,
                  detached: isDetached,
                },
              };
            }

            // ─── Wait mode — block until child finishes ───
            onUpdate?.({
              content: [
                {
                  type: "text",
                  text: `Spawned agent "${session.name ?? name}" (${session.id}). Waiting for completion...`,
                },
              ],
              details: {
                agentId: session.id,
                name: session.name ?? name,
                status: "waiting",
                model: session.model,
              },
            });

            const timeoutMs = params.timeout_seconds
              ? params.timeout_seconds * 1000
              : subagentConfig.defaultWaitTimeoutMs;

            const result = await waitForChildCompletion(
              ctx,
              session.id,
              timeoutMs,
              signal,
              onUpdate,
              session.name ?? name,
            );

            const completion = buildChildCompletionText(
              ctx,
              session.id,
              session.name ?? name,
              result.durationMs,
              {
                timedOut: result.timedOut,
                timeoutMs,
                fallbackLastMessage: result.lastMessage,
              },
            );

            return {
              content: [{ type: "text", text: completion.text }],
              details: {
                agentId: session.id,
                name: session.name ?? name,
                status: result.status,
                model: session.model,
                waited: true,
                cost: result.cost,
                durationMs: completion.durationMs,
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
    } // end if (!childMode) — spawn_agent

    // ─── stop_agent (root/detached only) ───

    if (!childMode) {
      pi.registerTool<typeof stopAgentParams, StopAgentDetails>({
        name: "stop_agent",
        label: "Stop Agent",
        description:
          "Stop a running child agent session. The session will be gracefully terminated. " +
          "Use when a child agent is no longer needed, stuck, or going in the wrong direction.",
        promptSnippet: "stop_agent(id) — stop a running child agent session",
        promptGuidelines: [
          "Use stop_agent to terminate a child that is no longer needed or is going in the wrong direction.",
          "The stop is graceful — the child gets a chance to clean up before terminating.",
          "Use the session ID returned by spawn_agent (or from a prior subagent_result) to target the right child.",
        ],
        parameters: stopAgentParams,

        async execute(_toolCallId: string, params: Static<typeof stopAgentParams>) {
          // Look up the session
          const session = ctx.getSession(params.id);
          if (!session) {
            return {
              content: [{ type: "text" as const, text: `Session not found: ${params.id}` }],
              details: { agentId: params.id, status: "not_found" },
            };
          }

          // Verify the session is a child in this session's tree
          const rootId = getRootSessionId(ctx);
          const allSessions = ctx.listWorkspaceSessions();
          const descendants = getDescendants(rootId, allSessions);
          const isInTree =
            session.parentSessionId === ctx.sessionId ||
            descendants.some((d) => d.id === params.id);
          if (!isInTree) {
            return {
              content: [
                {
                  type: "text" as const,
                  text: `Session ${params.id} is not in this session's tree.`,
                },
              ],
              details: { agentId: params.id, name: session.name ?? undefined, status: "error" },
            };
          }

          // Check if already terminal
          if (isTerminal(session.status)) {
            return {
              content: [
                {
                  type: "text" as const,
                  text: `Agent "${session.name ?? params.id}" is already ${session.status}. No action needed.`,
                },
              ],
              details: {
                agentId: params.id,
                name: session.name ?? undefined,
                status: session.status,
              },
            };
          }

          try {
            await ctx.stopSession(params.id);
            const updated = ctx.getSession(params.id);
            const finalStatus = updated?.status ?? "stopped";
            return {
              content: [
                {
                  type: "text" as const,
                  text: `Stopped agent "${session.name ?? params.id}" (${params.id}). Status: ${finalStatus}`,
                },
              ],
              details: {
                agentId: params.id,
                name: session.name ?? undefined,
                status: finalStatus,
              },
            };
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            return {
              content: [{ type: "text" as const, text: `Failed to stop agent: ${msg}` }],
              details: { agentId: params.id, name: session.name ?? undefined, status: "error" },
            };
          }
        },
      });
    } // end if (!childMode) — stop_agent

    // ─── send_message ───

    pi.registerTool<typeof sendMessageParams, SendMessageDetails>({
      name: "send_message",
      label: "Send Message",
      description:
        "Send a message to a child agent session. " +
        "If the target is idle, the message starts a new turn (prompt). " +
        "If the target is busy, the message is delivered as a steer (mid-turn) " +
        "or follow-up (after turn), controlled by the behavior parameter. " +
        "If the target is stopped, it is automatically resumed before delivering the message.",
      promptSnippet:
        "send_message(id, message, behavior?) — send a message to a child agent session",
      promptGuidelines: [
        "Use send_message to course-correct a running child or give it additional instructions.",
        "behavior='steer' (default): injected after current tool calls finish, before the next LLM call. " +
          "Use for course corrections like 'stop doing X, focus on Y instead'.",
        "behavior='followUp': queued until the agent finishes its current turn. " +
          "Use for non-urgent additions like 'when you're done, also check Z'.",
        "If the target is idle (not busy), the message starts a new turn regardless of behavior.",
        "If the target is stopped, it is automatically resumed and the message is delivered as a new prompt.",
        "Use the session ID returned by spawn_agent (or from a prior subagent_result).",
      ],
      parameters: sendMessageParams,

      async execute(_toolCallId: string, params: Static<typeof sendMessageParams>) {
        // Look up the session
        const session = ctx.getSession(params.id);
        if (!session) {
          return {
            content: [{ type: "text" as const, text: `Session not found: ${params.id}` }],
            details: { agentId: params.id, status: "not_found", deliveredAs: "prompt" as const },
          };
        }

        // Verify the session is in the same workspace
        if (!isInWorkspace(ctx, params.id)) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Session ${params.id} is not in this workspace.`,
              },
            ],
            details: {
              agentId: params.id,
              name: session.name ?? undefined,
              status: "error",
              deliveredAs: "prompt" as const,
            },
          };
        }

        // Auto-resume stopped sessions, then deliver message as a new prompt.
        // Error sessions cannot be resumed — they indicate a fatal failure.
        if (session.status === "error") {
          return {
            content: [
              {
                type: "text" as const,
                text:
                  `Agent "${session.name ?? params.id}" is in error state. ` +
                  `Cannot send messages to an errored session. Spawn a new agent instead.`,
              },
            ],
            details: {
              agentId: params.id,
              name: session.name ?? undefined,
              status: session.status,
              deliveredAs: "prompt" as const,
            },
          };
        }

        // Auto-resume: restart the stopped session's SDK process, then send as prompt.
        let autoResumed = false;
        if (session.status === "stopped") {
          try {
            await ctx.resumeSession(params.id);
            autoResumed = true;
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : "Resume failed";
            return {
              content: [
                {
                  type: "text" as const,
                  text:
                    `Failed to resume agent "${session.name ?? params.id}": ${msg}. ` +
                    `Spawn a new agent instead.`,
                },
              ],
              details: {
                agentId: params.id,
                name: session.name ?? undefined,
                status: "error",
                deliveredAs: "prompt" as const,
              },
            };
          }
        }

        // Determine delivery mode based on session status
        const isBusy = !autoResumed && session.status === "busy";
        const behavior = params.behavior ?? "steer";
        const deliveredAs: "prompt" | "steer" | "follow_up" = autoResumed
          ? "prompt"
          : isBusy
            ? behavior === "followUp"
              ? "follow_up"
              : "steer"
            : "prompt";

        try {
          // Prepend agent-origin preamble so recipient knows the message source
          const preamble = buildAgentPreamble(ctx);
          const fullMessage = `${preamble}\n${params.message}`;
          await ctx.sendMessage(params.id, fullMessage, behavior);

          const modeLabel = autoResumed
            ? "as a new turn after auto-resuming the stopped session"
            : deliveredAs === "prompt"
              ? "as a new turn (prompt)"
              : deliveredAs === "steer"
                ? "as a steer (mid-turn, before next LLM call)"
                : "as a follow-up (queued after current turn)";

          return {
            content: [
              {
                type: "text" as const,
                text: `Message sent to "${session.name ?? params.id}" ${modeLabel}.`,
              },
            ],
            details: {
              agentId: params.id,
              name: session.name ?? undefined,
              status: autoResumed ? "resumed" : session.status,
              deliveredAs,
            },
          };
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          return {
            content: [
              {
                type: "text" as const,
                text: `Failed to send message to "${session.name ?? params.id}": ${msg}`,
              },
            ],
            details: {
              agentId: params.id,
              name: session.name ?? undefined,
              status: "error",
              deliveredAs,
            },
          };
        }
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
        "inspect_agent(id) overview | inspect_agent(id, turn) drill into turn | inspect_agent(id, turn, tool) full output | inspect_agent(id, response) full last response",
      promptGuidelines: [
        "Start with inspect_agent(id) to get the overview. Look for error markers to find problems.",
        "Drill into specific turns with inspect_agent(id, turn: N) only when you need details.",
        "Use inspect_agent(id, turn: N, tool: M) to see full tool output — only when investigating a specific issue.",
        "Use inspect_agent(id, response: true) to get the full last response text with no truncation. Add turn: N to get a specific turn's response.",
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

        // Verify the session is in the same workspace
        if (!isInWorkspace(ctx, params.id)) {
          return {
            content: [
              {
                type: "text",
                text: `Session ${params.id} is not in this workspace.`,
              },
            ],
            details: { sessionId: params.id, level: "overview" },
          };
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

        if (params.response) {
          text = renderFullResponse(turns, params.turn);
          level = params.turn !== undefined ? "turn" : "overview";
        } else if (params.turn !== undefined && params.tool !== undefined) {
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

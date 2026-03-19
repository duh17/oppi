/**
 * spawn_agent — first-party extension for spawning child sessions.
 *
 * Registers two LLM-callable tools:
 *   spawn_agent  — create a new session in the current workspace
 *   check_agents — poll child session status
 *
 * Injected as an in-process factory extension (like autoresearch).
 * Uses direct SessionManager methods — no HTTP round-trip needed.
 */

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
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
  /** List child sessions of the current session. */
  listChildren(): Session[];
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

// ---------------------------------------------------------------------------
// Helpers
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
        "Use check_agents to poll child status after spawning.",
      ],
      parameters: spawnAgentParams,

      async execute(
        _toolCallId: string,
        params: Static<typeof spawnAgentParams>,
        signal: AbortSignal | undefined,
        onUpdate,
      ) {
        const name = params.name || params.message.slice(0, 80);

        // Report creating status
        onUpdate?.({
          content: [{ type: "text", text: `Creating session "${name}"...` }],
          details: { agentId: "", name, status: "creating", model: params.model },
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
            content: [
              {
                type: "text",
                text: `Failed to spawn agent: ${msg}`,
              },
            ],
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
          return `${icon} ${name}  [${a.status.toUpperCase()}]  ${a.messageCount} msgs  ${cost}  ${duration}`;
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

        const text = `${summary}\n\n${lines.join("\n")}`;

        return {
          content: [{ type: "text", text }],
          details: { agents },
        };
      },
    });
  };
}

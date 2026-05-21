/**
 * subagents — Oppi built-in extension for managing child sessions.
 *
 * Root and detached sessions get:
 *   spawn_agent, stop_agent, send_message, inspect_agent
 *
 * Child sessions get the non-spawning subset:
 *   send_message, inspect_agent
 *
 * Injected as an in-process server-owned factory extension.
 * Uses direct SessionManager methods — no HTTP round-trip needed.
 */

import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import type { ServerMessage, SubagentConfig, SubagentModelProfileConfig } from "./model-types.js";
import {
  renderFullResponse,
  renderOverview,
  renderToolDetail,
  renderTurnDetail,
  parseJsonlTrace,
} from "./trace.js";
import { getDescendants, getRootSessionId, getSpawnDepth } from "./tree.js";
import {
  buildChildCompletionText,
  isSessionBusy,
  isTerminal,
  waitForChildCompletion,
} from "./wait.js";
import type {
  InspectAgentDetails,
  SendMessageDetails,
  SpawnAgentDetails,
  StopAgentDetails,
  SubagentsContext,
  SubagentsFactoryOptions,
} from "./types.js";

export type { SubagentsContext, SubagentsFactoryOptions } from "./types.js";

function defaultSubagentConfig(): SubagentConfig {
  return {
    maxDepth: 1,
    autoStopWhenDone: false,
    childIdleTimeoutMs: 5 * 60_000,
    startupGraceMs: 60_000,
    defaultWaitTimeoutMs: 30 * 60_000,
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
  profile: Type.Optional(
    Type.String({
      description:
        "Optional named subagent profile from config.extensions.subagents.modelPolicy.profiles. " +
        "Useful for standardized lanes like discovery, coding, review, or web research.",
    }),
  ),
  model: Type.Optional(
    Type.String({
      description:
        "Model override for the child session (for example 'openai-codex/gpt-5.4-mini'). Inherits from parent or profile/default policy if omitted.",
    }),
  ),
  thinking: Type.Optional(
    Type.String({
      description:
        "Thinking level override: off, minimal, low, medium, high, xhigh. Inherits from parent or profile/default policy if omitted.",
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

function normalizeProfileName(value: string): string {
  return value.trim().toLowerCase();
}

function listConfiguredProfileNames(subagentConfig: SubagentConfig): string[] {
  return Object.keys(subagentConfig.modelPolicy?.profiles ?? {}).sort();
}

function resolveProfile(
  subagentConfig: SubagentConfig,
  requestedProfile: string | undefined,
): { profileName?: string; profile?: SubagentModelProfileConfig } {
  if (!requestedProfile) return {};
  const profiles = subagentConfig.modelPolicy?.profiles ?? {};
  const requested = normalizeProfileName(requestedProfile);
  const entry = Object.entries(profiles).find(([name]) => normalizeProfileName(name) === requested);
  if (!entry) return {};
  return { profileName: entry[0], profile: entry[1] };
}

function validateApprovedModel(
  subagentConfig: SubagentConfig,
  model: string | undefined,
): string | undefined {
  if (!model) return undefined;
  const approved = subagentConfig.modelPolicy?.approvedModels;
  if (!approved || approved.length === 0) return undefined;
  return approved.includes(model)
    ? undefined
    : `Model "${model}" is not approved for subagents. Approved models:\n${approved
        .map((id) => `  - ${id}`)
        .join("\n")}`;
}

function buildProfilePrompt(
  message: string,
  profileName: string | undefined,
  profile: SubagentModelProfileConfig | undefined,
): string {
  if (!profileName || !profile) return message;
  const lines: string[] = [`[Subagent profile: ${profileName}]`];
  if (profile.description) {
    lines.push(profile.description);
  }
  if (profile.guidelines && profile.guidelines.length > 0) {
    lines.push("Guidelines:");
    for (const guideline of profile.guidelines) {
      lines.push(`- ${guideline}`);
    }
  }
  lines.push("", message);
  return lines.join("\n");
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
          "finishes, stop it immediately, and get its result inline.",
        promptSnippet:
          "spawn_agent(message, name?, model?, thinking?, detached?, wait?, timeout_seconds?) — spawn a child agent session",
        promptGuidelines: [
          "Spawning starts a fresh context — the child must rediscover files and context you already have. Don't spawn when you already know the exact changes and could do them faster inline.",
          "Use spawn_agent for tasks that can run independently without blocking the current conversation.",
          "Give each spawned agent a clear, self-contained task description with all needed context.",
          "The child agent cannot see the parent's conversation history — include relevant context in the message.",
          "Fire-and-forget children automatically send a subagent_result message when they finish. Use inspect_agent to drill into a child's execution trace when you need details.",
          "Before spawning a new child for follow-up work, prefer send_message to the existing subagent that already investigated the area. Reusing that session keeps its context and prompt cache hot.",
          "Set wait=true when you need the child's result before continuing (sequential dependency). Default is fire-and-forget.",
          "wait=true blocks your context window until the child finishes, then immediately stops that child before returning the result inline. Use fire-and-forget when the work can complete in the background.",
          "Git safety: multiple agents share the same working directory. For small, file-isolated tasks (different files, no overlapping edits), parallel spawning is safe. For larger refactors that touch many files, use git worktrees or run agents sequentially.",
          "Child sessions cannot spawn their own agents. Use detached=true to create a fully independent session with its own spawn capability.",
          "Prefer configured subagent profiles for repeatable lanes like discovery, coding, review, or web research.",
          "If your workspace has both openai-codex/* and plain openai/* variants, prefer the openai-codex ones for subagent work unless the user explicitly asks otherwise.",
          "Model selection: omit model to inherit from parent (usually best) unless your workspace policy sets a subagent default or profile.",
          "Thinking selection: omit thinking unless the task or configured profile needs a different level.",
        ],
        parameters: spawnAgentParams,

        async execute(
          _toolCallId: string,
          params: Static<typeof spawnAgentParams>,
          signal: AbortSignal | undefined,
          onUpdate,
        ) {
          const { profileName, profile } = resolveProfile(subagentConfig, params.profile);
          if (params.profile && !profile) {
            const configuredProfiles = listConfiguredProfileNames(subagentConfig);
            const suffix =
              configuredProfiles.length > 0
                ? ` Available profiles:\n${configuredProfiles.map((name) => `  - ${name}`).join("\n")}`
                : " No subagent profiles are configured for this workspace.";
            return {
              content: [
                {
                  type: "text" as const,
                  text: `Unknown subagent profile "${params.profile}".${suffix}`,
                },
              ],
              details: {
                agentId: "",
                name: params.name || params.message.slice(0, 80),
                status: "error",
              },
              isError: true,
            };
          }

          const effectiveModel =
            params.model ?? profile?.model ?? subagentConfig.modelPolicy?.defaultModel;
          const effectiveThinking =
            params.thinking ?? profile?.thinking ?? subagentConfig.modelPolicy?.defaultThinking;
          const spawnPrompt = buildProfilePrompt(params.message, profileName, profile);
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

          const policyError = validateApprovedModel(subagentConfig, effectiveModel);
          if (policyError) {
            return {
              content: [{ type: "text" as const, text: policyError }],
              details: { agentId: "", name, status: "error" },
              isError: true,
            };
          }

          // Model validation: reject unknown model IDs early
          if (effectiveModel) {
            const available = ctx.getAvailableModelIds();
            if (available.length > 0 && !available.includes(effectiveModel)) {
              return {
                content: [
                  {
                    type: "text" as const,
                    text:
                      `Unknown model "${effectiveModel}". Available models:\n` +
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
              model: effectiveModel,
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
              model: effectiveModel,
              thinking: effectiveThinking,
              prompt: spawnPrompt,
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
                `Status: ${session.status}, Model: ${session.model ?? effectiveModel ?? "inherited"}`,
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
                  model: session.model ?? effectiveModel,
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
                model: session.model ?? effectiveModel,
              },
            });

            const timeoutMs = params.timeout_seconds
              ? params.timeout_seconds * 1000
              : subagentConfig.defaultWaitTimeoutMs;

            const result = await waitForChildCompletion(
              ctx,
              session.id,
              session.tokens.output,
              session.messageCount,
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
                model: session.model ?? effectiveModel,
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
              content: [
                {
                  type: "text" as const,
                  text: `Session not found: ${params.id}`,
                },
              ],
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
              details: {
                agentId: params.id,
                name: session.name ?? undefined,
                status: "error",
              },
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
              details: {
                agentId: params.id,
                name: session.name ?? undefined,
                status: "error",
              },
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
        "Prefer send_message over spawn_agent when a prior child already investigated the same code or issue. Reusing that session preserves context and usually benefits from a warmer prompt cache.",
        "behavior='steer' (default): injected after current tool calls finish, before the next LLM call. " +
          "Use for course corrections like 'stop doing X, focus on Y instead'.",
        "behavior='followUp': queued until the agent finishes its current turn. " +
          "Use for non-urgent additions like 'when you're done, also check Z'.",
        "If the target is idle (not busy), the message starts a new turn regardless of behavior.",
        "If the target is stopped, it is automatically resumed and the message is delivered as a new prompt — this is usually the best follow-up path when that agent already did the earlier investigation.",
        "Use the session ID returned by spawn_agent (or from a prior subagent_result).",
      ],
      parameters: sendMessageParams,

      async execute(_toolCallId: string, params: Static<typeof sendMessageParams>) {
        // Look up the session
        const session = ctx.getSession(params.id);
        if (!session) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Session not found: ${params.id}`,
              },
            ],
            details: {
              agentId: params.id,
              status: "not_found",
              deliveredAs: "prompt" as const,
            },
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

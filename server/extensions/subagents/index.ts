/**
 * subagents — Oppi built-in extension for managing child sessions.
 *
 * Root and detached sessions get:
 *   spawn_agent, send_message, inspect_agent
 *
 * Child sessions get the non-spawning subset:
 *   send_message, inspect_agent
 *
 * Injected as an in-process server-owned factory extension.
 * Uses direct SessionManager methods — no HTTP round-trip needed.
 */

import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import type {
  ServerMessage,
  Session,
  SubagentConfig,
  SubagentModelProfileConfig,
} from "./model-types.js";

type ExtensionAPI = Parameters<ExtensionFactory>[0];
import {
  renderFullResponse,
  renderOverview,
  renderToolDetail,
  renderTurnDetail,
  parseJsonlTrace,
} from "./trace.js";
import { getSpawnDepth } from "./tree.js";
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
        "Optional named subagent profile. Built-ins: default, discovery, coding, review, research; " +
        "workspace profiles can override them.",
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

const SUBAGENT_TOOL_POLICY_CUSTOM_TYPE = "oppi.subagents.toolPolicy";

interface SubagentToolPolicyState {
  profileName?: string;
  activeTools: string[];
}

const BUILT_IN_SUBAGENT_PROFILES: Record<string, SubagentModelProfileConfig> = {
  default: {
    description: "Default subagent profile. Use when no specialized lane is needed.",
  },
  discovery: {
    description: "Fast codebase discovery lane for bounded questions and source inspection.",
    guidelines: [
      "Search and read before summarizing; do not edit files unless explicitly asked.",
      "Return concrete findings with file paths, uncertainty, and the next useful action.",
      "Stay scoped to the delegated question and avoid broad refactors.",
    ],
  },
  coding: {
    description: "Implementation lane for focused code changes in a clear ownership area.",
    guidelines: [
      "Edit only the files or modules assigned to you unless the task proves that nearby support code must change.",
      "Assume other agents may edit the same repository; do not revert unrelated work.",
      "Validate your changes with the narrowest reliable check and report changed files.",
    ],
  },
  review: {
    description: "Review lane for correctness, regression, and risk analysis.",
    guidelines: [
      "Review evidence from diffs, tests, and relevant source before concluding.",
      "Prioritize correctness, data loss, security, concurrency, and protocol drift.",
      "Return findings with severity, confidence, file paths, and concrete fixes.",
    ],
  },
  research: {
    description: "Research lane for documentation, web/source discovery, and synthesis.",
    guidelines: [
      "Prefer primary sources and cite named sources for external claims.",
      "Separate confirmed facts from uncertainty and avoid over-broad summaries.",
      "Return concise recommendations tied to the parent task.",
    ],
  },
};

function normalizeProfileName(value: string): string {
  return value.trim().toLowerCase();
}

function normalizeActiveTools(values: string[] | undefined): string[] | undefined {
  if (!values) return undefined;
  const names = values.map((name) => name.trim()).filter((name) => name.length > 0);
  return Array.from(new Set(names));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseToolPolicyState(value: unknown): SubagentToolPolicyState | undefined {
  if (!isRecord(value) || !Array.isArray(value.activeTools)) return undefined;
  const activeTools = normalizeActiveTools(
    value.activeTools.filter((toolName): toolName is string => typeof toolName === "string"),
  );
  if (!activeTools) return undefined;
  const profileName = typeof value.profileName === "string" ? value.profileName : undefined;
  return { profileName, activeTools };
}

function readPersistedToolPolicy(ctx: {
  sessionManager: { getBranch(): unknown[] };
}): SubagentToolPolicyState | undefined {
  const entries = ctx.sessionManager.getBranch();
  for (let index = entries.length - 1; index >= 0; index--) {
    const entry = entries[index];
    if (!isRecord(entry)) continue;
    if (entry.type !== "custom" || entry.customType !== SUBAGENT_TOOL_POLICY_CUSTOM_TYPE) {
      continue;
    }
    const policy = parseToolPolicyState(entry.data);
    if (policy) return policy;
  }
  return undefined;
}

function applyToolPolicy(pi: ExtensionAPI, policy: SubagentToolPolicyState): void {
  pi.setActiveTools(policy.activeTools);
}

function installToolPolicyEnforcer(
  pi: ExtensionAPI,
  getPolicy: () => SubagentToolPolicyState | undefined,
): void {
  pi.on("tool_call", (event) => {
    const policy = getPolicy();
    if (!policy) return;
    if (policy.activeTools.includes(event.toolName)) return;
    const profile = policy.profileName ? ` for profile "${policy.profileName}"` : "";
    return {
      block: true,
      reason: `Tool "${event.toolName}" is not active${profile}. Active tools: ${policy.activeTools.join(", ") || "(none)"}`,
    };
  });
}

export function createSubagentToolPolicyFactory(policy: SubagentToolPolicyState): ExtensionFactory {
  return (pi) => {
    let currentPolicy: SubagentToolPolicyState | undefined = policy;
    installToolPolicyEnforcer(pi, () => currentPolicy);

    pi.on("session_start", () => {
      currentPolicy = policy;
      applyToolPolicy(pi, policy);
      pi.appendEntry(SUBAGENT_TOOL_POLICY_CUSTOM_TYPE, policy);
    });
  };
}

function listAvailableProfileNames(subagentConfig: SubagentConfig): string[] {
  return Array.from(
    new Set([
      ...Object.keys(BUILT_IN_SUBAGENT_PROFILES),
      ...Object.keys(subagentConfig.modelPolicy?.profiles ?? {}),
    ]),
  ).sort();
}

function resolveProfile(
  subagentConfig: SubagentConfig,
  requestedProfile: string | undefined,
): { profileName?: string; profile?: SubagentModelProfileConfig } {
  if (!requestedProfile) return {};
  const requested = normalizeProfileName(requestedProfile);
  const configuredProfiles = subagentConfig.modelPolicy?.profiles ?? {};
  const configuredEntry = Object.entries(configuredProfiles).find(
    ([name]) => normalizeProfileName(name) === requested,
  );
  if (configuredEntry) return { profileName: configuredEntry[0], profile: configuredEntry[1] };

  const builtInEntry = Object.entries(BUILT_IN_SUBAGENT_PROFILES).find(
    ([name]) => normalizeProfileName(name) === requested,
  );
  if (!builtInEntry) return {};
  return { profileName: builtInEntry[0], profile: builtInEntry[1] };
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
    let currentToolPolicy: SubagentToolPolicyState | undefined;

    installToolPolicyEnforcer(pi, () => currentToolPolicy);
    pi.on("session_start", (_event, ctx) => {
      const policy = readPersistedToolPolicy(ctx);
      if (!policy) return;
      currentToolPolicy = policy;
      applyToolPolicy(pi, policy);
    });

    const clearCompletionWatcher = (childId: string): void => {
      const cleanup = completionWatchers.get(childId);
      if (cleanup) cleanup();
    };

    const armChildCompletionHook = (
      childId: string,
      childName: string,
      baselineOutputTokens: number,
      baselineMessageCount: number,
    ): void => {
      clearCompletionWatcher(childId);

      let finished = false;
      let lastAssistantMessage: string | undefined;
      let finalizeTimer: ReturnType<typeof setTimeout> | undefined;
      let unsubscribe: () => void = () => {};

      const hasCompletedTurn = (session: Session | undefined): boolean => {
        if (!session || session.status !== "ready") return false;
        return (
          session.tokens.output > baselineOutputTokens ||
          session.messageCount > baselineMessageCount ||
          Boolean(lastAssistantMessage) ||
          session.lastAgentReplyAt !== undefined
        );
      };

      const cleanup = (): void => {
        if (finished) return;
        finished = true;
        if (finalizeTimer) {
          clearTimeout(finalizeTimer);
          finalizeTimer = undefined;
        }
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
          lastAssistantMessage ? { fallbackLastMessage: lastAssistantMessage } : undefined,
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
          { triggerTurn: true },
        );
      };

      const finalizeIfReady = (): void => {
        finalizeTimer = undefined;
        if (finished) return;
        if (hasCompletedTurn(ctx.getSession(childId))) {
          finalize();
        }
      };

      const scheduleFinalizeIfReady = (): void => {
        if (finished || finalizeTimer) return;
        finalizeTimer = setTimeout(finalizeIfReady, 0);
      };

      unsubscribe = ctx.subscribe(childId, (msg: ServerMessage) => {
        if (finished) return;
        if (msg.type === "message_end" && msg.role === "assistant" && msg.content) {
          lastAssistantMessage = msg.content;
          return;
        }
        if (msg.type === "agent_end") {
          scheduleFinalizeIfReady();
          return;
        }
        if (msg.type === "session_ended") {
          finalize();
          return;
        }
        if (msg.type === "state") {
          if (isTerminal(msg.session.status)) {
            finalize();
            return;
          }
          if (hasCompletedTurn(msg.session)) {
            finalize();
          }
        }
      });

      completionWatchers.set(childId, cleanup);

      const initial = ctx.getSession(childId);
      if (initial && (isTerminal(initial.status) || hasCompletedTurn(initial))) {
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
          "independently with its own context window. Use fire-and-forget for independent " +
          "work: spawn_agent returns immediately, and the child automatically sends a " +
          "subagent_result with its final/last assistant message when its turn finishes. " +
          "Set wait=true only for a sequential dependency where the parent must block for " +
          "the inline result.",
        promptSnippet:
          "spawn_agent(message, name?, profile?, model?, thinking?, detached?, wait?, timeout_seconds?) — spawn a child agent session",
        promptGuidelines: [
          "Spawning starts a fresh context — the child must rediscover files and context you already have. Don't spawn when you already know the exact changes and could do them faster inline.",
          "Use fire-and-forget spawn_agent for tasks that can run independently without blocking the current conversation.",
          "Give each spawned agent a clear, self-contained task description with all needed context.",
          "The child agent cannot see the parent's conversation history — include relevant context in the message.",
          "Fire-and-forget children automatically send a subagent_result message when they finish. Do not poll, stop, or repeatedly inspect them just to retrieve results; use inspect_agent only when you need debugging details.",
          "For long-running child work, including tasks that may take an hour, let the child run and wait for the automatic subagent_result instead of checking status in a loop.",
          "Before spawning a new child for follow-up work, prefer send_message to the existing subagent that already investigated the area. Reusing that session keeps its context and prompt cache hot.",
          "Set wait=true when you need the child's result before continuing (sequential dependency). Default is fire-and-forget.",
          "wait=true blocks your context window until the child finishes and performs managed cleanup before returning the result inline. Use fire-and-forget when the work can complete in the background.",
          "Git safety: multiple agents share the same working directory. For small, file-isolated tasks (different files, no overlapping edits), parallel spawning is safe. For larger refactors that touch many files, use git worktrees or run agents sequentially.",
          "Child sessions cannot spawn their own agents. Use detached=true to create a fully independent session with its own spawn capability.",
          "Prefer profile for repeatable lanes like discovery, coding, review, or research. Built-ins are available, and workspace profiles can override them.",
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
            const availableProfiles = listAvailableProfileNames(subagentConfig);
            const suffix =
              availableProfiles.length > 0
                ? ` Available profiles:\n${availableProfiles.map((name) => `  - ${name}`).join("\n")}`
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
              activeTools: normalizeActiveTools(profile?.activeTools),
              profileName,
            };
            const session = params.detached
              ? await ctx.spawnDetached(spawnParams)
              : await ctx.spawnChild(spawnParams);
            const isDetached = params.detached ?? false;

            // ─── Fire-and-forget (default) ───
            if (!params.wait) {
              if (!isDetached) {
                armChildCompletionHook(
                  session.id,
                  session.name ?? name,
                  session.tokens.output,
                  session.messageCount,
                );
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

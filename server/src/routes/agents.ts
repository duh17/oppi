import type { IncomingMessage, ServerResponse } from "node:http";

import { AgentLaunchService, type AgentDefinition } from "../agent-launch-service.js";
import {
  agentSummary,
  validateAgentDefinition,
  type AgentDefinitionStore,
  type StoredAgentDefinition,
} from "../agent-definitions.js";
import { safeErrorMessage } from "../log-utils.js";
import type { ChatAttachmentRef, Session } from "../types.js";
import { normalizeSessionWorktreeId } from "../worktrees.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createAgentRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function agentStore(): AgentDefinitionStore {
    return ctx.storage.getAgentDefinitionStore();
  }

  async function handleAgentCollection(
    method: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<boolean> {
    if (method === "GET") {
      const includeArchived = url.searchParams.get("includeArchived") === "true";
      helpers.json(res, { agents: agentStore().listAgentSummaries({ includeArchived }) });
      return true;
    }

    if (method === "POST") {
      try {
        const body = await helpers.parseBody<unknown>(req);
        const agent = agentStore().createAgent(body);
        helpers.json(res, { agent: serializeAgent(agent) }, 201);
      } catch (error) {
        helpers.error(res, 400, safeErrorMessage(error));
      }
      return true;
    }

    return false;
  }

  async function handleAgentMember(
    reference: string,
    method: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<boolean> {
    if (method === "GET") {
      const agent = resolveAgent(reference, res);
      if (!agent) return true;
      helpers.json(res, { agent: serializeAgent(agent) });
      return true;
    }

    if (method === "PATCH") {
      try {
        const agent = resolveAgent(reference, res);
        if (!agent) return true;
        const body = await helpers.parseBody<unknown>(req);
        const updated = agentStore().updateAgent(agent.id, body);
        if (!updated) {
          helpers.error(res, 404, "Agent not found");
          return true;
        }
        helpers.json(res, { agent: serializeAgent(updated) });
      } catch (error) {
        helpers.error(res, 400, safeErrorMessage(error));
      }
      return true;
    }

    if (method === "DELETE") {
      const agent = resolveAgent(reference, res);
      if (!agent) return true;
      const archived = agentStore().archiveAgent(agent.id);
      if (!archived) {
        helpers.error(res, 404, "Agent not found");
        return true;
      }
      helpers.json(res, { agent: serializeAgent(archived) });
      return true;
    }

    return false;
  }

  async function handleAgentSession(
    reference: string,
    method: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<boolean> {
    if (method !== "POST") return false;
    const agent = resolveAgent(reference, res);
    if (!agent) return true;
    if (agent.status === "archived") {
      helpers.error(res, 404, "Agent not found");
      return true;
    }

    try {
      const body = await helpers.parseBody<CreateAgentSessionRequest>(req);
      const prompt = parsePromptText(body.prompt);
      if (!prompt) {
        helpers.error(res, 400, "prompt.text required");
        return true;
      }
      if (!body.target?.workspaceId?.trim()) {
        helpers.error(res, 400, "target.workspaceId required");
        return true;
      }

      const workspace = ctx.storage.getWorkspace(body.target.workspaceId.trim());
      if (!workspace) {
        helpers.error(res, 404, "Workspace not found");
        return true;
      }
      const worktreeSelection = normalizeSessionWorktreeId(workspace, body.target.worktreeId);
      if (worktreeSelection.error) {
        helpers.error(res, 400, worktreeSelection.error);
        return true;
      }

      const launchService = new AgentLaunchService({
        storage: ctx.storage,
        sessions: ctx.sessions,
        ensureSessionContextWindow: ctx.ensureSessionContextWindow,
      });
      let launchAgent: AgentDefinition;
      try {
        launchAgent = applyOverrides(agent.definition, body.overrides);
      } catch (error) {
        helpers.error(res, 400, safeErrorMessage(error));
        return true;
      }
      const result = await launchService.launch({
        agent: launchAgent,
        agentId: agent.id,
        agentVersion: agent.version,
        parentSessionId: body.parentSessionId,
        target: { workspace, worktreeId: worktreeSelection.worktreeId },
        prompt,
        attachments: body.prompt?.attachments,
        idempotencyKey: body.idempotencyKey,
        leaseOwner: body.launchLeaseOwner ?? "agent-api-launch",
        source: "agent",
        sessionName: body.sessionName,
        ephemeral: body.ephemeral,
      });

      if (result.kind === "launch_in_progress") {
        helpers.json(
          res,
          {
            receipt: {
              accepted: false,
              retryable: true,
              reason: "launch_in_progress",
              agentId: agent.id,
              agentVersion: agent.version,
              sessionId: result.session.id,
              idempotencyKey: body.idempotencyKey,
              retryAfterMs: result.retryAfterMs,
            },
          },
          409,
        );
        return true;
      }

      if (result.kind !== "existing") {
        ctx.appEvents?.emitSessionCreated(result.createdSession);
      }
      if (result.summarySession) {
        ctx.appEvents?.emitSessionSummary(result.summarySession);
      }

      helpers.json(
        res,
        {
          receipt: buildReceipt(
            agent,
            result.session,
            result.kind === "existing",
            result.promptDispatch,
          ),
          session: result.session,
        },
        result.kind === "existing" ? 200 : 201,
      );
    } catch (error) {
      helpers.error(res, 500, safeErrorMessage(error));
    }

    return true;
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/agents") {
      return handleAgentCollection(method, url, req, res);
    }

    const sessionMatch = path.match(/^\/agents\/([^/]+)\/sessions$/);
    if (sessionMatch?.[1]) {
      return handleAgentSession(decodeURIComponent(sessionMatch[1]), method, req, res);
    }

    const memberMatch = path.match(/^\/agents\/([^/]+)$/);
    if (memberMatch?.[1]) {
      return handleAgentMember(decodeURIComponent(memberMatch[1]), method, req, res);
    }

    return false;
  };

  function resolveAgent(reference: string, res: ServerResponse): StoredAgentDefinition | null {
    const agent = agentStore().resolveAgent(reference);
    if (!agent || agent.status === "archived") {
      helpers.error(res, 404, "Agent not found");
      return null;
    }
    return agent;
  }
}

interface CreateAgentSessionRequest {
  prompt?: {
    text?: string;
    attachments?: ChatAttachmentRef[];
  };
  target?: {
    workspaceId?: string;
    worktreeId?: string;
  };
  overrides?: {
    model?: string;
    thinkingLevel?: string;
    tools?: string[];
    excludeTools?: string[];
    noTools?: "all" | "builtin";
  };
  parentSessionId?: string;
  idempotencyKey?: string;
  ephemeral?: boolean;
  sessionName?: string;
  launchLeaseOwner?: string;
}

function serializeAgent(agent: StoredAgentDefinition): Record<string, unknown> {
  return {
    ...agentSummary(agent),
    definition: agent.definition,
  };
}

function parsePromptText(prompt: CreateAgentSessionRequest["prompt"]): string | undefined {
  const text = prompt?.text?.trim();
  return text ? text : undefined;
}

function applyOverrides(
  agent: AgentDefinition,
  overrides: CreateAgentSessionRequest["overrides"],
): AgentDefinition {
  if (overrides === undefined) return agent;
  if (!isRecord(overrides)) throw new Error("overrides must be an object");
  return validateAgentDefinition({
    ...agent,
    sessionDefaults: {
      ...(agent.sessionDefaults ?? {}),
      ...("model" in overrides ? { model: overrides.model } : {}),
      ...("thinkingLevel" in overrides ? { thinkingLevel: overrides.thinkingLevel } : {}),
      ...("tools" in overrides ? { tools: overrides.tools } : {}),
      ...("excludeTools" in overrides ? { excludeTools: overrides.excludeTools } : {}),
      ...("noTools" in overrides ? { noTools: overrides.noTools } : {}),
    },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function buildReceipt(
  agent: StoredAgentDefinition,
  session: Session,
  existing: boolean,
  promptDispatch: "delivered" | "not_sent",
): Record<string, unknown> {
  return {
    accepted: true,
    agentId: agent.id,
    agentVersion: agent.version,
    sessionId: session.id,
    ...(session.launch?.parentSessionId ? { parentSessionId: session.launch.parentSessionId } : {}),
    ...(session.launch?.idempotencyKey ? { idempotencyKey: session.launch.idempotencyKey } : {}),
    ...(existing ? { existing: true } : {}),
    promptDispatch,
    ...(session.launch?.promptError ? { promptError: session.launch.promptError } : {}),
  };
}

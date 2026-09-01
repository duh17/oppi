import type { IncomingMessage, ServerResponse } from "node:http";

import { actionableAgentConfigurationMessage } from "../agent-launch-errors.js";
import {
  AgentLaunchService,
  DelegationPolicyError,
  requiredModelLaunchFailureMessage,
  type AgentDefinition,
} from "../agent-launch-service.js";
import {
  AGENT_VERSION_CONFLICT_CODE,
  AgentVersionConflictError,
  agentSummary,
  validateAgentDefinition,
  type AgentDefinitionStore,
  type StoredAgentDefinition,
} from "../agent-definitions.js";
import { iconAssetId } from "../icon-choice.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { ChatAttachmentRef, Session } from "../types.js";
import { normalizeSessionWorktreeId } from "../worktrees.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const log = createLogger({ base: { component: "agent_routes" } });

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
    url: URL,
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
        const expectedVersion = parseExpectedAgentVersion(url);
        const agent = resolveAgent(reference, res);
        if (!agent) return true;
        const previousAssetId = iconAssetId(agent.definition.icon);
        const body = await helpers.parseBody<unknown>(req);
        const updated = agentStore().updateAgent(agent.id, body, Date.now(), expectedVersion);
        if (!updated) {
          helpers.error(res, 404, "Agent not found");
          return true;
        }
        if (previousAssetId) {
          ctx.storage.cleanupUnreferencedIconAssets(new Set([previousAssetId]));
        }
        helpers.json(res, { agent: serializeAgent(updated) });
      } catch (error) {
        if (error instanceof AgentVersionConflictError) {
          helpers.json(
            res,
            {
              error: error.message,
              code: AGENT_VERSION_CONFLICT_CODE,
              ...(error.expectedVersion !== undefined
                ? { expectedVersion: error.expectedVersion }
                : {}),
              currentVersion: error.currentVersion,
            },
            409,
          );
        } else {
          helpers.error(res, 400, safeErrorMessage(error));
        }
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
      const delegationFieldError = invalidDelegationFields(
        body.parentSessionId,
        body.allowNestedDelegation,
      );
      if (delegationFieldError) {
        helpers.error(res, 400, delegationFieldError);
        return true;
      }
      if (body.autoStop !== undefined && typeof body.autoStop !== "boolean") {
        helpers.error(res, 400, "autoStop must be a boolean");
        return true;
      }
      const parsedPrompt = parsePrompt(body.prompt);
      if (parsedPrompt.error) {
        helpers.error(res, 400, parsedPrompt.error);
        return true;
      }
      const prompt = parsedPrompt.text;
      if (!body.target?.workspaceId?.trim()) {
        helpers.error(res, 400, "target.workspaceId required");
        return true;
      }

      const workspace = ctx.storage.getWorkspace(body.target.workspaceId.trim());
      if (!workspace) {
        helpers.error(res, 404, "Workspace not found");
        return true;
      }
      const worktreeSelection = normalizeSessionWorktreeId(workspace, body.target.worktreeId, {
        dataDir: ctx.storage.getDataDir(),
      });
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
        allowNestedDelegation: body.allowNestedDelegation === true,
        autoStop: body.autoStop === true,
        target: { workspace, worktreeId: worktreeSelection.worktreeId },
        prompt,
        attachments: parsedPrompt.attachments,
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

      if (result.failure) {
        const message = actionableAgentConfigurationMessage(result.failure, {
          agentName: agent.name,
          workspaceName: workspace.name,
        });
        // Discarded empty shells never enter the session list; do not broadcast them.
        if (result.kind !== "existing" && !result.discarded) {
          ctx.appEvents?.emitSessionCreated(result.session);
        }
        log.warn("agent.launch.configuration_failed", {
          agentId: agent.id,
          agentVersion: agent.version,
          workspaceId: workspace.id,
          sessionId: result.session.id,
          failureCode: result.failure.code,
          existing: result.kind === "existing",
          discarded: result.discarded === true,
        });
        helpers.json(
          res,
          {
            error: message,
            code: result.failure.code,
            ...(result.discarded ? {} : { sessionId: result.session.id }),
            receipt: {
              accepted: false,
              retryable: false,
              reason: result.failure.code,
              agentId: agent.id,
              agentVersion: agent.version,
              ...(result.discarded ? {} : { sessionId: result.session.id }),
              ...(result.session.launch?.idempotencyKey
                ? { idempotencyKey: result.session.launch.idempotencyKey }
                : {}),
              promptDispatch: "not_sent",
              promptError: message,
            },
            recovery: {
              actions:
                result.failure.code === "agent_workspace_incompatible" ||
                result.failure.code === "agent_workspace_unavailable"
                  ? ["choose_workspace", "edit_agent"]
                  : ["edit_agent"],
              agentId: agent.id,
              workspaceId: workspace.id,
              ...result.failure.details,
            },
          },
          422,
        );
        return true;
      }

      const requiredModelFailure = requiredModelLaunchFailureMessage(result.session);
      if (requiredModelFailure) {
        if (result.kind !== "existing") {
          ctx.appEvents?.emitSessionCreated(result.session);
        }
        helpers.json(
          res,
          {
            error: requiredModelFailure,
            sessionId: result.session.id,
            receipt: {
              accepted: false,
              retryable: false,
              reason: "required_model_unavailable",
              agentId: agent.id,
              agentVersion: agent.version,
              sessionId: result.session.id,
              ...(result.session.launch?.parentSessionId
                ? { parentSessionId: result.session.launch.parentSessionId }
                : {}),
              ...(result.session.launch?.idempotencyKey
                ? { idempotencyKey: result.session.launch.idempotencyKey }
                : {}),
              promptDispatch: result.promptDispatch,
              promptError: requiredModelFailure,
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
      if (error instanceof DelegationPolicyError) {
        helpers.error(res, 409, error.message);
      } else {
        helpers.error(res, 500, safeErrorMessage(error));
      }
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
      return handleAgentMember(decodeURIComponent(memberMatch[1]), method, url, req, res);
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

function parseExpectedAgentVersion(url: URL): number | undefined {
  for (const key of url.searchParams.keys()) {
    if (key !== "expectedVersion") {
      throw new Error(`Unknown Agent update query parameter: ${key}`);
    }
  }
  const values = url.searchParams.getAll("expectedVersion");
  if (values.length === 0) return undefined;
  if (values.length !== 1) {
    throw new Error("expectedVersion must be specified exactly once");
  }
  const value = values[0] ?? "";
  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error("expectedVersion must be a positive integer");
  }
  const version = Number(value);
  if (!Number.isSafeInteger(version)) {
    throw new Error("expectedVersion must be a positive safe integer");
  }
  return version;
}

interface CreateAgentSessionRequest {
  prompt?: unknown;
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
  allowNestedDelegation?: boolean;
  autoStop?: boolean;
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

const ATTACHMENT_KINDS = new Set(["image", "text", "pdf", "audio", "video", "archive", "unknown"]);

function parsePrompt(prompt: unknown): {
  text?: string;
  attachments?: ChatAttachmentRef[];
  error?: string;
} {
  if (prompt === undefined) return {};
  if (!isRecord(prompt)) return { error: "prompt must be an object" };
  if (typeof prompt.text !== "string" || !prompt.text.trim()) {
    return { error: "prompt.text required" };
  }
  if (prompt.attachments !== undefined && !Array.isArray(prompt.attachments)) {
    return { error: "prompt.attachments must be an array" };
  }
  if ((prompt.attachments?.length ?? 0) > 100) {
    return { error: "prompt.attachments must contain at most 100 items" };
  }

  const attachments: ChatAttachmentRef[] = [];
  for (const [index, value] of (prompt.attachments ?? []).entries()) {
    const parsed = parsePromptAttachment(value, index);
    if (typeof parsed === "string") return { error: parsed };
    attachments.push(parsed);
  }
  return {
    text: prompt.text.trim(),
    ...(prompt.attachments !== undefined ? { attachments } : {}),
  };
}

function parsePromptAttachment(value: unknown, index: number): ChatAttachmentRef | string {
  const field = `prompt.attachments[${index}]`;
  if (!isRecord(value)) return `${field} must be an object`;
  if (value.type !== "attachment") return `${field}.type must be attachment`;
  if (value.source !== "upload" && value.source !== "workspace") {
    return `${field}.source must be upload or workspace`;
  }
  const id = boundedInputString(value.id, 512);
  if (!id) return `${field}.id must be a non-empty string of at most 512 characters`;
  const name = boundedInputString(value.name, 512);
  if (!name) return `${field}.name must be a non-empty string of at most 512 characters`;
  const mimeType = boundedInputString(value.mimeType, 256);
  if (!mimeType) {
    return `${field}.mimeType must be a non-empty string of at most 256 characters`;
  }
  if (!Number.isSafeInteger(value.sizeBytes) || (value.sizeBytes as number) < 0) {
    return `${field}.sizeBytes must be a non-negative safe integer`;
  }
  if (
    value.sha256 !== undefined &&
    (typeof value.sha256 !== "string" || !/^[a-f0-9]{64}$/i.test(value.sha256))
  ) {
    return `${field}.sha256 must be a 64-character hexadecimal string`;
  }
  if (
    value.kind !== undefined &&
    (typeof value.kind !== "string" || !ATTACHMENT_KINDS.has(value.kind))
  ) {
    return `${field}.kind is invalid`;
  }
  const workspacePath =
    value.workspacePath === undefined ? undefined : boundedInputString(value.workspacePath, 4096);
  if (value.workspacePath !== undefined && !workspacePath) {
    return `${field}.workspacePath must be a non-empty string of at most 4096 characters`;
  }
  if (value.source === "workspace" && !workspacePath) {
    return `${field}.workspacePath is required for workspace attachments`;
  }

  return {
    type: "attachment",
    id,
    source: value.source,
    name,
    mimeType,
    sizeBytes: value.sizeBytes as number,
    ...(typeof value.sha256 === "string" ? { sha256: value.sha256 } : {}),
    ...(value.kind !== undefined ? { kind: value.kind as ChatAttachmentRef["kind"] } : {}),
    ...(workspacePath ? { workspacePath } : {}),
  };
}

function boundedInputString(value: unknown, maximumLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed && trimmed.length <= maximumLength ? trimmed : undefined;
}

function invalidDelegationFields(
  parentSessionId: unknown,
  allowNestedDelegation: unknown,
): string | undefined {
  if (
    parentSessionId !== undefined &&
    (typeof parentSessionId !== "string" || !parentSessionId.trim())
  ) {
    return "parentSessionId must be a non-empty string";
  }
  if (allowNestedDelegation !== undefined && typeof allowNestedDelegation !== "boolean") {
    return "allowNestedDelegation must be a boolean";
  }
  return undefined;
}

function applyOverrides(
  agent: AgentDefinition,
  overrides: CreateAgentSessionRequest["overrides"],
): AgentDefinition {
  if (overrides === undefined) return agent;
  if (!isRecord(overrides)) throw new Error("overrides must be an object");
  const merged = {
    ...agent,
    sessionDefaults: {
      ...(agent.sessionDefaults ?? {}),
      ...("model" in overrides ? { model: overrides.model } : {}),
      ...("thinkingLevel" in overrides ? { thinkingLevel: overrides.thinkingLevel } : {}),
      ...("tools" in overrides ? { tools: overrides.tools } : {}),
      ...("excludeTools" in overrides ? { excludeTools: overrides.excludeTools } : {}),
      ...("noTools" in overrides ? { noTools: overrides.noTools } : {}),
    },
  };
  return validateAgentDefinition(merged);
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

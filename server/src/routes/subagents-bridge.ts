import type { IncomingMessage, ServerResponse } from "node:http";

import {
  parseJsonlTrace,
  renderFullResponse,
  renderOverview,
  renderToolDetail,
  renderTurnDetail,
} from "../../extensions/subagents/trace.js";
import { getSpawnDepth } from "../../extensions/subagents/tree.js";
import { safeErrorMessage } from "../log-utils.js";
import type { Session } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

interface BridgeBodyBase {
  originSessionId?: string;
}

interface ResolveBody {
  piSessionId?: string;
  piSessionFile?: string;
  cwd?: string;
}

interface SpawnBody extends BridgeBodyBase {
  name?: string;
  prompt?: string;
  model?: string;
  thinking?: string;
  detached?: boolean;
}

interface SendBody extends BridgeBodyBase {
  targetSessionId?: string;
  message?: string;
  behavior?: "steer" | "followUp";
}

interface InspectBody extends BridgeBodyBase {
  targetSessionId?: string;
  turn?: number;
  tool?: number;
  response?: boolean;
}

interface StopBody extends BridgeBodyBase {
  targetSessionId?: string;
}

function publicSession(session: Session): Record<string, unknown> {
  return {
    id: session.id,
    name: session.name,
    status: session.status,
    workspaceId: session.workspaceId,
    parentSessionId: session.parentSessionId,
    createdAt: session.createdAt,
    lastActivity: session.lastActivity,
    messageCount: session.messageCount,
    tokens: session.tokens,
    cost: session.cost,
    model: session.model,
    firstMessage: session.firstMessage,
    lastMessage: session.lastMessage,
    lastAgentReplyAt: session.lastAgentReplyAt,
  };
}

function sameWorkspace(origin: Session, target: Session): boolean {
  return Boolean(
    origin.workspaceId && target.workspaceId && origin.workspaceId === target.workspaceId,
  );
}

function requireOriginSession(
  ctx: RouteContext,
  helpers: RouteHelpers,
  res: ServerResponse,
  originSessionId: string | undefined,
): Session | undefined {
  if (!originSessionId) {
    helpers.error(res, 400, "originSessionId required");
    return undefined;
  }
  const origin = ctx.storage.getSession(originSessionId);
  if (!origin) {
    helpers.error(res, 404, "Origin session not found");
    return undefined;
  }
  if (!origin.workspaceId) {
    helpers.error(res, 409, "Origin session is not attached to a workspace");
    return undefined;
  }
  return origin;
}

function tracePathForSession(session: Session): string | undefined {
  if (session.piSessionFile) return session.piSessionFile;
  if (session.piSessionFiles?.length)
    return session.piSessionFiles[session.piSessionFiles.length - 1];
  return undefined;
}

function inspectSession(
  session: Session,
  body: InspectBody,
): { text: string; details: Record<string, unknown> } {
  const tracePath = tracePathForSession(session);
  if (!tracePath) {
    return { text: "No trace file recorded for this session.", details: { level: "overview" } };
  }

  const turns = parseJsonlTrace(tracePath);
  const toolCount = turns.reduce((sum, turn) => sum + turn.toolCalls.length, 0);
  const errorCount = turns.reduce((sum, turn) => sum + turn.errorCount, 0);

  if (body.tool !== undefined) {
    return {
      text: renderToolDetail(turns, body.turn ?? 1, body.tool),
      details: { level: "tool", turnCount: turns.length, toolCount, errorCount },
    };
  }
  if (body.turn !== undefined) {
    const wantsResponse = body.response === true;
    return {
      text: wantsResponse
        ? renderFullResponse(turns, body.turn)
        : renderTurnDetail(turns, body.turn),
      details: {
        level: wantsResponse ? "response" : "turn",
        turnCount: turns.length,
        toolCount,
        errorCount,
      },
    };
  }
  if (body.response !== false) {
    return {
      text: renderFullResponse(turns),
      details: { level: "response", turnCount: turns.length, toolCount, errorCount },
    };
  }
  return {
    text: renderOverview(turns),
    details: { level: "overview", turnCount: turns.length, toolCount, errorCount },
  };
}

export function createSubagentsBridgeRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  async function handleResolve(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<ResolveBody>(req);
    const piSessionId = body.piSessionId?.trim();
    const piSessionFile = body.piSessionFile?.trim();
    const sessions = ctx.storage.listSessions();
    const session = sessions.find((candidate) => {
      if (piSessionId && candidate.piSessionId === piSessionId) return true;
      if (piSessionFile && candidate.piSessionFile === piSessionFile) return true;
      return false;
    });

    if (!session || !session.workspaceId) {
      helpers.error(res, 404, "No Oppi session is linked to this Pi session");
      return;
    }

    const subagentConfig = ctx.storage.getConfig().extensions?.subagents;
    helpers.json(res, {
      descriptor: {
        version: 1,
        originSessionId: session.id,
        workspaceId: session.workspaceId,
        runtime: session.runtime === "pi-tui" ? "pi-tui" : "sdk",
        canSpawn: !session.parentSessionId,
        defaultWaitTimeoutMs: subagentConfig?.defaultWaitTimeoutMs,
      },
    });
  }

  async function handleSpawn(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<SpawnBody>(req);
    const origin = requireOriginSession(ctx, helpers, res, body.originSessionId);
    if (!origin) return;
    if (!body.prompt || typeof body.prompt !== "string") {
      helpers.error(res, 400, "prompt required");
      return;
    }

    const subagentConfig = ctx.storage.getConfig().extensions?.subagents;
    const maxDepth = subagentConfig?.maxDepth ?? 1;
    const currentDepth = getSpawnDepth({
      getSession: (id) => ctx.storage.getSession(id),
      sessionId: origin.id,
    });
    if (currentDepth >= maxDepth) {
      helpers.error(res, 409, `Cannot spawn: max depth reached (${maxDepth})`);
      return;
    }

    try {
      const session = body.detached
        ? await ctx.sessions.spawnDetachedSession(origin.id, {
            name: body.name,
            model: body.model,
            thinking: body.thinking,
            prompt: body.prompt,
          })
        : await ctx.sessions.spawnChildSession(origin.id, {
            name: body.name,
            model: body.model,
            thinking: body.thinking,
            prompt: body.prompt,
          });
      helpers.json(res, { session: publicSession(session) }, 201);
    } catch (error) {
      helpers.error(res, 500, safeErrorMessage(error));
    }
  }

  async function handleSend(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<SendBody>(req);
    const origin = requireOriginSession(ctx, helpers, res, body.originSessionId);
    if (!origin) return;
    if (!body.targetSessionId || !body.message) {
      helpers.error(res, 400, "targetSessionId and message required");
      return;
    }
    const target = ctx.storage.getSession(body.targetSessionId);
    if (!target || !sameWorkspace(origin, target)) {
      helpers.error(res, 404, "Target session not found in this workspace");
      return;
    }

    try {
      if (target.status === "stopped" && target.runtime !== "pi-tui") {
        await ctx.sessions.startSession(target.id);
      }
      if (target.status === "busy") {
        if (body.behavior === "steer") {
          await ctx.sessionRuntimes.sendSteer(target.id, body.message, {});
        } else {
          await ctx.sessionRuntimes.sendFollowUp(target.id, body.message, {});
        }
      } else {
        await ctx.sessionRuntimes.sendPrompt(target.id, body.message, { timestamp: Date.now() });
      }
      helpers.json(res, { ok: true });
    } catch (error) {
      helpers.error(res, 500, safeErrorMessage(error));
    }
  }

  async function handleInspect(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<InspectBody>(req);
    const origin = requireOriginSession(ctx, helpers, res, body.originSessionId);
    if (!origin) return;
    if (!body.targetSessionId) {
      helpers.error(res, 400, "targetSessionId required");
      return;
    }
    const target = ctx.storage.getSession(body.targetSessionId);
    if (!target || !sameWorkspace(origin, target)) {
      helpers.error(res, 404, "Target session not found in this workspace");
      return;
    }

    const result = inspectSession(target, body);
    helpers.json(res, result);
  }

  async function handleStop(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<StopBody>(req);
    const origin = requireOriginSession(ctx, helpers, res, body.originSessionId);
    if (!origin) return;
    if (!body.targetSessionId) {
      helpers.error(res, 400, "targetSessionId required");
      return;
    }
    const target = ctx.storage.getSession(body.targetSessionId);
    if (!target || !sameWorkspace(origin, target)) {
      helpers.error(res, 404, "Target session not found in this workspace");
      return;
    }

    await ctx.sessionRuntimes.stopSessionIfActive(target.id);
    helpers.json(res, { ok: true });
  }

  function handleSessions(url: URL, res: ServerResponse): void {
    const originSessionId = url.searchParams.get("originSessionId") ?? undefined;
    const origin = requireOriginSession(ctx, helpers, res, originSessionId);
    if (!origin) return;
    const ids = new Set(
      (url.searchParams.get("ids") ?? "")
        .split(",")
        .map((id) => id.trim())
        .filter(Boolean),
    );
    const sessions = ctx.storage
      .listSessions()
      .filter((session) => sameWorkspace(origin, session))
      .filter((session) => session.parentSessionId === origin.id || ids.has(session.id))
      .sort((a, b) => b.lastActivity - a.lastActivity || a.id.localeCompare(b.id))
      .map(publicSession);
    helpers.json(res, { sessions });
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/subagents/bridge/resolve" && method === "POST") {
      await handleResolve(req, res);
      return true;
    }
    if (path === "/subagents/bridge/spawn" && method === "POST") {
      await handleSpawn(req, res);
      return true;
    }
    if (path === "/subagents/bridge/send" && method === "POST") {
      await handleSend(req, res);
      return true;
    }
    if (path === "/subagents/bridge/inspect" && method === "POST") {
      await handleInspect(req, res);
      return true;
    }
    if (path === "/subagents/bridge/stop" && method === "POST") {
      await handleStop(req, res);
      return true;
    }
    if (path === "/subagents/bridge/sessions" && method === "GET") {
      handleSessions(url, res);
      return true;
    }
    return false;
  };
}

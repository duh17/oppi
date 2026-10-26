import { mintSessionId } from "./id.js";
import type { Session, SessionLaunchMetadata } from "./types.js";

export function isDeclaredControlSession(
  session: Pick<Session, "workspaceId" | "control">,
): boolean {
  return session.workspaceId === undefined && session.control !== undefined;
}

/**
 * Launch idempotency key of the one control conversation per data directory. Reserved:
 * client create routes reject it (`reservedLaunchKeyError`), so only the find-or-create
 * service can hold a Session row under it.
 */
export const CONTROL_CONVERSATION_LAUNCH_KEY = "control-conversation";

/**
 * A durable Oppi Control session: a workspace-less server durable session marked by
 * `serverDurable.role`, either the standing control conversation (`oppi control`) or one that
 * `POST /control-sessions` creates per request. It is not a declared control session (no
 * `control` metadata; those are classic Pi Control rows created before control moved to the
 * durable engine). It uses the same `/control-sessions` routes and global recent list as
 * declared control sessions, never enters a workspace catalog or count, and is the only kind of
 * conversation the `oppi` CLI host serves.
 */
export function isControlConversation(session: Pick<Session, "serverDurable">): boolean {
  return session.serverDurable?.role === "control";
}

/**
 * A new durable Oppi Control row: workspace-less, its own durable store, launched by a human
 * for the server. `launch` carries only what differs between the standing conversation and a
 * per-request session (status, request time, idempotency key, lease, prompt dispatch).
 */
export function newControlSessionRow(params: {
  now: number;
  name: string;
  status: Session["status"];
  model?: string;
  thinking?: string;
  launch: Pick<SessionLaunchMetadata, "status" | "requestedAt"> & Partial<SessionLaunchMetadata>;
}): Session {
  const id = mintSessionId();
  return {
    id,
    name: params.name,
    status: params.status,
    createdAt: params.now,
    lastActivity: params.now,
    ...(params.model ? { model: params.model } : {}),
    ...(params.thinking ? { thinkingLevel: params.thinking } : {}),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    serverDurable: { storeId: id, role: "control" },
    launch: {
      source: "human",
      target: { server: true, displayCwd: "Oppi Control" },
      ...(params.model ? { model: params.model } : {}),
      ...(params.thinking ? { thinkingLevel: params.thinking } : {}),
      ...params.launch,
    },
  };
}

/**
 * Admitted by `/control-sessions` routes: a declared Pi Control session, or the durable
 * control conversation. Callers still require the same owner or paired-device auth.
 */
export function isControlRouteSession(
  session: Pick<Session, "workspaceId" | "control" | "serverDurable">,
): boolean {
  return isDeclaredControlSession(session) || isControlConversation(session);
}

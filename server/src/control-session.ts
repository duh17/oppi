import { mintSessionId } from "./id.js";
import type { Session, SessionLaunchMetadata } from "./types.js";

/**
 * An Oppi Control session: a workspace-less server durable session marked by
 * `serverDurable.role`, one that `POST /control-sessions` creates per request. The `/control-sessions`
 * routes admit only these. They list on the global recent list, never enter a workspace catalog
 * or count, and are the only kind of conversation the `oppi` CLI host serves.
 */
export function isControlConversation(session: Pick<Session, "serverDurable">): boolean {
  return session.serverDurable?.role === "control";
}

/**
 * A new durable Oppi Control row: workspace-less, its own durable store, launched by a human
 * for the server. `launch` carries what the request decides (status, request time, idempotency
 * key, lease, prompt dispatch).
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

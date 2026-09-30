import type { IncomingMessage } from "node:http";

import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { OPPI_CALLER_SESSION_HEADER } from "./session-caller-identity.js";
import { buildSessionSummary } from "./session-summary.js";
import type {
  Session,
  SessionInteraction,
  SessionInteractionKind,
  SessionPromptCacheStatus,
  SessionThreadCounterpart,
  SessionThreadResponse,
} from "./types.js";

const log = createLogger({ base: { component: "session_interactions" } });

interface InteractionStore {
  getSession(sessionId: string): Session | undefined;
  recordSessionInteraction(input: {
    at: number;
    fromSessionId: string;
    toSessionId: string;
    kind: SessionInteractionKind;
  }): void;
}

/**
 * Record one cross-session primitive when the request came from another Oppi
 * session's CLI. The header is self-asserted by the local owner CLI, so it is
 * display metadata only; callers never gain authority from it.
 */
export function recordCallerInteraction(
  store: InteractionStore,
  req: IncomingMessage,
  target: Session,
  kind: SessionInteractionKind,
  at = Date.now(),
): void {
  const raw = req.headers?.[OPPI_CALLER_SESSION_HEADER];
  const callerId = (Array.isArray(raw) ? raw[0] : raw)?.trim();
  if (!callerId || callerId === target.id || !store.getSession(callerId)) return;
  // The command already took effect. A failed audit write must not turn it
  // into an error the caller would retry.
  try {
    store.recordSessionInteraction({ at, fromSessionId: callerId, toSessionId: target.id, kind });
  } catch (error) {
    log.warn("session_interactions.record_failed", {
      kind,
      toSessionId: target.id,
      error: safeErrorMessage(error),
    });
  }
}

const SESSION_COMMAND_INTERACTIONS = new Map<string, SessionInteractionKind>([
  ["prompt", "prompt"],
  ["steer", "steer"],
  ["follow_up", "follow_up"],
  ["abort", "abort"],
]);

export function interactionKindForCommand(commandType: string): SessionInteractionKind | undefined {
  return SESSION_COMMAND_INTERACTIONS.get(commandType);
}

function rootOf(session: Session, byId: ReadonlyMap<string, Session>): Session {
  const visited = new Set<string>([session.id]);
  let current = session;
  for (;;) {
    const parentId = current.launch?.parentSessionId;
    const parent = parentId ? byId.get(parentId) : undefined;
    if (!parent || visited.has(parent.id)) return current;
    visited.add(parent.id);
    current = parent;
  }
}

/**
 * Build the launch tree containing `sessionId`, plus every recorded
 * interaction that touches it. A missing parent makes its child the root.
 */
export function buildSessionThread(
  sessions: readonly Session[],
  sessionId: string,
  listInteractions: (sessionIds: readonly string[]) => SessionInteraction[],
  promptCacheFor: (session: Session) => SessionPromptCacheStatus | undefined = () => undefined,
): SessionThreadResponse | undefined {
  const byId = new Map(sessions.map((session) => [session.id, session]));
  const target = byId.get(sessionId);
  if (!target) return undefined;

  const childrenByParent = new Map<string, Session[]>();
  for (const session of sessions) {
    const parentId = session.launch?.parentSessionId;
    if (!parentId || !byId.has(parentId)) continue;
    const siblings = childrenByParent.get(parentId);
    if (siblings) siblings.push(session);
    else childrenByParent.set(parentId, [session]);
  }

  const root = rootOf(target, byId);
  const members: Session[] = [];
  const memberIds = new Set<string>();
  const queue = [root];
  for (let index = 0; index < queue.length; index += 1) {
    const session = queue[index];
    if (memberIds.has(session.id)) continue;
    memberIds.add(session.id);
    members.push(session);
    queue.push(...(childrenByParent.get(session.id) ?? []));
  }
  members.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));

  const interactions = listInteractions([...memberIds]);
  const counterparts: SessionThreadCounterpart[] = [];
  const seen = new Set<string>();
  for (const interaction of interactions) {
    for (const id of [interaction.fromSessionId, interaction.toSessionId]) {
      if (memberIds.has(id) || seen.has(id)) continue;
      seen.add(id);
      const session = byId.get(id);
      if (!session) continue;
      const counterpartRoot = rootOf(session, byId);
      counterparts.push({
        id,
        ...(session.name ? { name: session.name } : {}),
        status: session.status,
        ...(session.workspaceId ? { workspaceId: session.workspaceId } : {}),
        ...(session.model ? { model: session.model } : {}),
        rootSessionId: counterpartRoot.id,
        ...(counterpartRoot.name ? { rootName: counterpartRoot.name } : {}),
      });
    }
  }

  const promptCache: Record<string, SessionPromptCacheStatus> = {};
  for (const member of members) {
    const status = promptCacheFor(member);
    if (status) promptCache[member.id] = status;
  }

  return {
    rootSessionId: root.id,
    sessions: members.map(buildSessionSummary),
    interactions,
    counterparts,
    ...(Object.keys(promptCache).length > 0 ? { promptCache } : {}),
  };
}

/** Pi's default retention tier; `PI_CACHE_RETENTION=long` opts every request into the long tier. */
export function promptCacheRetention(env: NodeJS.ProcessEnv = process.env): "short" | "long" {
  return env.PI_CACHE_RETENTION === "long" ? "long" : "short";
}

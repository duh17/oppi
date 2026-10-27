import { buildSessionSummary } from "./session-summary.js";
import type { Session, SessionPromptCacheStatus, SessionThreadResponse } from "./types.js";

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
 * Build the thread containing `sessionId`. The tree follows launch edges, where a
 * missing parent makes its child the root. A durable session also passes `owned`, the
 * sessions its Harness ownership edges put in the thread, which join whatever the launch
 * edges say.
 */
export function buildSessionThread(
  sessions: readonly Session[],
  sessionId: string,
  promptCacheFor: (session: Session) => SessionPromptCacheStatus | undefined = () => undefined,
  owned?: { rootSessionId: string; sessionIds: ReadonlySet<string> },
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

  const root = rootOf((owned && byId.get(owned.rootSessionId)) || target, byId);
  const members: Session[] = [];
  const memberIds = new Set<string>();
  // Owned members join even without a launch edge; launch children (a session the phone
  // started "in thread") still hang off whichever member launched them.
  const queue = [root, ...[...(owned?.sessionIds ?? [])].flatMap((id) => byId.get(id) ?? [])];
  for (let index = 0; index < queue.length; index += 1) {
    const session = queue[index];
    if (memberIds.has(session.id)) continue;
    memberIds.add(session.id);
    members.push(session);
    queue.push(...(childrenByParent.get(session.id) ?? []));
  }
  members.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));

  const promptCache: Record<string, SessionPromptCacheStatus> = {};
  for (const member of members) {
    const status = promptCacheFor(member);
    if (status) promptCache[member.id] = status;
  }

  return {
    rootSessionId: root.id,
    sessions: members.map(buildSessionSummary),
    ...(Object.keys(promptCache).length > 0 ? { promptCache } : {}),
  };
}

/** Pi's default retention tier; `PI_CACHE_RETENTION=long` opts every request into the long tier. */
export function promptCacheRetention(env: NodeJS.ProcessEnv = process.env): "short" | "long" {
  return env.PI_CACHE_RETENTION === "long" ? "long" : "short";
}

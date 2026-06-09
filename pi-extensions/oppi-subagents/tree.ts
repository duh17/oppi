interface SessionLike {
  id: string;
  parentSessionId?: string;
}

interface TreeContext {
  sessionId: string;
  getSession(sessionId: string): SessionLike | undefined;
}

export function getSpawnDepth(ctx: TreeContext): number {
  let depth = 0;
  let currentId: string | undefined = ctx.sessionId;
  const visited = new Set<string>();
  while (currentId) {
    if (visited.has(currentId)) break;
    visited.add(currentId);
    const session = ctx.getSession(currentId);
    if (!session?.parentSessionId) break;
    depth++;
    currentId = session.parentSessionId;
  }
  return depth;
}

export function getRootSessionId(ctx: TreeContext): string {
  let currentId = ctx.sessionId;
  const visited = new Set<string>();
  while (true) {
    if (visited.has(currentId)) return currentId;
    visited.add(currentId);
    const session = ctx.getSession(currentId);
    if (!session?.parentSessionId) return currentId;
    currentId = session.parentSessionId;
  }
}

export function getDescendants(rootId: string, allSessions: SessionLike[]): SessionLike[] {
  const descendants: SessionLike[] = [];
  const visited = new Set<string>([rootId]);
  const queue = [rootId];
  while (queue.length > 0) {
    const parentId = queue.shift();
    if (!parentId) continue;
    for (const session of allSessions) {
      if (session.parentSessionId === parentId && !visited.has(session.id)) {
        visited.add(session.id);
        descendants.push(session);
        queue.push(session.id);
      }
    }
  }
  return descendants;
}

import type { Session } from "./types.js";

export function isDeclaredControlSession(
  session: Pick<Session, "workspaceId" | "control">,
): boolean {
  return session.workspaceId === undefined && session.control !== undefined;
}

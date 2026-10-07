import type { Session } from "./types.js";

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
 * The durable control conversation: a workspace-less server durable session marked by
 * `serverDurable.role`. It is not a declared control session (no `control` metadata).
 * It uses the same `/control-sessions` routes and global recent list as declared control
 * sessions, and it never enters a workspace catalog or count.
 */
export function isControlConversation(session: Pick<Session, "serverDurable">): boolean {
  return session.serverDurable?.role === "control";
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

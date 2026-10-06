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
 * `serverDurable.role`. It is not a declared control session (no `control` metadata), so it
 * stays off `/control-sessions` and the phone session list.
 */
export function isControlConversation(session: Pick<Session, "serverDurable">): boolean {
  return session.serverDurable?.role === "control";
}

import { CONTROL_CONVERSATION_LAUNCH_KEY } from "./control-session.js";

/**
 * Launch idempotency key of a durable child's Session: one Session per child conversation.
 * Reserved: clients cannot create sessions under it. Kept out of the `durable-*` modules
 * because the create routes import it and a flag-off server loads no durable code.
 */
export const DURABLE_THREAD_KEY_PREFIX = "durable-thread:";

/** The 400 message for a client launch key in the reserved namespace, if it is one. */
export function reservedLaunchKeyError(...keys: unknown[]): string | undefined {
  for (const key of keys) {
    if (typeof key !== "string") continue;
    const trimmed = key.trim();
    if (trimmed.startsWith(DURABLE_THREAD_KEY_PREFIX))
      return `Idempotency keys starting with ${DURABLE_THREAD_KEY_PREFIX} are reserved`;
    if (trimmed === CONTROL_CONVERSATION_LAUNCH_KEY)
      return `Idempotency key ${CONTROL_CONVERSATION_LAUNCH_KEY} is reserved`;
  }
  return undefined;
}

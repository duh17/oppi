/**
 * Launch idempotency key of a durable child's Session: one Session per child conversation.
 * Reserved: clients cannot create sessions under it. Kept out of the `durable-*` modules
 * because the create routes import it and a flag-off server loads no durable code.
 */
export const DURABLE_THREAD_KEY_PREFIX = "durable-thread:";

/** The 400 message for a client launch key in the reserved namespace, if it is one. */
export function reservedLaunchKeyError(...keys: unknown[]): string | undefined {
  return keys.some(
    (key) => typeof key === "string" && key.trim().startsWith(DURABLE_THREAD_KEY_PREFIX),
  )
    ? `Idempotency keys starting with ${DURABLE_THREAD_KEY_PREFIX} are reserved`
    : undefined;
}

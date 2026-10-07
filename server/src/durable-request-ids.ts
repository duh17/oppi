/** Native reporters and Oppi admissions own these namespaces, never client turn IDs. */
export const DURABLE_QUEUE_REQUEST_ID_PREFIX = "oppi-queue:";
/** Display-only failure cards. One id per input or task, so a retry writes nothing. */
export const DURABLE_FAILURE_REQUEST_ID_PREFIX = "oppi-failure:";
export const DURABLE_RESERVED_REQUEST_ID_PREFIXES = [
  "background-job:",
  // Session tools: a child's first task, its report to the parent, and `session_send`.
  "oppi-spawn:",
  "oppi-report:",
  "oppi-send:",
  DURABLE_QUEUE_REQUEST_ID_PREFIX,
  DURABLE_FAILURE_REQUEST_ID_PREFIX,
] as const;

/** Native reporters and Oppi admissions own these namespaces, never client turn IDs. */
export const DURABLE_QUEUE_REQUEST_ID_PREFIX = "oppi-queue:";
export const DURABLE_RESERVED_REQUEST_ID_PREFIXES = [
  "background-job:",
  // Session tools: a child's first task, its report to the parent, and `session_send`.
  "oppi-spawn:",
  "oppi-report:",
  "oppi-send:",
  DURABLE_QUEUE_REQUEST_ID_PREFIX,
] as const;

/** Native reporters and Oppi admissions own these namespaces, never client turn IDs. */
export const DURABLE_QUEUE_REQUEST_ID_PREFIX = "oppi-queue:";
export const DURABLE_RESERVED_REQUEST_ID_PREFIXES = [
  "background-job:",
  "oppi-goal:",
  DURABLE_QUEUE_REQUEST_ID_PREFIX,
] as const;

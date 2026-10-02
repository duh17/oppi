/** Native reporters own these namespaces; client turn IDs must not occupy them. */
export const DURABLE_RESERVED_REQUEST_ID_PREFIXES = ["background-job:"] as const;

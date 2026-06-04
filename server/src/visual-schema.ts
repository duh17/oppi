/**
 * Validation + sanitization for structured tool result details.
 *
 * Oppi does not currently render legacy `details.ui[]` chart payloads. Keep the
 * sanitizer narrow: preserve regular tool detail fields, drop unsupported UI
 * payloads, and report warnings so callers can log the downgrade.
 */

interface ToolResultDetailsSanitization {
  details: unknown;
  warnings: string[];
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

/**
 * Sanitize tool result details before they are broadcast to clients.
 *
 * Non-UI fields are preserved as-is. Legacy `details.ui` chart payloads are no
 * longer a supported rendering surface, so they are removed instead of being
 * forwarded as an implied mobile contract.
 */
export function sanitizeToolResultDetails(details: unknown): ToolResultDetailsSanitization {
  const record = asRecord(details);
  if (!record || !("ui" in record)) {
    return { details, warnings: [] };
  }

  const next: Record<string, unknown> = {};
  for (const key in record) {
    if (key !== "ui") next[key] = record[key];
  }

  return {
    details: next,
    warnings: ["dropped unsupported details.ui payload"],
  };
}

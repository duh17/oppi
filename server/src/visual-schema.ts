/**
 * Validation + sanitization for structured tool result details.
 *
 * Oppi does not currently render legacy `details.ui[]` chart payloads. Keep the
 * sanitizer narrow: preserve regular tool detail fields, drop unsupported UI
 * payloads and private output paths, and report UI downgrade warnings.
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
 * Availability is projected separately before this boundary. Keep Pi's private
 * full-output path server-only, including path members inside truncation metadata.
 * Other detail fields (including requested file paths) remain inspectable.
 */
export function sanitizeToolResultDetails(details: unknown): ToolResultDetailsSanitization {
  const record = asRecord(details);
  if (!record) return { details, warnings: [] };
  const truncation = asRecord(record.truncation);
  // Pi's current truncation DTO has no paths. Also guard path-bearing additions
  // from extensions/future Pi versions without dropping counters or preview text.
  const privateTruncationKeys = truncation
    ? Object.keys(truncation).filter((key) => /paths?$/i.test(key))
    : [];
  const hasUI = "ui" in record;
  if (!hasUI && !("fullOutputPath" in record) && privateTruncationKeys.length === 0) {
    return { details, warnings: [] };
  }

  const next = { ...record };
  delete next.ui;
  delete next.fullOutputPath;
  if (truncation && privateTruncationKeys.length > 0) {
    const safeTruncation = { ...truncation };
    for (const key of privateTruncationKeys) delete safeTruncation[key];
    next.truncation = safeTruncation;
  }
  return {
    details: next,
    warnings: hasUI ? ["dropped unsupported details.ui payload"] : [],
  };
}

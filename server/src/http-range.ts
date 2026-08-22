import { createLogger } from "./logger.js";

const rangeLog = createLogger({ base: { component: "http_range" } });

export type ByteRangeParseResult =
  | { kind: "none" }
  | { kind: "valid"; start: number; end: number }
  | { kind: "invalid" }
  | { kind: "unsatisfiable" };

function parseRangeInteger(value: string): number | null {
  if (!/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) return null;
  return parsed;
}

export function parseByteRangeHeader(
  header: string | string[] | undefined,
  fileSize: number,
): ByteRangeParseResult {
  if (header === undefined) return { kind: "none" };
  if (Array.isArray(header)) return { kind: "invalid" };
  if (!Number.isSafeInteger(fileSize) || fileSize < 0) return { kind: "invalid" };

  const raw = header.trim();
  if (!raw) return { kind: "invalid" };
  if (!raw.toLowerCase().startsWith("bytes=")) return { kind: "none" };

  const spec = raw.slice("bytes=".length).trim();
  if (!spec || spec.includes(",")) return { kind: "invalid" };

  const match = spec.match(/^(\d*)-(\d*)$/);
  if (!match) return { kind: "invalid" };

  const [, startText, endText] = match;
  if (!startText && !endText) return { kind: "invalid" };
  if (fileSize === 0) return { kind: "unsatisfiable" };

  if (!startText) {
    const suffixLength = parseRangeInteger(endText);
    if (suffixLength === null) return { kind: "invalid" };
    if (suffixLength === 0) return { kind: "unsatisfiable" };

    const start = suffixLength >= fileSize ? 0 : fileSize - suffixLength;
    return { kind: "valid", start, end: fileSize - 1 };
  }

  const start = parseRangeInteger(startText);
  if (start === null) return { kind: "invalid" };
  if (start >= fileSize) return { kind: "unsatisfiable" };

  if (!endText) {
    return { kind: "valid", start, end: fileSize - 1 };
  }

  const requestedEnd = parseRangeInteger(endText);
  if (requestedEnd === null) return { kind: "invalid" };
  if (requestedEnd < start) return { kind: "unsatisfiable" };

  return { kind: "valid", start, end: Math.min(requestedEnd, fileSize - 1) };
}

export function logRejectedByteRange(
  route: string,
  header: string | string[] | undefined,
  kind: "invalid" | "unsatisfiable",
  fileSize: number,
): void {
  rangeLog.warn("media.range_rejected", {
    route,
    kind,
    fileSize,
    range: Array.isArray(header) ? header.join(",") : (header ?? ""),
  });
}

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

function isUtf8ContinuationByte(byte: number): boolean {
  return (byte & 0xc0) === 0x80;
}

function utf8SequenceLength(lead: number): number {
  if ((lead & 0x80) === 0) return 1;
  if ((lead & 0xe0) === 0xc0) return 2;
  if ((lead & 0xf0) === 0xe0) return 3;
  if ((lead & 0xf8) === 0xf0) return 4;
  return 1;
}

/**
 * Tool-output Range responses never split a UTF-8 codepoint.
 *
 * `start` advances to the next leading byte if it lands on a continuation.
 * `end` (inclusive) retracts to the last complete codepoint. HEAD reports the
 * unclamped file/range length and must not read the sidecar.
 */
export function clampUtf8CodepointRange(
  start: number,
  end: number,
  fileSize: number,
  byteAt: (offset: number) => number,
): { start: number; end: number } | { kind: "empty" } {
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    !Number.isSafeInteger(fileSize) ||
    fileSize <= 0 ||
    start < 0 ||
    end < start ||
    start >= fileSize
  ) {
    return { kind: "empty" };
  }

  let clampedStart = start;
  let clampedEnd = Math.min(end, fileSize - 1);
  while (clampedStart <= clampedEnd && isUtf8ContinuationByte(byteAt(clampedStart))) {
    clampedStart += 1;
  }
  if (clampedStart > clampedEnd) return { kind: "empty" };

  let lead = clampedEnd;
  while (lead > clampedStart && isUtf8ContinuationByte(byteAt(lead))) {
    lead -= 1;
  }
  if (isUtf8ContinuationByte(byteAt(lead))) {
    return { kind: "empty" };
  }
  const codepointEnd = lead + utf8SequenceLength(byteAt(lead)) - 1;
  if (codepointEnd > clampedEnd) {
    clampedEnd = lead - 1;
  }
  if (clampedEnd < clampedStart) return { kind: "empty" };
  return { start: clampedStart, end: clampedEnd };
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

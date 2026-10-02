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

/** The chunker and sidecar share this rule: invalid leads are single raw bytes. */
export function utf8SequenceLength(lead: number): number {
  return lead >= 0xf5 ? 1 : lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc2 ? 2 : 1;
}

function sequenceAcrossBoundary(
  boundary: number,
  fileSize: number,
  byteAt: (offset: number) => number,
): { start: number; end: number } | undefined {
  for (let back = 1; back <= 3 && back <= boundary; back += 1) {
    const lead = boundary - back;
    if (isUtf8ContinuationByte(byteAt(lead))) continue;
    const length = utf8SequenceLength(byteAt(lead));
    if (length <= back) return undefined;
    const end = Math.min(fileSize, lead + length);
    // Standalone continuation bytes and malformed sequences are raw bytes,
    // not scalars whose boundaries should be moved.
    for (let at = lead + 1; at < end; at += 1) {
      if (!isUtf8ContinuationByte(byteAt(at))) return undefined;
    }
    return { start: lead, end };
  }
  return undefined;
}

/**
 * Tool-output Range responses never split a UTF-8 codepoint.
 *
 * Move only boundaries inside a UTF-8 sequence. Invalid bytes stay in the
 * raw byte space, and EOF retains partial bytes emitted by the final drain.
 * HEAD reports the unclamped file/range length and must not read the sidecar.
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

  const clampedStart = sequenceAcrossBoundary(start, fileSize, byteAt)?.end ?? start;
  let clampedEnd = Math.min(end, fileSize - 1);
  if (clampedEnd + 1 < fileSize) {
    const sequence = sequenceAcrossBoundary(clampedEnd + 1, fileSize, byteAt);
    if (sequence) clampedEnd = sequence.start - 1;
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

import { closeSync, openSync, readSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { performance } from "node:perf_hooks";
import { OPPI_LIFECYCLE_CUSTOM_TYPE } from "./lifecycle-journal-extension.js";
import { buildSessionContext, type SessionEntry, type TraceEvent } from "./trace.js";

export interface TracePageOptions {
  cursor?: string;
  aroundEntryId?: string;
  targetEvents?: number;
  previewBytes?: number;
  maxInitialReadBytes?: number;
  attachmentDataDir?: string;
  attachmentSessionId?: string;
  /// Current in-memory tree leaf for the initial page. Omit for cursor and around-entry pages.
  leafId?: string | null;
}

export interface TracePageMetadata {
  hasOlder: boolean;
  olderCursor: string | null;
  traceVersion: string;
  previewBytes: number;
  staleCursor: boolean;
}

export interface TracePageMetrics {
  rawEntryCount: number;
  traceEventCount: number;
  selectedRawEntryCount: number;
  jsonlBytes: number;
  scannedBytes: number;
  readMs: number;
  parseMs: number;
  selectMs: number;
  formatMs: number;
  previewMs: number;
}

export interface TracePageResult {
  trace: TraceEvent[];
  page: TracePageMetadata;
  metrics: TracePageMetrics;
}

interface TraceSource {
  index: number;
  path: string;
  sourceId: string;
  size: number;
  mtimeMs: number;
}

interface ParsedLine {
  sourceIndex: number;
  sourceId: string;
  entry: SessionEntry;
  byteStart: number;
  byteEnd: number;
  hash: string;
}

interface TraceCursor {
  sourceId?: string;
  byteStart: number;
  entryId: string;
  lineHash: string;
  branchLeafId?: string | null;
}

interface ToolPreviewMetadata {
  outputPreviewBytes: number;
  outputTotalBytes: number;
}

interface ReadWindow {
  sourceIndex: number;
  sourceId: string;
  buffer: Buffer;
  baseByteOffset: number;
  scannedBytes: number;
}

const DEFAULT_TARGET_EVENTS = 450;
const DEFAULT_PREVIEW_BYTES = 4096;
const DEFAULT_INITIAL_READ_BYTES = 8 * 1024 * 1024;
const LINE_READ_CHUNK_BYTES = 64 * 1024;

export function readSessionTracePageFromFile(
  jsonlPath: string,
  options: TracePageOptions = {},
): TracePageResult {
  return readSessionTracePageFromFiles([jsonlPath], options);
}

export function readSessionTracePageFromFiles(
  jsonlPaths: string[],
  options: TracePageOptions = {},
): TracePageResult {
  const targetEvents = Math.max(1, options.targetEvents ?? DEFAULT_TARGET_EVENTS);
  const previewBytes = Math.max(0, options.previewBytes ?? DEFAULT_PREVIEW_BYTES);
  const maxInitialReadBytes = Math.max(
    1,
    options.maxInitialReadBytes ?? DEFAULT_INITIAL_READ_BYTES,
  );
  const sources = traceSources(jsonlPaths);
  const traceVersion = traceVersionFor(sources);
  const jsonlBytes = sources.reduce((sum, source) => sum + source.size, 0);
  const aroundEntryId = options.aroundEntryId?.trim();
  if (aroundEntryId) {
    return readAroundTracePage(sources, aroundEntryId, {
      traceVersion,
      jsonlBytes,
      targetEvents,
      previewBytes,
      maxInitialReadBytes,
      attachmentDataDir: options.attachmentDataDir,
      attachmentSessionId: options.attachmentSessionId,
    });
  }

  const cursor = options.cursor ? decodeCursor(options.cursor) : null;
  const requestedLeafId = options.cursor ? cursor?.branchLeafId : options.leafId;
  if (requestedLeafId === null) {
    return emptyPage({
      traceVersion,
      previewBytes,
      jsonlBytes,
      scannedBytes: 0,
      rawEntryCount: 0,
      readMs: 0,
      parseMs: 0,
      staleCursor: false,
    });
  }

  if (options.cursor && !cursor) {
    return emptyPage({
      traceVersion,
      previewBytes,
      jsonlBytes,
      scannedBytes: 0,
      rawEntryCount: 0,
      readMs: 0,
      parseMs: 0,
      staleCursor: true,
    });
  }

  const cursorSourceIndex = cursor ? resolveCursorSourceIndex(sources, cursor) : undefined;
  if (cursor && cursorSourceIndex === undefined) {
    return emptyPage({
      traceVersion,
      previewBytes,
      jsonlBytes,
      scannedBytes: 0,
      rawEntryCount: 0,
      readMs: 0,
      parseMs: 0,
      staleCursor: true,
    });
  }

  const readStart = performance.now();
  const cursorValidation = cursor
    ? validateCursor(sources[cursorSourceIndex as number], cursor)
    : true;
  let readMs = elapsed(readStart);
  if (!cursorValidation) {
    return emptyPage({
      traceVersion,
      previewBytes,
      jsonlBytes,
      scannedBytes: 0,
      rawEntryCount: 0,
      readMs,
      parseMs: 0,
      staleCursor: true,
    });
  }

  const parsed: ParsedLine[] = [];
  let scannedBytes = 0;
  let parseMs = 0;
  let selected: ParsedLine[];
  const sourceIndexes = pageSourceIndexes(sources, cursorSourceIndex);

  for (const sourceIndex of sourceIndexes) {
    const source = sources[sourceIndex];
    if (!source) continue;

    const windowReadStart = performance.now();
    const window =
      cursor && sourceIndex === cursorSourceIndex
        ? readPrefixWindow(source, cursor.byteStart, maxInitialReadBytes)
        : readSuffixWindow(source, maxInitialReadBytes);
    readMs += elapsed(windowReadStart);
    scannedBytes += window.scannedBytes;

    const parseStart = performance.now();
    parsed.push(...parseJsonlBuffer(window));
    parseMs += elapsed(parseStart);
    parsed.sort(compareLines);

    selected = selectEligiblePageEntries(
      parsed.filter((line) => isBeforeCursor(line, cursor, cursorSourceIndex)),
      targetEvents,
      requestedLeafId,
    );
    const selectEnough = selectedTraceEventEstimate(selected) >= targetEvents;
    if (selectEnough || window.baseByteOffset > 0) {
      break;
    }
  }

  const selectStart = performance.now();
  selected = selectEligiblePageEntries(
    parsed.filter((line) => isBeforeCursor(line, cursor, cursorSourceIndex)),
    targetEvents,
    requestedLeafId,
  );
  const selectMs = elapsed(selectStart);

  if (
    typeof requestedLeafId === "string" &&
    !selected.some((line) => line.entry.id === requestedLeafId)
  ) {
    return readAroundTracePage(sources, requestedLeafId, {
      traceVersion,
      jsonlBytes,
      targetEvents,
      previewBytes,
      maxInitialReadBytes,
      attachmentDataDir: options.attachmentDataDir,
      attachmentSessionId: options.attachmentSessionId,
      leafId: requestedLeafId,
    });
  }

  const previewStart = performance.now();
  const prepared = prepareEntriesForFormatting(selected, previewBytes);
  const previewMs = elapsed(previewStart);
  const formatStart = performance.now();
  const formattedTrace = formatEntries(prepared.entries, {
    ...options,
    leafId: requestedLeafId,
  });
  const formatMs = elapsed(formatStart);
  const trace = applyToolOutputPreviews(formattedTrace, previewBytes, prepared.previews);
  const firstSelected = selected[0];
  const hasOlder = firstSelected
    ? typeof requestedLeafId === "string"
      ? typeof firstSelected.entry.parentId === "string"
      : firstSelected.sourceIndex > 0 || firstSelected.byteStart > 0
    : false;

  return {
    trace,
    page: {
      hasOlder,
      olderCursor:
        hasOlder && firstSelected
          ? encodeCursor(
              firstSelected,
              typeof requestedLeafId === "string" ? firstSelected.entry.parentId : undefined,
            )
          : null,
      traceVersion,
      previewBytes,
      staleCursor: false,
    },
    metrics: {
      rawEntryCount: parsed.length,
      traceEventCount: trace.length,
      selectedRawEntryCount: selected.length,
      jsonlBytes,
      scannedBytes,
      readMs,
      parseMs,
      selectMs,
      formatMs,
      previewMs,
    },
  };
}

function emptyPage(params: {
  traceVersion: string;
  previewBytes: number;
  jsonlBytes: number;
  scannedBytes: number;
  rawEntryCount: number;
  readMs: number;
  parseMs: number;
  staleCursor: boolean;
}): TracePageResult {
  return {
    trace: [],
    page: {
      hasOlder: false,
      olderCursor: null,
      traceVersion: params.traceVersion,
      previewBytes: params.previewBytes,
      staleCursor: params.staleCursor,
    },
    metrics: {
      rawEntryCount: params.rawEntryCount,
      traceEventCount: 0,
      selectedRawEntryCount: 0,
      jsonlBytes: params.jsonlBytes,
      scannedBytes: params.scannedBytes,
      readMs: params.readMs,
      parseMs: params.parseMs,
      selectMs: 0,
      formatMs: 0,
      previewMs: 0,
    },
  };
}

function readAroundTracePage(
  sources: TraceSource[],
  aroundEntryId: string,
  params: {
    traceVersion: string;
    jsonlBytes: number;
    targetEvents: number;
    previewBytes: number;
    maxInitialReadBytes: number;
    attachmentDataDir?: string;
    attachmentSessionId?: string;
    leafId?: string;
  },
): TracePageResult {
  const readStart = performance.now();
  const found = findLineForEntryId(sources, aroundEntryId);
  let readMs = elapsed(readStart);
  if (!found.line) {
    return emptyPage({
      traceVersion: params.traceVersion,
      previewBytes: params.previewBytes,
      jsonlBytes: params.jsonlBytes,
      scannedBytes: found.scannedBytes,
      rawEntryCount: found.rawEntryCount,
      readMs,
      parseMs: found.parseMs,
      staleCursor: params.leafId !== undefined,
    });
  }

  const windowReadStart = performance.now();
  const windows = readAroundWindows(sources, found.line, params.maxInitialReadBytes);
  readMs += elapsed(windowReadStart);
  const scannedBytes =
    found.scannedBytes + windows.reduce((sum, window) => sum + window.scannedBytes, 0);

  const parseStart = performance.now();
  const parsed = uniqueLines([
    found.line,
    ...windows.flatMap((window) => parseJsonlBuffer(window)),
  ]).sort(compareLines);
  const parseMs = found.parseMs + elapsed(parseStart);

  const selectStart = performance.now();
  const selected = params.leafId
    ? selectEligiblePageEntries(
        parsed.filter((line) => compareLines(line, found.line as ParsedLine) <= 0),
        params.targetEvents,
        params.leafId,
      )
    : selectAroundPageEntries(parsed, found.line, params.targetEvents);
  const selectMs = elapsed(selectStart);
  const previewStart = performance.now();
  const prepared = prepareEntriesForFormatting(selected, params.previewBytes);
  const previewMs = elapsed(previewStart);
  const formatStart = performance.now();
  const formattedTrace = formatEntries(prepared.entries, params);
  const formatMs = elapsed(formatStart);
  const trace = applyToolOutputPreviews(formattedTrace, params.previewBytes, prepared.previews);
  const firstSelected = selected[0];
  const hasOlder = firstSelected
    ? params.leafId
      ? typeof firstSelected.entry.parentId === "string"
      : firstSelected.sourceIndex > 0 || firstSelected.byteStart > 0
    : false;

  return {
    trace,
    page: {
      hasOlder,
      olderCursor:
        hasOlder && firstSelected
          ? encodeCursor(firstSelected, params.leafId ? firstSelected.entry.parentId : undefined)
          : null,
      traceVersion: params.traceVersion,
      previewBytes: params.previewBytes,
      staleCursor: false,
    },
    metrics: {
      rawEntryCount: parsed.length,
      traceEventCount: trace.length,
      selectedRawEntryCount: selected.length,
      jsonlBytes: params.jsonlBytes,
      scannedBytes,
      readMs,
      parseMs,
      selectMs,
      formatMs,
      previewMs,
    },
  };
}

function elapsed(startMs: number): number {
  return Math.round((performance.now() - startMs) * 100) / 100;
}

function traceSources(jsonlPaths: string[]): TraceSource[] {
  return Array.from(new Set(jsonlPaths))
    .sort()
    .flatMap((path, index) => {
      try {
        const stats = statSync(path);
        if (!stats.isFile()) return [];
        return [
          {
            index,
            path,
            sourceId: sourceIdForPath(path),
            size: stats.size,
            mtimeMs: stats.mtimeMs,
          },
        ];
      } catch {
        return [];
      }
    })
    .map((source, index) => ({ ...source, index }));
}

function sourceIdForPath(path: string): string {
  return createHash("sha256").update(path).digest("base64url").slice(0, 16);
}

function traceVersionFor(sources: TraceSource[]): string {
  if (sources.length === 0) return "";
  const totalBytes = sources.reduce((sum, source) => sum + source.size, 0);
  const latestMtime = Math.max(...sources.map((source) => Math.trunc(source.mtimeMs)));
  const identity = createHash("sha256")
    .update(
      sources
        .map((source) => `${source.sourceId}:${source.size}:${Math.trunc(source.mtimeMs)}`)
        .join("|"),
    )
    .digest("base64url")
    .slice(0, 12);
  return `${sources.length}:${totalBytes}:${latestMtime}:${identity}`;
}

function pageSourceIndexes(
  sources: TraceSource[],
  cursorSourceIndex: number | undefined,
): number[] {
  const maxIndex = cursorSourceIndex ?? sources.length - 1;
  const indexes: number[] = [];
  for (let index = maxIndex; index >= 0; index -= 1) {
    indexes.push(index);
  }
  return indexes;
}

function readSuffixWindow(source: TraceSource, maxReadBytes: number): ReadWindow {
  const start = Math.max(0, source.size - maxReadBytes);
  return trimLeadingPartialLine(readRangeWindow(source, start, source.size));
}

function readPrefixWindow(
  source: TraceSource,
  upperExclusiveByte: number,
  maxReadBytes: number,
): ReadWindow {
  const clampedUpper = Math.max(0, Math.min(source.size, upperExclusiveByte));
  const start = Math.max(0, clampedUpper - maxReadBytes);
  return trimLeadingPartialLine(readRangeWindow(source, start, clampedUpper));
}

function readLeadingWindow(source: TraceSource, maxReadBytes: number): ReadWindow {
  return readRangeWindow(source, 0, Math.min(source.size, maxReadBytes));
}

function readAroundWindows(
  sources: TraceSource[],
  target: ParsedLine,
  maxReadBytes: number,
): ReadWindow[] {
  const windows: ReadWindow[] = [];
  const previous = sources[target.sourceIndex - 1];
  if (previous) {
    windows.push(readSuffixWindow(previous, maxReadBytes));
  }

  const source = sources[target.sourceIndex];
  if (source) {
    const start = Math.max(0, target.byteStart - maxReadBytes);
    const end = Math.min(source.size, target.byteEnd + maxReadBytes);
    windows.push(trimLeadingPartialLine(readRangeWindow(source, start, end)));
  }

  const next = sources[target.sourceIndex + 1];
  if (next) {
    windows.push(readLeadingWindow(next, maxReadBytes));
  }

  return windows;
}

function readRangeWindow(source: TraceSource, start: number, endExclusive: number): ReadWindow {
  const length = Math.max(0, endExclusive - start);
  if (length === 0) {
    return {
      sourceIndex: source.index,
      sourceId: source.sourceId,
      buffer: Buffer.alloc(0),
      baseByteOffset: start,
      scannedBytes: 0,
    };
  }

  const buffer = Buffer.allocUnsafe(length);
  const fd = openSync(source.path, "r");
  let bytesRead: number;
  try {
    bytesRead = readSync(fd, buffer, 0, length, start);
  } finally {
    closeSync(fd);
  }

  return {
    sourceIndex: source.index,
    sourceId: source.sourceId,
    buffer: bytesRead === length ? buffer : buffer.subarray(0, bytesRead),
    baseByteOffset: start,
    scannedBytes: bytesRead,
  };
}

function trimLeadingPartialLine(window: ReadWindow): ReadWindow {
  if (window.baseByteOffset === 0 || window.buffer.byteLength === 0) return window;

  const firstNewline = window.buffer.indexOf(0x0a);
  if (firstNewline < 0) {
    return {
      ...window,
      buffer: Buffer.alloc(0),
      baseByteOffset: window.baseByteOffset + window.buffer.byteLength,
    };
  }

  return {
    ...window,
    buffer: window.buffer.subarray(firstNewline + 1),
    baseByteOffset: window.baseByteOffset + firstNewline + 1,
  };
}

function parseJsonlBuffer(window: ReadWindow): ParsedLine[] {
  const parsed: ParsedLine[] = [];
  let lineStart = 0;
  for (let index = 0; index <= window.buffer.byteLength; index += 1) {
    if (index < window.buffer.byteLength && window.buffer[index] !== 0x0a) continue;
    const lineBuffer = window.buffer.subarray(lineStart, index);
    const byteStart = window.baseByteOffset + lineStart;
    const hasTerminatingNewline = index < window.buffer.byteLength;
    lineStart = index + 1;
    if (lineBuffer.byteLength === 0 || lineBuffer.toString("utf8").trim().length === 0) continue;
    try {
      const line = lineBuffer.toString("utf8");
      parsed.push({
        sourceIndex: window.sourceIndex,
        sourceId: window.sourceId,
        entry: JSON.parse(line) as SessionEntry,
        byteStart,
        byteEnd: byteStart + lineBuffer.byteLength + (hasTerminatingNewline ? 1 : 0),
        hash: hashLine(lineBuffer),
      });
    } catch {
      // Match the existing trace parser: tolerate malformed JSONL lines.
    }
  }
  return parsed;
}

function hashLine(line: Buffer): string {
  return createHash("sha256").update(line).digest("base64url").slice(0, 24);
}

function resolveCursorSourceIndex(sources: TraceSource[], cursor: TraceCursor): number | undefined {
  if (cursor.sourceId) {
    return sources.find((source) => source.sourceId === cursor.sourceId)?.index;
  }
  return sources.length === 1 ? 0 : undefined;
}

function validateCursor(source: TraceSource | undefined, cursor: TraceCursor): boolean {
  if (!source) return false;
  const line = readLineAt(source, cursor.byteStart);
  return line?.entry.id === cursor.entryId && line.hash === cursor.lineHash;
}

function readLineAt(source: TraceSource, byteStart: number): ParsedLine | null {
  if (byteStart < 0 || byteStart >= source.size) return null;

  const fd = openSync(source.path, "r");
  const chunks: Buffer[] = [];
  let offset = byteStart;
  let foundNewline = false;
  try {
    while (offset < source.size) {
      const length = Math.min(LINE_READ_CHUNK_BYTES, source.size - offset);
      const chunk = Buffer.allocUnsafe(length);
      const bytesRead = readSync(fd, chunk, 0, length, offset);
      if (bytesRead <= 0) break;
      const slice = bytesRead === length ? chunk : chunk.subarray(0, bytesRead);
      const newline = slice.indexOf(0x0a);
      if (newline >= 0) {
        chunks.push(slice.subarray(0, newline));
        foundNewline = true;
        break;
      }
      chunks.push(slice);
      offset += bytesRead;
    }
  } finally {
    closeSync(fd);
  }

  const lineBuffer = Buffer.concat(chunks);
  if (lineBuffer.byteLength === 0) return null;
  try {
    return {
      sourceIndex: source.index,
      sourceId: source.sourceId,
      entry: JSON.parse(lineBuffer.toString("utf8")) as SessionEntry,
      byteStart,
      byteEnd: Math.min(source.size, byteStart + lineBuffer.byteLength + (foundNewline ? 1 : 0)),
      hash: hashLine(lineBuffer),
    };
  } catch {
    return null;
  }
}

function findLineForEntryId(
  sources: TraceSource[],
  entryId: string,
): { line: ParsedLine | null; scannedBytes: number; rawEntryCount: number; parseMs: number } {
  let scannedBytes = 0;
  let rawEntryCount = 0;
  let parseMs = 0;

  for (const source of sources) {
    const fd = openSync(source.path, "r");
    let offset = 0;
    let pending = Buffer.alloc(0);
    let pendingByteStart = 0;

    try {
      while (offset < source.size) {
        const length = Math.min(LINE_READ_CHUNK_BYTES, source.size - offset);
        const chunk = Buffer.allocUnsafe(length);
        const bytesRead = readSync(fd, chunk, 0, length, offset);
        if (bytesRead <= 0) break;
        const slice = bytesRead === length ? chunk : chunk.subarray(0, bytesRead);
        scannedBytes += bytesRead;

        const buffer = pending.byteLength > 0 ? Buffer.concat([pending, slice]) : slice;
        const bufferByteStart = pending.byteLength > 0 ? pendingByteStart : offset;
        let lineStart = 0;
        let newline = buffer.indexOf(0x0a, lineStart);
        while (newline >= 0) {
          const lineBuffer = buffer.subarray(lineStart, newline);
          const byteStart = bufferByteStart + lineStart;
          const parseStart = performance.now();
          const line = parseMatchingLine(source, lineBuffer, byteStart, true, entryId);
          parseMs += elapsed(parseStart);
          if (lineBuffer.byteLength > 0) rawEntryCount += 1;
          if (line) return { line, scannedBytes, rawEntryCount, parseMs };

          lineStart = newline + 1;
          newline = buffer.indexOf(0x0a, lineStart);
        }

        pending = buffer.subarray(lineStart);
        pendingByteStart = bufferByteStart + lineStart;
        offset += bytesRead;
      }

      if (pending.byteLength > 0) {
        const parseStart = performance.now();
        const line = parseMatchingLine(source, pending, pendingByteStart, false, entryId);
        parseMs += elapsed(parseStart);
        rawEntryCount += 1;
        if (line) return { line, scannedBytes, rawEntryCount, parseMs };
      }
    } finally {
      closeSync(fd);
    }
  }

  return { line: null, scannedBytes, rawEntryCount, parseMs };
}

function parseMatchingLine(
  source: TraceSource,
  lineBuffer: Buffer,
  byteStart: number,
  hasTerminatingNewline: boolean,
  requestedEntryId: string,
): ParsedLine | null {
  if (lineBuffer.byteLength === 0) return null;

  const line = lineBuffer.toString("utf8");
  const entryId = readJsonStringField(line, "id");
  const canonicalEntryId = normalizeTraceDerivedEntryId(requestedEntryId);
  const exactEntryMatch = entryId === requestedEntryId || entryId === canonicalEntryId;
  const mayContainToolCall = !exactEntryMatch && line.includes(requestedEntryId);
  if (!exactEntryMatch && !mayContainToolCall) return null;
  if (!exactEntryMatch && line.includes('"role":"toolResult"')) return null;

  try {
    const entry = JSON.parse(line) as SessionEntry;
    if (!exactEntryMatch && !toolCallIdsInEntry(entry).includes(requestedEntryId)) {
      return null;
    }
    return {
      sourceIndex: source.index,
      sourceId: source.sourceId,
      entry,
      byteStart,
      byteEnd: Math.min(
        source.size,
        byteStart + lineBuffer.byteLength + (hasTerminatingNewline ? 1 : 0),
      ),
      hash: hashLine(lineBuffer),
    };
  } catch {
    return null;
  }
}

function readJsonStringField(line: string, field: string): string | undefined {
  const match = new RegExp(`"${field}":"((?:\\\\.|[^"\\\\])*)"`).exec(line);
  if (!match?.[1]) return undefined;
  return unescapeJsonString(match[1]);
}

function unescapeJsonString(value: string): string {
  if (!value.includes("\\")) return value;
  try {
    return JSON.parse(`"${value}"`) as string;
  } catch {
    return value;
  }
}

function normalizeTraceDerivedEntryId(id: string): string {
  for (const marker of ["-text-", "-think-", "-tool-"]) {
    const index = id.lastIndexOf(marker);
    if (index > 0) return id.slice(0, index);
  }
  return id;
}

function isBeforeCursor(
  line: ParsedLine,
  cursor: TraceCursor | null,
  cursorSourceIndex: number | undefined,
): boolean {
  if (!cursor || cursorSourceIndex === undefined) return true;
  if (line.sourceIndex < cursorSourceIndex) return true;
  if (line.sourceIndex > cursorSourceIndex) return false;
  return line.byteStart < cursor.byteStart;
}

function compareLines(lhs: ParsedLine, rhs: ParsedLine): number {
  return lhs.sourceIndex - rhs.sourceIndex || lhs.byteStart - rhs.byteStart;
}

function lineKey(line: ParsedLine): string {
  return `${line.sourceIndex}:${line.byteStart}`;
}

function selectEligiblePageEntries(
  lines: ParsedLine[],
  targetEvents: number,
  leafId: string | null | undefined,
): ParsedLine[] {
  if (leafId === null) return [];
  if (typeof leafId !== "string") return selectPageEntries(lines, targetEvents);

  const byId = new Map(lines.map((line) => [line.entry.id, line]));
  const branch: ParsedLine[] = [];
  const visited = new Set<string>();
  let currentId: string | null = leafId;

  while (currentId && !visited.has(currentId)) {
    visited.add(currentId);
    const line = byId.get(currentId);
    if (!line) break;
    branch.push(line);
    currentId = typeof line.entry.parentId === "string" ? line.entry.parentId : null;
  }

  return selectPageEntries(branch.reverse(), targetEvents);
}

function selectPageEntries(lines: ParsedLine[], targetEvents: number): ParsedLine[] {
  const eligible = [...lines].sort(compareLines);
  if (eligible.length === 0) return [];

  const toolGroups = buildToolLineGroups(eligible);
  const selected = new Set<string>();
  let selectedTraceCount = 0;

  for (let index = eligible.length - 1; index >= 0; index -= 1) {
    const line = eligible[index];
    if (!line || selected.has(lineKey(line))) continue;

    const group = groupForLine(line, toolGroups).filter(
      (grouped) => !selected.has(lineKey(grouped)),
    );
    if (group.length === 0) continue;

    for (const grouped of group) selected.add(lineKey(grouped));
    selectedTraceCount += group.reduce(
      (sum, grouped) => sum + estimateTraceEventCount(grouped.entry),
      0,
    );
    if (selectedTraceCount >= targetEvents) break;
  }

  return eligible.filter((line) => selected.has(lineKey(line)));
}

function selectAroundPageEntries(
  lines: ParsedLine[],
  targetLine: ParsedLine,
  targetEvents: number,
): ParsedLine[] {
  const eligible = uniqueLines(lines).sort(compareLines);
  if (eligible.length === 0) return [];

  const toolGroups = buildToolLineGroups(eligible);
  const selected = new Set<string>();
  let selectedTraceCount = 0;

  function addLine(line: ParsedLine | undefined): void {
    if (!line || selected.has(lineKey(line))) return;
    const group = groupForLine(line, toolGroups).filter(
      (grouped) => !selected.has(lineKey(grouped)),
    );
    if (group.length === 0) return;
    for (const grouped of group) selected.add(lineKey(grouped));
    selectedTraceCount += group.reduce(
      (sum, grouped) => sum + estimateTraceEventCount(grouped.entry),
      0,
    );
  }

  const targetKey = lineKey(targetLine);
  const targetIndex = eligible.findIndex((line) => lineKey(line) === targetKey);
  if (targetIndex < 0) return [];

  addLine(eligible[targetIndex]);

  let before = targetIndex - 1;
  let after = targetIndex + 1;
  while (selectedTraceCount < targetEvents && (before >= 0 || after < eligible.length)) {
    addLine(eligible[before]);
    before -= 1;
    if (selectedTraceCount >= targetEvents) break;
    addLine(eligible[after]);
    after += 1;
  }

  return eligible.filter((line) => selected.has(lineKey(line)));
}

function uniqueLines(lines: ParsedLine[]): ParsedLine[] {
  const seen = new Set<string>();
  return lines.filter((line) => {
    const key = lineKey(line);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function selectedTraceEventEstimate(lines: ParsedLine[]): number {
  return lines.reduce((sum, line) => sum + estimateTraceEventCount(line.entry), 0);
}

interface ToolLineGroup {
  lines: ParsedLine[];
  startIndex: number;
  endIndex: number;
}

function buildToolLineGroups(lines: ParsedLine[]): Map<string, ToolLineGroup> {
  const groups = new Map<string, { callIndex?: number; latestEvidenceIndex: number }>();
  for (const [index, line] of lines.entries()) {
    const callIds = toolCallIdsInEntry(line.entry);
    const evidenceId = toolEvidenceCallId(line.entry);
    for (const toolCallId of callIds) {
      const group = groups.get(toolCallId) ?? { latestEvidenceIndex: index };
      group.callIndex = index;
      group.latestEvidenceIndex = Math.max(group.latestEvidenceIndex, index);
      groups.set(toolCallId, group);
    }
    if (evidenceId) {
      const group = groups.get(evidenceId) ?? { latestEvidenceIndex: index };
      group.latestEvidenceIndex = Math.max(group.latestEvidenceIndex, index);
      groups.set(evidenceId, group);
    }
  }

  const complete = new Map<string, ToolLineGroup>();
  for (const [toolCallId, group] of groups) {
    if (group.callIndex === undefined) continue;
    complete.set(toolCallId, {
      lines,
      // Keep the entire parent-chain span. Concurrent tool lifecycle entries can
      // sit between this call and result; omitting them breaks both tree walking
      // and the next-page cursor boundary.
      startIndex: group.callIndex,
      endIndex: group.latestEvidenceIndex,
    });
  }
  return complete;
}

function groupForLine(line: ParsedLine, toolGroups: Map<string, ToolLineGroup>): ParsedLine[] {
  const toolCallId = toolCallIdsInEntry(line.entry)[0] ?? toolEvidenceCallId(line.entry);
  if (!toolCallId) return [line];

  const group = toolGroups.get(toolCallId);
  return group ? group.lines.slice(group.startIndex, group.endIndex + 1) : [];
}

function estimateTraceEventCount(entry: SessionEntry): number {
  switch (entry.type) {
    case "message":
      return estimateMessageEventCount(entry.message);
    case "compaction":
      return 1;
    case "thinking_level_change":
      return entry.thinkingLevel ? 1 : 0;
    case "model_change":
      return entry.modelId ? 1 : 0;
    case "branch_summary":
      return entry.summary ? 1 : 0;
    case "custom_message":
      return entry.content && entry.display !== false ? 1 : 0;
    case "custom":
      // Lifecycle is metadata on a nearby original trace event, not a standalone
      // wire event, so it does not consume the page's renderable event budget.
      return 0;
    default:
      return 0;
  }
}

function estimateMessageEventCount(message: SessionEntry["message"]): number {
  if (!message) return 0;
  if (message.role === "user") return hasTextContent(message.content) ? 1 : 0;
  if (message.role === "toolResult") return 1;
  if (message.role !== "assistant") return 0;
  if (typeof message.content === "string") return message.content.length > 0 ? 1 : 0;
  if (!Array.isArray(message.content)) return 0;
  return message.content.reduce((sum, block) => {
    const record = asRecord(block);
    if (!record) return sum;
    if (isTextBlock(record)) return sum + 1;
    if (record.type === "thinking" && typeof record.thinking === "string" && record.thinking) {
      return sum + 1;
    }
    if (record.type === "toolCall") return sum + 1;
    return sum;
  }, 0);
}

function hasTextContent(content: unknown): boolean {
  if (typeof content === "string") return content.length > 0;
  if (!Array.isArray(content)) return false;
  return content.some((block) => {
    const record = asRecord(block);
    return record ? isTextBlock(record) : false;
  });
}

function isTextBlock(record: Record<string, unknown>): boolean {
  return (
    (record.type === "text" || record.type === "output_text") &&
    typeof record.text === "string" &&
    record.text.length > 0
  );
}

function toolCallIdsInEntry(entry: SessionEntry): string[] {
  const message = entry.message;
  if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return [];
  return message.content.flatMap((block) => {
    const record = asRecord(block);
    if (record?.type === "toolCall" && typeof record.id === "string") return [record.id];
    return [];
  });
}

function toolEvidenceCallId(entry: SessionEntry): string | undefined {
  const message = entry.message;
  if (message?.role === "toolResult") {
    return typeof message.toolCallId === "string" ? message.toolCallId : undefined;
  }
  if (entry.type !== "custom" || entry.customType !== OPPI_LIFECYCLE_CUSTOM_TYPE) {
    return undefined;
  }
  const data = asRecord(entry.data);
  if (data?.event !== "tool_execution_start" && data?.event !== "tool_execution_end") {
    return undefined;
  }
  return typeof data.toolCallId === "string" ? data.toolCallId : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function formatEntries(
  entries: SessionEntry[],
  options: Pick<TracePageOptions, "attachmentDataDir" | "attachmentSessionId" | "leafId">,
): TraceEvent[] {
  return buildSessionContext(entries, {
    view: "full",
    attachmentDataDir: options.attachmentDataDir,
    attachmentSessionId: options.attachmentSessionId,
    ...(options.leafId !== undefined ? { leafId: options.leafId } : {}),
  });
}

function prepareEntriesForFormatting(
  selected: ParsedLine[],
  previewBytes: number,
): { entries: SessionEntry[]; previews: Map<string, ToolPreviewMetadata> } {
  const previews = new Map<string, ToolPreviewMetadata>();
  const entries = selected.map((line) => {
    const message = line.entry.message;
    if (!message || message.role !== "toolResult" || typeof message.content !== "string") {
      return line.entry;
    }

    const outputTotalBytes = Buffer.byteLength(message.content, "utf8");
    if (outputTotalBytes <= previewBytes) return line.entry;

    previews.set(`result-${line.entry.id}`, {
      outputPreviewBytes: previewBytes,
      outputTotalBytes,
    });
    return {
      ...line.entry,
      message: {
        ...message,
        content: utf8Prefix(message.content, previewBytes),
      },
    };
  });
  return { entries, previews };
}

function applyToolOutputPreviews(
  events: TraceEvent[],
  previewBytes: number,
  previews: Map<string, ToolPreviewMetadata>,
): TraceEvent[] {
  return events.map((event) => {
    const preparedPreview = previews.get(event.id);
    if (preparedPreview) {
      return {
        ...event,
        outputTruncated: true,
        outputPreviewBytes: preparedPreview.outputPreviewBytes,
        outputTotalBytes: preparedPreview.outputTotalBytes,
      };
    }

    if (event.type !== "toolResult" || typeof event.output !== "string") return event;
    const outputBytes = Buffer.byteLength(event.output, "utf8");
    if (outputBytes <= previewBytes) return event;
    return {
      ...event,
      output: utf8Prefix(event.output, previewBytes),
      outputTruncated: true,
      outputPreviewBytes: previewBytes,
      outputTotalBytes: outputBytes,
    };
  });
}

function utf8Prefix(text: string, maxBytes: number): string {
  if (maxBytes <= 0) return "";
  const buffer = Buffer.from(text, "utf8");
  if (buffer.byteLength <= maxBytes) return text;
  return buffer
    .subarray(0, maxBytes)
    .toString("utf8")
    .replace(/\uFFFD$/, "");
}

function encodeCursor(line: ParsedLine, branchLeafId?: string | null): string {
  const cursor: TraceCursor = {
    sourceId: line.sourceId,
    byteStart: line.byteStart,
    entryId: line.entry.id,
    lineHash: line.hash,
    ...(branchLeafId !== undefined ? { branchLeafId } : {}),
  };
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

function decodeCursor(encoded: string): TraceCursor | null {
  try {
    const parsed = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as unknown;
    const record = asRecord(parsed);
    if (!record) return null;
    if (typeof record.byteStart !== "number") return null;
    if (typeof record.entryId !== "string") return null;
    if (typeof record.lineHash !== "string") return null;
    return {
      ...(typeof record.sourceId === "string" ? { sourceId: record.sourceId } : {}),
      byteStart: record.byteStart,
      entryId: record.entryId,
      lineHash: record.lineHash,
      ...(typeof record.branchLeafId === "string" || record.branchLeafId === null
        ? { branchLeafId: record.branchLeafId as string | null }
        : {}),
    };
  } catch {
    return null;
  }
}

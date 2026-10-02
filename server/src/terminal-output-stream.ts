import { closeSync, fstatSync, openSync, readSync } from "node:fs";

/**
 * Append-only raw-byte log for one terminal-kind tool call.
 *
 * Phase 1 (no Pi temp file known): Pi's cumulative partial text is the source;
 * its UTF-8 encoding is the log. Phase 2 (Pi temp file known): the file's raw
 * bytes are the log, read synchronously from our cursor. Chunks within one epoch
 * are strictly contiguous from offset 0; an epoch bump means "discard prior
 * state". Offsets always count raw bytes, never UTF-16 units of `output`.
 *
 * The sidecar serves the same byte space: the Pi file when known, else the
 * phase-1 text (see `ToolOutputSnapshots`).
 */

/** Largest single chunk (raw bytes). */
export const TERMINAL_CHUNK_MAX_BYTES = 64 * 1024;
/** Largest amount of new bytes emitted per Pi update tick. */
export const TERMINAL_TICK_MAX_BYTES = 256 * 1024;
/** Largest drain at tool end; the remainder is left to the client's sidecar gap fill. */
export const TERMINAL_END_DRAIN_MAX_BYTES = 4 * 1024 * 1024;

export interface TerminalStreamChunk {
  output: string;
  outputStream: { epoch: number; offset: number; bytes: number };
}

export interface TerminalStreamEnd {
  chunks: TerminalStreamChunk[];
  epoch: number;
  totalBytes: number;
  /** Text that backs the sidecar after tool end when no Pi file exists. */
  snapshotText: string | null;
}

export interface TerminalAttachMarker {
  toolCallId: string;
  parentToolCallId?: string;
  epoch: number;
  offset: number;
}

interface StreamState {
  parentToolCallId?: string;
  epoch: number;
  sentBytes: number;
  /** Phase-1 text covering exactly `sentBytes`; null once the file owns the log. */
  text: string | null;
  filePath?: string;
  fileVerified: boolean;
}

export class TerminalOutputStreams {
  private readonly streams = new Map<string, StreamState>();

  has(id: string): boolean {
    return this.streams.has(id);
  }

  /** Register a running stream so a late attach can learn its cursor. */
  begin(id: string, parentToolCallId?: string): void {
    this.state(id, parentToolCallId);
  }

  /** Phase-1 text for the sidecar snapshot, or null when the Pi file owns the log. */
  retainedText(id: string): string | null {
    return this.streams.get(id)?.text ?? null;
  }

  /** One Pi update tick. `text` is Pi's cumulative partial text (ignored once a file is known). */
  update(
    id: string,
    input: { text?: string; fullOutputPath?: string; parentToolCallId?: string },
  ): TerminalStreamChunk[] {
    const s = this.state(id, input.parentToolCallId);
    if (input.fullOutputPath) s.filePath = input.fullOutputPath;
    if (s.filePath) return this.fileTick(s, TERMINAL_TICK_MAX_BYTES, false);
    if (input.text === undefined) return [];
    // A split surrogate pair would make delta bytes differ from whole-text bytes.
    const text = endsWithHighSurrogate(input.text) ? input.text.slice(0, -1) : input.text;
    return this.textTick(s, text, TERMINAL_TICK_MAX_BYTES);
  }

  /** Tool end: drain, then report the final length. The stream is no longer running afterwards. */
  end(
    id: string,
    input: { text?: string; fullOutputPath?: string; parentToolCallId?: string },
  ): TerminalStreamEnd {
    const s = this.state(id, input.parentToolCallId);
    this.streams.delete(id);
    if (input.fullOutputPath) s.filePath = input.fullOutputPath;
    if (s.filePath) {
      const chunks = this.fileTick(s, TERMINAL_END_DRAIN_MAX_BYTES, true);
      return {
        chunks,
        epoch: s.epoch,
        totalBytes: fileSize(s.filePath) ?? s.sentBytes,
        snapshotText: null,
      };
    }
    // An empty final text carries no information; keep what was streamed.
    const text = input.text !== undefined && input.text.length > 0 ? input.text : undefined;
    const chunks = text === undefined ? [] : this.textTick(s, text, TERMINAL_END_DRAIN_MAX_BYTES);
    const snapshotText = text ?? s.text;
    return {
      chunks,
      epoch: s.epoch,
      totalBytes: snapshotText === null ? s.sentBytes : Buffer.byteLength(snapshotText, "utf8"),
      snapshotText,
    };
  }

  attachMarkers(): TerminalAttachMarker[] {
    return [...this.streams].map(([toolCallId, s]) => ({
      toolCallId,
      ...(s.parentToolCallId ? { parentToolCallId: s.parentToolCallId } : {}),
      epoch: s.epoch,
      offset: s.sentBytes,
    }));
  }

  clear(): void {
    this.streams.clear();
  }

  get size(): number {
    return this.streams.size;
  }

  private state(id: string, parentToolCallId?: string): StreamState {
    let s = this.streams.get(id);
    if (!s) {
      s = {
        ...(parentToolCallId ? { parentToolCallId } : {}),
        epoch: 1,
        sentBytes: 0,
        text: "",
        fileVerified: false,
      };
      this.streams.set(id, s);
    }
    return s;
  }

  private textTick(s: StreamState, full: string, budget: number): TerminalStreamChunk[] {
    const sent = s.text ?? "";
    if (full === sent) return [];
    let start = sent.length;
    if (!full.startsWith(sent)) {
      // Pi replaced rather than extended its view: explicit new epoch.
      s.epoch += 1;
      s.sentBytes = 0;
      s.text = "";
      start = 0;
      if (full.length === 0) return [];
    }
    const chunks: TerminalStreamChunk[] = [];
    let emitted = 0;
    while (start < full.length && emitted < budget) {
      const end = utf16EndWithin(full, start, Math.min(TERMINAL_CHUNK_MAX_BYTES, budget - emitted));
      if (end <= start) break;
      const slice = full.slice(start, end);
      const bytes = Buffer.byteLength(slice, "utf8");
      chunks.push({
        output: LONE_SURROGATE.test(slice) ? Buffer.from(slice, "utf8").toString("utf8") : slice,
        outputStream: { epoch: s.epoch, offset: s.sentBytes, bytes },
      });
      s.sentBytes += bytes;
      emitted += bytes;
      start = end;
    }
    s.text = full.slice(0, start);
    return chunks;
  }

  private fileTick(s: StreamState, budget: number, draining: boolean): TerminalStreamChunk[] {
    const path = s.filePath;
    if (!path) return [];
    let fd: number;
    try {
      fd = openSync(path, "r");
    } catch {
      return [];
    }
    try {
      const size = fstatSync(fd).size;
      if (!s.fileVerified) {
        // Pi's write stream may lag the update that named the file.
        if (size < s.sentBytes && !draining) return [];
        const expected = Buffer.from(s.text ?? "", "utf8");
        const actual = Buffer.alloc(expected.length);
        const read = size >= expected.length ? readFully(fd, actual, 0) : 0;
        if (read !== expected.length || !actual.equals(expected)) {
          // The file is the authoritative log; restart it from byte 0.
          s.epoch += 1;
          s.sentBytes = 0;
        }
        s.fileVerified = true;
        s.text = null;
      }
      const want = Math.min(size - s.sentBytes, budget);
      if (want <= 0) return [];
      const buffer = Buffer.alloc(want);
      const got = readFully(fd, buffer, s.sentBytes);
      // Mid-file cuts and (while running) a trailing partial codepoint are held back.
      const reachedEof = s.sentBytes + got >= size;
      const usable = alignedLength(buffer, got, !reachedEof || !draining);
      const chunks: TerminalStreamChunk[] = [];
      for (let at = 0; at < usable; ) {
        const length = alignedLength(
          buffer.subarray(at, usable),
          Math.min(usable - at, TERMINAL_CHUNK_MAX_BYTES),
          usable - at > TERMINAL_CHUNK_MAX_BYTES,
        );
        if (length <= 0) break;
        chunks.push({
          output: buffer.toString("utf8", at, at + length),
          outputStream: { epoch: s.epoch, offset: s.sentBytes, bytes: length },
        });
        s.sentBytes += length;
        at += length;
      }
      return chunks;
    } catch {
      return [];
    } finally {
      closeSync(fd);
    }
  }
}

/** In `u` mode only unpaired surrogates match, so this finds text that is not valid Unicode. */
const LONE_SURROGATE = /\p{Surrogate}/u;

function endsWithHighSurrogate(text: string): boolean {
  const last = text.charCodeAt(text.length - 1);
  return last >= 0xd800 && last <= 0xdbff;
}

/** Largest UTF-16 end index so `text[start, end)` encodes to at most `maxBytes`, never splitting a pair. */
function utf16EndWithin(text: string, start: number, maxBytes: number): number {
  let end = Math.min(text.length, start + maxBytes);
  let bytes = Buffer.byteLength(text.slice(start, end), "utf8");
  while (bytes > maxBytes && end > start) {
    end -= Math.max(1, Math.ceil((bytes - maxBytes) / 3));
    bytes = Buffer.byteLength(text.slice(start, end), "utf8");
  }
  if (end < text.length && end > start) {
    const last = text.charCodeAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end -= 1;
  }
  return end;
}

/**
 * Length of `buffer[0, length)` after dropping an incomplete trailing UTF-8 sequence
 * when `holdPartial`. Invalid bytes are never held (the decoder maps them to U+FFFD).
 */
function alignedLength(buffer: Buffer, length: number, holdPartial: boolean): number {
  if (!holdPartial || length === 0) return length;
  for (let back = 1; back <= 3 && back <= length; back += 1) {
    const byte = buffer[length - back] ?? 0;
    if ((byte & 0xc0) === 0x80) continue; // continuation: keep looking for its lead
    const expected = byte >= 0xf5 ? 1 : byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : byte >= 0xc2 ? 2 : 1;
    return expected > back ? length - back : length;
  }
  return length;
}

function readFully(fd: number, buffer: Buffer, position: number): number {
  let total = 0;
  while (total < buffer.length) {
    const n = readSync(fd, buffer, total, buffer.length - total, position + total);
    if (n <= 0) break;
    total += n;
  }
  return total;
}

function fileSize(path: string): number | undefined {
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return undefined;
  }
  try {
    return fstatSync(fd).size;
  } finally {
    closeSync(fd);
  }
}

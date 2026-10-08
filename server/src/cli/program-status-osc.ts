/**
 * OSC 7501 program status emitter for `oppi session wait --program-status`.
 *
 * Grammar and limits follow the spec (rev 0.3, superlogical.com/rex/docs/build/program-status):
 *
 *   OSC 7501 ; key=value(:key=value)* ST        ESC ] 7501 ; ... ESC \
 *
 * Values use `[A-Za-z0-9_.,+/=-]`, so nothing needs escaping. `msg` and `title` are standard
 * base64 of UTF-8 text without control characters; a terminal discards the whole report
 * otherwise. Limits: `msg` 2048 bytes decoded, `title` 192 decoded, id 128 bytes total with
 * segments of `[A-Za-z0-9_.+-]{1,32}`, `app` `[A-Za-z0-9_.+-]{1,32}`.
 *
 * One session is the root record (no id). Several sessions are child records whose id is the
 * session UUID without dashes (32 characters, where the dashed form of 36 is rejected), each with
 * a base64 title and its own `app`, because there is no root to inherit it from.
 */

import type { ProgramStatus } from "../types.js";

const OSC_PREFIX = "\x1b]7501;";
const ST = "\x1b\\";
const APP = "oppi";
const MAX_MESSAGE_BYTES = 2048;
const MAX_TITLE_BYTES = 192;
const ID_SEGMENT = /^[A-Za-z0-9_.+-]{1,32}$/;
// eslint-disable-next-line no-control-regex -- the point is to remove them
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f-\u009f]+/g;

/** Where reports go. Only a TTY gets any; a pipe or file never sees escape sequences. */
export interface ProgramStatusStream {
  isTTY?: boolean;
  write(chunk: string): unknown;
}

/** One session as the wait loop observes it. */
export interface ProgramStatusSessionView {
  sessionId: string;
  name?: string;
  programStatus?: ProgramStatus;
}

function truncateUtf8(text: string, maxBytes: number): string {
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text;
  let bytes = 0;
  let end = 0;
  for (const char of text) {
    const size = Buffer.byteLength(char, "utf8");
    if (bytes + size > maxBytes) break;
    bytes += size;
    end += char.length;
  }
  return text.slice(0, end);
}

/** Base64 of one sanitized line, or undefined when nothing is left to send. */
function encodeText(text: string | undefined, maxBytes: number): string | undefined {
  const line = truncateUtf8((text ?? "").replace(CONTROL_CHARACTERS, " ").trim(), maxBytes);
  return line ? Buffer.from(line, "utf8").toString("base64") : undefined;
}

/** `id` for a session: its UUID without dashes. */
export function programStatusRecordId(sessionId: string): string {
  const id = sessionId.replaceAll("-", "");
  if (!id.split("/").every((segment) => ID_SEGMENT.test(segment)) || id.length > 128) {
    throw new Error(`Session id is not a valid OSC 7501 record id: ${sessionId}`);
  }
  return id;
}

function report(pairs: string[]): string {
  return `${OSC_PREFIX}${pairs.join(":")}${ST}`;
}

/** Report for one record. `id` absent addresses the root record. */
export function formatProgramStatusReport(
  status: ProgramStatus,
  record: { id?: string; title?: string } = {},
): string {
  const pairs = [`state=${status.state}`];
  if (record.id !== undefined) pairs.push(`id=${record.id}`);
  pairs.push(`app=${APP}`);
  if (status.state === "blocked" && status.kind) pairs.push(`kind=${status.kind}`);
  const title = encodeText(record.title, MAX_TITLE_BYTES);
  if (title) pairs.push(`title=${title}`);
  const message = encodeText(status.message, MAX_MESSAGE_BYTES);
  if (message) pairs.push(`msg=${message}`);
  return report(pairs);
}

/** Removes the addressed record and its subtree; with no id, every record on the terminal. */
export function formatProgramStatusClear(id?: string): string {
  return report(id === undefined ? ["state=clear"] : ["state=clear", `id=${id}`]);
}

/**
 * Reports the program status of the sessions a wait is watching, and clears it on exit.
 * Writes nothing unless the stream is a TTY. A report goes out only when it differs from the
 * last one for that record: terminals keep records until replaced, so there is no heartbeat.
 */
export class ProgramStatusEmitter {
  private readonly lastReport = new Map<string, string>();

  constructor(
    private readonly stream: ProgramStatusStream | undefined,
    private readonly sessionIds: readonly string[],
  ) {}

  /** The single watched session is the root record; several are child records. */
  private recordIdFor(sessionId: string): string | undefined {
    return this.sessionIds.length === 1 ? undefined : programStatusRecordId(sessionId);
  }

  update(session: ProgramStatusSessionView): void {
    if (!this.stream?.isTTY || !session.programStatus) return;
    const id = this.recordIdFor(session.sessionId);
    const sequence = formatProgramStatusReport(session.programStatus, {
      ...(id !== undefined ? { id } : {}),
      // Child records carry a label; the root record's label is the window title.
      ...(id !== undefined
        ? { title: session.name ?? `Session ${session.sessionId.slice(0, 8)}` }
        : {}),
    });
    const key = id ?? "";
    if (this.lastReport.get(key) === sequence) return;
    this.lastReport.set(key, sequence);
    this.stream.write(sequence);
  }

  /** Clear every record this emitter wrote. */
  clear(): void {
    if (!this.stream?.isTTY) return;
    for (const key of this.lastReport.keys()) {
      this.stream.write(formatProgramStatusClear(key === "" ? undefined : key));
    }
    this.lastReport.clear();
  }
}

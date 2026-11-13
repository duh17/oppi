/**
 * Daily files for `<data-dir>/server.log`, the file the launchd agent points both
 * StandardOutPath and StandardErrorPath at (`launchd.ts`). Nothing else rotates it.
 *
 * Whole lines older than today (UTC, by each record's `ts`) move to
 * `server-YYYY-MM-DD.log`, kept `OPPI_SERVER_LOG_RETENTION_DAYS` (14) days, the same
 * naming and retention pattern as the daily telemetry files (`telemetry/event-writer.ts`).
 *
 * launchd opens server.log O_APPEND and keeps the descriptor for the life of the process, so
 * renaming it would leave the server writing into the renamed file. The live file is therefore
 * rewritten in place: today's lines are read back, the file is truncated, and they are
 * appended again. O_APPEND makes the server's next write land at the new end, with no hole.
 * Lines the server writes between that read and the truncate are lost; the window is a few
 * milliseconds, once a day.
 *
 * The live file holds one UTC day, so its size is the day's log volume; nothing caps a day
 * that logs far more than usual, and today's lines are held in memory while the file is rewritten.
 */

import { appendFile, open, type FileHandle } from "node:fs/promises";
import { join } from "node:path";

import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import { dateString, pruneOldJsonlFiles, retentionDaysFromEnv } from "./metric-utils.js";

const log = createLogger({ base: { component: "server_log_rotation" } });

const LIVE_FILE = "server.log";
const DAILY_PREFIX = "server-";
const DAILY_SUFFIX = ".log";
const RETENTION_ENV = "OPPI_SERVER_LOG_RETENTION_DAYS";
const DEFAULT_RETENTION_DAYS = 14;
const DAY_MS = 24 * 60 * 60 * 1000;

/** How often to look for a new UTC day: the check reads only up to the first record. */
const CHECK_INTERVAL_MS = 5 * 60 * 1000;

/** The live file is read this much at a time, so memory stays flat however long it is. */
const CHUNK_BYTES = 1024 * 1024;

const TS_DAY = /^\{"ts":"(\d{4}-\d{2}-\d{2})T/;

interface ServerLogRotationOptions {
  now?: number;
  retentionDays?: number;
}

/**
 * The file's whole lines (newline kept, latin1 so offsets are byte offsets), one chunk's worth
 * at a time. The last line is yielded even when it has no newline yet.
 */
async function* lineChunks(file: FileHandle): AsyncGenerator<string[]> {
  const buf = Buffer.allocUnsafe(CHUNK_BYTES);
  let position = 0;
  let carry = "";
  for (;;) {
    const { bytesRead } = await file.read(buf, 0, CHUNK_BYTES, position);
    if (bytesRead === 0) break;
    position += bytesRead;
    const lines = (carry + buf.toString("latin1", 0, bytesRead)).split(/(?<=\n)/);
    carry = lines.pop() ?? "";
    if (carry.endsWith("\n")) {
      lines.push(carry);
      carry = "";
    }
    if (lines.length > 0) yield lines;
  }
  if (carry) yield [carry];
}

/**
 * Move lines older than today's UTC date out of `<dataDir>/server.log` into daily files and
 * remove daily files past retention. Returns whether any line moved.
 *
 * A line without a timestamp (a stack trace, a runtime warning) belongs to the day of the
 * line before it. Text ahead of the first timestamped record, however long (the file may open
 * with start markers or plain text from an older writer), belongs to that first record's day.
 * A file with no timestamped record, or one that starts today, is left alone.
 */
export async function rotateServerLog(
  dataDir: string,
  options: ServerLogRotationOptions = {},
): Promise<boolean> {
  const now = options.now ?? Date.now();
  const retentionDays =
    options.retentionDays ?? retentionDaysFromEnv(RETENTION_ENV, DEFAULT_RETENTION_DAYS);
  const livePath = join(dataDir, LIVE_FILE);
  const today = dateString(now);

  pruneOldJsonlFiles(dataDir, DAILY_PREFIX, DAILY_SUFFIX, retentionDays, now);

  let file;
  try {
    file = await open(livePath, "r+");
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw err;
  }
  try {
    let headDay: string | undefined;
    find: for await (const lines of lineChunks(file)) {
      for (const line of lines) {
        headDay = TS_DAY.exec(line)?.[1];
        if (headDay) break find;
      }
    }
    if (headDay === undefined || headDay >= today) return false;

    const oldestKept = now - retentionDays * DAY_MS;
    const writeDays = async (byDay: Map<string, string[]>): Promise<void> => {
      for (const [d, lines] of byDay) {
        if (Date.parse(`${d}T00:00:00.000Z`) < oldestKept) continue;
        await appendFile(join(dataDir, `${DAILY_PREFIX}${d}${DAILY_SUFFIX}`), lines.join(""), {
          encoding: "latin1",
          mode: 0o600,
        });
      }
    };

    let day = headDay;
    // Bytes before the first line of today: the part that moves.
    let offset = 0;
    let reachedToday = false;
    for await (const lines of lineChunks(file)) {
      const byDay = new Map<string, string[]>();
      for (const line of lines) {
        day = TS_DAY.exec(line)?.[1] ?? day;
        if (day >= today) {
          reachedToday = true;
          break;
        }
        const dayLines = byDay.get(day);
        if (dayLines) dayLines.push(line);
        else byDay.set(day, [line]);
        offset += line.length;
      }
      await writeDays(byDay);
      if (reachedToday) break;
    }

    // Re-read everything past the cut: the server kept writing while the days were written.
    const size = (await file.stat()).size;
    const tail = Buffer.alloc(Math.max(0, size - offset));
    await file.read(tail, 0, tail.length, offset);
    await file.truncate(0);
    // Append, as the server does: a line written since the truncate stays ahead of the tail
    // instead of being overwritten.
    await appendFile(livePath, tail);
  } finally {
    await file.close();
  }
  return true;
}

/** Check now and every few minutes, for the life of the process (the timer is unref'd). */
export function startServerLogRotation(dataDir: string): void {
  let running = false;
  const run = (): void => {
    if (running) return;
    running = true;
    rotateServerLog(dataDir)
      .then((rotated) => {
        if (rotated) log.info("server_log.rotated");
      })
      .catch((err: unknown) =>
        log.warn("server_log.rotation_failed", { error: safeErrorMessage(err) }),
      )
      .finally(() => {
        running = false;
      });
  };
  run();
  setInterval(run, CHECK_INTERVAL_MS).unref();
}

import {
  closeSync,
  existsSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { buildServerLogReview } from "../scripts/server-log-review.ts";
import { rotateServerLog } from "../src/server-log-rotation.js";

const NOW = Date.UTC(2026, 10, 12, 0, 30, 0);

/** A server log record stamped on 2026-11-`day`. */
const record = (day: number, n: number): string =>
  `${JSON.stringify({ ts: `2026-11-${String(day).padStart(2, "0")}T12:00:${String(n).padStart(2, "0")}.000Z`, level: "warn", component: "t", event: `d${day}n${n}` })}\n`;

describe("rotateServerLog", () => {
  let dir: string;
  let livePath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-log-rotation-"));
    livePath = join(dir, "server.log");
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  const read = (name: string): string => readFileSync(join(dir, name), "utf8");

  it("leaves a log that only holds today alone", async () => {
    const content = record(12, 1) + record(12, 2);
    writeFileSync(livePath, content);

    expect(await rotateServerLog(dir, { now: NOW })).toBe(false);
    expect(read("server.log")).toBe(content);
    expect(existsSync(join(dir, "server-2026-11-12.log"))).toBe(false);
  });

  it("does nothing when there is no log", async () => {
    expect(await rotateServerLog(dir, { now: NOW })).toBe(false);
  });

  it("moves finished days into daily files, keeps today, and keeps an O_APPEND writer working", async () => {
    // Stand in for launchd's descriptor: opened once, O_APPEND, held across the rotation.
    const launchdFd = openSync(livePath, "a");
    const stack = "    at somewhere (file.js:1:1)\n"; // no timestamp: belongs to the line before
    const lines = [
      record(9, 1),
      record(9, 2),
      record(10, 1),
      `Error: boom\n${stack}`,
      record(11, 1),
      record(12, 1),
      record(12, 2),
    ];
    for (const l of lines) writeSync(launchdFd, l);

    expect(await rotateServerLog(dir, { now: NOW })).toBe(true);

    expect(read("server-2026-11-09.log")).toBe(record(9, 1) + record(9, 2));
    expect(read("server-2026-11-10.log")).toBe(record(10, 1) + `Error: boom\n${stack}`);
    expect(read("server-2026-11-11.log")).toBe(record(11, 1));
    expect(read("server.log")).toBe(record(12, 1) + record(12, 2));

    // The held descriptor still appends to the same file, at the new end: no hole, no loss.
    writeSync(launchdFd, record(12, 3));
    closeSync(launchdFd);
    expect(read("server.log")).toBe(record(12, 1) + record(12, 2) + record(12, 3));

    // A second pass in the same day has nothing to move.
    expect(await rotateServerLog(dir, { now: NOW })).toBe(false);
  });

  it("drops days past retention and prunes daily files that aged out", async () => {
    writeFileSync(livePath, record(1, 1) + record(10, 1) + record(12, 1));
    writeFileSync(join(dir, "server-2026-10-01.log"), "aged out\n");
    writeFileSync(join(dir, "server-2026-11-08.log"), "still kept\n");

    await rotateServerLog(dir, { now: NOW, retentionDays: 5 });

    expect(existsSync(join(dir, "server-2026-11-01.log"))).toBe(false);
    expect(existsSync(join(dir, "server-2026-10-01.log"))).toBe(false);
    expect(read("server-2026-11-08.log")).toBe("still kept\n");
    expect(read("server-2026-11-10.log")).toBe(record(10, 1));
    expect(read("server.log")).toBe(record(12, 1));
  });

  it("keeps server-log-review reading the whole window across a rotation", async () => {
    writeFileSync(livePath, record(10, 1) + record(11, 1) + record(12, 1));
    await rotateServerLog(dir, { now: NOW });

    const review = buildServerLogReview({
      logPath: livePath,
      sinceMs: Date.UTC(2026, 10, 10, 0, 0, 0),
      limit: 10,
    });

    expect(review.lines).toBe(3);
    expect(review.inWindow).toBe(3);
    expect(review.unparsed).toBe(0);
  });
});

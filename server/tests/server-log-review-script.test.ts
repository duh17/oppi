import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { buildServerLogReview } from "../scripts/server-log-review.ts";

const HOUR_MS = 60 * 60 * 1_000;

describe("server-log-review", () => {
  let dataDir: string;
  let logPath: string;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-server-log-review-"));
    logPath = join(dataDir, "server.log");
    vi.spyOn(Date, "now").mockReturnValue(Date.UTC(2026, 6, 23, 1, 0, 0));
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("reports a missing server log as unavailable", () => {
    const review = buildServerLogReview({ logPath, hours: 1, limit: 10 });

    expect(review.logAvailable).toBe(false);
    expect(review.evidenceState).toBe("unavailable");
    expect(review.lines).toBe(0);
    expect(review.inWindow).toBe(0);
  });

  it("reports a log containing only unparsed lines as invalid", () => {
    writeFileSync(logPath, "{}\n");

    const review = buildServerLogReview({ logPath, hours: 1, limit: 10 });

    expect(review.evidenceState).toBe("invalid");
    expect(review.parsed).toBe(0);
    expect(review.unparsed).toBe(1);
  });

  it("uses an exact hour window and keeps the boundary event", () => {
    const cutoffMs = Date.now() - 2 * HOUR_MS;
    writeFileSync(
      logPath,
      [
        JSON.stringify({
          ts: new Date(cutoffMs - 1).toISOString(),
          level: "warn",
          component: "mirror",
          event: "outside",
        }),
        JSON.stringify({
          ts: new Date(cutoffMs).toISOString(),
          level: "warn",
          component: "mirror",
          event: "boundary",
        }),
      ].join("\n") + "\n",
    );

    const review = buildServerLogReview({ logPath, hours: 2, limit: 10 });

    expect(review.logAvailable).toBe(true);
    expect(review.evidenceState).toBe("available");
    expect(review.windowLabel).toBe("2h");
    expect(review.requestedSinceMs).toBe(cutoffMs);
    expect(review.inWindow).toBe(1);
    expect(review.problems.map((problem) => problem.event)).toEqual(["boundary"]);
  });

  it("reports an exact ISO since boundary", () => {
    const sinceMs = Date.now() - 37 * 60 * 1_000;
    writeFileSync(
      logPath,
      `${JSON.stringify({
        ts: new Date(sinceMs).toISOString(),
        level: "error",
        component: "bridge",
        event: "invalid_bridge_hello",
      })}\n`,
    );

    const review = buildServerLogReview({ logPath, sinceMs, limit: 10 });

    expect(review.requestedSinceMs).toBe(sinceMs);
    expect(review.inWindow).toBe(1);
    expect(review.windowLabel).toContain("since 2026-07-23 00:23:00Z");
  });
});

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { buildClientLogReview } from "../scripts/client-log-review.ts";

const HOUR_MS = 60 * 60 * 1_000;

describe("client-log-review", () => {
  let dataDir: string;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-client-log-review-"));
    mkdirSync(join(dataDir, "diagnostics", "telemetry"), { recursive: true });
    vi.spyOn(Date, "now").mockReturnValue(Date.UTC(2026, 4, 31, 12, 0, 0));
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("reports unavailable telemetry instead of a successful empty source", () => {
    rmSync(join(dataDir, "diagnostics"), { recursive: true, force: true });

    const review = buildClientLogReview({ dataDir, hours: 1, limit: 10 });

    expect(review.telemetryAvailable).toBe(false);
    expect(review.evidenceState).toBe("unavailable");
    expect(review.filesRead).toBe(0);
    expect(review.entries).toBe(0);
  });

  it("reports files containing only malformed records as invalid", () => {
    writeFileSync(
      join(dataDir, "diagnostics", "telemetry", "client-logs-2026-05-31.jsonl"),
      "{}\n",
    );

    const review = buildClientLogReview({ dataDir, hours: 1, limit: 10 });

    expect(review.evidenceState).toBe("invalid");
    expect(review.parsedRecords).toBe(0);
    expect(review.malformedRecords).toBe(1);
  });

  it("counts uploads and dropped logs inside the requested time window", () => {
    const now = Date.now();
    const oldTs = now - 6 * HOUR_MS;
    const recentTs = now - HOUR_MS;
    const telemetryDir = join(dataDir, "diagnostics", "telemetry");

    writeFileSync(
      join(telemetryDir, "client-logs-2026-05-31.jsonl"),
      [
        JSON.stringify({
          generatedAt: oldTs,
          buildNumber: "36",
          droppedCount: 10,
          entries: [{ ts: oldTs, level: "error", category: "WebSocket", message: "old" }],
        }),
        JSON.stringify({
          generatedAt: recentTs,
          buildNumber: "36",
          droppedCount: 2,
          entries: [{ ts: recentTs, level: "error", category: "WebSocket", message: "recent" }],
        }),
      ].join("\n") + "\n",
    );

    const review = buildClientLogReview({ dataDir, hours: 3, limit: 10 });

    expect(review.telemetryAvailable).toBe(true);
    expect(review.evidenceState).toBe("available");
    expect(review.filesRead).toBe(1);
    expect(review.uploads).toBe(1);
    expect(review.dropped).toBe(2);
    expect(review.entries).toBe(1);
    expect(review.issues).toHaveLength(1);
    expect(review.issues[0]?.message).toBe("recent");
    expect(review.windowLabel).toBe("3h");
    expect(review.requestedSinceMs).toBe(now - 3 * HOUR_MS);
  });

  it("prioritizes a focus match before applying the row limit", () => {
    const now = Date.now();
    const telemetryDir = join(dataDir, "diagnostics", "telemetry");
    const entries = [
      ...Array.from({ length: 5 }, (_, index) => ({
        ts: now - index,
        level: "error",
        category: "Network",
        message: "generic timeout",
      })),
      {
        ts: now,
        level: "warn",
        category: "Mirror",
        message: "bridge protocolVersion rejected",
      },
    ];
    writeFileSync(
      join(telemetryDir, "client-logs-2026-05-31.jsonl"),
      `${JSON.stringify({ generatedAt: now, buildNumber: "36", entries })}\n`,
    );

    const review = buildClientLogReview({
      dataDir,
      hours: 1,
      limit: 1,
      match: /bridge|protocolVersion/i,
    });

    expect(review.issues).toHaveLength(1);
    expect(review.issues[0]?.message).toBe("bridge protocolVersion rejected");
  });

  it("uses an exact since boundary instead of widening to a whole day", () => {
    const now = Date.now();
    const sinceMs = now - 90 * 60 * 1_000;
    const telemetryDir = join(dataDir, "diagnostics", "telemetry");
    writeFileSync(
      join(telemetryDir, "client-logs-2026-05-31.jsonl"),
      `${JSON.stringify({
        generatedAt: now,
        buildNumber: "36",
        entries: [
          { ts: sinceMs - 1, level: "error", category: "Network", message: "outside" },
          { ts: sinceMs, level: "error", category: "Network", message: "boundary" },
        ],
      })}\n`,
    );

    const review = buildClientLogReview({ dataDir, sinceMs, limit: 10 });

    expect(review.requestedSinceMs).toBe(sinceMs);
    expect(review.entries).toBe(1);
    expect(review.issues.map((issue) => issue.message)).toEqual(["boundary"]);
  });
});

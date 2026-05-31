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

    expect(review.filesRead).toBe(1);
    expect(review.uploads).toBe(1);
    expect(review.dropped).toBe(2);
    expect(review.entries).toBe(1);
    expect(review.issues).toHaveLength(1);
    expect(review.issues[0]?.message).toBe("recent");
  });
});

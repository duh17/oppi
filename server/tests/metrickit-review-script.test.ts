import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { buildMetricKitReview } from "../scripts/metrickit-review.ts";

const MATCHING_UUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
const MISMATCHED_UUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB";

function writeFakeXcrun(binDir: string): void {
  const scriptPath = join(binDir, "xcrun");
  writeFileSync(
    scriptPath,
    `#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  dwarfdump)
    echo "UUID: ${MATCHING_UUID} (arm64) \${3:-}"
    ;;
  atos)
    echo "Oppi.expandedStreamingRender() (in Oppi)"
    ;;
  *)
    echo "unexpected xcrun command: \${1:-}" >&2
    exit 2
    ;;
esac
`,
  );
  chmodSync(scriptPath, 0o755);
}

function writeMetricKitRecord(dataDir: string, frameUUID: string): void {
  const telemetryDir = join(dataDir, "diagnostics", "telemetry");
  mkdirSync(telemetryDir, { recursive: true });

  const windowEndMs = Date.UTC(2026, 5, 19, 12, 0, 0);
  const record = {
    receivedAt: windowEndMs,
    generatedAt: windowEndMs,
    appVersion: "1.0",
    buildNumber: "38",
    osVersion: "iOS 18.5",
    deviceModel: "iPhone",
    clientKind: "ios",
    payloadCount: 1,
    payloads: [
      {
        kind: "diagnostic",
        windowStartMs: windowEndMs - 60_000,
        windowEndMs,
        summary: {
          cpuExceptionDiagnosticCount: "1",
          lastSessionId: "Cu8iRTsq",
          lastWorkspaceId: "zs1JP9sA",
          lastStreamState: "streaming",
        },
        raw: {
          cpuExceptionDiagnostics: [
            {
              callStackTree: {
                callStacks: [
                  {
                    callStackRootFrames: [
                      {
                        binaryName: "Oppi",
                        binaryUUID: frameUUID,
                        address: 0x100001000,
                        offsetIntoBinaryTextSegment: 0x1000,
                        sampleCount: 7,
                      },
                    ],
                  },
                ],
              },
            },
          ],
        },
      },
    ],
  };

  writeFileSync(join(telemetryDir, "metrickit-2026-06-19.jsonl"), `${JSON.stringify(record)}\n`);
}

describe("metrickit-review", () => {
  let dataDir: string;
  let binDir: string;
  let originalPath: string | undefined;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-metrickit-review-"));
    binDir = mkdtempSync(join(tmpdir(), "oppi-fake-xcrun-"));
    originalPath = process.env.PATH;
    writeFakeXcrun(binDir);
    process.env.PATH = `${binDir}:${originalPath ?? ""}`;
    vi.spyOn(Date, "now").mockReturnValue(Date.UTC(2026, 5, 19, 13, 0, 0));
  });

  afterEach(() => {
    vi.restoreAllMocks();
    process.env.PATH = originalPath;
    rmSync(dataDir, { recursive: true, force: true });
    rmSync(binDir, { recursive: true, force: true });
  });

  it("resolves xcarchive dSYM paths and reports UUID mismatches", () => {
    writeMetricKitRecord(dataDir, MISMATCHED_UUID);

    const archivePath = join(dataDir, "Oppi.xcarchive");
    const dwarfPath = join(
      archivePath,
      "dSYMs",
      "Oppi.app.dSYM",
      "Contents",
      "Resources",
      "DWARF",
      "Oppi",
    );
    mkdirSync(dirname(dwarfPath), { recursive: true });
    writeFileSync(dwarfPath, "fake dwarf binary");

    const review = buildMetricKitReview({
      dataDir,
      days: 14,
      limit: 10,
      symbolicatePath: archivePath,
    });

    expect(review.symbolicationTarget?.binaryPath).toBe(dwarfPath);
    expect(review.symbolicationTarget?.uuids).toEqual([MATCHING_UUID]);
    expect(review.recentDiagnostics).toHaveLength(1);
    expect(review.recentDiagnostics[0]?.sessionId).toBe("Cu8iRTsq");
    expect(review.recentDiagnostics[0]?.appFrames[0]?.symbolicationIssue).toBe("uuid_mismatch");
    expect(review.recentDiagnostics[0]?.appFrames[0]?.symbolicationTargetUUIDs).toEqual([
      MATCHING_UUID,
    ]);
  });

  it("symbolicates app frames when the dSYM UUID matches", () => {
    writeMetricKitRecord(dataDir, MATCHING_UUID);

    const appPath = join(dataDir, "Oppi.app");
    const binaryPath = join(appPath, "Oppi");
    mkdirSync(appPath, { recursive: true });
    writeFileSync(binaryPath, "fake app binary");

    const review = buildMetricKitReview({
      dataDir,
      days: 14,
      limit: 10,
      symbolicatePath: appPath,
    });

    expect(review.symbolicationTarget?.binaryPath).toBe(binaryPath);
    expect(review.recentDiagnostics[0]?.appFrames[0]?.symbolicated).toBe(
      "Oppi.expandedStreamingRender() (in Oppi)",
    );
    expect(review.recentDiagnostics[0]?.appFrames[0]?.symbolicationIssue).toBeUndefined();
  });
});

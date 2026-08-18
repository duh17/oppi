import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { RETIRED_RUNTIME_STATUS_FILENAME, removeRetiredRuntimeStatusFile } from "../src/version.js";

describe("removeRetiredRuntimeStatusFile", () => {
  it("deletes a leftover runtime-status.json and leaves other data-dir files", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-runtime-status-"));
    const statusPath = join(dataDir, RETIRED_RUNTIME_STATUS_FILENAME);
    const keepPath = join(dataDir, "config.json");
    writeFileSync(
      statusPath,
      JSON.stringify({
        canUpdate: true,
        currentVersion: "unknown",
        lastCheckedAt: 1,
        latestVersion: "0.64.0",
        packageName: "@mariozechner/pi-coding-agent",
      }),
    );
    writeFileSync(keepPath, "{}\n");

    expect(removeRetiredRuntimeStatusFile(dataDir)).toBe(true);
    expect(removeRetiredRuntimeStatusFile(dataDir)).toBe(false);
    expect(() => readFileSync(statusPath)).toThrow();
    expect(readFileSync(keepPath, "utf-8")).toBe("{}\n");
  });

  it("is a no-op when the leftover file is absent or not a file", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-runtime-status-missing-"));
    expect(removeRetiredRuntimeStatusFile(dataDir)).toBe(false);

    const dirPath = join(dataDir, RETIRED_RUNTIME_STATUS_FILENAME);
    mkdirSync(dirPath);
    expect(removeRetiredRuntimeStatusFile(dataDir)).toBe(false);
  });
});

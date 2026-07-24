import { afterEach, describe, expect, it, vi } from "vitest";

import { cmdWait, parseDurationMs } from "../src/cli/commands/wait.js";
import type { Storage } from "../src/storage.js";

describe("parseDurationMs", () => {
  it.each([
    ["900", 900_000],
    ["1", 1_000],
    ["0", 0],
  ] as const)("treats bare number %s as seconds for CLI wait/timeout flags", (raw, expectedMs) => {
    // Help advertises --timeout <s>; bare values must not silently collapse to milliseconds.
    expect(parseDurationMs(raw)).toBe(expectedMs);
  });

  it.each([
    ["500ms", 500],
    ["15s", 15_000],
    ["5m", 300_000],
    ["1h", 3_600_000],
    ["1d", 86_400_000],
    [" 2s ", 2_000],
  ] as const)("parses explicit unit %s", (raw, expectedMs) => {
    expect(parseDurationMs(raw)).toBe(expectedMs);
  });

  it("rejects malformed durations", () => {
    expect(() => parseDurationMs("900sec")).toThrow(/Duration must look like/);
    expect(() => parseDurationMs("")).toThrow(/Duration must look like/);
  });
});

describe("cmdWait", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });
  it("rejects managed self-targeting before calling the local API", async () => {
    const getToken = vi.fn(() => {
      throw new Error("should not poll");
    });
    const storage = { getToken } as unknown as Storage;
    const previousCallerSessionId = process.env.OPPI_CALLER_SESSION_ID;
    const previousExitCode = process.exitCode;
    const write = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

    try {
      process.env.OPPI_CALLER_SESSION_ID = "sess-1";
      process.exitCode = undefined;
      await cmdWait(storage, "session", ["sess-1"], { json: "true" });

      expect(getToken).not.toHaveBeenCalled();
      expect(process.exitCode).toBe(1);
      expect(JSON.parse(write.mock.calls.map((call) => String(call[0])).join(""))).toEqual({
        ok: false,
        error: { message: "Cannot target the calling Oppi session (sess-1)" },
      });
    } finally {
      write.mockRestore();
      process.exitCode = previousExitCode;
      if (previousCallerSessionId === undefined) delete process.env.OPPI_CALLER_SESSION_ID;
      else process.env.OPPI_CALLER_SESSION_ID = previousCallerSessionId;
    }
  });

  it("rejects a zero poll interval before calling the local API", async () => {
    const getToken = vi.fn(() => {
      throw new Error("should not poll");
    });
    const storage = { getToken } as unknown as Storage;
    const previousExitCode = process.exitCode;
    const write = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

    try {
      process.exitCode = undefined;
      await cmdWait(storage, "session", ["sess-1"], { poll: "0ms", json: "true" });

      expect(getToken).not.toHaveBeenCalled();
      expect(process.exitCode).toBe(1);
      expect(JSON.parse(write.mock.calls.map((call) => String(call[0])).join(""))).toEqual({
        ok: false,
        error: { message: "--poll must be a positive duration" },
      });
    } finally {
      write.mockRestore();
      process.exitCode = previousExitCode;
    }
  });
});

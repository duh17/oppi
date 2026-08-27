import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { cmdWait, parseDurationMs } from "../src/cli/commands/wait.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";
import type { Storage } from "../src/storage.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const UUID_A = "019e1fff-5555-7555-8555-555555555555";
const UUID_B = "019e1fff-6666-7666-8666-666666666666";
const request = vi.mocked(localApiRequest);
const storage = {} as LocalApiConnection;

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
  beforeEach(() => {
    request.mockReset();
    process.exitCode = undefined;
  });

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

  it("resolves a unique Session.id prefix before polling GET /sessions/:id", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A, status: "ready" }, { id: UUID_B, status: "ready" }] };
      }
      if (path === `/sessions/${UUID_A}`) {
        return { session: { id: UUID_A, status: "stopped" } };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdWait(storage, "session", ["019e1fff-5555"], { status: "stopped", json: "true" }),
    );

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: true,
      data: { session: { id: UUID_A }, matchedStatus: "stopped" },
    });
    expect(paths).toEqual(["/sessions", `/sessions/${UUID_A}`]);
  });

  it("fails an ambiguous prefix without polling a session route", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }, { id: UUID_B }] };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdWait(storage, "session", ["019e1fff"], { json: "true" }),
    );

    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout).ok).toBe(false);
    expect(JSON.parse(stdout).error.message).toContain("Ambiguous session prefix '019e1fff'");
    expect(JSON.parse(stdout).error.message).toContain(UUID_A);
    expect(JSON.parse(stdout).error.message).toContain(UUID_B);
    expect(paths).toEqual(["/sessions"]);
  });

  it("fails an unknown prefix without polling a session route", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }] };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdWait(storage, "session", ["deadbeef"], { json: "true" }),
    );

    expect(exitCode).toBe(1);
    expect(JSON.parse(stdout)).toMatchObject({
      ok: false,
      error: {
        message: "Session not found: deadbeef",
        status: 404,
        code: "session_not_found",
        exit_code: 1,
      },
    });
    expect(paths).toEqual(["/sessions"]);
  });

  it("rejects a prefix that uniquely resolves to the calling session", async () => {
    const previousCallerSessionId = process.env.OPPI_CALLER_SESSION_ID;
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }, { id: UUID_B }] };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    try {
      process.env.OPPI_CALLER_SESSION_ID = UUID_A;
      const { stdout, exitCode } = await captureCliOutput(() =>
        cmdWait(storage, "session", ["019e1fff-5555"], { json: "true" }),
      );

      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout)).toMatchObject({
        ok: false,
        error: { message: `Cannot target the calling Oppi session (${UUID_A})` },
      });
      expect(paths).toEqual(["/sessions"]);
    } finally {
      if (previousCallerSessionId === undefined) delete process.env.OPPI_CALLER_SESSION_ID;
      else process.env.OPPI_CALLER_SESSION_ID = previousCallerSessionId;
    }
  });
});

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { cmdSchedule } from "../src/cli/commands/schedule.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const UUID_A = "019e1fff-5555-7555-8555-555555555555";
const UUID_B = "019e1fff-6666-7666-8666-666666666666";
const request = vi.mocked(localApiRequest);
const storage = {} as LocalApiConnection;

describe("schedule session targeting", () => {
  beforeEach(() => {
    request.mockReset();
    process.exitCode = undefined;
  });

  it("resolves schedule create --session before GET /sessions/:id and POST", async () => {
    const calls: Array<{ path: string; body?: unknown }> = [];
    request.mockImplementation(async (_conn, path, options) => {
      calls.push({ path, body: options?.body });
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A, workspaceId: "ws-1" }, { id: UUID_B }] };
      }
      if (path === `/sessions/${UUID_A}`) {
        return { session: { id: UUID_A, workspaceId: "ws-1" } };
      }
      if (path === "/schedules") {
        return { schedule: { id: "sch-1", status: "active" } };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { stdout, exitCode } = await captureCliOutput(() =>
      cmdSchedule(storage, "create", [], {
        session: "019e1fff-5555",
        prompt: "check tests",
        every: "1h",
        json: "true",
      }),
    );

    expect(exitCode).toBe(0);
    expect(JSON.parse(stdout).ok).toBe(true);
    expect(calls.map((call) => call.path)).toEqual([
      "/sessions",
      `/sessions/${UUID_A}`,
      "/schedules",
    ]);
    expect(calls[2]?.body).toMatchObject({
      action: { type: "existing_session", workspaceId: "ws-1", sessionId: UUID_A },
    });
  });

  it("resolves schedule list --session before the query string", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }, { id: UUID_B }] };
      }
      if (path === `/schedules?sessionId=${UUID_A}`) {
        return { schedules: [] };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { exitCode } = await captureCliOutput(() =>
      cmdSchedule(storage, "list", [], { session: "019e1fff-5555", json: "true" }),
    );

    expect(exitCode).toBe(0);
    expect(paths).toEqual(["/sessions", `/schedules?sessionId=${UUID_A}`]);
  });

  it("resolves action.sessionId from schedule update --definition-json before PATCH", async () => {
    const calls: Array<{ path: string; body?: unknown }> = [];
    request.mockImplementation(async (_conn, path, options) => {
      calls.push({ path, body: options?.body });
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }, { id: UUID_B }] };
      }
      if (path === "/schedules/sch-1") {
        return { schedule: { id: "sch-1", status: "active" } };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { exitCode } = await captureCliOutput(() =>
      cmdSchedule(storage, "update", ["sch-1"], {
        "definition-json": JSON.stringify({
          action: { type: "existing_session", sessionId: "019e1fff-5555" },
        }),
        json: "true",
      }),
    );

    expect(exitCode).toBe(0);
    expect(calls.map((call) => call.path)).toEqual(["/sessions", "/schedules/sch-1"]);
    expect(calls[1]?.body).toEqual({
      action: { type: "existing_session", sessionId: UUID_A },
    });
  });

  it("resolves action.sessionId from schedule update --definition before PATCH", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-schedule-session-id-"));
    const definitionPath = join(dir, "schedule.json");
    writeFileSync(
      definitionPath,
      JSON.stringify({ action: { type: "existing_session", sessionId: "019e1fff-5555" } }),
    );
    const calls: Array<{ path: string; body?: unknown }> = [];
    request.mockImplementation(async (_conn, path, options) => {
      calls.push({ path, body: options?.body });
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }, { id: UUID_B }] };
      }
      if (path === "/schedules/sch-1") {
        return { schedule: { id: "sch-1", status: "active" } };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    try {
      const { exitCode } = await captureCliOutput(() =>
        cmdSchedule(storage, "update", ["sch-1"], {
          definition: definitionPath,
          json: "true",
        }),
      );

      expect(exitCode).toBe(0);
      expect(calls.map((call) => call.path)).toEqual(["/sessions", "/schedules/sch-1"]);
      expect(calls[1]?.body).toEqual({
        action: { type: "existing_session", sessionId: UUID_A },
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not list sessions when schedule update has no action.sessionId", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/schedules/sch-1") {
        return { schedule: { id: "sch-1", status: "active" } };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { exitCode } = await captureCliOutput(() =>
      cmdSchedule(storage, "update", ["sch-1"], {
        "definition-json": JSON.stringify({ name: "Renamed" }),
        json: "true",
      }),
    );

    expect(exitCode).toBe(0);
    expect(paths).toEqual(["/schedules/sch-1"]);
  });

  it("does not prefix-match schedule ids", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/schedules/sch-pre") {
        return { schedule: { id: "sch-pre", status: "active" } };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const { exitCode } = await captureCliOutput(() =>
      cmdSchedule(storage, "get", ["sch-pre"], { json: "true" }),
    );

    expect(exitCode).toBe(0);
    expect(paths).toEqual(["/schedules/sch-pre"]);
  });

  it("fails an ambiguous schedule --session prefix without calling schedule routes", async () => {
    const paths: string[] = [];
    request.mockImplementation(async (_conn, path) => {
      paths.push(path);
      if (path === "/sessions") {
        return { sessions: [{ id: UUID_A }, { id: UUID_B }] };
      }
      throw new Error(`unexpected CLI path ${path}`);
    });

    const create = await captureCliOutput(() =>
      cmdSchedule(storage, "create", [], {
        session: "019e1fff",
        prompt: "check tests",
        every: "1h",
        json: "true",
      }),
    );
    expect(create.exitCode).toBe(1);
    expect(JSON.parse(create.stdout).error.message).toContain("Ambiguous session prefix '019e1fff'");
    expect(paths).toEqual(["/sessions"]);

    paths.length = 0;
    const list = await captureCliOutput(() =>
      cmdSchedule(storage, "list", [], { session: "019e1fff", json: "true" }),
    );
    expect(list.exitCode).toBe(1);
    expect(JSON.parse(list.stdout).error.message).toContain("Ambiguous session prefix '019e1fff'");
    expect(paths).toEqual(["/sessions"]);
  });
});

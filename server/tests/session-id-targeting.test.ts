import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { cmdSession } from "../src/cli/commands/session.js";
import { resolveHelpTopic } from "../src/cli/help.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const PI_SESSION_ID = "019e1fff-5555-7555-8555-555555555555";
const PI_SESSION_ID_B = "019e1fff-6666-7666-8666-666666666666";
const WRAPPER_ID = "cGEcSBwD";
const LEFTOVER_WRAPPER_ID = "RleHDYBu";
const request = vi.mocked(localApiRequest);
const storage = {} as LocalApiConnection;

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: PI_SESSION_ID,
    workspaceId: "ws-1",
    status: "stopped",
    createdAt: 1,
    lastActivity: 2,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

describe("session targeting uses Pi-native Session.id", () => {
  describe("HTTP lookup", () => {
    it("GET /sessions/:id, workspace inspect, and resume resolve Session.id only", async () => {
      const session = makeSession();
      const getSession = vi.fn((id: string) => (id === session.id ? session : undefined));
      const startSession = vi.fn(async () => ({ ...session, status: "ready" as const }));
      const ctx = {
        storage: {
          getSession,
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          getDataDir: vi.fn(() => tmpdir()),
        },
        sessions: { startSession },
        sessionRuntimes: {
          isSessionConnected: vi.fn(() => false),
          refreshSessionState: vi.fn(async () => undefined),
        },
        ensureSessionContextWindow: vi.fn((value: Session) => value),
      } as unknown as RouteContext;
      const dispatch = createSessionRoutes(ctx, createRouteHelpers());

      const getRes = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: `/sessions/${PI_SESSION_ID}`,
          url: new URL(`http://localhost/sessions/${PI_SESSION_ID}`),
          req: {} as never,
          res: getRes as never,
        }),
      ).toBe(true);
      expect(getRes.statusCode).toBe(200);
      expect(JSON.parse(getRes.body).session.id).toBe(PI_SESSION_ID);
      expect(JSON.parse(getRes.body).session).not.toHaveProperty("piSessionId");
      expect(getSession).toHaveBeenCalledWith(PI_SESSION_ID);

      const inspectRes = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: `/workspaces/ws-1/sessions/${PI_SESSION_ID}`,
          url: new URL(`http://localhost/workspaces/ws-1/sessions/${PI_SESSION_ID}`),
          req: {} as never,
          res: inspectRes as never,
        }),
      ).toBe(true);
      expect(inspectRes.statusCode).toBe(200);
      expect(JSON.parse(inspectRes.body).session.id).toBe(PI_SESSION_ID);
      expect(getSession).toHaveBeenCalledWith(PI_SESSION_ID);

      const resumeRes = makeResponse();
      expect(
        await dispatch({
          method: "POST",
          path: `/workspaces/ws-1/sessions/${PI_SESSION_ID}/resume`,
          url: new URL(`http://localhost/workspaces/ws-1/sessions/${PI_SESSION_ID}/resume`),
          req: {} as never,
          res: resumeRes as never,
        }),
      ).toBe(true);
      expect(resumeRes.statusCode).toBe(200);
      expect(JSON.parse(resumeRes.body).session.id).toBe(PI_SESSION_ID);
      expect(getSession).toHaveBeenCalledWith(PI_SESSION_ID);
      expect(startSession).toHaveBeenCalledWith(PI_SESSION_ID, expect.anything());
    });

    it("GET /control-sessions/:id looks up Session.id only", async () => {
      const session = makeSession({
        workspaceId: undefined,
        control: { domain: "agents", intent: "create" },
      });
      const getSession = vi.fn((id: string) => (id === session.id ? session : undefined));
      const ctx = {
        storage: {
          getSession,
          getDataDir: vi.fn(() => tmpdir()),
        },
        sessionRuntimes: {
          refreshSessionState: vi.fn(async () => undefined),
        },
        ensureSessionContextWindow: vi.fn((value: Session) => value),
      } as unknown as RouteContext;
      const dispatch = createSessionRoutes(ctx, createRouteHelpers());

      const getRes = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: `/control-sessions/${PI_SESSION_ID}`,
          url: new URL(`http://localhost/control-sessions/${PI_SESSION_ID}`),
          req: {} as never,
          res: getRes as never,
        }),
      ).toBe(true);
      expect(getRes.statusCode).toBe(200);
      expect(JSON.parse(getRes.body).session.id).toBe(PI_SESSION_ID);
      expect(getSession).toHaveBeenCalledWith(PI_SESSION_ID);

      const wrapperRes = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: `/control-sessions/${WRAPPER_ID}`,
          url: new URL(`http://localhost/control-sessions/${WRAPPER_ID}`),
          req: {} as never,
          res: wrapperRes as never,
        }),
      ).toBe(true);
      expect(wrapperRes.statusCode).toBe(404);
      expect(getSession).toHaveBeenCalledWith(WRAPPER_ID);
    });

    it("does not resolve a leftover wrapper id or piSessionId alias", async () => {
      const session = makeSession();
      const getSession = vi.fn((id: string) => (id === session.id ? session : undefined));
      const ctx = {
        storage: {
          getSession,
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        },
        sessionRuntimes: {
          isSessionConnected: vi.fn(() => false),
        },
        ensureSessionContextWindow: vi.fn((value: Session) => value),
      } as unknown as RouteContext;
      const dispatch = createSessionRoutes(ctx, createRouteHelpers());

      const wrapperRes = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: `/sessions/${WRAPPER_ID}`,
          url: new URL(`http://localhost/sessions/${WRAPPER_ID}`),
          req: {} as never,
          res: wrapperRes as never,
        }),
      ).toBe(true);
      expect(wrapperRes.statusCode).toBe(404);
      expect(getSession).toHaveBeenCalledWith(WRAPPER_ID);
      expect(getSession).not.toHaveBeenCalledWith("pi-session-uuid");

      const aliasRes = makeResponse();
      expect(
        await dispatch({
          method: "POST",
          path: `/workspaces/ws-1/sessions/${WRAPPER_ID}/resume`,
          url: new URL(`http://localhost/workspaces/ws-1/sessions/${WRAPPER_ID}/resume`),
          req: {} as never,
          res: aliasRes as never,
        }),
      ).toBe(true);
      expect(aliasRes.statusCode).toBe(404);
      expect(getSession.mock.calls.flat()).toEqual([WRAPPER_ID, WRAPPER_ID]);
    });
  });

  describe("SQLite store", () => {
    const dirs: string[] = [];

    afterEachStoreCleanup(dirs);

    it("looks up the primary key Session.id and strips leftover piSessionId JSON", () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-session-id-target-"));
      dirs.push(dir);
      const store = new SessionSqliteStore(dir);
      const session = store.createSession("Target", "openai/gpt-5.4");
      store.saveSession({
        ...session,
        // leftover dual-ID field must not become a targeting alias
        ...({ piSessionId: PI_SESSION_ID } as Partial<Session>),
      } as Session);

      expect(session.id).not.toBe(WRAPPER_ID);
      expect(store.getSession(session.id)?.id).toBe(session.id);
      expect(store.getSession(session.id)).not.toHaveProperty("piSessionId");
      expect(store.getSession(PI_SESSION_ID)).toBeUndefined();
      expect(store.getSession(WRAPPER_ID)).toBeUndefined();
      store.close();
    });
  });

  describe("CLI positional targets", () => {
    beforeEach(() => {
      request.mockReset();
      process.exitCode = undefined;
    });

    it.each([
      {
        action: "get",
        flags: { json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}`],
      },
      {
        action: "send",
        flags: { text: "hello", json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/command`],
      },
      {
        action: "inspect",
        flags: { json: "true" },
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-outline`,
        ],
      },
      {
        action: "resume",
        flags: { json: "true" },
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/resume`,
        ],
      },
      {
        action: "wait",
        flags: { for: "idle", json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/events?since=0`],
      },
      {
        action: "stop",
        flags: { json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/stop`],
      },
      {
        action: "abort",
        flags: { json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/command`],
      },
      {
        action: "read",
        flags: { json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/read`],
      },
      {
        action: "events",
        flags: { json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/events`],
      },
      {
        action: "trace",
        flags: { json: "true" },
        expected: ["/sessions", `/sessions/${PI_SESSION_ID}/trace`],
      },
      {
        action: "delete",
        flags: { json: "true" },
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}`,
        ],
      },
      {
        action: "fork",
        flags: { entry: "entry-1", json: "true" },
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/fork`,
        ],
      },
      {
        action: "tool-output",
        flags: { json: "true" },
        extraPositional: ["tool-1"],
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/tool-output/tool-1`,
        ],
      },
      {
        action: "trace-page",
        flags: { json: "true" },
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-page`,
        ],
      },
      {
        action: "trace-outline",
        flags: { json: "true" },
        expected: [
          "/sessions",
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-outline`,
        ],
      },
    ])(
      "session $action targets the Pi UUID Session.id",
      async ({ action, flags, expected, extraPositional }) => {
        const paths: string[] = [];
        request.mockImplementation(async (_conn, path, options) => {
          paths.push(path);
          if (path === "/sessions") {
            return { sessions: [{ id: PI_SESSION_ID, workspaceId: "ws-1", status: "ready" }] };
          }
          if (path === `/sessions/${PI_SESSION_ID}`) {
            return { session: { id: PI_SESSION_ID, workspaceId: "ws-1", status: "ready" } };
          }
          if (path.startsWith(`/sessions/${PI_SESSION_ID}/events`)) {
            return {
              session: { id: PI_SESSION_ID, status: "ready", messageCount: 1, lastMessage: "done" },
              events: [],
              currentSeq: 1,
            };
          }
          if (path === `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-outline`) {
            return { outline: { entries: [] } };
          }
          if (path === `/workspaces/ws-1/sessions/${PI_SESSION_ID}/resume`) {
            return { session: { id: PI_SESSION_ID, status: "ready" } };
          }
          if (path === `/workspaces/ws-1/sessions/${PI_SESSION_ID}/fork`) {
            expect(options).toMatchObject({ method: "POST" });
            return { session: { id: PI_SESSION_ID, status: "ready" } };
          }
          if (path === `/workspaces/ws-1/sessions/${PI_SESSION_ID}`) {
            expect(options).toMatchObject({ method: "DELETE" });
            return { deleted: true };
          }
          if (path === `/workspaces/ws-1/sessions/${PI_SESSION_ID}/tool-output/tool-1`) {
            return { output: "ok" };
          }
          if (path === `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-page`) {
            return { entries: [] };
          }
          if (
            path === `/sessions/${PI_SESSION_ID}/read` ||
            path === `/sessions/${PI_SESSION_ID}/trace`
          ) {
            return { trace: [] };
          }
          if (path === `/sessions/${PI_SESSION_ID}/events`) {
            return { events: [], currentSeq: 0 };
          }
          if (path === `/sessions/${PI_SESSION_ID}/command`) {
            expect(options).toMatchObject({ method: "POST" });
            return { ok: true };
          }
          if (path === `/sessions/${PI_SESSION_ID}/stop`) {
            expect(options).toMatchObject({ method: "POST" });
            return { session: { id: PI_SESSION_ID, status: "stopped" } };
          }
          throw new Error(`unexpected CLI path ${path}`);
        });

        const { stdout, exitCode } = await captureCliOutput(() =>
          cmdSession(storage, action, [PI_SESSION_ID, ...(extraPositional ?? [])], flags),
        );

        expect(exitCode).toBe(0);
        expect(JSON.parse(stdout).ok).toBe(true);
        expect(paths).toEqual(expected);
        expect(paths.join("\n")).not.toContain(WRAPPER_ID);
      },
    );

    it("resolves a unique Session.id prefix before the command HTTP call", async () => {
      const paths: string[] = [];
      request.mockImplementation(async (_conn, path) => {
        paths.push(path);
        if (path === "/sessions") {
          return {
            sessions: [
              { id: PI_SESSION_ID, workspaceId: "ws-1", status: "ready" },
              { id: PI_SESSION_ID_B, workspaceId: "ws-1", status: "ready" },
            ],
          };
        }
        if (path === `/sessions/${PI_SESSION_ID}`) {
          return { session: { id: PI_SESSION_ID, workspaceId: "ws-1", status: "ready" } };
        }
        throw new Error(`unexpected CLI path ${path}`);
      });

      const { stdout, exitCode } = await captureCliOutput(() =>
        cmdSession(storage, "get", ["019e1fff-5555"], { json: "true" }),
      );

      expect(exitCode).toBe(0);
      expect(JSON.parse(stdout)).toMatchObject({
        ok: true,
        data: { session: { id: PI_SESSION_ID } },
      });
      expect(paths).toEqual(["/sessions", `/sessions/${PI_SESSION_ID}`]);
    });

    it("fails an ambiguous prefix and lists the full Session.ids", async () => {
      const paths: string[] = [];
      request.mockImplementation(async (_conn, path) => {
        paths.push(path);
        if (path === "/sessions") {
          return {
            sessions: [{ id: PI_SESSION_ID }, { id: PI_SESSION_ID_B }],
          };
        }
        throw new Error(`unexpected CLI path ${path}`);
      });

      const { stdout, exitCode } = await captureCliOutput(() =>
        cmdSession(storage, "send", ["019e1fff"], { text: "hello", json: "true" }),
      );

      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout).ok).toBe(false);
      expect(JSON.parse(stdout).error).toMatchObject({
        message: expect.stringContaining("Ambiguous session prefix '019e1fff'"),
        status: 409,
        code: "session_prefix_ambiguous",
        hint: "Pass more of the UUID until exactly one session matches.",
        exit_code: 1,
      });
      expect(JSON.parse(stdout).error.message).toContain(PI_SESSION_ID);
      expect(JSON.parse(stdout).error.message).toContain(PI_SESSION_ID_B);
      expect(paths).toEqual(["/sessions"]);
    });

    it("fails an unknown prefix without calling the session route", async () => {
      const paths: string[] = [];
      request.mockImplementation(async (_conn, path) => {
        paths.push(path);
        if (path === "/sessions") {
          return { sessions: [{ id: PI_SESSION_ID }] };
        }
        throw new Error(`unexpected CLI path ${path}`);
      });

      const { stdout, exitCode } = await captureCliOutput(() =>
        cmdSession(storage, "get", ["deadbeef"], { json: "true" }),
      );

      expect(exitCode).toBe(1);
      expect(JSON.parse(stdout)).toMatchObject({
        ok: false,
        error: {
          message: "Session not found: deadbeef",
          status: 404,
          code: "session_not_found",
          hint: "Use the full Session.id or a longer unique prefix. List ids with `oppi session list --json`.",
          exit_code: 1,
        },
      });
      expect(paths).toEqual(["/sessions"]);
    });

    it("treats a leftover short wrapper as exact Session.id only", async () => {
      const paths: string[] = [];
      request.mockImplementation(async (_conn, path) => {
        paths.push(path);
        if (path === "/sessions") {
          return {
            sessions: [
              {
                id: PI_SESSION_ID,
                workspaceId: "ws-1",
                piSessionId: LEFTOVER_WRAPPER_ID,
              },
              { id: WRAPPER_ID, workspaceId: "ws-1" },
            ],
          };
        }
        if (path === `/sessions/${WRAPPER_ID}`) {
          return { session: { id: WRAPPER_ID, workspaceId: "ws-1", status: "stopped" } };
        }
        throw new Error(`unexpected CLI path ${path}`);
      });

      const alias = await captureCliOutput(() =>
        cmdSession(storage, "get", [LEFTOVER_WRAPPER_ID], { json: "true" }),
      );
      expect(alias.exitCode).toBe(1);
      expect(JSON.parse(alias.stdout)).toMatchObject({
        ok: false,
        error: {
          message: `Session not found: ${LEFTOVER_WRAPPER_ID}`,
          status: 404,
          code: "session_not_found",
          exit_code: 1,
        },
      });
      expect(paths).toEqual(["/sessions"]);

      paths.length = 0;
      const exact = await captureCliOutput(() =>
        cmdSession(storage, "get", [WRAPPER_ID], { json: "true" }),
      );
      expect(exact.exitCode).toBe(0);
      expect(JSON.parse(exact.stdout)).toMatchObject({
        ok: true,
        data: { session: { id: WRAPPER_ID } },
      });
      expect(paths).toEqual(["/sessions", `/sessions/${WRAPPER_ID}`]);
    });

    it("resolves each wait target to a unique Session.id before live wait streaming", async () => {
      const paths: string[] = [];
      request.mockImplementation(async (_conn, path) => {
        paths.push(path);
        if (path === "/sessions") {
          return { sessions: [{ id: PI_SESSION_ID }, { id: PI_SESSION_ID_B }] };
        }
        if (path === `/sessions/${PI_SESSION_ID}/events?since=0`) {
          return {
            session: { id: PI_SESSION_ID, status: "ready", messageCount: 1, lastMessage: "done" },
            events: [],
            currentSeq: 1,
          };
        }
        throw new Error(`unexpected CLI path ${path}`);
      });

      const { stdout, exitCode } = await captureCliOutput(() =>
        cmdSession(storage, "wait", ["019e1fff-5555"], { for: "idle", json: "true" }),
      );

      expect(exitCode).toBe(0);
      expect(JSON.parse(stdout)).toMatchObject({
        ok: true,
        data: { session_id: PI_SESSION_ID, reason: "idle" },
      });
      expect(paths).toEqual(["/sessions", `/sessions/${PI_SESSION_ID}/events?since=0`]);
    });
  });
});

describe("session prefix help", () => {
  it("documents unique prefixes on session, wait, and schedule --session inputs", () => {
    expect(argumentSummary(["session", "get"])).toBe("session id or unique prefix");
    expect(argumentSummary(["session", "send"])).toBe("session id or unique prefix");
    expect(argumentSummary(["session", "wait"])).toBe(
      "one or more session ids or unique prefixes",
    );
    expect(argumentSummary(["session", "fork"])).toBe("source session id or unique prefix");
    expect(argumentSummary(["wait", "session"])).toBe("session id or unique prefix");
    expect(flagSummary(["schedule", "create"], "--session")).toBe(
      "existing session id or unique prefix to send future prompts to",
    );
    expect(flagSummary(["schedule", "list"], "--session")).toBe(
      "filter by existing-session id or unique prefix",
    );
    expect(resolveHelpTopic(["session"])?.notes?.join(" ")).toMatch(/unique Session\.id prefix/);
  });

  it("does not change schedule, agent, or workspace id help", () => {
    expect(argumentSummary(["schedule", "get"])).toBe("schedule id");
    expect(argumentSummary(["schedule", "update"])).toBe("schedule id");
    expect(argumentSummary(["agent", "get"])).toBe("agent id or unique name");
    expect(argumentSummary(["workspace", "get"])).toBe("workspace id or unique name");
  });
});

function argumentSummary(path: string[]): string | undefined {
  return resolveHelpTopic(path)?.arguments?.[0]?.summary;
}

function flagSummary(path: string[], name: string): string | undefined {
  return resolveHelpTopic(path)?.flags?.find((flag) => flag.name === name)?.summary;
}

function afterEachStoreCleanup(dirs: string[]): void {
  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}

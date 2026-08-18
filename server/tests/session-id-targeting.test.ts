import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { cmdSession } from "../src/cli/commands/session.js";
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
const WRAPPER_ID = "cGEcSBwD";
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
        expected: [`/sessions/${PI_SESSION_ID}`],
      },
      {
        action: "send",
        flags: { text: "hello", json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/command`],
      },
      {
        action: "inspect",
        flags: { json: "true" },
        expected: [
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-outline`,
        ],
      },
      {
        action: "resume",
        flags: { json: "true" },
        expected: [
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/resume`,
        ],
      },
      {
        action: "wait",
        flags: { for: "idle", json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/events?since=0`],
      },
      {
        action: "stop",
        flags: { json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/stop`],
      },
      {
        action: "abort",
        flags: { json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/command`],
      },
      {
        action: "read",
        flags: { json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/read`],
      },
      {
        action: "events",
        flags: { json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/events`],
      },
      {
        action: "trace",
        flags: { json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}/trace`],
      },
      {
        action: "delete",
        flags: { json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}`, `/workspaces/ws-1/sessions/${PI_SESSION_ID}`],
      },
      {
        action: "fork",
        flags: { entry: "entry-1", json: "true" },
        expected: [`/sessions/${PI_SESSION_ID}`, `/workspaces/ws-1/sessions/${PI_SESSION_ID}/fork`],
      },
      {
        action: "tool-output",
        flags: { json: "true" },
        extraPositional: ["tool-1"],
        expected: [
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/tool-output/tool-1`,
        ],
      },
      {
        action: "trace-page",
        flags: { json: "true" },
        expected: [
          `/sessions/${PI_SESSION_ID}`,
          `/workspaces/ws-1/sessions/${PI_SESSION_ID}/trace-page`,
        ],
      },
      {
        action: "trace-outline",
        flags: { json: "true" },
        expected: [
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
  });
});

function afterEachStoreCleanup(dirs: string[]): void {
  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}

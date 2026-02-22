import type { IncomingMessage } from "node:http";
import { Readable } from "node:stream";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createPolicyRoutes } from "../src/routes/policy.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import { createSkillRoutes } from "../src/routes/skills.js";
import { createStreamingRoutes } from "../src/routes/streaming.js";
import { createThemeRoutes } from "../src/routes/themes.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import type { RouteContext } from "../src/routes/types.js";

interface MockResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(status: number, headers: Record<string, string>): MockResponse {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

function makeRequest(body?: unknown): IncomingMessage {
  const text = body === undefined ? "" : JSON.stringify(body);
  const req = Readable.from(text ? [text] : []) as unknown as IncomingMessage & {
    socket?: { remoteAddress?: string };
  };
  req.socket = { remoteAddress: "127.0.0.1" };
  return req;
}

describe("routes modules", () => {
  describe("streaming module", () => {
    it("handles GET /stream/events in isolation", async () => {
      const ctx = {
        streamMux: {
          getUserStreamCatchUp: vi.fn(() => ({
            events: [{ type: "state", sessionId: "s1" }],
            currentSeq: 12,
            catchUpComplete: true,
          })),
        },
      } as unknown as RouteContext;

      const dispatch = createStreamingRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/stream/events",
        url: new URL("http://localhost/stream/events?since=4"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const body = JSON.parse(res.body) as {
        currentSeq: number;
        catchUpComplete: boolean;
        events: unknown[];
      };
      expect(body.currentSeq).toBe(12);
      expect(body.catchUpComplete).toBe(true);
      expect(body.events).toHaveLength(1);
    });

    it("validates /permissions/pending filters", async () => {
      const ctx = {
        gate: {
          getPendingForUser: vi.fn(() => []),
        },
        storage: {
          getSession: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createStreamingRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/permissions/pending",
        url: new URL("http://localhost/permissions/pending?sessionId=missing"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Session not found" });
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createStreamingRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/definitely/not-streaming",
        url: new URL("http://localhost/definitely/not-streaming"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });

  describe("identity module", () => {
    it("handles GET /me in isolation", async () => {
      const ctx = {
        storage: {
          getOwnerName: vi.fn(() => "Bob"),
        },
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/me",
        url: new URL("http://localhost/me"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body)).toEqual({ user: "owner", name: "Bob" });
    });

    it("validates POST /pair body", async () => {
      const ctx = {
        storage: {
          consumePairingToken: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/pair",
        url: new URL("http://localhost/pair"),
        req: makeRequest({}) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "pairingToken required" });
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createIdentityRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/identity/nope",
        url: new URL("http://localhost/identity/nope"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });

  describe("policy module", () => {
    it("handles GET /policy/fallback in isolation", async () => {
      const ctx = {
        gate: {
          getDefaultFallback: vi.fn(() => "ask" as const),
        },
      } as unknown as RouteContext;

      const dispatch = createPolicyRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/policy/fallback",
        url: new URL("http://localhost/policy/fallback"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body)).toEqual({ fallback: "ask" });
    });

    it("validates scope on GET /policy/rules", async () => {
      const dispatch = createPolicyRoutes({} as RouteContext, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/policy/rules",
        url: new URL("http://localhost/policy/rules?scope=bad"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({
        error: 'scope must be one of: "session", "workspace", "global"',
      });
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createPolicyRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/policy/nope",
        url: new URL("http://localhost/policy/nope"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });

  describe("skills module", () => {
    it("handles GET /skills in isolation", async () => {
      const ctx = {
        skillRegistry: {
          list: vi.fn(() => [{ name: "fetch", description: "Fetch URLs" }]),
        },
      } as unknown as RouteContext;

      const dispatch = createSkillRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/skills",
        url: new URL("http://localhost/skills"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const body = JSON.parse(res.body) as { skills: unknown[] };
      expect(body.skills).toHaveLength(1);
    });

    it("returns 404 for unknown skill detail", async () => {
      const ctx = {
        skillRegistry: {
          getDetail: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createSkillRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/skills/nonexistent",
        url: new URL("http://localhost/skills/nonexistent"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Skill not found" });
    });

    it("validates path param on skill file access", async () => {
      const ctx = {
        skillRegistry: {},
      } as unknown as RouteContext;

      const dispatch = createSkillRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/skills/fetch/file",
        url: new URL("http://localhost/skills/fetch/file"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "path parameter required" });
    });

    it("returns 403 for skill mutation endpoints", async () => {
      const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "DELETE",
        path: "/me/skills/some-skill",
        url: new URL("http://localhost/me/skills/some-skill"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(403);
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/other/path",
        url: new URL("http://localhost/other/path"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });

  describe("workspaces module", () => {
    it("handles GET /workspaces in isolation", async () => {
      const ctx = {
        storage: {
          ensureDefaultWorkspaces: vi.fn(),
          listWorkspaces: vi.fn(() => [
            { id: "ws-1", name: "Default", skills: [] },
          ]),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces",
        url: new URL("http://localhost/workspaces"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const body = JSON.parse(res.body) as { workspaces: unknown[] };
      expect(body.workspaces).toHaveLength(1);
    });

    it("returns 404 for nonexistent workspace", async () => {
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/missing",
        url: new URL("http://localhost/workspaces/missing"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Workspace not found" });
    });

    it("validates name on POST /workspaces", async () => {
      const ctx = {} as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces",
        url: new URL("http://localhost/workspaces"),
        req: makeRequest({ skills: ["fetch"] }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "name required" });
    });

    it("validates skills array on POST /workspaces", async () => {
      const ctx = {} as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces",
        url: new URL("http://localhost/workspaces"),
        req: makeRequest({ name: "Test" }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "skills array required" });
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createWorkspaceRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/not/a/workspace",
        url: new URL("http://localhost/not/a/workspace"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });

  describe("sessions module", () => {
    it("handles GET workspace sessions in isolation", async () => {
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          listSessions: vi.fn(() => [
            { id: "s1", workspaceId: "ws-1", name: "Session 1" },
          ]),
        },
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions",
        url: new URL("http://localhost/workspaces/ws-1/sessions"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const body = JSON.parse(res.body) as { sessions: unknown[]; workspace: unknown };
      expect(body.sessions).toHaveLength(1);
      expect(body.workspace).toBeDefined();
    });

    it("returns 404 for sessions in nonexistent workspace", async () => {
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/missing/sessions",
        url: new URL("http://localhost/workspaces/missing/sessions"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Workspace not found" });
    });

    it("returns 404 for tool output with missing session", async () => {
      const ctx = {
        storage: {
          getSession: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions/s1/tool-output/tc-1",
        url: new URL("http://localhost/workspaces/ws-1/sessions/s1/tool-output/tc-1"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
      expect(JSON.parse(res.body)).toEqual({ error: "Session not found" });
    });

    it("validates path param on session file access", async () => {
      const ctx = {
        storage: {
          getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions/s1/files",
        url: new URL("http://localhost/workspaces/ws-1/sessions/s1/files"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "path parameter required" });
    });

    it("validates since param on session events", async () => {
      const ctx = {
        storage: {
          getSession: vi.fn(() => ({ id: "s1" })),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/sessions/s1/events",
        url: new URL("http://localhost/workspaces/ws-1/sessions/s1/events?since=-5"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "since must be a non-negative integer" });
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createSessionRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/not/sessions",
        url: new URL("http://localhost/not/sessions"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });

  describe("themes module", () => {
    it("returns 404 for nonexistent theme", async () => {
      const ctx = {
        storage: {
          getDataDir: vi.fn(() => "/tmp/oppi-test-nonexistent"),
        },
      } as unknown as RouteContext;

      const dispatch = createThemeRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/themes/ghost",
        url: new URL("http://localhost/themes/ghost"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(404);
    });

    it("validates missing theme body on PUT", async () => {
      const ctx = {
        storage: {
          getDataDir: vi.fn(() => "/tmp/oppi-test-nonexistent"),
        },
      } as unknown as RouteContext;

      const dispatch = createThemeRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "PUT",
        path: "/themes/my-theme",
        url: new URL("http://localhost/themes/my-theme"),
        req: makeRequest({}) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "Missing theme object in body" });
    });

    it("validates missing colors on PUT", async () => {
      const ctx = {
        storage: {
          getDataDir: vi.fn(() => "/tmp/oppi-test-nonexistent"),
        },
      } as unknown as RouteContext;

      const dispatch = createThemeRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "PUT",
        path: "/themes/my-theme",
        url: new URL("http://localhost/themes/my-theme"),
        req: makeRequest({ theme: { name: "Test" } }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error: "Missing colors object" });
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createThemeRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/not/themes",
        url: new URL("http://localhost/not/themes"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });
});

import type { IncomingMessage } from "node:http";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createPolicyRoutes } from "../src/routes/policy.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import { createSkillRoutes } from "../src/routes/skills.js";
import { createStreamingRoutes } from "../src/routes/streaming.js";
import { createThemeRoutes } from "../src/routes/themes.js";
import { createTelemetryRoutes } from "../src/routes/telemetry.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import type { RouteContext } from "../src/routes/types.js";
import {
  CHAT_METRIC_NAME_VALUES,
  CHAT_METRIC_REGISTRY,
  telemetryUploadsEnabledFromEnv,
} from "../src/types.js";

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
  describe("shared telemetry constants", () => {
    it("keeps chat metric names unique", () => {
      expect(new Set(CHAT_METRIC_NAME_VALUES).size).toBe(CHAT_METRIC_NAME_VALUES.length);
    });

    it("keeps metric registry in parity with metric names", () => {
      expect(Object.keys(CHAT_METRIC_REGISTRY).sort()).toEqual([...CHAT_METRIC_NAME_VALUES].sort());
    });

    it("keeps iOS metric enum in parity with server metric names", () => {
      const metricModelsPath = join(
        process.cwd(),
        "..",
        "ios",
        "Oppi",
        "Core",
        "Services",
        "MetricKitModels.swift",
      );
      const source = readFileSync(metricModelsPath, "utf8");
      const iosMetricNames = [...source.matchAll(/case\s+\w+\s*=\s*"([^"]+)"/g)]
        .map((match) => match[1])
        .filter((metric) => metric.startsWith("chat.") || metric.startsWith("plot."));

      expect([...new Set(iosMetricNames)].sort()).toEqual([...CHAT_METRIC_NAME_VALUES].sort());
    });

    it("parses OPPI_TELEMETRY_MODE consistently", () => {
      expect(telemetryUploadsEnabledFromEnv(undefined)).toBe(true);
      expect(telemetryUploadsEnabledFromEnv("internal")).toBe(true);
      expect(telemetryUploadsEnabledFromEnv("PUBLIC")).toBe(false);
      expect(telemetryUploadsEnabledFromEnv("unknown-mode")).toBe(false);
    });
  });

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
          listWorkspaces: vi.fn(() => [{ id: "ws-1", name: "Default", skills: [] }]),
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
          listSessions: vi.fn(() => [{ id: "s1", workspaceId: "ws-1", name: "Session 1" }]),
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

    it("returns full tool output from disk", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-tool-output-full-"));
      try {
        const fullOutputPath = join(dataDir, "tc-1.full.txt");
        writeFileSync(fullOutputPath, "complete tool output", "utf8");

        const ctx = {
          storage: {
            getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
          },
          sessions: {
            getToolFullOutputPath: vi.fn(() => fullOutputPath),
          },
        } as unknown as RouteContext;

        const dispatch = createSessionRoutes(ctx, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "GET",
          path: "/workspaces/ws-1/sessions/s1/tool-output/tc-1/full",
          url: new URL("http://localhost/workspaces/ws-1/sessions/s1/tool-output/tc-1/full"),
          req: {} as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(JSON.parse(res.body)).toEqual({
          toolCallId: "tc-1",
          output: "complete tool output",
        });
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
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

    it("rejects client-log uploads when OPPI_TELEMETRY_MODE disables telemetry", async () => {
      const previousMode = process.env.OPPI_TELEMETRY_MODE;
      process.env.OPPI_TELEMETRY_MODE = "public";

      try {
        const dispatch = createSessionRoutes({} as RouteContext, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "POST",
          path: "/workspaces/ws-1/sessions/s1/client-logs",
          url: new URL("http://localhost/workspaces/ws-1/sessions/s1/client-logs"),
          req: makeRequest({
            generatedAt: Date.now(),
            entries: [
              {
                timestamp: Date.now(),
                level: "info",
                category: "Test",
                message: "hello",
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(403);
        expect(JSON.parse(res.body)).toEqual({
          error: "telemetry uploads disabled by OPPI_TELEMETRY_MODE",
        });
      } finally {
        if (previousMode === undefined) {
          delete process.env.OPPI_TELEMETRY_MODE;
        } else {
          process.env.OPPI_TELEMETRY_MODE = previousMode;
        }
      }
    });

    it("accepts client-log uploads and appends JSONL envelope", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-client-logs-"));
      const previousMode = process.env.OPPI_TELEMETRY_MODE;
      process.env.OPPI_TELEMETRY_MODE = "internal";

      try {
        const dispatch = createSessionRoutes(
          {
            storage: {
              getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
              getDataDir: vi.fn(() => dataDir),
              getOwnerName: vi.fn(() => "tester"),
            },
          } as unknown as RouteContext,
          createRouteHelpers(),
        );
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/workspaces/ws-1/sessions/s1/client-logs",
          url: new URL("http://localhost/workspaces/ws-1/sessions/s1/client-logs"),
          req: makeRequest({
            generatedAt,
            trigger: "manual",
            entries: [
              {
                timestamp: generatedAt,
                level: "info",
                category: "UI",
                message: "hello world",
                metadata: { source: "test" },
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);
        expect(JSON.parse(res.body)).toEqual({ ok: true, accepted: 1 });

        const logPath = join(dataDir, "client-logs", "s1.jsonl");
        const lines = readFileSync(logPath, "utf8").trim().split("\n");
        expect(lines).toHaveLength(1);
        const record = JSON.parse(lines[0]) as {
          sessionId: string;
          workspaceId?: string;
          entries: Array<{ message: string }>;
        };
        expect(record.sessionId).toBe("s1");
        expect(record.workspaceId).toBe("ws-1");
        expect(record.entries[0]?.message).toBe("hello world");
      } finally {
        if (previousMode === undefined) {
          delete process.env.OPPI_TELEMETRY_MODE;
        } else {
          process.env.OPPI_TELEMETRY_MODE = previousMode;
        }
        rmSync(dataDir, { recursive: true, force: true });
      }
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

  describe("telemetry module", () => {
    it("stores normalized MetricKit payloads in daily JSONL files", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-"));
      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/metrickit",
          url: new URL("http://localhost/telemetry/metrickit"),
          req: makeRequest({
            generatedAt,
            appVersion: "1.0.0",
            buildNumber: "1",
            payloads: [
              {
                kind: "metric",
                windowStartMs: generatedAt - 4_000,
                windowEndMs: generatedAt,
                summary: { kind: "metric", count: 2 },
                raw: { payload: "{" },
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);

        const dayFile = join(
          dataDir,
          "diagnostics",
          "telemetry",
          `metrickit-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
        );
        const lines = readFileSync(dayFile, "utf8").trim().split("\n");
        expect(lines).toHaveLength(1);

        const record = JSON.parse(lines[0]) as {
          appVersion?: string;
          payloadCount: number;
          payloads: Array<{ kind: string }>;
        };
        expect(record.appVersion).toBe("1.0.0");
        expect(record.payloadCount).toBe(1);
        expect(record.payloads[0]?.kind).toBe("metric");
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("stores normalized chat metric payloads in daily JSONL files", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-"));
      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt,
            appVersion: "1.0.0",
            samples: [
              {
                ts: generatedAt - 250,
                metric: "chat.ttft_ms",
                value: 812,
                unit: "ms",
                sessionId: "session-1",
                workspaceId: "workspace-1",
                tags: { phase: "baseline" },
              },
              {
                ts: generatedAt,
                metric: "chat.catchup_ring_miss",
                value: 1,
                unit: "count",
              },
              {
                ts: generatedAt + 15,
                metric: "chat.fresh_content_lag_ms",
                value: 420,
                unit: "ms",
                tags: { reason: "history_applied", cache: "1" },
              },
              {
                ts: generatedAt + 21,
                metric: "chat.subscribe_ack_ms",
                value: 88,
                unit: "ms",
                tags: { transport: "paired", status: "ok" },
              },
              {
                ts: generatedAt + 22,
                metric: "chat.queue_sync_ms",
                value: 52,
                unit: "ms",
                tags: { transport: "paired", status: "ok" },
              },
              {
                ts: generatedAt + 23,
                metric: "chat.connected_dispatch_ms",
                value: 24,
                unit: "ms",
                tags: { transport: "paired" },
              },
              {
                ts: generatedAt + 24,
                metric: "chat.session_message_count",
                value: 10,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 25,
                metric: "chat.session_input_tokens",
                value: 1_250,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 26,
                metric: "chat.session_output_tokens",
                value: 640,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 28,
                metric: "chat.session_mutating_tool_calls",
                value: 3,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 29,
                metric: "chat.session_files_changed",
                value: 2,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 30,
                metric: "chat.session_added_lines",
                value: 48,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 31,
                metric: "chat.session_removed_lines",
                value: 13,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 32,
                metric: "chat.session_context_tokens",
                value: 3_200,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 33,
                metric: "chat.session_context_window",
                value: 200_000,
                unit: "count",
                sessionId: "session-1",
                tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
              },
              {
                ts: generatedAt + 34,
                metric: "plot.axis_visible_tick_count",
                value: 5,
                unit: "count",
                tags: { tool: "plot" },
              },
              {
                ts: generatedAt + 31,
                metric: "plot.legend_item_count",
                value: 3,
                unit: "count",
              },
              {
                ts: generatedAt + 32,
                metric: "plot.scroll_enabled",
                value: 1,
                unit: "ratio",
              },
              {
                ts: generatedAt + 33,
                metric: "plot.auto_adjustments",
                value: 2,
                unit: "count",
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);

        const dayFile = join(
          dataDir,
          "diagnostics",
          "telemetry",
          `chat-metrics-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
        );
        const lines = readFileSync(dayFile, "utf8").trim().split("\n");
        expect(lines).toHaveLength(1);

        const record = JSON.parse(lines[0]) as {
          appVersion?: string;
          sampleCount: number;
          samples: Array<{ metric: string; value: number }>;
        };
        expect(record.appVersion).toBe("1.0.0");
        expect(record.sampleCount).toBe(19);
        expect(record.samples[0]?.metric).toBe("chat.ttft_ms");
        expect(record.samples[2]?.metric).toBe("chat.fresh_content_lag_ms");
        expect(record.samples[3]?.metric).toBe("chat.subscribe_ack_ms");
        expect(record.samples[4]?.metric).toBe("chat.queue_sync_ms");
        expect(record.samples[5]?.metric).toBe("chat.connected_dispatch_ms");
        expect(record.samples[6]?.metric).toBe("chat.session_message_count");
        expect(record.samples[7]?.metric).toBe("chat.session_input_tokens");
        expect(record.samples[8]?.metric).toBe("chat.session_output_tokens");
        expect(record.samples[9]?.metric).toBe("chat.session_mutating_tool_calls");
        expect(record.samples[10]?.metric).toBe("chat.session_files_changed");
        expect(record.samples[11]?.metric).toBe("chat.session_added_lines");
        expect(record.samples[12]?.metric).toBe("chat.session_removed_lines");
        expect(record.samples[13]?.metric).toBe("chat.session_context_tokens");
        expect(record.samples[14]?.metric).toBe("chat.session_context_window");
        expect(record.samples[15]?.metric).toBe("plot.axis_visible_tick_count");
        expect(record.samples[16]?.metric).toBe("plot.legend_item_count");
        expect(record.samples[17]?.metric).toBe("plot.scroll_enabled");
        expect(record.samples[18]?.metric).toBe("plot.auto_adjustments");
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("normalizes chat metric tag keys to snake_case", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-tag-normalize-"));
      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt,
            samples: [
              {
                ts: generatedAt,
                metric: "chat.voice_setup_ms",
                value: 210,
                unit: "ms",
                tags: {
                  traceEvents: "120",
                  trace_events: "999",
                  "HTTP-Status": "200",
                  " phase ": "total",
                  __status__: "ok",
                  already_snake: "1",
                  "%%%%": "ignored",
                },
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);

        const dayFile = join(
          dataDir,
          "diagnostics",
          "telemetry",
          `chat-metrics-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
        );
        const lines = readFileSync(dayFile, "utf8").trim().split("\n");
        expect(lines).toHaveLength(1);

        const record = JSON.parse(lines[0]) as {
          sampleCount: number;
          samples: Array<{ tags?: Record<string, string> }>;
        };
        expect(record.sampleCount).toBe(1);
        expect(record.samples[0]?.tags).toEqual({
          trace_events: "120",
          http_status: "200",
          phase: "total",
          status: "ok",
          already_snake: "1",
        });
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("rejects chat metrics payloads when all samples are invalid", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-invalid-"));
      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt,
            samples: [
              {
                ts: generatedAt,
                metric: "plot.not_real",
                value: 1,
                unit: "count",
              },
              {
                ts: generatedAt + 1,
                metric: "plot.scroll_enabled",
                value: 1,
                unit: "wat",
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(400);
        expect(JSON.parse(res.body)).toEqual({
          error: "samples must be a non-empty array of valid metrics",
        });
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("rejects chat metrics payloads when units don't match metric contracts", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-unit-contracts-"));
      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt,
            samples: [
              {
                ts: generatedAt,
                metric: "chat.ttft_ms",
                value: 250,
                unit: "count",
              },
              {
                ts: generatedAt + 1,
                metric: "plot.scroll_enabled",
                value: 1,
                unit: "count",
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(400);
        expect(JSON.parse(res.body)).toEqual({
          error: "samples must be a non-empty array of valid metrics",
        });
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("drops invalid chat metric samples while persisting valid plot metrics", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-mixed-"));
      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();
        const generatedAt = Date.now();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt,
            samples: [
              {
                ts: generatedAt,
                metric: "plot.scroll_enabled",
                value: 1,
                unit: "ratio",
              },
              {
                ts: generatedAt + 1,
                metric: "plot.unknown",
                value: 3,
                unit: "count",
              },
              {
                ts: generatedAt + 2,
                metric: "plot.legend_item_count",
                value: 3,
                unit: "banana",
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);

        const dayFile = join(
          dataDir,
          "diagnostics",
          "telemetry",
          `chat-metrics-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
        );
        const lines = readFileSync(dayFile, "utf8").trim().split("\n");
        expect(lines).toHaveLength(1);

        const record = JSON.parse(lines[0]) as {
          sampleCount: number;
          samples: Array<{ metric: string; unit: string; value: number }>;
        };
        expect(record.sampleCount).toBe(1);
        expect(record.samples[0]?.metric).toBe("plot.scroll_enabled");
        expect(record.samples[0]?.unit).toBe("ratio");
        expect(record.samples[0]?.value).toBe(1);
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("rejects telemetry uploads when OPPI_TELEMETRY_MODE disables telemetry", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-gate-"));
      const previousMode = process.env.OPPI_TELEMETRY_MODE;
      process.env.OPPI_TELEMETRY_MODE = "public";

      try {
        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const generatedAt = Date.now();

        const metrickitRes = makeResponse();
        const metrickitHandled = await dispatch({
          method: "POST",
          path: "/telemetry/metrickit",
          url: new URL("http://localhost/telemetry/metrickit"),
          req: makeRequest({
            generatedAt,
            payloads: [
              {
                kind: "metric",
                windowStartMs: generatedAt - 100,
                windowEndMs: generatedAt,
                summary: { key: "value" },
                raw: { payload: "{}" },
              },
            ],
          }) as never,
          res: metrickitRes as never,
        });

        expect(metrickitHandled).toBe(true);
        expect(metrickitRes.statusCode).toBe(403);
        expect(JSON.parse(metrickitRes.body)).toEqual({
          error: "telemetry uploads disabled by OPPI_TELEMETRY_MODE",
        });

        const chatRes = makeResponse();
        const chatHandled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt,
            samples: [
              {
                ts: generatedAt,
                metric: "chat.ttft_ms",
                value: 200,
                unit: "ms",
              },
            ],
          }) as never,
          res: chatRes as never,
        });

        expect(chatHandled).toBe(true);
        expect(chatRes.statusCode).toBe(403);
        expect(JSON.parse(chatRes.body)).toEqual({
          error: "telemetry uploads disabled by OPPI_TELEMETRY_MODE",
        });
      } finally {
        if (previousMode === undefined) {
          delete process.env.OPPI_TELEMETRY_MODE;
        } else {
          process.env.OPPI_TELEMETRY_MODE = previousMode;
        }
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("prunes old telemetry files based on retention window", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-prune-"));
      const previousRetention = process.env.OPPI_METRICKIT_RETENTION_DAYS;
      process.env.OPPI_METRICKIT_RETENTION_DAYS = "1";

      try {
        const telemetryDir = join(dataDir, "diagnostics", "telemetry");
        mkdirSync(telemetryDir, { recursive: true });

        const oldDate = new Date(Date.now() - 10 * 24 * 60 * 60 * 1_000);
        const oldPath = join(telemetryDir, `metrickit-${oldDate.toISOString().slice(0, 10)}.jsonl`);
        writeFileSync(oldPath, '{"legacy":true}\n');

        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/metrickit",
          url: new URL("http://localhost/telemetry/metrickit"),
          req: makeRequest({
            generatedAt: Date.now(),
            payloads: [
              {
                kind: "metric",
                windowStartMs: Date.now() - 2_000,
                windowEndMs: Date.now(),
                summary: { reason: "prune-test" },
                raw: { payload: "{}" },
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);

        const files = readdirSync(telemetryDir);
        expect(files.length).toBe(1);
        expect(files[0]).not.toContain(oldDate.toISOString().slice(0, 10));
      } finally {
        if (previousRetention === undefined) {
          delete process.env.OPPI_METRICKIT_RETENTION_DAYS;
        } else {
          process.env.OPPI_METRICKIT_RETENTION_DAYS = previousRetention;
        }
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("prunes old chat metrics files based on retention window", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-prune-"));
      const previousRetention = process.env.OPPI_CHAT_METRICS_RETENTION_DAYS;
      process.env.OPPI_CHAT_METRICS_RETENTION_DAYS = "1";

      try {
        const telemetryDir = join(dataDir, "diagnostics", "telemetry");
        mkdirSync(telemetryDir, { recursive: true });

        const oldDate = new Date(Date.now() - 12 * 24 * 60 * 60 * 1_000);
        const oldPath = join(
          telemetryDir,
          `chat-metrics-${oldDate.toISOString().slice(0, 10)}.jsonl`,
        );
        writeFileSync(oldPath, '{"legacy":true}\n');

        const ctx = {
          storage: {
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext;

        const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "POST",
          path: "/telemetry/chat-metrics",
          url: new URL("http://localhost/telemetry/chat-metrics"),
          req: makeRequest({
            generatedAt: Date.now(),
            samples: [
              {
                ts: Date.now(),
                metric: "chat.timeline_apply_ms",
                value: 32,
                unit: "ms",
              },
            ],
          }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);

        const files = readdirSync(telemetryDir);
        expect(files.length).toBe(1);
        expect(files[0]).not.toContain(oldDate.toISOString().slice(0, 10));
      } finally {
        if (previousRetention === undefined) {
          delete process.env.OPPI_CHAT_METRICS_RETENTION_DAYS;
        } else {
          process.env.OPPI_CHAT_METRICS_RETENTION_DAYS = previousRetention;
        }
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("returns false for unrelated routes", async () => {
      const dispatch = createTelemetryRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "GET",
        path: "/telemetry/missing",
        url: new URL("http://localhost/telemetry/missing"),
        req: {} as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
    });
  });
});

import type { IncomingMessage } from "node:http";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createPolicyRoutes } from "../src/routes/policy.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import { createUploadRoutes } from "../src/routes/uploads.js";
import { createSkillRoutes } from "../src/routes/skills.js";
import { createStreamingRoutes } from "../src/routes/streaming.js";
import { createThemeRoutes } from "../src/routes/themes.js";
import { createTelemetryRoutes } from "../src/routes/telemetry.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import type { RouteContext } from "../src/routes/types.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
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

function makeRawRequest(body: Buffer | string): IncomingMessage {
  const req = Readable.from([body]) as unknown as IncomingMessage & {
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
        "clients",
        "apple",
        "Oppi",
        "Core",
        "Services",
        "MetricKitModels.swift",
      );
      const source = readFileSync(metricModelsPath, "utf8");
      const iosMetricNames = [...source.matchAll(/case\s+\w+\s*=\s*"([^"]+)"/g)]
        .map((match) => match[1])
        .filter(
          (metric) =>
            metric.startsWith("chat.") ||
            metric.startsWith("plot.") ||
            metric.startsWith("device."),
        );

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

    it("includes uploadProtocol in GET /server/info", async () => {
      const ctx = {
        storage: {
          getConfig: vi.fn(() => ({
            configVersion: 2,
            uploadStore: {
              maxFileBytes: 123,
              maxTurnBytes: 456,
            },
          })),
          listWorkspaces: vi.fn(() => []),
          listSessions: vi.fn(() => []),
        },
        sessions: {
          getActiveSessionIds: vi.fn(() => new Set()),
        },
        skillRegistry: {
          list: vi.fn(() => []),
        },
        getRuntimeUpdateStatus: vi.fn().mockResolvedValue({ upToDate: true }),
        getModelCatalog: vi.fn(() => []),
        serverStartedAt: Date.now(),
        serverVersion: "test",
        piVersion: "test",
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as {
        uploadProtocol: { version: number; maxFileBytes: number; maxTurnBytes: number };
      };
      expect(body.uploadProtocol).toEqual({ version: 1, maxFileBytes: 123, maxTurnBytes: 456 });
    });

    it("handles GET /server/subagents in isolation", async () => {
      const ctx = {
        storage: {
          getConfig: vi.fn(() => ({
            extensions: {
              subagents: {
                maxDepth: 1,
                autoStopWhenDone: false,
                childIdleTimeoutMs: 300_000,
                startupGraceMs: 60_000,
                defaultWaitTimeoutMs: 1_800_000,
                modelPolicy: {
                  approvedModels: ["openai-codex/gpt-5.4-mini"],
                },
              },
            },
          })),
        },
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/server/subagents",
        url: new URL("http://localhost/server/subagents"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body).modelPolicy.approvedModels).toEqual([
        "openai-codex/gpt-5.4-mini",
      ]);
    });

    it("handles PUT /server/subagents in isolation", async () => {
      const updateConfig = vi.fn();
      const ctx = {
        storage: {
          getConfig: vi.fn(() => ({
            extensions: {
              subagents: {
                maxDepth: 1,
                autoStopWhenDone: false,
                childIdleTimeoutMs: 300_000,
                startupGraceMs: 60_000,
                defaultWaitTimeoutMs: 1_800_000,
                modelPolicy: {
                  approvedModels: ["openai-codex/gpt-5.4-mini"],
                  profiles: {
                    discovery: {
                      model: "openai-codex/gpt-5.4-mini",
                    },
                  },
                },
              },
            },
          })),
          updateConfig,
        },
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "PUT",
        path: "/server/subagents",
        url: new URL("http://localhost/server/subagents"),
        req: makeRequest({
          modelPolicy: {
            defaultModel: "openai-codex/gpt-5.4-mini",
            profiles: {
              review: {
                model: "openai-codex/gpt-5.4-mini",
              },
            },
          },
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(updateConfig).toHaveBeenCalled();
      expect(updateConfig.mock.calls[0][0].extensions.subagents.modelPolicy.defaultModel).toBe(
        "openai-codex/gpt-5.4-mini",
      );
      expect(
        updateConfig.mock.calls[0][0].extensions.subagents.modelPolicy.profiles.discovery,
      ).toBeUndefined();
      expect(
        updateConfig.mock.calls[0][0].extensions.subagents.modelPolicy.profiles.review.model,
      ).toBe("openai-codex/gpt-5.4-mini");
    });

    it("clears subagent model policy when PUT sends an empty policy object", async () => {
      const updateConfig = vi.fn();
      const ctx = {
        storage: {
          getConfig: vi.fn(() => ({
            extensions: {
              subagents: {
                maxDepth: 1,
                autoStopWhenDone: false,
                childIdleTimeoutMs: 300_000,
                startupGraceMs: 60_000,
                defaultWaitTimeoutMs: 1_800_000,
                modelPolicy: {
                  approvedModels: ["openai-codex/gpt-5.4-mini"],
                  defaultModel: "openai-codex/gpt-5.4-mini",
                  defaultThinking: "medium",
                  profiles: {
                    discovery: {
                      model: "openai-codex/gpt-5.4-mini",
                    },
                  },
                },
              },
            },
          })),
          updateConfig,
        },
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "PUT",
        path: "/server/subagents",
        url: new URL("http://localhost/server/subagents"),
        req: makeRequest({ modelPolicy: {} }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(updateConfig).toHaveBeenCalled();
      expect(updateConfig.mock.calls[0][0].extensions.subagents.modelPolicy).toEqual({});
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

    it("reports host path status", async () => {
      const root = mkdtempSync(join(tmpdir(), "oppi-host-path-route-"));
      try {
        const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "GET",
          path: "/host/path/status",
          url: new URL(`http://localhost/host/path/status?path=${encodeURIComponent(root)}`),
          req: {} as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);
        const body = JSON.parse(res.body) as { status: { exists: boolean; isDirectory: boolean } };
        expect(body.status.exists).toBe(true);
        expect(body.status.isDirectory).toBe(true);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    });

    it("creates host workspace directories only after confirmation", async () => {
      const root = join(homedir(), "workspace");
      const target = join(root, `oppi-host-create-route-${Date.now()}`);
      mkdirSync(root, { recursive: true });
      rmSync(target, { recursive: true, force: true });
      try {
        const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
        const unconfirmed = makeResponse();

        await dispatch({
          method: "POST",
          path: "/host/path/create",
          url: new URL("http://localhost/host/path/create"),
          req: makeRequest({ path: target }) as never,
          res: unconfirmed as never,
        });

        expect(unconfirmed.statusCode).toBe(400);
        expect(existsSync(target)).toBe(false);

        const confirmed = makeResponse();
        const handled = await dispatch({
          method: "POST",
          path: "/host/path/create",
          url: new URL("http://localhost/host/path/create"),
          req: makeRequest({ path: target, confirmed: true }) as never,
          res: confirmed as never,
        });

        expect(handled).toBe(true);
        expect(confirmed.statusCode).toBe(201);
        expect(existsSync(target)).toBe(true);
      } finally {
        rmSync(target, { recursive: true, force: true });
      }
    });

    it("rejects host directory creation outside workspace roots", async () => {
      const target = join(tmpdir(), `oppi-host-create-denied-${Date.now()}`);
      rmSync(target, { recursive: true, force: true });
      try {
        const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "POST",
          path: "/host/path/create",
          url: new URL("http://localhost/host/path/create"),
          req: makeRequest({ path: target, confirmed: true }) as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(403);
        expect(existsSync(target)).toBe(false);
      } finally {
        rmSync(target, { recursive: true, force: true });
      }
    });

    it("returns host path completions", async () => {
      const root = join(homedir(), "workspace", `oppi-host-complete-route-${Date.now()}`);
      const child = join(root, "project-alpha");
      rmSync(root, { recursive: true, force: true });
      mkdirSync(child, { recursive: true });
      try {
        const dispatch = createSkillRoutes({} as RouteContext, createRouteHelpers());
        const res = makeResponse();
        const prefix = join(root, "project-a");

        const handled = await dispatch({
          method: "GET",
          path: "/host/path/completions",
          url: new URL(
            `http://localhost/host/path/completions?prefix=${encodeURIComponent(prefix)}`,
          ),
          req: {} as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);
        const body = JSON.parse(res.body) as { completions: Array<{ path: string }> };
        expect(body.completions.map((item) => item.path)).toContain(child.replace(homedir(), "~"));
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
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
          listWorkspaces: vi.fn(() => [{ id: "ws-1", name: "Default", skills: [] }]),
          listWorkspaceSessionSummarySnapshots: vi.fn(() => [
            {
              workspaceId: "ws-1",
              activeCount: 1,
              stoppedCount: 2,
              hasErrorRoot: false,
              latestActivity: 1_700_000_000_000,
            },
          ]),
        },
        gate: { getPendingForUser: vi.fn(() => []) },
        sessions: { getActiveSessionIds: vi.fn(() => []) },
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

      const body = JSON.parse(res.body) as {
        workspaces: unknown[];
        summaries: Array<{ workspaceId: string; activeCount: number; stoppedCount: number }>;
      };
      expect(body.workspaces).toHaveLength(1);
      expect(body.summaries).toEqual([
        expect.objectContaining({ workspaceId: "ws-1", activeCount: 1, stoppedCount: 2 }),
      ]);
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

    it("handles GET /tui-sessions as the global TUI session list", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-tui-session-route-"));
      const testDir = join(getPiSessionsRoot(), "--test-route-tui-sessions--");
      const filePath = join(testDir, "2026-02-20T00-00-00-000Z_route-tui.jsonl");

      try {
        mkdirSync(testDir, { recursive: true });
        writeFileSync(
          filePath,
          [
            JSON.stringify({
              type: "session",
              id: "route-tui",
              cwd: "/tmp/project",
              timestamp: "2026-02-20T00:00:00.000Z",
            }),
            JSON.stringify({
              type: "session_info",
              name: "Route TUI Session",
            }),
          ].join("\n") + "\n",
        );

        const ctx = {
          storage: {
            listSessions: vi.fn(() => []),
            getDataDir: vi.fn(() => dataDir),
          },
        } as unknown as RouteContext;

        const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
        const res = makeResponse();

        const handled = await dispatch({
          method: "GET",
          path: "/tui-sessions",
          url: new URL("http://localhost/tui-sessions"),
          req: {} as never,
          res: res as never,
        });

        expect(handled).toBe(true);
        expect(res.statusCode).toBe(200);
        const body = JSON.parse(res.body) as { sessions: Array<{ piSessionId: string }> };
        expect(body.sessions.some((session) => session.piSessionId === "route-tui")).toBe(true);
      } finally {
        rmSync(testDir, { recursive: true, force: true });
        rmSync(dataDir, { recursive: true, force: true });
      }
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

    it("rejects missing hostMount on POST /workspaces", async () => {
      const missing = join(tmpdir(), `oppi-route-missing-workspace-${Date.now()}`);
      rmSync(missing, { recursive: true, force: true });
      const ctx = {
        skillRegistry: { get: vi.fn() },
        storage: { createWorkspace: vi.fn() },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces",
        url: new URL("http://localhost/workspaces"),
        req: makeRequest({ name: "Test", skills: [], hostMount: missing }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("Host working directory does not exist");
      expect(ctx.storage.createWorkspace).not.toHaveBeenCalled();
    });

    it("marks review comments sent via the review comments collection", async () => {
      const comment = { id: "rc-1", workspaceId: "ws-1", status: "sent" };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test", skills: [] })),
          markReviewCommentsSent: vi.fn(() => [comment]),
        },
      } as unknown as RouteContext;

      const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/review/comments/sent",
        url: new URL("http://localhost/workspaces/ws-1/review/comments/sent"),
        req: makeRequest({ ids: ["rc-1"], sessionId: "s1" }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      expect(ctx.storage.markReviewCommentsSent).toHaveBeenCalledWith("ws-1", {
        ids: ["rc-1"],
        sessionId: "s1",
      });
      expect(JSON.parse(res.body)).toEqual({ comments: [comment] });
    });

    it("does not handle the legacy review comments attach route", async () => {
      const dispatch = createWorkspaceRoutes({} as RouteContext, createRouteHelpers());

      const handled = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/review/comments/attach-to-turn",
        url: new URL("http://localhost/workspaces/ws-1/review/comments/attach-to-turn"),
        req: makeRequest({ ids: ["rc-1"] }) as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
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

  describe("uploads module", () => {
    it("creates and uploads content in isolation", async () => {
      const root = mkdtempSync(join(tmpdir(), "oppi-upload-routes-test-"));
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Workspace" })),
          getConfig: vi.fn(() => ({
            dataDir: root,
            uploadStore: {
              path: join(root, "uploads"),
              maxFileBytes: 1024 * 1024,
              maxTurnBytes: 2 * 1024 * 1024,
              unusedTtlMs: 60_000,
            },
          })),
        },
      } as unknown as RouteContext;

      const dispatch = createUploadRoutes(ctx, createRouteHelpers());

      const createRes = makeResponse();
      const created = await dispatch({
        method: "POST",
        path: "/workspaces/ws-1/uploads",
        url: new URL("http://localhost/workspaces/ws-1/uploads"),
        req: makeRequest({
          name: "note.txt",
          mimeType: "text/plain",
          sizeBytes: 5,
          purpose: "chat_attachment",
        }) as never,
        res: createRes as never,
      });

      expect(created).toBe(true);
      expect(createRes.statusCode).toBe(201);
      const createBody = JSON.parse(createRes.body) as { uploadId: string };
      expect(createBody.uploadId).toMatch(/^upl_/);

      const contentRes = makeResponse();
      const uploaded = await dispatch({
        method: "PUT",
        path: `/workspaces/ws-1/uploads/${createBody.uploadId}/content`,
        url: new URL(`http://localhost/workspaces/ws-1/uploads/${createBody.uploadId}/content`),
        req: makeRawRequest("hello") as never,
        res: contentRes as never,
      });

      expect(uploaded).toBe(true);
      expect(contentRes.statusCode).toBe(200);
      const contentBody = JSON.parse(contentRes.body) as {
        attachment: { source: string; sizeBytes: number; sha256?: string };
      };
      expect(contentBody.attachment.source).toBe("upload");
      expect(contentBody.attachment.sizeBytes).toBe(5);
      expect(contentBody.attachment.sha256).toBeTruthy();

      rmSync(root, { recursive: true, force: true });
    });
  });

  describe("sessions module", () => {
    it("handles GET workspace home in isolation", async () => {
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          listWorkspaceTimeRangeSessionSnapshots: vi.fn(() => [
            { id: "s1", workspaceId: "ws-1", name: "Session 1" },
          ]),
          listWorkspaceStoppedTimeBuckets: vi.fn(() => []),
          listSessions: vi.fn(() => []),
          getDataDir: vi.fn(() => tmpdir()),
        },
        sessions: {
          getActiveSessionIds: vi.fn(() => new Set()),
          getActiveSession: vi.fn(() => undefined),
          getPendingAskMessage: vi.fn(() => undefined),
        },
        gate: { getPendingForUser: vi.fn(() => []) },
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/home",
        url: new URL("http://localhost/workspaces/ws-1/home?sinceMs=0&untilMs=1000"),
        req: { url: "/workspaces/ws-1/home?sinceMs=0&untilMs=1000" } as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const body = JSON.parse(res.body) as {
        sessions: unknown[];
      };
      expect(body.sessions).toHaveLength(1);
    });

    it("merges active in-memory sessions into workspace snapshots", async () => {
      const activeSession = {
        id: "active-1",
        workspaceId: "ws-1",
        status: "busy",
        lastActivity: 20,
      };
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          listWorkspaceTimeRangeSessionSnapshots: vi.fn(() => []),
          listWorkspaceStoppedTimeBuckets: vi.fn(() => []),
          listSessions: vi.fn(() => []),
          getDataDir: vi.fn(() => tmpdir()),
        },
        sessions: {
          getActiveSessionIds: vi.fn(() => new Set(["active-1"])),
          getActiveSession: vi.fn(() => activeSession),
          getPendingAskMessage: vi.fn(() => undefined),
        },
        gate: { getPendingForUser: vi.fn(() => []) },
        ensureSessionContextWindow: vi.fn((s: unknown) => s),
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/home",
        url: new URL("http://localhost/workspaces/ws-1/home?sinceMs=0&untilMs=1000"),
        req: { url: "/workspaces/ws-1/home?sinceMs=0&untilMs=1000" } as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { sessions: Array<{ id: string }> };
      expect(body.sessions.map((session) => session.id)).toEqual(["active-1"]);
    });

    it("returns 404 for workspace home in nonexistent workspace", async () => {
      const ctx = {
        storage: {
          getWorkspace: vi.fn(() => undefined),
        },
      } as unknown as RouteContext;

      const dispatch = createSessionRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/missing/home",
        url: new URL("http://localhost/workspaces/missing/home?sinceMs=0&untilMs=1000"),
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
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
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
            getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
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
          path: "/workspaces/ws-1/sessions/s1/tool-output/tc-1",
          url: new URL("http://localhost/workspaces/ws-1/sessions/s1/tool-output/tc-1?full=true"),
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
          getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
          getSession: vi.fn(() => ({ id: "s1", workspaceId: "ws-1" })),
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

    it("does not handle theme writes", async () => {
      const ctx = {
        storage: {
          getDataDir: vi.fn(() => "/tmp/oppi-test-nonexistent"),
        },
      } as unknown as RouteContext;

      const dispatch = createThemeRoutes(ctx, createRouteHelpers());

      const handled = await dispatch({
        method: "PUT",
        path: "/themes/my-theme",
        url: new URL("http://localhost/themes/my-theme"),
        req: makeRequest({}) as never,
        res: makeResponse() as never,
      });

      expect(handled).toBe(false);
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
                ts: generatedAt + 22,
                metric: "chat.queue_sync_ms",
                value: 52,
                unit: "ms",
                tags: { transport: "paired", status: "ok" },
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
        expect(record.sampleCount).toBe(13);
        expect(record.samples[0]?.metric).toBe("chat.ttft_ms");
        expect(record.samples[2]?.metric).toBe("chat.fresh_content_lag_ms");
        expect(record.samples[3]?.metric).toBe("chat.queue_sync_ms");
        expect(record.samples[4]?.metric).toBe("chat.session_message_count");
        expect(record.samples[5]?.metric).toBe("chat.session_input_tokens");
        expect(record.samples[6]?.metric).toBe("chat.session_output_tokens");
        expect(record.samples[7]?.metric).toBe("chat.session_mutating_tool_calls");
        expect(record.samples[8]?.metric).toBe("chat.session_files_changed");
        expect(record.samples[9]?.metric).toBe("chat.session_added_lines");
        expect(record.samples[10]?.metric).toBe("chat.session_removed_lines");
        expect(record.samples[11]?.metric).toBe("chat.session_context_tokens");
        expect(record.samples[12]?.metric).toBe("chat.session_context_window");
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

    it("drops invalid chat metric samples while persisting valid ones", async () => {
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
                metric: "chat.ttft_ms",
                value: 120,
                unit: "ms",
              },
              {
                ts: generatedAt + 1,
                metric: "chat.unknown_metric",
                value: 3,
                unit: "count",
              },
              {
                ts: generatedAt + 2,
                metric: "chat.catchup_ms",
                value: 50,
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
        expect(record.samples[0]?.metric).toBe("chat.ttft_ms");
        expect(record.samples[0]?.unit).toBe("ms");
        expect(record.samples[0]?.value).toBe(120);
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

import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import type { Session, SessionThreadResponse } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let dir: string;
let store: SessionSqliteStore;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "oppi-session-threads-"));
  store = new SessionSqliteStore(dir);
});

afterEach(() => {
  vi.unstubAllEnvs();
  store.close();
  rmSync(dir, { recursive: true, force: true });
});

function seed(
  name: string,
  createdAt: number,
  parent?: Session,
  status: Session["status"] = "stopped",
): Session {
  const session = store.createSession(name);
  session.workspaceId = "ws-1";
  session.status = status;
  session.createdAt = createdAt;
  session.lastActivity = createdAt + 10;
  if (parent) {
    session.launch = {
      source: "agent",
      parentSessionId: parent.id,
      status: "created",
      requestedAt: createdAt,
    };
  }
  store.saveSession(session);
  return session;
}

function routes(
  cache: {
    models?: Record<string, { short?: number; long?: number }>;
    live?: Record<string, ReturnType<RouteContext["sessionRuntimes"]["getPromptCacheRuntime"]>>;
  } = {},
) {
  const ctx = {
    sessions: { mobileRenderer: new MobileRendererRegistry() },
    storage: store,
    sessionRuntimes: {
      isSessionConnected: () => false,
      getActiveSessionIds: () => new Set<string>(),
      getActiveSession: () => undefined,
      getPromptCacheRuntime: (id: string) => cache.live?.[id],
    },
    ensureSessionContextWindow: (session: Session) => session,
    getModelPromptCache: (model: string | undefined) => (model ? cache.models?.[model] : undefined),
  } as unknown as RouteContext;
  return { dispatch: createSessionRoutes(ctx, createRouteHelpers()) };
}

async function getThread(dispatch: ReturnType<typeof routes>["dispatch"], id: string) {
  const res = makeResponse();
  await dispatch({
    method: "GET",
    path: `/sessions/${id}/thread`,
    url: new URL(`http://localhost/sessions/${id}/thread`),
    req: makeRequest() as never,
    res: res as never,
  });
  return res;
}

describe("GET /sessions/:id/thread", () => {
  it("returns the whole launch tree from any member", async () => {
    const root = seed("Investigate Unfinished Sonnet Worktree", 1_000, undefined, "ready");
    const fix = seed("Fix: queue move banner", 2_000, root);
    const master = seed("Donkey Master", 3_000, root, "busy");
    const worker = seed("Worker P1s3", 4_000, master);
    const otherRoot = seed("Investigate iOS App Modularity", 500);
    seed("Sonnet max Markdown resource access", 600, otherRoot);
    const { dispatch } = routes();

    const res = await getThread(dispatch, worker.id);

    expect(res.statusCode).toBe(200);
    const thread = JSON.parse(res.body) as SessionThreadResponse;
    expect(thread.rootSessionId).toBe(root.id);
    expect(thread.sessions.map((s) => [s.name, s.parentSessionId])).toEqual([
      [root.name, undefined],
      [fix.name, root.id],
      [master.name, root.id],
      [worker.name, master.id],
    ]);
  });

  it.each([
    { retention: "short", rootTtlMs: 300_000, liveTtlMs: 600_000 },
    { retention: "long", rootTtlMs: 3_600_000, liveTtlMs: 7_200_000 },
  ] as const)(
    "reports $retention prompt-cache lifetimes from the live runtime first, then the model catalog",
    async ({ retention, rootTtlMs, liveTtlMs }) => {
      // The route reads PI_CACHE_RETENTION from the process; pin it so ambient env cannot change the tier.
      vi.stubEnv("PI_CACHE_RETENTION", retention);
      const root = seed("Orchestrator", 1_000, undefined, "ready");
      const live = seed("Worker", 2_000, root, "busy");
      const unknown = seed("Local model", 3_000, root);
      for (const [session, model, repliedAt] of [
        [root, "anthropic/claude-opus-5-5", 5_000],
        [live, "anthropic/claude-sonnet-5-5", 6_000],
        [unknown, "mlx-serve/ddalcu/Qwen3.8", 7_000],
      ] as const) {
        session.model = model;
        session.lastAgentReplyAt = repliedAt;
        store.saveSession(session);
      }
      const { dispatch } = routes({
        models: { "anthropic/claude-opus-5-5": { short: 300, long: 3600 } },
        live: {
          [live.id]: {
            warmer: { state: "scheduled", action: "warm", nextWarmAt: 9_000 },
            promptCache: { short: 600, long: 7200 },
          },
        },
      });

      const thread = JSON.parse((await getThread(dispatch, root.id)).body) as SessionThreadResponse;

      expect(thread.promptCache).toEqual({
        [root.id]: { retention, ttlMs: rootTtlMs, lastRequestAt: 5_000 },
        [live.id]: {
          retention,
          ttlMs: liveTtlMs,
          lastRequestAt: 6_000,
          warmer: { state: "scheduled", action: "warm", nextWarmAt: 9_000 },
        },
      });
    },
  );

  it("treats a child whose parent is gone as the root", async () => {
    const root = seed("Root", 1_000);
    const child = seed("Child", 2_000, root);
    const grandchild = seed("Grandchild", 3_000, child);
    store.deleteSession(root.id);
    const { dispatch } = routes();

    const thread = JSON.parse(
      (await getThread(dispatch, grandchild.id)).body,
    ) as SessionThreadResponse;

    expect(thread.rootSessionId).toBe(child.id);
    expect(thread.sessions.map((s) => s.id)).toEqual([child.id, grandchild.id]);
  });

  it("returns 404 for an unknown session", async () => {
    const { dispatch } = routes();
    expect((await getThread(dispatch, "nope")).statusCode).toBe(404);
  });
});

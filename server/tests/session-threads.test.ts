import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { mkdtempSync, rmSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import { OPPI_CALLER_SESSION_HEADER } from "../src/session-caller-identity.js";
import { interactionKindForCommand, recordCallerInteraction } from "../src/session-interactions.js";
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
  sendSteer = vi.fn(async (): Promise<void> => undefined),
  cache: {
    models?: Record<string, { short?: number; long?: number }>;
    live?: Record<string, ReturnType<RouteContext["sessionRuntimes"]["getPromptCacheRuntime"]>>;
  } = {},
) {
  const ctx = {
    sessions: { mobileRenderer: new MobileRendererRegistry() },
    storage: store,
    sessionRuntimes: {
      sendSteer,
      isSessionConnected: () => false,
      getActiveSessionIds: () => new Set<string>(),
      getActiveSession: () => undefined,
      getPromptCacheRuntime: (id: string) => cache.live?.[id],
    },
    ensureSessionContextWindow: (session: Session) => session,
    getModelPromptCache: (model: string | undefined) => (model ? cache.models?.[model] : undefined),
  } as unknown as RouteContext;
  return { dispatch: createSessionRoutes(ctx, createRouteHelpers()), sendSteer };
}

function withCaller(req: IncomingMessage, callerId?: string): IncomingMessage {
  (req as IncomingMessage & { headers: Record<string, string> }).headers = callerId
    ? { [OPPI_CALLER_SESSION_HEADER]: callerId }
    : {};
  return req;
}

async function send(
  dispatch: ReturnType<typeof routes>["dispatch"],
  path: string,
  body: unknown,
  callerId?: string,
) {
  const res = makeResponse();
  await dispatch({
    method: "POST",
    path,
    url: new URL(`http://localhost${path}`),
    req: withCaller(makeRequest(body), callerId) as never,
    res: res as never,
  });
  return res;
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

describe("session interaction recording", () => {
  it("records a successful command from a calling session", async () => {
    const caller = seed("Orchestrator", 1_000, undefined, "ready");
    const target = seed("Worker", 2_000, caller, "busy");
    const { dispatch, sendSteer } = routes();

    const res = await send(
      dispatch,
      `/sessions/${target.id}/command`,
      { type: "steer", message: "rebase first" },
      caller.id,
    );

    expect(res.statusCode).toBe(200);
    expect(sendSteer).toHaveBeenCalledOnce();
    const interactions = store.listSessionInteractions([target.id]);
    expect(interactions).toEqual([
      expect.objectContaining({ fromSessionId: caller.id, toSessionId: target.id, kind: "steer" }),
    ]);
  });

  it.each([
    ["no caller header", undefined, { type: "steer", message: "x" }],
    ["self-targeting caller", "target", { type: "steer", message: "x" }],
    ["unknown caller", "missing-session", { type: "steer", message: "x" }],
    ["unsupported command", "caller", { type: "future_command_v99" }],
  ])("records nothing for %s", async (_label, callerRef, body) => {
    const caller = seed("Orchestrator", 1_000, undefined, "ready");
    const target = seed("Worker", 2_000, caller, "busy");
    const { dispatch } = routes();
    const callerId =
      callerRef === "caller" ? caller.id : callerRef === "target" ? target.id : callerRef;

    await send(dispatch, `/sessions/${target.id}/command`, body, callerId);

    expect(store.listSessionInteractions([caller.id, target.id])).toEqual([]);
  });

  it("records nothing when the runtime rejects the command", async () => {
    const caller = seed("Orchestrator", 1_000, undefined, "ready");
    const target = seed("Worker", 2_000, caller, "busy");
    const { dispatch } = routes(
      vi.fn(async (): Promise<void> => {
        throw new Error("runtime unavailable");
      }),
    );

    const res = await send(
      dispatch,
      `/sessions/${target.id}/command`,
      { type: "steer", message: "x" },
      caller.id,
    );

    expect(res.statusCode).toBe(500);
    expect(store.listSessionInteractions([target.id])).toEqual([]);
  });

  it("maps only session-driving commands to interaction kinds", () => {
    expect(
      ["prompt", "steer", "follow_up", "abort", "set_session_name", "get_state"].map(
        interactionKindForCommand,
      ),
    ).toEqual(["prompt", "steer", "follow_up", "abort", undefined, undefined]);
  });

  it("records a CLI stop before the session's own end time", async () => {
    const caller = seed("Orchestrator", 1_000, undefined, "ready");
    const target = seed("Worker", 2_000, caller, "ready");
    const { dispatch } = routes();
    // Every clock read advances, so a timestamp taken after the lifecycle sets
    // lastActivity would be strictly later than it.
    let clock = 10_000;
    const now = vi.spyOn(Date, "now").mockImplementation(() => (clock += 1));

    try {
      const res = await send(dispatch, `/sessions/${target.id}/stop`, {}, caller.id);
      expect(res.statusCode).toBe(200);
    } finally {
      now.mockRestore();
    }

    const [stop] = store.listSessionInteractions([target.id]);
    expect(stop).toMatchObject({ fromSessionId: caller.id, toSessionId: target.id, kind: "stop" });
    expect(stop.at).toBeLessThan(store.getSession(target.id)!.lastActivity);
  });

  it("keeps a delivered command successful when the audit write fails", () => {
    const caller = seed("Orchestrator", 1_000, undefined, "ready");
    const target = seed("Worker", 2_000, caller, "busy");
    const failing = {
      getSession: (id: string) => store.getSession(id),
      recordSessionInteraction: () => {
        throw new Error("SQLITE_BUSY");
      },
    };

    expect(() =>
      recordCallerInteraction(failing, withCaller(makeRequest(), caller.id), target, "steer"),
    ).not.toThrow();
  });

  it("drops a deleted session's interactions", () => {
    const a = seed("A", 1_000);
    const b = seed("B", 2_000);
    store.recordSessionInteraction({
      at: 3_000,
      fromSessionId: a.id,
      toSessionId: b.id,
      kind: "prompt",
    });

    store.deleteSession(b.id);

    expect(store.listSessionInteractions([a.id])).toEqual([]);
  });
});

describe("GET /sessions/:id/thread", () => {
  it("returns the whole launch tree and cross-thread counterparts from any member", async () => {
    const root = seed("Investigate Unfinished Sonnet Worktree", 1_000, undefined, "ready");
    const fix = seed("Fix: queue move banner", 2_000, root);
    const master = seed("Donkey Master", 3_000, root, "busy");
    const worker = seed("Worker P1s3", 4_000, master);
    const otherRoot = seed("Investigate iOS App Modularity", 500);
    const otherChild = seed("Sonnet max Markdown resource access", 600, otherRoot);
    const unrelated = seed("Daily digest", 700);
    store.recordSessionInteraction({
      at: 2_500,
      fromSessionId: root.id,
      toSessionId: otherChild.id,
      kind: "steer",
    });
    store.recordSessionInteraction({
      at: 4_500,
      fromSessionId: master.id,
      toSessionId: worker.id,
      kind: "follow_up",
    });
    store.recordSessionInteraction({
      at: 800,
      fromSessionId: otherRoot.id,
      toSessionId: unrelated.id,
      kind: "prompt",
    });
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
    expect(thread.interactions.map((i) => i.kind)).toEqual(["steer", "follow_up"]);
    expect(thread.counterparts).toEqual([
      {
        id: otherChild.id,
        name: otherChild.name,
        status: "stopped",
        workspaceId: "ws-1",
        rootSessionId: otherRoot.id,
        rootName: otherRoot.name,
      },
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
      const { dispatch } = routes(undefined, {
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

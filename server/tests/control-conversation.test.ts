import { lstatSync, mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import { AgentDoc, type ConversationId } from "@earendil-works/pi-durable";

import {
  ControlConversationError,
  ControlConversationService,
} from "../src/control-conversation-service.js";
import {
  CONTROL_CONVERSATION_LAUNCH_KEY,
  isControlConversation,
  isDeclaredControlSession,
} from "../src/control-session.js";
import {
  CONTROL_CONVERSATION_EXTENSIONS,
  controlConversationTools,
} from "../src/durable-control-conversation.js";
import type { DurableHarness } from "../src/durable-harness.js";
import { reservedLaunchKeyError } from "../src/reserved-launch-keys.js";
import { createControlConversationRoutes } from "../src/routes/control-conversation.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import { resolveSdkSessionCwd } from "../src/sdk-backend.js";
import { SessionListService } from "../src/session-list-service.js";
import { canResumeAfterServerRestart } from "../src/session-lifecycle-service.js";
import {
  queueOrphanedSessionsForRestart,
  recordLiveSessionsForRestart,
  resumeSessionsAfterRestart,
} from "../src/session-restart-resume.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "s1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

const controlRow = (overrides: Partial<Session> = {}): Session =>
  makeSession({ id: "control", serverDurable: { role: "control" }, ...overrides });

describe("control conversation marker gates", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-control-conversation-gates-"));
  });

  it("is a durable row with no workspace and no declared-control metadata", () => {
    const row = controlRow();
    expect(isControlConversation(row)).toBe(true);
    expect(isDeclaredControlSession(row)).toBe(false);
    expect(isControlConversation(makeSession({ serverDurable: { conversationId: 4 } }))).toBe(
      false,
    );
    expect(isControlConversation(makeSession())).toBe(false);
  });

  it("resumes after a server restart, and only the control conversation among workspace-less rows", () => {
    expect(canResumeAfterServerRestart(controlRow())).toBe(true);
    expect(canResumeAfterServerRestart(controlRow({ status: "busy" }))).toBe(true);
    expect(canResumeAfterServerRestart(makeSession({ serverDurable: { conversationId: 4 } }))).toBe(
      false,
    );
    expect(canResumeAfterServerRestart(controlRow({ ephemeral: true }))).toBe(false);
  });

  it("queues an idle control conversation at graceful stop and after a crash", () => {
    const queued: unknown[] = [];
    const entries = recordLiveSessionsForRestart({ queueRestartResume: (e) => queued.push(...e) }, [
      controlRow(),
    ]);
    expect(entries).toEqual([{ sessionId: "control", wasBusy: false }]);

    const stored = [controlRow({ status: "ready" })];
    const crashQueue: unknown[] = [];
    const crashed = queueOrphanedSessionsForRestart({
      listSessions: () => stored,
      queueRestartResume: (e) => crashQueue.push(...e),
      saveSession: () => {},
    });
    expect(crashed).toEqual([{ sessionId: "control", wasBusy: false }]);
  });

  it("resumes through the durable start path, never as a declared control session", async () => {
    const control = controlRow();
    const lifecycle = {
      resumeControlConversation: vi.fn(async (session: Session) => ({ session })),
      resumeControlSession: vi.fn(),
      resumeWorkspaceSession: vi.fn(),
    };
    const clears: string[] = [];
    const queue = [{ sessionId: "control", wasBusy: false }];
    const results = await resumeSessionsAfterRestart({
      storage: {
        clearRestartResume: (id: string) => {
          clears.push(id);
          queue.length = 0;
        },
        getSession: () => control,
        getWorkspace: () => undefined,
        listRestartResume: () => queue,
        listSessions: () => [control],
        queueRestartResume: () => {},
        saveSession: () => {},
      },
      lifecycle,
      sendPrompt: vi.fn(),
      sendFollowUp: vi.fn(),
    });
    expect(results).toEqual([{ sessionId: "control", outcome: "resumed" }]);
    expect(lifecycle.resumeControlConversation).toHaveBeenCalledOnce();
    expect(lifecycle.resumeControlSession).not.toHaveBeenCalled();
    expect(clears).toEqual(["control"]);
  });

  it("runs in $OPPI_DATA_DIR/control-conversation/cwd, owner-only", () => {
    const cwd = resolveSdkSessionCwd(undefined, controlRow(), { dataDir: dir });
    expect(cwd).toBe(join(dir, "control-conversation", "cwd"));
    expect(lstatSync(cwd).mode & 0o777).toBe(0o700);
    expect(lstatSync(join(dir, "control-conversation")).mode & 0o777).toBe(0o700);
    // Classic control sessions keep their own directory.
    expect(
      resolveSdkSessionCwd(
        undefined,
        makeSession({ control: { domain: "agents", intent: "create" } }),
        { dataDir: dir },
      ),
    ).toBe(join(dir, "control-sessions", "cwd"));
  });

  it("refuses a symlinked cwd root", () => {
    const elsewhere = mkdtempSync(join(tmpdir(), "oppi-control-conversation-elsewhere-"));
    symlinkSync(elsewhere, join(dir, "control-conversation"));
    expect(() => resolveSdkSessionCwd(undefined, controlRow(), { dataDir: dir })).toThrow(
      "Control conversation cwd parent must be a real directory",
    );
  });

  it("keeps the launch key out of client create routes", async () => {
    expect(reservedLaunchKeyError(CONTROL_CONVERSATION_LAUNCH_KEY)).toContain("reserved");
    expect(reservedLaunchKeyError(` ${CONTROL_CONVERSATION_LAUNCH_KEY} `)).toContain("reserved");
    expect(reservedLaunchKeyError("control-conversation-2", "ordinary")).toBeUndefined();

    const storage = new Storage(dir);
    const workspace = storage.createWorkspace({ name: "Reserved key", hostMount: dir });
    const dispatch = createSessionRoutes(
      {
        storage,
        sessions: {},
        sessionRuntimes: {},
        ensureSessionContextWindow: (session: Session) => session,
      } as unknown as RouteContext,
      createRouteHelpers(),
    );
    for (const [path, body] of [
      [
        `/workspaces/${workspace.id}/sessions`,
        { prompt: "hi", launchIdempotencyKey: CONTROL_CONVERSATION_LAUNCH_KEY },
      ],
      [
        `/workspaces/${workspace.id}/sessions`,
        { prompt: "hi", idempotencyKey: CONTROL_CONVERSATION_LAUNCH_KEY },
      ],
      [
        "/control-sessions",
        {
          domain: "agents",
          intent: "create",
          launchIdempotencyKey: CONTROL_CONVERSATION_LAUNCH_KEY,
        },
      ],
    ] as const) {
      const res = makeResponse();
      await dispatch({
        method: "POST",
        path,
        url: new URL(path, "http://localhost"),
        req: makeRequest(body),
        res: res as never,
      });
      expect(res.statusCode, path).toBe(400);
      expect(JSON.parse(res.body).error, path).toContain("reserved");
    }
    expect(storage.findSessionByLaunchIdempotencyKey(CONTROL_CONVERSATION_LAUNCH_KEY)).toBe(
      undefined,
    );
  });
});

describe("control conversation find-or-create service", () => {
  function serviceFixture(options: { serverDurable?: boolean; resume?: () => Promise<void> } = {}) {
    const rows = new Map<string, Session>();
    const storage = {
      getConfig: () => ({ experimental: { serverDurable: options.serverDurable ?? true } }),
      findSessionByLaunchIdempotencyKey: (key: string) =>
        [...rows.values()].find((row) => row.launch?.idempotencyKey === key),
      getSession: (id: string) => rows.get(id),
      saveSession: (session: Session) => void rows.set(session.id, structuredClone(session)),
      deleteSession: (id: string) => rows.delete(id),
    };
    const resume = vi.fn(async (session: Session) => {
      await options.resume?.();
      const stored = rows.get(session.id)!;
      stored.serverDurable = { ...stored.serverDurable, conversationId: 7 };
      return { session: structuredClone(stored) };
    });
    const service = new ControlConversationService({
      storage: storage as never,
      lifecycle: { resumeControlConversation: resume } as never,
    });
    return { rows, resume, service };
  }

  it("refuses while experimental.serverDurable is off and creates nothing", async () => {
    const f = serviceFixture({ serverDurable: false });
    await expect(f.service.open()).rejects.toMatchObject({
      statusCode: 409,
      message: expect.stringContaining("experimental.serverDurable"),
    });
    expect(f.rows.size).toBe(0);
    expect(f.resume).not.toHaveBeenCalled();
  });

  it("serializes concurrent first calls into one row and one start order", async () => {
    const order: string[] = [];
    const f = serviceFixture({
      resume: async () => {
        order.push("start");
        await new Promise((resolve) => setTimeout(resolve, 5));
        order.push("end");
      },
    });
    const results = await Promise.all([f.service.open(), f.service.open(), f.service.open()]);
    expect(f.rows.size).toBe(1);
    expect(new Set(results.map((r) => r.session.id)).size).toBe(1);
    expect(results.map((r) => r.created)).toEqual([true, false, false]);
    expect(order).toEqual(["start", "end", "start", "end", "start", "end"]);
    const row = [...f.rows.values()][0]!;
    expect(row.workspaceId).toBeUndefined();
    expect(row).toMatchObject({
      serverDurable: { role: "control", conversationId: 7 },
      launch: { idempotencyKey: CONTROL_CONVERSATION_LAUNCH_KEY },
    });
    expect(row.control).toBeUndefined();
  });

  it("adopts a row saved before the conversation bound instead of creating a second one", async () => {
    const f = serviceFixture();
    // A crash after the row was saved and before the runtime attached.
    const first = f.service.open({ model: "faux/faux-1" });
    await first;
    const bound = [...f.rows.values()][0]!;
    delete bound.serverDurable!.conversationId;

    const again = await f.service.open({ model: "ignored/on-existing" });
    expect(again.created).toBe(false);
    expect(f.rows.size).toBe(1);
    expect(again.session.id).toBe(bound.id);
    expect(bound.model).toBe("faux/faux-1");
  });

  it("drops a fresh row that failed to start so the next open can retry", async () => {
    let failures = 1;
    const f = serviceFixture({
      resume: async () => {
        if (failures-- > 0) throw new Error("Server durable model is unavailable: nope/none");
      },
    });
    await expect(f.service.open({ model: "nope/none" })).rejects.toThrow("unavailable");
    expect(f.rows.size).toBe(0);
    const retried = await f.service.open();
    expect(retried.created).toBe(true);
    expect(f.rows.size).toBe(1);
  });

  it("will not adopt another session's row under the reserved key", async () => {
    const f = serviceFixture();
    f.rows.set(
      "other",
      makeSession({
        id: "other",
        launch: { idempotencyKey: CONTROL_CONVERSATION_LAUNCH_KEY, status: "accepted" },
      }),
    );
    await expect(f.service.open()).rejects.toBeInstanceOf(ControlConversationError);
  });
});

describe("control conversation lifecycle on the durable harness", () => {
  const managers: SessionManager[] = [];
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

  beforeEach(() => {
    process.env.PI_CODING_AGENT_DIR = mkdtempSync(
      join(tmpdir(), "oppi-control-conversation-agent-"),
    );
  });
  afterEach(async () => {
    await Promise.all(managers.splice(0).map((manager) => manager.close()));
    vi.restoreAllMocks();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  async function setup() {
    const dir = mkdtempSync(join(tmpdir(), "oppi-control-conversation-"));
    const models = await ModelRuntime.create({
      authPath: join(dir, "auth.json"),
      modelsPath: null,
      modelsStorePath: join(dir, "models-cache.json"),
      refreshOnCreate: false,
    });
    const faux = fauxProvider();
    faux.setResponses([]);
    models.registerNativeProvider(faux.provider);
    await models.setRuntimeApiKey("faux", "test-only-faux-credential");
    await models.refresh({ allowNetwork: false });
    vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
    vi.spyOn(SettingsManager, "create").mockImplementation(() =>
      SettingsManager.inMemory({
        defaultProvider: "faux",
        defaultModel: "faux-1",
        defaultThinkingLevel: "off",
        compaction: { enabled: false },
      }),
    );
    const storage = new Storage(dir);
    storage.updateConfig({ experimental: { serverDurable: true } });
    return { dir, storage };
  }

  async function boot(storage: Storage) {
    const manager = new SessionManager(storage);
    managers.push(manager);
    await manager.resumeDurableSessions();
    const dispatch = createControlConversationRoutes(
      {
        storage,
        sessions: manager,
        sessionRuntimes: manager,
        ensureSessionContextWindow: (session: Session) => session,
      } as unknown as RouteContext,
      createRouteHelpers(),
    );
    async function open(body: Record<string, unknown> = {}) {
      const res = makeResponse();
      const handled = await dispatch({
        method: "POST",
        path: "/control-conversation",
        url: new URL("http://localhost/control-conversation"),
        req: makeRequest(body),
        res: res as never,
      });
      expect(handled).toBe(true);
      return { status: res.statusCode, body: JSON.parse(res.body) as { session: Session } };
    }
    return { manager, open };
  }

  it("creates one conversation under concurrency and finds the same one after a restart", async () => {
    const { storage } = await setup();
    const first = await boot(storage);

    const opened = await Promise.all([
      first.open({ model: "faux/faux-1" }),
      first.open(),
      first.open(),
    ]);
    expect(opened.map((r) => r.status).sort()).toEqual([200, 200, 201]);
    const ids = new Set(opened.map((r) => r.body.session.id));
    expect(ids.size).toBe(1);
    const sessionId = [...ids][0]!;
    const conversationId = opened[0]!.body.session.serverDurable?.conversationId;
    expect(conversationId).toBeGreaterThan(0);
    expect(storage.listSessions().filter(isControlConversation)).toHaveLength(1);
    expect(storage.getSession(sessionId)?.serverDurable).toEqual({
      conversationId,
      role: "control",
    });
    expect(first.manager.isActive(sessionId)).toBe(true);

    // The stored selection is the exact control list, not the coding default.
    const owner = (first.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    const { harness } = await (await owner).open();
    const agent = await harness.snapshot(AgentDoc, conversationId as ConversationId, context);
    expect(agent?.extensions).toEqual(CONTROL_CONVERSATION_EXTENSIONS.map((e) => e.name));
    expect(agent?.tools).toEqual(controlConversationTools().map((tool) => tool.name));
    expect(agent?.cwd).toBe(join(storage.getDataDir(), "control-conversation", "cwd"));
    expect((await owner).baseExtensions.map((e) => e.name)).not.toContain("oppi.control");

    // Never on the phone's session list, live or not.
    const list = new SessionListService({
      storage,
      sessionRuntimes: first.manager,
      ensureSessionContextWindow: (session) => session,
    });
    expect(
      list.listRecentWorkspaceSessionSummaries({ recentDays: 0 }).sessions.map((row) => row.id),
    ).not.toContain(sessionId);

    // Graceful restart with the conversation idle: it comes back with no client asking.
    const live = [first.manager.getActiveSession(sessionId)!];
    expect(live[0]?.status).toBe("ready");
    recordLiveSessionsForRestart(storage, live);
    await first.manager.close();
    managers.splice(managers.indexOf(first.manager), 1);

    const second = await boot(storage);
    expect(second.manager.isActive(sessionId)).toBe(true);
    const reopened = await second.open();
    expect(reopened.status).toBe(200);
    expect(reopened.body.session.id).toBe(sessionId);
    expect(reopened.body.session.serverDurable?.conversationId).toBe(conversationId);
    expect(storage.listSessions().filter(isControlConversation)).toHaveLength(1);
  });

  it("re-attaches a stopped control conversation to the same conversation on demand", async () => {
    const { storage } = await setup();
    const first = await boot(storage);
    const opened = await first.open({ model: "faux/faux-1" });
    const sessionId = opened.body.session.id;
    await first.manager.stopSession(sessionId);
    expect(first.manager.isActive(sessionId)).toBe(false);

    const again = await first.open();
    expect(again.status).toBe(200);
    expect(again.body.session.id).toBe(sessionId);
    expect(again.body.session.serverDurable?.conversationId).toBe(
      opened.body.session.serverDurable?.conversationId,
    );
    expect(first.manager.isActive(sessionId)).toBe(true);
  });

  it("answers 409 while experimental.serverDurable is off", async () => {
    const { storage } = await setup();
    storage.updateConfig({ experimental: { serverDurable: false } });
    const off = await boot(storage);
    const refused = await off.open();
    expect(refused.status).toBe(409);
    expect((refused.body as unknown as { error: string }).error).toContain(
      "experimental.serverDurable",
    );
    expect(storage.listSessions()).toEqual([]);
  });
});

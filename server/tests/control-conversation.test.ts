import { EventEmitter } from "node:events";
import { lstatSync, rmSync, symlinkSync } from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { WebSocket } from "ws";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { AgentDoc, type ConversationId } from "@earendil-works/pi-durable";

import { isControlConversation } from "../src/control-session.js";
import { createCliConfigStorage } from "../src/cli/connection-config.js";
import { controlConversationTools } from "../src/durable-control-conversation.js";
import type { DurableHarness } from "../src/durable-harness.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { resolveSdkSessionCwdAsync } from "../src/sdk-backend.js";
import { SessionRuntimes } from "../src/runtime-router.js";
import { BoundSessionStreamMux, type StreamContext } from "../src/stream.js";
import { WsMessageHandler } from "../src/ws-message-handler.js";
import { SessionListService } from "../src/session-list-service.js";
import {
  canResumeAfterServerRestart,
  SessionLifecycleService,
} from "../src/session-lifecycle-service.js";
import {
  queueOrphanedSessionsForRestart,
  recordLiveSessionsForRestart,
  resumeSessionsAfterRestart,
} from "../src/session-restart-resume.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";
import { saveControlRow } from "./harness/control-row.js";
import { makeTempDir } from "./harness/temp-dir.js";

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
    dir = makeTempDir("oppi-control-conversation-gates-");
  });

  it("is a durable row with no workspace", () => {
    const row = controlRow();
    expect(isControlConversation(row)).toBe(true);
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
    // A store the previous process wrote before it recorded live runtimes.
    const live: Array<{ sessionId: string; phase: "live" | "terminating" }> = [];
    const crashed = queueOrphanedSessionsForRestart({
      listSessions: () => stored,
      getSession: (id) => stored.find((session) => session.id === id),
      runMigrationOnceSync: (_key, run) => run(),
      markRuntimeLive: (sessionId, phase) => live.push({ sessionId, phase }),
      listRuntimeLive: () => live,
      clearRuntimeLive: () => {},
      queueRestartResume: (e) => crashQueue.push(...e),
      saveSession: () => {},
    });
    expect(crashed).toEqual([{ sessionId: "control", wasBusy: false }]);
  });

  it("resumes through the durable start path", async () => {
    const control = controlRow();
    const lifecycle = {
      resumeControlConversation: vi.fn(async (session: Session) => ({ session })),
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
      reportsLostWork: () => false,
    });
    expect(results).toEqual([{ sessionId: "control", outcome: "resumed" }]);
    expect(lifecycle.resumeControlConversation).toHaveBeenCalledOnce();
    expect(clears).toEqual(["control"]);
  });

  it("runs in $OPPI_DATA_DIR/control-conversation/cwd, owner-only", async () => {
    const cwd = await resolveSdkSessionCwdAsync(undefined, controlRow(), { dataDir: dir });
    expect(cwd).toBe(join(dir, "control-conversation", "cwd"));
    expect(lstatSync(cwd).mode & 0o777).toBe(0o700);
    expect(lstatSync(join(dir, "control-conversation")).mode & 0o777).toBe(0o700);
  });

  it("refuses a symlinked cwd root", async () => {
    const elsewhere = makeTempDir("oppi-control-conversation-elsewhere-");
    symlinkSync(elsewhere, join(dir, "control-conversation"));
    await expect(
      resolveSdkSessionCwdAsync(undefined, controlRow(), { dataDir: dir }),
    ).rejects.toThrow("Control conversation cwd parent must be a real directory");
  });
});

describe("control conversation lifecycle on the durable harness", () => {
  const managers: SessionManager[] = [];
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

  beforeEach(() => {
    process.env.PI_CODING_AGENT_DIR = makeTempDir("oppi-control-conversation-agent-");
  });
  afterEach(async () => {
    await Promise.all(managers.splice(0).map((manager) => manager.close()));
    vi.restoreAllMocks();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  async function setup() {
    const dir = makeTempDir("oppi-control-conversation-");
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
    // Durable Oppi Control runs without experimental.serverDurable.
    expect(storage.getConfig().experimental?.serverDurable).not.toBe(true);
    return { dir, storage, faux };
  }

  async function boot(storage: Storage) {
    const manager = new SessionManager(storage);
    managers.push(manager);
    await manager.resumeDurableSessions();
    const lifecycle = new SessionLifecycleService({
      storage,
      sessions: manager,
      sessionRuntimes: manager,
      ensureSessionContextWindow: (session: Session) => session,
    });
    // Attaches the data directory's stored control row, saving one first when it has none.
    async function open(options: { model?: string } = {}) {
      const stored = storage.listSessions().find(isControlConversation);
      const { session } = await lifecycle.resumeControlConversation(
        stored ?? saveControlRow(storage, options),
      );
      return { session };
    }
    return { manager, open };
  }

  it("does not start an unbound control row an earlier server created at boot", async () => {
    const { storage } = await setup();
    const first = await boot(storage);
    const row = saveControlRow(storage);
    expect(row.status).toBe("stopped");
    expect(first.manager.isActive(row.id)).toBe(false);
    expect(row.serverDurable?.conversationId).toBeUndefined();

    await first.manager.close();
    managers.splice(managers.indexOf(first.manager), 1);

    const second = await boot(storage);
    queueOrphanedSessionsForRestart(storage);
    await resumeSessionsAfterRestart({
      storage,
      lifecycle: {
        resumeControlConversation: async (session) => ({
          session: await second.manager.startSession(session.id),
        }),
        resumeWorkspaceSession: vi.fn(async ({ session }) => ({ session })),
      },
      sendPrompt: vi.fn(),
      sendFollowUp: vi.fn(),
      reportsLostWork: () => false,
    });

    expect(second.manager.isActive(row.id)).toBe(false);
    expect(storage.getSession(row.id)?.status).toBe("stopped");
    expect(storage.listRestartResume()).toEqual([]);

    const opened = await second.open({ model: "faux/faux-1" });
    expect(opened.session.id).toBe(row.id);
    expect(second.manager.isActive(row.id)).toBe(true);
    expect(opened.session.serverDurable?.conversationId).toBeGreaterThan(0);
  });

  it("binds one conversation and finds the same one after a restart", async () => {
    const { storage } = await setup();
    const first = await boot(storage);

    const opened = await first.open({ model: "faux/faux-1" });
    const sessionId = opened.session.id;
    const conversationId = opened.session.serverDurable?.conversationId;
    expect(conversationId).toBeGreaterThan(0);
    expect(storage.listSessions().filter(isControlConversation)).toHaveLength(1);
    expect(storage.getSession(sessionId)?.serverDurable).toEqual({
      storeId: sessionId,
      conversationId,
      role: "control",
    });
    expect(first.manager.isActive(sessionId)).toBe(true);

    // The stored selection is the exact control list, not the coding default.
    const owner = (first.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    const runtime = await owner;
    const { harness } = await (await runtime.openHost(sessionId)).open();
    const agent = await harness.snapshot(AgentDoc, conversationId as ConversationId, context);
    expect(agent?.extensions).toEqual([
      "ask",
      "working-words",
      "oppi.control",
      "project-context",
      "codemode",
      "coding-tools",
    ]);
    expect(agent?.tools).toEqual(expect.arrayContaining(["read", "bash", "edit", "write"]));
    expect(agent?.extensions).toEqual((await owner).controlExtensions.map((e) => e.name));
    expect(agent?.tools).toEqual(
      controlConversationTools((await owner).controlExtensions).map((tool) => tool.name),
    );
    expect(agent?.cwd).toBe(join(storage.getDataDir(), "control-conversation", "cwd"));
    expect((await owner).defaultExtensions.map((e) => e.name)).not.toContain("oppi.control");

    // On the phone's global list, with the role and without a workspace.
    const list = new SessionListService({
      storage,
      sessionRuntimes: first.manager,
      ensureSessionContextWindow: (session) => session,
    });
    const listed = list.listRecentWorkspaceSessionSummaries({ recentDays: 0 }).sessions;
    expect(listed.map((row) => row.id)).toContain(sessionId);
    expect(listed.find((row) => row.id === sessionId)).toMatchObject({
      engine: "durable",
      serverDurable: { role: "control" },
    });
    expect(listed.find((row) => row.id === sessionId)?.workspaceId).toBeUndefined();

    // Graceful restart with the conversation idle: it comes back with no client asking.
    const live = [first.manager.getActiveSession(sessionId)!];
    expect(live[0]?.status).toBe("ready");
    recordLiveSessionsForRestart(storage, live);
    await first.manager.close();
    managers.splice(managers.indexOf(first.manager), 1);

    const second = await boot(storage);
    expect(second.manager.isActive(sessionId)).toBe(true);
    const reopened = await second.open();
    expect(reopened.session.id).toBe(sessionId);
    expect(reopened.session.serverDurable?.conversationId).toBe(conversationId);
    expect(storage.listSessions().filter(isControlConversation)).toHaveLength(1);
  });

  it("runs control tools on the host the server binds, directly and from codemode, with the section as its instructions", async () => {
    const { storage, faux } = await setup();
    faux.setResponses([
      fauxAssistantMessage(
        [
          fauxToolCall("codemode", {
            code: "let reached; try { await tools.agents_list({}); } catch (e) { reached = e.message; } return [6 * 7, reached];",
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage([fauxToolCall("workspaces_list", {})], { stopReason: "toolUse" }),
      fauxAssistantMessage("forty-two"),
    ]);
    const booted = await boot(storage);
    const opened = await booted.open({ model: "faux/faux-1" });
    const owner = await (booted.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    const storeId = opened.session.serverDurable?.storeId ?? opened.session.id;
    const { harness } = await (await owner.openHost(storeId)).open();
    const conversation = (await harness.conversation(
      opened.session.serverDurable!.conversationId as ConversationId,
      context,
    ))!;
    const settled = await (
      await conversation.submit({ type: "input", content: "what is 6 * 7?" }, context)
    ).wait(context);
    expect(settled.status).toBe("done");
    const page = await conversation.entries({}, 50, undefined, context);
    const results = page.items
      .flatMap((entry) => entry.model ?? [])
      .filter((message) => message.role === "toolResult");
    const script = results.find((message) => message.toolName === "codemode");
    // Both reached the CLI host the server binds, which refuses: this data dir is not paired.
    expect(script).toMatchObject({ isError: false });
    expect(JSON.stringify(script?.content)).toContain("[42,");
    expect(JSON.stringify(script?.content)).toContain("oppi init");
    const direct = results.find((message) => message.toolName === "workspaces_list");
    expect(direct).toMatchObject({ isError: true });
    expect(JSON.stringify(direct?.content)).toContain("oppi init");
    const agent = await conversation.agent(context);
    expect(agent.instructions).toBeUndefined();
    expect(agent.sections.map((section) => section.key)).toContain("oppi-control");
  });

  it("re-attaches a stopped control conversation to the same conversation on demand", async () => {
    const { storage } = await setup();
    const first = await boot(storage);
    const opened = await first.open({ model: "faux/faux-1" });
    const sessionId = opened.session.id;
    await first.manager.stopSession(sessionId);
    expect(first.manager.isActive(sessionId)).toBe(false);

    const again = await first.open();
    expect(again.session.id).toBe(sessionId);
    expect(again.session.serverDurable?.conversationId).toBe(
      opened.session.serverDurable?.conversationId,
    );
    expect(first.manager.isActive(sessionId)).toBe(true);
  });

  describe("owner answers over /control-sessions/<id>/stream", () => {
    const servers: HttpServer[] = [];
    afterEach(async () => {
      await Promise.all(
        servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))),
      );
    });

    class StreamSocket extends EventEmitter {
      readyState: number = WebSocket.OPEN;
      sent: ServerMessage[] = [];
      closeCode?: number;
      send(data: string): void {
        this.sent.push(JSON.parse(data) as ServerMessage);
      }
      ping(): void {}
      terminate(): void {
        this.readyState = WebSocket.CLOSED;
      }
      close(code = 1000): void {
        this.readyState = WebSocket.CLOSED;
        this.closeCode = code;
        this.emit("close", code, Buffer.from(""));
      }
      receive(message: ClientMessage): void {
        this.emit("message", Buffer.from(JSON.stringify(message)), false);
      }
      async next(predicate: (message: ServerMessage) => boolean): Promise<ServerMessage> {
        const deadline = Date.now() + 15_000;
        for (;;) {
          const found = this.sent.find(predicate);
          if (found) return found;
          if (Date.now() > deadline) throw new Error("timed out waiting for a server message");
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
      }
    }

    /** The server's wiring of stream, runtime router and message handler around a real SessionManager. */
    function streamOf(storage: Storage, manager: SessionManager) {
      const runtimes = new SessionRuntimes(storage, manager, {} as never);
      const handler = new WsMessageHandler({
        sessions: runtimes,
        ensureSessionContextWindow: (session) => session,
        getModelCatalog: () => [],
      });
      return new BoundSessionStreamMux({
        storage,
        sessions: manager,
        sessionRuntimes: runtimes,
        ensureSessionContextWindow: (session) => session,
        resolveWorkspaceForSession: (session) =>
          session.workspaceId ? storage.getWorkspace(session.workspaceId) : undefined,
        handleClientMessage: (session, message, send, meta) =>
          handler.handleClientMessage(session, message, send, meta),
        trackConnection: () => {},
        untrackConnection: () => {},
      } as unknown as StreamContext);
    }

    it.each([
      ["Create Agent", 1],
      ["Cancel", 0],
    ])(
      "answering %j on the owner stream decides the pending write (%i Agent rows)",
      async (answer, rows) => {
        const { dir, storage, faux } = await setup();
        createCliConfigStorage(dir).ensurePaired();
        const dispatchAgents = createAgentRoutes(
          { storage } as unknown as RouteContext,
          createRouteHelpers(),
        );
        const api = createHttpServer((req, res) => {
          void (async () => {
            const url = new URL(req.url ?? "/", "http://localhost");
            const handled = await dispatchAgents({
              method: req.method ?? "GET",
              path: url.pathname,
              url,
              req,
              res,
            } as never);
            if (!handled) {
              res.writeHead(404, { "Content-Type": "application/json" });
              res.end(JSON.stringify({ error: "not found" }));
            }
          })();
        });
        servers.push(api);
        await listenOnLocalApiFixture(api, dir);

        faux.setResponses([
          fauxAssistantMessage(
            [
              fauxToolCall("codemode", {
                code: 'return await tools.oppi({ argv: ["agent","create","--name","Via stream"] });',
              }),
            ],
            { stopReason: "toolUse" },
          ),
          fauxAssistantMessage("settled"),
        ]);
        const booted = await boot(storage);
        const opened = await booted.open({ model: "faux/faux-1" });
        const sessionId = opened.session.id;
        // The row the phone lists as control: no workspace.
        expect(storage.getSession(sessionId)).toMatchObject({ serverDurable: { role: "control" } });
        expect(storage.getSession(sessionId)?.workspaceId).toBeUndefined();
        const store = storage.getAgentDefinitionStore();
        const before = store.listAgents().length;

        const mux = streamOf(storage, booted.manager);
        const ws = new StreamSocket();
        await mux.handleControlWebSocket(sessionId, ws as unknown as WebSocket);
        expect(ws.closeCode).toBeUndefined();
        expect(ws.sent.some((m) => m.type === "connected")).toBe(true);

        await booted.manager.sendPrompt(sessionId, "make an agent");
        const card = (await ws.next(
          (m) => m.type === "extension_ui_request" && m.method === "select",
        )) as Extract<ServerMessage, { type: "extension_ui_request" }>;
        expect(card.title).toBe("Create Agent “Via stream”?");
        expect(store.listAgents()).toHaveLength(before);

        ws.receive({ type: "extension_ui_response", id: card.id, value: answer });
        await ws.next((m) => m.type === "agent_end");
        expect(store.listAgents()).toHaveLength(before + rows);
        expect(ws.sent.filter((m) => m.type === "error")).toEqual([]);
        // The script's call reaches the phone as a call of the codemode row, not a row of its own.
        const script = ws.sent.find((m) => m.type === "tool_start" && m.tool === "codemode") as
          Extract<ServerMessage, { type: "tool_start" }> | undefined;
        const nested = ws.sent.filter(
          (m): m is Extract<ServerMessage, { type: "tool_start" | "tool_end" }> =>
            (m.type === "tool_start" || m.type === "tool_end") && m.tool === "oppi",
        );
        expect(nested.map((m) => m.type)).toEqual(["tool_start", "tool_end"]);
        expect(nested.every((m) => m.parentToolCallId === script?.toolCallId)).toBe(true);
        // The envelope is the call's value, an answer either way; a No is its error envelope.
        expect(nested[1]?.isError).not.toBe(true);
        rmSync(dir, { recursive: true, force: true });
      },
    );

    it("still refuses a workspace-less durable session that is not an Oppi Control session", async () => {
      const { storage } = await setup();
      const booted = await boot(storage);
      const stray = storage.createSession("Stray");
      stray.serverDurable = { conversationId: 99 };
      storage.saveSession(stray);
      const ws = new StreamSocket();
      await streamOf(storage, booted.manager).handleControlWebSocket(
        stray.id,
        ws as unknown as WebSocket,
      );
      expect(ws.closeCode).toBe(1008);
    });
  });
});

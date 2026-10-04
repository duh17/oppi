import { mkdtempSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
  fauxThinking,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { Type } from "typebox";
import {
  Harness,
  createRegistry,
  ToolTask,
  AssistantEntry,
  InboxDoc,
  LiveDoc,
  watchEvents,
  type AgentEvent,
  type ConversationId,
  type ToolRegistration,
  defineTool,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { SdkBackend, resolveSandboxGuestCwd } from "../src/sdk-backend.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { DurableBackend, DurableNotSupportedError } from "../src/durable-backend.js";
import { Storage } from "../src/storage.js";
import { SessionManager } from "../src/sessions.js";
import { DurableHarness } from "../src/durable-harness.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import { readDurableTrace } from "../src/durable-history.js";
import { SessionAgentEventCoordinator } from "../src/session-agent-events.js";
import { SessionStopCoordinator } from "../src/session-stop.js";
import { SessionMessageQueueCoordinator } from "../src/session-queue.js";
import {
  queueOrphanedSessionsForRestart,
  recordLiveSessionsForRestart,
} from "../src/session-restart-resume.js";
import type { ChatAttachmentRef, ServerMessage, Session } from "../src/types.js";
import { DurableAsk } from "../extensions/durable/ask/durable.js";
import { DurableGoal } from "../extensions/durable/goal/durable.js";
import { DurableWorkingWords } from "../extensions/durable/working-words/durable.js";
import {
  DurableBackgroundJobs,
  DurableJobs,
} from "../extensions/durable/background-jobs/durable.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { SdkUiBridge } from "../src/sdk-ui-bridge.js";
import {
  DurableUI,
  DurableInputCards,
  requestUI,
  type UIResponse,
  type UINotification,
} from "../extensions/durable/durable-ui.js";
import { buildExtensionUIRequestMessage } from "../src/extension-ui-contract.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { TraceEvent } from "../src/trace.js";
import type { TracePageResult } from "../src/trace-paging.js";
import type { TraceOutlineResult } from "../src/trace-outline.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const managers: SessionManager[] = [];
const harnesses: Harness[] = [];
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
  vi.restoreAllMocks();
});

async function fixture(
  responses: FauxResponseStep[],
  options?: { slow?: boolean; settings?: Parameters<typeof SettingsManager.inMemory>[0] },
) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-server-durable-test-"));
  console.info(`Durable integration artifacts: ${dir}`);
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider(
    options?.slow ? { tokensPerSecond: 10, tokenSize: { min: 1, max: 1 } } : {},
  );
  faux.setResponses(responses);
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
      ...options?.settings,
    }),
  );
  const storage = new Storage(dir);
  storage.updateConfig({ experimental: { serverDurable: true } });
  const workspace = storage.createWorkspace({ name: "Durable proof", hostMount: dir });
  const session = storage.createSession("Durable proof", "faux/faux-1");
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  return { dir, models, faux, storage, workspace, session, manager };
}

function observe(manager: SessionManager, sessionId: string) {
  const messages: ServerMessage[] = [];
  const pending = new Set<{
    predicate: (message: ServerMessage) => boolean;
    resolve: (message: ServerMessage) => void;
  }>();
  const unsubscribe = manager.subscribe(sessionId, (message) => {
    messages.push(message);
    for (const waiter of pending)
      if (waiter.predicate(message)) {
        pending.delete(waiter);
        waiter.resolve(message);
      }
  });
  return {
    messages,
    unsubscribe,
    next(predicate: (message: ServerMessage) => boolean): Promise<ServerMessage> {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(waiter);
          reject(
            new Error(
              `Expected durable projection event; observed ${messages.map((message) => message.type).join(",")}`,
            ),
          );
        }, 8_000);
        const waiter = {
          predicate,
          resolve: (message: ServerMessage) => {
            clearTimeout(timer);
            resolve(message);
          },
        };
        pending.add(waiter);
      });
    },
  };
}

async function openHarness(
  dir: string,
  models: ModelRuntime,
  tool?: ToolRegistration,
): Promise<Harness> {
  const registry = createRegistry();
  registry.install(CodingTools);
  registry.install(DurableAsk);
  registry.install(DurableGoal);
  registry.install(DurableWorkingWords);
  registry.install(DurableBackgroundJobs);
  if (tool) registry.install({ name: "restart-proof", tools: [tool] });
  const harness = await Harness.open(
    await openNodeSqliteStorage(join(dir, "restart.sqlite")),
    {
      models,
      registry,
      env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? dir }),
      settings: { compaction: { enabled: false } },
    },
    context,
  );
  harnesses.push(harness);
  return harness;
}

async function backend(harness: Harness, models: ModelRuntime, session: Session, dataDir: string) {
  const owner = new DurableHarness(dataDir);
  vi.spyOn(owner, "open").mockResolvedValue({ harness, models });
  await owner.releaseResume();
  const result = await DurableBackend.create({
    harness,
    owner,
    models,
    session,
    dataDir,
    persistBinding: () => {},
    onEvent: () => {},
  });
  result.startEvents();
  return result;
}

async function crashedQueuedTools(f: Awaited<ReturnType<typeof fixture>>) {
  const sessions = [f.session, f.storage.createSession("Queued tool B", "faux/faux-1")];
  const secondWorkspace = f.storage.createWorkspace({
    name: "Second crash workspace",
    hostMount: f.dir,
  });
  const effects: number[] = [];
  let recovering = false;
  let count = 0;
  let allEntered!: () => void;
  const entered = new Promise<void>((resolve) => {
    allEntered = resolve;
  });
  const tool: ToolRegistration = {
    name: "startup_counter",
    description: "Controlled tool recovery",
    parameters: Type.Object({}),
    replay: "safe",
    async execute(_args, api, callContext) {
      if (!recovering) {
        if (++count === sessions.length) allEntered();
        await new Promise<void>((_resolve, reject) => {
          callContext.abortSignal!.addEventListener(
            "abort",
            () => reject(callContext.abortSignal!.reason),
            { once: true },
          );
        });
      }
      effects.push(api.conversationId);
      return { content: [{ type: "text", text: "counted" }] };
    },
  };
  let harness = await openHarness(f.dir, f.models, tool);
  const tasks = [];
  for (const [index, session] of sessions.entries()) {
    const conversation = await harness.createConversation(
      {
        ownership: { kind: "ownerless" },
        agent: { model: { provider: "faux", modelId: "faux-1" }, tools: [tool], cwd: f.dir },
      },
      context,
    );
    session.workspaceId = index === 0 ? f.workspace.id : secondWorkspace.id;
    session.serverDurable = { conversationId: conversation.id };
    session.status = "busy";
    f.storage.saveSession(session);
    tasks.push(
      await conversation.commit(async (tx) => {
        const assistant = await tx.appendEntry(AssistantEntry, conversation.id, {
          model: [
            {
              role: "assistant",
              content: [fauxToolCall(tool.name, {}, { id: "startup" })],
              api: "faux",
              provider: "faux",
              model: "faux-1",
              usage: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 0,
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
              },
              stopReason: "toolUse",
              timestamp: 1,
            },
          ],
        });
        return tx.createTask(
          ToolTask,
          { assistant: assistant.id, callId: "startup" },
          { ownership: { kind: "conversation" } },
        );
      }, context),
    );
  }
  harness.resume();
  await entered;
  await harness.close(context);
  harnesses.splice(harnesses.indexOf(harness), 1);
  recovering = true;
  harness = await openHarness(f.dir, f.models, tool);
  vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
  vi.spyOn(f.storage, "listSessions").mockImplementation(() =>
    sessions.map((session) => f.storage.getSession(session.id)!),
  );
  queueOrphanedSessionsForRestart(f.storage);
  return { sessions, secondWorkspace, effects, harness, tasks };
}

describe("server durable managed runtime", () => {
  const questions = [
    {
      id: "color",
      question: "Favorite color?",
      options: [
        { value: "red", label: "Red" },
        { value: "blue", label: "Blue" },
      ],
    },
    {
      id: "extras",
      question: "Which extras?",
      options: [
        { value: "tests", label: "Tests" },
        { value: "docs", label: "Docs" },
      ],
      multiSelect: true,
    },
  ];
  const askResponse = { color: "red", extras: ["tests", "custom extra"] };
  const askStep = () =>
    fauxAssistantMessage([fauxToolCall("ask", { questions })], { stopReason: "toolUse" });

  it("enrolls goal tools on the managed backend and projects one continuation and its budget blocker", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxToolCall("create_goal", {
            objective: "Prove native goal wiring",
            max_continuations: 1,
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Initial goal run settled"),
      fauxAssistantMessage("One continuation finished"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    const blocked = observed.next(
      (m) =>
        m.type === "extension_ui_notification" &&
        m.method === "setStatus" &&
        m.statusKey === "goal" &&
        m.statusText === "goal: Blocked 1/1",
    );
    const blockedWidget = observed.next(
      (m) =>
        m.type === "extension_ui_notification" &&
        m.method === "setWidget" &&
        JSON.stringify(m.nativeSurface).includes("Continuation budget exhausted (1/1)."),
    );
    const stopNotice = observed.next(
      (m) =>
        m.type === "notice" &&
        m.message === "Goal runner · stop — Continuation budget exhausted (1/1).",
    );
    await f.manager.sendPrompt(f.session.id, "Create an explicit autonomous goal", {
      clientTurnId: "managed-goal",
    });
    await Promise.all([blocked, blockedWidget, stopNotice]);
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      role: string;
      toolName?: string;
      isError?: boolean;
    }>;
    expect(history.filter((m) => m.role === "user")).toHaveLength(2);
    expect(JSON.stringify(history)).not.toContain("[Goal runner]");
    expect(history.filter((m) => m.role === "toolResult" && m.toolName === "create_goal")).toEqual([
      expect.objectContaining({ isError: false }),
    ]);
    expect(observed.messages.filter((m) => m.type === "agent_end")).toHaveLength(2);
    expect(JSON.stringify(observed.messages)).not.toContain("[Goal runner]");
    const service = new SessionTraceService({
      storage: f.storage,
      sessionRuntimes: f.manager,
      ensureSessionContextWindow: (session) => session,
      mobileRenderers: f.manager.mobileRenderer,
    });
    const result = await service.getSessionWithTrace({ session: f.session });
    const cards = result.trace.filter((event) =>
      event.presentation?.title.startsWith("Goal runner ·"),
    );
    expect(cards.map((event) => event.presentation?.status)).toEqual([
      "update",
      "continue",
      "stop",
    ]);
    expect(
      cards.every((event) => event.type === "system" && event.presentation?.kind === "custom"),
    ).toBe(true);
    expect(cards[1]?.presentation?.body).toContain(
      "Run settled; no pending messages or compaction",
    );
    expect(cards[2]?.presentation?.body).toBe("Continuation budget exhausted (1/1).");
    const notices = observed.messages.filter((m) => m.type === "notice");
    expect(notices).toHaveLength(cards.length);
    expect(notices.map((m) => m.id)).toEqual(cards.map((event) => `entry:${event.id}`));
    expect(new Set(notices.map((m) => m.id)).size).toBe(cards.length);
    await service.getSessionWithTrace({ session: f.session });
    expect(observed.messages.filter((m) => m.type === "notice")).toHaveLength(cards.length);
    observed.unsubscribe();
  });

  it("pages and outlines stopped durable goal decision cards in full-trace order without model rows", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [fauxToolCall("create_goal", { objective: "Keep decision history", max_continuations: 1 })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Initial run settled"),
      fauxAssistantMessage("Continuation settled"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    const stopped = observed.next(
      (message) =>
        message.type === "notice" &&
        message.message === "Goal runner · stop — Continuation budget exhausted (1/1).",
    );
    await f.manager.sendPrompt(f.session.id, "Create an explicit autonomous goal");
    await stopped;
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      role: string;
    }>;
    expect(history.filter((message) => message.role === "user")).toHaveLength(2);
    expect(JSON.stringify(history)).not.toContain("[Goal runner]");
    await f.manager.stopSession(f.session.id);
    observed.unsubscribe();

    // Exercise the GET handlers and their JSON wire responses with the real
    // manager/storage, not a mocked page or outline. Only the provider is faux.
    const dispatch = createSessionRoutes(
      {
        storage: f.storage,
        sessions: f.manager,
        sessionRuntimes: f.manager,
        ensureSessionContextWindow: (session: Session) => session,
      } as unknown as RouteContext,
      createRouteHelpers(),
    );
    async function get<T>(path: string): Promise<T> {
      const url = new URL(path, "http://localhost");
      const res = makeResponse();
      expect(
        await dispatch({
          method: "GET",
          path: url.pathname,
          url,
          req: makeRequest(),
          res: res as never,
        }),
      ).toBe(true);
      expect(res.statusCode).toBe(200);
      return JSON.parse(res.body) as T;
    }
    const full = await get<{ trace: TraceEvent[] }>(`/sessions/${f.session.id}/trace?view=full`);
    const cards = full.trace.filter((event) =>
      event.presentation?.title.startsWith("Goal runner ·"),
    );
    expect(cards.map((event) => event.presentation?.status)).toEqual([
      "update",
      "continue",
      "stop",
    ]);
    expect(
      cards.every((event) => event.type === "system" && event.presentation?.kind === "custom"),
    ).toBe(true);
    expect(cards[1]?.presentation?.body).toContain(
      "Run settled; no pending messages or compaction",
    );
    expect(cards[2]?.presentation?.body).toBe("Continuation budget exhausted (1/1).");

    const base = `/workspaces/${f.workspace.id}/sessions/${f.session.id}`;
    const pages: TracePageResult[] = [];
    const paged: TraceEvent[] = [];
    let cursor: string | null = null;
    do {
      const query = new URLSearchParams({ targetEvents: "1" });
      if (cursor) query.set("cursor", cursor);
      const page = await get<TracePageResult>(`${base}/trace-page?${query}`);
      expect(page.page.staleCursor).toBe(false);
      expect(page.trace.length).toBeGreaterThan(0);
      expect(page.page.hasOlder).toBe(page.page.olderCursor !== null);
      pages.push(page);
      paged.unshift(...page.trace);
      cursor = page.page.olderCursor;
      // Fail a non-advancing cursor rather than leave the test in an unbounded loop.
      expect(pages.length).toBeLessThanOrEqual(full.trace.length);
    } while (cursor);
    expect(pages.length).toBeGreaterThan(1);
    expect(paged.filter((event) => event.presentation?.kind === "custom")).toEqual(cards);

    const outline = await get<TraceOutlineResult>(`${base}/trace-outline`);
    const rows = outline.outline.entries.filter((entry) => entry.kind === "custom");
    expect(
      rows.map(({ id, kind, summary, timestamp }) => ({ id, kind, summary, timestamp })),
    ).toEqual(
      cards.map((event) => ({
        id: event.id,
        kind: "custom",
        summary: event.presentation!.title,
        timestamp: event.timestamp,
      })),
    );
    // Outline rows deliberately omit card bodies. The client's anchor fetch
    // must retrieve the same complete system/custom event, including its reason.
    for (const card of cards) {
      const around = await get<TracePageResult>(
        `${base}/trace-page?targetEvents=1&aroundEntryId=${encodeURIComponent(card.id)}`,
      );
      expect(around.page.staleCursor).toBe(false);
      expect(around.trace.find((event) => event.id === card.id)).toEqual(card);
    }
    writeFileSync(
      join(f.dir, "goal-decision-history.json"),
      JSON.stringify({ full, pages, outline, modelMessages: history }, null, 2),
    );
  });

  it("projects SDK-identical ask fields, replays pending on reconnect, and commits only the first answer", async () => {
    const f = await fixture([askStep(), fauxAssistantMessage("ANSWER_RECEIVED")]);
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    const request = observed.next((m) => m.type === "extension_ui_request" && m.method === "ask");
    await f.manager.sendPrompt(f.session.id, "Ask both questions");
    const shown = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
    let classic: ServerMessage | undefined;
    const bridge = new SdkUiBridge(
      (event) => {
        if (event.type === "extension_ui_request")
          classic = buildExtensionUIRequestMessage(f.session.id, event);
      },
      () => false,
    );
    const ui = bridge.createContext() as unknown as {
      ask: (questions: typeof questions) => Promise<unknown>;
    };
    const classicAnswer = ui.ask(questions);
    expect(JSON.parse(JSON.stringify(shown))).toEqual(
      JSON.parse(
        JSON.stringify({
          ...classic,
          id: shown.id,
          extensionScopeId: "repo:ask",
          extensionDisplayName: "Ask",
        }),
      ),
      // SDK provenance comes from its caller stack (Vitest here, not ask).
      // All other wire fields are compared without overrides.
    );
    expect(f.manager.getPendingUIRequestMessages(f.session.id)).toContainEqual(shown);
    const end = observed.next((m) => m.type === "agent_end");
    const replies = await Promise.all([
      f.manager.respondToUIRequest(f.session.id, {
        type: "extension_ui_response",
        id: shown.id,
        value: JSON.stringify(askResponse),
      }),
      f.manager.respondToUIRequest(f.session.id, {
        type: "extension_ui_response",
        id: shown.id,
        value: JSON.stringify({ color: "blue" }),
      }),
    ]);
    expect(replies).toEqual([true, false]);
    await end;
    expect(
      f.manager
        .getPendingUIRequestMessages(f.session.id)
        .filter((m) => m.type === "extension_ui_request"),
    ).toEqual([]);
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      role: string;
      toolName?: string;
      details?: unknown;
    }>;
    expect(history.filter((m) => m.role === "toolResult" && m.toolName === "ask")).toEqual([
      expect.objectContaining({ details: { questions, answers: askResponse, allIgnored: false } }),
    ]);
    expect(
      observed.messages.filter((m) => m.type === "extension_ui_settled" && m.id === shown.id),
    ).toHaveLength(1);
    bridge.dispose();
    await classicAnswer;
  });

  it("restores the same pending ask after reopening SQLite, then completes the original call once", async () => {
    const f = await fixture([askStep(), fauxAssistantMessage("RESTART_ANSWER_RECEIVED")]);
    await f.manager.startSession(f.session.id, f.workspace);
    let observed = observe(f.manager, f.session.id);
    const request = observed.next((m) => m.type === "extension_ui_request" && m.method === "ask");
    await f.manager.sendPrompt(f.session.id, "Ask and survive", { clientTurnId: "ask-restart" });
    const shown = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
    recordLiveSessionsForRestart(f.storage, [f.manager.getActiveSession(f.session.id)!]);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    f.manager = new SessionManager(new Storage(f.dir));
    managers.push(f.manager);
    await f.manager.resumeDurableSessions();
    expect(f.manager.getPendingUIRequestMessages(f.session.id)).toContainEqual(
      expect.objectContaining({ id: shown.id, questions }),
    );
    observed = observe(f.manager, f.session.id);
    const end = observed.next((m) => m.type === "agent_end");
    expect(
      await f.manager.respondToUIRequest(f.session.id, {
        type: "extension_ui_response",
        id: shown.id,
        value: JSON.stringify(askResponse),
      }),
    ).toBe(true);
    await end;
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      role: string;
      toolName?: string;
      isError?: boolean;
    }>;
    expect(history.filter((m) => m.role === "user")).toHaveLength(1);
    expect(history.filter((m) => m.role === "toolResult" && m.toolName === "ask")).toEqual([
      expect.objectContaining({ isError: false }),
    ]);
    expect(f.faux.state.callCount).toBe(2);
    expect(
      await f.manager.respondToUIRequest(f.session.id, {
        type: "extension_ui_response",
        id: shown.id,
        cancelled: true,
      }),
    ).toBe(false);
  });

  it.each(["abort", "stop"])(
    "%s cancels the pending ask without running the answer turn",
    async (action) => {
      const f = await fixture([askStep(), fauxAssistantMessage("MUST_NOT_RUN")]);
      await f.manager.startSession(f.session.id, f.workspace);
      const observed = observe(f.manager, f.session.id);
      const request = observed.next((m) => m.type === "extension_ui_request" && m.method === "ask");
      await f.manager.sendPrompt(f.session.id, "Ask until stopped");
      const shown = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
      if (action === "abort") await f.manager.sendAbort(f.session.id);
      else await f.manager.stopSession(f.session.id);
      expect(
        f.manager
          .getPendingUIRequestMessages(f.session.id)
          .filter((m) => m.type === "extension_ui_request"),
      ).toEqual([]);
      expect(
        await f.manager.respondToUIRequest(f.session.id, {
          type: "extension_ui_response",
          id: shown.id,
          value: "{}",
        }),
      ).toBe(false);
      expect(f.faux.state.callCount).toBe(1);
      expect(observed.messages).toContainEqual(
        expect.objectContaining({ type: "extension_ui_settled", id: shown.id }),
      );
    },
  );

  it("allows only one ask in a model turn but allows ask again in the next turn", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxToolCall("ask", { questions }, { id: "first" }),
          fauxToolCall("ask", { questions }, { id: "second" }),
        ],
        { stopReason: "toolUse" },
      ),
      askStep(),
      fauxAssistantMessage("DONE"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    let request = observed.next((m) => m.type === "extension_ui_request" && m.method === "ask");
    await f.manager.sendPrompt(f.session.id, "Two calls in one turn, another next turn");
    const first = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
    request = observed.next((m) => m.type === "extension_ui_request" && m.method === "ask");
    await f.manager.respondToUIRequest(f.session.id, {
      type: "extension_ui_response",
      id: first.id,
      cancelled: true,
    });
    const second = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
    expect(second.id).not.toBe(first.id);
    const end = observed.next((m) => m.type === "agent_end");
    await f.manager.respondToUIRequest(f.session.id, {
      type: "extension_ui_response",
      id: second.id,
      cancelled: true,
    });
    await end;
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      role: string;
      toolName?: string;
      isError?: boolean;
      content?: unknown;
    }>;
    const results = history.filter((m) => m.role === "toolResult" && m.toolName === "ask");
    expect(results).toHaveLength(3);
    expect(results.filter((m) => m.isError)).toEqual([
      expect.objectContaining({
        content: expect.arrayContaining([
          expect.objectContaining({ text: expect.stringContaining("Only one ask call per turn") }),
        ]),
      }),
    ]);
  });
  it.each(["before", "after"] as const)(
    "survives a crash %s the answer memo and removes the answered row on replay",
    async (gap) => {
      const native = DurableAsk.tools![0]!;
      let saving!: () => void;
      const savingMemo = new Promise<void>((resolve) => {
        saving = resolve;
      });
      const wrapped: ToolRegistration = {
        ...native,
        async execute(args, api, ctx) {
          const memo = new Proxy(api.memo, {
            async apply(target, receiver, values) {
              if (String(values[0]).startsWith("ui-answer:") && values.length === 3) {
                if (gap === "after") await Reflect.apply(target, receiver, values);
                saving();
                return new Promise((_resolve, reject) => {
                  ctx.abortSignal!.addEventListener(
                    "abort",
                    () => reject(ctx.abortSignal!.reason),
                    {
                      once: true,
                    },
                  );
                });
              }
              return Reflect.apply(target, receiver, values);
            },
          });
          return native.execute(args as never, { ...api, memo }, ctx);
        },
      };
      const f = await fixture([askStep(), fauxAssistantMessage("MEMO_GAP_RECOVERED")]);
      let harness = await openHarness(f.dir, f.models, wrapped);
      const conversation = await harness.createConversation(
        {
          ownership: { kind: "ownerless" },
          agent: { model: { provider: "faux", modelId: "faux-1" }, tools: [wrapped], cwd: f.dir },
        },
        context,
      );
      f.session.serverDurable = { conversationId: conversation.id };
      const owner = new DurableHarness(f.dir);
      vi.spyOn(owner, "open").mockResolvedValue({ harness, models: f.models });
      await owner.releaseResume();
      let shown!: UIResponse;
      let show!: () => void;
      const displayed = new Promise<void>((resolve) => {
        show = resolve;
      });
      const first = await DurableBackend.create({
        harness,
        owner,
        models: f.models,
        session: f.session,
        dataDir: f.dir,
        persistBinding: () => {},
        onEvent: (event) => {
          if (event.type === "extension_ui_request" && event.method === "ask") {
            shown = { id: event.id, value: JSON.stringify(askResponse) };
            show();
          }
        },
      });
      first.startEvents();
      await first.prompt("Ask and cross the answer/memo crash window");
      await displayed;
      expect(await first.respondToExtensionUIRequest(shown)).toBe(true);
      await savingMemo;
      await first.detachForRestart();
      await harness.close(context);
      harnesses.splice(harnesses.indexOf(harness), 1);
      harness = await openHarness(f.dir, f.models);
      const resumed = await backend(harness, f.models, f.session, f.dir);
      harness.resume();
      await (await harness.conversation(conversation.id, context))!.waitForIdle(context);
      const results = resumed.messages().filter((m) => m.role === "toolResult") as Array<{
        details?: unknown;
        isError?: boolean;
      }>;
      expect(results).toEqual([
        expect.objectContaining({
          isError: false,
          details: { questions, answers: askResponse, allIgnored: false },
        }),
      ]);
      expect(f.faux.state.callCount).toBe(2);
      const restored = (await harness.conversation(conversation.id, context))!;
      expect(
        await restored.commit(
          async (tx) => Object.keys((await tx.doc(DurableUI, conversation.id)).requests),
          context,
        ),
      ).toEqual([]);
      await resumed.dispose();
    },
  );

  it("committed hostile UI JSON reaches handlePiEvent only as allowlisted UI requests", async () => {
    const f = await fixture([]);
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    const handled = vi.spyOn(SessionAgentEventCoordinator.prototype, "handlePiEvent");
    await f.manager.startSession(f.session.id, f.workspace);
    const { harness } = await opening.mock.results[0]!.value;
    const id = f.storage.getSession(f.session.id)!.serverDurable!.conversationId!;
    const conversation = (await harness.conversation(id, context))!;
    await conversation.commit(async (tx) => {
      const ui = await tx.doc(DurableUI, id);
      for (const type of ["message_end", "agent_end", "tool_execution_end"]) {
        ui.requests[`hostile:${type}`] = {
          taskId: 999 as Parameters<typeof requestUI>[0]["taskId"],
          request: {
            id: "forged",
            method: "confirm",
            title: "Safe dialog",
            type,
            details: { fullOutputPath: "/private/file" },
            extra: true,
          } as Parameters<typeof requestUI>[1],
        };
        ui.notifications[`hostile:slot:${type}`] = {
          id: "forged",
          method: "setStatus",
          statusKey: `safe:${type}`,
          statusText: "ready",
          type,
          details: { fullOutputPath: "/private/file" },
        } as UINotification;
      }
      ui.requests["hostile:unknown"] = {
        taskId: 999 as Parameters<typeof requestUI>[0]["taskId"],
        request: { id: "unknown", method: "tool_execution_end" } as unknown as Parameters<
          typeof requestUI
        >[1],
      };
    }, context);
    const hostileEvents = () =>
      handled.mock.calls
        .map(([, event]) => event)
        .filter(
          (event) =>
            "id" in event && typeof event.id === "string" && event.id.startsWith("hostile:"),
        );
    await vi.waitFor(() => expect(hostileEvents()).toHaveLength(6));
    for (const event of hostileEvents()) {
      expect(event.type).toBe("extension_ui_request");
      expect(event).not.toHaveProperty("details");
      expect(event).not.toHaveProperty("extra");
    }
    expect(
      f.manager
        .getPendingUIRequestMessages(f.session.id)
        .filter(
          (message) =>
            "id" in message &&
            message.id.startsWith("hostile:") &&
            message.type === "extension_ui_request",
        ),
    ).toHaveLength(3);
  });

  it.each(["select", "confirm", "input", "editor"] as const)(
    "relays generic %s with committed answers and reconnect state",
    async (method) => {
      const fields = {
        title: "Choose",
        message: "Continue?",
        options: ["A", "B"],
        placeholder: "Type",
        prefill: "Draft",
      };
      const probe = defineTool({
        name: "ui_probe",
        description: "Generic UI proof",
        parameters: Type.Object({}),
        replay: "safe",
        async execute(_args, api, ctx) {
          const response = await requestUI(
            api,
            { id: `probe:${api.taskId}`, method, ...fields },
            ctx,
          );
          return { content: [{ type: "text", text: JSON.stringify(response) }] };
        },
      });
      const f = await fixture([
        fauxAssistantMessage([fauxToolCall(probe.name, {})], { stopReason: "toolUse" }),
        fauxAssistantMessage("GENERIC_UI_DONE"),
      ]);
      const harness = await openHarness(f.dir, f.models, probe);
      vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
      await f.manager.startSession(f.session.id, f.workspace);
      const conversation = (await harness.conversation(
        f.storage.getSession(f.session.id)!.serverDurable!.conversationId!,
        context,
      ))!;
      await conversation.configure(
        { extensions: { add: [{ name: "restart-proof", tools: [probe] }] }, tools: [probe] },
        context,
      );
      const observed = observe(f.manager, f.session.id);
      const request = observed.next(
        (m) => m.type === "extension_ui_request" && m.method === method,
      );
      await f.manager.sendPrompt(f.session.id, "Run generic UI");
      const shown = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
      expect(shown).toMatchObject({ method, ...fields });
      expect(f.manager.getPendingUIRequestMessages(f.session.id)).toContainEqual(shown);
      const end = observed.next((m) => m.type === "agent_end");
      expect(
        await f.manager.respondToUIRequest(f.session.id, {
          type: "extension_ui_response",
          id: shown.id,
          value: "A",
          confirmed: true,
        }),
      ).toBe(true);
      await end;
      const messages = (await f.manager.runCommand(f.session.id, {
        type: "get_messages",
      })) as Array<{ role: string; toolName?: string; content?: unknown }>;
      expect(
        messages.find((m) => m.toolName === probe.name && m.role === "toolResult"),
      ).toMatchObject({
        content: [
          { type: "text", text: JSON.stringify({ id: shown.id, value: "A", confirmed: true }) },
        ],
      });
    },
  );

  it("replays generic native widgets/status and working words, sanitizes fields, and explicitly clears slots", async () => {
    const f = await fixture([askStep(), fauxAssistantMessage("DONE")]);
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const { harness } = await opening.mock.results[0]!.value;
    const id = f.storage.getSession(f.session.id)!.serverDurable!.conversationId!;
    const conversation = (await harness.conversation(id, context))!;
    const observed = observe(f.manager, f.session.id);
    const request = observed.next((m) => m.type === "extension_ui_request" && m.method === "ask");
    await f.manager.sendPrompt(f.session.id, "Hold a working turn");
    await request;
    const asking = /^(Waiting on you|Your move|Need a nod|Holding for you)( · \d+s)?$/;
    // Matches the classic working-message extension: an activity phrase, no
    // status pill, and Pi's default indicator (earlier slots are cleared).
    const working = await observed.next(
      (m) =>
        m.type === "extension_ui_notification" &&
        m.method === "setWorkingMessage" &&
        typeof m.message === "string" &&
        asking.test(m.message),
    );
    expect(working).toMatchObject({ method: "setWorkingMessage" });
    const notifications = f.manager
      .getPendingUIRequestMessages(f.session.id)
      .filter((m) => m.type === "extension_ui_notification");
    const status = notifications.find(
      (m) => m.method === "setStatus" && m.statusKey === "working-words",
    );
    expect(status).toBeDefined();
    expect((status as { statusText?: string }).statusText).toBeUndefined();
    const indicator = notifications.find((m) => m.method === "setWorkingIndicator");
    expect(indicator).toBeDefined();
    expect((indicator as { workingIndicator?: unknown }).workingIndicator).toBeUndefined();
    const elapsed = await observed.next(
      (m) =>
        m.type === "extension_ui_notification" &&
        m.method === "setWorkingMessage" &&
        typeof m.message === "string" &&
        / · \d+s$/.test(m.message),
    );
    expect((elapsed as { message: string }).message).toMatch(asking);
    const widget = observed.next(
      (m) => m.type === "extension_ui_notification" && m.widgetKey === "arbitrary-widget",
    );
    await conversation.commit(async (tx) => {
      const ui = await tx.doc(DurableUI, id);
      ui.notifications["widget:arbitrary-widget"] = {
        id: "widget-update",
        method: "setWidget",
        widgetKey: "arbitrary-widget",
        widgetPlacement: "belowEditor",
        widgetLines: ["\u001b[31mReadable\u001b[0m"],
        extensionScopeId: "repo:arbitrary",
        extensionDisplayName: "Arbitrary",
        nativeSurface: {
          version: 1,
          id: "widget:arbitrary-widget",
          source: "widget",
          presentation: { style: "surfacePanel", title: "Generic panel" },
          blocks: [{ type: "text", spans: [{ text: "Readable" }] }],
          fallback: { lines: ["Readable"] },
        },
      };
    }, context);
    expect(await widget).toMatchObject({
      widgetLines: ["Readable"],
      widgetPlacement: "belowEditor",
      extensionDisplayName: "Arbitrary",
      nativeSurface: { presentation: { title: "Generic panel" } },
    });
    expect(f.manager.getPendingUIRequestMessages(f.session.id)).toContainEqual(
      expect.objectContaining({ widgetKey: "arbitrary-widget" }),
    );
    const cleared = observed.next(
      (m) =>
        m.type === "extension_ui_notification" &&
        m.widgetKey === "arbitrary-widget" &&
        !m.nativeSurface,
    );
    await conversation.commit(async (tx) => {
      (await tx.doc(DurableUI, id)).notifications["widget:arbitrary-widget"] = {
        id: "widget-clear",
        method: "setWidget",
        widgetKey: "arbitrary-widget",
      };
    }, context);
    await cleared;
    const replayClear = f.manager
      .getPendingUIRequestMessages(f.session.id)
      .find(
        (message) =>
          message.type === "extension_ui_notification" &&
          message.method === "setWidget" &&
          message.widgetKey === "arbitrary-widget",
      );
    expect(replayClear).toMatchObject({
      method: "setWidget",
      widgetKey: "arbitrary-widget",
      widgetLines: undefined,
    });
    expect(replayClear).not.toHaveProperty("nativeSurface");
    await f.manager.sendAbort(f.session.id);
  });

  it("commits timeout cancellation and rejects a late generic answer", async () => {
    const probe = defineTool({
      name: "timeout_probe",
      description: "UI deadline proof",
      parameters: Type.Object({}),
      replay: "safe",
      async execute(_args, api, ctx) {
        const response = await requestUI(
          api,
          { id: `timeout:${api.taskId}`, method: "confirm", title: "Expires", timeout: 25 },
          ctx,
        );
        return { content: [{ type: "text", text: response.cancelled ? "TIMED_OUT" : "ANSWERED" }] };
      },
    });
    const f = await fixture([
      fauxAssistantMessage([fauxToolCall(probe.name, {})], { stopReason: "toolUse" }),
      fauxAssistantMessage("AFTER_TIMEOUT"),
    ]);
    const harness = await openHarness(f.dir, f.models, probe);
    vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
    await f.manager.startSession(f.session.id, f.workspace);
    const conversation = (await harness.conversation(
      f.storage.getSession(f.session.id)!.serverDurable!.conversationId!,
      context,
    ))!;
    await conversation.configure(
      { extensions: { add: [{ name: "restart-proof", tools: [probe] }] }, tools: [probe] },
      context,
    );
    const observed = observe(f.manager, f.session.id);
    const request = observed.next(
      (m) => m.type === "extension_ui_request" && m.method === "confirm",
    );
    const end = observed.next((m) => m.type === "agent_end");
    await f.manager.sendPrompt(f.session.id, "Expire a UI request");
    const shown = (await request) as Extract<ServerMessage, { type: "extension_ui_request" }>;
    expect(shown).toMatchObject({ timeout: 25, timeoutAt: expect.any(Number) });
    await end;
    expect(
      await f.manager.respondToUIRequest(f.session.id, {
        type: "extension_ui_response",
        id: shown.id,
        confirmed: true,
      }),
    ).toBe(false);
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      role: string;
      toolName?: string;
      content?: unknown;
    }>;
    expect(history.find((m) => m.role === "toolResult" && m.toolName === probe.name)).toMatchObject(
      { content: [{ type: "text", text: "TIMED_OUT" }] },
    );
  });

  const compactionSettings = {
    compaction: { enabled: true, keepRecentTokens: 1, reserveTokens: 100, backgroundTokens: 0 },
    retry: { enabled: true, maxRetries: 2, baseDelayMs: 20 },
  };

  async function answer(
    f: Awaited<ReturnType<typeof fixture>>,
    observed: ReturnType<typeof observe>,
    text: string,
  ) {
    const end = observed.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(f.session.id, text);
    await end;
  }

  it.each([false, true])(
    "projects one retry loop end with configured attempts (exhaust=%s)",
    async (exhaust) => {
      const failure = () =>
        fauxAssistantMessage("", { stopReason: "error", errorMessage: "429 overloaded" });
      const f = await fixture(
        [failure(), failure(), exhaust ? failure() : fauxAssistantMessage("RECOVERED")],
        {
          settings: { retry: { enabled: true, maxRetries: 2, baseDelayMs: 20 } },
        },
      );
      await f.manager.startSession(f.session.id, f.workspace);
      const observed = observe(f.manager, f.session.id);
      await answer(f, observed, "retry");
      const starts = observed.messages.filter((message) => message.type === "retry_start");
      expect(starts).toHaveLength(2);
      expect(starts).toMatchObject([
        { attempt: 1, maxAttempts: 2 },
        { attempt: 2, maxAttempts: 2 },
      ]);
      for (const start of starts) expect(start.delayMs).toBeGreaterThanOrEqual(0);
      expect(observed.messages.filter((message) => message.type === "retry_end")).toEqual([
        expect.objectContaining({
          success: !exhaust,
          attempt: 2,
          ...(exhaust ? { finalError: "429 overloaded" } : {}),
        }),
      ]);
      observed.unsubscribe();
    },
  );

  it("projects manual summary and start-time context tokens and resets cache state", async () => {
    const flush = vi.spyOn(
      SessionMessageQueueCoordinator.prototype,
      "schedulePostCompactionQueueFlush",
    );
    const f = await fixture(
      [
        fauxAssistantMessage("Earlier context ".repeat(50)),
        fauxAssistantMessage("Latest context"),
        fauxAssistantMessage("## Goal\nPreserve names"),
      ],
      { settings: compactionSettings },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    await answer(f, observed, "first");
    await answer(f, observed, "second");
    const active = (
      f.manager as unknown as { active: Map<string, { cacheMissTracker: { previous?: unknown } }> }
    ).active.get(f.session.id);
    // Existing SDK coordinator owns cache reset; verify the projected result reaches it.
    expect(active?.cacheMissTracker.previous).toBeDefined();
    const end = observed.next((message) => message.type === "compaction_end");
    await f.manager.runCommand(f.session.id, { type: "compact" });
    expect(await end).toMatchObject({
      aborted: false,
      willRetry: false,
      summary: "## Goal\nPreserve names",
      tokensBefore: expect.any(Number),
    });
    expect(active?.cacheMissTracker.previous).toBeUndefined();
    expect(flush).toHaveBeenCalledTimes(1);
    const message = observed.messages.find((item) => item.type === "compaction_end");
    expect(message?.type === "compaction_end" && message.tokensBefore).toBeGreaterThan(0);
    expect(f.manager.getActiveSession(f.session.id)?.changeStats?.compactionCount).toBe(1);
    observed.unsubscribe();
  });

  it("suppresses recoverable overflow errors and projects compact-and-retry", async () => {
    const flush = vi.spyOn(
      SessionMessageQueueCoordinator.prototype,
      "schedulePostCompactionQueueFlush",
    );
    const f = await fixture(
      [
        fauxAssistantMessage("Old context ".repeat(50)),
        fauxAssistantMessage("", {
          stopReason: "error",
          errorMessage: "prompt is too long: 999999 tokens",
        }),
        fauxAssistantMessage("Overflow summary"),
        fauxAssistantMessage("FRESH ANSWER"),
      ],
      { settings: compactionSettings },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    await answer(f, observed, "first");
    await answer(f, observed, "overflow");
    expect(observed.messages.filter((message) => message.type === "error")).toEqual([]);
    expect(flush).not.toHaveBeenCalled();
    expect(observed.messages.filter((message) => message.type === "compaction_end")).toEqual([
      expect.objectContaining({
        aborted: false,
        willRetry: true,
        summary: "Overflow summary",
        tokensBefore: expect.any(Number),
      }),
    ]);
    expect(
      observed.messages.filter(
        (message) => message.type === "message_end" && message.role === "assistant",
      ),
    ).toHaveLength(2);
    expect(f.manager.getActiveSession(f.session.id)?.changeStats?.compactionCount).toBe(1);
    observed.unsubscribe();
  });

  it("emits held compaction_end before a follow-up starts in the same placement batch", async () => {
    let entered!: () => void;
    let release!: () => void;
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    const f = await fixture(
      [
        fauxAssistantMessage("Old context ".repeat(50)),
        fauxAssistantMessage("Recent"),
        async (_transcript, options) => {
          entered();
          await Promise.race([
            held,
            new Promise<void>((_resolve, reject) => {
              options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
                once: true,
              });
            }),
          ]);
          return fauxAssistantMessage("Finished turn");
        },
        fauxAssistantMessage("Later summary"),
        fauxAssistantMessage("FOLLOWUP ANSWER"),
      ],
      { settings: compactionSettings },
    );
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    await answer(f, observed, "first");
    await answer(f, observed, "second");
    const turnEnd = observed.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(f.session.id, "held generation");
    await started;
    const { harness } = await opening.mock.results[0]!.value;
    const conversation = await harness.conversation(
      f.storage.getSession(f.session.id)!.serverDurable!.conversationId,
      context,
    );
    const raw = await watchEvents(harness, conversation.id, context);
    const batches: AgentEvent[][] = [];
    raw.start(async (events) => {
      batches.push([...events]);
    });
    const compactEnd = observed.next((message) => message.type === "compaction_end");
    const id = await conversation.compact(undefined, context);
    const task = await harness.waitForTask(id, context);
    expect(task.state.outcome.status).toBe("completed");
    expect(observed.messages.filter((message) => message.type === "compaction_end")).toHaveLength(
      0,
    );
    const followUpAnswer = observed.next(
      (message) => message.type === "text_delta" && message.delta === "FOLLOWUP ANSWER",
    );
    await f.manager.sendFollowUp(f.session.id, "follow-up in placement batch");
    const placementStart = observed.messages.length;
    release();
    await turnEnd;
    expect(await compactEnd).toMatchObject({
      summary: "Later summary",
      aborted: false,
      willRetry: false,
      tokensBefore: expect.any(Number),
    });
    await followUpAnswer;
    await raw.stop();
    const placement = batches.find((batch) =>
      batch.some((event) => event.type === "message_end" && event.entry.kind === "pi.compaction"),
    );
    expect(placement).toBeDefined();
    expect(placement!.some((event) => event.type === "run_end")).toBe(true);
    expect(placement!.some((event) => event.type === "run_start")).toBe(true);
    expect(
      placement!.some((event) => event.type === "message_end" && event.entry.kind === "pi.user"),
    ).toBe(true);
    const messages = observed.messages.slice(placementStart);
    const compactIndex = messages.findIndex((message) => message.type === "compaction_end");
    const followUpIndex = messages.findIndex(
      (message) => message.type === "message_end" && message.role === "user",
    );
    const startIndex = messages.findIndex((message) => message.type === "agent_start");
    expect(compactIndex).toBeGreaterThanOrEqual(0);
    expect(followUpIndex).toBeGreaterThan(compactIndex);
    expect(startIndex).toBeGreaterThan(compactIndex);
    expect(messages.filter((message) => message.type === "compaction_end")).toHaveLength(1);
    observed.unsubscribe();
  });

  it("projects failed compaction without counting it", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage("Old context ".repeat(50)),
        fauxAssistantMessage("Latest"),
        fauxAssistantMessage("", { stopReason: "error", errorMessage: "invalid summary request" }),
      ],
      { settings: compactionSettings },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    await answer(f, observed, "first");
    await answer(f, observed, "second");
    const end = observed.next((message) => message.type === "compaction_end");
    await expect(f.manager.runCommand(f.session.id, { type: "compact" })).rejects.toThrow();
    expect(await end).toMatchObject({
      aborted: false,
      willRetry: false,
      errorMessage: expect.stringContaining("invalid summary request"),
    });
    expect(f.manager.getActiveSession(f.session.id)?.changeStats?.compactionCount).toBeUndefined();
    observed.unsubscribe();
  });

  it("projects cancelled compaction without counting it", async () => {
    let entered!: () => void;
    const summarizing = new Promise<void>((resolve) => {
      entered = resolve;
    });
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    const f = await fixture(
      [
        fauxAssistantMessage("Old context ".repeat(50)),
        fauxAssistantMessage("Latest"),
        async (_transcript, options) => {
          entered();
          return new Promise((_resolve, reject) => {
            options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
              once: true,
            });
          });
        },
      ],
      { settings: compactionSettings },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    await answer(f, observed, "first");
    await answer(f, observed, "second");
    const end = observed.next((message) => message.type === "compaction_end");
    const compact = f.manager.runCommand(f.session.id, { type: "compact" });
    const rejected = expect(compact).rejects.toThrow();
    await summarizing;
    const { harness } = await opening.mock.results[0]!.value;
    const task = (await harness.inspect(context)).tasks.find(
      (item: { record: { kind: string } }) => item.record.kind === "pi.compaction",
    );
    expect(task).toBeDefined();
    await harness.abortTask(task!.record.id, context);
    expect(await end).toMatchObject({ aborted: true, willRetry: false });
    await rejected;
    expect(f.manager.getActiveSession(f.session.id)?.changeStats?.compactionCount).toBeUndefined();
    observed.unsubscribe();
  });

  it.each(["crash", "stop", "crash-then-stop"])(
    "hides crash-retried partials but keeps user Stop in live and trace (%s)",
    async (mode) => {
      const stop = mode === "stop";
      const f = await fixture(
        [
          fauxAssistantMessage("INTERRUPTED partial ".repeat(100)),
          fauxAssistantMessage("FRESH COMPLETE"),
        ],
        { slow: true },
      );
      await f.manager.startSession(f.session.id, f.workspace);
      let observed = observe(f.manager, f.session.id);
      const partial = observed.next((message) => message.type === "text_delta");
      await f.manager.sendPrompt(f.session.id, "original");
      await partial;
      if (stop) {
        const end = observed.next((message) => message.type === "agent_end");
        await f.manager.sendAbort(f.session.id);
        await end;
      } else {
        recordLiveSessionsForRestart(f.storage, [f.manager.getActiveSession(f.session.id)!]);
        await f.manager.close();
        managers.splice(managers.indexOf(f.manager), 1);
        const models = f.faux;
        models.setResponses([
          fauxAssistantMessage(
            mode === "crash-then-stop" ? "FRESH regenerated partial ".repeat(100) : "FRESH",
          ),
        ]);
        const restarted = new SessionManager(new Storage(f.dir));
        managers.push(restarted);
        let end!: Promise<ServerMessage>;
        let retriedPartial!: Promise<ServerMessage>;
        const start = restarted.startSession.bind(restarted);
        vi.spyOn(restarted, "startSession").mockImplementation(async (id, workspace) => {
          const result = await start(id, workspace);
          observed = observe(restarted, id);
          end = observed.next((message) => message.type === "agent_end");
          if (mode === "crash-then-stop")
            retriedPartial = observed.next((message) => message.type === "text_delta");
          return result;
        });
        await restarted.resumeDurableSessions();
        if (mode === "crash-then-stop") {
          await retriedPartial;
          await restarted.sendAbort(f.session.id);
        }
        await end;
        f.manager = restarted;
      }
      const ends = observed.messages.filter(
        (message) => message.type === "message_end" && message.role === "assistant",
      );
      expect(ends).toHaveLength(1);
      const service = new SessionTraceService({
        storage: f.storage,
        sessionRuntimes: f.manager,
        ensureSessionContextWindow: (session) => session,
        mobileRenderers: f.manager.mobileRenderer,
      });
      const result = await service.getSessionWithTrace({ session: f.session });
      const assistants = result.trace.filter((event) => event.type === "assistant");
      expect(assistants).toHaveLength(1);
      expect(assistants[0]?.text).toContain(stop ? "INTE" : "FRES");
      observed.unsubscribe();
    },
  );
  it("enrolls sandbox sessions without SDK fallback, reads guest images and refuses runtime changes", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxToolCall("write", { path: "note.txt", content: "guest only" }),
          fauxToolCall("read", { path: "image.png" }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("done"),
    ]);
    f.workspace.runtime = "sandbox";
    f.storage.updateWorkspace(f.workspace.id, { runtime: "sandbox" });
    const root = resolveSandboxGuestCwd(f.workspace);
    const png = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      "base64",
    );
    const files = new Map<string, Buffer>([[`${root}/image.png`, png]]);
    const vm: GondolinVm = {
      fs: {
        mkdir: async () => {},
        access: async (path) => {
          if (path !== root && !files.has(path)) throw new Error("ENOENT");
        },
        readFile: async (path) => {
          const bytes = files.get(path);
          if (!bytes) throw new Error("ENOENT");
          return bytes;
        },
        writeFile: async (path, content) => {
          files.set(path, Buffer.from(content));
        },
      },
      exec: (argv) =>
        Object.assign(
          Promise.resolve({
            ok: true,
            exitCode: 0,
            stdout: argv.includes("oppi-realpath") ? `${argv.at(-1)}\0` : "",
            stdoutBuffer: argv.includes("oppi-realpath")
              ? Buffer.from(`${argv.at(-1)}\0`)
              : Buffer.alloc(0),
          }),
          {
            async *output() {},
            write() {},
            end() {},
          },
        ),
    };
    const ensure = vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue(vm);
    const sdk = vi.spyOn(SdkBackend, "create");
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const { harness } = await opening.mock.results[0]!.value;
    const id = f.storage.getSession(f.session.id)!.serverDurable!.conversationId as ConversationId;
    const conversation = (await harness.conversation(id, context))!;
    const agent = await conversation.agent(context);
    expect(agent.cwd).toBe(root);
    expect(agent.tools.map((tool) => tool.name)).toEqual([
      "read",
      "write",
      "edit",
      "bash",
      "ask",
      "get_goal",
      "create_goal",
      "update_goal",
      "ls",
      "find",
      "grep",
      "background_job",
    ]);
    const settled = await (
      await conversation.submit({ type: "input", content: "write and read" }, context)
    ).wait(context);
    expect(settled.status).toBe("done");
    expect(files.get(`${root}/note.txt`)?.toString()).toBe("guest only");
    expect(existsSync(join(f.dir, "note.txt"))).toBe(false);
    const page = await conversation.entries({}, 40, undefined, context);
    const image = page.items
      .flatMap((entry) => entry.model ?? [])
      .find((message) => message.role === "toolResult" && message.toolName === "read");
    expect(image).toMatchObject({
      isError: false,
      content: expect.arrayContaining([
        expect.objectContaining({ type: "image", mimeType: "image/png" }),
      ]),
    });
    expect(ensure).toHaveBeenCalledOnce();
    expect(sdk).not.toHaveBeenCalled();
    await f.manager.stopSession(f.session.id);
    f.workspace.runtime = "host";
    f.storage.updateWorkspace(f.workspace.id, { runtime: "host" });
    await expect(f.manager.startSession(f.session.id, f.workspace)).rejects.toThrow(
      "cannot switch execution runtime",
    );
    expect(sdk).not.toHaveBeenCalled();
  });

  it.each([false, true])(
    "real startup fences user-stopped background jobs and resumes idle live ones (stopped=%s)",
    async (stopped) => {
      const f = await fixture([
        fauxAssistantMessage(
          [fauxToolCall("background_job", { action: "start", command: "controlled startup job" })],
          { stopReason: "toolUse" },
        ),
        fauxAssistantMessage("STARTED"),
        fauxAssistantMessage("INTERRUPTED_RESULT_RECEIVED"),
      ]);
      let entered!: () => void;
      const started = new Promise<void>((resolve) => {
        entered = resolve;
      });
      let executions = 0;
      vi.spyOn(NodeExecutionEnv.prototype, "exec").mockImplementation(
        async (_command, _options, execContext) => {
          executions++;
          entered();
          // Harness detach models process loss, not a successful guest/host kill.
          return await new Promise((_resolve, reject) => {
            execContext.abortSignal!.addEventListener(
              "abort",
              () => reject(execContext.abortSignal!.reason),
              { once: true },
            );
          });
        },
      );
      let harness = await openHarness(f.dir, f.models);
      const first = await backend(harness, f.models, f.session, f.dir);
      const id = f.session.serverDurable!.conversationId! as ConversationId;
      let root = (await harness.conversation(id, context))!;
      await first.prompt("Start a conversation-owned job");
      await started;
      await root.waitForIdle(context);
      const job = (await harness.snapshot(DurableJobs, id, context))!.jobs[0]!;
      f.session.status = "ready";
      f.storage.saveSession(f.session);
      const opening = vi
        .spyOn(DurableHarness.prototype, "open")
        .mockResolvedValue({ harness, models: f.models });
      if (stopped) {
        await f.manager.startSession(f.session.id, f.workspace);
        await f.manager.stopSession(f.session.id);
        expect(f.storage.getSession(f.session.id)?.status).toBe("stopped");
        // Ordinary Stop preserves the running execution in this process.
        expect((await harness.getTask(job.taskId, context))?.abortRequested).toBe(false);
      }
      await first.detachForRestart();
      await f.manager.close();
      managers.splice(managers.indexOf(f.manager), 1);
      await harness.close(context);
      harnesses.splice(harnesses.indexOf(harness), 1);
      harness = await openHarness(f.dir, f.models);
      opening.mockResolvedValue({ harness, models: f.models });
      expect((await harness.inspect(context)).scheduling).toBe("paused");
      const storage = new Storage(f.dir);
      queueOrphanedSessionsForRestart(storage);
      expect(storage.listRestartResume().map((entry) => entry.sessionId)).toEqual(
        stopped ? [] : [f.session.id],
      );
      const restarted = new SessionManager(storage);
      managers.push(restarted);
      await restarted.resumeDurableSessions();
      root = (await harness.conversation(id, context))!;
      await harness.waitForTask(job.taskId, context);
      await root.waitForIdle(context);
      const reports = (await root.context(context)).messages.filter(
        (message) =>
          message.role === "user" &&
          JSON.stringify(message.content).includes("Background job bash-1 was interrupted"),
      );
      expect(executions).toBe(1);
      expect(restarted.isActive(f.session.id)).toBe(!stopped);
      expect(reports).toHaveLength(stopped ? 0 : 1);
      expect(f.faux.state.callCount).toBe(stopped ? 2 : 3);
      // Same JSON-decoding oracle as the live smoke, over real native SQLite.
      const db = new DatabaseSync(join(f.dir, "restart.sqlite"), { readOnly: true });
      try {
        const receipts = db
          .prepare(
            "SELECT json_extract(request_id, '$') AS request_id, status FROM submissions WHERE json_extract(request_id, '$') LIKE 'background-job:%'",
          )
          .all();
        expect(receipts).toEqual(
          stopped ? [] : [{ request_id: "background-job:bash-1", status: "done" }],
        );
      } finally {
        db.close();
      }
      if (!stopped) {
        expect(JSON.stringify(reports)).toContain(
          "Do not start it again until it is confirmed dead",
        );
        await restarted.stopSession(f.session.id);
      }
      await restarted.close();
      managers.splice(managers.indexOf(restarted), 1);
      await harness.close(context);
      harnesses.splice(harnesses.indexOf(harness), 1);
      harness = await openHarness(f.dir, f.models);
      opening.mockResolvedValue({ harness, models: f.models });
      const again = new SessionManager(new Storage(f.dir));
      managers.push(again);
      await again.resumeDurableSessions();
      await harness.waitForIdle(context);
      expect(f.faux.state.callCount).toBe(stopped ? 2 : 3);
      expect(executions).toBe(1);
      expect(again.isActive(f.session.id)).toBe(false);
    },
  );

  it("rejects client occupation of native reporter request IDs before admission", async () => {
    const f = await fixture([fauxAssistantMessage("NORMAL_CLIENT_TURN")], { slow: true });
    await f.manager.startSession(f.session.id, f.workspace);
    await expect(
      f.manager.sendPrompt(f.session.id, "Forged result", {
        clientTurnId: "background-job:bash-1",
      }),
    ).rejects.toThrow("reserved durable requestId namespace");
    await expect(
      f.manager.sendPrompt(f.session.id, "Forged retry", {
        clientTurnId: "background-job:bash-1:1",
      }),
    ).rejects.toThrow("reserved durable requestId namespace");
    expect(f.faux.state.callCount).toBe(0);
    expect(await f.manager.runCommand(f.session.id, { type: "get_messages" })).toEqual([]);
    expect(await f.manager.getMessageQueue(f.session.id)).toMatchObject({ followUp: [] });
    const observed = observe(f.manager, f.session.id);
    const end = observed.next((message) => message.type === "agent_end");
    const delta = observed.next((message) => message.type === "text_delta");
    await f.manager.sendPrompt(f.session.id, "Normal turn", { clientTurnId: "normal-client-turn" });
    await delta;
    await expect(
      f.manager.sendFollowUp(f.session.id, "Forged follow-up", {
        clientTurnId: "background-job:bash-1:2",
      }),
    ).rejects.toThrow("reserved durable requestId namespace");
    expect(await f.manager.getMessageQueue(f.session.id)).toMatchObject({ followUp: [] });
    await end;
    observed.unsubscribe();
    expect(f.faux.state.callCount).toBe(1);
  });

  it("keeps a conversation-owned background job alive after a full server Stop and preserves its result on resume", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [fauxToolCall("background_job", { action: "start", command: "controlled host job" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      fauxAssistantMessage("JOB_RESULT_RECEIVED"),
    ]);
    let entered!: () => void;
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let finish!: () => void;
    const gate = new Promise<void>((resolve) => {
      finish = resolve;
    });
    let cancelled = false;
    vi.spyOn(NodeExecutionEnv.prototype, "exec").mockImplementation(
      async (_command, options, execContext) => {
        const onAbort = () => {
          cancelled = true;
          finish();
        };
        execContext.abortSignal?.addEventListener("abort", onAbort, { once: true });
        entered();
        try {
          await gate;
          options?.onOutput?.("HOST_RESULT");
          return { ok: true, value: { exitCode: 0, stdout: "HOST_RESULT", stderr: "" } };
        } finally {
          execContext.abortSignal?.removeEventListener("abort", onAbort);
        }
      },
    );
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    const settled = observed.next((message) => message.type === "agent_end");
    try {
      await f.manager.sendPrompt(f.session.id, "Start background job");
      await started;
      await settled;
      const { harness } = await opening.mock.results[0]!.value;
      const id = f.storage.getSession(f.session.id)!.serverDurable!
        .conversationId as ConversationId;
      const job = (await harness.snapshot(DurableJobs, id, context))!.jobs[0]!;
      await f.manager.stopSession(f.session.id);
      expect(cancelled).toBe(false);
      expect(
        (await harness.inspect(context)).tasks.find(({ record }) => record.id === job.taskId)
          ?.record.state.status,
      ).toBe("running");
      finish();
      await harness.waitForTask(job.taskId, context);
      await (await harness.conversation(id, context))!.waitForIdle(context);
      await f.manager.startSession(f.session.id, f.workspace);
      const history = (await f.manager.runCommand(f.session.id, {
        type: "get_messages",
      })) as Array<{ role: string; content: unknown }>;
      expect(
        history.filter(
          (message) =>
            message.role === "user" &&
            JSON.stringify(message.content).includes("Background job bash-1"),
        ),
      ).toHaveLength(0);
      const conversation = (await harness.conversation(id, context))!;
      const modelHistory = (await conversation.context(context)).messages;
      expect(
        modelHistory.filter(
          (message) =>
            message.role === "user" && JSON.stringify(message.content).includes("HOST_RESULT"),
        ),
      ).toHaveLength(1);
      const trace = await readDurableTrace(harness, id, "full");
      expect(
        trace.filter((event) => event.presentation?.title === "Background job bash-1"),
      ).toEqual([
        expect.objectContaining({
          type: "system",
          presentation: expect.objectContaining({ status: "completed" }),
        }),
      ]);
      expect(JSON.stringify(trace)).not.toContain("HOST_RESULT");
      expect(
        history.filter(
          (message) =>
            message.role === "assistant" &&
            JSON.stringify(message.content).includes("JOB_RESULT_RECEIVED"),
        ),
      ).toHaveLength(1);
    } finally {
      finish();
      observed.unsubscribe();
    }
  });

  it("does not confirm cancellation when the sandbox environment cannot prove the guest stopped", async () => {
    const f = await fixture([]);
    const harness = await openHarness(f.dir, f.models);
    const owner = new DurableHarness(f.dir);
    vi.spyOn(owner, "open").mockResolvedValue({ harness, models: f.models });
    await owner.releaseResume();
    const conversation = await harness.createConversation(
      { ownership: { kind: "ownerless" } },
      context,
    );
    const env = new GondolinExecutionEnv({} as GondolinVm, "workspace", "/workspace/project");
    const confirmation = vi
      .spyOn(env, "confirmCancelledCalls")
      .mockRejectedValue(new Error("Guest cancellation was not confirmed"));
    owner.bindSandboxEnv(conversation.id, env);
    await expect(owner.abortConversation(conversation.id)).rejects.toThrow(
      "Guest cancellation was not confirmed",
    );
    expect(confirmation).toHaveBeenCalledOnce();
  });

  it("fails clearly for selected sandbox MCP instead of launching it on the host", async () => {
    const f = await fixture([]);
    f.workspace.runtime = "sandbox";
    f.workspace.sandboxConfig = { mcpServers: ["picked-server"] };
    const sdk = vi.spyOn(SdkBackend, "create");
    const ensure = vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm");
    await expect(f.manager.startSession(f.session.id, f.workspace)).rejects.toMatchObject({
      code: "server_durable_not_supported",
      operation: "Sandbox MCP servers",
    });
    expect(sdk).not.toHaveBeenCalled();
    expect(ensure).not.toHaveBeenCalled();
  });
  it("gates an early HTTP-equivalent open and prompt before bootstrap even begins", async () => {
    const f = await fixture([]);
    const crashed = await crashedQueuedTools(f);
    const early = new SessionManager(f.storage);
    managers.push(early);
    const a = crashed.sessions[0]!;
    await early.startSession(a.id, f.workspace);
    await expect(early.sendPrompt(a.id, "Early launch prompt")).rejects.toMatchObject({
      code: "server_durable_startup_pending",
      retryable: true,
    });
    expect(f.storage.listRestartResume().map((entry) => entry.sessionId)).toContain(a.id);
    await early.stopSession(a.id);
    expect(crashed.effects).toEqual([]);
    expect((await crashed.harness.inspect(context)).scheduling).toBe("paused");
    await early.resumeDurableSessions();
    await Promise.all(crashed.tasks.map((id) => crashed.harness.waitForTask(id, context)));
    expect(crashed.effects).toEqual([crashed.sessions[1]!.serverDurable!.conversationId]);
  });

  it("keeps admission gated until an in-flight paused cancellation mark commits", async () => {
    const f = await fixture([]);
    const crashed = await crashedQueuedTools(f);
    const owner = new DurableHarness(f.dir);
    vi.spyOn(owner, "open").mockResolvedValue({ harness: crashed.harness, models: f.models });
    let admit!: () => void;
    let marking!: () => void;
    const allowed = new Promise<void>((resolve) => {
      admit = resolve;
    });
    const started = new Promise<void>((resolve) => {
      marking = resolve;
    });
    const abortTask = crashed.harness.abortTask.bind(crashed.harness);
    vi.spyOn(crashed.harness, "abortTask").mockImplementation(async (...args) => {
      if (args[0] === crashed.tasks[1]) {
        marking();
        await allowed;
      }
      return abortTask(...args);
    });
    const a = crashed.sessions[0]!;
    const active = await DurableBackend.create({
      harness: crashed.harness,
      owner,
      models: f.models,
      session: a,
      dataDir: f.dir,
      persistBinding: () => {},
      onEvent: () => {},
    });
    const stopped = owner.abortConversations(
      new Set([crashed.sessions[1]!.serverDurable!.conversationId! as ConversationId]),
    );
    await started;
    const released = owner.releaseResume();
    try {
      await expect(active.prompt("Do not resume before the stop mark")).rejects.toMatchObject({
        code: "server_durable_startup_pending",
        retryable: true,
      });
      expect(crashed.effects).toEqual([]);
      expect((await crashed.harness.inspect(context)).scheduling).toBe("paused");
    } finally {
      admit();
      await stopped;
      await released;
      await active.detachForRestart();
    }
    await Promise.all(crashed.tasks.map((id) => crashed.harness.waitForTask(id, context)));
    expect(crashed.effects).toEqual([a.serverDurable!.conversationId]);
  });

  it.each(["stop", "agent-launch prompt"])(
    "keeps shared scheduling paused during an attached %s while the next workspace disappears",
    async (action) => {
      const f = await fixture([]);
      const crashed = await crashedQueuedTools(f);
      const [a, b] = crashed.sessions;
      const start = f.manager.startSession.bind(f.manager);
      vi.spyOn(f.manager, "startSession").mockImplementation(async (id, workspace) => {
        const result = await start(id, workspace);
        expect(id).toBe(a!.id);
        if (action === "stop") await f.manager.stopSession(a!.id);
        else {
          await expect(
            f.manager.sendPrompt(a!.id, "Launch input during startup", {
              clientTurnId: "startup-launch",
            }),
          ).rejects.toMatchObject({ code: "server_durable_startup_pending", retryable: true });
          expect(f.storage.listRestartResume().map((entry) => entry.sessionId)).toContain(a!.id);
        }
        // If a broken stop enabled scheduling, join B's already-enabled work
        // before resolving B's workspace. Never enable a paused scheduler here.
        if ((await crashed.harness.inspect(context)).scheduling === "running")
          await crashed.harness.waitForTask(crashed.tasks[1]!, context);
        expect(crashed.effects).toEqual([]);
        expect((await crashed.harness.inspect(context)).scheduling).toBe("paused");
        // It existed at the first fence and disappears after A has been exposed.
        f.storage.deleteWorkspace(crashed.secondWorkspace.id);
        expect(f.storage.listRestartResume().map((entry) => entry.sessionId)).toContain(b!.id);
        return result;
      });
      await f.manager.resumeDurableSessions();
      await Promise.all(crashed.tasks.map((id) => crashed.harness.waitForTask(id, context)));
      expect(crashed.effects).toEqual(action === "stop" ? [] : [a!.serverDurable!.conversationId]);
      expect(f.manager.isActive(b!.id)).toBe(false);
    },
  );

  it.each(["prompt", "steer", "follow-up"])(
    "preserves restart intent when an inactive startup %s fails admission",
    async (kind) => {
      const f = await fixture([]);
      const crashed = await crashedQueuedTools(f);
      const b = crashed.sessions[1]!;
      const send =
        kind === "prompt"
          ? f.manager.sendPrompt.bind(f.manager)
          : kind === "steer"
            ? f.manager.sendSteer.bind(f.manager)
            : f.manager.sendFollowUp.bind(f.manager);
      await expect(send(b.id, "Not admitted")).rejects.toThrow("Session not active");
      expect(f.storage.listRestartResume().map((entry) => entry.sessionId)).toContain(b.id);
      await f.manager.resumeDurableSessions();
      await Promise.all(crashed.tasks.map((id) => crashed.harness.waitForTask(id, context)));
      expect(new Set(crashed.effects)).toEqual(
        new Set(crashed.sessions.map((session) => session.serverDurable!.conversationId)),
      );
    },
  );

  it.each(["follow-up", "steer", "prompt-followUp", "prompt-steer"])(
    "publishes one rich image chip for native %s, including inbox refresh and failed-submit rollback",
    async (kind) => {
      const f = await fixture(
        [
          fauxAssistantMessage(
            "A long streaming answer leaves time for deterministic native queue admission.",
          ),
        ],
        { slow: true },
      );
      const harness = await openHarness(f.dir, f.models);
      vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
      const creating = vi.spyOn(harness, "createConversation");
      await f.manager.startSession(f.session.id, f.workspace);
      const conversation = await creating.mock.results[0]!.value;
      const submit = conversation.submit.bind(conversation);
      let rejectNext = false;
      vi.spyOn(conversation, "submit").mockImplementation(async (...args) => {
        if (rejectNext) {
          rejectNext = false;
          throw new Error("native admission rejected");
        }
        return submit(...args);
      });
      const png = Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jE0YAAAAASUVORK5CYII=",
        "base64",
      );
      writeFileSync(join(f.dir, "queue.png"), png);
      const attachment: ChatAttachmentRef = {
        type: "attachment",
        id: "image-proof",
        source: "workspace",
        name: "queue.png",
        mimeType: "image/png",
        kind: "image",
        sizeBytes: png.length,
        workspacePath: "queue.png",
      };
      const projection = observe(f.manager, f.session.id);
      const delta = projection.next((message) => message.type === "text_delta");
      await f.manager.sendPrompt(f.session.id, "Stream");
      await delta;
      const send = (text: string, id: string) => {
        const opts = { clientTurnId: id, attachments: [attachment] };
        if (kind === "follow-up") return f.manager.sendFollowUp(f.session.id, text, opts);
        if (kind === "steer") return f.manager.sendSteer(f.session.id, text, opts);
        return f.manager.sendPrompt(f.session.id, text, {
          ...opts,
          streamingBehavior: kind === "prompt-steer" ? "steer" : "followUp",
        });
      };
      const before = projection.messages.length;
      f.storage.queueRestartResume([{ sessionId: f.session.id, wasBusy: true }], Date.now());
      rejectNext = true;
      await expect(send("Failed rich input", "failed-image-turn")).rejects.toThrow(
        "native admission rejected",
      );
      expect(f.storage.listRestartResume().map((entry) => entry.sessionId)).toContain(f.session.id);
      const failedFrames = projection.messages
        .slice(before)
        .filter((message) => message.type === "queue_state");
      for (const frame of failedFrames)
        expect([...frame.queue.steering, ...frame.queue.followUp]).toEqual([]);
      const acceptedAt = projection.messages.length;
      const richFrame = projection.next(
        (message) =>
          message.type === "queue_state" &&
          [...message.queue.steering, ...message.queue.followUp].some(
            (item) => item.message === "Rich input",
          ),
      );
      await send("Rich input", "rich-image-turn");
      await richFrame;
      expect(f.storage.listRestartResume()).toEqual([]);
      const inbox = await harness.snapshot(InboxDoc, conversation.id, context);
      expect(inbox!.items).toHaveLength(1);
      expect(inbox!.items[0]).toMatchObject({
        content: expect.arrayContaining([
          { type: "image", data: png.toString("base64"), mimeType: "image/png" },
        ]),
      });
      // Force another native inbox update, with no Oppi enqueue involved.
      const transient = await conversation.submit(
        { type: "input", content: "Native refresh tick", whenBusy: "followUp" },
        context,
      );
      const refreshed = projection.next(
        (message) =>
          message.type === "queue_state" &&
          [...message.queue.steering, ...message.queue.followUp].length === 1,
      );
      await transient.abort(context);
      await refreshed;
      const receipt = (await harness.inspect(context)).submissions.find(
        (record) => record.requestId === "rich-image-turn",
      )!;
      const frames = projection.messages
        .slice(acceptedAt)
        .filter((message) => message.type === "queue_state");
      expect(frames.length).toBeGreaterThan(0);
      for (const frame of frames) {
        const rich = [...frame.queue.steering, ...frame.queue.followUp].filter(
          (item) => item.id === String(receipt.id),
        );
        expect(rich).toHaveLength(1);
        expect(rich[0]).toMatchObject({ message: "Rich input", attachments: [attachment] });
        expect(
          [...frame.queue.steering, ...frame.queue.followUp].filter((item) =>
            item.message.includes("queue.png"),
          ),
        ).toEqual([]);
      }
      await f.manager.sendAbort(f.session.id);
      projection.unsubscribe();
    },
  );

  it("projects a tool-using prompt through the existing pipeline and keeps the client turn id unique", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxThinking("Inspect with a tool"),
          fauxToolCall(
            "write",
            { path: "proof.txt", content: "DURABLE_TOOL_OK" },
            { id: "proof-write" },
          ),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("DURABLE_FINAL_OK"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    const end = projection.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(f.session.id, "Write proof.txt, then report success", {
      clientTurnId: "apple-turn-1",
    });
    await end;
    expect(readFileSync(join(f.dir, "proof.txt"), "utf8")).toBe("DURABLE_TOOL_OK");
    expect(projection.messages.map((message) => message.type)).toEqual(
      expect.arrayContaining([
        "agent_start",
        "thinking_delta",
        "tool_start",
        "tool_end",
        "text_delta",
        "message_end",
        "agent_end",
      ]),
    );
    expect(projection.messages).toContainEqual(
      expect.objectContaining({
        type: "message_end",
        role: "assistant",
        content: "DURABLE_FINAL_OK",
        entryId: expect.any(String),
      }),
    );
    const count = f.manager.getActiveSession(f.session.id)!.messageCount;
    await f.manager.sendPrompt(f.session.id, "Write proof.txt, then report success", {
      clientTurnId: "apple-turn-1",
    });
    expect(f.manager.getActiveSession(f.session.id)!.messageCount).toBe(count);
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as {
      role: string;
    }[];
    expect(history.filter((message) => message.role === "user")).toHaveLength(1);
    expect(f.faux.state.callCount).toBe(2);
    expect(f.storage.getSession(f.session.id)?.serverDurable?.conversationId).toBeGreaterThan(0);
    projection.unsubscribe();
  });

  it("persists model and thinking configuration on the conversation and reports usage", async () => {
    const f = await fixture([fauxAssistantMessage("CONFIG_OK")]);
    await f.manager.startSession(f.session.id, f.workspace);
    expect(
      await f.manager.runCommand(f.session.id, { type: "set_model", model: "faux/faux-1" }),
    ).toMatchObject({ success: true, provider: "faux", id: "faux-1" });
    expect(
      await f.manager.runCommand(f.session.id, { type: "set_thinking_level", level: "high" }),
    ).toEqual({ level: "high" });
    const snapshot = await f.manager.runCommand(f.session.id, { type: "get_state" });
    expect(snapshot).toMatchObject({
      model: { provider: "faux", id: "faux-1" },
      thinkingLevel: "high",
      isStreaming: false,
    });
    const projection = observe(f.manager, f.session.id);
    const end = projection.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(f.session.id, "Report configuration");
    await end;
    const stats = await f.manager.runCommand(f.session.id, { type: "get_session_stats" });
    expect(stats).toMatchObject({
      userMessages: 1,
      assistantMessages: 1,
      totalMessages: expect.any(Number),
      tokens: { total: expect.any(Number) },
    });
    projection.unsubscribe();
  });

  it("aborts a stream and queued follow-up using native inbox withdrawal, then remains stopped after reopening", async () => {
    const f = await fixture(
      [fauxAssistantMessage("A long answer that must be interrupted before it finishes.")],
      { slow: true },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    const delta = projection.next((message) => message.type === "text_delta");
    await f.manager.sendPrompt(f.session.id, "Stream slowly", { clientTurnId: "stop-turn" });
    await delta;
    await f.manager.sendFollowUp(f.session.id, "Do not run this", { clientTurnId: "queued-turn" });
    expect((await f.manager.getMessageQueue(f.session.id)).followUp).toHaveLength(1);
    const confirmed = projection.next((message) => message.type === "stop_confirmed");
    await f.manager.sendAbort(f.session.id);
    await confirmed;
    expect(await f.manager.getMessageQueue(f.session.id)).toMatchObject({
      steering: [],
      followUp: [],
    });
    expect(
      projection.messages.filter((message) => message.type === "queue_state").at(-1),
    ).toMatchObject({ queue: { steering: [], followUp: [] } });
    expect(projection.messages.filter((message) => message.type === "stop_failed")).toHaveLength(0);
    await f.manager.stopSession(f.session.id);
    projection.unsubscribe();
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    const storage = new Storage(f.dir);
    queueOrphanedSessionsForRestart(storage);
    const restarted = new SessionManager(storage);
    managers.push(restarted);
    await restarted.resumeDurableSessions();
    expect(restarted.isActive(f.session.id)).toBe(false);
    expect(storage.getSession(f.session.id)?.status).toBe("stopped");
    expect(f.faux.state.callCount).toBe(1);
    await restarted.startSession(f.session.id, f.workspace);
    await expect(
      restarted.sendPrompt(f.session.id, "Do not run this", { clientTurnId: "queued-turn" }),
    ).resolves.toBeUndefined();
    await expect(
      restarted.sendPrompt(f.session.id, "Changed withdrawn input", {
        clientTurnId: "queued-turn",
      }),
    ).rejects.toThrow("clientTurnId conflict");
    expect((await restarted.getMessageQueue(f.session.id)).followUp).toEqual([]);
    expect(f.faux.state.callCount).toBe(1);
  });

  it("reserves internal goal request IDs before client prompt admission", async () => {
    const f = await fixture([fauxAssistantMessage("Normal client prompt accepted")]);
    const harness = await openHarness(f.dir, f.models);
    const runtime = await backend(harness, f.models, f.session, f.dir);
    const accepted = vi.fn();
    await expect(
      runtime.prompt("Preempt a continuation", {
        clientTurnId: "oppi-goal:known-goal:1",
        onPreflightAccepted: accepted,
      }),
    ).rejects.toThrow("reserved durable requestId namespace");
    expect(accepted).not.toHaveBeenCalled();
    expect(runtime.messages()).toHaveLength(0);
    expect(f.faux.state.callCount).toBe(0);
    await runtime.prompt("Normal prompt", { clientTurnId: "ordinary-client-id" });
    await harness.waitForIdle(context);
    expect(runtime.messages().filter((m) => m.role === "user")).toHaveLength(1);
    await runtime.dispose();
  });

  it("fails unsupported commands with a typed error instead of pretending success", async () => {
    const f = await fixture([]);
    await f.manager.startSession(f.session.id, f.workspace);
    await expect(f.manager.runCommand(f.session.id, { type: "reload" })).rejects.toMatchObject({
      code: "server_durable_not_supported",
      message: "reloadResources is not supported for server durable sessions",
    });
    await expect(
      f.manager.runCommand(f.session.id, { type: "get_session_tree" }),
    ).rejects.toBeInstanceOf(DurableNotSupportedError);
    expect(await f.manager.takeMessageQueue(f.session.id)).toMatchObject({
      steering: [],
      followUp: [],
    });
  });

  it("publishes durable queue_item_started by submission identity without text reconciliation", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage(
          "A long streaming answer leaves time for deterministic native queue admission.",
        ),
        fauxAssistantMessage("Answered the queued input."),
      ],
      { slow: true },
    );
    const harness = await openHarness(f.dir, f.models);
    vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    await f.manager.sendPrompt(f.session.id, "start");
    const started = projection.next((message) => message.type === "queue_item_started");
    await f.manager.sendFollowUp(f.session.id, "same", { clientTurnId: "queued-delivery" });
    const queue = await f.manager.getMessageQueue(f.session.id);
    expect(queue.followUp).toHaveLength(1);
    const event = await started;
    expect(event).toMatchObject({
      type: "queue_item_started",
      kind: "follow_up",
      item: queue.followUp[0],
    });
    expect(event.type === "queue_item_started" && event.queueVersion).toBeGreaterThan(
      queue.version,
    );
    projection.unsubscribe();
  });

  it("removes identical-text durable submissions independently and restores raw attachment metadata", async () => {
    const f = await fixture(
      [fauxAssistantMessage("A long streaming answer leaves the queue pending.")],
      { slow: true },
    );
    const harness = await openHarness(f.dir, f.models);
    vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
    const creating = vi.spyOn(harness, "createConversation");
    await f.manager.startSession(f.session.id, f.workspace);
    const conversation = await creating.mock.results[0]!.value;
    writeFileSync(join(f.dir, "notes.txt"), "note");
    const attachment: ChatAttachmentRef = {
      type: "attachment",
      id: "notes",
      source: "workspace",
      name: "notes.txt",
      mimeType: "text/plain",
      sizeBytes: 4,
      workspacePath: "notes.txt",
    };
    const projection = observe(f.manager, f.session.id);
    const started = projection.next((message) => message.type === "text_delta");
    await f.manager.sendPrompt(f.session.id, "Stream");
    await started;
    await f.manager.sendFollowUp(f.session.id, "same", { clientTurnId: "one" });
    await f.manager.sendFollowUp(f.session.id, "same", {
      clientTurnId: "two",
      attachments: [attachment],
    });
    const before = await f.manager.getMessageQueue(f.session.id);
    const inbox = await harness.snapshot(InboxDoc, conversation.id, context);
    expect(before.followUp.map((item) => item.id)).toEqual(
      inbox!.items.filter((item) => item.mode === "followUp").map((item) => String(item.id)),
    );
    expect(before.followUp.map((item) => item.message)).toEqual(["same", "same"]);
    expect(before.followUp[1]!.attachments).toEqual([attachment]);
    const receipt = await harness.submission(Number(before.followUp[0]!.id) as never, context);
    const waiting = receipt!.wait(context);
    const removed = await f.manager.removeQueuedMessage(f.session.id, before.followUp[0]!.id);
    expect(removed.followUp.map((item) => item.id)).toEqual([before.followUp[1]!.id]);
    expect(await waiting).toMatchObject({ status: "unanswered", reason: "aborted" });
    const taken = await f.manager.takeMessageQueue(f.session.id);
    expect(taken.followUp).toEqual([before.followUp[1]]);
    expect(await f.manager.getMessageQueue(f.session.id)).toMatchObject({
      steering: [],
      followUp: [],
    });
    await f.manager.sendAbort(f.session.id);
    projection.unsubscribe();
  });

  it("never lists a report admitted after a queue read's card transaction", async () => {
    const f = await fixture([]);
    const harness = await openHarness(f.dir, f.models);
    const b = await backend(harness, f.models, f.session, f.dir);
    const native = (
      b as unknown as { conversation: Awaited<ReturnType<typeof harness.conversation>> }
    ).conversation!;
    const commit = native.commit.bind(native);
    const one = await commit(async (tx) => {
      await tx.doc(DurableInputCards, native.id);
      const submission = await tx.createSubmission({
        conversationId: native.id,
        type: "input",
        status: "queued",
      });
      (await tx.doc(InboxDoc, native.id)).items.push({
        id: submission.id,
        mode: "followUp",
        content: "user input",
      });
      return submission.id;
    }, context);
    let admitReport = true;
    const afterRead = async () => {
      if (!admitReport) return;
      admitReport = false;
      // Deterministic barrier: publication is between the committed card read
      // and its caller continuing. No sleeps or scheduler timing assumptions.
      await commit(async (tx) => {
        const report = await tx.createSubmission({
          conversationId: native.id,
          type: "input",
          status: "queued",
          requestId: "background-job:race",
        });
        (await tx.doc(DurableInputCards, native.id)).requests["background-job:race"] = {
          title: "Background result",
          body: "done",
          at: 1,
        };
        (await tx.doc(InboxDoc, native.id)).items.push({
          id: report.id,
          mode: "followUp",
          content: "internal report",
        });
      }, context);
    };
    // Cover both the former harness-only card read and the atomic conversation
    // read: the new code must return its detached inbox, not a later view.
    const harnessCommit = harness.commit.bind(harness);
    vi.spyOn(harness, "commit").mockImplementation(async (change, ctx) => {
      const result = await harnessCommit(change, ctx);
      await afterRead();
      return result;
    });
    vi.spyOn(native, "commit").mockImplementation(async (change, ctx) => {
      const result = await commit(change, ctx);
      await afterRead();
      return result;
    });
    const queue = await b.nativeMessageQueue();
    expect(admitReport).toBe(false);
    expect((await harness.snapshot(InboxDoc, native.id, context))!.items).toHaveLength(2);
    expect(queue.followUp.map((item) => item.id)).toEqual([String(one)]);
    expect((await b.nativeMessageQueue()).followUp).toEqual(queue.followUp);
    await b.dispose();
  });

  it("preserves generated input cards during Remove and take, and omits placement that wins the withdrawal race", async () => {
    const f = await fixture([]);
    const harness = await openHarness(f.dir, f.models);
    const b = await backend(harness, f.models, f.session, f.dir);
    const conversation = (await harness.conversation(
      f.session.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    const ids = await conversation.commit(async (tx) => {
      const one = await tx.createSubmission({
        conversationId: conversation.id,
        type: "input",
        status: "queued",
      });
      const two = await tx.createSubmission({
        conversationId: conversation.id,
        type: "input",
        status: "queued",
      });
      const report = await tx.createSubmission({
        conversationId: conversation.id,
        type: "input",
        status: "queued",
        requestId: "background-job:test",
      });
      const cards = await tx.doc(DurableInputCards, conversation.id);
      cards.requests["background-job:test"] = { title: "Background result", body: "done", at: 1 };
      const inbox = await tx.doc(InboxDoc, conversation.id);
      inbox.items.push(
        { id: one.id, mode: "steer", content: "one" },
        { id: two.id, mode: "followUp", content: "two" },
        { id: report.id, mode: "followUp", content: "generated report" },
      );
      return { one: one.id, two: two.id, report: report.id };
    }, context);
    await b.withRuntimeLifecycleTransaction("remove", (permit) =>
      b.withdrawNativeQueue(String(ids.one), permit),
    );
    expect(
      (await harness.submission(ids.report, context)) &&
        (await (await harness.submission(ids.report, context))!.status(context)),
    ).toMatchObject({ status: "queued" });
    const native = (b as unknown as { conversation: typeof conversation }).conversation;
    const commit = native.commit.bind(native);
    let intercept = true;
    vi.spyOn(native, "commit").mockImplementation(async (change, ctx) => {
      if (intercept) {
        intercept = false;
        await commit(async (tx) => {
          const entry = await tx.appendEntry(conversation.id, {
            kind: "pi.user",
            model: [{ role: "user", content: "two", timestamp: 1 }],
          });
          tx.placeSubmission(ids.two, entry.id);
          const inbox = await tx.doc(InboxDoc, conversation.id);
          inbox.items.splice(
            inbox.items.findIndex((item) => item.id === ids.two),
            1,
          );
        }, ctx);
      }
      return commit(change, ctx);
    });
    const taken = await b.withRuntimeLifecycleTransaction("take", (permit) =>
      b.withdrawNativeQueue(undefined, permit),
    );
    expect(taken).toMatchObject({ steering: [], followUp: [] });
    expect(
      (await harness.snapshot(InboxDoc, conversation.id, context))!.items.map((item) => item.id),
    ).toEqual([ids.report]);
    expect(await (await harness.submission(ids.two, context))!.status(context)).toMatchObject({
      status: "placed",
    });
    await b.detachForRestart();
  });

  it("reopens durable queue attachment metadata from SQLite without an Oppi queue copy", async () => {
    const f = await fixture([]);
    let harness = await openHarness(f.dir, f.models);
    let b = await backend(harness, f.models, f.session, f.dir);
    const conversation = (await harness.conversation(
      f.session.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    // A parked run keeps admission queued without starting a provider request.
    await conversation.commit(async (tx) => {
      (await tx.doc(LiveDoc, conversation.id)).run = {
        taskId: 999 as never,
        inputs: [998 as never],
      };
    }, context);
    const attachment: ChatAttachmentRef = {
      type: "attachment",
      id: "a",
      source: "workspace",
      name: "notes.txt",
      mimeType: "text/plain",
      sizeBytes: 4,
      workspacePath: "notes.txt",
    };
    await b.prompt("materialized bytes", {
      streamingBehavior: "followUp",
      clientTurnId: "reload-metadata",
      queueDisplay: { message: "raw composer", attachments: [attachment] },
    });
    const before = await b.nativeMessageQueue();
    expect(before.followUp[0]).toMatchObject({
      message: "raw composer",
      attachments: [attachment],
    });
    await b.detachForRestart();
    await harness.close(context);
    harness = await openHarness(f.dir, f.models);
    b = await backend(harness, f.models, f.session, f.dir);
    expect((await b.nativeMessageQueue()).followUp).toEqual(before.followUp);
    const taken = await b.withRuntimeLifecycleTransaction("take", (permit) =>
      b.withdrawNativeQueue(undefined, permit),
    );
    expect(taken.followUp).toEqual(before.followUp);
    await b.detachForRestart();
  });

  it("rebinds SQLite state and resumes the same unfinished submission without a continuation user message", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage(
          "An interrupted streaming response that remains pending across a close.",
        ),
      ],
      { slow: true },
    );
    // Real Harness close models process loss without a recorded Oppi shutdown.
    let harness = await openHarness(f.dir, f.models);
    const first = await backend(harness, f.models, f.session, f.dir);
    const conversation = (await harness.conversation(
      f.session.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    const events = await import("@earendil-works/pi-durable").then(({ watchEvents }) =>
      watchEvents(harness, conversation.id, context),
    );
    let partial!: () => void;
    const started = new Promise<void>((resolve) => {
      partial = resolve;
    });
    events.start(async (batch) => {
      if (batch.some((event) => event.type === "message_update")) partial();
    });
    await first.prompt("Continue exactly this original turn", { clientTurnId: "restart-turn" });
    await expect(
      first.prompt("Conflicting live text", { clientTurnId: "restart-turn" }),
    ).rejects.toThrow("clientTurnId conflict");
    await started;
    const persisted = JSON.parse(JSON.stringify(f.session)) as Session;
    await events.stop();
    await harness.close(context);
    harnesses.splice(harnesses.indexOf(harness), 1);
    f.faux.setResponses([fauxAssistantMessage("RESUMED_EXACTLY_ONCE")]);
    // Fast provider for the resumed answer; the faux response may still stream.
    harness = await openHarness(f.dir, f.models);
    const resumed = await backend(harness, f.models, persisted, f.dir);
    expect(persisted.serverDurable).toEqual(f.session.serverDurable);
    harness.resume();
    const rebound = (await harness.conversation(
      persisted.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    await rebound.waitForIdle(context);
    expect(resumed.messages().filter((message) => message.role === "user")).toHaveLength(1);
    expect(
      resumed
        .messages()
        .filter(
          (message) =>
            message.role === "assistant" &&
            Array.isArray(message.content) &&
            message.content.some(
              (block: { text?: string }) => block.text === "RESUMED_EXACTLY_ONCE",
            ),
        ),
    ).toHaveLength(1);
    const accepted = vi.fn();
    await resumed.prompt("Continue exactly this original turn", {
      clientTurnId: "restart-turn",
      onPreflightAccepted: accepted,
    });
    expect(accepted).not.toHaveBeenCalled();
    await expect(
      resumed.prompt("Different text", {
        clientTurnId: "restart-turn",
        onPreflightAccepted: accepted,
      }),
    ).rejects.toThrow("clientTurnId conflict");
    expect(accepted).not.toHaveBeenCalled();
    expect(f.faux.state.callCount).toBe(2);
    await resumed.dispose();
  }, 15_000);

  it("marks two crashed stopped conversations while paused before the third runs its tool", async () => {
    const f = await fixture([]);
    const sessions = [
      f.session,
      f.storage.createSession("stopped-2", "faux/faux-1"),
      f.storage.createSession("continue-3", "faux/faux-1"),
    ];
    const effects: number[] = [];
    let recoveredAll!: () => void;
    const allRecovered = new Promise<void>((resolve) => {
      recoveredAll = resolve;
    });
    let recovering = false;
    let entered = 0;
    let allEntered!: () => void;
    const started = new Promise<void>((resolve) => {
      allEntered = resolve;
    });
    const tool: ToolRegistration = {
      name: "side_effect_counter",
      description: "Deterministic restart probe",
      parameters: Type.Object({}),
      replay: "safe",
      async execute(_args, api, callContext) {
        if (!recovering) {
          if (++entered === 3) allEntered();
          await new Promise<void>((_resolve, reject) => {
            callContext.abortSignal!.addEventListener(
              "abort",
              () => reject(callContext.abortSignal!.reason),
              { once: true },
            );
          });
        }
        effects.push(api.conversationId);
        if (effects.length === 3) recoveredAll();
        return { content: [{ type: "text", text: "counted" }] };
      },
    };
    let harness = await openHarness(f.dir, f.models, tool);
    const taskIds = [];
    for (const [index, session] of sessions.entries()) {
      const conversation = await harness.createConversation(
        {
          ownership: { kind: "ownerless" },
          agent: { model: { provider: "faux", modelId: "faux-1" }, tools: [tool], cwd: f.dir },
        },
        context,
      );
      session.workspaceId = f.workspace.id;
      session.serverDurable = { conversationId: conversation.id };
      session.status = index === 2 ? "busy" : "stopping";
      f.storage.saveSession(session);
      if (index < 2)
        await conversation.commit(async (tx) => {
          const inbox = await tx.doc(InboxDoc, conversation.id);
          const input = await tx.createSubmission({
            conversationId: conversation.id,
            type: "input",
            status: "queued",
            requestId: `stopped-input-${index}`,
          });
          inbox.items.push({ id: input.id, mode: "followUp", content: "Never deliver" });
        }, context);
      taskIds.push(
        await conversation.commit(async (tx) => {
          const assistant = await tx.appendEntry(AssistantEntry, conversation.id, {
            model: [
              {
                role: "assistant",
                content: [fauxToolCall(tool.name, {}, { id: "counter" })],
                api: "faux",
                provider: "faux",
                model: "faux-1",
                usage: {
                  input: 0,
                  output: 0,
                  cacheRead: 0,
                  cacheWrite: 0,
                  totalTokens: 0,
                  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
                },
                stopReason: "toolUse",
                timestamp: 1,
              },
            ],
          });
          return tx.createTask(
            ToolTask,
            { assistant: assistant.id, callId: "counter" },
            { ownership: { kind: "conversation" } },
          );
        }, context),
      );
    }
    harness.resume();
    await started;
    await harness.close(context);
    harnesses.splice(harnesses.indexOf(harness), 1);
    recovering = true;
    harness = await openHarness(f.dir, f.models, tool);
    expect((await harness.inspect(context)).scheduling).toBe("paused");
    const idle = f.storage.createSession("Already idle stopped conversation", "faux/faux-1");
    idle.status = "stopped";
    idle.serverDurable = {
      conversationId: (
        await harness.createConversation({ ownership: { kind: "ownerless" } }, context)
      ).id,
    };
    f.storage.saveSession(idle);
    // The idle cleanup is first. A delayed next handle read is a plausible
    // startup interleaving: if cleanup enabled scheduling, tools can run before
    // the remaining stopped conversations have been marked.
    vi.spyOn(f.storage, "listSessions").mockImplementation(() =>
      [idle, ...sessions].map((session) => structuredClone(session)),
    );
    const conversation = harness.conversation.bind(harness);
    vi.spyOn(harness, "conversation").mockImplementation(async (id, callContext) => {
      if (
        id === sessions[0]!.serverDurable!.conversationId &&
        (await harness.inspect(context)).scheduling === "running"
      )
        await allRecovered;
      return conversation(id, callContext);
    });
    vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
    queueOrphanedSessionsForRestart(f.storage);
    await f.manager.resumeDurableSessions();
    await Promise.all(taskIds.map((id) => harness.waitForTask(id, context)));
    expect(effects).toEqual([sessions[2]!.serverDurable!.conversationId]);
    expect((await harness.inspect(context)).submissions).toEqual([]);
    expect(f.manager.isActive(sessions[0]!.id)).toBe(false);
    expect(f.manager.isActive(sessions[1]!.id)).toBe(false);
    expect(f.manager.isActive(sessions[2]!.id)).toBe(true);
  });

  it("rechecks the restart queue after an earlier attach so a startup stop wins", async () => {
    const f = await fixture([]);
    const harness = await openHarness(f.dir, f.models);
    const second = f.storage.createSession("Stop during startup", "faux/faux-1");
    for (const session of [f.session, second]) {
      await backend(harness, f.models, session, f.dir);
      session.workspaceId = f.workspace.id;
      session.status = "busy";
      f.storage.saveSession(session);
    }
    vi.spyOn(DurableHarness.prototype, "open").mockResolvedValue({ harness, models: f.models });
    queueOrphanedSessionsForRestart(f.storage);
    const ordered = f.storage
      .listSessions()
      .filter((session) => session.serverDurable?.conversationId !== undefined);
    const stopped = ordered[1]!;
    const start = f.manager.startSession.bind(f.manager);
    const starts = vi.spyOn(f.manager, "startSession").mockImplementation(async (id, workspace) => {
      await f.manager.stopSession(stopped.id);
      return start(id, workspace);
    });
    await f.manager.resumeDurableSessions();
    expect(starts.mock.calls.map(([id]) => id)).toEqual([ordered[0]!.id]);
    expect(f.manager.isActive(stopped.id)).toBe(false);
  });

  it("persists a busy sandbox restart attachment until its original submission settles once", async () => {
    let finishReply!: () => void;
    const replyGate = new Promise<void>((resolve) => {
      finishReply = resolve;
    });
    let generating!: () => void;
    const generationStarted = new Promise<void>((resolve) => {
      generating = resolve;
    });
    const f = await fixture([
      fauxAssistantMessage(
        [fauxToolCall("bash", { command: "controlled guest tool" }, { id: "sandbox-restart" })],
        { stopReason: "toolUse" },
      ),
      async () => {
        generating();
        await replyGate;
        return fauxAssistantMessage("SANDBOX_RECOVERED");
      },
    ]);
    f.workspace.runtime = "sandbox";
    f.storage.updateWorkspace(f.workspace.id, { runtime: "sandbox" });
    const result = { ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) };
    let stopGuest!: () => void;
    const guestStopped = new Promise<void>((resolve) => {
      stopGuest = resolve;
    });
    let guestCalls = 0;
    let markGuestStarted!: () => void;
    const guestStarted = new Promise<void>((resolve) => {
      markGuestStarted = resolve;
    });
    const vm: GondolinVm = {
      fs: {
        mkdir: async () => {},
        access: async () => {},
        readFile: async () => Buffer.alloc(0),
        writeFile: async () => {},
      },
      exec: (argv) => {
        const tool = argv.includes("oppi-exec");
        if (tool) guestCalls++;
        if (argv.includes("oppi-kill")) stopGuest();
        return Object.assign(tool ? guestStopped.then(() => result) : Promise.resolve(result), {
          async *output() {
            if (tool) {
              yield { stream: "stdout" as const, data: Buffer.from("42 12345\n") };
              yield { stream: "stdout" as const, data: Buffer.from("MID_TOOL\n") };
              markGuestStarted();
              await guestStopped;
            }
          },
          write() {},
          end() {},
        });
      },
    };
    vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue(vm);
    const sdk = vi.spyOn(SdkBackend, "create");
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    // Native background jobs retain final output only. Synchronize on guest
    // execution, not CodingTools' former streaming-output projection.
    await f.manager.sendPrompt(f.session.id, "Keep this original turn", {
      clientTurnId: "sandbox-restart-turn",
    });
    await guestStarted;
    const { harness } = await opening.mock.results[0]!.value;
    const id = f.storage.getSession(f.session.id)!.serverDurable!.conversationId! as ConversationId;
    const placed = (await harness.inspect(context)).submissions.find(
      (item) => item.conversationId === id,
    )!;
    recordLiveSessionsForRestart(f.storage, [f.manager.getActiveSession(f.session.id)!]);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    projection.unsubscribe();
    const storage = new Storage(f.dir);
    const restarted = new SessionManager(storage);
    managers.push(restarted);
    let observed!: ReturnType<typeof observe>;
    let end!: Promise<ServerMessage>;
    const start = restarted.startSession.bind(restarted);
    vi.spyOn(restarted, "startSession").mockImplementation(async (sessionId, workspace) => {
      const session = await start(sessionId, workspace);
      observed = observe(restarted, sessionId);
      end = observed.next((message) => message.type === "agent_end");
      return session;
    });
    try {
      await restarted.resumeDurableSessions();
      await generationStarted;
      // GET /sessions reads persisted state, not the in-memory event projection.
      // No save-debounce delay or extra continuation input may be required.
      expect(restarted.isActive(f.session.id)).toBe(true);
      expect(restarted.getActiveSession(f.session.id)?.status).toBe("busy");
      expect(storage.getSession(f.session.id)?.status).toBe("busy");
      await restarted.refreshSessionState(f.session.id);
      expect(storage.getSession(f.session.id)?.status).toBe("busy");
      finishReply();
      await end;
      const resumed = (await opening.mock.results.at(-1)!.value).harness;
      expect(await (await resumed.submission(placed.id, context))!.status(context)).toMatchObject({
        status: "done",
      });
      const conversation = (await resumed.conversation(id, context))!;
      const entries = (await conversation.entries({}, 100, undefined, context)).items;
      expect(entries.filter((entry) => entry.kind === "pi.user")).toHaveLength(1);
      expect(
        entries
          .flatMap((entry) => entry.model ?? [])
          .filter((message) => message.role === "assistant" && message.stopReason === "stop"),
      ).toHaveLength(1);
      expect(
        entries.filter(
          (entry) =>
            entry.kind === "pi.tool-result" &&
            entry.data?.diagnostics?.some(
              (diagnostic: { code: string }) => diagnostic.code === "interrupted",
            ),
        ),
      ).toHaveLength(1);
      expect(guestCalls).toBe(1);
      expect(sdk).not.toHaveBeenCalled();
      expect(restarted.getActiveSession(f.session.id)?.status).toBe("ready");
    } finally {
      finishReply();
      observed?.unsubscribe();
    }
  });

  it("continues the same submission once after graceful shutdown mid-tool", async () => {
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxToolCall(
            "bash",
            { command: "printf 'once\\n' >> graceful-effects.log; printf 'MID_TOOL\\n'; sleep 60" },
            { id: "graceful-bash" },
          ),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("GRACEFUL_RESUMED"),
    ]);
    let markStarted!: () => void;
    const marker = new Promise<void>((resolve) => {
      markStarted = resolve;
    });
    const exec = NodeExecutionEnv.prototype.exec;
    vi.spyOn(NodeExecutionEnv.prototype, "exec").mockImplementation(
      function (command, options, execContext) {
        return exec.call(
          this,
          command,
          {
            ...options,
            onOutput: (text, stream) => {
              options?.onOutput?.(text, stream);
              if (text.includes("MID_TOOL")) markStarted();
            },
          },
          execContext,
        );
      },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    await f.manager.sendPrompt(f.session.id, "Continue the original submission", {
      clientTurnId: "graceful-turn",
    });
    await marker;
    recordLiveSessionsForRestart(f.storage, [f.manager.getActiveSession(f.session.id)!]);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    projection.unsubscribe();
    const restarted = new SessionManager(new Storage(f.dir));
    managers.push(restarted);
    let observed!: ReturnType<typeof observe>;
    let end!: Promise<ServerMessage>;
    const start = restarted.startSession.bind(restarted);
    vi.spyOn(restarted, "startSession").mockImplementation(async (id, workspace) => {
      const result = await start(id, workspace);
      observed = observe(restarted, id);
      end = observed.next((message) => message.type === "agent_end");
      return result;
    });
    await restarted.resumeDurableSessions();
    await end;
    const history = (await restarted.runCommand(f.session.id, { type: "get_messages" })) as {
      role: string;
      content: unknown;
    }[];
    expect(history.filter((message) => message.role === "user")).toHaveLength(1);
    expect(
      history.filter(
        (message) =>
          message.role === "assistant" &&
          JSON.stringify(message.content).includes("GRACEFUL_RESUMED"),
      ),
    ).toHaveLength(1);
    expect(readFileSync(join(f.dir, "graceful-effects.log"), "utf8")).toBe("once\n");
    const count = restarted.getActiveSession(f.session.id)!.messageCount;
    await restarted.sendPrompt(f.session.id, "Continue the original submission", {
      clientTurnId: "graceful-turn",
    });
    expect(restarted.getActiveSession(f.session.id)!.messageCount).toBe(count);
    await expect(
      restarted.sendPrompt(f.session.id, "Conflicting retry", { clientTurnId: "graceful-turn" }),
    ).rejects.toThrow("clientTurnId conflict");
    observed.unsubscribe();
  });

  it("pages and outlines live and stopped durable history across compaction without scheduling reads", async () => {
    const f = await fixture([
      fauxAssistantMessage("answer one"),
      fauxAssistantMessage("answer two"),
      fauxAssistantMessage("answer three"),
    ]);
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    for (const prompt of ["turn one", "turn two", "turn three"]) {
      const ended = observed.next((message) => message.type === "agent_end");
      await f.manager.sendPrompt(f.session.id, prompt);
      await ended;
    }
    const { harness } = await opening.mock.results[0]!.value;
    const conversation = (await harness.conversation(
      f.storage.getSession(f.session.id)!.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    const history = await conversation.entries({}, 100, undefined, context);
    await conversation.commit(async (tx) => {
      await tx.appendEntry(conversation.id, {
        kind: "pi.compaction",
        head: history.items[0]!.id,
        model: [{ role: "user", content: "<summary>earlier turns</summary>", timestamp: 7 }],
      });
    }, context);
    const service = new SessionTraceService({
      storage: f.storage,
      sessionRuntimes: f.manager,
      ensureSessionContextWindow: (session) => session,
      mobileRenderers: f.manager.mobileRenderer,
    });
    const resume = vi.spyOn(harness, "resume");
    for (const stopped of [false, true]) {
      if (stopped) await f.manager.stopSession(f.session.id);
      resume.mockClear();
      const full = await service.getSessionWithTrace({ session: f.session, traceView: "full" });
      expect(
        full.trace.filter((event) => event.type === "user").map((event) => event.text),
      ).toEqual(["turn one", "turn two", "turn three"]);
      expect(full.trace.at(-1)?.type).toBe("compaction");
      const pages = [];
      let cursor: string | undefined;
      do {
        const result = (await service.getSessionTracePage({
          session: f.session,
          targetEvents: 2,
          cursor,
        }))!;
        expect(result.page.staleCursor).toBe(false);
        expect(result.trace.length).toBeGreaterThan(0);
        pages.unshift(...result.trace);
        cursor = result.page.olderCursor ?? undefined;
      } while (cursor);
      expect(pages).toEqual(full.trace);
      const outline = await service.getSessionTraceOutline({ session: f.session });
      expect(outline.outline.entries.map((entry) => entry.kind)).toEqual([
        "user",
        "assistant",
        "user",
        "assistant",
        "user",
        "assistant",
        "compaction",
      ]);
      for (const entry of outline.outline.entries) {
        const around = (await service.getSessionTracePage({
          session: f.session,
          targetEvents: 2,
          aroundEntryId: entry.id,
        }))!;
        expect(around.trace.map((event) => event.id)).toContain(entry.id);
      }
      const stale = (await service.getSessionTracePage({ session: f.session, cursor: "invalid" }))!;
      expect(stale.page.staleCursor).toBe(true);
      expect(resume).not.toHaveBeenCalled();
    }
    observed.unsubscribe();
  });

  it("bounds durable page reads for 2,000 entries and keeps cursors valid after append", async () => {
    const f = await fixture([]);
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const { harness } = await opening.mock.results[0]!.value;
    const conversation = (await harness.conversation(
      f.storage.getSession(f.session.id)!.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    await conversation.commit(async (tx) => {
      for (let index = 0; index < 2_000; index++)
        await tx.appendEntry(conversation.id, {
          kind: "pi.user",
          model: [{ role: "user", content: `entry ${index}`, timestamp: index }],
        });
    }, context);
    vi.spyOn(harness, "conversation").mockResolvedValue(conversation);
    const reads = vi.spyOn(conversation, "entries");
    const resume = vi.spyOn(harness, "resume");
    const service = new SessionTraceService({
      storage: f.storage,
      sessionRuntimes: f.manager,
      ensureSessionContextWindow: (session) => session,
      mobileRenderers: f.manager.mobileRenderer,
    });
    const timings: number[] = [];
    let cursor: string | undefined;
    const events = [];
    let version: string | undefined;
    do {
      const start = performance.now();
      const page = (await service.getSessionTracePage({
        session: f.session,
        targetEvents: 100,
        cursor,
      }))!;
      timings.push(performance.now() - start);
      expect(page.trace).toHaveLength(100);
      expect(page.page.staleCursor).toBe(false);
      version ??= page.page.traceVersion;
      expect(page.page.traceVersion).toBe(version);
      events.unshift(...page.trace);
      cursor = page.page.olderCursor ?? undefined;
    } while (cursor);
    expect(events.map((event) => event.text)).toEqual(
      Array.from({ length: 2_000 }, (_, index) => `entry ${index}`),
    );
    // One bounded window + one latest-entry read per page, not twenty full rescans.
    expect(reads).toHaveBeenCalledTimes(40);
    expect(reads.mock.calls.every(([, limit]) => limit <= 101)).toBe(true);
    const latest = (await service.getSessionTracePage({ session: f.session, targetEvents: 2 }))!;
    await conversation.commit(async (tx) => {
      await tx.appendEntry(conversation.id, {
        kind: "pi.user",
        model: [{ role: "user", content: "appended", timestamp: 2000 }],
      });
    }, context);
    const older = (await service.getSessionTracePage({
      session: f.session,
      targetEvents: 2,
      cursor: latest.page.olderCursor!,
    }))!;
    expect(older.trace.map((event) => event.text)).toEqual(["entry 1996", "entry 1997"]);
    expect(older.page.staleCursor).toBe(false);
    expect(older.page.traceVersion).not.toBe(latest.page.traceVersion);
    const outlineStart = performance.now();
    const outline = await service.getSessionTraceOutline({ session: f.session });
    const outlineMs = performance.now() - outlineStart;
    expect(outline.outline.itemCount).toBe(2001);
    expect(resume).not.toHaveBeenCalled();
    const perf = { pages: timings.length, timingsMs: timings, outlineMs };
    writeFileSync(join(f.dir, "trace-perf.json"), JSON.stringify(perf, null, 2));
    process.stdout.write(
      `Durable 2000-entry perf: pages=${timings.length} min=${Math.min(...timings).toFixed(2)} max=${Math.max(...timings).toFixed(2)} avg=${(timings.reduce((a, b) => a + b, 0) / timings.length).toFixed(2)}ms outline=${outlineMs.toFixed(2)}ms artifact=${join(f.dir, "trace-perf.json")}\n`,
    );
  });

  it("loads trace for an active durable session without Pi tree metadata", async () => {
    const f = await fixture([]);
    await f.manager.startSession(f.session.id, f.workspace);
    const service = new SessionTraceService({
      storage: f.storage,
      sessionRuntimes: f.manager,
      ensureSessionContextWindow: (session) => session,
      mobileRenderers: f.manager.mobileRenderer,
    });
    expect(await f.manager.refreshSessionState(f.session.id)).toMatchObject({ leafId: null });
    await expect(service.getSessionWithTrace({ session: f.session })).resolves.toMatchObject({
      session: { id: f.session.id },
      trace: [],
    });
  });

  it("refreshes the phone queue from durable inbox updates while busy", async () => {
    const f = await fixture(
      [fauxAssistantMessage("A deliberately long stream so queued input remains pending.")],
      { slow: true },
    );
    const opening = vi.spyOn(DurableHarness.prototype, "open");
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    const started = projection.next((message) => message.type === "text_delta");
    await f.manager.sendPrompt(f.session.id, "Stream");
    await started;
    const { harness } = await opening.mock.results[0]!.value;
    const conversation = (await harness.conversation(
      f.storage.getSession(f.session.id)!.serverDurable!.conversationId! as ConversationId,
      context,
    ))!;
    const queued = projection.next(
      (message) =>
        message.type === "queue_state" &&
        message.queue.followUp.some((item) => item.message === "Native follow-up"),
    );
    await conversation.submit(
      { type: "input", content: "Native follow-up", whenBusy: "followUp" },
      context,
    );
    await queued;
    expect(
      (await f.manager.getMessageQueue(f.session.id)).followUp.map((item) => item.message),
    ).toEqual(["Native follow-up"]);
    await f.manager.sendAbort(f.session.id);
    projection.unsubscribe();
  });

  it("reports a failed emergency stop and retains the view when durable abort rejects", async () => {
    const f = await fixture([]);
    const harness = await openHarness(f.dir, f.models);
    const conversation = await harness.createConversation(
      { ownership: { kind: "ownerless" } },
      context,
    );
    f.session.serverDurable = { conversationId: conversation.id };
    vi.spyOn(conversation, "abort").mockRejectedValue(new Error("abort commit rejected"));
    vi.spyOn(harness, "conversation").mockResolvedValue(conversation);
    const activeBackend = await backend(harness, f.models, f.session, f.dir);
    const active = { session: f.session, sdkBackend: activeBackend, pendingStop: undefined };
    const broadcast = vi.fn();
    const ended = vi.fn();
    const coordinator = new SessionStopCoordinator(
      {
        getActiveSession: () => active,
        persistSessionNow: () => {},
        broadcast,
        handleSessionEnd: ended,
      },
      100,
      100,
    );
    coordinator.beginPendingStop(f.session.id, active, "terminate", "user");
    await coordinator.forceTerminateSessionProcess(
      f.session.id,
      active,
      "user",
      undefined,
      undefined,
      () => activeBackend.captureEmergencyDisposalForStop()(100),
    );
    expect(ended).not.toHaveBeenCalled();
    expect(broadcast.mock.calls.map(([, message]) => message)).toContainEqual(
      expect.objectContaining({
        type: "stop_failed",
        reason: "Force stop failed: abort commit rejected",
      }),
    );
    expect(broadcast.mock.calls.some(([, message]) => message.type === "stop_confirmed")).toBe(
      false,
    );
    expect(activeBackend.isDisposed).toBe(false);
    expect(activeBackend.messages()).toEqual([]);
    await activeBackend.detachForRestart();
  });

  it("keeps disabled creation and existing sessions on the SDK path without opening durable storage", async () => {
    const f = await fixture([]);
    f.storage.updateConfig({ experimental: { serverDurable: false } });
    const existing = f.storage.createSession("Existing");
    expect(existing.serverDurable).toBeUndefined();
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    expect(existsSync(join(f.dir, "durable"))).toBe(false);
    f.storage.updateConfig({ experimental: { serverDurable: true } });
    expect(f.storage.getSession(existing.id)?.serverDurable).toBeUndefined();
    const terminal = f.storage.createSession("Terminal", undefined, { durable: false });
    expect(terminal.serverDurable).toBeUndefined();
  });
});

import { mkdtempSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
  type ConversationId,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { DurableBackend, DurableNotSupportedError } from "../src/durable-backend.js";
import { Storage } from "../src/storage.js";
import { SessionManager } from "../src/sessions.js";
import { DurableHarness } from "../src/durable-harness.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import { SessionStopCoordinator } from "../src/session-stop.js";
import {
  queueOrphanedSessionsForRestart,
  recordLiveSessionsForRestart,
} from "../src/session-restart-resume.js";
import type { ServerMessage, Session } from "../src/types.js";

const managers: SessionManager[] = [];
const harnesses: Harness[] = [];
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
  vi.restoreAllMocks();
});

async function fixture(responses: FauxResponseStep[], options?: { slow?: boolean }) {
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
  const result = await DurableBackend.create({
    harness,
    models,
    session,
    dataDir,
    persistBinding: () => {},
    onEvent: () => {},
  });
  result.startEvents();
  return result;
}

describe("server durable managed runtime", () => {
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
    expect(f.manager.getMessageQueue(f.session.id).followUp).toHaveLength(1);
    const confirmed = projection.next((message) => message.type === "stop_confirmed");
    await f.manager.sendAbort(f.session.id);
    await confirmed;
    expect(f.manager.getMessageQueue(f.session.id)).toMatchObject({ steering: [], followUp: [] });
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
    expect(restarted.getMessageQueue(f.session.id).followUp).toEqual([]);
    expect(f.faux.state.callCount).toBe(1);
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
    await expect(
      f.manager.setMessageQueue(f.session.id, { steering: [], followUp: [], baseVersion: 0 }),
    ).rejects.toBeInstanceOf(DurableNotSupportedError);
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
    await f.manager.startSession(f.session.id, f.workspace);
    const projection = observe(f.manager, f.session.id);
    const marker = projection.next(
      (message) => message.type === "tool_output" && message.output.includes("MID_TOOL"),
    );
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
    expect(f.manager.getMessageQueue(f.session.id).followUp.map((item) => item.message)).toEqual([
      "Native follow-up",
    ]);
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

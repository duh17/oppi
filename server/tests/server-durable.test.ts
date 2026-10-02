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
import { Harness, createRegistry, type ConversationId } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { DurableBackend, DurableNotSupportedError } from "../src/durable-backend.js";
import { Storage } from "../src/storage.js";
import { SessionManager } from "../src/sessions.js";
import { queueOrphanedSessionsForRestart } from "../src/session-restart-resume.js";
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

async function openHarness(dir: string, models: ModelRuntime): Promise<Harness> {
  const registry = createRegistry();
  registry.install(CodingTools);
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
    await f.manager.sendPrompt(f.session.id, "Write proof.txt, then report success", {
      clientTurnId: "apple-turn-1",
    });
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
    const confirmed = projection.next((message) => message.type === "stop_confirmed");
    await f.manager.sendAbort(f.session.id);
    await confirmed;
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
    // Real Harness close models a process loss (unlike manager.close, which must abort).
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
    await resumed.prompt("Continue exactly this original turn", { clientTurnId: "restart-turn" });
    expect(f.faux.state.callCount).toBe(2);
    await resumed.dispose();
  }, 15_000);

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

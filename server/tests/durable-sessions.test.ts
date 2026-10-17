import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Message } from "@earendil-works/pi-ai";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
  type FauxResponseFactory,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import {
  AgentDoc,
  InboxDoc,
  LiveDoc,
  type ConversationId,
  type Harness,
  type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { createDurableSessions } from "../extensions/durable/sessions/durable.js";
import { Subagents } from "../extensions/durable/sessions/contract.js";
import { DurableUI } from "../extensions/durable/durable-ui.js";
import { OppiAgentDoc } from "../src/durable-agent.js";
import {
  DurableHarness,
  DurableRuntime,
  SessionHost,
  durableStoreDir,
  durableStoreSqlitePath,
} from "../src/durable-harness.js";
import { ProjectContextDoc } from "../extensions/durable/project-context/contract.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { createAgentScheduleDispatchHooks } from "../src/agent-schedule-dispatch.js";
import type { NewSessionDispatchInput } from "../src/agent-schedules.js";
import { SessionManager } from "../src/sessions.js";
import { readDurableTrace } from "../src/durable-history.js";
import { Storage } from "../src/storage.js";
import { recordLiveSessionsForRestart } from "../src/session-restart-resume.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { ServerMessage, Session, SessionThreadResponse } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const managers: SessionManager[] = [];
const gates: Array<() => void> = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
beforeEach(() => {
  process.env.PI_CODING_AGENT_DIR = mkdtempSync(join(tmpdir(), "oppi-durable-sessions-agent-"));
});
afterEach(async () => {
  // Release any model call a test left parked so shutdown can finish.
  for (const open of gates.splice(0)) open();
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

/** A scripted model call parks on `wait()` until the test opens it, or the call is aborted. */
function gate() {
  let open!: () => void;
  const opened = new Promise<void>((resolve) => {
    open = resolve;
  });
  gates.push(open);
  return {
    open,
    wait: (signal?: AbortSignal) =>
      Promise.race([
        opened,
        new Promise<void>((resolve) =>
          signal?.addEventListener("abort", () => resolve(), { once: true }),
        ),
      ]),
  };
}

function textOf(message: Message | undefined): string {
  if (!message) return "";
  if (typeof message.content === "string") return message.content;
  return message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

/** The scripted model answers each request by its newest non-system message. */
function model(
  route: (input: {
    last: Message;
    text: string;
    signal?: AbortSignal;
  }) => ReturnType<FauxResponseFactory>,
) {
  const step: FauxResponseFactory = (transcript, options) => {
    const last = transcript.messages.findLast((message) => message.role !== "system")!;
    return route({ last, text: textOf(last), signal: options?.signal });
  };
  return Array.from({ length: 60 }, () => step) as FauxResponseStep[];
}

const toolCall = (name: string, args: Record<string, unknown>) =>
  fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
const subagentCall = (action: string, args: Record<string, unknown> = {}) =>
  toolCall("subagent", { action, ...args });
const spawnCall = (args: Record<string, unknown>) => subagentCall("spawn", args);

async function fixture(responses: FauxResponseStep[], options?: { serverDurable?: boolean }) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-sessions-test-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider({ models: [{ id: "faux-1" }, { id: "faux-2" }] });
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
  storage.updateConfig({ experimental: { serverDurable: options?.serverDurable ?? true } });
  const workspace = storage.createWorkspace({ name: "Durable threads", hostMount: dir });
  const session = (name: string) => {
    const created = storage.createSession(name, "faux/faux-1");
    created.serverDurable = { storeId: created.id };
    created.workspaceId = workspace.id;
    storage.saveSession(created);
    return created;
  };
  const parent = session("Parent");
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  const openHost = async (sessionId: string): Promise<SessionHost> => {
    const storeId = storage.getSession(sessionId)?.serverDurable?.storeId ?? sessionId;
    for (const candidate of [...managers].reverse()) {
      const runtime = await (candidate as unknown as { durableHarness?: Promise<DurableHarness> })
        .durableHarness;
      const host = runtime?.host(storeId);
      if (host?.isOpen) return host;
    }
    throw new Error(`store ${storeId} is not open`);
  };
  const openStore = async (sessionId: string): Promise<Harness> =>
    (await (await openHost(sessionId)).open()).harness;
  return {
    dir,
    storage,
    workspace,
    manager,
    parent,
    session,
    openHost,
    openStore,
    harness: () => openStore(parent.id),
    /** The parent session's store host. */
    owner: () => openHost(parent.id),
    /** Oppi's thread host bound to the newest runtime. */
    threads: async () => {
      for (const candidate of [...managers].reverse()) {
        const runtime = await (candidate as unknown as { durableHarness?: Promise<DurableHarness> })
          .durableHarness;
        if (runtime?.boundThreads) return runtime.boundThreads;
      }
      throw new Error("thread host is not bound");
    },
  };
}
type Fixture = Awaited<ReturnType<typeof fixture>>;

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
              `Expected event; observed ${messages.map((message) => message.type).join(",")}`,
            ),
          );
        }, 10_000);
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

const conversationOf = (storage: Storage, session: Session | string) =>
  storage.getSession(typeof session === "string" ? session : session.id)!.serverDurable!
    .conversationId as ConversationId;

async function until(check: () => boolean | Promise<boolean>, what: string): Promise<void> {
  for (let tries = 0; tries < 500; tries += 1) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for ${what}`);
}

type ToolResult = {
  toolName: string;
  isError?: boolean;
  details?: Record<string, unknown>;
  text: string;
};
/** The tool results of a conversation, oldest first. */
async function toolResults(harness: Harness, id: ConversationId): Promise<ToolResult[]> {
  const page = await (await harness.conversation(id, context))!.entries(
    {},
    200,
    undefined,
    context,
  );
  return page.items.toReversed().flatMap((entry) => {
    const message = entry.model?.[0];
    if (message?.role !== "toolResult") return [];
    return [
      {
        toolName: message.toolName,
        isError: message.isError,
        details: message.details as Record<string, unknown> | undefined,
        text: textOf(message),
      },
    ];
  });
}
const userTexts = async (harness: Harness, id: ConversationId): Promise<string[]> =>
  (await (await harness.conversation(id, context))!.entries({}, 200, undefined, context)).items
    .toReversed()
    .flatMap((entry) => (entry.model?.[0]?.role === "user" ? [textOf(entry.model[0])] : []));

/** Request ids of a conversation's submissions, oldest first, read from the Harness database. */
function requestIds(
  storage: Storage,
  dir: string,
  session: Session | string,
  prefix: string,
): string[] {
  const row = storage.getSession(typeof session === "string" ? session : session.id)!;
  const storeId = row.serverDurable?.storeId;
  const id = row.serverDurable?.conversationId as ConversationId | undefined;
  if (!storeId || id === undefined) return [];
  const db = new DatabaseSync(durableStoreSqlitePath(dir, storeId), { readOnly: true });
  try {
    return (
      db
        .prepare(
          "SELECT json_extract(request_id, '$') AS request_id FROM submissions WHERE conversation_id = ? AND json_extract(request_id, '$') LIKE ? ORDER BY id",
        )
        .all(id, `${prefix}%`) as Array<{ request_id: string }>
    ).map((row) => row.request_id);
  } finally {
    db.close();
  }
}

async function getThread(f: Fixture, sessionId: string): Promise<SessionThreadResponse> {
  const routeContext = {
    sessions: { mobileRenderer: { renderers: () => [] } },
    storage: f.storage,
    sessionRuntimes: {
      getDurableThread: (id: string) => f.manager.getDurableThread(id),
      getActiveSessionIds: () => f.manager.getActiveSessionIds(),
      getActiveSession: (id: string) => f.manager.getActiveSession(id),
      getPromptCacheRuntime: () => undefined,
    },
    ensureSessionContextWindow: (session: Session) => session,
    getModelPromptCache: () => undefined,
  } as unknown as RouteContext;
  const dispatch = createSessionRoutes(routeContext, createRouteHelpers());
  const res = makeResponse();
  await dispatch({
    method: "GET",
    path: `/sessions/${sessionId}/thread`,
    url: new URL(`http://localhost/sessions/${sessionId}/thread`),
    req: makeRequest() as never,
    res: res as never,
  });
  expect(res.statusCode).toBe(200);
  return JSON.parse(res.body) as SessionThreadResponse;
}

describe("durable-native threads", () => {
  it("runs a foreground child as a bound Session: parent busy until it is idle, thread from ownership", async () => {
    const childGate = gate();
    let childStarted!: () => void;
    const started = new Promise<void>((resolve) => (childStarted = resolve));
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK scout", name: "Scout", wait: true });
        childStarted();
        await childGate.wait(signal);
        return fauxAssistantMessage("CHILD_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const parentEnd = observe(f.manager, f.parent.id).next(
      (message) => message.type === "agent_end",
    );
    await f.manager.sendPrompt(f.parent.id, "Delegate the scouting");
    await started;
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);

    // The child is a Session bound to its own conversation, owned by the parent's tool call.
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    expect(child.name).toBe("Scout");
    expect(child.workspaceId).toBe(f.workspace.id);
    expect(child.launch?.parentSessionId).toBe(f.parent.id);
    expect(f.manager.isActive(child.id)).toBe(true);
    const childConversation = conversationOf(f.storage, child);
    const record = await harness.commit((tx) => tx.conversation(childConversation), context);
    expect(record?.owner?.conversationId).toBe(parentConversation);

    // Busy until the child is idle.
    expect((await harness.snapshot(LiveDoc, parentConversation, context))?.run).toBeDefined();
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();

    // The thread comes from ownership: it survives losing the launch edge copy.
    const stored = f.storage.getSession(child.id)!;
    f.storage.saveSession({ ...stored, launch: { ...stored.launch!, parentSessionId: undefined } });
    for (const from of [f.parent.id, child.id]) {
      const thread = await getThread(f, from);
      expect(thread.rootSessionId).toBe(f.parent.id);
      expect(thread.sessions.map((session) => session.id).sort()).toEqual(
        [f.parent.id, child.id].sort(),
      );
    }
    f.storage.saveSession(stored);

    // A session the phone starts "in thread" has a launch edge but no owner; it still joins.
    const phoneChild = f.session("Phone child");
    phoneChild.launch = {
      source: "human",
      parentSessionId: f.parent.id,
      status: "created",
      requestedAt: Date.now(),
    };
    f.storage.saveSession(phoneChild);
    expect((await getThread(f, child.id)).sessions.map((session) => session.id).sort()).toEqual(
      [f.parent.id, child.id, phoneChild.id].sort(),
    );

    childGate.open();
    await parentEnd;
    const [result] = await toolResults(harness, parentConversation);
    expect(result).toMatchObject({
      toolName: "subagent",
      text: "CHILD_ANSWER",
      details: { name: "Scout", conversationId: childConversation, sessionId: child.id },
    });
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeUndefined();
  });

  it("aborts a foreground child with its parent's Stop", async () => {
    const childGate = gate();
    let childStarted!: () => void;
    const started = new Promise<void>((resolve) => (childStarted = resolve));
    const f = await fixture(
      model(async ({ text, signal }) => {
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK park", name: "Parked", wait: true });
        childStarted();
        await childGate.wait(signal);
        return fauxAssistantMessage("NEVER_ANSWERED");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate and wait");
    await started;
    const harness = await f.harness();
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();

    await f.manager.sendAbort(f.parent.id);

    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeUndefined();
    expect(
      (await harness.snapshot(LiveDoc, conversationOf(f.storage, f.parent), context))?.run,
    ).toBeUndefined();
    // The child Session stays: its lane keeps its history.
    expect(f.storage.getSession(child.id)).toBeDefined();
  });

  it("returns a background spawn at once and delivers the child's report as one follow-up", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK later", name: "Later" });
        await childGate.wait(signal);
        return fauxAssistantMessage("BACKGROUND_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const parentEvents = observe(f.manager, f.parent.id);
    const parentEnd = parentEvents.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    await parentEnd;
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);

    // The parent is idle while the child still works; the child is owned through the anchor.
    await until(
      async () => (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
      "parent idle",
    );
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();
    const [spawned] = await toolResults(harness, parentConversation);
    expect(spawned?.details).toMatchObject({ background: true, sessionId: child.id });
    const record = await harness.commit((tx) => tx.conversation(childConversation), context);
    expect(record?.owner?.conversationId).toBe(parentConversation);
    const anchor = await harness.getTask(record!.owner!.taskId, context);
    expect(anchor?.background).toBe(true);

    childGate.open();
    await until(
      async () =>
        (await userTexts(harness, parentConversation)).some((text) =>
          text.includes("BACKGROUND_ANSWER"),
        ),
      "the report",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    const reports = (await userTexts(harness, parentConversation)).filter((text) =>
      text.includes("finished, no reply needed"),
    );
    expect(reports).toEqual([
      `[session Later (${child.id}) finished, no reply needed] BACKGROUND_ANSWER`,
    ]);

    // The model reads the header; the transcript shows the child's answer, attributed to it.
    const report = { kind: "session", sessionId: child.id, name: "Later", intent: "report" };
    const parentTrace = await readDurableTrace(harness, parentConversation, "full");
    expect(parentTrace.filter((event) => event.origin)).toEqual([
      expect.objectContaining({ type: "user", text: "BACKGROUND_ANSWER", origin: report }),
    ]);
    expect(
      parentEvents.messages.filter(
        (message) => message.type === "message_end" && message.role === "user",
      ),
    ).toEqual([
      expect.not.objectContaining({ origin: expect.anything() }),
      expect.objectContaining({ content: "BACKGROUND_ANSWER", origin: report }),
    ]);
    // The child's task is the parent's message.
    const childTrace = await readDurableTrace(harness, childConversation, "full");
    expect(childTrace.find((event) => event.type === "user")).toMatchObject({
      text: "CHILD_TASK later",
      origin: { kind: "session", sessionId: f.parent.id, intent: "task" },
    });
  });

  it("keeps a background child running through its busy parent's Stop", async () => {
    const childGate = gate();
    const parentGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") {
          await parentGate.wait(signal);
          return fauxAssistantMessage("STARTED");
        }
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK later", name: "Later" });
        await childGate.wait(signal);
        return fauxAssistantMessage("SURVIVOR_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 1,
      "spawn result",
    );
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    // The parent is mid-turn (parked on its next model call) and the child is working.
    expect((await harness.snapshot(LiveDoc, parentConversation, context))?.run).toBeDefined();

    await f.manager.sendAbort(f.parent.id);

    expect((await harness.snapshot(LiveDoc, parentConversation, context))?.run).toBeUndefined();
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();
    childGate.open();
    await until(
      async () =>
        (await userTexts(harness, parentConversation)).some((text) =>
          text.includes("SURVIVOR_ANSWER"),
        ),
      "the report after Stop",
    );
  });

  it("shows children in a pill that links to each child and follows its runs, also after the watcher retires", async () => {
    const childGate = gate();
    const againGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate")) return spawnCall({ task: "CHILD_TASK pill", name: "Scout" });
        await (text.includes("CHILD_TASK pill") ? childGate : againGate).wait(signal);
        return fauxAssistantMessage("PILL_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const parentEvents = observe(f.manager, f.parent.id);
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(() => f.storage.listSessions().length === 2, "the child session");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const pill = async () =>
      (await harness.snapshot(DurableUI, parentConversation, context))?.notifications[
        "widget:subagents"
      ]?.nativeSurface as
        | {
            presentation: { title: string; subtitle?: string };
            blocks: Array<{ rows: Array<Record<string, unknown>> }>;
          }
        | undefined;
    const row = async () => (await pill())?.blocks[0]?.rows[0];

    await until(async () => (await row())?.state === "running", "a working row");
    expect((await pill())?.presentation).toMatchObject({
      title: "1 subagent",
      subtitle: "Working",
    });
    expect(await row()).toMatchObject({
      id: child.id,
      title: "Scout",
      link: `oppi://session/${child.id}`,
      subtitle: "Working · faux-1",
    });
    // The client receives it through the generic widget projection.
    await until(
      () =>
        parentEvents.messages.some(
          (message) =>
            message.type === "extension_ui_notification" &&
            message.widgetKey === "subagents" &&
            message.nativeSurface?.presentation?.subtitle === "Working",
        ),
      "the projected widget",
    );

    childGate.open();
    await until(async () => (await row())?.state === "success", "a done row");
    expect((await pill())?.presentation).toMatchObject({ title: "1 subagent", subtitle: "Done" });
    expect(await row()).toMatchObject({ subtitle: "Done · faux-1" });
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

    // An idle store retires the watcher as a ticker (here: aborted directly); attaching the
    // parent again brings it back.
    const widgetTask = async () =>
      (await harness.snapshot(Subagents, parentConversation, context))?.widget;
    const retired = await widgetTask();
    await harness.abortTask(retired!, context);
    await f.manager.stopSession(f.parent.id);
    await f.manager.startSession(f.parent.id, f.workspace);
    await until(async () => (await widgetTask()) !== retired, "a new watcher");
    await f.manager.sendPrompt(child.id, "Once more");
    await until(
      async () => (await row())?.state === "running",
      "the new watcher follows the child",
    );
    againGate.open();
    await until(async () => (await row())?.state === "success", "done again");
  });

  it("shows a child stopped before its first answer as done, not working", async () => {
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK quiet", name: "Quiet" });
        await gate().wait(signal);
        return fauxAssistantMessage("NEVER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(() => f.storage.listSessions().length === 2, "the child session");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const state = async () =>
      (
        (await harness.snapshot(DurableUI, parentConversation, context))?.notifications[
          "widget:subagents"
        ]?.nativeSurface as { blocks: Array<{ rows: Array<{ state: string }> }> } | undefined
      )?.blocks[0]?.rows[0]?.state;
    await until(async () => (await state()) === "running", "a working row");

    await f.manager.sendAbort(child.id);
    await until(async () => (await state()) === "success", "a done row");
  });

  it("resumes a running child after a restart because its Session keeps it in resumeIds", async () => {
    let childCalls = 0;
    const firstCall = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate")) return spawnCall({ task: "CHILD_TASK long", name: "Long" });
        childCalls += 1;
        if (childCalls === 1) {
          // Interrupted by the shutdown: the answer must come from the resumed run.
          await firstCall.wait(signal);
          throw new Error("interrupted by shutdown");
        }
        return fauxAssistantMessage("RESUMED_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    await until(() => childCalls === 1, "the child's first model call");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const parentConversation = conversationOf(f.storage, f.parent);
    const childConversation = conversationOf(f.storage, child);
    await until(
      async () => (await toolResults(await f.harness(), parentConversation)).length === 1,
      "spawn result",
    );

    recordLiveSessionsForRestart(f.storage, [
      f.manager.getActiveSession(f.parent.id)!,
      f.manager.getActiveSession(child.id)!,
    ]);
    expect(f.storage.listRestartResume().map((entry) => entry.sessionId)).toContain(child.id);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);

    const restarted = new SessionManager(new Storage(f.dir));
    managers.push(restarted);
    await restarted.resumeDurableSessions();
    expect(restarted.isActive(child.id)).toBe(true);
    const harness = await f.harness();
    await until(
      async () =>
        (await userTexts(harness, parentConversation)).some((text) =>
          text.includes("RESUMED_ANSWER"),
        ),
      "the resumed child's report",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

    // Delivered once on each side despite the rerun.
    expect(childCalls).toBe(2);
    expect(
      (await userTexts(harness, childConversation)).filter((text) => text === "CHILD_TASK long"),
    ).toHaveLength(1);
    expect(requestIds(f.storage, f.dir, child.id, "oppi-spawn:")).toHaveLength(1);
    expect(requestIds(f.storage, f.dir, f.parent.id, "oppi-report:")).toHaveLength(1);
    expect(
      (await userTexts(harness, parentConversation)).filter((text) =>
        text.includes("finished, no reply needed"),
      ),
    ).toHaveLength(1);
  });

  it("stops a child's current work by name; the child stays usable, and wait returns its answer", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ task: "CHILD_TASK work", name: "Worker" });
        if (text.includes("Stop nobody")) return subagentCall("stop", { name: "Nobody" });
        if (text.includes("Stop it")) return subagentCall("stop", { name: "Worker" });
        if (text.includes("Ask again"))
          return subagentCall("send", { name: "Worker", message: "SECOND_TASK" });
        if (text.includes("Wait for it")) return subagentCall("wait", { names: ["Worker"] });
        if (text.includes("List them")) return subagentCall("list");
        if (text.includes("CHILD_TASK")) {
          await childGate.wait(signal);
          return fauxAssistantMessage("CHILD_DONE");
        }
        if (text.includes("SECOND_TASK")) return fauxAssistantMessage("SECOND_ANSWER");
        return fauxAssistantMessage("OTHER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    let results = 0;
    const call = async (prompt: string): Promise<ToolResult> => {
      await f.manager.sendPrompt(f.parent.id, prompt);
      results += 1;
      await until(
        async () =>
          (await toolResults(harness, parentConversation)).length === results &&
          (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
        prompt,
      );
      return (await toolResults(harness, parentConversation))[results - 1]!;
    };
    await call("Spawn it");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();

    expect(await call("Stop nobody")).toMatchObject({
      toolName: "subagent",
      isError: true,
      text: "No subagent named Nobody.",
    });
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();

    expect(await call("Stop it")).toMatchObject({
      text: "Stopped Worker.",
      details: { name: "Worker", sessionId: child.id },
    });
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeUndefined();

    // Stopped, not removed: its transcript stays and it takes new work.
    expect(await call("Ask again")).toMatchObject({ text: "Sent to Worker (steer)." });
    // The phone opens each child from the row's ids.
    const ids = { name: "Worker", conversationId: childConversation, sessionId: child.id };
    expect(await call("Wait for it")).toMatchObject({
      text: "Worker: SECOND_ANSWER",
      details: { children: [ids] },
    });
    expect(await userTexts(harness, childConversation)).toEqual(["CHILD_TASK work", "SECOND_TASK"]);
    const listed = await call("List them");
    expect(listed.text).toBe(
      `Worker | idle | agent: none | model: faux/faux-1 | session: ${child.id}`,
    );
    expect(listed.details).toEqual({ children: [ids] });
    // A stopped task has no report.
    expect(requestIds(f.storage, f.dir, f.parent.id, "oppi-report:")).toEqual([]);
  });

  it("stops only the caller's own child when another store has the same name and conversation id", async () => {
    const ownerGate = gate();
    const strangerGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Owner spawn"))
          return spawnCall({ task: "OWNER_CHILD work", name: "Worker" });
        if (text.includes("Stranger spawn"))
          return spawnCall({ task: "STRANGER_CHILD work", name: "Worker" });
        if (text.includes("Stranger stop")) return subagentCall("stop", { name: "Worker" });
        if (text.includes("OWNER_CHILD")) {
          await ownerGate.wait(signal);
          return fauxAssistantMessage("OWNER_DONE");
        }
        if (text.includes("STRANGER_CHILD")) {
          await strangerGate.wait(signal);
          return fauxAssistantMessage("STRANGER_DONE");
        }
        return fauxAssistantMessage("OTHER");
      }),
    );
    const stranger = f.session("Stranger");
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.startSession(stranger.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Owner spawn");
    await f.manager.sendPrompt(stranger.id, "Stranger spawn");
    const ownerHarness = await f.harness();
    const strangerHarness = await f.openStore(stranger.id);
    const ownerConversation = conversationOf(f.storage, f.parent);
    const strangerConversation = conversationOf(f.storage, stranger);
    await until(
      async () => (await toolResults(ownerHarness, ownerConversation)).length === 1,
      "owner spawn",
    );
    await until(
      async () => (await toolResults(strangerHarness, strangerConversation)).length === 1,
      "stranger spawn",
    );
    const ownerChild = f.storage
      .listSessions()
      .find((session) => session.launch?.parentSessionId === f.parent.id)!;
    const strangerChild = f.storage
      .listSessions()
      .find((session) => session.launch?.parentSessionId === stranger.id)!;
    const ownerChildConversation = conversationOf(f.storage, ownerChild);
    const strangerChildConversation = conversationOf(f.storage, strangerChild);
    expect(ownerChildConversation).toBe(strangerChildConversation);
    expect(ownerChild.serverDurable?.storeId).not.toBe(strangerChild.serverDurable?.storeId);

    await until(
      async () =>
        (await ownerHarness.snapshot(LiveDoc, ownerChildConversation, context))?.run !== undefined,
      "owner child running",
    );
    await until(
      async () =>
        (await strangerHarness.snapshot(LiveDoc, strangerChildConversation, context))?.run !==
        undefined,
      "stranger child running",
    );

    await f.manager.sendPrompt(stranger.id, "Stranger stop");
    await until(
      async () => (await toolResults(strangerHarness, strangerConversation)).length === 2,
      "stranger stop",
    );
    expect((await toolResults(strangerHarness, strangerConversation))[1]).toMatchObject({
      toolName: "subagent",
      text: "Stopped Worker.",
      details: { sessionId: strangerChild.id },
    });
    expect(
      (await ownerHarness.snapshot(LiveDoc, ownerChildConversation, context))?.run,
    ).toBeDefined();
    expect(
      (await strangerHarness.snapshot(LiveDoc, strangerChildConversation, context))?.run,
    ).toBeUndefined();
  });

  it("records the oppi-send request id when a session messages its child, and reserves the prefix", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ task: "CHILD_TASK quick", name: "Quick" });
        if (text.includes("Message it"))
          return subagentCall("send", { name: "Quick", message: "HELLO_CHILD", followUp: true });
        if (text.includes("Wait for it")) return subagentCall("wait", { names: ["Quick"] });
        return fauxAssistantMessage("CHILD_REPLY");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "spawn");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);

    await f.manager.sendPrompt(f.parent.id, "Message it now");
    await until(async () => (await toolResults(harness, parentConversation)).length === 2, "send");
    const sent = (await toolResults(harness, parentConversation))[1]!;
    expect(sent).toMatchObject({ toolName: "subagent", text: "Sent to Quick (followUp)." });
    const parentStore = f.storage.getSession(f.parent.id)!.serverDurable!.storeId!;
    const sendRequestId = String(sent.details?.requestId);
    const sendPrefix = `oppi-send:${parentStore}:${parentConversation}:`;
    expect(sendRequestId.startsWith(sendPrefix)).toBe(true);
    expect(sendRequestId.slice(sendPrefix.length)).toMatch(/^\d+$/);
    const receipt = await harness.commit(
      (tx) => tx.submissionByRequest(childConversation, sent.details!.requestId as string),
      context,
    );
    expect(receipt?.type).toBe("input");
    expect(requestIds(f.storage, f.dir, child.id, "oppi-send:")).toEqual([sent.details!.requestId]);
    expect(await userTexts(harness, childConversation)).toContain("HELLO_CHILD");
    const childTrace = await readDurableTrace(harness, childConversation, "full");
    expect(childTrace.find((event) => event.text === "HELLO_CHILD")?.origin).toEqual({
      kind: "session",
      sessionId: f.parent.id,
      name: f.parent.name,
      intent: "message",
    });

    await f.manager.sendPrompt(f.parent.id, "Wait for it please");
    await until(async () => (await toolResults(harness, parentConversation)).length === 3, "wait");
    expect((await toolResults(harness, parentConversation))[2]).toMatchObject({
      toolName: "subagent",
      text: "Quick: CHILD_REPLY",
    });

    // Clients cannot occupy the namespace.
    await expect(
      f.manager.sendPrompt(child.id, "spoof", { clientTurnId: "oppi-send:1" }),
    ).rejects.toThrow("reserved durable requestId namespace");
  });

  it("admits one request id once across the session socket and subagent send", async () => {
    const busy = gate();
    let held!: () => void;
    const holding = new Promise<void>((resolve) => (held = resolve));
    const f = await fixture(
      model(async ({ text, signal }) => {
        if (text === "HOLD") {
          held();
          await busy.wait(signal);
        }
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const threads = await f.threads();
    const harness = await f.harness();
    const id = conversationOf(f.storage, f.parent);
    const events = observe(f.manager, f.parent.id);

    // The socket and subagent send race one request id: one admission, one user row.
    const answered = events.next((message) => message.type === "agent_end");
    await Promise.all([
      f.manager.sendPrompt(f.parent.id, "SAME", { clientTurnId: "shared-turn" }),
      threads.submit(f.parent.id, {
        content: "SAME",
        whenBusy: "followUp",
        requestId: "shared-turn",
      }),
    ]);
    await answered;
    expect(await userTexts(harness, id)).toEqual(["SAME"]);
    expect(requestIds(f.storage, f.dir, f.parent, "shared-turn")).toEqual(["shared-turn"]);

    // A repeated send to a busy session queues once; changed content is a conflict.
    await f.manager.sendPrompt(f.parent.id, "HOLD");
    await holding;
    const send = { content: "QUEUED", whenBusy: "followUp" as const, requestId: "repeat-send" };
    expect(await threads.submit(f.parent.id, send)).toBeUndefined();
    expect(await threads.submit(f.parent.id, send)).toBeUndefined();
    await expect(threads.submit(f.parent.id, { ...send, content: "CHANGED" })).rejects.toThrow(
      "clientTurnId conflict",
    );
    expect(
      (await harness.snapshot(InboxDoc, id, context))?.items.map((item) => item.content),
    ).toEqual(["QUEUED"]);

    busy.open();
    await until(
      async () => (await userTexts(harness, id)).join(",") === "SAME,HOLD,QUEUED",
      "the queued send to run once",
    );
    await threads.waitForIdle(f.parent.id);
    expect(await userTexts(harness, id)).toEqual(["SAME", "HOLD", "QUEUED"]);
  });

  it("reruns a foreground spawn after a restart against the same child and Session", async () => {
    let childCalls = 0;
    const firstCall = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK foreground", name: "Fg", wait: true });
        childCalls += 1;
        if (childCalls === 1) {
          await firstCall.wait(signal);
          throw new Error("interrupted by shutdown");
        }
        return fauxAssistantMessage("FG_RESUMED");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate and wait");
    await until(() => childCalls === 1, "the child's first model call");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const parentConversation = conversationOf(f.storage, f.parent);

    recordLiveSessionsForRestart(f.storage, [
      f.manager.getActiveSession(f.parent.id)!,
      f.manager.getActiveSession(child.id)!,
    ]);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    const reopened = new Storage(f.dir);
    const restarted = new SessionManager(reopened);
    managers.push(restarted);
    await restarted.resumeDurableSessions();
    const harness = await f.harness();
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 1,
      "tool result",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

    expect((await toolResults(harness, parentConversation))[0]).toMatchObject({
      text: "FG_RESUMED",
      details: { sessionId: child.id },
    });
    // One child, one Session: the rerun found them instead of making more.
    expect(reopened.listSessions().filter((session) => session.id !== f.parent.id)).toHaveLength(1);
    expect(childCalls).toBe(2);
  });

  it("gives a child no subagent tool without the grant; a granted child's subtree spawns two levels down", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Delegate plain"))
          return spawnCall({ name: "Plain", task: "PLAIN_TASK", wait: true });
        if (text.includes("Delegate lead"))
          return spawnCall({
            name: "Lead",
            task: "LEAD_TASK",
            wait: true,
            allowNestedDelegation: true,
          });
        // The plain child tries anyway; the lead's subtree really spawns.
        if (text.includes("PLAIN_TASK")) return spawnCall({ name: "Grand", task: "GRAND_TASK" });
        if (text.includes("LEAD_TASK"))
          return spawnCall({ name: "Mid", task: "MID_TASK", wait: true });
        if (text.includes("MID_TASK"))
          return spawnCall({ name: "Leaf", task: "LEAF_TASK", wait: true });
        return fauxAssistantMessage("LEAF_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const rowNamed = (name: string) =>
      f.storage.listSessions().find((session) => session.name === name);
    const agentOf = async (session: Session) =>
      (await harness.conversation(conversationOf(f.storage, session), context))!.agent(context);
    const toolsOf = async (session: Session) =>
      (await agentOf(session)).tools.map((tool) => tool.name);

    await f.manager.sendPrompt(f.parent.id, "Delegate plain");
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 1,
      "plain spawn",
    );
    const plain = rowNamed("Plain")!;
    const plainConversation = conversationOf(f.storage, plain);
    expect(plain.launch?.allowsNestedDelegation).toBeUndefined();
    expect(await toolsOf(plain)).not.toContain("subagent");
    // Nor its guidance: the extension is not selected, also after the child attached.
    expect((await agentOf(plain)).sections.map((section) => section.key)).not.toContain("sessions");
    expect(await toolsOf(f.parent)).toContain("subagent");
    const [refused] = await toolResults(harness, plainConversation);
    expect(refused).toMatchObject({ toolName: "subagent", isError: true });
    expect(
      (
        await harness.commit(
          (tx) => tx.scanConversations({ ownerConversationId: plainConversation }, 10),
          context,
        )
      ).items,
    ).toHaveLength(0);

    await f.manager.sendPrompt(f.parent.id, "Delegate lead");
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 2,
      "lead spawn",
    );
    const [lead, mid, leaf] = ["Lead", "Mid", "Leaf"].map((name) => rowNamed(name)!);
    // The grant passes down; each row's parent is its direct parent.
    expect(lead!.launch).toMatchObject({
      parentSessionId: f.parent.id,
      allowsNestedDelegation: true,
    });
    expect(mid!.launch).toMatchObject({ parentSessionId: lead!.id, allowsNestedDelegation: true });
    expect(leaf!.launch).toMatchObject({ parentSessionId: mid!.id, allowsNestedDelegation: true });
    expect(await toolsOf(leaf!)).toContain("subagent");
    expect((await toolResults(harness, conversationOf(f.storage, mid!)))[0]).toMatchObject({
      text: "LEAF_ANSWER",
      details: { name: "Leaf", sessionId: leaf!.id },
    });
    expect((await getThread(f, leaf!.id)).sessions.map((session) => session.id).sort()).toEqual(
      [f.parent.id, plain.id, lead!.id, mid!.id, leaf!.id].sort(),
    );
  });

  it("refuses a grant from a sandbox parent, before any child exists", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Grant"))
          return spawnCall({ name: "Granted", task: "T", allowNestedDelegation: true });
        return fauxAssistantMessage("OK");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await harness.commit(async (tx) => {
      const runtime = await tx.doc(DurableRuntime, parentConversation);
      runtime.kind = "sandbox";
      runtime.workspaceId = f.workspace.id;
    }, context);
    (await f.owner()).bindSandboxEnv(parentConversation, new NodeExecutionEnv({ cwd: f.dir }));

    await f.manager.sendPrompt(f.parent.id, "Grant it");
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "grant");
    expect((await toolResults(harness, parentConversation))[0]).toMatchObject({
      toolName: "subagent",
      isError: true,
      text: expect.stringContaining("Sandbox sessions cannot authorize nested delegation"),
    });
    expect(f.storage.listSessions().map((session) => session.id)).toEqual([f.parent.id]);
  });

  it("steers a busy child or queues after its answer", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ name: "Busy", task: "BUSY_TASK" });
        if (text.includes("Steer it"))
          return subagentCall("send", { name: "Busy", message: "STEER_MSG" });
        if (text.includes("Queue it"))
          return subagentCall("send", { name: "Busy", message: "QUEUE_MSG", followUp: true });
        if (text.includes("BUSY_TASK")) await childGate.wait(signal);
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    for (const [prompt, results] of [
      ["Spawn it", 1],
      ["Steer it", 2],
      ["Queue it", 3],
    ] as const) {
      await f.manager.sendPrompt(f.parent.id, prompt);
      await until(
        async () =>
          (await toolResults(harness, parentConversation)).length === results &&
          (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
        prompt,
      );
    }
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    expect(
      (await harness.snapshot(InboxDoc, childConversation, context))?.items.map((item) => [
        item.mode,
        item.mode === "write" ? undefined : item.content,
      ]),
    ).toEqual([
      ["steer", "STEER_MSG"],
      ["followUp", "QUEUE_MSG"],
    ]);

    childGate.open();
    await until(
      async () => (await userTexts(harness, childConversation)).includes("QUEUE_MSG"),
      "the queued message",
    );
    expect(await userTexts(harness, childConversation)).toEqual([
      "BUSY_TASK",
      "STEER_MSG",
      "QUEUE_MSG",
    ]);
  });

  it("spawns a saved Agent as its AgentChange: model, tools, replaced instructions without project context", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Review it"))
          return spawnCall({ name: "Rev", task: "REVIEW_TASK", agent: "Reviewer", wait: true });
        if (text.includes("Plug it"))
          return spawnCall({ name: "Plug", task: "T", agent: "Plugged", wait: true });
        if (text.includes("Fence it"))
          return spawnCall({ name: "Fence", task: "T", agent: "Fenced", wait: true });
        if (text.includes("List them")) return subagentCall("list");
        return fauxAssistantMessage("REVIEWED");
      }),
    );
    writeFileSync(join(f.dir, "AGENTS.md"), "PROJECT_RULES_MARKER");
    const agents = f.storage.getAgentDefinitionStore();
    const reviewer = agents.createAgent({
      name: "Reviewer",
      instructions: { mode: "replace", text: "REVIEWER_PROMPT" },
      sessionDefaults: { model: "faux/faux-2", thinkingLevel: "high", tools: ["read", "ask"] },
    });
    agents.createAgent({
      name: "Plugged",
      resources: { extensionIds: ["extension_missing", "builtin:codemode"] },
    });
    agents.createAgent({
      name: "Fenced",
      launchConstraints: { allowedWorkspaceIds: ["elsewhere"] },
    });
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    let results = 0;
    const call = async (prompt: string): Promise<ToolResult> => {
      await f.manager.sendPrompt(f.parent.id, prompt);
      results += 1;
      await until(
        async () =>
          (await toolResults(harness, parentConversation)).length === results &&
          (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
        prompt,
      );
      return (await toolResults(harness, parentConversation))[results - 1]!;
    };

    expect(await call("Review it")).toMatchObject({ text: "REVIEWED" });
    const child = f.storage.listSessions().find((session) => session.name === "Rev")!;
    const childConversation = conversationOf(f.storage, child);
    const stored = await harness.snapshot(AgentDoc, childConversation, context);
    expect(stored).toMatchObject({
      model: { provider: "faux", modelId: "faux-2" },
      thinkingLevel: "high",
      tools: ["read", "ask"],
    });
    expect(stored?.instructions?.startsWith("REVIEWER_PROMPT\n\nWorking directory: ")).toBe(true);
    expect(await harness.snapshot(OppiAgentDoc, childConversation, context)).toEqual({
      agent: { id: reviewer.id, version: 1, name: "Reviewer", icon: { kind: "default" } },
      spawn: false,
      grant: false,
      projectContext: false,
      tools: { allowed: ["read", "ask"] },
    });
    // The parent reads the project's AGENTS.md; the replaced prompt drops that section.
    expect(
      (await harness.snapshot(ProjectContextDoc, parentConversation, context))?.projectContext,
    ).toContain("PROJECT_RULES_MARKER");
    expect(
      (await harness.snapshot(ProjectContextDoc, childConversation, context))?.projectContext,
    ).toBeUndefined();
    expect(child.launch).toMatchObject({
      agentId: reviewer.id,
      agentVersion: 1,
      model: "faux/faux-2",
      tools: { allowed: ["read", "ask"] },
    });

    const plugged = await call("Plug it");
    expect(plugged).toMatchObject({ isError: true });
    expect(plugged.text).toContain(
      "Selected Agent Extension has no durable entry for a host session: extension_missing, builtin:codemode",
    );
    const fenced = await call("Fence it");
    expect(fenced).toMatchObject({ isError: true });
    expect(fenced.text).toContain("Start it as a top-level session instead");
    expect(
      f.storage
        .listSessions()
        .map((session) => session.name)
        .sort(),
    ).toEqual(["Parent", "Rev"]);
    expect((await call("List them")).text).toBe(
      `Rev | idle | agent: Reviewer | model: faux/faux-2 | session: ${child.id}`,
    );
  });

  it("does not start new host turns from a background report once its parent is stopped", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK later", name: "Later" });
        await childGate.wait(signal);
        return fauxAssistantMessage("LATE_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(
      async () =>
        (await toolResults(harness, parentConversation)).length === 1 &&
        (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
      "idle parent with a background child",
    );
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);

    await f.manager.stopSession(f.parent.id);

    // The child is not the parent's to stop.
    expect(f.manager.isActive(f.parent.id)).toBe(false);
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();
    childGate.open();
    await until(
      async () => (await harness.snapshot(LiveDoc, childConversation, context))?.run === undefined,
      "child idle",
    );
    await new Promise((resolve) => setTimeout(resolve, 300));

    expect(requestIds(f.storage, f.dir, f.parent.id, "oppi-report:")).toEqual([]);
    expect(
      (await userTexts(harness, parentConversation)).filter((text) => text.includes("[session")),
    ).toEqual([]);
    expect((await harness.snapshot(LiveDoc, parentConversation, context))?.run).toBeUndefined();
  });

  it("does not adopt a Session row that is not bound to the child's conversation", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ task: "CHILD_TASK work", name: "Worker" });
        await childGate.wait(signal);
        return fauxAssistantMessage("OK");
      }),
    );
    const stranger = f.session("Stranger");
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.startSession(stranger.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "spawn");
    const child = f.storage
      .listSessions()
      .find((session) => session.id !== f.parent.id && session.id !== stranger.id)!;
    const childConversation = conversationOf(f.storage, child);
    const sessions = (await f.threads()).forCaller(await f.owner(), parentConversation);
    // The row holding the child's key is now one a client made: it points elsewhere, or nowhere.
    for (const serverDurable of [
      { conversationId: conversationOf(f.storage, stranger) },
      undefined,
    ]) {
      f.storage.saveSession({ ...child, serverDurable });
      await expect(
        sessions.materialize({ conversationId: childConversation, name: "Again" }),
      ).rejects.toThrow(/not bound to the child conversation/);
    }
    expect(f.storage.listSessions()).toHaveLength(3);
    f.storage.saveSession(child);
    await expect(
      sessions.materialize({ conversationId: childConversation, name: "Again" }),
    ).resolves.toBe(child.id);
  });

  it("keeps the surviving children in one thread after their parent's Session is deleted", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn one")) return spawnCall({ task: "CHILD_TASK one", name: "One" });
        if (text.includes("Spawn two")) return spawnCall({ task: "CHILD_TASK two", name: "Two" });
        await childGate.wait(signal);
        return fauxAssistantMessage("OK");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const spawn = async (prompt: string, results: number) => {
      await f.manager.sendPrompt(f.parent.id, prompt);
      await until(
        async () =>
          (await toolResults(harness, parentConversation)).length === results &&
          (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
        prompt,
      );
    };
    await spawn("Spawn one", 1);
    await spawn("Spawn two", 2);
    const children = f.storage.listSessions().filter((session) => session.id !== f.parent.id);
    expect(children).toHaveLength(2);

    await f.manager.stopSession(f.parent.id);
    f.storage.deleteSession(f.parent.id);

    for (const from of children) {
      const thread = await getThread(f, from.id);
      expect(thread.rootSessionId).toBe(from.id);
      expect(thread.sessions.map((session) => session.id).sort()).toEqual(
        children.map((child) => child.id).sort(),
      );
    }
  });
});

describe("durable engine on create requests", () => {
  async function route(
    f: Fixture,
    method: "GET" | "POST",
    path: string,
    body?: Record<string, unknown>,
  ) {
    const routeContext = {
      storage: f.storage,
      sessions: f.manager,
      sessionRuntimes: f.manager,
      ensureSessionContextWindow: (session: Session) => session,
      getModelPromptCache: () => undefined,
    } as unknown as RouteContext;
    const res = makeResponse();
    const url = new URL(`http://localhost${path}`);
    const routes =
      path === "/server/info"
        ? createIdentityRoutes(
            {
              ...routeContext,
              skillRegistry: { list: () => [] },
              getModelCatalog: () => [],
              serverStartedAt: Date.now(),
              serverVersion: "test",
              piVersion: "test",
            } as unknown as RouteContext,
            createRouteHelpers(),
          )
        : path.startsWith("/agents/")
          ? createAgentRoutes(routeContext, createRouteHelpers())
          : createSessionRoutes(routeContext, createRouteHelpers());
    // List handlers read their query from req.url.
    const req = Object.assign(makeRequest(body), { url: path });
    await routes({ method, path: url.pathname, url, req: req as never, res: res as never });
    return { status: res.statusCode, body: JSON.parse(res.body) as Record<string, unknown> };
  }

  it("starts durable only on request, binds on the first prompt, and its child stays durable", async () => {
    const f = await fixture(
      model(({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK scout", name: "Scout", wait: true });
        return fauxAssistantMessage("CHILD_ANSWER");
      }),
    );
    const created = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
      prompt: "Delegate the scouting",
      engine: "durable",
    });
    expect(created.status).toBe(201);
    const sessionId = (created.body.session as Session).id;
    const conversation = conversationOf(f.storage, sessionId);
    expect(conversation).toBeDefined();
    const harness = await f.openStore(sessionId);
    await until(
      async () =>
        (await toolResults(harness, conversation)).length === 1 &&
        (await harness.snapshot(LiveDoc, conversation, context))?.run === undefined,
      "the durable parent finishing its spawn",
    );
    expect(await userTexts(harness, conversation)).toEqual(["Delegate the scouting"]);

    const child = f.storage
      .listSessions()
      .find((session) => session.launch?.parentSessionId === sessionId)!;
    expect(conversationOf(f.storage, child)).toBeDefined();

    // Every summary the app reads names the engine: thread rows and workspace list rows.
    const thread = await getThread(f, sessionId);
    expect(thread.sessions.map((session) => [session.id, session.engine]).sort()).toEqual(
      [
        [sessionId, "durable"],
        [child.id, "durable"],
      ].sort(),
    );
    const list = await route(f, "GET", `/workspaces/${f.workspace.id}/sessions?status=active`);
    const rows = list.body.active as Array<{ id: string; engine?: string }>;
    expect(rows.find((row) => row.id === sessionId)?.engine).toBe("durable");
    expect(rows.find((row) => row.id === child.id)?.engine).toBe("durable");

    // Stopped rows come from the SQLite projection, not the live runtime.
    await f.manager.stopSession(sessionId);
    const stopped = await route(
      f,
      "GET",
      `/workspaces/${f.workspace.id}/sessions?status=stopped&sinceMs=0&untilMs=${Date.now() + 60_000}`,
    );
    const stoppedRows = stopped.body.stopped as Array<{ id: string; engine?: string }>;
    expect(stoppedRows.find((row) => row.id === sessionId)?.engine).toBe("durable");
  });

  it("launches a saved Agent durable through the one resolver, and records it in meta.json", async () => {
    const f = await fixture(model(() => fauxAssistantMessage("AGENT_ANSWER")));
    const agents = f.storage.getAgentDefinitionStore();
    const agent = agents.createAgent({
      name: "Scout",
      instructions: { mode: "append", text: "SCOUT_RULES" },
      sessionDefaults: { model: "faux/faux-2", excludeTools: ["bash"] },
    });
    const created = await route(f, "POST", `/agents/${agent.id}/sessions`, {
      prompt: { text: "Scout around" },
      target: { workspaceId: f.workspace.id },
      engine: "durable",
    });
    expect(created.status).toBe(201);
    const sessionId = (created.body.session as Session).id;
    const conversation = conversationOf(f.storage, sessionId);
    const harness = await f.openStore(sessionId);
    await until(
      async () => (await userTexts(harness, conversation)).includes("Scout around"),
      "the agent's first prompt",
    );
    const stored = await harness.snapshot(AgentDoc, conversation, context);
    expect(stored?.model).toEqual({ provider: "faux", modelId: "faux-2" });
    expect(stored?.tools).toContain("subagent");
    expect(stored?.tools).not.toContain("bash");
    expect(stored?.instructions).toMatch(/^You are an expert coding assistant[^]*SCOUT_RULES$/);
    expect(await harness.snapshot(OppiAgentDoc, conversation, context)).toMatchObject({
      agent: { id: agent.id, version: 1, name: "Scout" },
      spawn: true,
      grant: false,
      tools: { excluded: ["bash"] },
    });
    const meta = JSON.parse(
      readFileSync(join(durableStoreDir(f.dir, sessionId), "meta.json"), "utf8"),
    ) as { agent?: unknown };
    expect(meta.agent).toEqual({ id: agent.id, version: 1 });

    // A selection the durable engine cannot honor fails closed before a session exists.
    const plugged = agents.createAgent({
      name: "Plugged",
      resources: { extensionIds: ["extension_missing"] },
    });
    const before = f.storage.listSessions().length;
    const refused = await route(f, "POST", `/agents/${plugged.id}/sessions`, {
      prompt: { text: "Never runs" },
      target: { workspaceId: f.workspace.id },
      engine: "durable",
    });
    expect(refused.status).toBe(422);
    expect(refused.body).toMatchObject({
      code: "agent_extensions_unavailable",
      recovery: { unavailableExtensions: ["extension_missing"] },
    });
    expect(f.storage.listSessions()).toHaveLength(before);
  });

  it("runs a durable new-session schedule as its saved Agent", async () => {
    const f = await fixture(model(() => fauxAssistantMessage("SCHEDULED_ANSWER")));
    const agent = f.storage.getAgentDefinitionStore().createAgent({
      name: "Nightly",
      instructions: { mode: "replace", text: "NIGHTLY_PROMPT" },
    });
    const hooks = createAgentScheduleDispatchHooks(
      {
        storage: f.storage,
        sessions: f.manager,
        ensureSessionContextWindow: (session) => session,
      },
      "test-runner",
    );
    const result = (await hooks.launchNewSession({
      run: { id: "run-1", idempotencyKey: "schedule-run-1", slotKey: "slot-1" },
      schedule: { id: "schedule-1" },
      action: {
        type: "new_session",
        workspaceId: f.workspace.id,
        prompt: "Nightly check",
        agentId: agent.id,
        engine: "durable",
      },
    } as unknown as NewSessionDispatchInput)) as { sessionId: string };
    const conversation = conversationOf(f.storage, result.sessionId);
    expect(conversation).toBeDefined();
    const harness = await f.openStore(result.sessionId);
    const stored = await harness.snapshot(AgentDoc, conversation, context);
    expect(stored?.instructions?.startsWith("NIGHTLY_PROMPT\n\nWorking directory: ")).toBe(true);
    expect(await harness.snapshot(OppiAgentDoc, conversation, context)).toMatchObject({
      agent: { id: agent.id, version: 1, name: "Nightly" },
      projectContext: false,
    });
    expect(f.storage.getSession(result.sessionId)?.launch).toMatchObject({
      source: "schedule",
      agentId: agent.id,
    });
  });

  it("keeps an omitted or classic engine classic while durable is available", async () => {
    const f = await fixture([]);
    for (const engine of [undefined, "classic"]) {
      const created = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
        name: `Classic ${engine ?? "omitted"}`,
        ...(engine ? { engine } : {}),
      });
      expect(created.status).toBe(201);
      const session = f.storage.getSession((created.body.session as Session).id)!;
      expect(session.serverDurable).toBeUndefined();
    }
    const list = await route(f, "GET", `/workspaces/${f.workspace.id}/sessions?status=active`);
    const rows = list.body.active as Array<{ name?: string; engine?: string }>;
    expect(rows.filter((row) => row.name?.startsWith("Classic"))).toHaveLength(2);
    expect(rows.filter((row) => row.name?.startsWith("Classic") && row.engine)).toEqual([]);
    expect((await route(f, "GET", "/server/info")).body.capabilities).toMatchObject({
      durableSessions: { version: 1 },
    });
  });

  it("rejects a durable request while durable sessions are off, and says so in server info", async () => {
    const f = await fixture([], { serverDurable: false });
    const before = f.storage.listSessions().length;
    const created = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
      prompt: "Should not start",
      engine: "durable",
    });
    expect(created.status).toBe(409);
    expect(created.body.error).toContain("experimental.serverDurable");
    expect(f.storage.listSessions()).toHaveLength(before);
    const invalid = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
      engine: "fast",
    });
    expect(invalid.status).toBe(400);
    const info = await route(f, "GET", "/server/info");
    expect(info.body.capabilities).not.toHaveProperty("durableSessions");
  });

  it("refuses durable requests the durable engine cannot run, before saving a session", async () => {
    const f = await fixture([]);
    const before = f.storage.listSessions().length;

    const incognito = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
      prompt: "Should not start",
      engine: "durable",
      ephemeral: true,
    });
    expect(incognito.status).toBe(400);
    expect(incognito.body.error).toContain("Incognito sessions");
    expect(f.storage.listSessions()).toHaveLength(before);

    // The same requests stay valid on the classic engine.
    const classic = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
      ephemeral: true,
    });
    expect(classic.status).toBe(201);
  });

  it("refuses an idempotent replay that asks for the other engine", async () => {
    const f = await fixture([]);
    const create = (launchIdempotencyKey: string, engine?: string) =>
      route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
        launchIdempotencyKey,
        ...(engine ? { engine } : {}),
      });

    expect((await create("durable-key", "durable")).status).toBe(201);
    expect((await create("durable-key", "durable")).status).toBe(200);
    const classicReplay = await create("durable-key");
    expect(classicReplay.status).toBe(409);
    expect(classicReplay.body.error).toContain("different engine");

    expect((await create("classic-key", "classic")).status).toBe(201);
    expect((await create("classic-key")).status).toBe(200);
    const durableReplay = await create("classic-key", "durable");
    expect(durableReplay.status).toBe(409);
    expect(durableReplay.body.error).toContain("different engine");
  });
});

describe("subagent stop replay", () => {
  it("does not abort again when a crash came after the stop decided to abort", async () => {
    const memos = new Map<string, unknown>();
    let aborts = 0;
    const child = { conversationId: 7 as ConversationId, sessionId: "child", background: true };
    // The tool against a minimal call API whose memos survive a rerun, as the Harness keeps them.
    const api = {
      conversationId: 1 as ConversationId,
      snapshot: async () => ({ children: { Worker: child }, calls: {} }),
      conversation: async () => ({
        abort: async () => {
          aborts += 1;
          // The process dies once the abort has reached the child, before the call returns.
          if (aborts === 1) throw new Error("crash after abort");
        },
      }),
      memo: async (name: string, ...rest: unknown[]) => {
        if (rest.length === 1) return memos.get(name);
        if (!memos.has(name)) memos.set(name, rest[0]);
        return memos.get(name);
      },
    } as unknown as ToolExecutionApi;
    const [subagent] = createDurableSessions(() => undefined).tools!;
    const stop = () => subagent!.execute({ action: "stop", name: "Worker" }, api, context);

    await expect(stop()).rejects.toThrow("crash after abort");
    // The rerun reports the stop without aborting the child's newer work.
    expect(await stop()).toMatchObject({ details: { name: "Worker", sessionId: "child" } });
    expect(aborts).toBe(1);
  });
});

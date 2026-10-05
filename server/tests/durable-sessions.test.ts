import { mkdtempSync } from "node:fs";
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
import { LiveDoc, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import { DurableHarness, DurableRuntime } from "../src/durable-harness.js";
import { SessionManager } from "../src/sessions.js";
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

const spawnCall = (args: Record<string, unknown>) =>
  fauxAssistantMessage([fauxToolCall("session_spawn", args)], { stopReason: "toolUse" });
const toolCall = (name: string, args: Record<string, unknown>) =>
  fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });

async function fixture(responses: FauxResponseStep[], options?: { serverDurable?: boolean }) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-sessions-test-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
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
  const opening = vi.spyOn(DurableHarness.prototype, "open");
  const storage = new Storage(dir);
  storage.updateConfig({ experimental: { serverDurable: options?.serverDurable ?? true } });
  const workspace = storage.createWorkspace({ name: "Durable threads", hostMount: dir });
  const session = (name: string) => {
    const created = storage.createSession(name, "faux/faux-1");
    created.serverDurable = {};
    created.workspaceId = workspace.id;
    storage.saveSession(created);
    return created;
  };
  const parent = session("Parent");
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  return {
    dir,
    storage,
    workspace,
    manager,
    parent,
    session,
    /** The open Harness; after a simulated restart, the newest one. */
    harness: async (): Promise<Harness> => (await opening.mock.results.at(-1)!.value).harness,
    /** The newest Harness owner. */
    owner: () => opening.mock.contexts.at(-1) as DurableHarness,
    /** Oppi's thread host bound to the newest Harness owner. */
    threads: () => (opening.mock.contexts.at(-1) as DurableHarness).boundThreads!,
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
function requestIds(dir: string, id: ConversationId, prefix: string): string[] {
  const db = new DatabaseSync(join(dir, "durable", "harness.sqlite"), { readOnly: true });
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
          return spawnCall({ task: "CHILD_TASK scout", name: "Scout" });
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
      toolName: "session_spawn",
      text: "CHILD_ANSWER",
      details: { conversationId: childConversation, sessionId: child.id },
    });
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeUndefined();
  });

  it("aborts a foreground child with its parent's Stop", async () => {
    const childGate = gate();
    let childStarted!: () => void;
    const started = new Promise<void>((resolve) => (childStarted = resolve));
    const f = await fixture(
      model(async ({ text, signal }) => {
        if (text.includes("Delegate")) return spawnCall({ task: "CHILD_TASK park" });
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
          return spawnCall({ task: "CHILD_TASK later", name: "Later", background: true });
        await childGate.wait(signal);
        return fauxAssistantMessage("BACKGROUND_ANSWER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const parentEnd = observe(f.manager, f.parent.id).next(
      (message) => message.type === "agent_end",
    );
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
          return spawnCall({ task: "CHILD_TASK later", background: true });
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

  it("resumes a running child after a restart because its Session keeps it in resumeIds", async () => {
    let childCalls = 0;
    const firstCall = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK long", background: true });
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
    expect(requestIds(f.dir, childConversation, "oppi-spawn:")).toHaveLength(1);
    expect(requestIds(f.dir, parentConversation, "oppi-report:")).toHaveLength(1);
    expect(
      (await userTexts(harness, parentConversation)).filter((text) =>
        text.includes("finished, no reply needed"),
      ),
    ).toHaveLength(1);
  });

  it("lets a session abort only children it spawned", async () => {
    const childGate = gate();
    const state: { childSession?: string } = {};
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ task: "CHILD_TASK work", background: true });
        if (text.includes("Stranger abort"))
          return toolCall("session_abort", { sessionId: state.childSession });
        if (text.includes("Owner abort"))
          return toolCall("session_abort", { sessionId: state.childSession });
        if (text.includes("CHILD_TASK")) {
          await childGate.wait(signal);
          return fauxAssistantMessage("CHILD_DONE");
        }
        return fauxAssistantMessage("OTHER");
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
    state.childSession = child.id;
    const childConversation = conversationOf(f.storage, child);
    const strangerConversation = conversationOf(f.storage, stranger);
    await until(
      async () => (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
      "parent idle",
    );

    // A session that did not spawn the child cannot stop it.
    await f.manager.sendPrompt(stranger.id, "Stranger abort");
    await until(
      async () => (await toolResults(harness, strangerConversation)).length === 1,
      "refusal",
    );
    expect((await toolResults(harness, strangerConversation))[0]).toMatchObject({
      toolName: "session_abort",
      isError: true,
    });
    expect((await toolResults(harness, strangerConversation))[0]!.text).toContain(
      "not one of your children",
    );
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();

    // The spawning parent can.
    await f.manager.sendPrompt(f.parent.id, "Owner abort it");
    await until(async () => (await toolResults(harness, parentConversation)).length === 2, "abort");
    expect((await toolResults(harness, parentConversation))[1]).toMatchObject({
      toolName: "session_abort",
      text: `Stopped session ${child.id}.`,
    });
    expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeUndefined();
  });

  it("records the oppi-send request id when a session messages another, and reserves the prefix", async () => {
    const state: { childSession?: string } = {};
    const f = await fixture(
      model(async ({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn"))
          return spawnCall({ task: "CHILD_TASK quick", background: true });
        if (text.includes("Message it"))
          return toolCall("session_send", {
            sessionId: state.childSession,
            text: "HELLO_CHILD",
            mode: "followUp",
          });
        if (text.includes("Wait for it"))
          return toolCall("session_wait", { sessionIds: [state.childSession] });
        return fauxAssistantMessage("CHILD_REPLY");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "spawn");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    state.childSession = child.id;
    const childConversation = conversationOf(f.storage, child);

    await f.manager.sendPrompt(f.parent.id, "Message it now");
    await until(async () => (await toolResults(harness, parentConversation)).length === 2, "send");
    const sent = (await toolResults(harness, parentConversation))[1]!;
    expect(sent.toolName).toBe("session_send");
    expect(sent.details?.requestId).toMatch(/^oppi-send:\d+$/);
    const receipt = await harness.commit(
      (tx) => tx.submissionByRequest(childConversation, sent.details!.requestId as string),
      context,
    );
    expect(receipt?.type).toBe("input");
    expect(requestIds(f.dir, childConversation, "oppi-send:")).toEqual([sent.details!.requestId]);
    expect(await userTexts(harness, childConversation)).toContain("HELLO_CHILD");

    await f.manager.sendPrompt(f.parent.id, "Wait for it please");
    await until(async () => (await toolResults(harness, parentConversation)).length === 3, "wait");
    expect((await toolResults(harness, parentConversation))[2]).toMatchObject({
      toolName: "session_wait",
      text: `Idle: ${child.id}.`,
    });

    // Clients cannot occupy the namespace.
    await expect(
      f.manager.sendPrompt(child.id, "spoof", { clientTurnId: "oppi-send:1" }),
    ).rejects.toThrow("reserved durable requestId namespace");
  });

  it("reruns a foreground spawn after a restart against the same child and Session", async () => {
    let childCalls = 0;
    const firstCall = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK foreground", name: "Fg" });
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

  it("refuses a nested spawn: the child's call errors and no third session appears", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ task: "CHILD_TASK work", background: true });
        await childGate.wait(signal);
        return spawnCall({ task: "grandchild" });
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "spawn");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);

    // Now the child really calls session_spawn.
    childGate.open();
    await until(
      async () => (await toolResults(harness, childConversation)).length === 1,
      "refusal",
    );
    expect((await toolResults(harness, childConversation))[0]).toMatchObject({
      toolName: "session_spawn",
      isError: true,
      text: expect.stringContaining("Child sessions cannot spawn sessions."),
    });
    expect(
      f.storage
        .listSessions()
        .map((session) => session.id)
        .sort(),
    ).toEqual([f.parent.id, child.id].sort());
    const grandchildren = await harness.commit(
      (tx) => tx.scanConversations({ ownerConversationId: childConversation }, 10),
      context,
    );
    expect(grandchildren.items).toHaveLength(0);
  });

  it("keeps a sandbox session from prompting host sessions or another workspace's sandbox", async () => {
    const state: { host?: string; same?: string; other?: string } = {};
    const f = await fixture(
      model(async ({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        const send = (sessionId?: string) =>
          toolCall("session_send", { sessionId, text: "ATTACK", mode: "followUp" });
        if (text.includes("Send host")) return send(state.host);
        if (text.includes("Wait host"))
          return toolCall("session_wait", { sessionIds: [state.host] });
        if (text.includes("Send other")) return send(state.other);
        if (text.includes("Send same")) return send(state.same);
        return fauxAssistantMessage("OK");
      }),
    );
    const otherWorkspace = f.storage.createWorkspace({ name: "Elsewhere", hostMount: f.dir });
    const host = f.session("Host target");
    const same = f.session("Same sandbox");
    const other = f.session("Other sandbox");
    other.workspaceId = otherWorkspace.id;
    f.storage.saveSession(other);
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.startSession(host.id, f.workspace);
    await f.manager.startSession(same.id, f.workspace);
    await f.manager.startSession(other.id, otherWorkspace);
    // Detached host target: reaching it would have to attach it first.
    await f.manager.stopSession(host.id);
    expect(f.manager.isActive(host.id)).toBe(false);
    Object.assign(state, { host: host.id, same: same.id, other: other.id });

    const harness = await f.harness();
    // Mark the conversation as a sandbox one, with a stand-in guest env the harness will accept.
    const sandbox = async (session: Session, workspaceId: string) => {
      const id = conversationOf(f.storage, session);
      await harness.commit(async (tx) => {
        const runtime = await tx.doc(DurableRuntime, id);
        runtime.kind = "sandbox";
        runtime.workspaceId = workspaceId;
      }, context);
      f.owner().bindSandboxEnv(id, new NodeExecutionEnv({ cwd: f.dir }));
    };
    await sandbox(f.parent, f.workspace.id);
    await sandbox(same, f.workspace.id);
    await sandbox(other, otherWorkspace.id);

    const parentConversation = conversationOf(f.storage, f.parent);
    let results = 0;
    const call = async (prompt: string) => {
      await f.manager.sendPrompt(f.parent.id, prompt);
      results += 1;
      await until(
        async () => (await toolResults(harness, parentConversation)).length === results,
        prompt,
      );
      await until(
        async () =>
          (await harness.snapshot(LiveDoc, parentConversation, context))?.run === undefined,
        "parent idle",
      );
    };
    await call("Send host");
    await call("Wait host");
    await call("Send other");
    await call("Send same");

    const [sendHost, waitHost, sendOther, sendSame] = await toolResults(
      harness,
      parentConversation,
    );
    for (const refused of [sendHost, waitHost, sendOther])
      expect(refused).toMatchObject({ isError: true, text: expect.stringContaining("sandbox") });
    expect(sendSame?.isError).toBeFalsy();

    // Nothing reached the host session: not attached, nothing submitted.
    expect(f.manager.isActive(host.id)).toBe(false);
    expect(requestIds(f.dir, conversationOf(f.storage, host), "oppi-send:")).toEqual([]);
    expect(await userTexts(harness, conversationOf(f.storage, host))).not.toContain("ATTACK");
    expect(requestIds(f.dir, conversationOf(f.storage, other), "oppi-send:")).toEqual([]);
    // The same sandbox workspace stays reachable.
    expect(requestIds(f.dir, conversationOf(f.storage, same), "oppi-send:")).toHaveLength(1);
  });

  it("does not start new host turns from a background report once its parent is stopped", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK later", background: true });
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

    expect(requestIds(f.dir, parentConversation, "oppi-report:")).toEqual([]);
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
        if (text.includes("Spawn")) return spawnCall({ task: "CHILD_TASK work", background: true });
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
    // The row holding the child's key is now one a client made: it points elsewhere, or nowhere.
    for (const serverDurable of [
      { conversationId: conversationOf(f.storage, stranger) },
      undefined,
    ]) {
      f.storage.saveSession({ ...child, serverDurable });
      await expect(
        f.threads().materialize({ conversationId: childConversation, name: "Again" }),
      ).rejects.toThrow(/not bound to the child conversation/);
    }
    expect(f.storage.listSessions()).toHaveLength(3);
    f.storage.saveSession(child);
    await expect(
      f.threads().materialize({ conversationId: childConversation, name: "Again" }),
    ).resolves.toBe(child.id);
  });

  it("keeps the surviving children in one thread after their parent's Session is deleted", async () => {
    const childGate = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn one"))
          return spawnCall({ task: "CHILD_TASK one", background: true });
        if (text.includes("Spawn two"))
          return spawnCall({ task: "CHILD_TASK two", background: true });
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
          return spawnCall({ task: "CHILD_TASK scout", name: "Scout" });
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
    const harness = await f.harness();
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
    const sandbox = f.storage.createWorkspace({
      name: "Sandbox with MCP",
      hostMount: f.dir,
      runtime: "sandbox",
      sandboxConfig: { mcpServers: ["github"] },
    });
    const before = f.storage.listSessions().length;

    const incognito = await route(f, "POST", `/workspaces/${f.workspace.id}/sessions`, {
      prompt: "Should not start",
      engine: "durable",
      ephemeral: true,
    });
    expect(incognito.status).toBe(400);
    expect(incognito.body.error).toContain("Incognito sessions");
    const mcp = await route(f, "POST", `/workspaces/${sandbox.id}/sessions`, {
      prompt: "Should not start",
      engine: "durable",
    });
    expect(mcp.status).toBe(400);
    expect(mcp.body.error).toContain("Sandbox MCP servers");
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

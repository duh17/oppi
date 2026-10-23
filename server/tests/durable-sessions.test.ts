import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
  type TaskId,
  type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { createDurableSessions } from "../extensions/durable/sessions/durable.js";
import {
  SUBAGENT_WIDGET_TASK,
  Subagents,
  ensureSubagentWidget,
} from "../extensions/durable/sessions/contract.js";
import { DurableJobs } from "../extensions/durable/background-jobs/contract.js";
import { ACTIVITY_INTERVAL_MS, WAITING_ACTIVITY } from "../extensions/durable/sessions/widget.js";
import { DurableUI } from "../extensions/durable/durable-ui.js";
import { OppiAgentDoc } from "../src/durable-agent.js";
import { createWorkspaceWorktree, listWorkspaceWorktrees } from "../src/worktrees.js";
import {
  DurableHarness,
  DurableRuntime,
  SessionHost,
  durableStoreDir,
  durableStoreSqlitePath,
} from "../src/durable-harness.js";
import { ProjectContextDoc } from "../extensions/durable/project-context/contract.js";
import { AgentLaunchService, DelegationPolicyError } from "../src/agent-launch-service.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { createAgentScheduleDispatchHooks } from "../src/agent-schedule-dispatch.js";
import type { NewSessionDispatchInput } from "../src/agent-schedules.js";
import { SessionManager } from "../src/sessions.js";
import { durableStoreId } from "../src/session-runtime-capabilities.js";
import { SessionRuntimes } from "../src/runtime-router.js";
import { readDurableTrace } from "../src/durable-history.js";
import { serverResourceId } from "../src/server-resource-id.js";
import { Storage } from "../src/storage.js";
import { recordLiveSessionsForRestart } from "../src/session-restart-resume.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { ServerMessage, Session, SessionThreadResponse } from "../src/types.js";
import {
  makeRequest,
  makeResponse,
  makeUnconfiguredVoiceBackendHealth,
} from "./harness/route-test-helpers.js";

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

/** Run git in `cwd` for a test fixture's repo, as the worktree tests do. */
function gitIn(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

async function fixture(
  responses: FauxResponseStep[],
  options?: { serverDurable?: boolean; tokensPerSecond?: number; git?: boolean },
) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-sessions-test-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider({
    models: [{ id: "faux-1" }, { id: "faux-2" }],
    ...(options?.tokensPerSecond ? { tokensPerSecond: options.tokensPerSecond } : {}),
  });
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
  // A git workspace: its own checkout inside the data dir, so the worktrees Oppi manages
  // (`<dataDir>/worktrees/...`) stay outside the repo.
  const repo = join(dir, "repo");
  if (options?.git) {
    mkdirSync(repo, { recursive: true });
    gitIn(repo, ["init", "--initial-branch=main"]);
    gitIn(repo, ["config", "user.email", "oppi-test@example.invalid"]);
    gitIn(repo, ["config", "user.name", "Oppi Test"]);
    writeFileSync(join(repo, "README.md"), "main checkout\n");
    gitIn(repo, ["add", "README.md"]);
    gitIn(repo, ["commit", "-m", "initial"]);
  }
  const storage = new Storage(dir);
  storage.updateConfig({ experimental: { serverDurable: options?.serverDurable ?? true } });
  const workspace = storage.createWorkspace({
    name: "Durable threads",
    hostMount: options?.git ? repo : dir,
  });
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
    repo,
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
/** The children's reports a parent received, oldest first, as the model reads them. */
const reports = async (harness: Harness, id: ConversationId): Promise<string[]> =>
  (await userTexts(harness, id)).filter((text) => text.includes("finished, no reply needed"));

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
    // The reporter attaches the child, then delivers the task, which parks on the gate.
    await until(
      async () => (await harness.snapshot(LiveDoc, childConversation, context))?.run !== undefined,
      "the child working",
    );
    expect((await harness.snapshot(LiveDoc, parentConversation, context))?.run).toBeUndefined();
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
    // The child stopped once it answered; the phone opens it from its row and messages it.
    expect(f.storage.getSession(child.id)?.status).toBe("stopped");
    await f.manager.startSession(child.id, f.workspace);
    await f.manager.sendPrompt(child.id, "Once more");
    await until(
      async () => (await row())?.state === "running",
      "the new watcher follows the child",
    );
    againGate.open();
    await until(async () => (await row())?.state === "success", "done again");
  });

  it("shows what a working child does in its pill row, writing a new activity at most every two seconds", async () => {
    let gatePath = "";
    // About six seconds at 40 tokens a second: several activity intervals.
    const answer = Array.from({ length: 60 }, (_, index) => `progress line ${index + 1}`).join(
      "\n",
    );
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult" && last.toolName === "bash")
          return fauxAssistantMessage(answer);
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK activity", name: "Busy" });
        return toolCall("bash", {
          command: `for i in $(seq 1 400); do [ -f '${gatePath}' ] && break; echo waiting $i; sleep 0.05; done`,
        });
      }),
      { tokensPerSecond: 40 },
    );
    gatePath = join(f.dir, "activity-gate");
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate in the background");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(() => f.storage.listSessions().length === 2, "the child session");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    const row = async () =>
      (
        (await harness.snapshot(DurableUI, parentConversation, context))?.notifications[
          "widget:subagents"
        ]?.nativeSurface as { blocks: Array<{ rows: Array<Record<string, unknown>> }> } | undefined
      )?.blocks[0]?.rows[0];

    // A running tool: its name, after the context use of an answer the row has read, if any.
    // Its output streams without a write, as the activity holds.
    const activity = async () =>
      /(?:^|\u00b7 )([^\u00b7]+)$/.exec(String((await row())?.detail))?.[1];
    await until(async () => (await activity()) === "Running bash", "the running tool");

    // Streamed text: its last line, in writes at least the interval apart.
    const widgetWrites: number[] = [];
    let liveChanges = 0;
    let lastWidget: string | undefined;
    const unsubscribe = harness.subscribeCommits((publication) => {
      for (const change of publication.changes) {
        if (change.type !== "document" || change.record.key !== undefined) continue;
        if (
          change.conversationId === childConversation &&
          change.record.kind === LiveDoc.definition.kind
        )
          liveChanges += 1;
        if (
          change.conversationId !== parentConversation ||
          change.record.kind !== DurableUI.definition.kind
        )
          continue;
        const widget = JSON.stringify(
          (change.value as { notifications?: Record<string, unknown> } | undefined)
            ?.notifications?.["widget:subagents"],
        );
        if (widget !== lastWidget) widgetWrites.push(Date.now());
        lastWidget = widget;
      }
    });
    writeFileSync(gatePath, "");
    // A write takes the partial as it is, so the line can be cut mid-word ("progress li").
    const lines = answer.split("\n");
    await until(async () => {
      const shown = await activity();
      return !!shown && shown !== "Running bash" && lines.some((line) => line.startsWith(shown));
    }, "a line of the streaming answer");
    await until(async () => (await row())?.state === "success", "a done row");
    unsubscribe();
    // Idle: no activity, only the answer's context use.
    expect((await row())?.detail).toMatch(/^\d+%$/);
    // The answer streamed through many `pi.live` commits; the row followed in a few writes.
    expect(liveChanges).toBeGreaterThan(10);
    const gaps = widgetWrites.slice(1).map((at, index) => at - widgetWrites[index]!);
    // Every write but the last (Done, the busy edge) waited out the interval. Passes are spaced
    // from their start, so a slower commit before a faster one shortens the gap between commits
    // a little; per-delta writes would be 100 ms apart.
    expect(widgetWrites.length).toBeGreaterThanOrEqual(3);
    for (const gap of gaps.slice(0, -1))
      expect(gap).toBeGreaterThanOrEqual(ACTIVITY_INTERVAL_MS - 500);
  }, 30_000);

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

  it("keeps a child whose Session was deleted in a reattached pill, in list, and in wait", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn gone"))
          return spawnCall({ task: "CHILD_TASK gone", name: "Gone" });
        if (text.includes("Spawn kept"))
          return spawnCall({ task: "CHILD_TASK kept", name: "Kept" });
        if (text.includes("List them")) return subagentCall("list");
        if (text.includes("Wait for Gone")) return subagentCall("wait", { names: ["Gone"] });
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const ask = async (prompt: string, results: number) => {
      await f.manager.sendPrompt(f.parent.id, prompt);
      await until(
        async () => (await toolResults(harness, parentConversation)).length === results,
        prompt,
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
      return (await toolResults(harness, parentConversation))[results - 1]!;
    };
    const rows = async () =>
      (
        (await harness.snapshot(DurableUI, parentConversation, context))?.notifications[
          "widget:subagents"
        ]?.nativeSurface as { blocks: Array<{ rows: Array<{ title: string }> }> } | undefined
      )?.blocks[0]?.rows.map((row) => row.title);
    await ask("Spawn gone", 1);
    await until(async () => (await reports(harness, parentConversation)).length === 1, "report");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    const gone = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    await until(() => f.storage.getSession(gone.id)?.status === "stopped", "the child stopping");
    f.storage.deleteSession(gone.id);

    // A new watcher sees the child for the first time, with no Session behind it.
    const widgetTask = async () =>
      (await harness.snapshot(Subagents, parentConversation, context))?.widget;
    const retired = await widgetTask();
    await harness.abortTask(retired!, context);
    await f.manager.stopSession(f.parent.id);
    await f.manager.startSession(f.parent.id, f.workspace);
    await until(async () => (await widgetTask()) !== retired, "a new watcher");
    await ask("Spawn kept", 2);
    await until(async () => (await rows())?.length === 2, "both rows");
    expect(await rows()).toEqual(["Gone", "Kept"]);

    const list = await ask("List them", 3);
    expect(list.isError).toBeFalsy();
    expect(list.text).toContain("Gone | idle |");
    expect(list.text).toContain(`session: ${gone.id}`);
    // wait reports the missing Session in Gone's own line instead of failing the call.
    const waited = await ask("Wait for Gone", 4);
    expect(waited.text).toMatch(new RegExp(`^Gone: Session ${gone.id}`));
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

    // Stopped, not removed: its transcript stays and it takes new work, whose answer comes back.
    expect((await call("Ask again")).text).toMatch(/^Sent to Worker \(steer\)\./);
    await until(async () => (await reports(harness, parentConversation)).length === 1, "report");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
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
    // The stopped task has no report; the message after it has one.
    expect(await reports(harness, parentConversation)).toEqual([
      `[session Worker (${child.id}) finished, no reply needed] SECOND_ANSWER`,
    ]);
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
    await until(async () => (await reports(harness, parentConversation)).length === 1, "report");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

    await f.manager.sendPrompt(f.parent.id, "Message it now");
    await until(async () => (await toolResults(harness, parentConversation)).length === 2, "send");
    const sent = (await toolResults(harness, parentConversation))[1]!;
    expect(sent.text).toMatch(/^Sent to Quick \(followUp\)\./);
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
    // Spawn and send each report their answer.
    await until(async () => (await reports(harness, parentConversation)).length === 2, "reports");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

    await f.manager.sendPrompt(f.parent.id, "Wait for it please");
    await until(async () => (await toolResults(harness, parentConversation)).length === 3, "wait");
    expect((await toolResults(harness, parentConversation))[2]).toMatchObject({
      toolName: "subagent",
      text: "Quick: CHILD_REPLY",
    });

    // Clients cannot occupy the namespace.
    await f.manager.startSession(child.id, f.workspace);
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

  it("reruns a worktree spawn after a restart into one child and one worktree", async () => {
    let childCalls = 0;
    const firstCall = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (toolName === "bash") return fauxAssistantMessage("TREE_RESUMED");
        if (text.includes("Delegate"))
          return spawnCall({ name: "Tree", task: "TREE_TASK", worktree: "new", wait: true });
        childCalls += 1;
        if (childCalls === 1) {
          await firstCall.wait(signal);
          throw new Error("interrupted by shutdown");
        }
        // A file the worktree keeps, so it survives the end of the child and can be counted.
        return toolCall("bash", { command: "printf 'kept\\n' > resume.txt" });
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate it");
    await until(() => childCalls === 1, "the child's first model call");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const parentConversation = conversationOf(f.storage, f.parent);
    expect(child.worktreeId).toMatch(/^wt_/);

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
      text: expect.stringContaining("TREE_RESUMED"),
      details: { sessionId: child.id },
    });
    // One child, one Session, one worktree: the rerun found the child instead of branching again.
    expect(reopened.listSessions().filter((session) => session.id !== f.parent.id)).toHaveLength(1);
    const worktrees = await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir });
    expect(worktrees.map((tree) => tree.id)).toEqual(["main", child.worktreeId]);
    expect(existsSync(join(worktrees[1]!.path, "resume.txt"))).toBe(true);
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

  it("runs a worktree child in its own checkout and leaves the parent's clean", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "bash") return fauxAssistantMessage("WORKER_DONE");
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Delegate"))
          return spawnCall({ name: "Worker", task: "WORK_COMMIT", worktree: "new", wait: true });
        return toolCall("bash", {
          command:
            "pwd && printf 'work\\n' > work.txt && git add work.txt && " +
            "git commit -qm work && git rev-parse --short HEAD",
        });
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate it");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "spawn");
    const [result] = await toolResults(harness, parentConversation);
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    const worktreeId = child.worktreeId!;
    expect(worktreeId).toMatch(/^wt_/);
    expect(child.launch?.target?.worktreeId).toBe(worktreeId);
    const worktree = (await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir })).find(
      (candidate) => candidate.id === worktreeId,
    )!;
    expect(worktree.branch).toBe("subagent/worker");
    expect(worktree.path).toContain(join("worktrees", f.workspace.id));
    // The child ran in the worktree: its bash `pwd` is there, and the file it committed is not
    // in the parent's checkout.
    expect((await toolResults(harness, childConversation))[0]!.text.trim().split("\n")[0]).toBe(
      worktree.path,
    );
    expect((await harness.snapshot(AgentDoc, childConversation, context))?.cwd).toBe(worktree.path);
    expect(existsSync(join(worktree.path, "work.txt"))).toBe(true);
    expect(existsSync(join(f.repo, "work.txt"))).toBe(false);
    expect(gitIn(f.repo, ["status", "--porcelain"])).toBe("");
    // Its answer reports the worktree, one commit past its base, clean, and it stays: a commit
    // is something to review or land.
    expect(result).toMatchObject({ toolName: "subagent" });
    expect(result!.text).toContain("WORKER_DONE");
    expect(result!.text).toContain(`worktree: ${worktree.branch} \u00b7 ${worktreeId}`);
    expect(result!.text).toContain("1 commit ahead");
    expect(result!.text).toContain("clean");
    expect(existsSync(worktree.path)).toBe(true);
    expect(gitIn(f.repo, ["branch", "--list", "subagent/worker"])).toContain("subagent/worker");
  });

  it("keeps a worktree child's checkout so a later message still runs there", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "bash") return fauxAssistantMessage("CHILD_OK");
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Spawn"))
          return spawnCall({ name: "Quiet", task: "QUIET_TASK", worktree: "new" });
        if (text.includes("Again"))
          return subagentCall("send", { name: "Quiet", message: "AGAIN_TASK" });
        if (text.includes("AGAIN_TASK")) return toolCall("bash", { command: "pwd" });
        return fauxAssistantMessage("CHILD_OK");
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await until(
      async () => (await reports(harness, parentConversation)).length === 1,
      "the child's report",
    );
    // Its first answer wrote nothing, and nothing takes the checkout away: the worktree and
    // the branch are still there for the correction that may follow.
    const quiet = f.storage.listSessions().find((session) => session.name === "Quiet")!;
    const worktree = (await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir })).find(
      (candidate) => candidate.id === quiet.worktreeId,
    )!;
    expect(worktree.branch).toBe("subagent/quiet");
    expect(existsSync(worktree.path)).toBe(true);
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

    await f.manager.sendPrompt(f.parent.id, "Again please");
    await until(
      async () =>
        (await userTexts(harness, parentConversation)).some((text) =>
          text.includes("could not start:"),
        ) === false && (await toolResults(harness, conversationOf(f.storage, quiet))).length === 1,
      "the follow-up run in the child's worktree",
    );
    // The correction ran in the same checkout, not in the parent's.
    expect((await toolResults(harness, conversationOf(f.storage, quiet)))[0]!.text.trim()).toBe(
      worktree.path,
    );
    expect(existsSync(worktree.path)).toBe(true);
    expect(gitIn(f.repo, ["status", "--porcelain"])).toBe("");
  });

  it("gives concurrent spawns of one name distinct worktrees", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Twins"))
          return fauxAssistantMessage(
            [
              fauxToolCall("subagent", {
                action: "spawn",
                name: "Twin",
                task: "TWIN_A",
                worktree: "new",
                wait: true,
              }),
              fauxToolCall("subagent", {
                action: "spawn",
                name: "twin",
                task: "TWIN_B",
                worktree: "new",
                wait: true,
              }),
            ],
            { stopReason: "toolUse" },
          );
        return fauxAssistantMessage("CHILD_OK");
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Twins, please");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 2,
      "both spawns",
    );
    const children = f.storage
      .listSessions()
      .filter((session) => session.id !== f.parent.id)
      .sort((lhs, rhs) => (lhs.name < rhs.name ? -1 : 1));
    // Both names slug to `subagent/twin`; each spawn holds its branch, so neither takes the
    // other's checkout.
    expect(children.map((session) => session.name)).toEqual(["Twin", "twin"]);
    expect(new Set(children.map((session) => session.worktreeId)).size).toBe(2);
    const worktrees = await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir });
    const branches = worktrees
      .filter((tree) => !tree.isMain)
      .map((tree) => tree.branch)
      .sort();
    expect(branches).toEqual(["subagent/twin", "subagent/twin-2"]);
    const paths: string[] = [];
    for (const session of children) {
      const worktree = worktrees.find((tree) => tree.id === session.worktreeId)!;
      expect(worktree.path).toContain(join("worktrees", f.workspace.id));
      // Each child was bound to its own checkout, not to the one the other spawn made.
      expect(
        (await harness.snapshot(AgentDoc, conversationOf(f.storage, session), context))?.cwd,
      ).toBe(worktree.path);
      paths.push(worktree.path);
    }
    expect(new Set(paths).size).toBe(2);
  });

  it("lists a worktree child's branch, commits ahead, and dirt", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "bash") return fauxAssistantMessage("CHILD_OK");
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Spawn"))
          return spawnCall({ name: "Dirty", task: "DIRTY_TASK", worktree: "new" });
        if (text.includes("Show them")) return subagentCall("list");
        if (text.includes("DIRTY_TASK")) return fauxAssistantMessage("CHILD_OK");
        return fauxAssistantMessage("PARENT_DONE");
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 1,
      "the child's report",
    );
    const child = f.storage.listSessions().find((session) => session.name === "Dirty")!;
    const worktree = (await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir })).find(
      (candidate) => candidate.id === child.worktreeId,
    )!;
    writeFileSync(join(worktree.path, "dirty.txt"), "x\n");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    await f.manager.sendPrompt(f.parent.id, "Show them");
    await until(async () => (await toolResults(harness, parentConversation)).length === 2, "list");
    const [listed] = (await toolResults(harness, parentConversation)).filter((result) =>
      result.text.includes("Dirty |"),
    );
    expect(listed!.text).toContain(`worktree: subagent/dirty \u00b7 ${worktree.id}`);
    expect(listed!.text).toContain("0 commits ahead");
    expect(listed!.text).toContain("dirty");
    expect(existsSync(worktree.path)).toBe(true);
  });

  it("narrows a child's tools and never widens them", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("RO_TASK") || text.includes("NARROW_TASK"))
          return fauxAssistantMessage("CHILD_OK");
        if (text.includes("Read only"))
          return spawnCall({ name: "Solo", task: "RO_TASK", readOnly: true, wait: true });
        if (text.includes("Narrow"))
          return spawnCall({
            name: "Narrow",
            task: "NARROW_TASK",
            tools: ["edit", "subagent", "not_a_tool"],
            excludeTools: ["write"],
            wait: true,
          });
        return fauxAssistantMessage("PARENT_DONE");
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const toolsOf = async (session: Session) =>
      (
        await (await harness.conversation(conversationOf(f.storage, session), context))!.agent(
          context,
        )
      ).tools
        .map((tool) => tool.name)
        .sort();
    await f.manager.sendPrompt(f.parent.id, "Read only please");
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "solo");
    const solo = f.storage.listSessions().find((session) => session.name === "Solo")!;
    expect(await toolsOf(solo)).toEqual(["bash", "read"]);
    // The task says what readOnly means, and that bash is not a sandbox.
    const [soloTask] = await userTexts(harness, conversationOf(f.storage, solo));
    expect(soloTask).toContain("[Read-only subagent:");
    expect(soloTask).toContain("not a sandbox");
    expect(soloTask).toContain("RO_TASK");
    // The parent keeps its own tools; a named tool it lacks is dropped, never added.
    expect(await toolsOf(f.parent)).toEqual(
      expect.arrayContaining(["read", "bash", "edit", "write"]),
    );
    await f.manager.sendPrompt(f.parent.id, "Narrow it");
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 2,
      "narrow",
    );
    const narrow = f.storage.listSessions().find((session) => session.name === "Narrow")!;
    expect(await toolsOf(narrow)).toEqual(["edit"]);
  });

  it("adopts a worktree by id and refuses another workspace's", async () => {
    const other = join(mkdtempSync(join(tmpdir(), "oppi-durable-other-ws-")), "repo");
    mkdirSync(other, { recursive: true });
    gitIn(other, ["init", "--initial-branch=main"]);
    gitIn(other, ["config", "user.email", "oppi-test@example.invalid"]);
    gitIn(other, ["config", "user.name", "Oppi Test"]);
    writeFileSync(join(other, "README.md"), "other\n");
    gitIn(other, ["add", "README.md"]);
    gitIn(other, ["commit", "-m", "initial"]);
    let adoptedId = "";
    let strangerId = "";
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "bash") return fauxAssistantMessage("REVIEWER_DONE");
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Review the worker"))
          return spawnCall({
            name: "Reviewer",
            task: "REVIEW_TASK",
            worktree: adoptedId,
            wait: true,
          });
        if (text.includes("Borrow the stranger"))
          return spawnCall({ name: "Stranger", task: "T", worktree: strangerId, wait: true });
        if (text.includes("REVIEW_TASK")) return toolCall("bash", { command: "pwd" });
        return fauxAssistantMessage("PARENT_DONE");
      }),
      { git: true },
    );
    const adopted = await createWorkspaceWorktree(
      f.workspace,
      { branch: "review/worker-source" },
      { dataDir: f.dir },
    );
    const otherWorkspace = f.storage.createWorkspace({ name: "Other", hostMount: other });
    const stranger = await createWorkspaceWorktree(
      otherWorkspace,
      { branch: "review/stranger" },
      { dataDir: f.dir },
    );
    adoptedId = adopted.id;
    strangerId = stranger.id;
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Review the worker's source");
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "adopt");
    const reviewer = f.storage.listSessions().find((session) => session.name === "Reviewer")!;
    expect(reviewer.worktreeId).toBe(adopted.id);
    expect((await toolResults(harness, conversationOf(f.storage, reviewer)))[0]!.text.trim()).toBe(
      adopted.path,
    );
    expect(existsSync(adopted.path)).toBe(true);

    await f.manager.sendPrompt(f.parent.id, "Borrow the stranger's");
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 2,
      "refusal",
    );
    const refused = (await toolResults(harness, parentConversation))[1]!;
    expect(refused).toMatchObject({ toolName: "subagent", isError: true });
    expect(refused.text).toContain("is not a worktree of workspace");
    expect(existsSync(stranger.path)).toBe(true);
  });

  it("gives a nested child its parent's worktree", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "subagent") return fauxAssistantMessage("LEAD_ANSWER");
        if (text.includes("Delegate lead"))
          return spawnCall({
            name: "Lead",
            task: "LEAD_TASK",
            worktree: "new",
            wait: true,
            allowNestedDelegation: true,
          });
        if (text.includes("LEAD_TASK"))
          return spawnCall({ name: "Mid", task: "MID_TASK", wait: true });
        return fauxAssistantMessage("MID_ANSWER");
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    await f.manager.sendPrompt(f.parent.id, "Delegate lead");
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await until(async () => (await toolResults(harness, parentConversation)).length === 1, "lead");
    const lead = f.storage.listSessions().find((session) => session.name === "Lead")!;
    const mid = f.storage.listSessions().find((session) => session.name === "Mid")!;
    const cwdOf = async (session: Session) =>
      (await harness.snapshot(AgentDoc, conversationOf(f.storage, session), context))?.cwd;
    expect(lead.worktreeId).toMatch(/^wt_/);
    expect(mid.worktreeId).toBe(lead.worktreeId);
    expect(mid.launch?.parentSessionId).toBe(lead.id);
    // The nested child runs in the same checkout, under the same path.
    expect(await cwdOf(mid)).toBe(await cwdOf(lead));
    expect(await cwdOf(mid)).toContain(join("worktrees", f.workspace.id));
  });

  it("refuses a worktree from a sandbox parent before any child exists", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Worktree it"))
          return spawnCall({ name: "Sand", task: "SAND_TASK", worktree: "new" });
        return fauxAssistantMessage("OK");
      }),
      { git: true },
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

    await f.manager.sendPrompt(f.parent.id, "Worktree it");
    await until(
      async () => (await toolResults(harness, parentConversation)).length === 1,
      "worktree refusal",
    );
    expect((await toolResults(harness, parentConversation))[0]).toMatchObject({
      toolName: "subagent",
      isError: true,
      text: expect.stringContaining("sandbox session cannot spawn a worktree child"),
    });
    expect(f.storage.listSessions().map((session) => session.id)).toEqual([f.parent.id]);
    expect(await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir })).toHaveLength(1);
  });

  it("fails a worktree child closed when its worktree is gone, never in the main checkout", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        const toolName = (last as { toolName?: string }).toolName;
        if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Spawn"))
          return spawnCall({ name: "Gone", task: "GONE_TASK", worktree: "new" });
        if (text.includes("Message it"))
          return subagentCall("send", { name: "Gone", message: "AGAIN" });
        return fauxAssistantMessage("CHILD_OK");
      }),
      { git: true },
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await until(
      async () => (await reports(harness, parentConversation)).length === 1,
      "the child's report",
    );
    const child = f.storage.listSessions().find((session) => session.name === "Gone")!;
    const worktree = (await listWorkspaceWorktrees(f.workspace, { dataDir: f.dir })).find(
      (candidate) => candidate.id === child.worktreeId,
    )!;
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    rmSync(worktree.path, { recursive: true, force: true });

    await f.manager.sendPrompt(f.parent.id, "Message it");
    await until(
      async () =>
        (await userTexts(harness, parentConversation)).some((text) =>
          text.includes("could not start:"),
        ),
      "the failure report",
    );
    const failure = (await userTexts(harness, parentConversation)).find((text) =>
      text.includes("could not start:"),
    )!;
    expect(failure).toContain("Gone");
    expect(failure).toContain("worktree is no longer available");
    // Nothing ran in the main checkout instead.
    expect(gitIn(f.repo, ["status", "--porcelain"])).toBe("");
    expect(existsSync(join(f.repo, "work.txt"))).toBe(false);
  });

  it("steers a busy child or queues after its answer, and reports each answer once", async () => {
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
        // The task's run calls a tool, so the steer joins that run after it.
        if (text.includes("BUSY_TASK")) {
          await childGate.wait(signal);
          return toolCall("read", { path: "BUSY_FILE" });
        }
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
    // Each send's reporter delivers it after the call returns.
    const inbox = async () =>
      (await harness.snapshot(InboxDoc, childConversation, context))?.items.map((item) => [
        item.mode,
        item.mode === "write" ? undefined : item.content,
      ]);
    await until(async () => (await inbox())?.length === 2, "both messages queued");
    expect(await inbox()).toEqual([
      ["steer", "STEER_MSG"],
      ["followUp", "QUEUE_MSG"],
    ]);

    childGate.open();
    await until(
      async () => (await reports(harness, parentConversation)).length === 2,
      "the reports",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    expect(await userTexts(harness, childConversation)).toEqual([
      "BUSY_TASK",
      "STEER_MSG",
      "QUEUE_MSG",
    ]);
    // The task and the steer end in one answer, reported once; the queued message has its own.
    const header = `[session Busy (${child.id}) finished, no reply needed] `;
    expect(await reports(harness, parentConversation)).toEqual([
      `${header}ANSWER STEER_MSG`,
      `${header}ANSWER QUEUE_MSG`,
    ]);
  });

  it("reports the answer to a message sent to an idle background child as a follow-up", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ name: "Idle", task: "IDLE_TASK" });
        if (text.includes("Ask it"))
          return subagentCall("send", { name: "Idle", message: "IDLE_QUESTION" });
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const settle = async (count: number, what: string) => {
      await until(async () => (await reports(harness, parentConversation)).length === count, what);
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    };
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await settle(1, "the spawn's report");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);

    await f.manager.sendPrompt(f.parent.id, "Ask it");
    await settle(2, "the send's report");

    const header = `[session Idle (${child.id}) finished, no reply needed] `;
    expect(await reports(harness, parentConversation)).toEqual([
      `${header}ANSWER IDLE_TASK`,
      `${header}ANSWER IDLE_QUESTION`,
    ]);
    const childTrace = await readDurableTrace(harness, childConversation, "full");
    expect(childTrace.find((event) => event.text === "IDLE_QUESTION")?.origin).toMatchObject({
      sessionId: f.parent.id,
      intent: "message",
    });
    const parentTrace = await readDurableTrace(harness, parentConversation, "full");
    expect(parentTrace.filter((event) => event.origin).map((event) => event.text)).toEqual([
      "ANSWER IDLE_TASK",
      "ANSWER IDLE_QUESTION",
    ]);
  });

  it("stops a child once it answers; a restart leaves it stopped, and send and wait still reach it", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ name: "Idle", task: "IDLE_TASK" });
        if (text.includes("Ask it"))
          return subagentCall("send", { name: "Idle", message: "LATER_QUESTION" });
        if (text.includes("Wait for it")) return subagentCall("wait", { names: ["Idle"] });
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const parentConversation = conversationOf(f.storage, f.parent);
    const settle = async (count: number, what: string) => {
      const harness = await f.harness();
      await until(async () => (await reports(harness, parentConversation)).length === count, what);
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    };
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await settle(1, "the spawn's report");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);

    // One settle with nothing pending stops it. Of its conversation only the working-words
    // ticker is left, which the store fence may abort and the next attach starts again; no job
    // or reporter whose loss would drop an answer.
    await until(() => f.storage.getSession(child.id)?.status === "stopped", "the child stopping");
    expect(f.manager.isActive(child.id)).toBe(false);
    expect(f.storage.getSession(child.id)?.launch?.autoStop).toBe(true);
    expect(await (await f.owner()).pendingWakers(childConversation)).toEqual([]);
    const childTasks = (await (await f.harness()).inspect(context)).tasks.filter(
      ({ record }) => record.conversationId === childConversation,
    );
    expect(childTasks.map(({ record }) => record.kind)).toEqual(["oppi.working-words"]);

    // A restart resumes the parent, not the stopped child.
    recordLiveSessionsForRestart(f.storage, [f.manager.getActiveSession(f.parent.id)!]);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    const restarted = new SessionManager(new Storage(f.dir));
    managers.push(restarted);
    await restarted.resumeDurableSessions();
    expect(restarted.isActive(f.parent.id)).toBe(true);
    expect(restarted.isActive(child.id)).toBe(false);
    expect(f.storage.getSession(child.id)?.status).toBe("stopped");

    // send attaches it again; its answer comes back once, and it stops again.
    await restarted.sendPrompt(f.parent.id, "Ask it");
    await settle(2, "the send's report");
    await until(() => f.storage.getSession(child.id)?.status === "stopped", "stopping again");
    const header = `[session Idle (${child.id}) finished, no reply needed] `;
    expect(await reports(await f.harness(), parentConversation)).toEqual([
      `${header}ANSWER IDLE_TASK`,
      `${header}ANSWER LATER_QUESTION`,
    ]);
    expect(await userTexts(await f.harness(), childConversation)).toEqual([
      "IDLE_TASK",
      "LATER_QUESTION",
    ]);

    // wait on the stopped child returns its latest answer.
    await restarted.sendPrompt(f.parent.id, "Wait for it");
    const harness = await f.harness();
    await until(
      async () =>
        (await toolResults(harness, parentConversation)).some(
          (result) => result.text === "Idle: ANSWER LATER_QUESTION",
        ),
      "the wait",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    expect(await reports(harness, parentConversation)).toHaveLength(2);
  });

  it("tells the parent when a stopped child cannot start for its message", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ name: "Idle", task: "IDLE_TASK" });
        if (text.includes("Ask it"))
          return subagentCall("send", { name: "Idle", message: "LOST_QUESTION" });
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await until(async () => (await reports(harness, parentConversation)).length === 1, "report");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    await until(() => f.storage.getSession(child.id)?.status === "stopped", "the child stopping");

    // Its sandbox VM, say, does not boot any more.
    const start = f.manager.startSession.bind(f.manager);
    vi.spyOn(f.manager, "startSession").mockImplementation((sessionId, workspace) =>
      sessionId === child.id
        ? Promise.reject(new Error("VM did not boot"))
        : start(sessionId, workspace),
    );
    await f.manager.sendPrompt(f.parent.id, "Ask it");

    const failure = `[session Idle (${child.id}) failed: could not start: VM did not boot]`;
    await until(
      async () => (await userTexts(harness, parentConversation)).includes(failure),
      "the failure report",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    expect(
      (await userTexts(harness, parentConversation)).filter((text) => text === failure),
    ).toHaveLength(1);
    expect(await userTexts(harness, conversationOf(f.storage, child))).toEqual(["IDLE_TASK"]);
    expect(f.manager.isActive(child.id)).toBe(false);
  });

  it("returns the answer to a send from a wait right after it, not the previous answer", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn")) return spawnCall({ name: "Quick", task: "FIRST_TASK" });
        // Send, then wait, in one answer.
        if (text.includes("Ask and wait"))
          return fauxAssistantMessage(
            [
              fauxToolCall("subagent", { action: "send", name: "Quick", message: "SECOND_Q" }),
              fauxToolCall("subagent", { action: "wait", names: ["Quick"] }),
            ],
            { stopReason: "toolUse" },
          );
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Spawn it");
    await until(async () => (await reports(harness, parentConversation)).length === 1, "report");
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    // The child stopped after its answer; the send and the wait reach it all the same.
    const quick = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    await until(() => f.storage.getSession(quick.id)?.status === "stopped", "the child stopping");

    await f.manager.sendPrompt(f.parent.id, "Ask and wait");
    await until(async () => (await toolResults(harness, parentConversation)).length === 3, "wait");
    expect((await toolResults(harness, parentConversation))[2]).toMatchObject({
      toolName: "subagent",
      text: "Quick: ANSWER SECOND_Q",
    });
    // Once everything settled, the parent read the answer once, as the wait result: the send's
    // reporter posted no report of it.
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    await until(
      async () => !(await (await f.owner()).hasPendingWake(parentConversation)),
      "the reporters to end",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    expect(await reports(harness, parentConversation)).toEqual([
      `[session Quick (${child.id}) finished, no reply needed] ANSWER FIRST_TASK`,
    ]);
    expect(
      (await toolResults(harness, parentConversation)).filter((result) =>
        result.text.includes("ANSWER SECOND_Q"),
      ),
    ).toHaveLength(1);
    expect(
      (await userTexts(harness, conversationOf(f.storage, child))).filter(
        (text) => text === "SECOND_Q",
      ),
    ).toEqual(["SECOND_Q"]);
  });

  it("keeps an answer of a multi-child wait that is aborted while another child works", async () => {
    const held = gate();
    let bStarted!: () => void;
    const bStarting = new Promise<void>((resolve) => (bStarted = resolve));
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Spawn A")) return spawnCall({ name: "A", task: "A_TASK" });
        if (text.includes("Spawn B")) return spawnCall({ name: "B", task: "B_TASK" });
        if (text.includes("Ask both"))
          return fauxAssistantMessage(
            [
              fauxToolCall("subagent", { action: "send", name: "A", message: "QA" }),
              fauxToolCall("subagent", { action: "send", name: "B", message: "QB" }),
              fauxToolCall("subagent", { action: "wait", names: ["A", "B"] }),
            ],
            { stopReason: "toolUse" },
          );
        if (text === "QB") {
          bStarted();
          await held.wait(signal);
        }
        return fauxAssistantMessage(`ANSWER ${text}`);
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const settle = async (count: number) => {
      await until(
        async () => (await reports(harness, parentConversation)).length === count,
        "report",
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    };
    await f.manager.sendPrompt(f.parent.id, "Spawn A");
    await settle(1);
    await f.manager.sendPrompt(f.parent.id, "Spawn B");
    await settle(2);
    const childA = f.storage.listSessions().find((session) => session.name === "A")!;

    await f.manager.sendPrompt(f.parent.id, "Ask both");
    await bStarting;
    // A answered QA and its report reached the parent's queue (the parent is busy in the round),
    // after the report of its task.
    const reportOfA = `oppi-report:${conversationOf(f.storage, childA)}:`;
    await until(
      () => requestIds(f.storage, f.dir, f.parent.id, reportOfA).length === 2,
      "A's report",
    );
    await new Promise((resolve) => setTimeout(resolve, 300));
    // Abort the wait call alone, while B still works; the parent's run goes on.
    const waitCall = (await harness.snapshot(LiveDoc, parentConversation, context))?.tools?.[2];
    expect(waitCall?.status).not.toBe("done");
    await harness.abortTask(waitCall!.taskId!, context);
    held.open();

    // The aborted wait returned no answer, so A's answer still reaches the parent, once.
    await settle(4);
    const childB = f.storage.listSessions().find((session) => session.name === "B")!;
    const header = (name: string, id: string) =>
      `[session ${name} (${id}) finished, no reply needed] `;
    expect((await reports(harness, parentConversation)).toSorted()).toEqual(
      [
        `${header("A", childA.id)}ANSWER A_TASK`,
        `${header("A", childA.id)}ANSWER QA`,
        `${header("B", childB.id)}ANSWER B_TASK`,
        `${header("B", childB.id)}ANSWER QB`,
      ].toSorted(),
    );
  });

  it("holds wait on a child idle while its own subagent works, and ends that wait with the parent's Stop", async () => {
    const held = gate();
    const f = await fixture(
      model(async ({ last, text, signal }) => {
        if (text.includes("[session Grand")) return fauxAssistantMessage("LEAD_DONE");
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult") return fauxAssistantMessage("LEAD_WAITING");
        if (text.includes("Delegate lead"))
          return spawnCall({ name: "Lead", task: "LEAD_TASK", allowNestedDelegation: true });
        if (text.includes("Wait for Lead")) return subagentCall("wait", { names: ["Lead"] });
        if (text.includes("LEAD_TASK")) return spawnCall({ name: "Grand", task: "GRAND_TASK" });
        if (text.includes("GRAND_TASK")) {
          await held.wait(signal);
          return fauxAssistantMessage("GRAND_DONE");
        }
        return fauxAssistantMessage("OTHER");
      }),
    );
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    await f.manager.sendPrompt(f.parent.id, "Delegate lead");
    await until(
      async () => (await reports(harness, parentConversation)).length === 1,
      "Lead's first report",
    );
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    const lead = f.storage.listSessions().find((session) => session.name === "Lead")!;
    const leadConversation = conversationOf(f.storage, lead);
    // Lead answered and is idle; its only pending waker is its reporter of Grand, still working.
    expect((await harness.snapshot(LiveDoc, leadConversation, context))?.run).toBeUndefined();
    expect(await (await f.owner()).pendingWakers(leadConversation)).toHaveLength(1);

    await f.manager.sendPrompt(f.parent.id, "Wait for Lead");
    const slot = async () =>
      (await harness.snapshot(LiveDoc, parentConversation, context))?.tools?.find(
        (candidate) => candidate.name === "subagent",
      );
    await until(async () => (await slot())?.status === "running", "the wait call");
    await new Promise((resolve) => setTimeout(resolve, 500));
    expect((await slot())?.status).toBe("running");
    expect(await toolResults(harness, parentConversation)).toHaveLength(1);
    // Deciding that Lead waits on its own subagent wrote nothing for jobs it never started.
    expect(await harness.snapshot(DurableJobs, leadConversation, context)).toBeUndefined();

    await f.manager.sendAbort(f.parent.id);
    await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
    // The parent is idle while Grand still works; the aborted wait returned no answer of Lead.
    expect(await (await f.owner()).pendingWakers(leadConversation)).toHaveLength(1);
    expect(
      (await toolResults(harness, parentConversation)).filter((result) =>
        result.text.includes("LEAD_"),
      ),
    ).toEqual([]);

    // Grand's answer wakes Lead, whose answer then reaches the parent as a report.
    held.open();
    await until(
      async () => (await reports(harness, parentConversation)).length === 2,
      "Lead's report after Grand",
    );
    const header = `[session Lead (${lead.id}) finished, no reply needed] `;
    expect(await reports(harness, parentConversation)).toEqual([
      `${header}LEAD_WAITING`,
      `${header}LEAD_DONE`,
    ]);
  });

  describe("a child that answers while its background job runs", () => {
    /**
     * Builder's model: on its task it starts `command()` as a job, ends that turn (once `turn`
     * resolves), then answers on its receipt.
     */
    const jobModel = (command: () => string, turn?: Promise<void>) =>
      model(async ({ last, text }) => {
        if (text.includes("[session")) return fauxAssistantMessage("NOTED");
        if (last.role === "toolResult" && last.toolName === "background_job") {
          await turn;
          return fauxAssistantMessage("WAITING_ON_JOB");
        }
        if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
        if (text.includes("Delegate")) return spawnCall({ name: "Builder", task: "BUILD_TASK" });
        if (text.includes("Build in the foreground"))
          return spawnCall({ name: "Builder", task: "BUILD_TASK", wait: true });
        if (text.includes("Wait for Builder")) return subagentCall("wait", { names: ["Builder"] });
        if (text.includes("List them")) return subagentCall("list");
        if (text.includes("BUILD_TASK"))
          return toolCall("background_job", { action: "start", command: command() });
        // The job's receipt, finished or interrupted.
        if (text.includes("Background job bash-1")) return fauxAssistantMessage("BUILD_DONE");
        return fauxAssistantMessage("OTHER");
      });
    /** A job command that runs until the gate file exists. */
    const gated = (gatePath: string) =>
      `for i in $(seq 1 400); do [ -f '${gatePath}' ] && break; sleep 0.05; done; echo JOB_OUTPUT`;

    async function jobFixture() {
      let command = "";
      const f = await fixture(jobModel(() => command));
      const gatePath = join(f.dir, "job-gate");
      command = gated(gatePath);
      await f.manager.startSession(f.parent.id, f.workspace);
      await f.manager.sendPrompt(f.parent.id, "Delegate the build");
      const parentConversation = conversationOf(f.storage, f.parent);
      const harness = await f.harness();
      await until(
        async () => (await reports(harness, parentConversation)).length === 1,
        "the first report",
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
      const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
      return { f, child, parentConversation, open: () => writeFileSync(gatePath, "") };
    }

    /** Waits for both reports and for the parent to let go of the child, then checks them. */
    async function expectTwoReports(
      f: Fixture,
      child: Session,
      parentConversation: ConversationId,
    ): Promise<void> {
      const harness = await f.harness();
      await until(
        async () => (await reports(harness, parentConversation)).length >= 2,
        "the report after the job",
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
      // Nothing of the child holds the parent awake any more.
      await until(
        async () => !(await (await f.owner()).hasPendingWake(parentConversation)),
        "the parent's reporter to end",
      );
      const header = `[session Builder (${child.id}) finished, no reply needed] `;
      expect(await reports(harness, parentConversation)).toEqual([
        `${header}WAITING_ON_JOB`,
        `${header}BUILD_DONE`,
      ]);
      expect(requestIds(f.storage, f.dir, f.parent.id, "oppi-report:")).toHaveLength(2);
    }

    it("reports its answer after the job's receipt turn, once, and stops only after that turn", async () => {
      const { f, child, parentConversation, open } = await jobFixture();
      // The parent's reporter waits on the child's job, so the parent's idle timeout holds.
      expect(await (await f.owner()).hasPendingWake(parentConversation)).toBe(true);
      // The child settled with its job running: it stays attached for the receipt. Decide again
      // as a settle does, and watch that decision end at its wake check.
      const internals = f.manager as unknown as {
        active: Map<string, { sdkBackend: { hasPendingWake(): Promise<boolean> } }>;
        lifecycleCoordinator: { handleSessionSettled(key: string): void };
        autoStopSession(sessionId: string, guard: unknown): Promise<boolean>;
      };
      expect(f.manager.isActive(child.id)).toBe(true);
      const wake = vi.spyOn(internals.active.get(child.id)!.sdkBackend, "hasPendingWake");
      const autoStop = vi.spyOn(internals, "autoStopSession");
      internals.lifecycleCoordinator.handleSessionSettled(child.id);
      expect(wake).toHaveBeenCalledOnce();
      // The decision awaited this promise first, so it has returned once the test sees it.
      expect(await wake.mock.results[0]!.value).toBe(true);
      expect(autoStop).not.toHaveBeenCalled();
      expect(f.manager.isActive(child.id)).toBe(true);
      expect(f.storage.getSession(child.id)?.status).toBe("ready");
      autoStop.mockRestore();

      open();
      await expectTwoReports(f, child, parentConversation);
      await until(
        () => f.storage.getSession(child.id)?.status === "stopped",
        "the child stopping after its receipt turn",
      );
      expect(f.manager.isActive(child.id)).toBe(false);
    });

    /**
     * `text` is `answer` and then a note that names the job still running, which it still is.
     */
    const expectAnswerNamingRunningJob = async (
      f: Fixture,
      child: Session,
      text: string,
      answer: string,
    ) => {
      expect(text.startsWith(`${answer}\n\n`)).toBe(true);
      expect(text.slice(answer.length)).toContain("bash-1");
      const harness = await f.harness();
      expect(
        (await harness.snapshot(DurableJobs, conversationOf(f.storage, child), context))?.jobs,
      ).toMatchObject([{ id: "bash-1", status: "running" }]);
    };

    it("returns the child's answer from wait with a note while only its job runs, and the job's end still wakes it", async () => {
      const { f, child, parentConversation, open } = await jobFixture();
      const harness = await f.harness();
      const childConversation = conversationOf(f.storage, child);
      await f.manager.sendPrompt(f.parent.id, "Wait for Builder");
      await until(
        async () => (await toolResults(harness, parentConversation)).length === 2,
        "the wait result",
      );
      const waited = (await toolResults(harness, parentConversation))[1]!;
      expect(waited.toolName).toBe("subagent");
      expect(waited.isError).toBeFalsy();
      await expectAnswerNamingRunningJob(f, child, waited.text, "Builder: WAITING_ON_JOB");
      // The child still waits on its job.
      expect(await (await f.owner()).pendingWakers(childConversation)).toHaveLength(1);

      // Its end wakes the child, whose answer arrives as a report.
      open();
      await expectTwoReports(f, child, parentConversation);
    });

    it("holds wait while the child is busy in a turn, even with its job running, and returns once it ends that turn", async () => {
      let command = "";
      const turn = gate();
      const f = await fixture(jobModel(() => command, turn.wait()));
      const gatePath = join(f.dir, "job-gate");
      command = gated(gatePath);
      await f.manager.startSession(f.parent.id, f.workspace);
      const harness = await f.harness();
      const parentConversation = conversationOf(f.storage, f.parent);
      await f.manager.sendPrompt(f.parent.id, "Delegate the build");
      await until(() => f.storage.listSessions().length === 2, "the child session");
      const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
      const childConversation = conversationOf(f.storage, child);
      // The child started its job and is still in that turn.
      await until(
        async () =>
          (await harness.snapshot(DurableJobs, childConversation, context))?.jobs[0]?.status ===
          "running",
        "the child's job",
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

      await f.manager.sendPrompt(f.parent.id, "Wait for Builder");
      const slot = async () =>
        (await harness.snapshot(LiveDoc, parentConversation, context))?.tools?.find(
          (candidate) => candidate.name === "subagent",
        );
      await until(async () => (await slot())?.status === "running", "the wait call");
      await new Promise((resolve) => setTimeout(resolve, 500));
      expect((await slot())?.status).toBe("running");
      expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();
      expect(await toolResults(harness, parentConversation)).toHaveLength(1);

      turn.open();
      await until(
        async () => (await toolResults(harness, parentConversation)).length === 2,
        "the wait result",
      );
      await expectAnswerNamingRunningJob(
        f,
        child,
        (await toolResults(harness, parentConversation))[1]!.text,
        "Builder: WAITING_ON_JOB",
      );

      // wait took that answer, so only the answer after the job's receipt is reported.
      writeFileSync(gatePath, "");
      await until(
        async () => (await reports(harness, parentConversation)).length === 1,
        "the report after the job",
      );
      expect(await reports(harness, parentConversation)).toEqual([
        `[session Builder (${child.id}) finished, no reply needed] BUILD_DONE`,
      ]);
    });

    it("returns the child's answer from spawn with wait with a note while only its job runs; a later wait returns its answer after the job", async () => {
      let command = "";
      const f = await fixture(jobModel(() => command));
      const gatePath = join(f.dir, "job-gate");
      command = gated(gatePath);
      await f.manager.startSession(f.parent.id, f.workspace);
      await f.manager.sendPrompt(f.parent.id, "Build in the foreground");
      const harness = await f.harness();
      const parentConversation = conversationOf(f.storage, f.parent);
      await until(
        async () => (await toolResults(harness, parentConversation)).length === 1,
        "the spawn result",
      );
      const spawned = (await toolResults(harness, parentConversation))[0]!;
      expect(spawned.toolName).toBe("subagent");
      const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
      await expectAnswerNamingRunningJob(f, child, spawned.text, "WAITING_ON_JOB");
      const childConversation = conversationOf(f.storage, child);
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

      writeFileSync(gatePath, "");
      await until(
        async () =>
          (await harness.snapshot(DurableJobs, childConversation, context))?.jobs[0]?.status !==
          "running",
        "the job's end",
      );
      await f.manager.sendPrompt(f.parent.id, "Wait for Builder");
      await until(
        async () => (await toolResults(harness, parentConversation)).length === 2,
        "the wait result",
      );
      expect((await toolResults(harness, parentConversation))[1]).toMatchObject({
        toolName: "subagent",
        text: "Builder: BUILD_DONE",
      });
    });

    it("shows the child as working in its pill and list while its job runs, and done after", async () => {
      const { f, child, parentConversation, open } = await jobFixture();
      const harness = await f.harness();
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

      await until(
        async () => String((await row())?.detail).includes(WAITING_ACTIVITY),
        "the waiting row",
      );
      expect(await row()).toMatchObject({ state: "running", subtitle: "Working · faux-1" });
      expect((await pill())?.presentation).toMatchObject({ subtitle: "Working" });
      await f.manager.sendPrompt(f.parent.id, "List them");
      await until(
        async () => (await toolResults(harness, parentConversation)).length === 2,
        "the list result",
      );
      expect((await toolResults(harness, parentConversation))[1]?.text).toContain(
        "Builder | waiting on background work |",
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);

      open();
      await until(async () => (await row())?.state === "success", "a done row");
      expect((await pill())?.presentation).toMatchObject({ subtitle: "Done" });
      expect(String((await row())?.detail)).not.toContain(WAITING_ACTIVITY);
      await expectTwoReports(f, child, parentConversation);
    });

    it("shows the child as working in a pill whose watcher starts while the parent has no execution env", async () => {
      const { f, child, parentConversation, open } = await jobFixture();
      const harness = await f.harness();
      const row = async () =>
        (
          (await harness.snapshot(DurableUI, parentConversation, context))?.notifications[
            "widget:subagents"
          ]?.nativeSurface as
            { blocks: Array<{ rows: Array<{ state: string; detail?: string }> }> } | undefined
        )?.blocks[0]?.rows[0];
      await until(
        async () => String((await row())?.detail).includes(WAITING_ACTIVITY),
        "the waiting row",
      );
      // A sandbox parent with no VM attached: the server refuses to build its env. The pill's
      // slot is cleared so the new watcher's first pass is what it shows.
      const setRuntime = (kind: "host" | "sandbox") =>
        harness.commit(async (tx) => {
          (await tx.doc(DurableRuntime, parentConversation)).kind = kind;
        }, context);
      await setRuntime("sandbox");
      const retired = (await harness.snapshot(Subagents, parentConversation, context))?.widget;
      await harness.abortTask(retired!, context);
      await harness.waitForTask(retired!, context);
      const host = await f.owner();
      await harness.commit(async (tx) => {
        delete (await tx.doc(DurableUI, parentConversation)).notifications["widget:subagents"];
        await ensureSubagentWidget(
          tx,
          parentConversation,
          host.runtime.installedTask(SUBAGENT_WIDGET_TASK),
        );
      }, context);

      await until(async () => (await row()) !== undefined, "the new watcher's row");
      expect(await row()).toMatchObject({ state: "running" });
      expect(String((await row())?.detail)).toContain(WAITING_ACTIVITY);

      // The parent's follower needs its env again after the job.
      await setRuntime("host");
      open();
      await until(async () => (await row())?.state === "success", "a done row");
      await expectTwoReports(f, child, parentConversation);
    });

    it("reports its answer once when a restart interrupts the job", async () => {
      const { f, child, parentConversation } = await jobFixture();

      recordLiveSessionsForRestart(f.storage, [
        f.manager.getActiveSession(f.parent.id)!,
        f.manager.getActiveSession(child.id)!,
      ]);
      await f.manager.close();
      managers.splice(managers.indexOf(f.manager), 1);
      const restarted = new SessionManager(new Storage(f.dir));
      managers.push(restarted);
      await restarted.resumeDurableSessions();

      await expectTwoReports(f, child, parentConversation);
    });

    it("keeps following its child after a long run of crashes", async () => {
      const { f, child, parentConversation } = await jobFixture();
      // Cut off by 9 crashes in a row while it waited; pi-durable's default would park it at 5.
      await restartWithFollower(f, [child], parentConversation, "$.restarts", 9);
      await expectTwoReports(f, child, parentConversation);
    });

    it("ends a wait on a child busy in its receipt turn with the parent's Stop, and leaves nothing waiting on the child", async () => {
      const receiptTurn = gate();
      let command = "";
      const f = await fixture(
        model(async ({ last, text, signal }) => {
          if (text.includes("[session")) return fauxAssistantMessage("NOTED");
          if (last.role === "toolResult" && last.toolName === "background_job")
            return fauxAssistantMessage("WAITING_ON_JOB");
          if (last.role === "toolResult") return fauxAssistantMessage("PARENT_DONE");
          if (text.includes("Delegate")) return spawnCall({ name: "Builder", task: "BUILD_TASK" });
          if (text.includes("Wait for Builder"))
            return subagentCall("wait", { names: ["Builder"] });
          if (text.includes("BUILD_TASK"))
            return toolCall("background_job", { action: "start", command });
          // The job's receipt: the child's turn that the parent's wait then finds it in.
          if (text.includes("Background job bash-1")) {
            await receiptTurn.wait(signal);
            return fauxAssistantMessage("BUILD_DONE");
          }
          return fauxAssistantMessage("OTHER");
        }),
      );
      command = gated(join(f.dir, "job-gate"));
      await f.manager.startSession(f.parent.id, f.workspace);
      await f.manager.sendPrompt(f.parent.id, "Delegate the build");
      const parentConversation = conversationOf(f.storage, f.parent);
      const harness = await f.harness();
      await until(
        async () => (await reports(harness, parentConversation)).length === 1,
        "the first report",
      );
      await (await harness.conversation(parentConversation, context))!.waitForIdle(context);
      const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
      const childConversation = conversationOf(f.storage, child);
      // The job ends and its receipt starts a turn of the child that stays open.
      writeFileSync(join(f.dir, "job-gate"), "");
      await until(
        async () =>
          (await harness.snapshot(LiveDoc, childConversation, context))?.run !== undefined,
        "the child's receipt turn",
      );

      await f.manager.sendPrompt(f.parent.id, "Wait for Builder");
      // The wait holds the store open while it waits for the child's turn to end.
      await until(
        async () => (await f.owner()).holdReasons.includes("use"),
        "the wait for the child to be idle",
      );
      await f.manager.sendAbort(f.parent.id);
      // Stop does not cascade to a background child, whose turn goes on: the parent's Stop must
      // not wait for it, and its cut-off wait must let go of the store.
      const idle = (await harness.conversation(parentConversation, context))!.waitForIdle(context);
      const outcome = await Promise.race([
        idle.then(() => "idle"),
        new Promise<string>((resolve) => setTimeout(() => resolve("still waiting"), 5_000)),
      ]);
      expect(outcome).toBe("idle");
      expect((await harness.snapshot(LiveDoc, childConversation, context))?.run).toBeDefined();
      await until(
        async () => !(await f.owner()).holdReasons.includes("use"),
        "the cut-off wait to release the store",
      );
      expect(
        (await toolResults(harness, parentConversation)).filter((result) =>
          result.text.includes("BUILD_"),
        ),
      ).toEqual([]);

      // The child's turn is unaffected; its answer reaches the parent as a report.
      receiptTurn.open();
      await until(
        async () => (await reports(harness, parentConversation)).length === 2,
        "the report after the receipt turn",
      );
    });

    it("lets the parent idle when its follower cannot run", async () => {
      const { f, child, parentConversation } = await jobFixture();
      // Stored by a newer Oppi than this one: no installed definition takes it.
      const follower = await restartWithFollower(f, [child], parentConversation, "$.version", 99);
      const harness = await f.harness();
      const inspected = (await harness.inspect(context)).tasks.find(
        ({ record }) => record.id === follower,
      );
      expect(inspected?.state).toMatchObject({ kind: "blocked", reason: "task_too_old" });
      // A blocked task never ends by itself, so it must not hold the parent's idle timeout.
      expect(await (await f.owner()).hasPendingWake(parentConversation)).toBe(false);
    });
  });

  /**
   * Restart the server with the parent's follower of Builder stored with `value` at `path` of
   * its task record. Returns the follower's id.
   */
  async function restartWithFollower(
    f: Fixture,
    children: Session[],
    parentConversation: ConversationId,
    path: string,
    value: number,
  ): Promise<TaskId> {
    const harness = await f.harness();
    const followerOf = async () =>
      (await harness.snapshot(Subagents, parentConversation, context))?.children.Builder?.follower;
    // A reporter becomes the follower in its first follow round.
    await until(async () => (await followerOf()) !== undefined, "the follower");
    const follower = (await followerOf())!;
    recordLiveSessionsForRestart(f.storage, [
      f.manager.getActiveSession(f.parent.id)!,
      ...children.map((child) => f.manager.getActiveSession(child.id)!),
    ]);
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    const storeId = f.storage.getSession(f.parent.id)!.serverDurable!.storeId!;
    const db = new DatabaseSync(durableStoreSqlitePath(f.dir, storeId));
    try {
      db.prepare("UPDATE tasks SET record = json_set(record, ?, ?) WHERE id = ?").run(
        path,
        value,
        follower,
      );
    } finally {
      db.close();
    }
    const restarted = new SessionManager(new Storage(f.dir));
    managers.push(restarted);
    await restarted.resumeDurableSessions();
    return follower;
  }

  it("spawns a saved Agent as its AgentChange: model, tools, replaced instructions without project context", async () => {
    const f = await fixture(
      model(async ({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("DONE");
        if (text.includes("Review it"))
          return spawnCall({ name: "Rev", task: "REVIEW_TASK", agent: "Reviewer", wait: true });
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
    // The child answers and stops; with nothing attached and nothing live, the store closes.
    await until(() => f.storage.getSession(child.id)?.status === "stopped", "child stopped");
    await new Promise((resolve) => setTimeout(resolve, 300));

    // No report reached the stopped parent, so no turn of it started.
    expect(requestIds(f.storage, f.dir, f.parent.id, "oppi-report:")).toEqual([]);
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

  it("deletes a session tree's store with its last Session and leaves other stores alone", async () => {
    const f = await fixture(
      model(({ last, text }) => {
        if (last.role === "toolResult") return fauxAssistantMessage("PARENT_DONE");
        if (text.includes("Delegate"))
          return spawnCall({ task: "CHILD_TASK scout", name: "Scout", wait: true });
        if (text.includes("CHILD_TASK")) return fauxAssistantMessage("CHILD_ANSWER");
        return fauxAssistantMessage("SIBLING_ANSWER");
      }),
    );
    const sibling = f.session("Sibling");
    const ask = async (sessionId: string, prompt: string) => {
      await f.manager.startSession(sessionId, f.workspace);
      const end = observe(f.manager, sessionId).next((message) => message.type === "agent_end");
      await f.manager.sendPrompt(sessionId, prompt);
      await end;
    };
    await ask(f.parent.id, "Delegate the scouting");
    await ask(sibling.id, "Hello sibling");
    const child = f.storage
      .listSessions()
      .find((session) => session.launch?.parentSessionId === f.parent.id)!;
    expect(durableStoreId(child)).toBe(f.parent.id);
    const treeStore = durableStoreDir(f.dir, f.parent.id);
    const siblingStore = durableStoreSqlitePath(f.dir, sibling.id);
    expect(existsSync(durableStoreSqlitePath(f.dir, f.parent.id))).toBe(true);
    expect(existsSync(siblingStore)).toBe(true);

    const dispatch = createSessionRoutes(
      {
        storage: f.storage,
        sessions: f.manager,
        sessionRuntimes: new SessionRuntimes(f.storage, f.manager, {} as never),
        ensureSessionContextWindow: (session: Session) => session,
      } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const remove = async (sessionId: string) => {
      const path = `/workspaces/${f.workspace.id}/sessions/${sessionId}`;
      const res = makeResponse();
      await dispatch({
        method: "DELETE",
        path,
        url: new URL(path, "http://localhost"),
        req: makeRequest() as never,
        res: res as never,
      });
      expect(res.statusCode).toBe(200);
    };
    const transcript = async (sessionId: string) =>
      ((await f.manager.getServerDurableTrace(sessionId, "full")) ?? [])
        .filter((event) => event.type === "assistant")
        .map((event) => event.text);

    // The child's conversation lives in its parent's store: deleting the parent keeps it.
    await remove(f.parent.id);
    expect(existsSync(treeStore)).toBe(true);
    expect(await transcript(child.id)).toEqual(["CHILD_ANSWER"]);

    // The tree's last Session takes the store with it; another tree's store stays.
    await remove(child.id);
    expect(existsSync(treeStore)).toBe(false);
    expect(existsSync(siblingStore)).toBe(true);
    expect(await transcript(sibling.id)).toEqual(["SIBLING_ANSWER"]);
  });
});

describe("durable host caller identity", () => {
  /** The model of these tests: bash prints the caller identity its env carries; "Delegate" spawns. */
  const probingModel = (spawnArgs: Record<string, unknown> = {}) =>
    model(({ last, text }) => {
      const toolName = (last as { toolName?: string }).toolName;
      if (toolName === "bash") return fauxAssistantMessage("CHECKED");
      if (toolName === "subagent") return fauxAssistantMessage("PARENT_DONE");
      if (text.includes("Delegate"))
        return spawnCall({ name: "Probe", task: "PROBE_TASK", ...spawnArgs });
      return toolCall("bash", { command: 'printf "%s" "$OPPI_CALLER_SESSION_ID"' });
    });

  /** The launch service `oppi session create` goes through, over the fixture's Storage. */
  const launchService = (f: Fixture) =>
    new AgentLaunchService({
      storage: f.storage,
      sessions: {
        startSession: (sessionId, workspace) => f.manager.startSession(sessionId, workspace),
        sendPrompt: (sessionId, message) => f.manager.sendPrompt(sessionId, message),
      },
      ensureSessionContextWindow: (session) => session,
    });

  /**
   * Run the parent's bash, spawn a child, and return both sessions with the caller identity each
   * host env gave its bash. The parent's bash runs first so the child's id can only be its own.
   */
  async function probe(f: Fixture) {
    await f.manager.startSession(f.parent.id, f.workspace);
    const harness = await f.harness();
    const parentConversation = conversationOf(f.storage, f.parent);
    const parentBash = async () =>
      (await toolResults(harness, parentConversation)).find((result) => result.toolName === "bash");
    await f.manager.sendPrompt(f.parent.id, "Check the caller");
    await until(async () => (await parentBash()) !== undefined, "the parent's bash");
    await f.manager.sendPrompt(f.parent.id, "Delegate the check");
    await until(() => f.storage.listSessions().length === 2, "the child session");
    const child = f.storage.listSessions().find((session) => session.id !== f.parent.id)!;
    const childConversation = conversationOf(f.storage, child);
    const childBash = async () =>
      (await toolResults(harness, childConversation)).find((result) => result.toolName === "bash");
    await until(async () => (await childBash()) !== undefined, "the child's bash");
    return {
      child,
      parentCaller: (await parentBash())!.text,
      childCaller: (await childBash())!.text,
    };
  }

  it("gives a conversation's host bash its own session's caller identity, not its owner's", async () => {
    const f = await fixture(probingModel());
    const { child, parentCaller, childCaller } = await probe(f);

    expect(parentCaller).toBe(f.parent.id);
    // The child's bash attributes a launch to the child, not to the session that spawned it.
    expect(childCaller).toBe(child.id);
    expect(childCaller).not.toBe(parentCaller);
  });

  it("refuses the launch a child without the grant asks for through its bash", async () => {
    const f = await fixture(probingModel());
    const { child, childCaller } = await probe(f);

    // `oppi session create` run from that bash: the caller id is the parent of the launch.
    await expect(
      launchService(f).launch({
        agent: { name: "Grandchild" },
        target: { workspace: f.workspace },
        parentSessionId: childCaller,
        prompt: "no",
      }),
    ).rejects.toThrow(DelegationPolicyError);
    expect(
      f.storage
        .listSessions()
        .map((session) => session.id)
        .sort(),
    ).toEqual([f.parent.id, child.id].sort());
  });

  it("parents the launch a child with the grant asks for through its bash", async () => {
    const f = await fixture(probingModel({ allowNestedDelegation: true }));
    const { child, childCaller } = await probe(f);

    const result = await launchService(f).launch({
      agent: { name: "Grandchild" },
      target: { workspace: f.workspace },
      parentSessionId: childCaller,
    });
    if (result.kind !== "created") throw new Error(`unexpected ${result.kind}`);
    // The caller is the child, so the launch is parented and takes the child's auto-stop default.
    expect(result.session.launch).toMatchObject({
      parentSessionId: child.id,
      allowsNestedDelegation: true,
      autoStop: true,
    });
    expect(f.storage.listSessions().map((session) => session.id)).toContain(result.session.id);
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
              voiceBackendHealth: makeUnconfiguredVoiceBackendHealth(),
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

    // Stopped rows come from the SQLite projection, not the live runtime. The child stopped
    // once it answered.
    await until(() => f.storage.getSession(child.id)?.status === "stopped", "the child stopping");
    await f.manager.stopSession(sessionId);
    const stopped = await route(
      f,
      "GET",
      `/workspaces/${f.workspace.id}/sessions?status=stopped&sinceMs=0&untilMs=${Date.now() + 60_000}`,
    );
    const stoppedRows = stopped.body.stopped as Array<{ id: string; engine?: string }>;
    expect(stoppedRows.find((row) => row.id === sessionId)?.engine).toBe("durable");
    expect(stoppedRows.find((row) => row.id === child.id)?.engine).toBe("durable");
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

    // A selection the durable engine cannot fully honor still starts: MCP and tool search
    // come with `builtin:mcp`, a Pi package whose durable version Oppi bundles is that
    // built-in, and the rest (codemode, classic-only Extensions) are named as skipped.
    const agentDir = process.env.PI_CODING_AGENT_DIR!;
    const twin = join(agentDir, "extensions", "my-ask");
    mkdirSync(twin, { recursive: true });
    writeFileSync(
      join(twin, "package.json"),
      JSON.stringify({
        name: "my-ask",
        pi: { extensions: ["./index.ts"] },
        oppi: { durable: { entry: "./durable.ts" } },
      }),
    );
    writeFileSync(join(twin, "index.ts"), "export default function () {}\n");
    writeFileSync(join(twin, "durable.ts"), 'export default { name: "ask" };\n');
    const classicOnly = join(agentDir, "extensions", "commit-trailer.ts");
    writeFileSync(classicOnly, "export default function () {}\n");
    expect((await f.manager.reloadDurableExtensions())?.skipped).toEqual([
      expect.objectContaining({ root: twin }),
    ]);
    const plugged = agents.createAgent({
      name: "Plugged",
      resources: {
        extensionIds: [
          serverResourceId("extension", join(twin, "index.ts")),
          serverResourceId("extension", classicOnly),
          "extension_missing",
          "builtin:mcp",
          "builtin:tool-search",
          "builtin:codemode",
        ],
      },
    });
    const started = await route(f, "POST", `/agents/${plugged.id}/sessions`, {
      prompt: { text: "Plugged in" },
      target: { workspaceId: f.workspace.id },
      engine: "durable",
    });
    expect(started.status).toBe(201);
    const pluggedId = (started.body.session as Session).id;
    const pluggedConversation = conversationOf(f.storage, pluggedId);
    const pluggedHarness = await f.openStore(pluggedId);
    await until(
      async () => (await userTexts(pluggedHarness, pluggedConversation)).includes("Plugged in"),
      "the plugged agent's first prompt",
    );
    expect(
      (await pluggedHarness.snapshot(OppiAgentDoc, pluggedConversation, context))?.extensions,
    ).toEqual({
      packages: [],
      mcp: true,
      skipped: ["commit-trailer", "extension_missing", "codemode"],
    });
    // The session row says what it runs without, once, also after another attach.
    const warnings = [
      "Selected Agent Extensions are not loaded in this durable session (no durable version, or turned off with oppi extensions disable): commit-trailer, extension_missing, codemode. Edit the Agent's selected Extensions, or start it Classic, to use them.",
    ];
    expect(f.storage.getSession(pluggedId)?.warnings).toEqual(warnings);
    await f.manager.stopSession(pluggedId);
    await f.manager.startSession(pluggedId, f.workspace);
    expect(f.storage.getSession(pluggedId)?.warnings).toEqual(warnings);
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

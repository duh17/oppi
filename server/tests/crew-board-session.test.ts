import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY } from "../src/extension-ui-contract.js";
import type { ExtensionUISurfaceAudience } from "../src/extension-surface-runtime.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import { WsMessageHandler } from "../src/ws-message-handler.js";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

/**
 * `crew_board` through a real durable Session: the built-in plugin publishes its strip surface on
 * the session stream, the phone taps it, and the board clears with the Session. The worker is a
 * child Session row (its conversation is never attached here); the land queue is a real file in
 * the workspace's repository, in the format the agent-workflow script writes.
 */

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
let agentDir: string;

beforeEach(() => {
  agentDir = makeTempDir("oppi-crew-board-agent-");
  process.env.PI_CODING_AGENT_DIR = agentDir;
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

const QUEUE = [
  { branch: "worker-a", after: [], status: "queued" },
  { branch: "worker-b", after: ["worker-a"], status: "queued" },
  { branch: "worker-c", after: [], status: "conflict" },
];

function createDurableSession(storage: Storage, name: string): Session {
  const session = storage.createSession(name, "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  storage.saveSession(session);
  return session;
}

async function fixture(
  responses: FauxResponseStep[],
  options: { queue?: boolean; child?: boolean } = {},
) {
  const dir = makeTempDir("oppi-crew-board-workspace-");
  if (options.queue !== false) {
    const landQueue = join(dir, ".git", "oppi", "land-queue");
    mkdirSync(landQueue, { recursive: true });
    writeFileSync(
      join(landQueue, "queue.jsonl"),
      QUEUE.map((entry) => JSON.stringify(entry)).join("\n"),
    );
  }
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
  const storage = new Storage(dir);
  storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
  const workspace = storage.createWorkspace({ name: "Crew board", hostMount: dir });
  const session = createDurableSession(storage, "Lead session");
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  if (options.child) {
    // A worker this lead launched: a Session row whose launch edge names the lead, in its store.
    const child = storage.createSession("builder", "faux/faux-1");
    child.serverDurable = {
      storeId: session.id,
      conversationId: 9_000_001,
    };
    child.launch = { status: "created", requestedAt: Date.now(), parentSessionId: session.id };
    child.status = "busy";
    child.lastMessage = "Building the parser";
    child.lastActivity = Date.now() - 2 * 60_000;
    storage.saveSession(child);
  }
  return { dir, storage, workspace, session, manager };
}

interface ObservedFrame {
  message: ServerMessage;
  audience?: ExtensionUISurfaceAudience;
}

function observe(manager: SessionManager, sessionId: string) {
  const frames: ObservedFrame[] = [];
  const pending = new Set<{
    predicate: (frame: ObservedFrame) => boolean;
    resolve: (frame: ObservedFrame) => void;
  }>();
  const unsubscribe = manager.subscribe(sessionId, (message, audience) => {
    const frame = { message, audience };
    frames.push(frame);
    for (const waiter of pending) {
      if (waiter.predicate(frame)) {
        pending.delete(waiter);
        waiter.resolve(frame);
      }
    }
  });
  return {
    frames,
    unsubscribe,
    messages: (type: ServerMessage["type"]) =>
      frames.filter((frame) => frame.message.type === type).map((frame) => frame.message),
    next(predicate: (frame: ObservedFrame) => boolean, timeoutMs = 20_000): Promise<ObservedFrame> {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(waiter);
          reject(
            new Error(
              `Expected a session frame; observed ${frames
                .map((frame) => `${frame.message.type}@${frame.audience ?? "-"}`)
                .join(",")}`,
            ),
          );
        }, timeoutMs);
        const waiter = {
          predicate,
          resolve: (frame: ObservedFrame) => {
            clearTimeout(timer);
            resolve(frame);
          },
        };
        pending.add(waiter);
      });
    },
  };
}

/** The handler a session stream's socket uses: the server's own surface wiring, without a socket. */
function socketHandler(manager: SessionManager, session: Session) {
  const handler = new WsMessageHandler({
    sessions: manager,
    ensureSessionContextWindow: (target) => target,
    getModelCatalog: () => [],
    surfaces: {
      canAct: (sessionId) => manager.canActOnSurface(sessionId),
      act: (sessionId, message, clientId) => manager.actOnSurface(sessionId, message, clientId),
      declare: (sessionId, clientId, capabilities) =>
        manager.declareSurfaceCapabilities(sessionId, clientId, capabilities),
    },
  });
  return async (message: ClientMessage, connId: string) => {
    const sent: ServerMessage[] = [];
    await handler.handleClientMessage(session, message, (frame) => sent.push(frame), { connId });
    return sent;
  };
}

type SurfaceFrame = Extract<ServerMessage, { type: "extension_ui_surface" }>;
type ProjectionFrame = Extract<ServerMessage, { type: "extension_ui_notification" }>;

describe("crew board on the session stream", () => {
  it("publishes the crew and the queue, answers a tap, and clears with the session", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage([fauxToolCall("crew_board", {})], { stopReason: "toolUse" }),
        fauxAssistantMessage("BOARD_UP"),
      ],
      { child: true },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);

    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await f.manager.sendPrompt(f.session.id, "Show the crew board");
    const surface = (await published).message as SurfaceFrame;
    expect(surface.surface.id).toBe("crew-board");
    expect(surface.surface.placement).toEqual({ kind: "strip" });
    expect(surface.sessionId).toBe(f.session.id);
    expect(surface.surface.header).toMatchObject({
      title: "Crew · 1 working",
      subtitle: "1 worker · queue: 1 ready",
    });

    const [workers, queue, actions] = surface.surface.sections;
    if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
    expect(workers.rows).toHaveLength(1);
    expect(workers.rows[0]?.cells).toMatchObject({
      name: "builder",
      status: "busy",
      worktree: "—",
      activity: "2m ago",
      latest: "Building the parser",
    });
    expect(workers.rows[0]?.actions).toEqual(["stop"]);
    if (queue?.composite !== "checklist") throw new Error("queue is not a checklist");
    expect(queue.items.map((item) => [item.title, item.state])).toEqual([
      ["1 ready", "success"],
      ["1 blocked", "warning"],
      ["1 conflict", "error"],
      ["0 failed", "inactive"],
    ]);
    if (actions?.composite !== "actionBar") throw new Error("actions is not a bar");
    expect(actions.actions).toEqual(["refresh"]);

    // The v1 client is handed the same surface projected: the grid, then the queue's words.
    const projection = observed.frames
      .filter((frame) => frame.audience === "v1-projection")
      .map((frame) => frame.message)
      .filter((message): message is ProjectionFrame => message.type === "extension_ui_notification")
      .find((message) => message.widgetKey === "surface:crew-board");
    expect(projection?.nativeSurface?.blocks[0]).toMatchObject({
      type: "table",
      rows: [["builder", "busy", "—", "2m ago", "Building the parser"]],
    });
    expect(projection?.nativeSurface?.fallback?.text).toContain(
      "builder — busy — Building the parser",
    );
    expect(projection?.nativeSurface?.fallback?.text).toContain(
      "Land queue: ready 1, blocked 1, conflict 1, failed 0.",
    );
    // A phone that draws composites is sent the live surface when it says so.
    const tap = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    const declared = await tap(
      { type: "client_capabilities", capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY] },
      "phone-1",
    );
    expect(declared.map((frame) => frame.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
    ]);

    // Refresh re-reads and publishes the board again.
    const refreshed = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_surface" &&
        (frame.message as SurfaceFrame).surface.revision > surface.surface.revision,
    );
    await tap(
      {
        type: "extension_ui_action",
        surfaceId: "crew-board",
        compositeId: "actions",
        actionId: "refresh",
        revision: surface.surface.revision,
        requestId: "tap-refresh",
      },
      "phone-1",
    );
    const again = (await refreshed).message as SurfaceFrame;
    expect(again.surface.header.title).toBe("Crew · 1 working");

    // The Session ends with the board up: the clients watching are told it is gone.
    const removed = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_patch" &&
        frame.message.removed === true &&
        frame.audience === "composites",
    );
    await f.manager.stopSession(f.session.id);
    expect((await removed).message).toMatchObject({ surfaceId: "crew-board", removed: true });
    expect(f.manager.getSurfaceMessages(f.session.id, "phone-1")).toEqual([]);
  }, 60_000);

  it("says what it found when the session has no workers and the workspace no queue", async () => {
    const f = await fixture(
      [
        fauxAssistantMessage([fauxToolCall("crew_board", {})], { stopReason: "toolUse" }),
        fauxAssistantMessage("BOARD_UP"),
      ],
      { queue: false },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    const ran = observed.next((frame) => frame.message.type === "tool_end");
    await f.manager.sendPrompt(f.session.id, "Show the crew board");
    const surface = (await published).message as SurfaceFrame;
    expect(surface.surface.header).toMatchObject({
      title: "Crew · 0 working",
      subtitle: "no workers · queue: none",
    });
    const [workers, queue] = surface.surface.sections;
    expect(workers?.state).toMatchObject({ kind: "empty", title: "No workers" });
    expect(queue?.state).toMatchObject({ kind: "empty", title: "No land queue" });
    expect(surface.surface.fallback.text).toBe("No workers.\nLand queue: none.");

    // The model reads the same summary in the tool's own result.
    await ran;
    const history = (await f.manager.runCommand(f.session.id, { type: "get_messages" })) as Array<{
      toolName?: string;
      content?: unknown;
    }>;
    expect(JSON.stringify(history)).toContain("Crew board: 0 workers, 0 working");
  }, 60_000);
});

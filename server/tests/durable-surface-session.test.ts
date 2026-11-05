import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import {
  EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
  EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
} from "../src/extension-ui-contract.js";
import type { ExtensionUISurfaceAudience } from "../src/extension-surface-runtime.js";
import { DurableUI, type UINotification } from "../src/durable-ui.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import { WsMessageHandler } from "../src/ws-message-handler.js";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
let agentDir: string;

beforeEach(() => {
  agentDir = makeTempDir("oppi-durable-surface-agent-");
  process.env.PI_CODING_AGENT_DIR = agentDir;
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

/**
 * A durable plugin in the owner's plugin root: one tool that publishes a status card through
 * `oppiHost().surfaces(env)`, and the two actions its card offers. Test data, never shipped.
 */
const SURFACE_PLUGIN = [
  'import { obj } from "oppi/v1/schema";',
  "import {",
  "  Extensions,",
  "  defineExtension,",
  "  defineFacet,",
  "  defineTool,",
  "  oppiHost,",
  "  statusCard,",
  "  surface,",
  '} from "oppi/v1";',
  "const panel = surface({",
  '  id: "deploy",',
  '  title: "Deploys",',
  '  actions: { retry: { title: "Retry", role: "primary" }, drop: { title: "Drop" } },',
  "  view: (state) => ({",
  '    header: { title: "web → prod" },',
  "    sections: [",
  "      statusCard({",
  '        id: "status",',
  "        header: { title: `Deploy ${state.phase}` },",
  "        phase: state.phase,",
  '        actions: ["retry", "drop"],',
  "        fallback: `Deploy ${state.phase}`,",
  "      }),",
  "    ],",
  "  }),",
  "});",
  'panel.action("retry", () => ({ patch: { "sections.0.phase": "success" } }));',
  'panel.action("drop", (_state, invocation) => {',
  "  panel.end(invocation.ctx);",
  "  return { patch: {} };",
  "});",
  "const extension = defineExtension({",
  '  name: "surface-probe",',
  '  runtimes: ["host"],',
  "  tools: [",
  "    defineTool({",
  '      name: "surface_probe",',
  '      description: "Publish a deploy panel.",',
  "      parameters: obj({}),",
  "      async execute(_args, api) {",
  "        const surfaces = oppiHost().surfaces(api.env);",
  '        if (!surfaces) return { output: [{ type: "text", text: "no surface loop" }] };',
  '        panel.publish({ surfaces }, { phase: "running" });',
  '        return { output: [{ type: "text", text: "published" }] };',
  "      },",
  "    }),",
  "  ],",
  "});",
  "export default defineFacet((_host, self) => self.contribute(Extensions, extension));",
  "",
].join("\n");

function writeSurfacePlugin(): void {
  const root = join(agentDir, "plugins", "surface-probe");
  mkdirSync(root, { recursive: true });
  writeFileSync(join(root, "package.json"), JSON.stringify({ name: "surface-probe" }));
  writeFileSync(join(root, "server.ts"), SURFACE_PLUGIN);
}

function createDurableSession(storage: Storage, name: string): Session {
  const session = storage.createSession(name, "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  storage.saveSession(session);
  return session;
}

async function fixture(responses: FauxResponseStep[]) {
  writeSurfacePlugin();
  const dir = makeTempDir("oppi-durable-surface-");
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
  const workspace = storage.createWorkspace({ name: "Surface proof", hostMount: dir });
  const session = createDurableSession(storage, "Surface proof");
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  return { dir, models, faux, storage, workspace, session, manager };
}

/** One frame of the session stream, with the shape it was built for. */
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
    next(predicate: (frame: ObservedFrame) => boolean): Promise<ObservedFrame> {
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
        }, 10_000);
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
function socketHandler(
  manager: SessionManager,
  session: Session,
): (message: ClientMessage, connId: string) => Promise<ServerMessage[]> {
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
  return async (message, connId) => {
    const sent: ServerMessage[] = [];
    await handler.handleClientMessage(session, message, (frame) => sent.push(frame), { connId });
    return sent;
  };
}

describe("durable plugin surfaces on the session stream", () => {
  it("carries a plugin's surface to clients, answers its actions, and clears it at the end", async () => {
    const f = await fixture([
      fauxAssistantMessage([fauxToolCall("surface_probe", {})], { stopReason: "toolUse" }),
      fauxAssistantMessage("PANEL_PUBLISHED"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);

    // The port `oppiHost().surfaces(env)` returns for this session's conversation.
    expect(f.manager.surfacePublisherFor(f.session.id)).toBeDefined();

    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    const ran = observed.next((frame) => frame.message.type === "tool_end");
    await f.manager.sendPrompt(f.session.id, "Publish the deploy panel");
    const surfaceFrame = (await published).message as Extract<
      ServerMessage,
      { type: "extension_ui_surface" }
    >;
    expect(surfaceFrame.surface.id).toBe("deploy");
    expect(surfaceFrame.sessionId).toBe(f.session.id);
    expect(surfaceFrame.surface.sections[0]).toMatchObject({ id: "status", phase: "running" });
    // The clients without the capability are sent the widget projection of the same surface.
    expect(
      observed.frames
        .filter((frame) => frame.audience === "v1-projection")
        .map((frame) => frame.message)
        .filter((message) => message.type === "extension_ui_notification"),
    ).toEqual([expect.objectContaining({ widgetKey: "surface:deploy", method: "setWidget" })]);

    // The tool's result is the plugin's own: it reached the loop.
    await ran;
    const history = (await f.manager.runCommand(f.session.id, {
      type: "get_messages",
    })) as Array<{ role: string; toolName?: string; content?: unknown }>;
    expect(
      history.filter((message) => message.role === "toolResult" || message.toolName),
    ).toContainEqual(expect.objectContaining({ toolName: "surface_probe" }));
    expect(JSON.stringify(history)).toContain("published");

    const session = f.manager.getActiveSession(f.session.id)!;
    const tap = socketHandler(f.manager, session);
    // What a phone says when it connects: it draws composites, so it is sent the live surface
    // and the projection it was handed at subscribe cleared.
    const declared = await tap(
      { type: "client_capabilities", capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY] },
      "phone-1",
    );
    expect(declared.map((frame) => frame.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
    ]);
    // A declaration that asks for an answer gets one, after the frames it reconciled.
    expect(
      await tap(
        {
          type: "client_capabilities",
          capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY],
          requestId: "capabilities-1",
        },
        "phone-1",
      ),
    ).toEqual([
      {
        type: "command_result",
        command: "client_capabilities",
        requestId: "capabilities-1",
        success: true,
      },
    ]);
    expect(f.manager.surfaceAudience(f.session.id, "phone-1")).toBe("composites");
    expect(f.manager.surfaceAudience(f.session.id, "phone-2")).toBe("v1-projection");
    expect(session.id).toBe(f.session.id);

    // A tap runs the panel's handler and patches the card.
    const patch = observed.next(
      (frame) => frame.message.type === "extension_ui_patch" && frame.audience === "composites",
    );
    const settledForTap = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_settled" &&
        (frame.message as Extract<ServerMessage, { type: "extension_ui_settled" }>).id === "tap-1",
    );
    const answered = await tap(
      {
        type: "extension_ui_action",
        surfaceId: "deploy",
        compositeId: "status",
        actionId: "retry",
        revision: surfaceFrame.surface.revision,
        requestId: "tap-1",
      },
      "phone-1",
    );
    // The runtime answers on the session stream, so the tap itself returns nothing to send: the
    // socket takes its next message while the panel's work runs, and the round trip ends here.
    expect(answered).toEqual([]);
    const patchFrame = (await patch).message as Extract<
      ServerMessage,
      { type: "extension_ui_patch" }
    >;
    expect(patchFrame).toMatchObject({
      surfaceId: "deploy",
      patch: { "sections.0.phase": "success" },
    });
    expect((await settledForTap).message).toMatchObject({
      type: "extension_ui_settled",
      id: "tap-1",
    });

    // A client that only draws v1 cannot tap the card it never drew: the tap ends on its round
    // trip and the card that offered the action is unchanged.
    const patches = observed.messages("extension_ui_patch").length;
    const settledForV1 = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_settled" &&
        (frame.message as Extract<ServerMessage, { type: "extension_ui_settled" }>).id === "tap-v1",
    );
    await tap(
      {
        type: "extension_ui_action",
        surfaceId: "deploy",
        compositeId: "status",
        actionId: "retry",
        revision: patchFrame.revision,
        requestId: "tap-v1",
      },
      "phone-2",
    );
    // The tap ends on its round trip, in the shape the client draws, and changes nothing.
    expect((await settledForV1).audience).toBe("v1-projection");
    expect(observed.messages("extension_ui_patch").length).toBe(patches);

    // The panel's own `end` leaves the surface, and the last client draws nothing.
    const removed = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_patch" &&
        frame.message.removed === true &&
        frame.audience === "composites",
    );
    await tap(
      {
        type: "extension_ui_action",
        surfaceId: "deploy",
        compositeId: "status",
        actionId: "drop",
        revision: patchFrame.revision,
        requestId: "tap-2",
      },
      "phone-1",
    );
    expect((await removed).message).toMatchObject({ surfaceId: "deploy", removed: true });
    expect(f.manager.getSurfaceMessages(f.session.id, "late-phone")).toEqual([]);
  }, 30_000);

  it("replays a live surface to a client that subscribes later, and clears it when the session ends", async () => {
    const f = await fixture([
      fauxAssistantMessage([fauxToolCall("surface_probe", {})], { stopReason: "toolUse" }),
      fauxAssistantMessage("PANEL_PUBLISHED"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const observed = observe(f.manager, f.session.id);

    // A session that never published has no loop: a tap is answered where it arrives, and a
    // declaration has nothing to replay.
    expect(f.manager.getSurfaceMessages(f.session.id, "phone-1")).toEqual([]);
    expect(
      f.manager.declareSurfaceCapabilities(f.session.id, "phone-1", [
        EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
      ]),
    ).toEqual([]);
    const idle = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    expect(
      await idle(
        {
          type: "extension_ui_action",
          surfaceId: "deploy",
          compositeId: "status",
          actionId: "retry",
          revision: 1,
          requestId: "tap-early",
        },
        "phone-1",
      ),
    ).toEqual([
      { type: "error", error: "Unknown extension surface: deploy" },
      { type: "extension_ui_settled", id: "tap-early", sessionId: f.session.id },
    ]);

    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await f.manager.sendPrompt(f.session.id, "Publish the deploy panel");
    await published;

    // Subscribe happens again: this client draws v1, so it is handed the projection.
    expect(f.manager.getSurfaceMessages(f.session.id, "late-phone")).toEqual([
      expect.objectContaining({ type: "extension_ui_notification", widgetKey: "surface:deploy" }),
    ]);
    // A socket says it draws composites and is handed the surface itself.
    const frames = f.manager.declareSurfaceCapabilities(f.session.id, "late-phone-2", [
      EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
    ]);
    expect(frames.map((frame) => frame.type)).toEqual([
      "extension_ui_notification",
      "extension_ui_surface",
    ]);

    // The session ends with the surface still up: the clients watching are told it is gone
    // before the session's own end, so nothing keeps drawing a card no loop can answer.
    const removed = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_patch" &&
        frame.message.removed === true &&
        frame.audience === "composites",
    );
    await f.manager.stopSession(f.session.id);
    expect((await removed).message).toMatchObject({ surfaceId: "deploy", removed: true });
    expect(f.manager.getSurfaceMessages(f.session.id, "late-phone")).toEqual([]);
    expect(f.manager.surfacePublisherFor(f.session.id)).toBeUndefined();
  });
});

/**
 * The built-in background-jobs plugin on the same stream: a real shell job, the panel its runner
 * publishes, and the Stop a phone taps. Nothing here fakes the host: the process is a real `sleep`.
 */
describe("background jobs on their panel", () => {
  type SurfaceFrame = Extract<ServerMessage, { type: "extension_ui_surface" }>;
  type Surface = SurfaceFrame["surface"];
  type Node = { id?: string; children?: Node[]; text?: string; action?: unknown };

  const PANEL = "background-jobs";

  /** The panel as a phone that draws blocks receives it. */
  const isPanel = (frame: ObservedFrame): boolean =>
    frame.message.type === "extension_ui_surface" &&
    (frame.message as SurfaceFrame).surface.id === PANEL &&
    frame.audience === "blocks";

  const surfaceOf = (frame: ObservedFrame): Surface => (frame.message as SurfaceFrame).surface;

  function find(surface: Surface, id: string): Node | undefined {
    const section = surface.sections[0] as unknown as { body: Node };
    const visit = (node: Node): Node | undefined => {
      if (node.id === id) return node;
      for (const child of node.children ?? []) {
        const found = visit(child);
        if (found) return found;
      }
      return undefined;
    };
    return visit(section.body);
  }

  async function until(predicate: () => boolean, label: string): Promise<void> {
    const deadline = Date.now() + 10_000;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error(`Timed out waiting for ${label}`);
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  /** Waits for the model's answer to the job's result: the report woke it and it replied. */
  async function answered(f: Awaited<ReturnType<typeof fixture>>, text: string): Promise<void> {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const history = await f.manager.runCommand(f.session.id, { type: "get_messages" });
      if (JSON.stringify(history).includes(text)) return;
      if (Date.now() > deadline) throw new Error(`The model never answered with ${text}`);
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  function alive(pid: number): boolean {
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  }

  async function phone(f: Awaited<ReturnType<typeof fixture>>) {
    await f.manager.startSession(f.session.id, f.workspace);
    const tap = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    await tap(
      {
        type: "client_capabilities",
        capabilities: [
          EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
          EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
        ],
      },
      "phone-1",
    );
    return tap;
  }

  it("offers Stop on a running job, kills it on a tap, and clears once the result is delivered", async () => {
    const pidFile = join(makeTempDir("oppi-jobs-panel-"), "job.pid");
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxToolCall("background_job", {
            action: "start",
            command: `echo $$ > '${pidFile}' && exec sleep 300`,
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      fauxAssistantMessage("STOP_NOTED"),
    ]);
    const tap = await phone(f);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next(isPanel);
    await f.manager.sendPrompt(f.session.id, "Start the job");
    const panel = surfaceOf(await published);

    // One running job: its row offers Stop, and nothing else is offered.
    expect(panel.header.title).toBe("1 job");
    expect(find(panel, "stop:bash-1")).toMatchObject({
      type: "button",
      action: { id: "stop", values: { job: "bash-1" } },
    });
    expect(panel.actions.stop).toMatchObject({ title: "Stop", pending: { title: "Stopping…" } });
    expect(Object.keys(panel.actions)).toEqual(["stop"]);
    // The clients without composites are sent the same panel's v1 projection.
    expect(
      observed
        .messages("extension_ui_notification")
        .filter((message) => (message as { widgetKey?: string }).widgetKey?.endsWith(PANEL)),
    ).not.toHaveLength(0);

    await until(
      () => existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "",
      "the job",
    );
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(alive(pid)).toBe(true);

    const removed = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_patch" &&
        frame.message.surfaceId === PANEL &&
        frame.message.removed === true,
    );
    const settledTap = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_settled" &&
        (frame.message as Extract<ServerMessage, { type: "extension_ui_settled" }>).id === "stop-1",
    );
    await tap(
      {
        type: "extension_ui_action",
        surfaceId: PANEL,
        compositeId: "jobs",
        actionId: "stop",
        nodeId: "stop:bash-1",
        values: { job: "bash-1" },
        revision: panel.revision,
        requestId: "stop-1",
      },
      "phone-1",
    );

    await settledTap;
    // The process is gone, not just the row.
    await until(() => !alive(pid), "the process to die");
    // The result reaches the model as one follow-up, which clears the panel.
    await removed;
    expect(f.manager.getSurfaceMessages(f.session.id, "phone-1")).toEqual([]);
    // The model was woken by the cancellation's report and answered it.
    await answered(f, "STOP_NOTED");
  }, 30_000);

  it("draws the panel into a Session that restarts while the job runs, and Stop still kills it", async () => {
    const pidFile = join(makeTempDir("oppi-jobs-restart-"), "job.pid");
    const f = await fixture([
      fauxAssistantMessage(
        [
          fauxToolCall("background_job", {
            action: "start",
            command: `echo $$ > '${pidFile}' && exec sleep 300`,
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      fauxAssistantMessage("STOP_NOTED"),
    ]);
    await phone(f);
    const first = observe(f.manager, f.session.id);
    const published = first.next(isPanel);
    await f.manager.sendPrompt(f.session.id, "Start the job");
    await published;
    await until(
      () => existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "",
      "the job",
    );
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    const before = f.manager.surfacePublisherFor(f.session.id);

    // The Session stops and starts again; a stopped Session leaves its job running.
    await f.manager.stopSession(f.session.id);
    expect(alive(pid)).toBe(true);
    const tap = await phone(f);
    expect(f.manager.surfacePublisherFor(f.session.id)).not.toBe(before);
    const observed = observe(f.manager, f.session.id);

    // The new Session's loop gets the panel without any job changing: a client that connects
    // reads it from the live surfaces.
    const drawn = (): Surface | undefined =>
      f.manager
        .getSurfaceMessages(f.session.id, "phone-1")
        .flatMap((message) => (message.type === "extension_ui_surface" ? [message.surface] : []))
        .find((surface) => surface.id === PANEL);
    await until(() => drawn() !== undefined, "the panel in the new Session");
    const panel = drawn()!;
    expect(panel.header.title).toBe("1 job");
    expect(find(panel, "stop:bash-1")).toBeDefined();

    const removed = observed.next(
      (frame) =>
        frame.message.type === "extension_ui_patch" &&
        frame.message.surfaceId === PANEL &&
        frame.message.removed === true,
    );
    await tap(
      {
        type: "extension_ui_action",
        surfaceId: PANEL,
        compositeId: "jobs",
        actionId: "stop",
        nodeId: "stop:bash-1",
        values: { job: "bash-1" },
        revision: panel.revision,
        requestId: "stop-restart",
      },
      "phone-1",
    );
    await until(() => !alive(pid), "the process to die");
    await removed;
  }, 30_000);
});

/**
 * Conversations saved by 0.54.0 hold the pill and the Data widget in their `DurableUI` document,
 * and a client replays that document when it attaches. The plugins clear those slots the next time
 * they write for the conversation; this seeds the stored entries and reads what a client attaching
 * afterwards is sent.
 */
describe("slots stored before the panel and the tool rows", () => {
  type Held = Extract<ServerMessage, { type: "extension_ui_notification" }>;

  /** What 0.54.0 stored: a pill with a status and a native widget, and the Data widget. */
  const STORED: Record<string, UINotification> = {
    "status:background-jobs": {
      id: "background-jobs:status",
      method: "setStatus",
      statusKey: "background-jobs",
      statusText: "1 job · 12s",
      extensionScopeId: "repo:background-jobs",
      extensionDisplayName: "Background Jobs",
    },
    "widget:background-jobs": {
      id: "background-jobs:widget",
      method: "setWidget",
      widgetKey: "background-jobs",
      widgetLines: ["1 job"],
      nativeSurface: {
        version: 1,
        id: "widget:background-jobs",
        source: "widget",
        presentation: { style: "surfacePanel", title: "1 job", subtitle: "sleep 300" },
        blocks: [{ type: "activityList", id: "jobs", rows: [] }],
        fallback: { lines: ["1 job"] },
      },
      extensionScopeId: "repo:background-jobs",
      extensionDisplayName: "Background Jobs",
    },
    "widget:data": {
      id: "sql-explorer:data",
      method: "setWidget",
      widgetKey: "data",
      widgetLines: ["sales.db", "3 rows"],
      nativeSurface: {
        version: 1,
        id: "widget:data",
        source: "widget",
        presentation: { style: "surfacePanel", title: "sales.db", subtitle: "3 rows" },
        blocks: [{ type: "table", id: "result", columns: ["name"], rows: [["apples"]] }],
        fallback: { lines: ["sales.db"] },
      },
      extensionScopeId: "repo:sql-explorer",
      extensionDisplayName: "Data",
    },
  };

  async function seed(f: Awaited<ReturnType<typeof fixture>>): Promise<void> {
    const runtime = await (
      f.manager as unknown as {
        durableHarness: Promise<{
          host(id: string): { open(): Promise<{ harness: Harness }> } | undefined;
        }>;
      }
    ).durableHarness;
    const { harness } = await runtime.host(f.session.id)!.open();
    const id = f.storage.getSession(f.session.id)!.serverDurable!.conversationId as ConversationId;
    const conversation = (await harness.conversation(id, context))!;
    await conversation.commit(async (tx) => {
      Object.assign((await tx.doc(DurableUI, id)).notifications, structuredClone(STORED));
    }, context);
  }

  /** The slots a client that attaches now is told to draw, by their key. */
  function drawn(f: Awaited<ReturnType<typeof fixture>>): string[] {
    return f.manager
      .getPendingUIRequestMessages(f.session.id)
      .filter((message): message is Held => message.type === "extension_ui_notification")
      .filter(
        (message) =>
          message.statusText ||
          message.nativeSurface ||
          message.widgetLines?.some((line) => line.length > 0),
      )
      .map((message) => message.statusKey ?? message.widgetKey ?? "")
      .sort();
  }

  async function sessionWithStoredSlots(responses: FauxResponseStep[]) {
    const f = await fixture(responses);
    await f.manager.startSession(f.session.id, f.workspace);
    await seed(f);
    await until(() => drawn(f).length === 3, "the stored slots to reach a client");
    expect(drawn(f)).toEqual(["background-jobs", "background-jobs", "data"]);
    return f;
  }

  async function until(predicate: () => boolean, label: string): Promise<void> {
    const deadline = Date.now() + 10_000;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error(`Timed out waiting for ${label}`);
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }

  it("clears the stored pill when the background jobs plugin next writes for the conversation", async () => {
    const f = await sessionWithStoredSlots([
      fauxAssistantMessage(
        [fauxToolCall("background_job", { action: "start", command: "sleep 1" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      fauxAssistantMessage("DONE"),
    ]);
    await f.manager.sendPrompt(f.session.id, "Start the job");
    // Only the Data widget is left: the pill is gone from what a client attaching now is sent.
    await until(() => drawn(f).join() === "data", "the pill to be cleared");
  }, 30_000);

  it("clears the stored Data widget when sqlite_query next runs", async () => {
    const db = join(makeTempDir("oppi-stored-data-"), "sales.db");
    const sqlite = new DatabaseSync(db);
    sqlite.exec("CREATE TABLE sales (name TEXT); INSERT INTO sales VALUES ('apples')");
    sqlite.close();
    const f = await sessionWithStoredSlots([
      fauxAssistantMessage(
        [fauxToolCall("sqlite_query", { path: db, sql: "SELECT name FROM sales" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("QUERIED"),
    ]);
    await f.manager.sendPrompt(f.session.id, "Query the database");
    await until(() => !drawn(f).includes("data"), "the Data widget to be cleared");
    // The query's rows are the tool result, not a widget.
    expect(drawn(f)).toEqual(["background-jobs", "background-jobs"]);
  }, 30_000);
});

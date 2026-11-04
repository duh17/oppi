import { mkdirSync, writeFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
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
import { EXTENSION_UI_SURFACE_MAX_BYTES } from "../src/extension-surface.js";
import type { ExtensionUISurfaceAudience } from "../src/extension-surface-runtime.js";
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
 * The built-in sql-explorer, on the same session stream: it is one of the extensions a workspace
 * session selects, so its tools publish into the session's own surface loop.
 */
describe("sql-explorer on its results surface", () => {
  type SurfaceFrame = Extract<ServerMessage, { type: "extension_ui_surface" }>;
  type NotificationFrame = Extract<ServerMessage, { type: "extension_ui_notification" }>;
  type WidgetFrame = Extract<ServerMessage, { type: "extension_ui_request" }>;
  type RowsSection = Extract<
    SurfaceFrame["surface"]["sections"][number],
    { composite: "dataTable" }
  >;

  function surfaceOf(frame: ObservedFrame): SurfaceFrame["surface"] {
    return (frame.message as SurfaceFrame).surface;
  }

  /** The rows section of a published panel: the file's rows, or the words that replaced them. */
  function rowsOf(surface: SurfaceFrame["surface"]): RowsSection {
    return surface.sections[0] as RowsSection;
  }

  /** A surface is drawn on the wire, so its own JSON bytes are what the host caps. */
  function surfaceBytes(surface: SurfaceFrame["surface"]): number {
    return Buffer.byteLength(JSON.stringify(surface), "utf8");
  }

  function nextSurface(observed: ReturnType<typeof observe>, after: number) {
    return observed.next(
      (frame) =>
        frame.message.type === "extension_ui_surface" &&
        (frame.message as SurfaceFrame).surface.revision > after,
    );
  }

  function seed(path: string, extraRows = 0): void {
    const db = new DatabaseSync(path);
    db.exec(`
      CREATE TABLE sales (name TEXT, amount INTEGER);
      INSERT INTO sales VALUES ('apples', 12), ('bananas', 9), ('cherries', 4);
    `);
    if (extraRows > 0) {
      db.exec("BEGIN");
      for (let index = 0; index < extraRows; index += 1) {
        db.exec(`INSERT INTO sales VALUES ('row-${index}', ${index})`);
      }
      db.exec("COMMIT");
    }
    db.close();
  }

  /** Wide numeric rows: the surface's own column cap, at a width whose JSON bytes add up. */
  function seedWide(path: string, count: number, columns: number): void {
    const db = new DatabaseSync(path);
    const names = Array.from({ length: columns }, (_, index) => `c${index}`);
    db.exec(`CREATE TABLE wide (${names.map((name) => `${name} INTEGER`).join(", ")})`);
    const insert = db.prepare(`INSERT INTO wide VALUES (${names.map(() => "?").join(", ")})`);
    db.exec("BEGIN");
    for (let row = 0; row < count; row += 1) {
      insert.run(...names.map((_, column) => 1_000_000 + row * 100 + column));
    }
    db.exec("COMMIT");
    db.close();
  }

  /** Two text columns at the widget's cell cap: enough characters to fill a card on their own. */
  function seedDocs(path: string, count: number, chars: number): void {
    const db = new DatabaseSync(path);
    db.exec("CREATE TABLE docs (a TEXT, b TEXT)");
    const insert = db.prepare("INSERT INTO docs VALUES (?, ?)");
    db.exec("BEGIN");
    for (let row = 0; row < count; row += 1) insert.run("a".repeat(chars), "b".repeat(chars));
    db.exec("COMMIT");
    db.close();
  }

  async function sqlFixture(responses: FauxResponseStep[]) {
    const f = await fixture(responses);
    await f.manager.startSession(f.session.id, f.workspace);
    return f;
  }

  /** One prompt, run to the end of its turn: the next one needs an idle session. */
  async function prompt(
    f: Awaited<ReturnType<typeof sqlFixture>>,
    observed: ReturnType<typeof observe>,
    text: string,
  ): Promise<void> {
    const settled = observed.next((frame) => frame.message.type === "agent_settled");
    await f.manager.sendPrompt(f.session.id, text);
    await settled;
  }

  async function tap(
    f: Awaited<ReturnType<typeof sqlFixture>>,
    action: {
      compositeId: string;
      actionId: string;
      revision: number;
      rowId?: string;
      requestId: string;
    },
  ): Promise<void> {
    const handler = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    await handler(
      {
        type: "extension_ui_action",
        surfaceId: "sql-explorer",
        compositeId: action.compositeId,
        actionId: action.actionId,
        revision: action.revision,
        requestId: action.requestId,
        ...(action.rowId === undefined ? {} : { rowId: action.rowId }),
      },
      "phone-1",
    );
  }

  /** A phone that draws composites: the audience a tap comes from. */
  async function declareComposites(
    f: Awaited<ReturnType<typeof sqlFixture>>,
  ): Promise<void> {
    const handler = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    await handler(
      { type: "client_capabilities", capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY] },
      "phone-1",
    );
  }

  /** Every tool result the model received, in order. */
  async function toolResults(f: Awaited<ReturnType<typeof sqlFixture>>) {
    const history = (await f.manager.runCommand(f.session.id, {
      type: "get_messages",
    })) as Array<{ role: string; isError?: boolean; content?: unknown }>;
    return history.filter((message) => message.role === "toolResult");
  }

  it("publishes rows, pages them, and runs the query again without a model turn", async () => {
    const db = join(makeTempDir("oppi-sql-surface-"), "sales.db");
    const f = await sqlFixture([
      fauxAssistantMessage(
        [
          fauxToolCall("sqlite_query", {
            path: db,
            sql: "SELECT name, amount FROM sales",
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("QUERIED"),
    ]);
    seed(db, 250);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    const projected = observed.next(
      (frame) =>
        frame.audience === "v1-projection" &&
        (frame.message as NotificationFrame).widgetKey === "surface:sql-explorer",
    );
    const cleared = observed.next(
      (frame) =>
        (frame.message as WidgetFrame).method === "setWidget" &&
        (frame.message as WidgetFrame).widgetKey === "data",
    );
    await prompt(f, observed, "Query the database");

    // A client that draws composites gets the surface: the file, its rows, and what it can do.
    const first = surfaceOf(await published);
    expect(first).toMatchObject({
      version: 2,
      id: "sql-explorer",
      title: "sales.db",
      lifecycle: "persistent",
      placement: { kind: "strip" },
    });
    expect(first.header).toEqual({
      title: "sales.db",
      subtitle: expect.stringMatching(/^200 rows · \d+ms$/),
    });
    expect(first.sections[0]).toMatchObject({
      composite: "dataTable",
      id: "rows",
      state: { kind: "content" },
      columns: [
        { id: "c0", title: "name" },
        { id: "c1", title: "amount", kind: "number" },
      ],
    });
    const rows = first.sections[0] as Extract<
      SurfaceFrame["surface"]["sections"][number],
      { composite: "dataTable" }
    >;
    expect(rows.rows).toHaveLength(200);
    expect(rows.rows[0]).toEqual({ id: "r0", cells: { c0: "apples", c1: "12" } });
    expect(first.sections[1]).toMatchObject({
      composite: "actionBar",
      id: "actions",
      actions: ["runAgain", "next"],
    });

    // A client without the composites capability gets the grid, not a paragraph about it.
    const projection = (await projected).message as NotificationFrame;
    expect(projection.nativeSurface?.presentation).toEqual({
      style: "surfacePanel",
      title: "sales.db",
      subtitle: expect.stringMatching(/^200 rows · \d+ms$/),
    });
    const blocks = (projection.nativeSurface?.blocks ?? []) as Array<{
      type: string;
      id?: string;
      columns?: string[];
      rows?: unknown[][];
      spans?: Array<{ text: string }>;
    }>;
    expect(blocks[0]).toMatchObject({
      type: "table",
      id: "rows",
      columns: ["name", "amount"],
    });
    expect(blocks[0]?.rows).toHaveLength(200);
    expect(blocks[0]?.rows?.[0]).toEqual(["apples", "12"]);
    expect(blocks[1]).toEqual({
      type: "text",
      id: "actions",
      spans: [{ text: "Run again · Next 200 rows" }],
    });
    expect(projection.nativeSurface?.fallback?.text).toContain("apples");
    expect(projection.nativeSurface?.fallback?.text).toContain("200 rows");

    // The panel replaces the old table widget: its slot is emptied, never left beside the surface.
    expect((await cleared).message).toMatchObject({
      method: "setWidget",
      widgetKey: "data",
      widgetLines: [],
    });

    // The model still sees the preview it always did.
    const history = JSON.stringify(
      await f.manager.runCommand(f.session.id, { type: "get_messages" }),
    );
    expect(history).toContain("Result truncated.");

    const handler = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    await handler(
      { type: "client_capabilities", capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY] },
      "phone-1",
    );
    const toolEnds = observed.messages("tool_end").length;

    // "Next 200 rows" reads the next page of the same statement, in the handler.
    const second = nextSurface(observed, first.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "next",
      revision: first.revision,
      requestId: "tap-next",
    });
    const page2 = surfaceOf(await second);
    expect(page2.header.subtitle).toMatch(/^53 rows · \d+ms · from row 201$/);
    expect(page2.sections[0]).toMatchObject({ id: "rows", state: { kind: "content" } });
    expect(
      (
        page2.sections[0] as Extract<
          SurfaceFrame["surface"]["sections"][number],
          { composite: "dataTable" }
        >
      ).rows,
    ).toHaveLength(53);
    expect(page2.sections[1]).toMatchObject({ actions: ["runAgain", "previous"] });

    // "Previous" comes back to the first page: the same rows, no offset in the header.
    const third = nextSurface(observed, page2.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "previous",
      revision: page2.revision,
      requestId: "tap-previous",
    });
    const page1 = surfaceOf(await third);
    expect(page1.header.subtitle).toMatch(/^200 rows · \d+ms$/);
    expect(page1.sections[1]).toMatchObject({ actions: ["runAgain", "next"] });

    // "Run again" is the same read again, and the model was never asked to do it.
    const fourth = nextSurface(observed, page1.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "runAgain",
      revision: page1.revision,
      requestId: "tap-again",
    });
    const again = surfaceOf(await fourth);
    expect(again.header.subtitle).toMatch(/^200 rows · \d+ms$/);
    expect(again.revision).toBeGreaterThan(page1.revision);
    expect(observed.messages("tool_end").length).toBe(toolEnds);
  }, 60_000);

  it("keeps a wide or text-heavy page inside the surface's byte budget", async () => {
    const dir = makeTempDir("oppi-sql-surface-");
    const docs = join(dir, "docs.db");
    const wide = join(dir, "wide.db");
    const f = await sqlFixture([
      fauxAssistantMessage(
        [fauxToolCall("sqlite_query", { path: docs, sql: "SELECT a, b FROM docs" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("DOCS"),
      fauxAssistantMessage([fauxToolCall("sqlite_query", { path: wide, sql: "SELECT * FROM wide" })], {
        stopReason: "toolUse",
      }),
      fauxAssistantMessage("WIDE"),
    ]);
    seedDocs(docs, 200, 200);
    seedWide(wide, 200, 32);
    const observed = observe(f.manager, f.session.id);

    // Two text columns at the cell cap: 80 KiB of text before the panel shortens a cell.
    const first = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await prompt(f, observed, "Query the docs");
    const docsSurface = surfaceOf(await first);
    const docsRows = rowsOf(docsSurface);
    expect(docsRows.rows).toHaveLength(200);
    expect(docsRows.rows[0]?.cells.c0).toMatch(/^a{79}…$/);
    expect(docsSurface.header.subtitle).toMatch(/^200 rows · \d+ms$/);
    expect(docsRows.fallback?.text).toContain("Some values are shortened to fit the panel.");
    expect(surfaceBytes(docsSurface)).toBeLessThanOrEqual(EXTENSION_UI_SURFACE_MAX_BYTES);

    // 32 numeric columns: the rows themselves are what does not fit, so the page loses trailing
    // rows and says how many it left out, while the tool call still returns everything.
    const second = nextSurface(observed, docsSurface.revision);
    await prompt(f, observed, "Query the wide table");
    const wideSurface = surfaceOf(await second);
    const wideRows = rowsOf(wideSurface);
    expect(wideRows.columns).toHaveLength(32);
    expect(wideRows.rows.length).toBeGreaterThan(0);
    expect(wideRows.rows.length).toBeLessThan(200);
    expect(wideSurface.header.subtitle).toMatch(
      new RegExp(`^${wideRows.rows.length} of 200 rows · \\d+ms$`),
    );
    expect(wideRows.fallback?.text).toContain("did not fit the panel");
    expect(surfaceBytes(wideSurface)).toBeLessThanOrEqual(EXTENSION_UI_SURFACE_MAX_BYTES);

    // The query itself succeeded twice: the model has its rows, not a refused surface.
    const results = await toolResults(f);
    expect(results).toHaveLength(2);
    for (const result of results) expect(result.isError).toBeFalsy();
    expect(JSON.stringify(results)).not.toContain("exceeds 65536");
    expect(JSON.stringify(results)).toContain("aaaaaaaaaa");

    // Paging continues after the rows this page showed, so a shortened page skips nothing.
    await declareComposites(f);
    const third = nextSurface(observed, wideSurface.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "next",
      revision: wideSurface.revision,
      requestId: "tap-wide-next",
    });
    const wideNext = surfaceOf(await third);
    expect(wideNext.header.subtitle).toContain(`from row ${wideRows.rows.length + 1}`);
    expect(rowsOf(wideNext).rows[0]?.cells.c0).toBe(
      String(1_000_000 + wideRows.rows.length * 100),
    );
  }, 90_000);

  it("clips a database name to the title cap instead of dropping the card", async () => {
    const name = `${"n".repeat(200)}.db`;
    const db = join(makeTempDir("oppi-sql-surface-"), name);
    const f = await sqlFixture([
      fauxAssistantMessage(
        [fauxToolCall("sqlite_query", { path: db, sql: "SELECT name FROM sales" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("QUERIED"),
    ]);
    seed(db);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await prompt(f, observed, "Query the database");

    // A long file name is the card's title, and a title over the cap would refuse the surface.
    const surface = surfaceOf(await published);
    expect(surface.title).toHaveLength(200);
    expect(surface.title).toMatch(/…$/);
    expect(surface.header.title).toBe(surface.title);
    expect((await toolResults(f))[0]?.isError).toBeFalsy();
  }, 60_000);

  it("pages a statement whose final semicolon is followed by a comment", async () => {
    const db = join(makeTempDir("oppi-sql-surface-"), "sales.db");
    const f = await sqlFixture([
      fauxAssistantMessage(
        [
          fauxToolCall("sqlite_query", {
            path: db,
            sql: "SELECT name, amount FROM sales; -- paid only",
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("QUERIED"),
    ]);
    seed(db, 250);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await prompt(f, observed, "Query the database");
    const first = surfaceOf(await published);
    expect(rowsOf(first).rows).toHaveLength(200);
    expect(first.sections[1]).toMatchObject({ actions: ["runAgain", "next"] });

    await declareComposites(f);
    const second = nextSurface(observed, first.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "next",
      revision: first.revision,
      requestId: "tap-comment-next",
    });
    // The wrapper drops the `;` and the comment: sqlite3 reads a `;` inside its parentheses as
    // the end of the inner query and refuses the rest.
    const page2 = surfaceOf(await second);
    expect(page2.header.subtitle).toMatch(/^53 rows · \d+ms · from row 201$/);
    expect(rowsOf(page2).state).toEqual({ kind: "content" });
    expect(rowsOf(page2).rows).toHaveLength(53);
  }, 60_000);

  it("words a page past the last row as no more rows", async () => {
    const db = join(makeTempDir("oppi-sql-surface-"), "sales.db");
    const f = await sqlFixture([
      fauxAssistantMessage(
        [fauxToolCall("sqlite_query", { path: db, sql: "SELECT name, amount FROM sales" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("QUERIED"),
    ]);
    seed(db, 250);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await prompt(f, observed, "Query the database");
    const first = surfaceOf(await published);
    await declareComposites(f);

    // The card is still up after the table empties under it: the next page is past the end, and
    // that is not the same thing as a query that returned nothing.
    const writer = new DatabaseSync(db);
    try {
      writer.exec("DELETE FROM sales");
    } finally {
      writer.close();
    }
    const second = nextSurface(observed, first.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "next",
      revision: first.revision,
      requestId: "tap-past-end",
    });
    const page2 = surfaceOf(await second);
    expect(rowsOf(page2).state).toEqual({
      kind: "empty",
      title: "No more rows",
      message: "No rows past this point.",
    });
  }, 60_000);

  it("previews a schema object and returns to the schema without a second tool call", async () => {
    const db = join(makeTempDir("oppi-sql-surface-"), "sales.db");
    const f = await sqlFixture([
      fauxAssistantMessage([fauxToolCall("sqlite_schema", { path: db })], {
        stopReason: "toolUse",
      }),
      fauxAssistantMessage("SCHEMA"),
    ]);
    seed(db);
    const observed = observe(f.manager, f.session.id);
    const published = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await prompt(f, observed, "Inspect the schema");

    const schema = surfaceOf(await published);
    expect(schema.header).toEqual({
      title: "sales.db",
      subtitle: expect.stringMatching(/^\d+ rows? · \d+ms$/),
    });
    expect(schema.sections[0]).toMatchObject({
      id: "rows",
      header: { title: "Schema objects" },
      columns: [
        { id: "c0", title: "name" },
        { id: "c1", title: "type" },
        { id: "c2", title: "sql" },
      ],
    });
    // The CREATE statement stays visible: the model is not the only reader of the schema.
    expect(rowsOf(schema).rows[0]).toEqual({
      id: "r0",
      cells: { c0: "sales", c1: "table", c2: "CREATE TABLE sales (name TEXT, amount INTEGER)" },
      actions: ["preview"],
    });
    expect(schema.sections[1]).toMatchObject({ actions: ["runAgain"] });

    const handler = socketHandler(f.manager, f.manager.getActiveSession(f.session.id)!);
    await handler(
      { type: "client_capabilities", capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY] },
      "phone-1",
    );

    const previewFrame = nextSurface(observed, schema.revision);
    await tap(f, {
      compositeId: "rows",
      actionId: "preview",
      rowId: "r0",
      revision: schema.revision,
      requestId: "tap-preview",
    });
    const preview = surfaceOf(await previewFrame);
    expect(preview.header).toEqual({
      title: "sales.db",
      subtitle: expect.stringMatching(/^3 rows · \d+ms$/),
    });
    expect(preview.sections[0]).toMatchObject({
      header: { title: "Results" },
      columns: [
        { id: "c0", title: "name" },
        { id: "c1", title: "amount", kind: "number" },
      ],
    });
    expect(preview.sections[1]).toMatchObject({ actions: ["back", "runAgain"] });

    // "Back to schema" shows the schema the tap came from, with no second read.
    const backFrame = nextSurface(observed, preview.revision);
    await tap(f, {
      compositeId: "actions",
      actionId: "back",
      revision: preview.revision,
      requestId: "tap-back",
    });
    const back = surfaceOf(await backFrame);
    expect(back.sections[0]).toMatchObject({
      header: { title: "Schema objects" },
      rows: [
        {
          id: "r0",
          cells: {
            c0: "sales",
            c1: "table",
            c2: "CREATE TABLE sales (name TEXT, amount INTEGER)",
          },
          actions: ["preview"],
        },
      ],
    });
    expect(back.sections[1]).toMatchObject({ actions: ["runAgain"] });
  }, 60_000);

  it("shows empty and failure states on the surface and keeps the chart a v1 widget", async () => {
    const db = join(makeTempDir("oppi-sql-surface-"), "sales.db");
    const f = await sqlFixture([
      fauxAssistantMessage(
        [
          fauxToolCall("sqlite_query", {
            path: db,
            sql: "SELECT name FROM sales WHERE 0",
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("EMPTY"),
      fauxAssistantMessage(
        [fauxToolCall("sqlite_query", { path: db, sql: "SELECT * FROM missing_table" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("FAILED"),
      fauxAssistantMessage(
        [
          fauxToolCall("sqlite_query", {
            path: db,
            sql: "SELECT name, amount FROM sales",
            chart: { kind: "bar" },
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("CHARTED"),
    ]);
    seed(db);
    const observed = observe(f.manager, f.session.id);

    const emptyFrame = observed.next((frame) => frame.message.type === "extension_ui_surface");
    await prompt(f, observed, "Query nothing");
    const empty = surfaceOf(await emptyFrame);
    expect(empty.sections[0]).toMatchObject({
      id: "rows",
      state: { kind: "empty", title: "No rows", message: "The query returned no rows." },
      rows: [],
    });
    expect(empty.sections[1]).toMatchObject({ actions: ["runAgain"] });

    const failedFrame = nextSurface(observed, empty.revision);
    await prompt(f, observed, "Query a missing table");
    const failed = surfaceOf(await failedFrame);
    expect(failed.header.subtitle).toBe("Query failed");
    expect(failed.sections[0]).toMatchObject({
      id: "rows",
      state: {
        kind: "failure",
        title: "Query failed",
        message: expect.stringContaining("no such table: missing_table"),
      },
    });
    const history = JSON.stringify(
      await f.manager.runCommand(f.session.id, { type: "get_messages" }),
    );
    expect(history).toContain("no such table: missing_table");

    // The chart is still a v1 widget beside the surface: its own slot, no table block.
    const charted = observed.next(
      (frame) =>
        (frame.message as WidgetFrame).method === "setWidget" &&
        (frame.message as WidgetFrame).widgetKey === "data" &&
        (frame.message as WidgetFrame).nativeSurface !== undefined,
    );
    const chartSurface = nextSurface(observed, failed.revision);
    await prompt(f, observed, "Chart the sales");
    const chartedWidget = (await charted).message as WidgetFrame;
    expect(chartedWidget.nativeSurface?.blocks).toEqual([
      {
        type: "chart",
        id: "chart",
        kind: "bar",
        labels: ["apples", "bananas", "cherries"],
        series: [{ name: "amount", values: [12, 9, 4] }],
      },
    ]);
    expect(chartedWidget.nativeSurface?.presentation).toEqual(
      expect.objectContaining({ title: "sales.db" }),
    );
    // Nothing in the surface itself is a chart.
    const chartedSurface = surfaceOf(await chartSurface);
    expect(chartedSurface.sections.map((section) => section.composite)).toEqual([
      "dataTable",
      "actionBar",
    ]);
  }, 90_000);
});

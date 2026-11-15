import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Message } from "@earendil-works/pi-ai";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseFactory,
} from "@earendil-works/pi-ai/providers/faux";
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import { SessionHost } from "../src/durable-harness.js";
import {
  ServerResourceService,
  type ServerExtensionSummary,
} from "../src/server-resource-service.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createServerResourceRoutes } from "../src/routes/server-resources.js";
import type { RouteContext } from "../src/routes/types.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";
import { makeTempDir } from "./harness/temp-dir.js";

// The example plugins Oppi ships off (server/plugins/example-*), driven as the owner would: their
// rows on the extension list turn them on, and a durable session's model calls their tools.

const EXAMPLE_TOOLS = ["example_bookmark_add", "example_bookmark_list", "example_release_notes"];

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
beforeEach(() => {
  // No owner plugins: only Oppi's built-ins load.
  process.env.PI_CODING_AGENT_DIR = makeTempDir("oppi-example-plugins-agent-");
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

function textOf(message: Message | undefined): string {
  if (!message) return "";
  if (typeof message.content === "string") return message.content;
  return message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

/** The model calls the tool a prompt names as JSON (`{ tool, args }`); its result ends the turn. */
const callsPromptedTool: FauxResponseFactory = (transcript) => {
  const last = transcript.messages.findLast((message) => message.role !== "system")!;
  if (last.role === "toolResult") return fauxAssistantMessage("DONE");
  const { tool, args } = JSON.parse(textOf(last)) as { tool: string; args: object };
  return fauxAssistantMessage([fauxToolCall(tool, args)], { stopReason: "toolUse" });
};

async function fixture() {
  const dir = makeTempDir("oppi-example-plugins-test-");
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  faux.setResponses(Array.from({ length: 40 }, () => callsPromptedTool));
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
  const opening = vi.spyOn(SessionHost.prototype, "open");
  let storage = new Storage(dir);
  storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
  const workspace = storage.createWorkspace({ name: "Examples", hostMount: dir });

  let manager!: SessionManager;
  let route!: (
    method: string,
    path: string,
    body?: unknown,
  ) => Promise<{ status: number; body: Record<string, unknown> }>;
  /** A SessionManager over the data dir, as a server (re)start makes one. */
  const start = async (): Promise<void> => {
    manager = new SessionManager(storage);
    managers.push(manager);
    await manager.resumeDurableSessions();
    const serverResources = new ServerResourceService({
      dataDir: dir,
      agentDir: process.env.PI_CODING_AGENT_DIR!,
      plugins: manager,
    });
    const routes = createServerResourceRoutes(
      {
        sessions: manager,
        serverResources,
        refreshModelCatalog: async () => undefined,
      } as unknown as RouteContext,
      createRouteHelpers(),
    );
    route = async (method, path, body) => {
      const res = makeResponse();
      const req = makeRequest(body);
      if (body !== undefined) req.headers = { "content-type": "application/json" };
      const url = new URL(`http://localhost${path}`);
      expect(await routes({ method, path: url.pathname, url, req, res })).toBe(true);
      return { status: res.statusCode, body: JSON.parse(res.body) as Record<string, unknown> };
    };
  };
  await start();

  const f = {
    dir,
    workspace,
    get storage(): Storage {
      return storage;
    },
    get manager(): SessionManager {
      return manager;
    },
    /** Stop the server and start a new one over the same data dir. */
    async restart(): Promise<void> {
      await manager.close();
      managers.splice(managers.indexOf(manager), 1);
      storage = new Storage(dir);
      await start();
    },
    /** A durable session in `ws`, started. */
    async session(name: string, ws: Workspace = workspace): Promise<Session> {
      const session = storage.createSession(name, "faux/faux-1");
      session.serverDurable = { storeId: session.id };
      session.workspaceId = ws.id;
      storage.saveSession(session);
      await manager.startSession(session.id, ws);
      return session;
    },
    /** The Harness of `session`'s store, as last opened. */
    async harness(session: Session): Promise<Harness> {
      const index = opening.mock.contexts.findLastIndex((host) => host.storeId === session.id);
      return (await opening.mock.results[index]!.value).harness;
    },
    conversation(session: Session): ConversationId {
      return storage.getSession(session.id)!.serverDurable!.conversationId as ConversationId;
    },
    /** The example tools `session`'s agent offers now. */
    async offered(session: Session): Promise<string[]> {
      const conversation = await (
        await f.harness(session)
      ).conversation(f.conversation(session), context);
      return (await conversation!.agent(context)).tools
        .map((tool) => tool.name)
        .filter((name) => EXAMPLE_TOOLS.includes(name));
    },
    async reattach(session: Session): Promise<void> {
      await manager.stopSession(session.id);
      await manager.startSession(session.id, workspace);
    },
    /** One turn whose model calls `tool` with `args`; resolves to that call's result. */
    async call(session: Session, tool: string, args: object = {}) {
      const ended = new Promise<void>((resolve) => {
        const unsubscribe = manager.subscribe(session.id, (message: ServerMessage) => {
          if (message.type !== "agent_end") return;
          unsubscribe();
          resolve();
        });
      });
      await manager.sendPrompt(session.id, JSON.stringify({ tool, args }));
      await ended;
      const page = await (await (
        await f.harness(session)
      ).conversation(f.conversation(session), context))!.entries({}, 200, undefined, context);
      const result = page.items
        .map((entry) => entry.model?.[0])
        .find((message) => message?.role === "toolResult");
      expect(result).toMatchObject({ toolName: tool });
      return { isError: result!.role === "toolResult" && result!.isError, text: textOf(result) };
    },
    async rows(): Promise<ServerExtensionSummary[]> {
      const listed = await route("GET", "/server/resources/extensions?plugins=true");
      expect(listed.status).toBe(200);
      return listed.body.extensions as ServerExtensionSummary[];
    },
    /** Switch a row as the Extensions page and `oppi extensions enable|disable` do. */
    async switchRow(name: string, enabled: boolean) {
      const row = (await f.rows()).find((candidate) => candidate.name === name)!;
      return route("PUT", `/server/resources/extensions/${row.id}/enabled`, { enabled });
    },
  };
  return f;
}

describe("example plugins", () => {
  it("ship off, and their rows turn them on and off again for sessions", async () => {
    const f = await fixture();
    const examples = (await f.rows()).filter((row) => row.name.startsWith("oppi-example-"));
    expect(examples).toEqual([
      expect.objectContaining({ name: "oppi-example-bookmarks", source: "built-in", state: "off" }),
      expect.objectContaining({
        name: "oppi-example-release-notes",
        source: "built-in",
        state: "off",
      }),
    ]);
    expect(examples.map((row) => row.plugin)).toEqual([
      expect.objectContaining({ required: false, enabled: false }),
      expect.objectContaining({ required: false, enabled: false }),
    ]);
    const session = await f.session("Examples off");
    expect(await f.offered(session)).toEqual([]);

    for (const name of ["oppi-example-bookmarks", "oppi-example-release-notes"])
      expect(await f.switchRow(name, true)).toMatchObject({
        status: 200,
        body: { name, state: "on" },
      });
    // Kept apart from `disabled`, which a default-on plugin uses.
    expect(f.storage.getConfig().experimental?.durableExtensions).toEqual({
      enabled: ["example-bookmarks", "example-release-notes"],
    });
    await f.reattach(session);
    expect(await f.offered(session)).toEqual(EXAMPLE_TOOLS);

    expect(await f.switchRow("oppi-example-bookmarks", false)).toMatchObject({
      status: 200,
      body: { state: "off" },
    });
    expect(f.storage.getConfig().experimental?.durableExtensions).toEqual({
      enabled: ["example-release-notes"],
    });
    await f.reattach(session);
    expect(await f.offered(session)).toEqual(["example_release_notes"]);
    // A stray `disabled` entry does not turn a default-off example on.
    f.storage.mutateConfig(() => ({
      experimental: { serverDurable: true, durableExtensions: { disabled: ["example-bookmarks"] } },
    }));
    await f.reattach(session);
    expect(await f.offered(session)).toEqual([]);
  });

  it("bookmarks: saved links survive a server restart and belong to their chat", async () => {
    const f = await fixture();
    await f.manager.setPluginEnabled("example-bookmarks", true);
    const chat = await f.session("Bookmarks");
    expect(await f.call(chat, "example_bookmark_list")).toEqual({
      isError: false,
      text: "No bookmarks yet.",
    });
    expect(
      await f.call(chat, "example_bookmark_add", { url: "https://example.com", title: "Example" }),
    ).toEqual({ isError: false, text: "Saved https://example.com. 1 bookmark(s) in total." });
    expect(await f.call(chat, "example_bookmark_add", { url: "https://oppi.dev" })).toEqual({
      isError: false,
      text: "Saved https://oppi.dev. 2 bookmark(s) in total.",
    });

    await f.restart();
    await f.manager.startSession(chat.id, f.workspace);
    expect(await f.call(chat, "example_bookmark_list")).toEqual({
      isError: false,
      text: "1. Example <https://example.com>\n2. https://oppi.dev <https://oppi.dev>",
    });
    const other = await f.session("Another chat");
    expect(await f.call(other, "example_bookmark_list")).toEqual({
      isError: false,
      text: "No bookmarks yet.",
    });
  });

  it("release-notes: returns the top of the workspace's CHANGELOG.md, and an error without one", async () => {
    const f = await fixture();
    await f.manager.setPluginEnabled("example-release-notes", true);
    writeFileSync(
      join(f.dir, "CHANGELOG.md"),
      ["# Changelog", "", "## 1.2.0", "- Faster", "## 1.1.0", "- Older"].join("\n"),
    );
    const chat = await f.session("Release notes");
    expect(await f.call(chat, "example_release_notes", { lines: 4 })).toEqual({
      isError: false,
      text: "# Changelog\n\n## 1.2.0\n- Faster\n",
    });

    const emptyDir = makeTempDir("oppi-example-plugins-empty-");
    const empty = f.storage.createWorkspace({ name: "No changelog", hostMount: emptyDir });
    const missing = await f.call(await f.session("Missing", empty), "example_release_notes");
    expect(missing.isError).toBe(true);
    expect(missing.text).toContain("CHANGELOG.md");
  });
});

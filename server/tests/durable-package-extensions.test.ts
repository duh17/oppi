import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import { DurableHarness, SessionHost, type DurableExtensionReport } from "../src/durable-harness.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createDurableExtensionRoutes } from "../src/routes/durable-extensions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { ServerMessage } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
let agentDir: string;
beforeEach(() => {
  agentDir = mkdtempSync(join(tmpdir(), "oppi-durable-packages-agent-"));
  process.env.PI_CODING_AGENT_DIR = agentDir;
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

/** A Pi package with a classic entry and a durable entry whose tool reports `version.ts`. */
function writePackage(name: string, extensionName = name): string {
  const root = join(agentDir, "extensions", name);
  mkdirSync(root, { recursive: true });
  writeFileSync(join(root, "index.ts"), "export default function () {}\n");
  writeFileSync(
    join(root, "durable.ts"),
    [
      'import { Type } from "typebox";',
      'import { defineExtension, defineTool } from "@earendil-works/pi-durable";',
      'import { defineDurableExtension } from "oppi/durable";',
      'import { VERSION } from "./version.js";',
      "export default defineDurableExtension({",
      "  extension: defineExtension({",
      `    name: ${JSON.stringify(extensionName)},`,
      "    tools: [defineTool({",
      `      name: ${JSON.stringify(`${name}_version`)},`,
      '      description: "Report the code version.",',
      "      parameters: Type.Object({}),",
      "      async execute() {",
      '        return { output: [{ type: "text", text: VERSION }] };',
      "      },",
      "    })],",
      "  }),",
      "});",
      "",
    ].join("\n"),
  );
  setVersion(name, "v1");
  return root;
}

function setVersion(name: string, version: string): void {
  writeFileSync(
    join(agentDir, "extensions", name, "version.ts"),
    `export const VERSION: string = ${JSON.stringify(version)};\n`,
  );
}

function textOf(message: Message | undefined): string {
  if (!message) return "";
  if (typeof message.content === "string") return message.content;
  return message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

/** Every prompt calls `tool`; its result ends the turn. */
function callsTool(tool: string): FauxResponseStep[] {
  const step: FauxResponseFactory = (transcript) => {
    const last = transcript.messages.findLast((message) => message.role !== "system")!;
    if (last.role === "toolResult") return fauxAssistantMessage("DONE");
    return fauxAssistantMessage([fauxToolCall(tool, {})], { stopReason: "toolUse" });
  };
  return Array.from({ length: 20 }, () => step);
}

async function fixture(responses: FauxResponseStep[]) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-packages-test-"));
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
  // Package discovery still scans `<agentDir>/extensions` with in-memory settings.
  vi.spyOn(SettingsManager, "create").mockImplementation(() =>
    SettingsManager.inMemory({
      defaultProvider: "faux",
      defaultModel: "faux-1",
      defaultThinkingLevel: "off",
      compaction: { enabled: false },
    }),
  );
  const opening = vi.spyOn(SessionHost.prototype, "open");
  const storage = new Storage(dir);
  storage.updateConfig({ experimental: { serverDurable: true } });
  const workspace = storage.createWorkspace({ name: "Packages", hostMount: dir });
  const session = storage.createSession("Package user", "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  const helpers = createRouteHelpers();
  const routes = createDurableExtensionRoutes(
    { sessions: manager } as unknown as RouteContext,
    helpers,
  );
  return {
    storage,
    workspace,
    manager,
    session,
    harness: async (): Promise<Harness> => (await opening.mock.results.at(-1)!.value).harness,
    /** `POST /durable/extensions/reload`, as `oppi extensions reload` sends it. */
    async reload(): Promise<DurableExtensionReport> {
      const res = makeResponse();
      const handled = await routes({
        method: "POST",
        path: "/durable/extensions/reload",
        url: new URL("http://localhost/durable/extensions/reload"),
        req: makeRequest(),
        res,
      });
      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      return JSON.parse(res.body) as DurableExtensionReport;
    },
  };
}

async function prompt(manager: SessionManager, sessionId: string, text: string): Promise<void> {
  const ended = new Promise<void>((resolve) => {
    const unsubscribe = manager.subscribe(sessionId, (message: ServerMessage) => {
      if (message.type !== "agent_end") return;
      unsubscribe();
      resolve();
    });
  });
  await manager.sendPrompt(sessionId, text);
  await ended;
}

async function toolResults(harness: Harness, id: ConversationId) {
  const page = await (await harness.conversation(id, context))!.entries(
    {},
    200,
    undefined,
    context,
  );
  return page.items.toReversed().flatMap((entry) => {
    const message = entry.model?.[0];
    return message?.role === "toolResult"
      ? [{ toolName: message.toolName, isError: message.isError, text: textOf(message) }]
      : [];
  });
}

describe("durable extensions from Pi packages", () => {
  it("offers a package's tool to a durable session and runs the reloaded code without a restart", async () => {
    writePackage("probe");
    const f = await fixture(callsTool("probe_version"));
    await f.manager.startSession(f.session.id, f.workspace);
    const conversation = f.storage.getSession(f.session.id)!.serverDurable!
      .conversationId as ConversationId;

    await prompt(f.manager, f.session.id, "Which version?");
    setVersion("probe", "v2");
    const report = await f.reload();
    expect(report.loaded.map((loaded) => loaded.name)).toEqual(["probe"]);
    expect(report.errors).toEqual([]);
    await prompt(f.manager, f.session.id, "Which version now?");

    const results = await toolResults(await f.harness(), conversation);
    expect(results.map((result) => [result.toolName, result.isError, result.text])).toEqual([
      ["probe_version", false, "v1"],
      ["probe_version", false, "v2"],
    ]);
  });

  it("keeps the running code when a reload fails, and uninstalls a removed package", async () => {
    const root = writePackage("probe");
    const f = await fixture(callsTool("probe_version"));
    await f.manager.startSession(f.session.id, f.workspace);
    const conversation = f.storage.getSession(f.session.id)!.serverDurable!
      .conversationId as ConversationId;

    writeFileSync(join(root, "durable.ts"), "export default {\n");
    const broken = await f.reload();
    expect(broken.loaded).toEqual([]);
    expect(broken.kept.map((kept) => kept.name)).toEqual(["probe"]);
    expect(broken.errors).toEqual([
      expect.objectContaining({ entry: realpathSync(join(root, "durable.ts")) }),
    ]);
    await prompt(f.manager, f.session.id, "Still there?");

    rmSync(root, { recursive: true });
    const removed = await f.reload();
    expect(removed.removed).toEqual(["probe"]);
    await prompt(f.manager, f.session.id, "And now?");

    const results = await toolResults(await f.harness(), conversation);
    expect(results.map((result) => [result.isError, result.text])).toEqual([
      [false, "v1"],
      [true, expect.stringContaining("probe_version")],
    ]);
  });

  it("loads a symlinked package whose entry imports a file next to its real directory", async () => {
    // As `~/.pi/agent/extensions/ask -> ~/workspace/oppi/pi-extensions/ask`, with `../durable-ui.js`.
    const source = mkdtempSync(join(tmpdir(), "oppi-durable-packages-source-"));
    mkdirSync(join(source, "linked"));
    writeFileSync(join(source, "shared.ts"), 'export const VERSION: string = "shared";\n');
    writeFileSync(join(source, "linked", "index.ts"), "export default function () {}\n");
    writeFileSync(
      join(source, "linked", "durable.ts"),
      [
        'import { defineExtension } from "@earendil-works/pi-durable";',
        'import { VERSION } from "../shared.js";',
        "export default { extension: defineExtension({ name: `linked-${VERSION}` }) };",
        "",
      ].join("\n"),
    );
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    symlinkSync(join(source, "linked"), join(agentDir, "extensions", "linked"));
    const f = await fixture(callsTool("unused"));
    const report = await f.reload();
    expect(report.errors).toEqual([]);
    expect(report.loaded.map((loaded) => loaded.name)).toEqual(["linked-shared"]);
  });

  it("skips a package that provides a built-in extension and refuses a tool name a built-in owns", async () => {
    writePackage("ask");
    const clash = writePackage("shadow");
    writeFileSync(
      join(clash, "durable.ts"),
      [
        'import { defineExtension } from "@earendil-works/pi-durable";',
        'import { CodingTools } from "@earendil-works/pi-durable/tools";',
        'export default { extension: defineExtension({ name: "shadow", tools: CodingTools.tools }) };',
        "",
      ].join("\n"),
    );
    writePackage("probe");
    const f = await fixture(callsTool("probe_version"));
    const report = await f.reload();
    expect(report.loaded.map((loaded) => loaded.name)).toEqual(["probe"]);
    expect(report.skipped).toEqual([
      expect.objectContaining({ message: '"ask" is built into Oppi' }),
    ]);
    expect(report.errors).toEqual([
      expect.objectContaining({
        entry: realpathSync(join(clash, "durable.ts")),
        message: expect.stringContaining("already offered"),
      }),
    ]);
  });
});

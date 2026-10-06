import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import { fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import type { ConversationId } from "@earendil-works/pi-durable";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { DurableHarness } from "../src/durable-harness.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
beforeEach(() => {
  process.env.PI_CODING_AGENT_DIR = mkdtempSync(join(tmpdir(), "oppi-control-selection-agent-"));
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

async function startDurable(runtime: "host" | "sandbox") {
  const dir = mkdtempSync(join(tmpdir(), "oppi-control-selection-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
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
  const workspace = storage.createWorkspace({ name: "Selection", hostMount: dir });
  if (runtime === "sandbox") {
    workspace.runtime = "sandbox";
    storage.updateWorkspace(workspace.id, { runtime: "sandbox" });
    const vm: GondolinVm = {
      fs: {
        mkdir: async () => {},
        access: async () => {},
        readFile: async () => Buffer.alloc(0),
        writeFile: async () => {},
      },
      exec: () =>
        Object.assign(
          Promise.resolve({
            ok: true,
            exitCode: 0,
            stdout: "",
            stdoutBuffer: Buffer.alloc(0),
          }),
          { async *output() {}, write() {}, end() {} },
        ),
    };
    vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue(vm);
  }
  const session = storage.createSession("Selection", "faux/faux-1");
  session.serverDurable = {};
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  const opening = vi.spyOn(DurableHarness.prototype, "open");
  await manager.resumeDurableSessions();
  await manager.startSession(session.id, workspace);
  const { harness } = await opening.mock.results[0]!.value;
  const id = storage.getSession(session.id)!.serverDurable!.conversationId as ConversationId;
  return (await harness.conversation(id, context))!.agent(context);
}

describe("oppi.control is not offered to other durable sessions", () => {
  it.each(["host", "sandbox"] as const)(
    "a fresh %s session has no oppi_query or oppi_script",
    async (runtime) => {
      const agent = await startDurable(runtime);
      const tools = agent.tools.map((tool) => tool.name);
      expect(tools).toContain("session_spawn");
      expect(tools).not.toContain("oppi_query");
      expect(tools).not.toContain("oppi_script");
      expect(agent.extensions.map((extension) => extension.name)).not.toContain("oppi.control");
      expect(agent.sections.map((section) => section.key)).not.toContain("oppi-control");
    },
  );
});

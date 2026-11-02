import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Message } from "@earendil-works/pi-ai";
import {
  fauxAssistantMessage,
  fauxProvider,
  type FauxResponseFactory,
} from "@earendil-works/pi-ai/providers/faux";

import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ServerMessage } from "../src/types.js";

const AUTO_NAME = join(import.meta.dirname, "../plugins/auto-name");

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
let agentDir: string;

beforeEach(() => {
  agentDir = mkdtempSync(join(tmpdir(), "auto-name-durable-agent-"));
  process.env.PI_CODING_AGENT_DIR = agentDir;
  mkdirSync(join(agentDir, "extensions"));
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  rmSync(agentDir, { recursive: true, force: true });
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

function textOf(message: Message | undefined): string {
  if (!message) return "";
  if (typeof message.content === "string") return message.content;
  return message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

/** A durable server over the faux model: it titles a request that asks for a title, else says DONE. */
async function fixture(options: { sessionName?: string }) {
  const dir = mkdtempSync(join(tmpdir(), "auto-name-durable-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  const titleRequests: string[] = [];
  const answer: FauxResponseFactory = (transcript) => {
    const last = textOf(transcript.messages.at(-1));
    if (!last.includes("<first_user_message>")) return fauxAssistantMessage("DONE");
    titleRequests.push(last);
    return fauxAssistantMessage('"Fix Websocket Drift"');
  };
  faux.setResponses(Array.from({ length: 20 }, () => answer));
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
  const workspace = storage.createWorkspace({ name: "Naming", hostMount: dir });
  const session = storage.createSession(options.sessionName, "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  // What `oppi serve` wires: the durable runtime names a Session through the server.
  manager.sessionNaming = {
    name: (id) => storage.getSession(id)?.name,
    setName: async (id, name) => {
      const stored = storage.getSession(id)!;
      stored.name = name;
      storage.saveSession(stored);
    },
  };
  await manager.resumeDurableSessions();
  await manager.startSession(session.id, workspace);
  return {
    storage,
    manager,
    session,
    titleRequests,
    rm: () => rmSync(dir, { recursive: true, force: true }),
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

async function settled(until: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !until(); i++) await new Promise((resolve) => setTimeout(resolve, 20));
}

describe("auto-name in durable sessions", () => {
  it("names an unnamed durable session from its first message, once", async () => {
    symlinkSync(AUTO_NAME, join(agentDir, "extensions", "auto-name"), "dir");
    const f = await fixture({});
    await prompt(f.manager, f.session.id, "fix the websocket reconnect state drift");
    await settled(() => f.storage.getSession(f.session.id)?.name !== undefined);
    expect(f.storage.getSession(f.session.id)?.name).toBe("Fix Websocket Drift");

    await prompt(f.manager, f.session.id, "and now the heartbeat timer, please");
    expect(f.titleRequests).toHaveLength(1);
    f.rm();
  });

  it("never renames a session that has a name", async () => {
    symlinkSync(AUTO_NAME, join(agentDir, "extensions", "auto-name"), "dir");
    const f = await fixture({ sessionName: "Chosen by me" });
    await prompt(f.manager, f.session.id, "fix the websocket reconnect state drift");
    expect(f.titleRequests).toHaveLength(0);
    expect(f.storage.getSession(f.session.id)?.name).toBe("Chosen by me");
    f.rm();
  });

  it("does nothing while the package is not installed", async () => {
    const f = await fixture({});
    await prompt(f.manager, f.session.id, "fix the websocket reconnect state drift");
    expect(f.titleRequests).toHaveLength(0);
    expect(f.storage.getSession(f.session.id)?.name).toBeUndefined();
    f.rm();
  });
});

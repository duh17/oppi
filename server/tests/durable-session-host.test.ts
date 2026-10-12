import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { DurableHarness, durableStoreDir, durableStoreSqlitePath } from "../src/durable-harness.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import { DURABLE_STORE_MISSING } from "../src/session-runtime-capabilities.js";
import type { ServerMessage, Session } from "../src/types.js";

const managers: SessionManager[] = [];
const runtimes: DurableHarness[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;

beforeEach(() => {
  process.env.PI_CODING_AGENT_DIR = mkdtempSync(join(tmpdir(), "oppi-session-host-agent-"));
});

afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close().catch(() => undefined)));
  await Promise.all(runtimes.splice(0).map((runtime) => runtime.closeAll().catch(() => undefined)));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
}, 20_000);

async function fixture(responses: FauxResponseStep[] = []) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-session-host-"));
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
  storage.updateConfig({ experimental: { serverDurable: true } });
  const workspace = storage.createWorkspace({ name: "Stores", hostMount: dir });
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  return { dir, models, faux, storage, workspace, manager };
}

function enroll(storage: Storage, workspaceId: string, name: string): Session {
  const session = storage.createSession(name, "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  session.workspaceId = workspaceId;
  storage.saveSession(session);
  return session;
}

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
          reject(new Error(`Expected event; observed ${messages.map((m) => m.type).join(",")}`));
        }, 8_000);
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

async function until(
  check: () => boolean | Promise<boolean>,
  what: string | (() => string),
): Promise<void> {
  for (let tries = 0; tries < 200; tries += 1) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for ${typeof what === "function" ? what() : what}`);
}

describe("durable SessionHost stores", () => {
  it("creates meta.json and session.sqlite and holds the directory lock while open", async () => {
    const f = await fixture();
    const session = enroll(f.storage, f.workspace.id, "One");
    await f.manager.startSession(session.id, f.workspace);
    const directory = durableStoreDir(f.dir, session.id);
    expect(existsSync(join(directory, "meta.json"))).toBe(true);
    expect(existsSync(durableStoreSqlitePath(f.dir, session.id))).toBe(true);
    const meta = JSON.parse(
      await import("node:fs/promises").then((fs) =>
        fs.readFile(join(directory, "meta.json"), "utf8"),
      ),
    );
    expect(meta.cwd).toBe(f.workspace.hostMount);
    expect(typeof meta.createdAt).toBe("number");
    const other = new DurableHarness(f.dir);
    runtimes.push(other);
    await expect(other.openHost(session.id, { cwd: f.dir })).rejects.toMatchObject({
      code: "durable_store_locked",
    });
  });

  it("isolates two stores that share conversation id 1", async () => {
    const f = await fixture([fauxAssistantMessage("ONE"), fauxAssistantMessage("TWO")]);
    const first = enroll(f.storage, f.workspace.id, "First");
    const second = enroll(f.storage, f.workspace.id, "Second");
    await f.manager.startSession(first.id, f.workspace);
    await f.manager.startSession(second.id, f.workspace);
    const firstId = f.storage.getSession(first.id)!.serverDurable!.conversationId;
    const secondId = f.storage.getSession(second.id)!.serverDurable!.conversationId;
    expect(firstId).toBe(secondId);
    const watchFirst = observe(f.manager, first.id);
    const watchSecond = observe(f.manager, second.id);
    const firstEnd = watchFirst.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(first.id, "say one");
    await firstEnd;
    expect(watchSecond.messages.some((message) => message.type === "agent_end")).toBe(false);
    await f.manager.sendAbort(first.id);
    const secondEnd = watchSecond.next((message) => message.type === "agent_end");
    await f.manager.sendPrompt(second.id, "say two");
    await secondEnd;
    watchFirst.unsubscribe();
    watchSecond.unsubscribe();
  });

  it("closes an idle store and reopens it", async () => {
    const f = await fixture([fauxAssistantMessage("HI")]);
    const session = enroll(f.storage, f.workspace.id, "Idle");
    await f.manager.startSession(session.id, f.workspace);
    const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    expect(f.manager.isActive(session.id)).toBe(true);
    expect(runtime.host(session.id)?.isOpen).toBe(true);
    await f.manager.stopSession(session.id);
    expect(f.manager.isActive(session.id)).toBe(false);
    await until(
      () => runtime.host(session.id) === undefined,
      () => {
        const host = runtime.host(session.id);
        return `idle store close (${host?.holdReasons.join("; ") || "missing host"})`;
      },
    );
    const other = new DurableHarness(f.dir);
    runtimes.push(other);
    const reopened = await other.openHost(session.id, { cwd: f.dir });
    expect(reopened.isOpen).toBe(true);
    await reopened.close();
    await f.manager.startSession(session.id, f.workspace);
    expect(runtime.host(session.id)?.isOpen).toBe(true);
  });

  it("refuses to open a durable session that has no storeId", async () => {
    const f = await fixture();
    const session = f.storage.createSession("Legacy", "faux/faux-1");
    session.serverDurable = { conversationId: 1 };
    session.workspaceId = f.workspace.id;
    f.storage.saveSession(session);
    await expect(f.manager.startSession(session.id, f.workspace)).rejects.toThrow(
      DURABLE_STORE_MISSING,
    );
  });
});

import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
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
import { InboxDoc, type ConversationId } from "@earendil-works/pi-durable";
import { DurableHarness, durableStoreDir, durableStoreSqlitePath } from "../src/durable-harness.js";
import { DurableInputCards } from "../extensions/durable/durable-ui.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { SANDBOX_RESOURCE_MAX_BYTES } from "../src/gondolin-ops.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import type { ConversationStreamServerMessage } from "../src/types.js";
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

  it("fails open when meta.json exists but is invalid", async () => {
    const f = await fixture();
    const session = enroll(f.storage, f.workspace.id, "Torn meta");
    await f.manager.startSession(session.id, f.workspace);
    const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    await f.manager.stopSession(session.id);
    await until(
      () => runtime.host(session.id) === undefined,
      () => {
        const host = runtime.host(session.id);
        return `idle store close (${host?.holdReasons.join("; ") || "missing host"})`;
      },
    );
    const directory = durableStoreDir(f.dir, session.id);
    writeFileSync(join(directory, "meta.json"), "{not-json\n");
    const other = new DurableHarness(f.dir);
    runtimes.push(other);
    await expect(other.openHost(session.id, { cwd: f.dir })).rejects.toThrow(
      /meta\.json is invalid/,
    );
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

  it("re-attaches a transcript socket whose room failed, on one subscription", async () => {
    const f = await fixture([fauxAssistantMessage("done")]);
    const session = enroll(f.storage, f.workspace.id, "Lost room");
    await f.manager.startSession(session.id, f.workspace);
    const conversationId = f.storage.getSession(session.id)!.serverDurable!
      .conversationId as ConversationId;
    const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    const host = runtime.host(session.id)!;
    const frames: ConversationStreamServerMessage[] = [];
    const stop = await host.transcript(conversationId, {
      renderers: new MobileRendererRegistry(),
      send: (frame) => frames.push(JSON.parse(JSON.stringify(frame))),
    });
    try {
      await host.use(async (harness) => {
        const conversation = (await harness.conversation(conversationId, context))!;
        await conversation.commit(async (tx) => {
          const cards = await tx.doc(DurableInputCards, conversationId);
          cards.requests["job-1"] = { title: "Background job 1", at: 1 };
        }, context);
        // The room's next presentation pass fails its input-card read, as a store error
        // would. Other readers of the same document (session events) are left alone.
        const snapshot = harness.snapshot.bind(harness);
        let failed = false;
        vi.spyOn(harness, "snapshot").mockImplementation(((doc, id, ctx) => {
          if (doc === DurableInputCards && !failed && new Error().stack?.includes("presentPass")) {
            failed = true;
            return Promise.reject(new Error("store busy"));
          }
          return snapshot(doc, id, ctx);
        }) as typeof harness.snapshot);
        const submission = await conversation.submit(
          { type: "input", content: "raw job output", requestId: "job-1" },
          context,
        );
        await submission.wait(context);
        await conversation.waitForIdle(context);
        expect(failed).toBe(true);
      });
      const sent = () =>
        frames.flatMap((frame) =>
          frame.type === "update" || frame.type === "snapshot" ? (frame.entries ?? []) : [],
        );
      await until(
        () => sent().some((entry) => JSON.stringify(entry.model ?? "").includes("done")),
        "the reply on the re-attached stream",
      );
      expect(JSON.stringify(frames)).not.toContain("raw job output");
      expect(sent().find((entry) => entry.inputCard)?.card?.title).toBe("Background job 1");
      // One subscription: a later commit reaches the socket once, not once per subscription.
      const before = frames.length;
      await host.use(async (harness) => {
        const conversation = (await harness.conversation(conversationId, context))!;
        await conversation.commit(async (tx) => {
          const cards = await tx.doc(DurableInputCards, conversationId);
          cards.requests["job-1"] = { title: "Background job 1 (renamed)", at: 2 };
        }, context);
      });
      await until(() => frames.length > before, "the renamed card");
      await new Promise((resolve) => setTimeout(resolve, 300));
      const restated = frames
        .slice(before)
        .flatMap((frame) => (frame.type === "update" ? (frame.entries ?? []) : []))
        .filter((entry) => entry.inputCard);
      expect(restated.map((entry) => entry.card?.title)).toEqual(["Background job 1 (renamed)"]);
    } finally {
      stop();
    }
  });

  it("reads a sandbox /skill: file within the resource cap", async () => {
    const f = await fixture();
    const session = enroll(f.storage, f.workspace.id, "Skill cap");
    await f.manager.startSession(session.id, f.workspace);
    const conversationId = f.storage.getSession(session.id)!.serverDurable!
      .conversationId as ConversationId;
    const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    const host = runtime.host(session.id)!;
    // A guest grew the Skill file after discovery; the small one still reads.
    const sizes: Record<string, number> = {
      "/workspace/big/SKILL.md": SANDBOX_RESOURCE_MAX_BYTES + 1,
      "/workspace/small/SKILL.md": 5,
    };
    const vm = {
      fs: {
        stat: async (path: string) => ({ isFile: () => true, size: sizes[path] ?? 0 }),
        readFileStream: async () =>
          Object.assign(
            (async function* () {
              yield Buffer.from("hello");
            })(),
            {
              destroy: () => undefined,
            },
          ),
      },
      exec: vi.fn(),
    } as unknown as GondolinVm;
    host.bindSandboxEnv(conversationId, new GondolinExecutionEnv(vm, f.workspace.id, "/workspace"));
    try {
      await expect(
        host.readSandboxTextFile(conversationId, "/workspace/small/SKILL.md"),
      ).resolves.toBe("hello");
      await expect(
        host.readSandboxTextFile(conversationId, "/workspace/big/SKILL.md"),
      ).rejects.toThrow("larger than");
    } finally {
      await host.unbindSandboxEnv(conversationId, true);
    }
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

  it("reads stored history after the session worktree is gone", async () => {
    const f = await fixture();
    const session = enroll(f.storage, f.workspace.id, "History");
    await f.manager.startSession(session.id, f.workspace);
    const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    await f.manager.stopSession(session.id);
    await until(
      () => runtime.host(session.id) === undefined,
      () => {
        const host = runtime.host(session.id);
        return `idle store close (${host?.holdReasons.join("; ") || "missing host"})`;
      },
    );
    const stored = f.storage.getSession(session.id)!;
    stored.worktreeId = "wt_removed";
    f.storage.saveSession(stored);
    const page = await f.manager.getServerDurableTracePage(session.id, {});
    expect(page).not.toBeNull();
    expect(page?.trace).toEqual([]);
  });

  it.each(["graceful", "crash"] as const)(
    "%s restart aborts a stopped session leftover task when the store reopens",
    async (mode) => {
      const f = await fixture();
      const session = enroll(f.storage, f.workspace.id, "Leftover");
      await f.manager.startSession(session.id, f.workspace);
      const conversationId = f.storage.getSession(session.id)!.serverDurable!
        .conversationId as ConversationId;
      const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
        .durableHarness;
      await f.manager.stopSession(session.id);
      await until(
        () => runtime.host(session.id) === undefined || runtime.host(session.id)?.isIdle === true,
        "store idle after stop",
      );
      const host = await runtime.openHost(session.id);
      const release = host.retain("plant-leftover");
      try {
        const { harness } = await host.open();
        const conversation = (await harness.conversation(conversationId, context))!;
        await conversation.commit(async (tx) => {
          const inbox = await tx.doc(InboxDoc, conversationId);
          const input = await tx.createSubmission({
            conversationId,
            type: "input",
            status: "queued",
            requestId: "leftover-input",
          });
          inbox.items.push({ id: input.id, mode: "followUp", content: "Never deliver" });
        }, context);
        expect(
          (await harness.inspect(context)).submissions.some(
            (submission) => submission.status === "queued",
          ),
        ).toBe(true);
      } finally {
        release();
      }

      if (mode === "graceful") {
        await f.manager.close();
      } else {
        await runtime.closeAll();
      }
      managers.splice(managers.indexOf(f.manager), 1);

      const restarted = new SessionManager(new Storage(f.dir));
      managers.push(restarted);
      await restarted.resumeDurableSessions();
      expect(restarted.isActive(session.id)).toBe(false);
      expect(await restarted.getServerDurableTracePage(session.id, {})).not.toBeNull();
      const reopened = await (
        await (restarted as unknown as { durableHarness: Promise<DurableHarness> }).durableHarness
      ).openHost(session.id);
      await until(async () => {
        const live = await (await reopened.open()).harness.inspect(context);
        return !live.submissions.some((submission) => submission.status === "queued");
      }, "leftover submission aborted");
    },
  );

  it("startSession after stop aborts leftover background work instead of running it", async () => {
    const f = await fixture();
    const session = enroll(f.storage, f.workspace.id, "Leftover start");
    await f.manager.startSession(session.id, f.workspace);
    const conversationId = f.storage.getSession(session.id)!.serverDurable!
      .conversationId as ConversationId;
    const runtime = await (f.manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    await f.manager.stopSession(session.id);
    await until(
      () => runtime.host(session.id) === undefined || runtime.host(session.id)?.isIdle === true,
      "store idle after stop",
    );
    const host = await runtime.openHost(session.id);
    const release = host.retain("plant-leftover");
    try {
      const { harness } = await host.open();
      const conversation = (await harness.conversation(conversationId, context))!;
      await conversation.commit(async (tx) => {
        const inbox = await tx.doc(InboxDoc, conversationId);
        const input = await tx.createSubmission({
          conversationId,
          type: "input",
          status: "queued",
          requestId: "leftover-input",
        });
        inbox.items.push({ id: input.id, mode: "followUp", content: "Never deliver" });
      }, context);
    } finally {
      release();
    }
    await host.close();

    await f.manager.startSession(session.id, f.workspace);
    expect(f.manager.isActive(session.id)).toBe(true);
    const started = runtime.host(session.id)!;
    const { harness } = await started.open();
    await until(async () => {
      const live = await harness.inspect(context);
      return !live.submissions.some((submission) => submission.status === "queued");
    }, "leftover submission settled");
    const page = await (await harness.conversation(conversationId, context))!.entries(
      {},
      50,
      undefined,
      context,
    );
    const texts = page.items.flatMap((entry) => {
      const message = entry.model?.[0];
      if (message?.role !== "user") return [];
      if (typeof message.content === "string") return [message.content];
      if (!Array.isArray(message.content)) return [];
      return [
        message.content
          .flatMap((part) =>
            part && typeof part === "object" && "text" in part ? [String(part.text)] : [],
          )
          .join(""),
      ];
    });
    expect(texts).not.toContain("Never deliver");
  });
});

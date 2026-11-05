import {} from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { obj } from "@earendil-works/pi-schema";
import {
  Harness,
  createRegistry,
  defineExtension,
  defineTool,
  InboxDoc,
  type SubmissionId,
  type Conversation,
  type TaskId,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { DurableBackgroundJobs } from "../plugins/background-jobs/server.js";
import { DurableJobs } from "../plugins/background-jobs/contract.js";
import { DurableBackend } from "../src/durable-backend.js";
import { DurableUI } from "../src/durable-ui.js";
import type { OppiDurableHost, SurfaceDispatch, SurfacePublisher } from "../src/oppi-v1.js";
import type { ExtensionUISurface } from "../src/types.js";
import { Storage } from "../src/storage.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import { DurableHarness, type SessionHost } from "../src/durable-harness.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { RESULT_GUIDANCE } from "../plugins/background-jobs/delivery.js";
import { readDurableInputCardOutput } from "../src/durable-input-cards.js";
import { readDurableTrace } from "../src/durable-history.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { makeTempDir } from "./harness/temp-dir.js";
import { toolArguments, toolNamed } from "./helpers/tool-arguments.js";

/**
 * A Session's surface loop, as the panel sees it: what it published and dismissed, and the
 * dispatch it handed back for a tap. Off by default: `oppiHost()` answers as it really does in a
 * bare Harness, which has no Session, and the panel then publishes nothing.
 */
const loop = vi.hoisted(() => {
  const state = {
    on: false,
    published: [] as Array<{ surface: ExtensionUISurface; dispatch?: SurfaceDispatch }>,
    dismissed: [] as string[],
  };
  return state;
});

vi.mock("oppi/v1", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/oppi-v1.js")>();
  const publisher: SurfacePublisher = {
    publish: (surface, dispatch) => {
      loop.published.push({ surface, ...(dispatch ? { dispatch } : {}) });
    },
    dismiss: (surfaceId) => {
      loop.dismissed.push(surfaceId);
    },
  };
  const mocked = {
    ...actual,
    oppiHost: () =>
      loop.on ? ({ surfaces: () => publisher } as unknown as OppiDurableHost) : actual.oppiHost(),
  };
  // The plugin host loads the built-ins through this module and reads its `default` too.
  return { ...mocked, default: mocked };
});

const harnesses = new Set<Harness>();
afterEach(async () => {
  await Promise.all([...harnesses].map((h) => h.close(context)));
  harnesses.clear();
  vi.restoreAllMocks();
  loop.on = false;
  loop.published.length = 0;
  loop.dismissed.length = 0;
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
/** A node of the published panel by id, wherever it sits in the tree. */
function panelNode(
  surface: ExtensionUISurface,
  id: string,
): { id?: string; text?: string; type?: string } | undefined {
  type Node = { id?: string; children?: Node[] };
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
/** A tap on a job's Stop, as the loop hands it to the panel that was published. */
async function tapStop(shown: { dispatch?: SurfaceDispatch }, job: string) {
  return shown.dispatch!({
    compositeId: "jobs",
    actionId: "stop",
    nodeId: `stop:${job}`,
    values: { job },
    revision: 1,
    signal: new AbortController().signal,
  });
}
function tool(name: string, args: Record<string, unknown>): FauxResponseStep {
  return fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
}
const answer = () => fauxAssistantMessage("Integrated the result.");
async function fixture(responses: FauxResponseStep[], realExec = false, serverOwner = false) {
  const dir = makeTempDir("oppi-durable-background-jobs-");
  console.info(`Background jobs integration artifacts: ${dir}`);
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
  const env = new NodeExecutionEnv({ cwd: dir });
  const entered = deferred<void>();
  const finish = deferred<void>();
  let executions = 0;
  let cancellations = 0;
  if (!realExec)
    vi.spyOn(serverOwner ? NodeExecutionEnv.prototype : env, "exec").mockImplementation(
      async (_command, options, execContext) => {
        executions++;
        entered.resolve();
        let onAbort = () => {};
        try {
          await Promise.race([
            finish.promise,
            new Promise<void>((resolve) => {
              onAbort = () => {
                cancellations++;
                resolve();
              };
              execContext.abortSignal?.addEventListener("abort", onAbort, { once: true });
              if (execContext.abortSignal?.aborted) onAbort();
            }),
          ]);
        } finally {
          execContext.abortSignal?.removeEventListener("abort", onAbort);
        }
        if (execContext.abortSignal?.aborted)
          return { ok: false, error: { code: "aborted", message: "aborted" } };
        options?.onOutput?.("FINAL-OUTPUT\n");
        return { ok: true, value: { exitCode: 0, stdout: "FINAL-OUTPUT\n", stderr: "" } };
      },
    );
  let owner = new DurableHarness(dir);
  if (serverOwner) {
    vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
    vi.spyOn(SettingsManager, "create").mockReturnValue(
      SettingsManager.inMemory({ compaction: { enabled: false } }),
    );
  }
  let openedStorage: Awaited<ReturnType<typeof openNodeSqliteStorage>> | undefined;
  let host: SessionHost | undefined;
  const open = async (executionEnv: NodeExecutionEnv | GondolinExecutionEnv = env) => {
    if (serverOwner) {
      const reopen = async (): Promise<Harness> => {
        try {
          host = await owner.openHost("jobs-host", { cwd: dir });
        } catch (error) {
          if (!(error instanceof Error) || !error.message.includes("is closed")) throw error;
          owner = new DurableHarness(dir);
          host = await owner.openHost("jobs-host", { cwd: dir });
        }
        return (await host.open()).harness;
      };
      let reopened = await reopen();
      try {
        await reopened.inspect(context);
      } catch {
        await host?.close().catch(() => undefined);
        owner = new DurableHarness(dir);
        host = undefined;
        reopened = await reopen();
      }
      harnesses.add(reopened);
      return reopened;
    }
    const registry = createRegistry();
    registry.install(CodingTools);
    registry.install(DurableBackgroundJobs);
    openedStorage = await openNodeSqliteStorage(join(dir, "jobs.sqlite"));
    const harness = await Harness.open(
      openedStorage,
      { models, registry, env: () => executionEnv, settings: { compaction: { enabled: false } } },
      context,
    );
    harnesses.add(harness);
    return harness;
  };
  const harness = serverOwner
    ? await (async () => {
        host = await owner.openHost("jobs-host", { cwd: dir });
        return (await host.open()).harness;
      })()
    : await open();
  harnesses.add(harness);
  const durableStorage = serverOwner ? host!.storage : openedStorage;
  if (!durableStorage) throw new Error("background-job fixture has no retained storage");
  const root = await harness.root(context, {
    agent: { model: { provider: "faux", modelId: "faux-1" }, cwd: dir },
  });
  return {
    dir,
    harness,
    root,
    models,
    faux,
    env,
    open,
    owner,
    durableStorage,
    entered,
    finish,
    counts: () => ({ executions, cancellations }),
  };
}
/** Stored document revisions of any kind, history included, that hold `text`. */
function documentRevisionsContaining(dir: string, text: string): number {
  const db = new DatabaseSync(join(dir, "jobs.sqlite"), { readOnly: true });
  try {
    return (
      db
        .prepare("SELECT count(*) AS n FROM document_revisions WHERE instr(content, ?) > 0")
        .get(text) as { n: number }
    ).n;
  } finally {
    db.close();
  }
}
async function prompt(root: Conversation, content = "Start the job") {
  const submission = await root.submit({ type: "input", content }, context);
  expect((await submission.wait(context)).status).toBe("done");
  await root.waitForIdle(context);
}
async function jobTask(harness: Harness, root: Conversation): Promise<TaskId> {
  return (await harness.snapshot(DurableJobs, root.id, context))!.jobs[0]!.taskId;
}
async function delivery(harness: Harness, root: Conversation) {
  await harness.waitForTask(await jobTask(harness, root), context);
  await root.waitForIdle(context);
  const state = (await root.context(context)).messages;
  const reports = state.filter(
    (message) =>
      message.role === "user" && JSON.stringify(message.content).includes("Background job bash-1"),
  );
  expect(reports).toHaveLength(1);
  expect(state.at(-1)).toMatchObject({
    role: "assistant",
    content: [{ type: "text", text: "Integrated the result." }],
  });
  return reports;
}

describe("native Durable background jobs", () => {
  it.each(["result", "throw"])(
    "discloses truncation when an appended %s error overflows the retained output",
    async (mode) => {
      const f = await fixture([
        tool("background_job", { action: "start", command: "failure 🐢" }),
        answer(),
        answer(),
      ]);
      vi.spyOn(f.env, "exec").mockImplementation(async (_command, options) => {
        options?.onOutput?.("x".repeat(63_980));
        const message = "failure ".repeat(20);
        if (mode === "throw") throw new Error(message);
        return { ok: false, error: { code: "failed", message } };
      });
      await prompt(f.root);
      await delivery(f.harness, f.root);
      const trace = await readDurableTrace(f.harness, f.root.id, "full");
      const output = trace.find((event) => event.presentation?.output)!.presentation!.output!;
      expect(output.truncated).toBe(true);
      expect(
        (await readDurableInputCardOutput(f.harness, f.root.id, output.entryId))?.output.length,
      ).toBeLessThanOrEqual(64_000);
      expect(JSON.stringify((await f.root.context(context)).messages)).toContain(
        "Output truncated",
      );
    },
  );
  it("is idle while running and answers exactly one idempotent follow-up", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    const record = (await f.harness.inspect(context)).tasks.find(
      ({ record }) => record.kind === "oppi.background-job",
    )!.record;
    expect(record).toMatchObject({ background: true, state: { status: "running" } });
    f.finish.resolve();
    const reports = await delivery(f.harness, f.root);
    expect(JSON.stringify(reports)).toContain("FINAL-OUTPUT");
    const trace = await readDurableTrace(f.harness, f.root.id, "full");
    expect(trace.filter((event) => event.type === "user")).toHaveLength(1);
    expect(
      trace.find((event) => event.presentation?.title === "Background job bash-1"),
    ).toMatchObject({
      type: "system",
      presentation: { status: "completed", body: "controlled command" },
    });
    expect(JSON.stringify(trace)).not.toContain("FINAL-OUTPUT");
    const outputRef = trace.find((event) => event.presentation?.output)?.presentation?.output;
    expect(outputRef).toMatchObject({ kind: "terminal", command: "controlled command" });
    const disclosed = await readDurableInputCardOutput(f.harness, f.root.id, outputRef!.entryId);
    expect(disclosed?.output).toContain("FINAL-OUTPUT");
    expect(disclosed?.output).not.toContain(RESULT_GUIDANCE);
    expect(disclosed?.output).not.toContain("Do not poll");
    const first = await f.root.submit(
      {
        type: "input",
        content: "duplicate must not replace original",
        requestId: "background-job:bash-1",
      },
      context,
    );
    const second = await f.root.submit(
      { type: "input", content: "duplicate", requestId: "background-job:bash-1" },
      context,
    );
    expect(first.id).toBe(second.id);
    expect((await first.wait(context)).status).toBe("done");
    expect(f.counts()).toEqual({ executions: 1, cancellations: 0 });
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      delivered: true,
    });
    // Delivered output lives in the transcript only, not in any document's history.
    expect(documentRevisionsContaining(f.dir, "FINAL-OUTPUT")).toBe(0);
  });

  it("emits a compact live notice and keeps internal reports out of get_messages after reattach", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    const storage = new Storage(f.dir);
    const session = storage.createSession("Background display", "faux/faux-1");
    session.serverDurable = { storeId: session.id, conversationId: f.root.id };
    const owner = await new DurableHarness(f.dir).attachOpened(
      session.id,
      { harness: f.harness, storage: f.durableStorage, models: f.models },
      { createdAt: Date.now(), cwd: f.dir },
    );
    await owner.releaseResume();
    const events: SessionBackendEvent[] = [];
    const shown = deferred<void>();
    const attach = async () => {
      const backend = await DurableBackend.create({
        harness: f.harness,
        host: owner,
        models: f.models,
        session,
        dataDir: f.dir,
        persistBinding: () => {},
        onEvent: (event) => {
          events.push(event);
          if (event.type === "notice" && event.message.includes("Background job bash-1"))
            shown.resolve();
        },
      });
      await backend.startEvents();
      return backend;
    };
    const backend = await attach();
    try {
      await prompt(f.root);
      await f.entered.promise;
      f.finish.resolve();
      await delivery(f.harness, f.root);
      await shown.promise;
      expect(events.filter((event) => event.type === "notice")).toEqual([
        expect.objectContaining({
          message: "Background job bash-1 · completed — controlled command",
        }),
      ]);
      expect(
        JSON.stringify(
          events.filter((event) => event.type === "message_start" || event.type === "message_end"),
        ),
      ).not.toContain("FINAL-OUTPUT");
      expect((await backend.messages()).filter((message) => message.role === "user")).toHaveLength(
        1,
      );
    } finally {
      await backend.detachForRestart();
    }
    const resumed = await attach();
    try {
      expect((await resumed.messages()).filter((message) => message.role === "user")).toHaveLength(
        1,
      );
      expect(events.filter((event) => event.type === "notice")).toHaveLength(1);
    } finally {
      await resumed.detachForRestart();
    }
  });

  it.each(["edit", "delete"])(
    "preserves generated report identity when users %s their queue",
    async (mode) => {
      const busy = deferred<void>();
      const release = deferred<void>();
      const f = await fixture([
        tool("background_job", { action: "start", command: "controlled command" }),
        answer(),
        async () => {
          busy.resolve();
          await release.promise;
          return answer();
        },
        answer(),
        answer(),
      ]);
      const storage = new Storage(f.dir);
      const session = storage.createSession("Report queue", "faux/faux-1");
      session.serverDurable = { storeId: session.id, conversationId: f.root.id };
      const owner = await new DurableHarness(f.dir).attachOpened(
        session.id,
        { harness: f.harness, storage: f.durableStorage, models: f.models },
        { createdAt: Date.now(), cwd: f.dir },
      );
      await owner.releaseResume();
      let onQueue = () => {};
      const backend = await DurableBackend.create({
        harness: f.harness,
        host: owner,
        models: f.models,
        session,
        dataDir: f.dir,
        persistBinding: () => {},
        onEvent: (event) => {
          if (event.type === "queue_update") onQueue();
        },
      });
      await backend.startEvents();
      try {
        await prompt(f.root);
        await f.entered.promise;
        await f.root.submit({ type: "input", content: "Hold foreground" }, context);
        await busy.promise;
        const userQueued = deferred<void>();
        onQueue = userQueued.resolve;
        await f.root.submit({ type: "input", content: "Original user follow-up" }, context);
        await userQueued.promise;
        const reportQueued = deferred<void>();
        onQueue = reportQueued.resolve;
        f.finish.resolve();
        await reportQueued.promise;
        await f.harness.waitForTask(await jobTask(f.harness, f.root), context);
        expect(backend.queuedMessages()).toEqual({
          steering: [],
          followUp: ["Original user follow-up"],
        });
        const before = (await f.harness.snapshot(InboxDoc, f.root.id, context))!.items.find(
          (item) => item.mode !== "write" && JSON.stringify(item.content).includes("FINAL-OUTPUT"),
        )!;
        const user = (await backend.nativeMessageQueue()).followUp[0]!;
        await backend.withRuntimeLifecycleTransaction("queue proof", (permit) =>
          backend.withdrawNativeQueue(mode === "edit" ? user.id : undefined, permit),
        );
        const after = (await f.harness.snapshot(InboxDoc, f.root.id, context))!.items;
        expect(after.find((item) => item.id === before.id)).toEqual(before);
        expect(
          await (await f.harness.submission(before.id, context))!.status(context),
        ).toMatchObject({
          status: "queued",
          requestId: "background-job:bash-1",
        });
        expect(backend.queuedMessages()).toEqual({
          steering: [],
          followUp: [],
        });
        release.resolve();
        await delivery(f.harness, f.root);
        expect(JSON.stringify(await backend.messages())).not.toContain("FINAL-OUTPUT");
        const trace = await readDurableTrace(f.harness, f.root.id, "full");
        expect(
          trace.filter((event) => event.presentation?.title === "Background job bash-1"),
        ).toHaveLength(1);
        expect(JSON.stringify(trace)).not.toContain("FINAL-OUTPUT");
        expect(f.counts().executions).toBe(1);
      } finally {
        release.resolve();
        await backend.detachForRestart();
      }
    },
  );

  it("stops a running job from its panel: the process is killed and the row follows", async () => {
    loop.on = true;
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    const shown = loop.published.at(-1)!;
    expect(shown.surface.header.title).toBe("1 job");
    expect(panelNode(shown.surface, "stop:bash-1")).toMatchObject({
      action: { id: "stop", values: { job: "bash-1" } },
    });
    // A tap that names a job this conversation is not running stops nothing.
    expect(await tapStop(shown, "bash-9")).toMatchObject({
      error: { compositeId: "jobs", message: "bash-9 is not running." },
    });
    expect(f.counts().cancellations).toBe(0);

    expect(await tapStop(shown, "bash-1")).toEqual({ patch: {} });
    const reports = await delivery(f.harness, f.root);
    expect(JSON.stringify(reports)).toContain("was cancelled");
    expect(f.counts()).toEqual({ executions: 1, cancellations: 1 });

    // The stopped job is published as stopped, with no Stop to tap again, and the panel is
    // dismissed once its result is delivered.
    const stopped = loop.published.find(
      (entry) => panelNode(entry.surface, "status:bash-1")?.text === "cancelled",
    )!;
    expect(stopped.surface.header.title).toBe("1 result");
    expect(panelNode(stopped.surface, "stop:bash-1")).toBeUndefined();
    expect(loop.dismissed).toEqual(["background-jobs"]);
    // A tap that arrives after that finds nothing to stop.
    expect(await tapStop(shown, "bash-1")).toMatchObject({ error: { compositeId: "jobs" } });
    expect(f.counts().cancellations).toBe(1);
  });

  it("clears the panel once a finished job's result is delivered", async () => {
    loop.on = true;
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    expect(loop.dismissed).toEqual([]);
    f.finish.resolve();
    await delivery(f.harness, f.root);
    expect(loop.dismissed).toEqual(["background-jobs"]);
    // Its output waited behind the row until delivery.
    const finished = loop.published.find(
      (entry) => panelNode(entry.surface, "status:bash-1")?.text === "done",
    )!;
    expect(panelNode(finished.surface, "tail:bash-1")).toMatchObject({
      type: "code",
      text: "FINAL-OUTPUT",
    });
    expect(panelNode(finished.surface, "stop:bash-1")).toBeUndefined();
  });

  it("draws the panel again from the saved job list when a runner resumes after a restart", async () => {
    loop.on = true;
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    await f.harness.close(context);
    harnesses.delete(f.harness);
    // The server went away: what the old Session's loop held went with it.
    loop.published.length = 0;
    loop.dismissed.length = 0;
    const harness = await f.open();
    const root = (await harness.conversation(f.root.id, context))!;
    harness.resume();
    await delivery(harness, root);
    // The interrupted job is a result waiting for delivery: shown, and with nothing left to stop.
    const redrawn = loop.published.find((entry) => panelNode(entry.surface, "status:bash-1"))!;
    expect(redrawn.surface.header.title).toBe("1 result");
    expect(panelNode(redrawn.surface, "status:bash-1")).toMatchObject({ text: "failed" });
    expect(panelNode(redrawn.surface, "stop:bash-1")).toBeUndefined();
    expect(loop.dismissed).toEqual(["background-jobs"]);
  });

  it("clears a pill saved before the panel when a runner resumes after a restart", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    // What 0.54.0 stored for a conversation with a job running.
    await f.root.commit(async (tx) => {
      const { notifications } = await tx.doc(DurableUI, f.root.id);
      notifications["status:background-jobs"] = {
        id: "background-jobs:status",
        method: "setStatus",
        statusKey: "background-jobs",
        statusText: "1 job",
      };
      notifications["widget:background-jobs"] = {
        id: "background-jobs:widget",
        method: "setWidget",
        widgetKey: "background-jobs",
        widgetLines: ["1 job"],
        nativeSurface: { version: 1, id: "widget:background-jobs" },
      };
    }, context);
    await f.harness.close(context);
    harnesses.delete(f.harness);
    const harness = await f.open();
    const root = (await harness.conversation(f.root.id, context))!;
    harness.resume();
    await delivery(harness, root);
    const stored = (await harness.snapshot(DurableUI, root.id, context))!.notifications;
    expect(stored["status:background-jobs"]).toEqual({
      id: "background-jobs:status",
      method: "setStatus",
      statusKey: "background-jobs",
      extensionScopeId: "repo:background-jobs",
      extensionDisplayName: "Background Jobs",
    });
    expect(stored["widget:background-jobs"]).not.toHaveProperty("nativeSurface");
    expect(stored["widget:background-jobs"]).not.toHaveProperty("widgetLines");
  });

  it("server Stop leaves a job running, while cancel kills it and delivers its final cancellation", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      tool("background_job", { action: "cancel", job_id: "bash-1" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    const owner = await new DurableHarness(f.dir).attachOpened(
      "jobs-host",
      { harness: f.harness, storage: f.durableStorage, models: f.models },
      { createdAt: Date.now(), cwd: f.dir },
    );
    await owner.releaseResume();
    await owner.abortConversation(f.root.id);
    expect(f.counts().cancellations).toBe(0);
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!.status).toBe(
      "running",
    );
    await prompt(f.root, "Cancel the job");
    const reports = await delivery(f.harness, f.root);
    expect(JSON.stringify(reports)).toContain("was cancelled");
    expect(f.counts()).toEqual({ executions: 1, cancellations: 1 });
  });

  it("holds the idle timeout while a background job runs, and releases it once delivered", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    const host = await new DurableHarness(f.dir).attachOpened(
      "jobs-host",
      { harness: f.harness, storage: f.durableStorage, models: f.models },
      { createdAt: Date.now(), cwd: f.dir },
    );
    await host.releaseResume();
    await f.root.waitForIdle(context);
    expect(await host.hasPendingWake(f.root.id)).toBe(true);

    f.finish.resolve();
    await delivery(f.harness, f.root);
    await f.root.waitForIdle(context);
    expect(await host.hasPendingWake(f.root.id)).toBe(false);
  });

  it("background abort crosses the ownership boundary and kills the execution", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    await f.root.abort(context, { background: true });
    expect(f.counts().cancellations).toBe(1);
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      status: "cancelled",
      delivered: true,
    });
  });

  it.each(["harness detach", "server graceful shutdown"])(
    "%s mid-job reports interrupted once without rerunning",
    async (mode) => {
      const f = await fixture(
        [
          tool("background_job", { action: "start", command: "controlled command" }),
          answer(),
          answer(),
        ],
        false,
        mode === "server graceful shutdown",
      );
      await prompt(f.root);
      await f.entered.promise;
      if (mode === "harness detach") await f.harness.close(context);
      else {
        f.owner.shuttingDown = true;
        await f.owner.closeAll();
      }
      harnesses.delete(f.harness);
      let harness = await f.open();
      let root = (await harness.conversation(f.root.id, context))!;
      harness.resume();
      const reports = await delivery(harness, root);
      expect(JSON.stringify(reports)).toContain("interrupted by a host restart");
      expect(JSON.stringify(reports)).toContain(
        "previous host or guest process may still be running",
      );
      expect(JSON.stringify(reports)).toContain("Do not start it again until it is confirmed dead");
      expect(f.counts().executions).toBe(1);
      await harness.close(context);
      harnesses.delete(harness);
      harness = await f.open();
      root = (await harness.conversation(f.root.id, context))!;
      harness.resume();
      const again = await root.submit(
        { type: "input", content: "duplicate", requestId: "background-job:bash-1" },
        context,
      );
      expect((await again.wait(context)).status).toBe("done");
      await delivery(harness, root);
      expect(f.counts().executions).toBe(1);
    },
  );

  it("reuses a receipt after submit-before-settlement without submitting twice", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    const admitted = await f.root.submit(
      {
        type: "input",
        content: `${RESULT_GUIDANCE}\n\nBackground job bash-1 finished (exit 0).\n\ncommand: controlled command\ncwd: ${f.dir}\n\noutput:\nFINAL-OUTPUT\n\nThis is the final result. Do not poll for this job.`,
        requestId: "background-job:bash-1",
      },
      context,
    );
    await admitted.wait(context);
    f.finish.resolve();
    await delivery(f.harness, f.root);
    expect(f.faux.state.callCount).toBe(3);
    expect(f.counts().executions).toBe(1);
  });

  it.each(["Stop", "restart"])("hands a queued result to the Harness across %s", async (mode) => {
    const busy = deferred();
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      async (_transcript, options) => {
        busy.resolve();
        await new Promise<void>((_resolve, reject) => {
          options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
            once: true,
          });
        });
        return fauxAssistantMessage("Must not finish the interrupted turn");
      },
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    await f.root.submit({ type: "input", content: "Hold a foreground turn" }, context);
    await busy.promise;
    const queued = deferred<SubmissionId>();
    const inbox = (await f.harness.watchDoc(InboxDoc, f.root.id, context))!;
    inbox.start(async (call) => {
      if (call.kind !== "value") return;
      const item = call.value.items.find(
        (item) => item.mode !== "write" && JSON.stringify(item.content).includes("FINAL-OUTPUT"),
      );
      if (item) queued.resolve(item.id);
    });
    f.finish.resolve();
    const id = await queued.promise;
    await inbox.stop();
    await f.harness.waitForTask(await jobTask(f.harness, f.root), context);
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      status: "completed",
      delivered: true,
    });
    let harness = f.harness;
    let root = f.root;
    if (mode === "Stop") {
      await root.abort(context);
      expect(await (await harness.submission(id, context))!.status(context)).toMatchObject({
        status: "unanswered",
        reason: "aborted",
      });
    } else {
      await harness.close(context);
      harnesses.delete(harness);
      harness = await f.open();
      root = (await harness.conversation(root.id, context))!;
      harness.resume();
    }
    if (mode === "restart") {
      const reports = await delivery(harness, root);
      expect(JSON.stringify(reports)).toContain("FINAL-OUTPUT");
    } else {
      await root.waitForIdle(context);
      expect(JSON.stringify((await root.context(context)).messages)).not.toContain("FINAL-OUTPUT");
    }
    expect((await harness.snapshot(DurableJobs, root.id, context))!.jobs[0]).toMatchObject({
      delivered: true,
      receiptId: "background-job:bash-1",
    });
    expect(f.counts().executions).toBe(1);
    const calls = f.faux.state.callCount;
    await harness.close(context);
    harnesses.delete(harness);
    harness = await f.open();
    root = (await harness.conversation(root.id, context))!;
    harness.resume();
    if (mode === "restart") await delivery(harness, root);
    else {
      await root.waitForIdle(context);
      expect(JSON.stringify((await root.context(context)).messages)).not.toContain("FINAL-OUTPUT");
    }
    expect(f.faux.state.callCount).toBe(calls);
    expect(f.counts().executions).toBe(1);
  });

  it("bash replacement returns quick commands in foreground and trailing & immediately", async () => {
    const f = await fixture(
      [
        tool("bash", { command: "printf foreground" }),
        answer(),
        tool("bash", { command: "printf background &" }),
        answer(),
        answer(),
      ],
      true,
    );
    await prompt(f.root);
    const first = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;
    expect(first).toMatchObject({
      status: "completed",
      decision: "foreground",
    });
    expect((await f.root.context(context)).messages.filter((m) => m.role === "user")).toHaveLength(
      1,
    );
    expect((await f.root.context(context)).messages).toContainEqual(
      expect.objectContaining({
        role: "toolResult",
        toolName: "bash",
        content: [{ type: "text", text: "foreground" }],
      }),
    );
    await f.harness.waitForTask(first.taskId, context);
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      delivered: true,
    });
    await prompt(f.root, "Run background bash");
    const second = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[1]!;
    await f.harness.waitForTask(second.taskId, context);
    await f.root.waitForIdle(context);
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[1]).toMatchObject({
      decision: "background",
      command: "printf background",
      delivered: true,
    });
  });

  it("bash backgrounds a still-running command after 15 seconds", async () => {
    const f = await fixture([tool("bash", { command: "controlled command" }), answer(), answer()]);
    await prompt(f.root);
    const job = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;
    expect(job.deadline - job.startedAt).toBe(15_000);
    expect(job).toMatchObject({ status: "running", decision: "background" });
    await f.root.abort(context);
    expect(f.counts().cancellations).toBe(0);
    f.finish.resolve();
    await delivery(f.harness, f.root);
  }, 25_000);

  it("Stop before the bash foreground deadline kills it without waking a new model turn", async () => {
    const f = await fixture([tool("bash", { command: "controlled command" }), answer()]);
    const submission = await f.root.submit(
      { type: "input", content: "Run foreground bash" },
      context,
    );
    await f.entered.promise;
    await f.root.abort(context);
    expect((await submission.wait(context)).status).toBe("unanswered");
    await f.harness.waitForTask(await jobTask(f.harness, f.root), context);
    expect(f.counts()).toEqual({ executions: 1, cancellations: 1 });
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      status: "cancelled",
      decision: "foreground",
      delivered: true,
    });
    expect((await f.root.context(context)).messages.filter((m) => m.role === "user")).toHaveLength(
      1,
    );
  });

  it("reports a thrown execution failure and frees the running job slot", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "cannot spawn" }),
      answer(),
      answer(),
    ]);
    vi.spyOn(f.env, "exec").mockRejectedValue(new Error("spawn failed"));
    await prompt(f.root);
    expect(JSON.stringify(await delivery(f.harness, f.root))).toContain("spawn failed");
    expect((await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]).toMatchObject({
      status: "failed",
      delivered: true,
    });
  });

  it("blocks bash polling while a job runs, without starting another execution", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      tool("bash", { command: "ps" }),
      answer(),
      answer(),
    ]);
    await prompt(f.root);
    await f.entered.promise;
    await prompt(f.root, "Try polling");
    expect(f.counts().executions).toBe(1);
    const results = (await f.root.context(context)).messages.filter((m) => m.role === "toolResult");
    expect(results.at(-1)).toMatchObject({ isError: true });
    expect(JSON.stringify(results.at(-1))).toContain("Do NOT poll");
    f.finish.resolve();
    await delivery(f.harness, f.root);
  });

  it("short bash timeout remains foreground and kills a real host process", async () => {
    const f = await fixture([tool("bash", { command: "sleep 20", timeout: 0.05 }), answer()], true);
    await prompt(f.root);
    const job = (await f.harness.snapshot(DurableJobs, f.root.id, context))!.jobs[0]!;
    expect(job).toMatchObject({ status: "timed_out", decision: "foreground" });
    expect((await f.root.context(context)).messages.filter((m) => m.role === "user")).toHaveLength(
      1,
    );
  });

  it("gives programs a finished command's output and exit code, as pi-durable's bash does", async () => {
    const dir = makeTempDir("oppi-durable-bash-structured-");
    const models = await ModelRuntime.create({
      authPath: join(dir, "auth.json"),
      modelsPath: null,
      modelsStorePath: join(dir, "models-cache.json"),
      refreshOnCreate: false,
    });
    const faux = fauxProvider();
    faux.setResponses([tool("probe", {}), answer()]);
    models.registerNativeProvider(faux.provider);
    await models.setRuntimeApiKey("faux", "test-only-faux-credential");
    await models.refresh({ allowNetwork: false });
    const nested: unknown[] = [];
    // A program calling bash, as a code mode script does through a nested call.
    const probe = defineTool({
      name: "probe",
      description: "Run commands through bash.",
      parameters: obj({}),
      async execute(_args, api, ctx) {
        nested.push(await api.executeTool("bash", { command: "echo ok" }, ctx));
        nested.push(await api.executeTool("bash", { command: "echo broke; exit 3" }, ctx));
        return { output: [{ type: "text", text: "probed" }] };
      },
    });
    const registry = createRegistry();
    registry.install(CodingTools);
    registry.install(DurableBackgroundJobs);
    registry.install(defineExtension({ name: "probe", tools: [probe] }));
    const harness = await Harness.open(
      await openNodeSqliteStorage(join(dir, "jobs.sqlite")),
      {
        models,
        registry,
        env: () => new NodeExecutionEnv({ cwd: dir }),
        settings: { compaction: { enabled: false } },
      },
      context,
    );
    harnesses.add(harness);
    const root = await harness.root(context, {
      agent: { model: { provider: "faux", modelId: "faux-1" }, cwd: dir },
    });
    await prompt(root, "Probe");
    expect(nested).toEqual([
      expect.objectContaining({
        isError: false,
        structuredOutput: { output: "ok\n", truncated: false, exitCode: 0 },
      }),
      expect.objectContaining({
        isError: true,
        structuredOutput: { output: "broke\n", truncated: false, exitCode: 3 },
        diagnostics: expect.arrayContaining([
          expect.objectContaining({ code: "exit_code", message: "Command exited with code 3" }),
        ]),
      }),
    ]);
  });

  it("server Stop joins foreground guest cancellation and rejects an unconfirmed kill", async () => {
    const f = await fixture([tool("bash", { command: "foreground guest command" }), answer()]);
    await f.harness.close(context);
    harnesses.delete(f.harness);
    const started = deferred<void>();
    const finish = deferred<void>();
    const killing = deferred<void>();
    const releaseKill = deferred<void>();
    const result = { ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) };
    const vm = {
      exec: vi.fn((args: string[] | string) => {
        if (args.includes("oppi-kill")) {
          killing.resolve();
          return releaseKill.promise.then(() => {
            finish.resolve();
            throw new Error("Guest kill could not be confirmed");
          });
        }
        return Object.assign(
          finish.promise.then(() => result),
          {
            async *output() {
              yield { stream: "stdout", data: Buffer.from("42 12345\n") };
              started.resolve();
              await finish.promise;
            },
            write() {},
            end() {},
          },
        );
      }),
    } as unknown as GondolinVm;
    const env = new GondolinExecutionEnv(vm, "workspace", "/workspace/project");
    const harness = await f.open(env);
    const root = (await harness.conversation(f.root.id, context))!;
    const owner = await new DurableHarness(f.dir).attachOpened(
      "jobs-host",
      { harness, storage: f.durableStorage, models: f.models },
      { createdAt: Date.now(), cwd: f.dir },
    );
    owner.bindSandboxEnv(root.id, env);
    await owner.releaseResume();
    const submission = await root.submit(
      { type: "input", content: "Run guest foreground bash" },
      context,
    );
    await started.promise;
    let confirmed = false;
    const stop = owner.abortConversation(root.id).then(() => {
      confirmed = true;
    });
    // Capture both outcomes before releasing the failed kill receipt, so an
    // early successful Stop cannot become an unhandled assertion rejection.
    const outcome = stop.then(
      () => undefined,
      (error: unknown) => error,
    );
    let confirmedBeforeReceipt = false;
    try {
      await killing.promise;
      // Let ordinary task aborts and the owner's UI commit drain while the
      // guest kill receipt is deliberately withheld.
      await new Promise<void>((resolve) => setImmediate(resolve));
      confirmedBeforeReceipt = confirmed;
    } finally {
      releaseKill.resolve();
    }
    const failure = await outcome;
    expect(confirmedBeforeReceipt).toBe(false);
    expect(failure).toMatchObject({ message: "Failed to kill durable sandbox guest work" });
    expect((await submission.wait(context)).status).toBe("unanswered");
  });

  it("runs background commands through Gondolin, and Stop does not clean up that guest execution", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "guest-command" }),
      answer(),
      answer(),
    ]);
    await f.harness.close(context);
    harnesses.delete(f.harness);
    const started = deferred<void>();
    const finish = deferred<void>();
    const calls: Array<string[] | string> = [];
    const vm = {
      exec: vi.fn((args: string[] | string) => {
        calls.push(args);
        const result = finish.promise.then(() => ({
          ok: true,
          exitCode: 0,
          stdout: "guest-result",
          stdoutBuffer: Buffer.from("guest-result"),
        }));
        return Object.assign(result, {
          async *output() {
            yield { stream: "stdout", data: Buffer.from("42 12345\n") };
            started.resolve();
            await finish.promise;
            yield { stream: "stdout", data: Buffer.from("guest-result") };
          },
          write() {},
          end() {},
        });
      }),
    } as unknown as GondolinVm;
    const env = new GondolinExecutionEnv(vm, "workspace", "/workspace/project");
    const harness = await f.open(env);
    const root = (await harness.conversation(f.root.id, context))!;
    const owner = await new DurableHarness(f.dir).attachOpened(
      "jobs-host",
      { harness, storage: f.durableStorage, models: f.models },
      { createdAt: Date.now(), cwd: f.dir },
    );
    owner.bindSandboxEnv(root.id, env);
    await owner.releaseResume();
    await prompt(root);
    await started.promise;
    try {
      await owner.abortConversation(root.id);
      expect(calls).toHaveLength(1);
      expect(JSON.stringify(calls)).toContain("guest-command");
      expect(vm.exec).toHaveBeenCalledWith(
        expect.any(Array),
        expect.objectContaining({ cwd: "/workspace/project", env: undefined }),
      );
    } finally {
      finish.resolve();
    }
    expect(JSON.stringify(await delivery(harness, root))).toContain("guest-result");
  });
});

// Argument shapes models sent these tools in recorded durable sessions.
describe("background job tool arguments", () => {
  const backgroundJob = toolNamed(DurableBackgroundJobs.tools, "background_job");
  const bash = toolNamed(DurableBackgroundJobs.tools, "bash");

  it("takes background_job's start and cancel calls, and coerces a timeout sent as text", () => {
    for (const args of [
      { action: "start", command: "npm test", timeout: 900 },
      { action: "start", command: "npm test" },
      { action: "cancel", job_id: "bash-87" },
    ])
      expect(toolArguments(backgroundJob, args)).toEqual(args);
    expect(
      toolArguments(backgroundJob, { action: "start", command: "./scrape.sh", timeout: "600" }),
    ).toEqual({ action: "start", command: "./scrape.sh", timeout: 600 });
    expect(() =>
      toolArguments(backgroundJob, { action: "start", command: "npm test", detach: true }),
    ).toThrow("detach: unknown field");
  });

  it("runs bash calls that carry another harness's background flag instead of rejecting them", () => {
    for (const args of [
      { command: "ls" },
      { command: "sleep 20", timeout: 15 },
      { command: "npx vitest run > /tmp/t.log 2>&1", run_in_background: "true" },
      { command: "xcodebuild test", background: "true" },
    ])
      expect(toolArguments(bash, args)).toEqual(args);
  });
});

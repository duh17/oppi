import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
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
import {
  Harness,
  createRegistry,
  InboxDoc,
  type SubmissionId,
  type Conversation,
  type TaskId,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import {
  DurableBackgroundJobs,
  DurableJobs,
} from "../extensions/durable/background-jobs/durable.js";
import { DurableUI } from "../extensions/durable/durable-ui.js";
import { DurableBackend } from "../src/durable-backend.js";
import { Storage } from "../src/storage.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import { DurableHarness } from "../src/durable-harness.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { RESULT_GUIDANCE } from "../extensions/durable/background-jobs/delivery.js";
import { readDurableInputCardOutput } from "../src/durable-input-cards.js";
import { readDurableTrace } from "../src/durable-history.js";
import type { GondolinVm } from "../src/gondolin-ops.js";

const harnesses = new Set<Harness>();
afterEach(async () => {
  await Promise.all([...harnesses].map((h) => h.close(context)));
  harnesses.clear();
  vi.restoreAllMocks();
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
function tool(name: string, args: Record<string, unknown>): FauxResponseStep {
  return fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
}
const answer = () => fauxAssistantMessage("Integrated the result.");
async function fixture(responses: FauxResponseStep[], realExec = false, serverOwner = false) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-background-jobs-"));
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
  const owner = new DurableHarness(dir);
  if (serverOwner) {
    vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
    vi.spyOn(SettingsManager, "create").mockReturnValue(
      SettingsManager.inMemory({ compaction: { enabled: false } }),
    );
  }
  const open = async (executionEnv: NodeExecutionEnv | GondolinExecutionEnv = env) => {
    const registry = createRegistry();
    registry.install(CodingTools);
    registry.install(DurableBackgroundJobs);
    const harness = await Harness.open(
      await openNodeSqliteStorage(
        join(dir, serverOwner ? "durable/harness.sqlite" : "jobs.sqlite"),
      ),
      { models, registry, env: () => executionEnv, settings: { compaction: { enabled: false } } },
      context,
    );
    harnesses.add(harness);
    return harness;
  };
  const harness = serverOwner ? (await owner.open()).harness : await open();
  harnesses.add(harness);
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
    entered,
    finish,
    counts: () => ({ executions, cancellations }),
  };
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
  it("is idle while running, publishes generic chrome, and answers exactly one idempotent follow-up", async () => {
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
    const ui = await f.harness.snapshot(DurableUI, f.root.id, context);
    expect(ui?.notifications["status:background-jobs"]?.statusText).toContain("1 job");
    expect(ui?.notifications["widget:background-jobs"]?.nativeSurface?.blocks).toEqual([
      {
        type: "activityList",
        id: "jobs",
        rows: [
          {
            id: "bash-1",
            title: "bash-1",
            subtitle: "controlled command",
            state: "running",
            blocks: [
              {
                type: "text",
                id: "output:bash-1",
                spans: [{ text: "No output yet", role: "muted" }],
              },
            ],
          },
        ],
      },
    ]);
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
      output: "",
    });
    const cleared = await f.harness.snapshot(DurableUI, f.root.id, context);
    expect(cleared?.notifications["status:background-jobs"]).not.toHaveProperty("statusText");
    expect(cleared?.notifications["widget:background-jobs"]).not.toHaveProperty("nativeSurface");
  });

  it("emits a compact live notice and keeps internal reports out of get_messages after reattach", async () => {
    const f = await fixture([
      tool("background_job", { action: "start", command: "controlled command" }),
      answer(),
      answer(),
    ]);
    const storage = new Storage(f.dir);
    const session = storage.createSession("Background display", "faux/faux-1");
    session.serverDurable = { conversationId: f.root.id };
    const owner = new DurableHarness(f.dir);
    vi.spyOn(owner, "open").mockResolvedValue({ harness: f.harness, models: f.models });
    await owner.releaseResume();
    const events: SessionBackendEvent[] = [];
    const shown = deferred<void>();
    const attach = async () => {
      const backend = await DurableBackend.create({
        harness: f.harness,
        owner,
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
      backend.startEvents();
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
      expect(backend.messages().filter((message) => message.role === "user")).toHaveLength(1);
    } finally {
      await backend.detachForRestart();
    }
    const resumed = await attach();
    try {
      expect(resumed.messages().filter((message) => message.role === "user")).toHaveLength(1);
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
      session.serverDurable = { conversationId: f.root.id };
      const owner = new DurableHarness(f.dir);
      vi.spyOn(owner, "open").mockResolvedValue({ harness: f.harness, models: f.models });
      await owner.releaseResume();
      let onQueue = () => {};
      const backend = await DurableBackend.create({
        harness: f.harness,
        owner,
        models: f.models,
        session,
        dataDir: f.dir,
        persistBinding: () => {},
        onEvent: (event) => {
          if (event.type === "queue_update") onQueue();
        },
      });
      backend.startEvents();
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
        expect(JSON.stringify(backend.messages())).not.toContain("FINAL-OUTPUT");
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
    const owner = new DurableHarness(f.dir);
    vi.spyOn(owner, "open").mockResolvedValue({ harness: f.harness, models: {} as ModelRuntime });
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
      else await f.owner.close();
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
    inbox.start(async (value) => {
      const item = value?.items.find(
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
      output: "",
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
      output: "",
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
      output: "",
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
    const owner = new DurableHarness(f.dir);
    vi.spyOn(owner, "open").mockResolvedValue({ harness, models: {} as ModelRuntime });
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
    const owner = new DurableHarness(f.dir);
    vi.spyOn(owner, "open").mockResolvedValue({ harness, models: {} as ModelRuntime });
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

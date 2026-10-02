import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { randomUUID } from "node:crypto";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import {
  Harness,
  createRegistry,
  LiveDoc,
  InboxDoc,
  UserEntry,
  GenerationTask,
  type StorageWrite,
  type Conversation,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { DurableGoal, GoalDoc } from "../extensions/durable/goal/durable.js";
import { DurableUI, sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";

const harnesses = new Set<Harness>();
const gates = new Set<() => void>();
afterEach(async () => {
  for (const release of gates) release();
  gates.clear();
  await Promise.all([...harnesses].map((h) => h.close(context)));
  harnesses.clear();
  vi.restoreAllMocks();
});
function tool(name: string, args: Record<string, unknown>) {
  return fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
}
function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  gates.add(resolve);
  return { promise, resolve };
}
async function fixture(
  responses: FauxResponseStep[],
  options: {
    compaction?: boolean;
    slow?: boolean;
    cut?: (writes: readonly StorageWrite[]) => boolean;
  } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-goal-"));
  console.info(`Durable goal integration artifacts: ${dir}`);
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider(
    options.slow ? { tokensPerSecond: 80, tokenSize: { min: 1, max: 1 } } : {},
  );
  faux.setResponses(responses);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  const registry = createRegistry();
  registry.install(DurableGoal);
  const cutReached = gate();
  const releaseCommit = gate();
  let armed = !!options.cut;
  async function open() {
    const storage = await openNodeSqliteStorage(join(dir, "goal.sqlite"));
    if (armed) {
      const commit = storage.commit.bind(storage);
      vi.spyOn(storage, "commit").mockImplementation(async (writes, ctx) => {
        const seq = await commit(writes, ctx);
        if (armed && options.cut!(writes)) {
          armed = false;
          cutReached.resolve();
          // Real SQLite commit happened. Delay its acknowledgment, then close:
          // the process cannot take its next step, exactly the crash window.
          await releaseCommit.promise;
        }
        return seq;
      });
    }
    const harness = await Harness.open(
      storage,
      {
        models,
        registry,
        settings: {
          compaction: { enabled: false, keepRecentTokens: options.compaction ? 1 : 20000 },
          retry: { enabled: false },
        },
      },
      context,
    );
    harnesses.add(harness);
    return harness;
  }
  const harness = await open();
  const conversation = await harness.createConversation(
    {
      ownership: { kind: "ownerless" },
      agent: { model: { provider: "faux", modelId: "faux-1" }, extensions: [DurableGoal] },
    },
    context,
  );
  return { dir, harness, conversation, faux, open, cutReached, releaseCommit };
}
async function history(conversation: Conversation) {
  return (await conversation.entries({}, 200, undefined, context)).items;
}

async function reserved(
  responses: FauxResponseStep[] = [fauxAssistantMessage("Continuation answered")],
) {
  const f = await fixture(
    [
      tool("create_goal", { objective: "Protect continuation ownership", max_continuations: 1 }),
      fauxAssistantMessage("Original run settled"),
      ...responses,
    ],
    {
      cut: (writes) =>
        writes.some(
          (write) =>
            write.type === "task" &&
            write.value.kind === "oppi.goal-runner" &&
            write.value.state.status === "running" &&
            write.value.state.checkpoint.phase === "submit",
        ),
    },
  );
  await f.conversation.submit({ type: "input", content: "Create an autonomous goal" }, context);
  await f.cutReached.promise;
  const closing = f.harness.close(context);
  f.releaseCommit.resolve();
  await closing;
  harnesses.delete(f.harness);
  const harness = await f.open();
  const conversation = (await harness.conversation(f.conversation.id, context))!;
  const doc = (await harness.snapshot(GoalDoc, conversation.id, context))!;
  const runner = (await harness.getTask(doc.runner!, context))!;
  expect(runner.state.status).toBe("pending");
  const plan = (
    runner.state as {
      checkpoint: { phase: string; requestId: string; content: string; count: number };
    }
  ).checkpoint;
  expect(plan.phase).toBe("submit");
  return { ...f, harness, conversation, plan, goal: doc.goal! };
}
async function waitForCount(harness: Harness, conversation: Conversation, count: number) {
  const watch = (await harness.watchDoc(GoalDoc, conversation.id, context))!;
  if (watch.value?.goal?.continuationCount === count) {
    await watch.stop();
    return;
  }
  await new Promise<void>((resolve) => {
    watch.start(async (value) => {
      if (value?.goal?.continuationCount === count) resolve();
    });
  });
  await watch.stop();
}

describe("Durable goal", () => {
  it("rejects a foreign request-ID collision without burning budget or withdrawing the client submission", async () => {
    const f = await reserved();
    const foreign = await f.conversation.commit(async (tx) => {
      const input = await tx.createSubmission({
        conversationId: f.conversation.id,
        type: "input",
        requestId: f.plan.requestId,
        status: "queued",
      });
      (await tx.doc(InboxDoc, f.conversation.id)).items.push({
        id: input.id,
        mode: "followUp",
        content: "Foreign client text",
      });
      return input;
    }, context);
    f.harness.resume();
    await f.conversation.waitForIdle(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
      status: "blocked",
      continuationCount: 0,
      blocker:
        "Continuation requestId conflict: stored content differs from the planned continuation.",
    });
    expect((await f.harness.snapshot(InboxDoc, f.conversation.id, context))!.items).toHaveLength(1);
    expect((await f.harness.submission(foreign.id, context))!.id).toBe(foreign.id);
    expect(f.faux.state.callCount).toBe(2);
  });

  it.each(["paused", "complete", "blocked"] as const)(
    "withdraws a queued continuation and rolls back its reservation when goal becomes %s across restart",
    async (status) => {
      const f = await reserved();
      const submission = await f.conversation.commit(async (tx) => {
        const input = await tx.createSubmission({
          conversationId: f.conversation.id,
          type: "input",
          requestId: f.plan.requestId,
          status: "queued",
        });
        (await tx.doc(InboxDoc, f.conversation.id)).items.push({
          id: input.id,
          mode: "followUp",
          content: f.plan.content,
        });
        (await tx.doc(GoalDoc, f.conversation.id)).goal!.status = status;
        return input;
      }, context);
      f.harness.resume();
      await f.conversation.waitForIdle(context);
      expect(
        await (await f.harness.submission(submission.id, context))!.status(context),
      ).toMatchObject({ status: "unanswered", reason: "aborted" });
      expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
        status,
        continuationCount: 0,
      });
      expect((await f.harness.snapshot(InboxDoc, f.conversation.id, context))!.items).toEqual([]);
      expect(
        (await history(f.conversation)).some(
          (entry) =>
            entry.data?.decision === "skip" &&
            String(entry.data?.reason).includes("Goal changed or stopped"),
        ),
      ).toBe(true);
      expect(f.faux.state.callCount).toBe(2);
    },
  );

  it.each(["paused", "complete", "blocked", "active"] as const)(
    "lets a user run committed after the checkpoint own the next turn (status=%s)",
    async (status) => {
      const entered = gate();
      const release = gate();
      const f = await reserved([
        async () => {
          entered.resolve();
          await release.promise;
          return tool(
            "update_goal",
            status === "active" ? { summary: "User work came first" } : { status },
          );
        },
        fauxAssistantMessage("User turn finished"),
        fauxAssistantMessage("Only the new continuation may run"),
      ]);
      await f.conversation.commit(async (tx) => {
        const entry = await tx.appendEntry(UserEntry, f.conversation.id, {
          model: [
            { role: "user", content: "User intervened before admission", timestamp: Date.now() },
          ],
        });
        const input = await tx.createSubmission({
          conversationId: f.conversation.id,
          type: "input",
          status: "placed",
          entry: entry.id,
        });
        (await tx.doc(LiveDoc, f.conversation.id)).run = {
          taskId: await tx.createTask(
            GenerationTask,
            {},
            { conversationId: f.conversation.id, ownership: { kind: "conversation" } },
          ),
          inputs: [input.id],
        };
      }, context);
      f.harness.resume();
      await entered.promise;
      await waitForCount(f.harness, f.conversation, 0);
      release.resolve();
      await f.conversation.waitForIdle(context);
      const goal = (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal!;
      expect(goal).toMatchObject({
        status: status === "active" ? "blocked" : status,
        continuationCount: status === "active" ? 1 : 0,
      });
      const entries = await history(f.conversation);
      expect(entries.filter((entry) => entry.kind === "pi.user")).toHaveLength(
        status === "active" ? 3 : 2,
      );
      expect(
        entries.some(
          (entry) => entry.data?.decision === "skip" && entry.data.requestId === f.plan.requestId,
        ),
      ).toBe(true);
      if (status === "active") {
        expect(
          entries
            .filter((entry) => entry.data?.decision === "continue")
            .map((entry) => entry.data!.requestId),
        ).toEqual([`oppi-goal:${f.goal.id}:1:2`, f.plan.requestId]);
      }
    },
  );

  it.each(["paused", "complete", "blocked"] as const)(
    "rolls back an unadmitted reservation when goal becomes %s across restart",
    async (status) => {
      const f = await reserved();
      await f.conversation.commit(async (tx) => {
        (await tx.doc(GoalDoc, f.conversation.id)).goal!.status = status;
      }, context);
      f.harness.resume();
      await f.conversation.waitForIdle(context);
      expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
        status,
        continuationCount: 0,
      });
      expect(
        (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
      ).toHaveLength(1);
      expect(f.faux.state.callCount).toBe(2);
    },
  );

  it("places an exact-content sole queued continuation without replacing its request ID", async () => {
    const f = await reserved();
    const queued = await f.conversation.commit(async (tx) => {
      const input = await tx.createSubmission({
        conversationId: f.conversation.id,
        type: "input",
        requestId: f.plan.requestId,
        status: "queued",
      });
      (await tx.doc(InboxDoc, f.conversation.id)).items.push({
        id: input.id,
        mode: "followUp",
        content: f.plan.content,
      });
      return input;
    }, context);
    f.harness.resume();
    await f.conversation.waitForIdle(context);
    expect(await (await f.harness.submission(queued.id, context))!.status(context)).toMatchObject({
      status: "done",
      requestId: f.plan.requestId,
    });
    const entries = await history(f.conversation);
    expect(entries.filter((entry) => entry.kind === "pi.user")).toHaveLength(2);
    expect(entries.filter((entry) => entry.data?.decision === "continue")).toHaveLength(1);
    expect(entries.some((entry) => entry.data?.decision === "skip")).toBe(false);
    expect(f.faux.state.callCount).toBe(3);
  });

  it("does not charge a replacement goal for the old goal's pending reservation", async () => {
    const f = await reserved();
    const replacement = {
      ...f.goal,
      id: randomUUID(),
      objective: "Replacement goal",
      continuationCount: 0,
    };
    await f.conversation.commit(async (tx) => {
      (await tx.doc(GoalDoc, f.conversation.id)).goal = replacement;
    }, context);
    f.harness.resume();
    await f.conversation.waitForIdle(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
      id: replacement.id,
      objective: replacement.objective,
      status: "blocked",
      continuationCount: 1,
    });
    const entries = await history(f.conversation);
    expect(entries.filter((entry) => entry.kind === "pi.user")).toHaveLength(2);
    expect(
      entries.some(
        (entry) =>
          entry.data?.decision === "skip" &&
          entry.data.goalId === f.goal.id &&
          entry.data.requestId === f.plan.requestId,
      ),
    ).toBe(true);
    expect(
      entries.some(
        (entry) => entry.data?.decision === "continue" && entry.data.goalId === replacement.id,
      ),
    ).toBe(true);
  });

  it("accepts only an exact-content already-placed continuation as replay without another run", async () => {
    const f = await reserved([
      async () => {
        const live = (await f.harness.snapshot(LiveDoc, f.conversation.id, context))!;
        expect(live.run!.inputs).toHaveLength(1);
        return fauxAssistantMessage("Existing continuation settled");
      },
    ]);
    await f.conversation.commit(async (tx) => {
      const entry = await tx.appendEntry(UserEntry, f.conversation.id, {
        model: [{ role: "user", content: f.plan.content, timestamp: Date.now() }],
      });
      const submission = await tx.createSubmission({
        conversationId: f.conversation.id,
        type: "input",
        status: "placed",
        requestId: f.plan.requestId,
        entry: entry.id,
      });
      (await tx.doc(LiveDoc, f.conversation.id)).run = {
        taskId: await tx.createTask(
          GenerationTask,
          {},
          { conversationId: f.conversation.id, ownership: { kind: "conversation" } },
        ),
        inputs: [submission.id],
      };
    }, context);
    f.harness.resume();
    await f.conversation.waitForIdle(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
      status: "blocked",
      continuationCount: 1,
    });
    expect(
      (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
    ).toHaveLength(2);
    expect((await history(f.conversation)).some((entry) => entry.data?.decision === "skip")).toBe(
      false,
    );
    expect(f.faux.state.callCount).toBe(3);
  });

  it("Abort releases an unadmitted reservation while preserving the stopped goal", async () => {
    const f = await reserved();
    await f.harness.abortTask(
      (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.runner!,
      context,
    );
    f.harness.resume();
    await f.conversation.waitForIdle(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
      status: "active",
      continuationCount: 0,
    });
    expect(
      (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
    ).toHaveLength(1);
    expect(f.faux.state.callCount).toBe(2);
  });

  it("wakes on inbox emptiness alone and gives a withdrawn reservation a fresh request ID", async () => {
    const f = await reserved();
    const input = await f.conversation.commit(async (tx) => {
      const queued = await tx.createSubmission({
        conversationId: f.conversation.id,
        type: "input",
        status: "queued",
      });
      const owned = await tx.createSubmission({
        conversationId: f.conversation.id,
        type: "input",
        status: "queued",
        requestId: f.plan.requestId,
      });
      (await tx.doc(InboxDoc, f.conversation.id)).items.push(
        { id: owned.id, mode: "followUp", content: f.plan.content },
        { id: queued.id, mode: "followUp", content: "Pending user input" },
      );
      return { queued, owned };
    }, context);
    f.harness.resume();
    await waitForCount(f.harness, f.conversation, 0);
    expect(
      await (await f.harness.submission(input.owned.id, context))!.status(context),
    ).toMatchObject({ status: "unanswered", reason: "aborted" });
    expect((await f.harness.snapshot(InboxDoc, f.conversation.id, context))!.items).toEqual([
      expect.objectContaining({ id: input.queued.id, content: "Pending user input" }),
    ]);
    await f.conversation.commit(async (tx) => {
      (await tx.doc(InboxDoc, f.conversation.id)).items = [];
      tx.settleSubmission(input.queued.id, { status: "unanswered", reason: "aborted" });
    }, context);
    await f.conversation.waitForIdle(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
      status: "blocked",
      continuationCount: 1,
    });
    expect(
      (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
    ).toHaveLength(2);
    expect(
      (await history(f.conversation))
        .filter((entry) => entry.data?.decision === "continue")
        .map((entry) => entry.data!.requestId),
    ).toEqual([`oppi-goal:${f.goal.id}:1:2`, f.plan.requestId]);
  });

  it("keeps Stop sticky for summary-only updates and rearms only an explicit active update", async () => {
    const entered = gate();
    let stoppedPrompt = "";
    let resumedPrompt = "";
    const f = await fixture([
      tool("create_goal", { objective: "Sticky Stop", max_continuations: 1 }),
      async (_request, options) => {
        entered.resolve();
        await new Promise<void>((_, reject) =>
          options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
            once: true,
          }),
        );
        return fauxAssistantMessage("unreachable");
      },
    ]);
    await f.conversation.submit({ type: "input", content: "Create autonomous goal" }, context);
    await entered.promise;
    await f.conversation.abort(context);
    const stopped = (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!;
    const ui = (await f.harness.snapshot(DurableUI, f.conversation.id, context))!;
    f.faux.appendResponses([
      (request) => {
        stoppedPrompt = JSON.stringify(
          request.messages.filter((message) => message.role === "system").at(-1),
        );
        return tool("update_goal", { summary: "Only a progress note" });
      },
      fauxAssistantMessage("Summary recorded"),
    ]);
    await f.conversation.submit(
      { type: "input", content: "Update summary without resuming" },
      context,
    );
    await f.conversation.waitForIdle(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!).toMatchObject({
      runner: stopped.runner,
      runnerStopped: true,
      goal: { status: "active", continuationCount: 0 },
    });
    expect(stoppedPrompt).not.toContain("Keep status=active");
    expect(stoppedPrompt).toContain("runner stopped by user");
    expect(stoppedPrompt).toContain("Sticky Stop");
    expect((await f.harness.inspect(context)).tasks).toHaveLength(0);
    expect(JSON.stringify(ui.notifications["widget:goal"]!.nativeSurface)).toContain(
      "Runner stopped",
    );
    expect(JSON.stringify(ui.notifications["widget:goal"]!.nativeSurface)).toContain(
      '"state":"inactive"',
    );
    expect(
      JSON.stringify(
        (await f.harness.snapshot(DurableUI, f.conversation.id, context))!.notifications[
          "widget:goal"
        ]!.nativeSurface,
      ),
    ).toContain("Runner stopped");
    f.faux.appendResponses([
      tool("update_goal", { status: "active" }),
      (request) => {
        resumedPrompt = JSON.stringify(
          request.messages.filter((message) => message.role === "system").at(-1),
        );
        return fauxAssistantMessage("Resuming explicitly");
      },
      fauxAssistantMessage("One continuation"),
    ]);
    await f.conversation.submit({ type: "input", content: "Explicitly resume goal" }, context);
    await f.conversation.waitForIdle(context);
    expect(resumedPrompt).toContain("Keep status=active");
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.runnerStopped).toBe(
      false,
    );
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.runner).not.toBe(
      stopped.runner,
    );
    expect(
      (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal!.continuationCount,
    ).toBe(1);
    expect(
      (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
    ).toHaveLength(4);
  });

  it("does not commit from the runner on streaming partial frames", async () => {
    const runner = (DurableGoal.tasks ?? [])[0]!;
    const phases = runner.definition.phases as {
      watch: (
        task: unknown,
        runtime: { commit: (...args: unknown[]) => Promise<void> },
        ctx: unknown,
      ) => Promise<void>;
    };
    const original = phases.watch;
    let commits = 0;
    vi.spyOn(phases, "watch").mockImplementation(async (task, runtime, ctx) => {
      const commit = runtime.commit.bind(runtime);
      vi.spyOn(runtime, "commit").mockImplementation(async (...args) => {
        commits++;
        return commit(...args);
      });
      return original(task, runtime, ctx);
    });
    const f = await fixture(
      [
        tool("create_goal", { objective: "Observe partials", max_continuations: 1 }),
        fauxAssistantMessage("Streaming partial frames must not wake the goal runner. ".repeat(12)),
      ],
      { slow: true },
    );
    const live = (await f.harness.watchDoc(LiveDoc, f.conversation.id, context))!;
    const frames = gate();
    let baseline = 0;
    let count = 0;
    live.start(async (value) => {
      if (!value?.generation?.message) return;
      if (String(JSON.stringify(value.generation.message)).includes("Streaming")) {
        if (count++ === 0) baseline = commits;
        if (count === 4) frames.resolve();
      }
    });
    await f.conversation.submit({ type: "input", content: "Create a goal then stream" }, context);
    await frames.promise;
    expect(count).toBeGreaterThanOrEqual(4);
    expect(commits).toBe(baseline);
    expect(commits).toBeGreaterThan(0);
    await live.stop();
    await f.conversation.abort(context);
  });

  it("injects goal state, settles before a new continuation run, and stops at the budget with a visible reason", async () => {
    let conversation!: Conversation;
    let original!: Awaited<ReturnType<Conversation["submit"]>>;
    const f = await fixture([
      tool("create_goal", {
        objective: "Verify every requirement",
        max_continuations: 1,
        summary: "Evidence starts here",
      }),
      async (request) => {
        expect(JSON.stringify(request.messages)).toContain("## Active goal runner");
        expect(JSON.stringify(request.messages)).toContain("Evidence starts here");
        return fauxAssistantMessage("Initial run settled");
      },
      async (request) => {
        expect(await original.status(context)).toMatchObject({ status: "done" });
        expect(JSON.stringify(request.messages)).toContain(
          "Continue the active goal autonomously.",
        );
        expect(
          (await conversation.context(context)).entries.filter((entry) => entry.kind === "pi.user"),
        ).toHaveLength(2);
        return fauxAssistantMessage("Still active but budget stops us");
      },
    ]);
    conversation = f.conversation;
    original = await conversation.submit(
      { type: "input", content: "Start explicitly autonomous goal" },
      context,
    );
    await conversation.waitForIdle(context);
    const goal = (await f.harness.snapshot(GoalDoc, conversation.id, context))!.goal!;
    expect(goal).toMatchObject({
      status: "blocked",
      continuationCount: 1,
      maxContinuations: 1,
      blocker: "Continuation budget exhausted (1/1).",
    });
    const entries = await history(conversation);
    const decisionEntries = entries.filter((entry) => entry.kind === "oppi-goal-continuation");
    for (const entry of decisionEntries) {
      expect(entry.model).toBeUndefined();
      expect(sanitizeTranscriptCard(entry.data?.card)).toBeDefined();
      expect(entry.data?.card).toMatchObject({
        title: `Goal runner · ${entry.data?.decision}`,
        status: entry.data?.decision,
        body: entry.data?.reason,
        fields: [{ label: "Continuation", value: `${entry.data?.continuation}/1` }],
        at: expect.any(Number),
      });
    }
    const decisions = decisionEntries.map((entry) => entry.data);
    expect(decisions).toContainEqual(
      expect.objectContaining({
        decision: "continue",
        reason: "Run settled; no pending messages or compaction; active goal has budget remaining.",
        requestId: `oppi-goal:${goal.id}:1:1`,
      }),
    );
    expect(decisions).toContainEqual(
      expect.objectContaining({ decision: "stop", reason: goal.blocker }),
    );
    expect(entries.filter((entry) => entry.kind === "pi.user")).toHaveLength(2);
    expect(entries.filter((entry) => entry.kind === "oppi-goal")).toHaveLength(3);
    const ui = await f.harness.snapshot(DurableUI, conversation.id, context);
    expect(ui!.notifications["status:goal"]!.statusText).toBe("goal: Blocked 1/1");
    expect(JSON.stringify(ui!.notifications["widget:goal"]!.nativeSurface)).toContain(goal.blocker);
    expect(f.faux.state.callCount).toBe(3);
  });

  it.each(["blocked", "paused", "complete"] as const)(
    "does not continue a %s goal and removes its active section",
    async (status) => {
      const f = await fixture([
        tool("create_goal", { objective: "Only continue while active" }),
        tool("update_goal", {
          status,
          blocker: status === "blocked" ? "Need explicit decision" : undefined,
          summary: "Verified evidence",
        }),
        (request) => {
          expect(JSON.stringify(request.messages)).not.toContain("## Active goal runner");
          return fauxAssistantMessage("Stopped");
        },
      ]);
      await f.conversation.submit({ type: "input", content: "Create and stop goal" }, context);
      await f.conversation.waitForIdle(context);
      expect(
        (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
      ).toHaveLength(1);
      expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal!.status).toBe(
        status,
      );
      if (status === "complete") {
        const ui = (await f.harness.snapshot(DurableUI, f.conversation.id, context))!;
        expect(ui.notifications["status:goal"]!.statusText).toBeUndefined();
        expect(ui.notifications["widget:goal"]!.widgetLines).toEqual([]);
        expect(ui.notifications["widget:goal"]!.nativeSurface).toBeUndefined();
      }
    },
  );

  it("defers completion for unfinished tasks, then completes with task timing and full evidence", async () => {
    const evidence = "Completion audit: tests and artifacts verified. ".repeat(250).trim();
    const f = await fixture([
      tool("create_goal", {
        objective: "Audit deliverables",
        tasks: [{ id: "test", title: "Run tests", status: "in_progress" }],
        max_continuations: 2,
      }),
      tool("update_goal", { status: "complete", summary: "Not done yet" }),
      fauxAssistantMessage("Need next run"),
      tool("update_goal", {
        status: "complete",
        summary: evidence,
        task_updates: [{ id: "test", status: "completed" }],
      }),
      tool("get_goal", {}),
      fauxAssistantMessage("Evidence-backed completion"),
    ]);
    await f.conversation.submit({ type: "input", content: "Create goal and audit" }, context);
    await f.conversation.waitForIdle(context);
    const goal = (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal!;
    expect(goal).toMatchObject({
      status: "complete",
      summary: evidence,
      continuationCount: 1,
      tasks: [{ id: "test", status: "completed" }],
    });
    expect(goal.tasks[0]!.startedAt).toBeDefined();
    expect(goal.tasks[0]!.completedAt).toBeDefined();
    expect(goal.tasks[0]!.elapsedMs).toBeGreaterThanOrEqual(0);
    const entries = await history(f.conversation);
    expect(JSON.stringify(entries)).toContain(
      "Completion deferred: unfinished tasks remain (Run tests).",
    );
    expect(
      entries
        .filter((entry) => entry.kind === "oppi-goal")
        .map((entry) => entry.data!.goal.summary),
    ).toContain(evidence);
    expect(JSON.stringify(entries.filter((entry) => entry.kind === "pi.tool-result"))).toContain(
      evidence,
    );
  });

  for (const window of ["during create", "before admission", "after admission"] as const) {
    it(`restarts ${window} without losing state, incrementing twice, or sending a duplicate continuation`, async () => {
      const f = await fixture(
        [
          tool("create_goal", {
            objective: "Survive restart",
            tasks: [{ id: "a", title: "Still pending" }],
            max_continuations: 1,
          }),
          fauxAssistantMessage("Original run done"),
          fauxAssistantMessage("Continuation answered"),
        ],
        {
          cut: (writes) =>
            window === "during create"
              ? writes.some((write) => write.type === "entry" && write.value.kind === "oppi-goal")
              : window === "before admission"
                ? writes.some(
                    (write) =>
                      write.type === "task" &&
                      write.value.kind === "oppi.goal-runner" &&
                      write.value.state.status === "running" &&
                      write.value.state.checkpoint.phase === "submit",
                  )
                : writes.some(
                    (write) =>
                      write.type === "submission" &&
                      write.value.requestId?.startsWith("oppi-goal:") === true,
                  ),
        },
      );
      await f.conversation.submit({ type: "input", content: "Explicit autonomous goal" }, context);
      await f.cutReached.promise;
      const closing = f.harness.close(context);
      f.releaseCommit.resolve();
      await closing;
      harnesses.delete(f.harness);
      const restarted = await f.open();
      const conversation = (await restarted.conversation(f.conversation.id, context))!;
      const restored = (await restarted.snapshot(GoalDoc, conversation.id, context))!.goal!;
      expect(restored).toMatchObject({
        objective: "Survive restart",
        status: "active",
        continuationCount: window === "during create" ? 0 : 1,
        tasks: [{ id: "a", title: "Still pending" }],
      });
      restarted.resume();
      await conversation.waitForIdle(context);
      const goal = (await restarted.snapshot(GoalDoc, conversation.id, context))!.goal!;
      expect(goal).toMatchObject({ id: restored.id, status: "blocked", continuationCount: 1 });
      expect(
        (await history(conversation)).filter((entry) => entry.kind === "pi.user"),
      ).toHaveLength(2);
      expect(
        (await history(conversation)).filter(
          (entry) => entry.kind === "oppi-goal-continuation" && entry.data!.decision === "continue",
        ),
      ).toHaveLength(1);
      const continuation = (await history(conversation)).find(
        (entry) => entry.kind === "oppi-goal-continuation" && entry.data?.decision === "continue",
      )!;
      const again = await conversation.submit(
        { type: "input", content: "must deduplicate", requestId: continuation.data!.requestId },
        context,
      );
      expect(await again.status(context)).toMatchObject({ status: "done" });
      expect(
        (await history(conversation)).filter((entry) => entry.kind === "pi.user"),
      ).toHaveLength(2);
      expect(
        (await history(conversation)).filter((entry) => entry.kind === "oppi-goal"),
      ).toHaveLength(3);
      expect(f.faux.state.callCount).toBe(3);
    });
  }

  it("Abort cancels the observer without discarding the goal or launching another run", async () => {
    const entered = gate();
    const f = await fixture([
      tool("create_goal", { objective: "Stop must win" }),
      async (_request, options) => {
        entered.resolve();
        await new Promise<void>((_, reject) => {
          options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
            once: true,
          });
        });
        return fauxAssistantMessage("unreachable");
      },
    ]);
    await f.conversation.submit({ type: "input", content: "Create active goal" }, context);
    await entered.promise;
    await f.conversation.abort(context);
    expect((await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal).toMatchObject({
      objective: "Stop must win",
      status: "active",
      continuationCount: 0,
    });
    expect(
      (await history(f.conversation)).filter((entry) => entry.kind === "pi.user"),
    ).toHaveLength(1);
    expect(
      (await history(f.conversation)).some(
        (entry) => entry.data?.reason === "Goal runner cancelled by Abort/Stop; state retained.",
      ),
    ).toBe(true);
    expect((await f.harness.inspect(context)).tasks).toHaveLength(0);
  });

  it.each([
    { failure: false, duringContinuation: false },
    { failure: true, duringContinuation: false },
    { failure: true, duringContinuation: true },
  ])(
    "waits for compaction and retains state (failure=$failure, continuation=$duringContinuation)",
    async ({ failure, duringContinuation }) => {
      const entered = gate();
      const release = gate();
      const summaryEntered = gate();
      const summaryRelease = gate();
      const f = await fixture(
        [
          tool("create_goal", {
            objective: "Preserve goal across compaction",
            tasks: [{ id: "a", title: "Audit", status: "pending" }],
            max_continuations: duringContinuation ? 2 : 1,
          }),
          ...(duringContinuation
            ? [fauxAssistantMessage("Initial run settled before compaction")]
            : []),
          async () => {
            entered.resolve();
            await release.promise;
            return fauxAssistantMessage("A long result worth compacting. ".repeat(100));
          },
          async () => {
            summaryEntered.resolve();
            await summaryRelease.promise;
            return failure
              ? fauxAssistantMessage("", {
                  stopReason: "error",
                  errorMessage: "summary unavailable",
                })
              : fauxAssistantMessage("Summary retains the objective and evidence");
          },
          fauxAssistantMessage("Continued after compaction"),
        ],
        { compaction: true },
      );
      await f.conversation.submit({ type: "input", content: "Create goal. ".repeat(200) }, context);
      await entered.promise;
      const compaction = await f.conversation.compact(
        "Preserve validation and unrelated changes",
        context,
      );
      await summaryEntered.promise;
      release.resolve();
      // Wait for the actual first submission to settle, not an arbitrary sleep.
      const live = await f.harness.watchDoc(LiveDoc, f.conversation.id, context);
      if (live!.value!.run)
        await new Promise<void>((resolve) => {
          live!.start(async (value) => {
            if (!value?.run) resolve();
          });
        });
      expect(
        (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal!.continuationCount,
      ).toBe(duringContinuation ? 1 : 0);
      const checkpoint = await f.harness.getTask(compaction, context);
      expect(checkpoint!.memos!["oppi-goal-before-compact"]).toMatchObject({
        goal: {
          objective: "Preserve goal across compaction",
          continuationCount: duringContinuation ? 1 : 0,
        },
      });
      summaryRelease.resolve();
      await f.harness.waitForTask(compaction, context);
      await live!.stop();
      await f.conversation.waitForIdle(context);
      const goal = (await f.harness.snapshot(GoalDoc, f.conversation.id, context))!.goal!;
      expect(goal.objective).toBe("Preserve goal across compaction");
      expect(goal.tasks[0]!.title).toBe("Audit");
      expect(goal.continuationCount).toBe(duringContinuation ? 1 : failure ? 0 : 1);
      if (failure) expect(goal.blocker).toContain("Context compaction failed:");
      const entries = await history(f.conversation);
      for (const entry of entries.filter(
        (item) =>
          item.kind === "oppi-goal-continuation" &&
          ["wait", "resume", "stop"].includes(item.data!.decision),
      )) {
        expect(entry.model).toBeUndefined();
        expect(entry.data?.card).toMatchObject({
          title: `Goal runner · ${entry.data!.decision}`,
          body: entry.data!.reason,
        });
      }
      expect(
        entries.some(
          (entry) => entry.data?.decision === "wait" && entry.data.reason.includes("compaction"),
        ),
      ).toBe(true);
      expect(
        entries.some(
          (entry) =>
            entry.data?.decision === (failure ? "stop" : "resume") &&
            entry.data.reason.includes("compaction"),
        ),
      ).toBe(true);
    },
  );
});

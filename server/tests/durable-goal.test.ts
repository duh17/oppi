import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
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
  type StorageWrite,
  type Conversation,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { DurableGoal, GoalDoc } from "../extensions/durable/goal/durable.js";
import { DurableUI } from "../extensions/durable/durable-ui.js";

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
  options: { compaction?: boolean; cut?: (writes: readonly StorageWrite[]) => boolean } = {},
) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-goal-"));
  console.info(`Durable goal integration artifacts: ${dir}`);
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

describe("Durable goal", () => {
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
    const decisions = entries
      .filter((entry) => entry.kind === "oppi-goal-continuation")
      .map((entry) => entry.data);
    expect(decisions).toContainEqual(
      expect.objectContaining({
        decision: "continue",
        reason: "Run settled; no pending messages or compaction; active goal has budget remaining.",
        requestId: `oppi-goal:${goal.id}:1`,
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
      const again = await conversation.submit(
        { type: "input", content: "must deduplicate", requestId: `oppi-goal:${goal.id}:1` },
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

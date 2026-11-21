import { describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type {
  Conversation,
  Harness,
  TaskDefinition,
  ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { DurableUIProjection } from "../src/durable-ui-projection.js";
import { requestUI, type UIRequest, type UIResponse, type UIState } from "../src/durable-ui.js";
import { deriveView, DurableWorkingWords, pickPhrase } from "../plugins/working-words/server.js";
import type { SessionBackendEvent } from "../src/pi-events.js";

const empty = (): UIState => ({ requests: {}, notifications: {} });
const taskId = 1 as ToolExecutionApi["taskId"];
const conversationId = 1 as ToolExecutionApi["conversationId"];
const entry = (request: UIRequest) => ({ taskId, request });

async function project(initial: UIState) {
  let change!: (value: UIState) => Promise<void>;
  const events: SessionBackendEvent[] = [];
  const watch = {
    value: initial,
    start: (listener: typeof change) => {
      change = listener;
    },
    stop: async () => {},
  };
  const conversation = {
    id: conversationId,
    commit: async (fn: (tx: unknown) => unknown) => fn({ doc: async () => initial }),
  };
  const projection = await DurableUIProjection.create(
    { watchDoc: async () => watch } as unknown as Harness,
    conversation as unknown as Conversation,
    (event) => events.push(event),
  );
  projection.start();
  return { events, change: (state: UIState) => change(state), stop: () => projection.stop() };
}

/** A tool call's api over `ui`, with `answer` as its committed answer signal. */
function tool(ui: UIState, answer?: { value: UIResponse } | { expired: true }) {
  const published: UIState[] = [];
  const api = {
    taskId,
    conversationId,
    now: () => 1_000,
    readSignal: vi.fn(async () => answer),
    snapshot: vi.fn(async () => structuredClone(ui)),
    commit: vi.fn(async (fn: (tx: unknown) => unknown) => {
      const result = await fn({ doc: async () => ui });
      published.push(structuredClone(ui));
      return result;
    }),
  };
  return { api: api as unknown as ToolExecutionApi, published };
}

describe("durable UI document safety", () => {
  it.each(["message_end", "agent_end", "tool_execution_end"])(
    "never emits document-controlled %s events",
    async (type) => {
      const ui = empty();
      ui.requests.dialog = entry({
        id: "forged-id",
        method: "confirm",
        title: "Safe",
        type,
        extra: true,
        details: { fullOutputPath: "/private/file" },
      } as UIRequest);
      ui.notifications.slot = {
        id: "forged-slot",
        method: "setWorkingMessage",
        message: "Safe",
        type,
        details: { fullOutputPath: "/private/file" },
      } as UIState["notifications"][string];
      ui.requests.unknown = entry({
        id: "unknown",
        method: "tool_execution_end",
      } as unknown as UIRequest);
      ui.notifications.unknown = {
        id: "unknown",
        method: "message_end",
      } as unknown as UIState["notifications"][string];
      const p = await project(ui);
      expect(p.events).toEqual([
        expect.objectContaining({
          type: "extension_ui_request",
          id: "dialog",
          method: "confirm",
          title: "Safe",
        }),
        expect.objectContaining({
          type: "extension_ui_request",
          id: "slot",
          method: "setWorkingMessage",
          message: "Safe",
        }),
      ]);
      for (const event of p.events) {
        expect(event).not.toHaveProperty("details");
        expect(event).not.toHaveProperty("extra");
      }
      await p.stop();
    },
  );

  it("stores only allowlisted tool fields and parks on the request's answer", async () => {
    const ui = empty();
    const t = tool(ui);
    const outcome = await requestUI(
      t.api,
      {
        id: "dialog",
        method: "confirm",
        title: "Authoritative",
        type: "message_end",
        details: { fullOutputPath: "/private/file" },
      } as UIRequest,
      context,
    );
    expect(t.published).toHaveLength(1);
    expect(t.published[0]!.requests.dialog).toEqual(
      entry({ id: "dialog", method: "confirm", title: "Authoritative" }),
    );
    // No deadline: the park waits for the answer only.
    expect(outcome).toEqual({
      park: {
        sleep: {
          checkpoint: { ui: "dialog" },
          signals: [{ signal: "oppi.ui-answer", key: "dialog" }],
        },
      },
    });
  });

  it("rejects unknown tool UI methods without committing a document", async () => {
    const t = tool(empty());
    await expect(
      requestUI(t.api, { id: "unknown", method: "message_end" } as unknown as UIRequest, context),
    ).rejects.toThrow("Unsupported");
    expect(t.api.commit).not.toHaveBeenCalled();
  });

  it("sets the deadline once, on the Harness clock, and a rerun parks until that first one", async () => {
    const first = tool(empty());
    const parked = await requestUI(
      first.api,
      { id: "dialog", method: "confirm", timeout: 5000 },
      context,
    );
    expect(first.published[0]!.requests.dialog!.request.timeoutAt).toBe(6_000);
    expect(parked.park?.sleep?.until).toBe(6_000);

    // A rerun that never parked (a crash in between) keeps the stored deadline.
    const ui = empty();
    ui.requests.dialog = entry({
      id: "dialog",
      method: "confirm",
      timeout: 5000,
      timeoutAt: 4_000,
    });
    const rerun = tool(ui);
    const again = await requestUI(
      rerun.api,
      { id: "dialog", method: "confirm", timeout: 5000 },
      context,
    );
    expect(again.park?.sleep?.until).toBe(4_000);
    expect(rerun.published[0]!.requests.dialog!.request.timeoutAt).toBe(4_000);
  });

  it("returns the delivered answer and takes down a request still up", async () => {
    const ui = empty();
    ui.requests.dialog = entry({ id: "dialog", method: "input" });
    const response = { id: "dialog", value: "answer" };
    const t = tool(ui, { value: response });
    expect(await requestUI(t.api, { id: "dialog", method: "input" }, context)).toEqual({
      response,
    });
    expect(ui.requests).toEqual({});
  });

  it("answers cancelled when the deadline came first", async () => {
    const ui = empty();
    ui.requests.dialog = entry({ id: "dialog", method: "input", timeout: 10, timeoutAt: 1 });
    const t = tool(ui, { expired: true });
    expect(await requestUI(t.api, { id: "dialog", method: "input" }, context)).toEqual({
      response: { id: "dialog", cancelled: true },
    });
    expect(ui.requests).toEqual({});
  });
});

describe("durable working words commit interleavings", () => {
  it.each(["idle", "abort"])("does not lose %s while publishing a busy frame", async (edge) => {
    const definition = DurableWorkingWords.tasks![0]!.definition as TaskDefinition<
      null,
      { phase: "watch" },
      null,
      object
    >;
    const controller = new AbortController();
    const reason = new Error("invocation aborted");
    let notify!: (value: unknown) => Promise<void>;
    const ui = empty();
    const frames: Array<string | undefined> = [];
    const stop = vi.fn(async () => {});
    const runtime = {
      conversationId,
      signal: controller.signal,
      watchDoc: async () => ({
        value: { run: 1 },
        start: (listener: typeof notify) => {
          notify = listener;
        },
        stop,
      }),
      commit: async (fn: (tx: unknown) => unknown) => {
        await fn({ doc: async () => ui });
        frames.push(ui.notifications["working:message"]?.message);
        if (frames.length === 1) {
          if (edge === "idle") await notify({ kind: "value", value: {}, ops: [], retired: false });
          else controller.abort(reason);
        } else controller.abort(reason);
      },
    };
    const run = definition.phases.watch(
      { state: { checkpoint: { phase: "watch" } } } as Parameters<
        typeof definition.phases.watch
      >[0],
      runtime as unknown as Parameters<typeof definition.phases.watch>[1],
      context,
    );
    const outcome = run.then(
      () => undefined,
      (error: unknown) => error,
    );
    try {
      await vi.waitFor(() => expect(stop).toHaveBeenCalledOnce(), { timeout: 300 });
    } finally {
      controller.abort(reason);
      expect(await outcome).toBe(reason);
    }
    expect(frames[0]).toEqual(expect.any(String));
    expect(frames).toHaveLength(edge === "idle" ? 2 : 1);
    if (edge === "idle") expect(frames[1]).toBeUndefined();
  });
});

describe("durable working words activity", () => {
  const run = { taskId: 7, inputs: [] };
  const live = (value: object) => value as Parameters<typeof deriveView>[0];

  it("maps pi.live to the classic working-message activities", () => {
    expect(deriveView(live({}))).toEqual({ activity: "thinking" });
    expect(deriveView(live({ run }))).toEqual({ run: "7", activity: "thinking" });
    expect(
      deriveView(
        live({
          run,
          generation: {
            attempt: 1,
            message: { content: [{ type: "thinking" }, { type: "text" }] },
          },
        }),
      ),
    ).toEqual({ run: "7", activity: "writing" });
    expect(
      deriveView(
        live({
          run,
          generation: {
            attempt: 1,
            message: { content: [{ type: "text" }, { type: "toolCall" }] },
          },
        }),
      ),
    ).toEqual({ run: "7", activity: "writing" });
    expect(
      deriveView(
        live({
          run,
          tools: [
            { callId: "a", name: "read", status: "running" },
            { callId: "b", name: "bash", status: "running" },
          ],
        }),
      ),
    ).toEqual({ run: "7", activity: "running" });
    expect(
      deriveView(live({ run, tools: [{ callId: "a", name: "ask", status: "running" }] })),
    ).toEqual({
      run: "7",
      activity: "asking",
    });
    // An ask parked on the answer still reads as asking.
    expect(
      deriveView(live({ run, tools: [{ callId: "a", name: "ask", status: "sleeping" }] })),
    ).toEqual({ run: "7", activity: "asking" });
    expect(
      deriveView(
        live({
          run,
          generation: { attempt: 1, message: { content: [{ type: "text" }] } },
          tools: [{ callId: "a", name: "edit", status: "done" }],
        }),
      ),
    ).toEqual({ run: "7", activity: "thinking" });
  });

  // The client's working row shows the turn's time, so the message carries none and is
  // written again only when the run's activity changes, never once a second.
  it("publishes the run's phrase with no clock, only when its activity changes", async () => {
    vi.useFakeTimers();
    try {
      const definition = DurableWorkingWords.tasks![0]!.definition as TaskDefinition<
        null,
        { phase: "watch" },
        null,
        object
      >;
      const controller = new AbortController();
      let notify!: (value: unknown) => Promise<void>;
      const ui = empty();
      const frames: Array<string | undefined> = [];
      const runtime = {
        conversationId,
        signal: controller.signal,
        now: () => Date.now(),
        watchDoc: async () => ({
          value: { run },
          start: (listener: typeof notify) => {
            notify = listener;
          },
          stop: async () => {},
        }),
        commit: async (fn: (tx: unknown) => unknown) => {
          await fn({ doc: async () => ui });
          frames.push(ui.notifications["working:message"]?.message);
        },
      };
      const outcome = definition.phases
        .watch(
          { state: { checkpoint: { phase: "watch" } } } as Parameters<
            typeof definition.phases.watch
          >[0],
          runtime as unknown as Parameters<typeof definition.phases.watch>[1],
          context,
        )
        .then(
          () => undefined,
          (error: unknown) => error,
        );

      await vi.advanceTimersByTimeAsync(0);
      expect(frames).toEqual([pickPhrase("thinking", "7")]);
      await vi.advanceTimersByTimeAsync(10_000);
      expect(frames).toHaveLength(1);

      await notify({
        kind: "value",
        value: { run, tools: [{ callId: "a", name: "bash", status: "running" }] },
        ops: [],
        retired: false,
      });
      await vi.advanceTimersByTimeAsync(0);
      expect(frames).toEqual([pickPhrase("thinking", "7"), pickPhrase("running", "7")]);

      const reason = new Error("stop");
      controller.abort(reason);
      await vi.advanceTimersByTimeAsync(0);
      expect(await outcome).toBe(reason);
    } finally {
      vi.useRealTimers();
    }
  });
});

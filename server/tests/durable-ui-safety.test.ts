import { describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import type {
  Conversation,
  Harness,
  TaskDefinition,
  ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { DurableUIProjection } from "../src/durable-ui-projection.js";
import { requestUI, type UIRequest, type UIState } from "../extensions/durable/durable-ui.js";
import { DurableWorkingWords } from "../extensions/durable/working-words/durable.js";
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

function tool(ui: UIState, saved?: { id: string; value: string }) {
  const published: UIState[] = [];
  const api = {
    taskId,
    conversationId,
    memo: vi.fn(async (_key: string, value: unknown, writeContext?: Context) =>
      writeContext ? value : saved,
    ),
    commit: vi.fn(async (fn: (tx: unknown) => unknown) => {
      await fn({ doc: async () => ui });
      published.push(structuredClone(ui));
    }),
    watchDoc: vi.fn(async () => ({ value: ui, start: () => {}, stop: async () => {} })),
  };
  return { api: api as unknown as ToolExecutionApi, published };
}

function abortContext(controller: AbortController): Context {
  return Object.create(context, { abortSignal: { value: controller.signal } }) as Context;
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

  it.each(["requests", "notifications"] as const)(
    "caps %s fan-out at 32 and emits one error on attach and update",
    async (map) => {
      const ui = empty();
      for (let i = 0; i < 100; i++) {
        const id = `slot:${i}`;
        if (map === "requests") ui.requests[id] = entry({ id, method: "confirm" });
        else ui.notifications[id] = { id, method: "setStatus", statusKey: id, statusText: "ready" };
      }
      const p = await project(ui);
      expect(p.events.filter((e) => e.type === "extension_ui_request")).toHaveLength(32);
      expect(p.events.filter((e) => e.type === "prompt_error")).toHaveLength(1);
      p.events.length = 0;
      await p.change(structuredClone(ui));
      expect(p.events).toEqual([expect.objectContaining({ type: "prompt_error" })]);
      await p.stop();
    },
  );

  it("settles a replaced pending body before emitting its authoritative replacement", async () => {
    const ui = empty();
    ui.requests.dialog = entry({ id: "dialog", method: "confirm", title: "Preseeded" });
    const p = await project(ui);
    const next = structuredClone(ui);
    next.requests.dialog!.request.title = "Authoritative";
    await p.change(next);
    expect(p.events.slice(1)).toEqual([
      { type: "extension_ui_request_settled", id: "dialog" },
      expect.objectContaining({
        type: "extension_ui_request",
        id: "dialog",
        title: "Authoritative",
      }),
    ]);
    await p.stop();
  });

  it.each([false, true])(
    "stores only allowlisted tool fields and replaces an unanswered same-task preseed (seeded=%s)",
    async (seeded) => {
      const ui = empty();
      if (seeded)
        ui.requests.dialog = entry({ id: "dialog", method: "confirm", title: "Preseeded" });
      const t = tool(ui);
      const controller = new AbortController();
      const waiting = requestUI(
        t.api,
        {
          id: "dialog",
          method: "confirm",
          title: "Authoritative",
          type: "message_end",
          details: { fullOutputPath: "/private/file" },
        } as UIRequest,
        abortContext(controller),
      );
      const outcome = waiting.then(
        () => undefined,
        (error: unknown) => error,
      );
      try {
        await vi.waitFor(() => expect(t.published).toHaveLength(1));
        expect(t.published[0]!.requests.dialog).toEqual(
          entry({ id: "dialog", method: "confirm", title: "Authoritative" }),
        );
      } finally {
        controller.abort(new Error("cancel wait"));
        expect(await outcome).toEqual(new Error("cancel wait"));
      }
    },
  );

  it.each(["requests", "notifications"] as const)(
    "refuses publication when %s exceeds capacity",
    async (map) => {
      const ui = empty();
      for (let i = 0; i < 33; i++) {
        const id = `slot:${i}`;
        if (map === "requests") ui.requests[id] = entry({ id, method: "confirm" });
        else ui.notifications[id] = { id, method: "setWorkingMessage" };
      }
      const t = tool(ui);
      const controller = new AbortController();
      let finished = false;
      const outcome = requestUI(t.api, { id: "new", method: "confirm" }, abortContext(controller))
        .then(
          () => undefined,
          (error: unknown) => error,
        )
        .finally(() => {
          finished = true;
        });
      await vi.waitFor(() => expect(finished || t.published.length > 0).toBe(true));
      controller.abort(new Error("Unexpected wait instead of capacity rejection"));
      expect(await outcome).toEqual(
        expect.objectContaining({ message: expect.stringMatching(/limit/i) }),
      );
      expect(ui.requests).not.toHaveProperty("new");
    },
  );

  it("rejects unknown tool UI methods without committing a document", async () => {
    const t = tool(empty());
    await expect(
      requestUI(t.api, { id: "unknown", method: "message_end" } as unknown as UIRequest, context),
    ).rejects.toThrow("Unsupported");
    expect(t.api.commit).not.toHaveBeenCalled();
  });

  it("preserves the first absolute deadline on replay of the same tool payload", async () => {
    const ui = empty();
    const timeoutAt = Date.now() + 5000;
    ui.requests.dialog = entry({ id: "dialog", method: "confirm", timeout: 5000, timeoutAt });
    const t = tool(ui);
    const controller = new AbortController();
    const outcome = requestUI(
      t.api,
      { id: "dialog", method: "confirm", timeout: 5000 },
      abortContext(controller),
    ).then(
      () => undefined,
      (error: unknown) => error,
    );
    await vi.waitFor(() => expect(t.published).toHaveLength(1));
    controller.abort(new Error("cancel wait"));
    expect(await outcome).toEqual(new Error("cancel wait"));
    expect(t.published[0]!.requests.dialog!.request.timeoutAt).toBe(timeoutAt);
  });

  it("deletes an answered row on memo-hit replay without publishing or waiting", async () => {
    const ui = empty();
    const response = { id: "dialog", value: "answer" };
    ui.requests.dialog = { ...entry({ id: "dialog", method: "input" }), response };
    const t = tool(ui, response);
    expect(await requestUI(t.api, { id: "dialog", method: "input" }, context)).toEqual(response);
    expect(ui.requests).toEqual({});
    expect(t.api.watchDoc).not.toHaveBeenCalled();
    expect(t.published).toHaveLength(1);
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
          if (edge === "idle") await notify({});
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

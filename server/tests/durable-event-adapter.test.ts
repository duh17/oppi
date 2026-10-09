import { describe, expect, it } from "vitest";

import { adaptDurableEvent, createAdapterState } from "../src/durable-event-adapter.js";
import { DurableEventProjection } from "../src/durable-event-projection.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { SessionEventProcessor } from "../src/session-events.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";

describe("durable event adapter", () => {
  it("carries a projected assistant error into agent_end for the shared turn metric path", () => {
    const state = createAdapterState();
    adaptDurableEvent({ type: "run_start" } as never, state);
    adaptDurableEvent(
      {
        type: "message_end",
        entry: {
          id: 4,
          model: [{ role: "assistant", stopReason: "error", errorMessage: "overloaded" }],
        },
      } as never,
      state,
    );
    const events = adaptDurableEvent({ type: "run_end" } as never, state);
    expect(events[0]).toMatchObject({
      type: "agent_end",
      messages: [{ stopReason: "error", errorMessage: "overloaded" }],
    });
    expect(events[1]).toMatchObject({ type: "agent_settled" });
  });

  it("does not invent an error when the projected assistant stopped cleanly", () => {
    const state = createAdapterState();
    adaptDurableEvent(
      {
        type: "message_end",
        entry: { id: 4, model: [{ role: "assistant", stopReason: "stop" }] },
      } as never,
      state,
    );
    const events = adaptDurableEvent({ type: "run_end" } as never, state);
    expect(events[0]).toMatchObject({ type: "agent_end", messages: [] });
  });

  it("keeps turn_error when a same-run snapshot lands between the error and run_end", async () => {
    const harness = { snapshot: async () => undefined } as never;
    const projection = new DurableEventProjection(harness, () => ({}));
    const metrics: Array<{ metric: string; tags?: Record<string, string> }> = [];
    const processor = new SessionEventProcessor({
      mobileRenderers: new MobileRendererRegistry(),
      storage: {} as never,
      broadcast: () => undefined,
      persistSessionNow: () => undefined,
      markSessionDirty: () => undefined,
      metrics: {
        record(metric: string, _value: number, tags?: Record<string, string>) {
          metrics.push({ metric, tags });
        },
      } as never,
    });
    const active = {
      session: {
        id: "sess-1",
        status: "busy",
        createdAt: 1,
        lastActivity: 1,
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
        serverDurable: { conversationId: 7 },
      },
      pendingUIRequests: new Map(),
      toolOutputSnapshots: new ToolOutputSnapshots(),
      streamedAssistantText: "",
      toolNames: new Map(),
      streamingToolUpdatesSeen: new Map(),
    };
    const snap = (entries: unknown[] = []) =>
      ({
        type: "snapshot",
        entries,
        run: { inputs: [1] },
        tools: [],
        compactions: [],
        inbox: [],
        agent: {},
        usage: {},
      }) as never;

    projection.snapshot(snap(), false);
    await projection.batch([
      {
        type: "message_end",
        entry: {
          id: 4,
          conversationId: 1,
          kind: "assistant",
          model: [{ role: "assistant", stopReason: "error", errorMessage: "overloaded" }],
        },
      } as never,
    ]);
    // Same run, and the snapshot does not replay the assistant entry.
    projection.snapshot(snap(), false);
    const ended = await projection.batch([{ type: "run_end", inputs: [1] } as never]);
    const agentEnd = ended.find((event) => event.type === "agent_end");
    expect(agentEnd).toMatchObject({
      type: "agent_end",
      messages: [{ stopReason: "error", errorMessage: "overloaded" }],
    });
    processor.updateSessionFromEvent("sess-1", active as never, agentEnd as never);
    expect(metrics).toContainEqual({
      metric: "server.turn_error",
      tags: { sessionId: "sess-1", runtime: "durable", category: "overloaded" },
    });
  });
});

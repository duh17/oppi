import { describe, expect, it } from "vitest";

import { DurableEventProjection } from "../src/durable-event-projection.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { SessionEventProcessor } from "../src/session-events.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";

type Sample = { metric: string; tags?: Record<string, string> };

function entry(id: number, kind: string, message: Record<string, unknown>) {
  return { id, conversationId: 1, kind, model: [message] };
}

function user(id: number, kind = "pi.user") {
  return entry(id, kind, { role: "user", content: kind === "pi.user" ? "go" : "summary" });
}

function assistant(id: number, stopReason: string, errorMessage?: string) {
  return entry(id, "pi.assistant", {
    role: "assistant",
    stopReason,
    ...(errorMessage ? { errorMessage } : {}),
  });
}

function snap(entries: unknown[]) {
  return {
    type: "snapshot",
    entries,
    run: { inputs: [1] },
    tools: [],
    compactions: [],
    inbox: [],
    agent: {},
    usage: {},
  } as never;
}

function messageEnd(row: ReturnType<typeof assistant>) {
  return { type: "message_end", entry: row } as never;
}

/** Project a run and return turn_error samples recorded from its agent_end. */
async function turnErrors(steps: {
  attached: unknown[];
  live?: unknown[];
  replaced?: unknown[];
}): Promise<Sample[]> {
  const projection = new DurableEventProjection(
    { snapshot: async () => undefined } as never,
    () => ({}),
  );
  const metrics: Sample[] = [];
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
  projection.snapshot(snap(steps.attached), false);
  if (steps.live) await projection.batch(steps.live as never);
  if (steps.replaced) projection.snapshot(snap(steps.replaced), false);
  const ended = await projection.batch([{ type: "run_end", inputs: [1] } as never]);
  const agentEnd = ended.find((event) => event.type === "agent_end");
  processor.updateSessionFromEvent("sess-1", active as never, agentEnd as never);
  return metrics.filter((sample) => sample.metric === "server.turn_error");
}

const overloaded = {
  metric: "server.turn_error",
  tags: { sessionId: "sess-1", runtime: "durable", category: "overloaded" },
};

describe("durable turn_error", () => {
  it("records turn_error when the ending run's assistant stopped with error", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      live: [messageEnd(assistant(4, "error", "overloaded"))],
    });
    expect(errors).toEqual([overloaded]);
  });

  it("does not invent turn_error when the ending assistant stopped cleanly", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      live: [messageEnd(assistant(4, "stop"))],
    });
    expect(errors).toEqual([]);
  });

  it("keeps turn_error when a same-run snapshot still has that error", async () => {
    const error = assistant(4, "error", "overloaded");
    const errors = await turnErrors({
      attached: [user(1)],
      live: [messageEnd(error)],
      // Committed active context: the snapshot includes the error, not a newer success.
      replaced: [user(1), error],
    });
    expect(errors).toEqual([overloaded]);
  });

  it("does not keep a stale error when a same-run snapshot has a newer success", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      live: [messageEnd(assistant(4, "error", "overloaded"))],
      replaced: [user(1), assistant(4, "error", "overloaded"), assistant(5, "stop")],
    });
    expect(errors).toEqual([]);
  });

  it("records turn_error when a snapshot's overflow error is followed by a compaction summary", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      replaced: [user(1), assistant(4, "error", "overloaded"), user(5, "pi.compaction")],
    });
    expect(errors).toEqual([overloaded]);
  });

  it("records turn_error when a snapshot's error is followed by a reset handoff", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      replaced: [user(1), assistant(4, "error", "overloaded"), user(5, "pi.reset")],
    });
    expect(errors).toEqual([overloaded]);
  });

  it("does not record an earlier turn's error after a newer pi.user", async () => {
    const errors = await turnErrors({
      attached: [user(1), assistant(2, "error", "overloaded"), user(3)],
    });
    expect(errors).toEqual([]);
  });
});

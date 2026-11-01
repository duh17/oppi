import { describe, expect, it } from "vitest";

import { adaptDurableEvent, createAdapterState } from "../src/durable-event-adapter.js";
import { DurableEventProjection } from "../src/durable-event-projection.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
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

/** Project a run and return the failed server.turn events recorded from its agent_end. */
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
      record(metric: string, _fields: unknown, tags?: Record<string, string>) {
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
  return metrics.filter(
    (sample) => sample.metric === "server.turn" && sample.tags?.status === "error",
  );
}

const overloaded = {
  metric: "server.turn",
  tags: { runtime: "durable", status: "error", error_kind: "overloaded" },
};

describe("durable turn error", () => {
  it("records turn error when the ending run's assistant stopped with error", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      live: [messageEnd(assistant(4, "error", "overloaded"))],
    });
    expect(errors).toEqual([overloaded]);
  });

  it("does not invent turn error when the ending assistant stopped cleanly", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      live: [messageEnd(assistant(4, "stop"))],
    });
    expect(errors).toEqual([]);
  });

  it("keeps turn error when a same-run snapshot still has that error", async () => {
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

  it("records turn error when a snapshot's overflow error is followed by a compaction summary", async () => {
    const errors = await turnErrors({
      attached: [user(1)],
      replaced: [user(1), assistant(4, "error", "overloaded"), user(5, "pi.compaction")],
    });
    expect(errors).toEqual([overloaded]);
  });

  it("records turn error when a snapshot's error is followed by a reset handoff", async () => {
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

const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

type Severity = "info" | "warn" | "error";

/** A `pi.tool-result` entry as pi-durable commits one: the diagnostics block ends the content. */
function toolResult(
  content: Array<Record<string, unknown>>,
  diagnostics: Array<{ severity: Severity; message: string }>,
  options: { toolName?: string; isError?: boolean } = {},
) {
  const toolName = options.toolName ?? "read";
  return {
    id: 9,
    conversationId: 1,
    kind: "pi.tool-result",
    model: [
      {
        role: "toolResult",
        toolCallId: "tc",
        toolName,
        content,
        isError: options.isError ?? false,
        timestamp: 1,
      },
    ],
    data: { diagnostics },
  };
}

/** What a client is sent for one committed tool result: the Durable adapter, then Pi's protocol. */
function liveToolMessages(result: unknown, toolName = "read"): Array<Record<string, unknown>> {
  const state = createAdapterState();
  const ctx: TranslationContext = {
    sessionId: "sess-1",
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    mobileRenderers: new MobileRendererRegistry(),
    toolNames: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
  const events = [
    ...adaptDurableEvent(
      { type: "tool_execution_start", toolCallId: "tc", toolName, args: {} } as never,
      state,
    ),
    ...adaptDurableEvent(
      { type: "tool_execution_end", toolCallId: "tc", toolName, entry: result } as never,
      state,
    ),
  ];
  const messages: Array<Record<string, unknown>> = [];
  for (const event of events) messages.push(...translatePiEvent(event, ctx));
  return messages;
}

/** The tool output text a client accumulates from its `tool_output` messages. */
function liveToolOutput(messages: Array<Record<string, unknown>>): string {
  return messages
    .filter((message) => message.type === "tool_output")
    .map((message) => String(message.output ?? ""))
    .join("");
}

describe("durable tool result diagnostics", () => {
  it("hides the model-only block a read image leaves under its output", () => {
    const messages = liveToolMessages(
      toolResult(
        [
          { type: "image", data: PNG, mimeType: "image/png" },
          { type: "text", text: "<harness>\n[info] Read image file [image/png].\n</harness>" },
        ],
        [{ severity: "info", message: "Read image file [image/png]." }],
      ),
    );
    expect(liveToolOutput(messages)).toBe("");
    expect(JSON.stringify(messages)).not.toContain("<harness>");
    expect(JSON.stringify(messages)).not.toContain("Read image file");
  });

  it("shows a warn diagnostic as the note the client keeps", () => {
    const truncated = "Output truncated to its end: 12 lines, 900 bytes dropped";
    const messages = liveToolMessages(
      toolResult(
        [
          { type: "text", text: "kept lines" },
          { type: "text", text: `<harness>\n[info] read\n[warn] ${truncated}\n</harness>` },
        ],
        [
          { severity: "info", message: "read" },
          { severity: "warn", message: truncated },
        ],
      ),
    );
    const output = liveToolOutput(messages);
    expect(output).toBe(`kept lines\n${truncated}`);
    expect(JSON.stringify(messages)).not.toContain("<harness>");
    expect(output).not.toContain("[info]");
  });

  it("keeps <harness> text a tool printed itself", () => {
    const own = "<harness>\n[info] echoed by the tool\n</harness>";
    const messages = liveToolMessages(
      toolResult(
        [
          { type: "text", text: `output:\n${own}` },
          { type: "text", text: "<harness>\n[info] a model note\n</harness>" },
        ],
        [{ severity: "info", message: "a model note" }],
      ),
    );
    expect(liveToolOutput(messages)).toBe(`output:\n${own}`);
  });
});

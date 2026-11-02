import { describe, expect, it } from "vitest";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import { fauxAssistantMessage, fauxText, fauxThinking } from "@earendil-works/pi-ai/providers/faux";
import type { ConversationView, EntryRecord, LiveState } from "@earendil-works/pi-durable";
import { DurableClassicEvents } from "../src/durable-classic-events.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { SessionEventProcessor } from "../src/session-events.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import type { ServerMessage } from "../src/types.js";

type Sample = { metric: string; tags?: Record<string, string> };

const usage: Usage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function entry(id: number, kind: string, message: Record<string, unknown>): EntryRecord {
  return { id, conversationId: 1, kind, model: [message] } as never;
}

function user(id: number, kind = "pi.user"): EntryRecord {
  return entry(id, kind, { role: "user", content: kind === "pi.user" ? "go" : "summary" });
}

function assistant(id: number, stopReason: string, errorMessage?: string): EntryRecord {
  return entry(id, "pi.assistant", {
    role: "assistant",
    content: [],
    stopReason,
    ...(errorMessage ? { errorMessage } : {}),
  });
}

function view(entries: readonly EntryRecord[], live: LiveState = {}): ConversationView {
  return { conversation: { id: 1 } as never, entries, docs: { "pi.live": live } } as never;
}

const running: LiveState = { run: { taskId: 5, inputs: [1] } } as never;

/** A projector over a fixed first value; the Harness has no documents, tasks, or submissions. */
function projector(initial: ConversationView): Promise<DurableClassicEvents> {
  const harness = {
    snapshot: async () => undefined,
    getTask: async () => undefined,
    submission: async () => undefined,
  };
  const conversation = {
    id: 1,
    watch: async () => ({ value: initial, start() {}, stop: async () => ({ reason: "stopped" }) }),
  };
  return DurableClassicEvents.open(harness as never, conversation as never, () => ({}));
}

/** Tell `values` after `initial`, returning every Pi event in order. */
async function tell(
  initial: ConversationView,
  values: readonly ConversationView[],
): Promise<AgentSessionEvent[]> {
  const events = await projector(initial);
  const told: AgentSessionEvent[] = [];
  for (const value of values) told.push(...(await events.frame(value)).events);
  return told;
}

/** The failed `server.turn` samples `SessionEventProcessor` records from a run's `agent_end`. */
function turnErrors(events: readonly AgentSessionEvent[]): Sample[] {
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
  const agentEnd = events.find((event) => event.type === "agent_end");
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
    const error = assistant(4, "error", "overloaded");
    const events = await tell(view([user(1)], running), [view([user(1), error], {})]);
    expect(turnErrors(events)).toEqual([overloaded]);
  });

  it("does not invent turn error when the ending assistant stopped cleanly", async () => {
    const events = await tell(view([user(1)], running), [view([user(1), assistant(4, "stop")])]);
    expect(turnErrors(events)).toEqual([]);
  });

  it("records turn error when the error is followed by a compaction summary", async () => {
    const error = assistant(2, "error", "overloaded");
    const events = await tell(view([user(1), error], running), [
      view([user(1), error, user(3, "pi.compaction")]),
    ]);
    expect(turnErrors(events)).toEqual([overloaded]);
  });

  it("does not record an earlier turn's error after a newer pi.user", async () => {
    const rows = [user(1), assistant(2, "error", "overloaded"), user(3)];
    const events = await tell(view(rows, running), [view(rows)]);
    expect(turnErrors(events)).toEqual([]);
  });
});

function translationContext(): TranslationContext {
  return {
    sessionId: "sess-1",
    mobileRenderers: new MobileRendererRegistry(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
}

function translate(events: readonly AgentSessionEvent[]): ServerMessage[] {
  const ctx = translationContext();
  return events.flatMap((event) => translatePiEvent(event, ctx));
}

function partial(content: AssistantMessage["content"], timestamp = 1): AssistantMessage {
  return { ...fauxAssistantMessage(content, { timestamp }), usage, stopReason: "stop" };
}

function streaming(message: AssistantMessage): ConversationView {
  return view([user(1)], { ...running, generation: { attempt: 1, message } } as never);
}

describe("durable live text", () => {
  it("keeps prefix streaming as a suffix delta and replaces a non-prefix rewrite", async () => {
    const messages = translate(
      await tell(view([user(1)], running), [
        streaming(partial([fauxText("Hello world")])),
        streaming(partial([fauxText("Hello world!")])),
        streaming(partial([fauxText("Hi")])),
      ]),
    );
    const deltas = messages.filter(
      (message): message is Extract<ServerMessage, { type: "text_delta" }> =>
        message.type === "text_delta",
    );
    expect(deltas.map(({ delta, replace }) => ({ delta, replace }))).toEqual([
      { delta: "Hello world", replace: undefined },
      { delta: "!", replace: undefined },
      { delta: "Hi", replace: true },
    ]);
  });

  it("replaces thinking the same way", async () => {
    const messages = translate(
      await tell(view([user(1)], running), [
        streaming(partial([fauxThinking("Plan the whole answer")])),
        streaming(partial([fauxThinking("Shorter")])),
      ]),
    );
    const deltas = messages.filter(
      (message): message is Extract<ServerMessage, { type: "thinking_delta" }> =>
        message.type === "thinking_delta",
    );
    expect(deltas.map(({ delta, replace }) => ({ delta, replace }))).toEqual([
      { delta: "Plan the whole answer", replace: undefined },
      { delta: "Shorter", replace: true },
    ]);
  });

  it("ends a streamed answer with its entry without starting it again", async () => {
    const message = partial([fauxText("Done")]);
    const final = { ...entry(2, "pi.assistant", message as never) };
    const events = await tell(view([user(1)], running), [
      streaming(message),
      view([user(1), final]),
    ]);
    expect(events.map((event) => event.type)).toEqual([
      "message_start",
      "message_update", // text_start
      "message_update", // text_delta
      "message_end",
      "turn_end",
      "agent_end",
      "agent_settled",
    ]);
  });
});

const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";

type Severity = "info" | "warn" | "error";

/** A `pi.tool-result` entry as pi-durable commits one: the diagnostics block ends the content. */
function toolResult(
  content: Array<Record<string, unknown>>,
  diagnostics: Array<{ severity: Severity; message: string }>,
): EntryRecord {
  return {
    id: 9,
    conversationId: 1,
    kind: "pi.tool-result",
    model: [
      {
        role: "toolResult",
        toolCallId: "tc",
        toolName: "read",
        content,
        isError: false,
        timestamp: 1,
      },
    ],
    data: { diagnostics },
  } as never;
}

/** What a client is sent for one tool call that runs and settles with `result`. */
async function liveToolMessages(result: EntryRecord): Promise<ServerMessage[]> {
  const slot = { callId: "tc", name: "read", taskId: 6 };
  const events = await tell(view([user(1)], running), [
    view([user(1)], { ...running, tools: [{ ...slot, status: "running" }] } as never),
    view([user(1), result], {
      ...running,
      tools: [{ ...slot, status: "done", entry: result.id }],
    } as never),
  ]);
  return translate(events);
}

/** The tool output text a client accumulates from its `tool_output` messages. */
function liveToolOutput(messages: readonly ServerMessage[]): string {
  return messages
    .flatMap((message) => (message.type === "tool_output" ? [message.output] : []))
    .join("");
}

describe("durable tool result diagnostics", () => {
  it("hides the model-only block a read image leaves under its output", async () => {
    const messages = await liveToolMessages(
      toolResult(
        [
          { type: "image", data: PNG, mimeType: "image/png" },
          { type: "text", text: "<harness>\n[info] Read image file [image/png].\n</harness>" },
        ],
        [{ severity: "info", message: "Read image file [image/png]." }],
      ),
    );
    expect(messages.some((message) => message.type === "tool_end")).toBe(true);
    expect(liveToolOutput(messages)).toBe("");
    expect(JSON.stringify(messages)).not.toContain("<harness>");
    expect(JSON.stringify(messages)).not.toContain("Read image file");
  });

  it("shows a warn diagnostic as the note the client keeps", async () => {
    const truncated = "Output truncated to its end: 12 lines, 900 bytes dropped";
    const messages = await liveToolMessages(
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

  it("keeps <harness> text a tool printed itself", async () => {
    const own = "<harness>\n[info] echoed by the tool\n</harness>";
    const messages = await liveToolMessages(
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

import { describe, expect, it } from "vitest";
import type { AssistantMessage, Usage } from "@earendil-works/pi-ai";
import { fauxAssistantMessage, fauxText, fauxThinking } from "@earendil-works/pi-ai/providers/faux";
import type { AgentEvent } from "@earendil-works/pi-durable";
import { adaptDurableEvent, createAdapterState } from "../src/durable-event-adapter.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import type { ServerMessage } from "../src/types.js";

const usage: Usage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function partial(content: AssistantMessage["content"], timestamp = 1): AssistantMessage {
  return { ...fauxAssistantMessage(content, { timestamp }), usage, stopReason: "stop" };
}

function context(): TranslationContext {
  return {
    sessionId: "live-text",
    mobileRenderers: new MobileRendererRegistry(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
}

function project(events: AgentEvent[]): ServerMessage[] {
  const state = createAdapterState();
  const ctx = context();
  return events.flatMap((event) =>
    adaptDurableEvent(event, state).flatMap((pi) => translatePiEvent(pi, ctx)),
  );
}

describe("durable live text replacement", () => {
  it("keeps prefix streaming as a suffix delta and replaces a non-prefix rewrite", () => {
    const first = partial([fauxText("Hello world")]);
    const extended = partial([fauxText("Hello world!")]);
    const rewritten = partial([fauxText("Hi")]);
    const messages = project([
      {
        type: "message_update",
        usage,
        changes: [{ type: "message", message: first }],
      },
      {
        type: "message_update",
        usage,
        changes: [{ type: "message", message: extended }],
      },
      {
        type: "message_update",
        usage,
        changes: [{ type: "message", message: rewritten }],
      },
    ]);
    const deltas = messages.filter(
      (message): message is Extract<ServerMessage, { type: "text_delta" }> =>
        message.type === "text_delta",
    );
    expect(deltas.map(({ delta, replace }) => ({ delta, replace }))).toEqual([
      { delta: "Hello world", replace: undefined },
      { delta: "!", replace: undefined },
      { delta: "Hi", replace: true },
    ]);
    expect(deltas.every((message) => message.delta.length >= 0)).toBe(true);
  });

  it("replaces thinking the same way, including a text_end block that is not a prefix", () => {
    const started = partial([fauxThinking("Plan the whole answer")]);
    const replaced = partial([fauxThinking("Shorter")]);
    const messages = project([
      {
        type: "message_update",
        usage,
        changes: [{ type: "message", message: started }],
      },
      {
        type: "message_update",
        usage,
        changes: [{ type: "block", contentIndex: 0, block: fauxThinking("Shorter") }],
      },
    ]);
    const deltas = messages.filter(
      (message): message is Extract<ServerMessage, { type: "thinking_delta" }> =>
        message.type === "thinking_delta",
    );
    expect(deltas.map(({ delta, replace }) => ({ delta, replace }))).toEqual([
      { delta: "Plan the whole answer", replace: undefined },
      { delta: "Shorter", replace: true },
    ]);
    expect(replaced.content[0]).toMatchObject({ type: "thinking", thinking: "Shorter" });
  });
});

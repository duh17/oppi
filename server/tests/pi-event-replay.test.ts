/**
 * Pi event replay tests — feed canonical pi RPC events through translatePiEvent
 * and verify the server produces correct ServerMessage output.
 *
 * Uses protocol/pi-events.json as the fixture. If pi changes its event format,
 * update the fixture and this test will catch translation regressions.
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import type { ServerMessage } from "../src/types.js";

const FIXTURE_PATH = resolve(__dirname, "../../protocol/pi-events.json");

interface PiEvent {
  _label: string;
  type: string;
  [key: string]: unknown;
}

function loadEvents(): PiEvent[] {
  const raw = JSON.parse(readFileSync(FIXTURE_PATH, "utf-8"));
  return raw.events as PiEvent[];
}

function makeContext(): TranslationContext {
  return {
    sessionId: "test-session",
    toolCallIdMap: new Map(),
    partialResults: new Map(),
    lastToolCallId: undefined,
    streamedAssistantText: "",
  };
}

describe("pi event replay", () => {
  const events = loadEvents();

  it("fixture file loads with expected events", () => {
    expect(events.length).toBeGreaterThan(10);
    expect(events.every((e) => typeof e.type === "string")).toBe(true);
  });

  it("every event translates without throwing", () => {
    const ctx = makeContext();
    const failures: string[] = [];

    for (const event of events) {
      // Skip response and extension_ui_request — handled by sessions.ts, not translatePiEvent
      if (event.type === "response" || event.type === "extension_ui_request") continue;

      try {
        const messages = translatePiEvent(event, ctx);
        // Should return an array (possibly empty for unknown events)
        if (!Array.isArray(messages)) {
          failures.push(`${event._label}: returned non-array`);
        }
      } catch (err) {
        failures.push(`${event._label}: ${(err as Error).message}`);
      }
    }

    if (failures.length > 0) {
      expect.fail(`Translation failures:\n${failures.join("\n")}`);
    }
  });

  it("agent_start → agent_start message", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "agent_start");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("agent_start");
  });

  it("agent_end → agent_end message", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "agent_end");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("agent_end");
  });

  it("message_update text_delta → text_delta with delta string", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "text_delta",
    );
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("text_delta");
    expect((messages[0] as { delta: string }).delta).toBe("Let me help you with that. ");
  });

  it("message_update thinking_delta → thinking_delta", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "thinking_delta",
    );
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("thinking_delta");
  });

  it("tool_execution_start → tool_start with tool name and args", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "tool_execution_start" && e.toolName === "bash");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("tool_start");
    const msg = messages[0] as { tool: string; args: Record<string, unknown> };
    expect(msg.tool).toBe("bash");
    expect(msg.args.command).toBe("npm test");
  });

  it("tool_execution_update → tool_output with delta computation", () => {
    const ctx = makeContext();

    // Must process tool_execution_start first to set up toolCallId mapping
    const startEvent = events.find((e) => e.type === "tool_execution_start" && e.toolName === "bash");
    translatePiEvent(startEvent, ctx);

    // First update
    const updates = events.filter((e) => e.type === "tool_execution_update");
    const msg1 = translatePiEvent(updates[0], ctx);
    expect(msg1).toHaveLength(1);
    expect(msg1[0].type).toBe("tool_output");
    expect((msg1[0] as { output: string }).output).toBe("Running tests...\n");

    // Second update — should return only the delta
    const msg2 = translatePiEvent(updates[1], ctx);
    expect(msg2).toHaveLength(1);
    expect((msg2[0] as { output: string }).output).toBe("42 tests passed\n");
  });

  it("tool_execution_end → tool_end", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "tool_execution_end");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("tool_end");
  });

  it("auto_compaction_start → compaction_start", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "auto_compaction_start");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("compaction_start");
    expect((messages[0] as { reason: string }).reason).toBe("Context window 90% full");
  });

  it("auto_compaction_end → compaction_end", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "auto_compaction_end");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("compaction_end");
    const msg = messages[0] as { aborted: boolean; willRetry: boolean };
    expect(msg.aborted).toBe(false);
    expect(msg.willRetry).toBe(false);
  });

  it("auto_retry_start → retry_start", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "auto_retry_start");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("retry_start");
  });

  it("auto_retry_end → retry_end", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "auto_retry_end");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("retry_end");
  });

  it("full session sequence produces coherent message stream", () => {
    const ctx = makeContext();
    const allMessages: ServerMessage[] = [];

    for (const event of events) {
      if (event.type === "response" || event.type === "extension_ui_request") continue;
      const messages = translatePiEvent(event, ctx);
      allMessages.push(...messages);
    }

    // Should have a reasonable number of messages
    expect(allMessages.length).toBeGreaterThan(8);

    // Should contain the core lifecycle events
    const types = allMessages.map((m) => m.type);
    expect(types).toContain("agent_start");
    expect(types).toContain("agent_end");
    expect(types).toContain("text_delta");
    expect(types).toContain("tool_start");
    expect(types).toContain("tool_output");
    expect(types).toContain("tool_end");
  });
});

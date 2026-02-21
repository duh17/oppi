/**
 * Pi event replay tests — feed canonical pi SDK events through translatePiEvent
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
import { MobileRendererRegistry, type StyledSegment } from "../src/mobile-renderer.js";

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
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
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

  it("tool_execution_end → tool_end with details and isError", () => {
    const ctx = makeContext();
    // First tool_execution_end has result.details
    const event = events.find(
      (e) => e.type === "tool_execution_end" && (e as { toolCallId?: string }).toolCallId === "tc-replay-001",
    );
    // Seed partialResults so final text delta is empty (already streamed)
    ctx.partialResults.set("tc-replay-001", "Running tests...\n42 tests passed\n");
    const messages = translatePiEvent(event, ctx);

    const toolEnd = messages.find((m) => m.type === "tool_end");
    expect(toolEnd).toBeDefined();
    expect(toolEnd!.type).toBe("tool_end");
    const te = toolEnd as { type: string; details?: unknown; isError?: boolean };
    expect(te.details).toEqual({ exitCode: 0, durationMs: 1234 });
    expect(te.isError).toBeUndefined(); // isError=false → omitted
  });

  it("tool_execution_end error → tool_end with isError: true", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "tool_execution_end" && (e as { toolCallId?: string }).toolCallId === "tc-replay-err",
    );
    const messages = translatePiEvent(event, ctx);

    const toolEnd = messages.find((m) => m.type === "tool_end");
    expect(toolEnd).toBeDefined();
    const te = toolEnd as { type: string; details?: unknown; isError?: boolean };
    expect(te.details).toEqual({ exitCode: 127, durationMs: 50 });
    expect(te.isError).toBe(true);
  });

  it("tool_execution_end extension → tool_end with extension details", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "tool_execution_end" && (e as { toolCallId?: string }).toolCallId === "tc-replay-ext",
    );
    const messages = translatePiEvent(event, ctx);

    const toolEnd = messages.find((m) => m.type === "tool_end");
    const te = toolEnd as { type: string; tool: string; details?: unknown };
    expect(te.tool).toBe("remember");
    expect(te.details).toEqual({ file: "2026-02-18-mac-studio.md", redacted: false });
  });

  it("tool_execution_end bare (no result) → tool_end without details", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "tool_execution_end" && (e as { toolCallId?: string }).toolCallId === "tc-replay-bare",
    );
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    const te = messages[0] as { type: string; details?: unknown; isError?: boolean };
    expect(te.type).toBe("tool_end");
    expect(te.details).toBeUndefined();
    expect(te.isError).toBeUndefined();
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

  // ── SDK lifecycle events ──

  it("turn_start → turn_start message", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "turn_start");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("turn_start");
  });

  it("turn_end → turn_end message", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "turn_end");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("turn_end");
  });

  it("message_start → empty (structural, no client payload)", () => {
    const ctx = makeContext();
    const event = events.find((e) => e.type === "message_start");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  // ── message_update sub-events ──

  it("message_update start → empty (stream initialization)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "start",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update text_start → empty (bookkeeping)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "text_start",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update text_end → empty (bookkeeping)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "text_end",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update thinking_start → empty (bookkeeping)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "thinking_start",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update thinking_end → empty (bookkeeping)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "thinking_end",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update toolcall_start → empty (redundant with tool_execution_start)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "toolcall_start",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update toolcall_delta → empty (redundant with tool_execution_update)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "toolcall_delta",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update toolcall_end → empty (redundant with tool_execution_end)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "toolcall_end",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update done → empty (message_end is authoritative)", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "done",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(0);
  });

  it("message_update error → error message with stream error", () => {
    const ctx = makeContext();
    const event = events.find(
      (e) => e.type === "message_update" && (e.assistantMessageEvent as { type: string })?.type === "error",
    );
    expect(event).toBeDefined();
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe("error");
    const msg = messages[0] as { error: string };
    expect(msg.error).toContain("aborted");
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
    expect(types).toContain("turn_start");
    expect(types).toContain("turn_end");
    expect(types).toContain("text_delta");
    expect(types).toContain("thinking_delta");
    expect(types).toContain("tool_start");
    expect(types).toContain("tool_output");
    expect(types).toContain("tool_end");
    expect(types).toContain("compaction_start");
    expect(types).toContain("compaction_end");
    expect(types).toContain("retry_start");
    expect(types).toContain("retry_end");
    expect(types).toContain("error"); // from message_update error sub-event
  });
});

describe("mobile renderer integration", () => {
  const events = loadEvents();

  function makeContextWithRenderers(): TranslationContext {
    return {
      ...makeContext(),
      mobileRenderers: new MobileRendererRegistry(),
    };
  }

  it("tool_execution_start → tool_start includes callSegments", () => {
    const ctx = makeContextWithRenderers();
    const event = events.find((e) => e.type === "tool_execution_start" && e.toolName === "bash");
    const messages = translatePiEvent(event, ctx);

    expect(messages).toHaveLength(1);
    const msg = messages[0] as { callSegments?: StyledSegment[] };
    expect(msg.callSegments).toBeDefined();
    expect(msg.callSegments!.length).toBeGreaterThan(0);
    // bash call should show "$ npm test"
    const text = msg.callSegments!.map((s) => s.text).join("");
    expect(text).toContain("npm test");
  });

  it("tool_execution_start without renderer → no callSegments", () => {
    const ctx = makeContext(); // no mobileRenderers
    const event = events.find((e) => e.type === "tool_execution_start" && e.toolName === "bash");
    const messages = translatePiEvent(event, ctx);

    const msg = messages[0] as { callSegments?: StyledSegment[] };
    expect(msg.callSegments).toBeUndefined();
  });

  it("tool_execution_end with details → tool_end includes resultSegments", () => {
    const ctx = makeContextWithRenderers();
    const event = events.find(
      (e) => e.type === "tool_execution_end" && (e as { toolCallId?: string }).toolCallId === "tc-replay-ext",
    );
    const messages = translatePiEvent(event, ctx);

    // remember tool → should have resultSegments
    // Note: remember is not a built-in renderer, but registry might not have it.
    // For this test, let's register a custom renderer:
    ctx.mobileRenderers!.register("remember", {
      renderCall(args) {
        return [{ text: "remember ", style: "bold" }, { text: String(args.text || ""), style: "muted" }];
      },
      renderResult(details: any) {
        return [{ text: "✓ Saved", style: "success" }, { text: ` → ${details?.file || "journal"}`, style: "muted" }];
      },
    });

    const messages2 = translatePiEvent(event, ctx);
    const toolEnd = messages2.find((m) => m.type === "tool_end");
    const te = toolEnd as { resultSegments?: StyledSegment[] };
    expect(te.resultSegments).toBeDefined();
    expect(te.resultSegments!.map((s) => s.text).join("")).toContain("✓ Saved");
  });

  it("tool_execution_end error → resultSegments with error style", () => {
    const ctx = makeContextWithRenderers();
    const event = events.find(
      (e) => e.type === "tool_execution_end" && (e as { toolCallId?: string }).toolCallId === "tc-replay-err",
    );
    const messages = translatePiEvent(event, ctx);

    const toolEnd = messages.find((m) => m.type === "tool_end");
    const te = toolEnd as { resultSegments?: StyledSegment[] };
    expect(te.resultSegments).toBeDefined();
    // bash error with exitCode 127 → "exit 127" with error style
    expect(te.resultSegments!.some((s) => s.style === "error")).toBe(true);
  });

  it("read tool_execution_start → callSegments with path and range", () => {
    const ctx = makeContextWithRenderers();
    const event = events.find((e) => e.type === "tool_execution_start" && e.toolName === "read");
    const messages = translatePiEvent(event, ctx);

    const msg = messages[0] as { callSegments?: StyledSegment[] };
    expect(msg.callSegments).toBeDefined();
    const text = msg.callSegments!.map((s) => s.text).join("");
    expect(text).toContain("src/main.ts");
    expect(text).toContain(":1-50");
  });
});

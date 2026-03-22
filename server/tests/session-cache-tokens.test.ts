/**
 * Cache token accumulation tests.
 *
 * Exercises cacheRead/cacheWrite tracking across the two accumulation paths:
 * 1. Text-present path: applyMessageEndToSession → appendSessionMessage
 * 2. Text-absent path: applyMessageEndToSession → direct += on session.tokens
 *
 * Also covers extractUsage (private) via its observable effects, contextTokens
 * per-message semantics, cost accumulation, and edge cases around malformed
 * or missing usage data.
 */

import { describe, expect, it } from "vitest";
import type { Session } from "../src/types.js";
import { appendSessionMessage, applyMessageEndToSession } from "../src/session-protocol.js";
import type { PiMessage } from "../src/pi-events.js";

function makeSession(overrides?: Partial<Session>): Session {
  const now = Date.now();
  return {
    id: "test-session",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    model: "anthropic/claude-sonnet-4-0",
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeAssistantMessage(
  text: string,
  usage?: PiMessage["usage"],
): PiMessage {
  return {
    role: "assistant",
    content: [{ type: "text", text }],
    usage,
  };
}

function makeToolOnlyMessage(usage?: PiMessage["usage"]): PiMessage {
  return {
    role: "assistant",
    content: [],
    usage,
  };
}

// ─── Single-message accumulation ───

describe("cache tokens: single message", () => {
  it("accumulates cacheRead and cacheWrite from a text message", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("hello", {
        input: 100,
        output: 50,
        cacheRead: 200,
        cacheWrite: 80,
        cost: { total: 0.01 },
      }),
    );

    expect(session.tokens).toEqual({
      input: 100,
      output: 50,
      cacheRead: 200,
      cacheWrite: 80,
    });
  });

  it("accumulates cache tokens via the text-absent (direct) path", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 30,
        output: 10,
        cacheRead: 500,
        cacheWrite: 150,
        cost: { total: 0.005 },
      }),
    );

    expect(session.tokens).toEqual({
      input: 30,
      output: 10,
      cacheRead: 500,
      cacheWrite: 150,
    });
  });
});

// ─── Multi-message accumulation ───

describe("cache tokens: multi-message accumulation", () => {
  it("sums cache tokens across multiple text messages", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("first", {
        input: 50,
        output: 20,
        cacheRead: 100,
        cacheWrite: 40,
        cost: { total: 0.01 },
      }),
    );

    applyMessageEndToSession(
      session,
      makeAssistantMessage("second", {
        input: 60,
        output: 30,
        cacheRead: 300,
        cacheWrite: 0,
        cost: { total: 0.02 },
      }),
    );

    expect(session.tokens).toEqual({
      input: 110,
      output: 50,
      cacheRead: 400,
      cacheWrite: 40,
    });
  });

  it("sums cache tokens across mixed paths (text + tool-only)", () => {
    const session = makeSession();

    // Text message (goes through appendSessionMessage)
    applyMessageEndToSession(
      session,
      makeAssistantMessage("thinking...", {
        input: 100,
        output: 20,
        cacheRead: 150,
        cacheWrite: 50,
        cost: { total: 0.01 },
      }),
    );

    // Tool-only message (direct accumulation)
    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 200,
        output: 40,
        cacheRead: 350,
        cacheWrite: 100,
        cost: { total: 0.02 },
      }),
    );

    expect(session.tokens).toEqual({
      input: 300,
      output: 60,
      cacheRead: 500,
      cacheWrite: 150,
    });
    expect(session.cost).toBe(0.03);
  });

  it("handles interleaved text and tool-only messages", () => {
    const session = makeSession();
    const messages: PiMessage[] = [
      makeAssistantMessage("a", { input: 10, output: 5, cacheRead: 20, cacheWrite: 10 }),
      makeToolOnlyMessage({ input: 15, output: 3, cacheRead: 30, cacheWrite: 0 }),
      makeAssistantMessage("b", { input: 20, output: 7, cacheRead: 0, cacheWrite: 25 }),
      makeToolOnlyMessage({ input: 5, output: 2, cacheRead: 50, cacheWrite: 5 }),
    ];

    for (const msg of messages) {
      applyMessageEndToSession(session, msg);
    }

    expect(session.tokens).toEqual({
      input: 50,
      output: 17,
      cacheRead: 100,
      cacheWrite: 40,
    });
  });
});

// ─── Partial cache fields ───

describe("cache tokens: partial fields", () => {
  it("handles cacheRead present but cacheWrite missing", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("answer", {
        input: 50,
        output: 20,
        cacheRead: 300,
        // cacheWrite intentionally omitted
      }),
    );

    expect(session.tokens.cacheRead).toBe(300);
    expect(session.tokens.cacheWrite).toBe(0);
  });

  it("handles cacheWrite present but cacheRead missing", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("first turn", {
        input: 50,
        output: 20,
        // cacheRead intentionally omitted
        cacheWrite: 150,
      }),
    );

    expect(session.tokens.cacheRead).toBe(0);
    expect(session.tokens.cacheWrite).toBe(150);
  });

  it("handles both cache fields missing", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("no cache", {
        input: 100,
        output: 50,
      }),
    );

    expect(session.tokens.cacheRead).toBe(0);
    expect(session.tokens.cacheWrite).toBe(0);
    expect(session.tokens.input).toBe(100);
    expect(session.tokens.output).toBe(50);
  });

  it("handles partial cache fields via text-absent path", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 80,
        output: 10,
        cacheRead: 400,
        // cacheWrite omitted
      }),
    );

    expect(session.tokens.cacheRead).toBe(400);
    expect(session.tokens.cacheWrite).toBe(0);
  });
});

// ─── contextTokens (per-message, not accumulated) ───

describe("cache tokens: contextTokens", () => {
  it("sets contextTokens to sum of all token fields from last message", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("answer", {
        input: 100,
        output: 50,
        cacheRead: 200,
        cacheWrite: 80,
      }),
    );

    expect(session.contextTokens).toBe(430); // 100+50+200+80
  });

  it("contextTokens reflects only the LAST message, not accumulated", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("first", {
        input: 100,
        output: 50,
        cacheRead: 200,
        cacheWrite: 80,
      }),
    );
    expect(session.contextTokens).toBe(430);

    applyMessageEndToSession(
      session,
      makeAssistantMessage("second", {
        input: 300,
        output: 100,
        cacheRead: 500,
        cacheWrite: 0,
      }),
    );

    // contextTokens should be from the second message only
    expect(session.contextTokens).toBe(900); // 300+100+500+0
    // But session.tokens should be accumulated
    expect(session.tokens.input).toBe(400);
    expect(session.tokens.cacheRead).toBe(700);
  });

  it("contextTokens is set from tool-only messages too", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 50,
        output: 10,
        cacheRead: 100,
        cacheWrite: 20,
      }),
    );

    expect(session.contextTokens).toBe(180);
  });

  it("contextTokens is not updated when usage is absent", () => {
    const session = makeSession();

    // First message sets contextTokens
    applyMessageEndToSession(
      session,
      makeAssistantMessage("first", {
        input: 100,
        output: 50,
        cacheRead: 200,
        cacheWrite: 80,
      }),
    );
    expect(session.contextTokens).toBe(430);

    // Second message has no usage — contextTokens should remain from first
    applyMessageEndToSession(session, makeAssistantMessage("second"));

    expect(session.contextTokens).toBe(430);
  });
});

// ─── Cost accumulation ───

describe("cache tokens: cost", () => {
  it("accumulates cost alongside cache tokens (text path)", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("a", {
        input: 10,
        output: 5,
        cacheRead: 100,
        cacheWrite: 50,
        cost: { total: 0.01 },
      }),
    );

    applyMessageEndToSession(
      session,
      makeAssistantMessage("b", {
        input: 20,
        output: 10,
        cacheRead: 200,
        cacheWrite: 0,
        cost: { total: 0.025 },
      }),
    );

    expect(session.cost).toBeCloseTo(0.035);
    expect(session.tokens.cacheRead).toBe(300);
  });

  it("accumulates cost from tool-only messages", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 10,
        output: 5,
        cacheRead: 50,
        cacheWrite: 20,
        cost: { total: 0.003 },
      }),
    );

    expect(session.cost).toBeCloseTo(0.003);
  });

  it("handles missing cost.total gracefully", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("answer", {
        input: 50,
        output: 20,
        cacheRead: 100,
        cost: {},
      }),
    );

    // cost.total is missing → extractUsage returns 0 for cost
    expect(session.cost).toBe(0);
    // But tokens should still accumulate
    expect(session.tokens.cacheRead).toBe(100);
  });

  it("handles missing cost object entirely", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("answer", {
        input: 50,
        output: 20,
        cacheRead: 100,
      }),
    );

    expect(session.cost).toBe(0);
    expect(session.tokens.cacheRead).toBe(100);
  });
});

// ─── extractUsage edge cases (tested via applyMessageEndToSession) ───

describe("cache tokens: extractUsage edge cases", () => {
  it("rejects string values for cacheRead/cacheWrite (defaults to 0)", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "answer" }],
      usage: {
        input: 50,
        output: 20,
        cacheRead: "100" as unknown as number,
        cacheWrite: "50" as unknown as number,
        cost: { total: 0.01 },
      },
    });

    // Strings fail typeof === "number" check → default to 0
    expect(session.tokens.cacheRead).toBe(0);
    expect(session.tokens.cacheWrite).toBe(0);
    // Regular tokens still accumulate
    expect(session.tokens.input).toBe(50);
    expect(session.tokens.output).toBe(20);
  });

  it("rejects null values for cache fields", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "answer" }],
      usage: {
        input: 50,
        output: 20,
        cacheRead: null as unknown as number,
        cacheWrite: null as unknown as number,
      },
    });

    expect(session.tokens.cacheRead).toBe(0);
    expect(session.tokens.cacheWrite).toBe(0);
  });

  it("handles NaN values for cache fields (typeof NaN is number)", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "answer" }],
      usage: {
        input: 50,
        output: 20,
        cacheRead: NaN,
        cacheWrite: NaN,
      },
    });

    // NaN passes typeof === "number" check! This is a real edge case.
    // extractUsage will return NaN, and 0 + NaN = NaN.
    // This documents the current behavior — NaN propagation is a risk.
    expect(session.tokens.cacheRead).toBeNaN();
    expect(session.tokens.cacheWrite).toBeNaN();
  });

  it("returns null usage when usage object is missing entirely", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "answer" }],
      // No usage field
    });

    // No usage → tokens stay at 0, but message is still counted
    expect(session.tokens).toEqual({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
    expect(session.messageCount).toBe(1);
    expect(session.contextTokens).toBeUndefined();
  });

  it("handles usage as a non-object (string)", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "answer" }],
      usage: "invalid" as unknown as PiMessage["usage"],
    });

    expect(session.tokens).toEqual({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
    expect(session.messageCount).toBe(1);
  });

  it("handles usage with string input/output (they also use typeof check)", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "answer" }],
      usage: {
        input: "100" as unknown as number,
        output: "50" as unknown as number,
        cacheRead: 200,
        cacheWrite: 80,
      },
    });

    // String input/output should default to 0
    expect(session.tokens.input).toBe(0);
    expect(session.tokens.output).toBe(0);
    // But numeric cache fields should work
    expect(session.tokens.cacheRead).toBe(200);
    expect(session.tokens.cacheWrite).toBe(80);
  });

  it("accepts zero as a valid value (not confused with missing)", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("answer", {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cost: { total: 0 },
      }),
    );

    expect(session.tokens).toEqual({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
    expect(session.cost).toBe(0);
    // contextTokens should still be set (usage existed, even with all zeros)
    expect(session.contextTokens).toBe(0);
  });
});

// ─── User messages are ignored ───

describe("cache tokens: user messages ignored", () => {
  it("skips user role messages entirely", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "user",
      content: "hello",
      usage: {
        input: 100,
        output: 50,
        cacheRead: 200,
        cacheWrite: 80,
      },
    });

    expect(session.tokens).toEqual({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
    expect(session.messageCount).toBe(0);
    expect(session.contextTokens).toBeUndefined();
  });
});

// ─── appendSessionMessage directly ───

describe("cache tokens: appendSessionMessage", () => {
  it("accumulates cache tokens from message.tokens", () => {
    const session = makeSession();

    appendSessionMessage(session, {
      role: "assistant",
      content: "hello",
      timestamp: Date.now(),
      tokens: { input: 50, output: 20, cacheRead: 100, cacheWrite: 40 },
    });

    expect(session.tokens).toEqual({
      input: 50,
      output: 20,
      cacheRead: 100,
      cacheWrite: 40,
    });
  });

  it("defaults optional cache fields to 0 via nullish coalescing", () => {
    const session = makeSession();

    appendSessionMessage(session, {
      role: "assistant",
      content: "hello",
      timestamp: Date.now(),
      tokens: { input: 50, output: 20 },
    });

    expect(session.tokens.cacheRead).toBe(0);
    expect(session.tokens.cacheWrite).toBe(0);
  });

  it("skips token accumulation when tokens object is undefined", () => {
    const session = makeSession();

    appendSessionMessage(session, {
      role: "assistant",
      content: "hello",
      timestamp: Date.now(),
      // no tokens field
    });

    expect(session.tokens).toEqual({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
    expect(session.messageCount).toBe(1);
  });

  it("accumulates across multiple calls", () => {
    const session = makeSession();

    appendSessionMessage(session, {
      role: "assistant",
      content: "first",
      timestamp: Date.now(),
      tokens: { input: 10, output: 5, cacheRead: 100, cacheWrite: 50 },
      cost: 0.01,
    });

    appendSessionMessage(session, {
      role: "assistant",
      content: "second",
      timestamp: Date.now(),
      tokens: { input: 20, output: 10, cacheRead: 200, cacheWrite: 0 },
      cost: 0.02,
    });

    expect(session.tokens).toEqual({
      input: 30,
      output: 15,
      cacheRead: 300,
      cacheWrite: 50,
    });
    expect(session.cost).toBeCloseTo(0.03);
    expect(session.messageCount).toBe(2);
  });

  it("user messages through appendSessionMessage accumulate tokens too", () => {
    // appendSessionMessage doesn't filter by role for token accumulation —
    // only applyMessageEndToSession filters user messages.
    const session = makeSession();

    appendSessionMessage(session, {
      role: "user",
      content: "hello",
      timestamp: Date.now(),
      tokens: { input: 10, output: 0, cacheRead: 50, cacheWrite: 20 },
    });

    expect(session.tokens.cacheRead).toBe(50);
    expect(session.tokens.cacheWrite).toBe(20);
    expect(session.messageCount).toBe(1);
  });
});

// ─── messageCount behavior across paths ───

describe("cache tokens: messageCount", () => {
  it("text-present path increments messageCount", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeAssistantMessage("answer", {
        input: 50,
        output: 20,
        cacheRead: 100,
        cacheWrite: 40,
      }),
    );

    expect(session.messageCount).toBe(1);
  });

  it("text-absent path does NOT increment messageCount", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 50,
        output: 20,
        cacheRead: 100,
        cacheWrite: 40,
      }),
    );

    expect(session.messageCount).toBe(0);
    // But tokens still accumulate
    expect(session.tokens.cacheRead).toBe(100);
  });

  it("mixed paths: only text messages increment count", () => {
    const session = makeSession();

    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({ input: 10, output: 5, cacheRead: 50, cacheWrite: 20 }),
    );
    applyMessageEndToSession(
      session,
      makeAssistantMessage("hello", { input: 20, output: 10, cacheRead: 100, cacheWrite: 30 }),
    );
    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({ input: 5, output: 3, cacheRead: 25, cacheWrite: 0 }),
    );

    expect(session.messageCount).toBe(1);
    expect(session.tokens.cacheRead).toBe(175);
    expect(session.tokens.cacheWrite).toBe(50);
  });
});

// ─── First message with no usage ───

describe("cache tokens: no-usage messages", () => {
  it("first message with no usage leaves tokens at zero", () => {
    const session = makeSession();

    applyMessageEndToSession(session, makeAssistantMessage("thinking out loud"));

    expect(session.tokens).toEqual({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
    expect(session.cost).toBe(0);
    expect(session.contextTokens).toBeUndefined();
    expect(session.messageCount).toBe(1);
  });

  it("no-usage followed by usage: second message accumulates normally", () => {
    const session = makeSession();

    applyMessageEndToSession(session, makeAssistantMessage("first, no usage"));

    applyMessageEndToSession(
      session,
      makeAssistantMessage("second, with usage", {
        input: 100,
        output: 50,
        cacheRead: 200,
        cacheWrite: 80,
        cost: { total: 0.01 },
      }),
    );

    expect(session.tokens).toEqual({
      input: 100,
      output: 50,
      cacheRead: 200,
      cacheWrite: 80,
    });
    expect(session.cost).toBeCloseTo(0.01);
    expect(session.contextTokens).toBe(430);
    expect(session.messageCount).toBe(2);
  });
});

// ─── Realistic multi-turn scenario ───

describe("cache tokens: realistic multi-turn", () => {
  it("simulates a 3-turn conversation with growing cache reads", () => {
    const session = makeSession();

    // Turn 1: cold start, large cacheWrite, no cacheRead
    applyMessageEndToSession(
      session,
      makeAssistantMessage("Let me read the file...", {
        input: 1000,
        output: 200,
        cacheRead: 0,
        cacheWrite: 800,
        cost: { total: 0.05 },
      }),
    );

    expect(session.tokens.cacheWrite).toBe(800);
    expect(session.tokens.cacheRead).toBe(0);
    expect(session.contextTokens).toBe(2000);

    // Tool execution (no text, just usage)
    applyMessageEndToSession(
      session,
      makeToolOnlyMessage({
        input: 500,
        output: 50,
        cacheRead: 600,
        cacheWrite: 100,
        cost: { total: 0.02 },
      }),
    );

    expect(session.tokens.cacheRead).toBe(600);
    expect(session.tokens.cacheWrite).toBe(900);
    expect(session.contextTokens).toBe(1250);

    // Turn 2: cache hit, large cacheRead
    applyMessageEndToSession(
      session,
      makeAssistantMessage("Here's what I found.", {
        input: 1500,
        output: 300,
        cacheRead: 900,
        cacheWrite: 200,
        cost: { total: 0.03 },
      }),
    );

    expect(session.tokens).toEqual({
      input: 3000,
      output: 550,
      cacheRead: 1500,
      cacheWrite: 1100,
    });
    expect(session.cost).toBeCloseTo(0.10);
    // contextTokens = last message only
    expect(session.contextTokens).toBe(2900);
    expect(session.messageCount).toBe(2); // only text messages counted
  });
});

// ─── PiMessage content format variations ───

describe("cache tokens: content format variations", () => {
  it("handles string content (not array) as assistant text", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: "plain string content",
      usage: {
        input: 50,
        output: 20,
        cacheRead: 100,
        cacheWrite: 40,
      },
    });

    expect(session.tokens.cacheRead).toBe(100);
    expect(session.tokens.cacheWrite).toBe(40);
    expect(session.messageCount).toBe(1);
  });

  it("handles output_text content blocks", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "output_text", text: "output text block" }],
      usage: {
        input: 50,
        output: 20,
        cacheRead: 100,
        cacheWrite: 40,
      },
    });

    expect(session.tokens.cacheRead).toBe(100);
    expect(session.messageCount).toBe(1);
  });

  it("treats empty text as no-text path", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [{ type: "text", text: "" }],
      usage: {
        input: 50,
        output: 20,
        cacheRead: 100,
        cacheWrite: 40,
      },
    });

    // Empty string is falsy → goes through the direct accumulation path
    expect(session.tokens.cacheRead).toBe(100);
    expect(session.messageCount).toBe(0); // no text → no messageCount increment
  });

  it("handles mixed content blocks (thinking + text)", () => {
    const session = makeSession();

    applyMessageEndToSession(session, {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "let me think..." },
        { type: "text", text: "here's my answer" },
      ],
      usage: {
        input: 200,
        output: 100,
        cacheRead: 500,
        cacheWrite: 150,
      },
    });

    // Text exists → goes through appendSessionMessage path
    expect(session.tokens.cacheRead).toBe(500);
    expect(session.tokens.cacheWrite).toBe(150);
    expect(session.messageCount).toBe(1);
    expect(session.contextTokens).toBe(950);
  });
});

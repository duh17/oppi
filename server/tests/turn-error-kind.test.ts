import { describe, expect, it } from "vitest";

import { classifyTurnError } from "../src/telemetry/turn-error-kind.js";

describe("classifyTurnError", () => {
  // Messages seen in failed turns: the agent runtime's own, and provider SDK errors that lead
  // with the HTTP status.
  it.each([
    ["OMP worker exited early", "runtime_crash"],
    ["OMP worker failed", "runtime_crash"],
    ["Request timed out.", "timeout"],
    [
      '429: {"type":"server_error","message":"Upstream request failed: Endpoint is unavailable."}',
      "rate_limit",
    ],
    [
      '529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
      "overloaded",
    ],
    ['503 {"error":"upstream"}', "overloaded"],
    ['401 {"error":{"type":"authentication_error"}}', "auth"],
    ["403 Forbidden", "auth"],
    ["504 Gateway Timeout", "timeout"],
    ["Connection error.", "network"],
    ["fetch failed", "network"],
    ["terminated", "terminated"],
    ["Request was aborted.", "cancelled"],
    ["Unexpected token < in JSON at position 0, cannot parse", "json_parse"],
    ["Codex error: The usage limit has been reached", "rate_limit"],
    ["Error Code null: The model is currently at capacity due to high demand.", "overloaded"],
    ["Error Code null: Service temporarily unavailable.", "overloaded"],
  ] as const)("%s -> %s", (message, kind) => {
    expect(classifyTurnError(message)).toBe(kind);
  });

  it("calls context overflow request_too_large whatever status carries it", () => {
    expect(classifyTurnError("413 request_too_large")).toBe("request_too_large");
    expect(
      classifyTurnError(
        '400 {"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}',
      ),
    ).toBe("request_too_large");
    expect(classifyTurnError("context_length_exceeded")).toBe("request_too_large");
  });

  it("splits generic provider statuses into 4xx and 5xx only when the text says nothing more", () => {
    expect(classifyTurnError('400 {"error":{"message":"messages: invalid"}}')).toBe("http_4xx");
    expect(classifyTurnError("404 model not found")).toBe("http_4xx");
    expect(classifyTurnError('500 {"error":{"message":"internal"}}')).toBe("http_5xx");
    expect(classifyTurnError("502 Bad Gateway")).toBe("http_5xx");
    expect(classifyTurnError('400 {"error":{"type":"rate_limit_error"}}')).toBe("rate_limit");
    expect(classifyTurnError("status 500: connection reset")).toBe("network");
  });

  it("reads a status only where the provider reports one", () => {
    // 429 is a token count here, not a status.
    expect(classifyTurnError("model produced 429 tokens of invalid output")).toBe("other");
    expect(classifyTurnError("HTTP 502 from upstream")).toBe("http_5xx");
    expect(classifyTurnError('{"status": 429}')).toBe("rate_limit");
  });

  it("treats a timeout abort as a timeout, not a user stop", () => {
    expect(classifyTurnError("The operation was aborted due to timeout")).toBe("timeout");
  });

  it("answers other for a missing or unrecognized error", () => {
    expect(classifyTurnError(undefined)).toBe("other");
    expect(classifyTurnError(42)).toBe("other");
    expect(classifyTurnError("")).toBe("other");
    expect(classifyTurnError("something odd happened")).toBe("other");
  });

  // A provider HTML page or echoed request can be hundreds of kilobytes. A backtracking pattern
  // took seconds on this input and blocked the event loop; a linear one takes milliseconds.
  it("classifies a huge repetitive message without stalling", () => {
    const started = performance.now();
    expect(classifyTurnError("worker ".repeat(40_000))).toBe("other");
    expect(classifyTurnError(`x status${" ".repeat(200_000)}x`)).toBe("other");
    expect(performance.now() - started).toBeLessThan(1_000);
  });
});

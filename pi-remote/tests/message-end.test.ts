import { describe, expect, it } from "vitest";
import { computeAssistantTextTailDelta } from "../src/session-protocol.js";

describe("computeAssistantTextTailDelta", () => {
  it("returns finalized text when no text_delta streamed", () => {
    const delta = computeAssistantTextTailDelta("", "Final assistant answer.");
    expect(delta).toBe("Final assistant answer.");
  });

  it("returns only the missing suffix when finalized text extends streamed text", () => {
    const streamed = "Short answer: ";
    const finalized = "Short answer: not literally.";

    const delta = computeAssistantTextTailDelta(streamed, finalized);
    expect(delta).toBe("not literally.");
  });

  it("returns empty delta when streamed and finalized text match", () => {
    const text = "No changes.";
    const delta = computeAssistantTextTailDelta(text, text);
    expect(delta).toBe("");
  });

  it("falls back to append from common prefix when streams diverge", () => {
    const streamed = "Answer: abc";
    const finalized = "Answer: xyz";

    const delta = computeAssistantTextTailDelta(streamed, finalized);
    expect(delta).toBe("xyz");
  });
});

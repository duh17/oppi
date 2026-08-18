import { describe, expect, it } from "vitest";

import { attributeManagedSessionMessage } from "../src/cli/managed-session-message.js";

describe("managed session message attribution", () => {
  it.each([
    {
      name: "leaves human or unaffiliated CLI text unchanged",
      text: "Focus on the failing test",
      callerSessionId: undefined,
      expected: "Focus on the failing test",
    },
    {
      name: "prefixes a bare prompt with the caller session",
      text: "Own TODO-aa22aa04 to completion",
      callerSessionId: "parent-1",
      expected: "This is a message from session parent-1: Own TODO-aa22aa04 to completion",
    },
    {
      name: "rewrites the typed convention instead of double-prefixing",
      text: "This is a message: You are a hand-off session.",
      callerSessionId: "parent-1",
      expected: "This is a message from session parent-1: You are a hand-off session.",
    },
    {
      name: "rewrites a previously attributed prefix to the current caller",
      text: "This is a message from session other-9: Continue from the review.",
      callerSessionId: "parent-1",
      expected: "This is a message from session parent-1: Continue from the review.",
    },
    {
      name: "is idempotent when the caller already attributed the text",
      text: "This is a message from session parent-1: Keep going.",
      callerSessionId: "parent-1",
      expected: "This is a message from session parent-1: Keep going.",
    },
    {
      name: "does not treat a later convention mention as a prefix",
      text: "Prefix child prompts with This is a message: if you type them by hand.",
      callerSessionId: "parent-1",
      expected:
        "This is a message from session parent-1: Prefix child prompts with This is a message: if you type them by hand.",
    },
  ])("$name", ({ text, callerSessionId, expected }) => {
    expect(attributeManagedSessionMessage(text, callerSessionId)).toBe(expected);
  });
});

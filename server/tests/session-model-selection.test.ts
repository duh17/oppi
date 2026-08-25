import { describe, expect, it } from "vitest";

import { resolveInitialChatModel } from "../src/session-model-selection.js";

describe("resolveInitialChatModel", () => {
  it("uses explicit request model before inherited state", () => {
    const selection = resolveInitialChatModel({
      requestModel: " anthropic/claude-sonnet-4-6 ",
      sourceSessionModel: "openai-codex/gpt-5.4",
    });

    expect(selection).toEqual({ model: "anthropic/claude-sonnet-4-6", source: "request" });
  });

  it("inherits a source session model when no request model is present", () => {
    const selection = resolveInitialChatModel({
      sourceSessionModel: "openai-codex/gpt-5.4",
    });

    expect(selection).toEqual({ model: "openai-codex/gpt-5.4", source: "sourceSession" });
  });

  it("defers to Pi settings when no explicit or inherited model applies", () => {
    const selection = resolveInitialChatModel({ requestModel: " " });

    expect(selection).toEqual({ source: "piSettings" });
  });
});

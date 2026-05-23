import { describe, expect, it } from "vitest";

import { resolveInitialChatModel } from "./session-model-selection.js";

describe("resolveInitialChatModel", () => {
  it("uses explicit request model before all other sources", () => {
    const selection = resolveInitialChatModel({
      requestModel: " anthropic/claude-sonnet-4-6 ",
      subagentModel: "openai-codex/gpt-5.5",
      sourceSessionModel: "openai-codex/gpt-5.4",
      workspace: { defaultModel: "ds4/deepseek-v4-flash" },
    });

    expect(selection).toEqual({ model: "anthropic/claude-sonnet-4-6", source: "request" });
  });

  it("uses subagent model before inherited source and workspace defaults", () => {
    const selection = resolveInitialChatModel({
      subagentModel: "openai-codex/gpt-5.5",
      sourceSessionModel: "openai-codex/gpt-5.4",
      workspace: { defaultModel: "ds4/deepseek-v4-flash" },
    });

    expect(selection).toEqual({ model: "openai-codex/gpt-5.5", source: "subagent" });
  });

  it("inherits a source session model before workspace defaults", () => {
    const selection = resolveInitialChatModel({
      sourceSessionModel: "openai-codex/gpt-5.4",
      workspace: { defaultModel: "ds4/deepseek-v4-flash" },
    });

    expect(selection).toEqual({ model: "openai-codex/gpt-5.4", source: "sourceSession" });
  });

  it("uses workspace default before Pi settings", () => {
    const selection = resolveInitialChatModel({
      workspace: { defaultModel: " ds4/deepseek-v4-flash " },
    });

    expect(selection).toEqual({ model: "ds4/deepseek-v4-flash", source: "workspaceDefault" });
  });

  it("can skip workspace defaults so Pi can restore imported trace state", () => {
    const selection = resolveInitialChatModel({
      workspace: { defaultModel: "ds4/deepseek-v4-flash" },
      includeWorkspaceDefault: false,
    });

    expect(selection).toEqual({ source: "piSettings" });
  });

  it("falls through to Pi settings when no Oppi model applies", () => {
    const selection = resolveInitialChatModel({
      requestModel: " ",
      workspace: { defaultModel: "\t" },
    });

    expect(selection).toEqual({ source: "piSettings" });
  });
});

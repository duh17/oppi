import { describe, expect, it } from "vitest";

import { composeModelId } from "./session-state.js";

describe("composeModelId", () => {
  it("prefixes simple model ids with the provider", () => {
    expect(composeModelId("anthropic", "claude-sonnet-4-0")).toBe("anthropic/claude-sonnet-4-0");
  });

  it("preserves nested model ids while adding the provider prefix", () => {
    expect(composeModelId("openrouter", "z.ai/glm-5")).toBe("openrouter/z.ai/glm-5");
  });

  it("does not double-prefix an already qualified model id", () => {
    expect(composeModelId("anthropic", "anthropic/claude-sonnet-4-0")).toBe(
      "anthropic/claude-sonnet-4-0",
    );
  });

  it("handles local provider model ids", () => {
    expect(composeModelId("lmstudio", "glm-4.7-flash-mlx")).toBe("lmstudio/glm-4.7-flash-mlx");
  });
});

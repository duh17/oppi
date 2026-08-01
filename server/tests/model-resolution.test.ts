import { describe, expect, it } from "vitest";

import { stripModelThinkingLevel } from "../src/model-resolution.js";

describe("model thinking-level suffixes", () => {
  it("round-trips max without treating it as part of the model id", () => {
    expect(stripModelThinkingLevel("ds4/deepseek-v4-flash:max")).toEqual({
      model: "ds4/deepseek-v4-flash",
      thinkingLevel: "max",
    });
  });

  it("keeps unsupported suffixes in the model query", () => {
    expect(stripModelThinkingLevel("ds4/deepseek-v4-flash:turbo")).toEqual({
      model: "ds4/deepseek-v4-flash:turbo",
    });
  });
});

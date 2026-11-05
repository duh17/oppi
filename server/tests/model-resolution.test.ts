import { describe, expect, it } from "vitest";

import { modelCandidatesFromRegistry, stripModelThinkingLevel } from "../src/model-resolution.js";

describe("local model candidates", () => {
  // Models without credentials are not "available", but a model served from this machine
  // needs none, so it is still offered as a local candidate.
  function registryWith(baseUrl: string) {
    const model = { provider: "lab", id: "tiny", name: "Tiny", baseUrl };
    return { getAvailable: () => [], getAll: () => [model] } as unknown as Parameters<
      typeof modelCandidatesFromRegistry
    >[0];
  }

  it.each(["http://localhost:8080/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"])(
    "offers an unavailable model served from loopback as local: %s",
    (baseUrl) => {
      const candidates = modelCandidatesFromRegistry(registryWith(baseUrl));
      expect(candidates.map((c) => [c.canonicalId, c.authKind])).toEqual([["lab/tiny", "local"]]);
    },
  );

  it("does not offer an unavailable model served from another host", () => {
    expect(modelCandidatesFromRegistry(registryWith("http://models.example.com/v1"))).toEqual([]);
  });
});

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

import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  applySessionDefaultFlags,
  parseCsvList,
  resolveNoToolsFlag,
  resolveThinkingFromFlags,
} from "../src/cli/launch-flags.js";
import { resolveModelFlagForCli } from "../src/cli/model-resolution.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const request = vi.mocked(localApiRequest);
const storage = {} as LocalApiConnection;

describe("Pi launch-flag helpers", () => {
  it("splits CSV lists like Pi: comma, trim, drop empties", () => {
    expect(parseCsvList("read, grep, ,bash,")).toEqual(["read", "grep", "bash"]);
    expect(parseCsvList("  ")).toEqual([]);
  });

  it("maps --no-tools and --no-builtin-tools to sessionDefaults.noTools", () => {
    expect(resolveNoToolsFlag({ "no-tools": "true" })).toBe("all");
    expect(resolveNoToolsFlag({ "no-builtin-tools": "true" })).toBe("builtin");
  });

  it("rejects combining --no-tools with --no-builtin-tools", () => {
    expect(() =>
      resolveNoToolsFlag({ "no-tools": "true", "no-builtin-tools": "true" }),
    ).toThrow("--no-tools and --no-builtin-tools cannot be used together");
  });

  it("lets explicit --thinking win over a model suffix", () => {
    expect(resolveThinkingFromFlags({ thinking: "low" }, "high")).toBe("low");
    expect(resolveThinkingFromFlags({}, "high")).toBe("high");
    expect(resolveThinkingFromFlags({}, undefined)).toBeUndefined();
  });

  it("overlays first-class flags onto definition sessionDefaults", () => {
    expect(
      applySessionDefaultFlags(
        {
          name: "Reviewer",
          sessionDefaults: { model: "old-model", tools: ["bash"], thinkingLevel: "low" },
        },
        {
          tools: "read, grep",
          "exclude-tools": "bash",
          "no-builtin-tools": "true",
          thinking: "high",
        },
        { canonicalId: "new-model", thinkingLevel: "max" },
      ),
    ).toEqual({
      name: "Reviewer",
      sessionDefaults: {
        model: "new-model",
        tools: ["read", "grep"],
        excludeTools: ["bash"],
        noTools: "builtin",
        thinkingLevel: "high",
      },
    });
  });
});

describe("resolveModelFlagForCli thinking suffix", () => {
  beforeEach(() => {
    request.mockReset();
  });

  it("keeps the :thinking suffix instead of dropping it", async () => {
    request.mockResolvedValueOnce({
      models: [{ id: "openai/gpt-5.3-codex", name: "GPT-5.3 Codex", provider: "openai" }],
    });

    await expect(resolveModelFlagForCli(storage, "gpt-5.3-codex:high")).resolves.toEqual({
      canonicalId: "openai/gpt-5.3-codex",
      thinkingLevel: "high",
    });
  });
});

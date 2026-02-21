import { describe, expect, it } from "vitest";
import {
  defaultPolicy,
  policyRulesFromDeclarativeConfig,
  policyRuntimeConfig,
} from "../src/policy.js";

describe("policy store unification", () => {
  it("derives global rule seeds from declarative policy rules", () => {
    const policy = {
      schemaVersion: 1 as const,
      mode: "custom",
      fallback: "ask" as const,
      guardrails: [
        {
          id: "block-sudo",
          decision: "block" as const,
          match: { tool: "bash", executable: "sudo" },
        },
      ],
      permissions: [
        {
          id: "ask-push",
          decision: "ask" as const,
          match: { tool: "bash", executable: "git", commandMatches: "git push*" },
        },
      ],
    };

    const seeds = policyRulesFromDeclarativeConfig(policy);

    expect(seeds).toHaveLength(2);
    expect(seeds[0]).toMatchObject({
      tool: "bash",
      decision: "deny",
      executable: "sudo",
      scope: "global",
      source: "preset",
    });
    expect(seeds[1]).toMatchObject({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      scope: "global",
      source: "preset",
    });
  });

  it("keeps runtime engine focused on fallback + heuristics", () => {
    const runtime = policyRuntimeConfig(defaultPolicy());

    expect(runtime.guardrails).toEqual([]);
    expect(runtime.permissions).toEqual([]);
    expect(runtime.fallback).toBe("allow");
    expect(runtime.heuristics).toBeTruthy();
  });
});

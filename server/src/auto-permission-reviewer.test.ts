import { describe, expect, it } from "vitest";

import { parseAutoPermissionDecision } from "./auto-permission-reviewer.js";
import { PolicyEngine } from "./policy.js";

describe("auto permission review", () => {
  it("parses allow/ask decisions and rejects deny", () => {
    expect(
      parseAutoPermissionDecision(
        '{"outcome":"allow","risk_level":"low","user_authorization":"unknown","confidence":0.9,"rationale":"read-only"}',
      ),
    ).toMatchObject({ outcome: "allow", riskLevel: "low", confidence: 0.9 });

    expect(
      parseAutoPermissionDecision(
        '{"outcome":"ask","risk_level":"high","user_authorization":"unknown","confidence":1,"rationale":"network mutation"}',
      ),
    ).toMatchObject({ outcome: "ask", riskLevel: "high", confidence: 1 });

    expect(
      parseAutoPermissionDecision(
        '{"outcome":"deny","risk_level":"critical","user_authorization":"unknown","confidence":1,"rationale":"nope"}',
      ),
    ).toBeNull();
  });

  it("supports auto as a policy fallback", () => {
    const engine = new PolicyEngine("default");
    engine.setDefaultAction("auto");

    const result = engine.evaluateWithRules(
      { tool: "bash", input: { command: "git status" }, toolCallId: "call-1" },
      [],
      "session-1",
      "workspace-1",
    );

    expect(result.action).toBe("auto");
  });
});

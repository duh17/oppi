import { describe, expect, it } from "vitest";
import { PolicyEngine, type GateRequest } from "../src/policy.js";
import type { Rule } from "../src/rules.js";

interface GoldenCase {
  name: string;
  request: GateRequest;
  rules: Rule[];
  expected: {
    action: "allow" | "ask" | "deny";
    layer: "global_rule" | "default";
    ruleId?: string;
    reasonContains: string;
  };
}

const engine = new PolicyEngine({
  schemaVersion: 1,
  mode: "golden",
  fallback: "ask",
  guardrails: [],
  permissions: [],
  heuristics: {
    pipeToShell: false,
    dataEgress: false,
    secretEnvInUrl: false,
    secretFileAccess: false,
  },
});

const now = Date.now();

const goldenCases: GoldenCase[] = [
  {
    name: "deny-first over allow",
    request: {
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc-deny-first",
    },
    rules: [
      {
        id: "r-allow-git",
        tool: "bash",
        decision: "allow",
        pattern: "git *",
        scope: "global",
        source: "manual",
        label: "Allow git",
        createdAt: now,
      },
      {
        id: "r-deny-push",
        tool: "bash",
        decision: "deny",
        pattern: "git push*",
        scope: "global",
        source: "manual",
        label: "Deny git push",
        createdAt: now,
      },
    ],
    expected: {
      action: "deny",
      layer: "global_rule",
      ruleId: "r-deny-push",
      reasonContains: "Deny git push",
    },
  },
  {
    name: "most-specific rule wins",
    request: {
      tool: "read",
      input: { path: "/workspace/reports/q1.md" },
      toolCallId: "tc-specificity",
    },
    rules: [
      {
        id: "r-ask-workspace",
        tool: "read",
        decision: "ask",
        pattern: "/workspace/**",
        scope: "global",
        source: "manual",
        label: "Ask workspace",
        createdAt: now,
      },
      {
        id: "r-allow-reports",
        tool: "read",
        decision: "allow",
        pattern: "/workspace/reports/**",
        scope: "global",
        source: "manual",
        label: "Allow reports",
        createdAt: now,
      },
    ],
    expected: {
      action: "allow",
      layer: "global_rule",
      ruleId: "r-allow-reports",
      reasonContains: "Allow reports",
    },
  },
  {
    name: "ask beats allow when specificity ties",
    request: {
      tool: "bash",
      input: { command: "npm run lint" },
      toolCallId: "tc-ask-over-allow",
    },
    rules: [
      {
        id: "r-allow-lint",
        tool: "bash",
        decision: "allow",
        executable: "npm",
        pattern: "npm run lint*",
        scope: "global",
        source: "manual",
        label: "Allow lint",
        createdAt: now,
      },
      {
        id: "r-ask-lint",
        tool: "bash",
        decision: "ask",
        executable: "npm",
        pattern: "npm run lint*",
        scope: "global",
        source: "manual",
        label: "Ask lint",
        createdAt: now,
      },
    ],
    expected: {
      action: "ask",
      layer: "global_rule",
      ruleId: "r-ask-lint",
      reasonContains: "Ask lint",
    },
  },
  {
    name: "stable first match when fully tied",
    request: {
      tool: "bash",
      input: { command: "python main.py" },
      toolCallId: "tc-stable-fallback",
    },
    rules: [
      {
        id: "r-allow-python-a",
        tool: "bash",
        decision: "allow",
        executable: "python",
        scope: "global",
        source: "manual",
        label: "Allow python A",
        createdAt: now,
      },
      {
        id: "r-allow-python-b",
        tool: "bash",
        decision: "allow",
        executable: "python",
        scope: "global",
        source: "manual",
        label: "Allow python B",
        createdAt: now,
      },
    ],
    expected: {
      action: "allow",
      layer: "global_rule",
      ruleId: "r-allow-python-a",
      reasonContains: "Allow python A",
    },
  },
];

describe("policy precedence golden", () => {
  it("enforces deny/specificity/tie precedence deterministically", () => {
    const actual = goldenCases.map((scenario) => {
      const decision = engine.evaluateWithRules(scenario.request, scenario.rules, "s1", "w1");
      return {
        name: scenario.name,
        action: decision.action,
        layer: decision.layer,
        ruleId: decision.ruleId,
        reason: decision.reason,
      };
    });

    for (let index = 0; index < goldenCases.length; index += 1) {
      const scenario = goldenCases[index];
      const result = actual[index];

      expect(result.name).toBe(scenario.name);
      expect(result.action).toBe(scenario.expected.action);
      expect(result.layer).toBe(scenario.expected.layer);
      expect(result.ruleId).toBe(scenario.expected.ruleId);
      expect(result.reason).toContain(scenario.expected.reasonContains);
    }
  });
});

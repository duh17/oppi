import { describe, it, expect } from "vitest";
import { PolicyEngine } from "../src/policy.js";
import type { GateRequest } from "../src/policy-types.js";
import type { Rule } from "../src/rules.js";
import { defaultPresetRules } from "../src/policy-presets.js";

// ─── Helpers ─────────────────────────────────────────────────────────

function bashRequest(command: string): GateRequest {
  return { tool: "bash", input: { command }, toolCallId: "test-tc-1" };
}

function makeRule(overrides: Partial<Rule> & { tool: string; decision: Rule["decision"] }): Rule {
  return {
    id: `rule-${Math.random().toString(36).slice(2, 8)}`,
    scope: "global",
    createdAt: Date.now(),
    ...overrides,
  };
}

const SESSION_ID = "test-session-1";
const WORKSPACE_ID = "test-workspace-1";

// ─── Preset rules (what ships by default) ────────────────────────────

describe("default preset rules contain git push", () => {
  const presetInputs = defaultPresetRules();

  it("has a git push rule", () => {
    const gitPushRule = presetInputs.find(
      (r) => r.tool === "bash" && r.executable === "git" && r.pattern === "git push*",
    );
    expect(gitPushRule).toBeDefined();
    expect(gitPushRule?.decision).toBe("ask");
  });

  it("force push pattern only exists in compiled built-in policies, not preset seeds", () => {
    // git push*--force* is in BUILTIN_HOST_POLICY and BUILTIN_CONTAINER_POLICY
    // but NOT in defaultPolicy() declarative config (which feeds defaultPresetRules).
    // The broader git push* rule catches all pushes including force pushes.
    const forcePushRule = presetInputs.find(
      (r) => r.tool === "bash" && r.pattern === "git push*--force*",
    );
    expect(forcePushRule).toBeUndefined();
  });
});

// ─── PolicyEngine.evaluate (compiled rules path) ────────────────────

describe("PolicyEngine.evaluate — git push detection", () => {
  const engine = new PolicyEngine("default");

  it("catches simple git push", () => {
    const result = engine.evaluate(bashRequest("git push origin main"));
    expect(result.action).toBe("ask");
    expect(result.ruleLabel).toContain("Git push");
  });

  it("catches git push --force", () => {
    const result = engine.evaluate(bashRequest("git push --force origin main"));
    expect(result.action).toBe("ask");
  });

  it("catches git push --force-with-lease", () => {
    const result = engine.evaluate(bashRequest("git push --force-with-lease origin main"));
    expect(result.action).toBe("ask");
  });

  it("catches compound: cd && add && commit --amend && push --force-with-lease", () => {
    const cmd =
      "cd /Users/testuser/workspace/oppi && git add -A && git commit --amend --no-edit && git push --force-with-lease origin main 2>&1 | tail -5";
    const result = engine.evaluate(bashRequest(cmd));
    expect(result.action).toBe("ask");
  });

  it("allows normal git commit", () => {
    const result = engine.evaluate(bashRequest("git commit -m 'fix: stuff'"));
    expect(result.action).toBe("allow");
  });

  it("allows git status", () => {
    const result = engine.evaluate(bashRequest("git status"));
    expect(result.action).toBe("allow");
  });
});

// ─── PolicyEngine.evaluateWithRules (runtime rules path) ─────────────

describe("PolicyEngine.evaluateWithRules — git push with user rules", () => {
  const engine = new PolicyEngine("default");

  const gitPushRule = makeRule({
    tool: "bash",
    decision: "ask",
    executable: "git",
    pattern: "git push*",
    label: "Git push",
    scope: "global",
    source: "preset",
  });

  const forcePushRule = makeRule({
    tool: "bash",
    decision: "ask",
    executable: "git",
    pattern: "git push*--force*",
    label: "Force push",
    scope: "global",
    source: "preset",
  });

  const rules: Rule[] = [gitPushRule, forcePushRule];

  it("catches simple git push via user rules", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push origin main"),
      rules,
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("ask");
  });

  it("catches git push --force-with-lease via user rules", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push --force-with-lease origin main"),
      rules,
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("ask");
  });

  it("catches compound command with git push --force-with-lease via user rules", () => {
    const cmd =
      "cd /Users/testuser/workspace/oppi && git add -A && git commit --amend --no-edit && git push --force-with-lease origin main 2>&1 | tail -5";
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SESSION_ID, WORKSPACE_ID);
    expect(result.action).toBe("ask");
  });

  it("allows git add via user rules (no matching rule → default allow)", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git add -A"),
      rules,
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("allow");
  });

  it("allows git commit via user rules", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git commit --amend --no-edit"),
      rules,
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("allow");
  });
});

// ─── evaluate() vs evaluateWithRules() behavior difference ──────────

describe("evaluate() path handles npm && git push correctly", () => {
  const engine = new PolicyEngine("default");

  it("catches git push after npm install via compiled rules", () => {
    // evaluate() uses matchesBashRuleSegment per-segment (correct)
    // unlike evaluateWithRules() which checks primary exe once
    const result = engine.evaluate(bashRequest("npm install && git push origin main"));
    expect(result.action).toBe("ask");
  });
});

// ─── THE BUG: git commit allow rule hides git push ask rule ─────────

describe("BUG: compound command with git commit allow + git push ask", () => {
  const engine = new PolicyEngine("default");

  // Reproduce the user's actual rules.json
  const rules: Rule[] = [
    makeRule({
      tool: "bash",
      decision: "allow",
      executable: "git",
      label: "Allow git",
      scope: "global",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      label: "Git push",
      scope: "global",
    }),
    makeRule({
      tool: "bash",
      decision: "allow",
      executable: "git",
      pattern: "git commit*",
      label: "Allow git commit",
      scope: "global",
    }),
    makeRule({
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git reset*",
      label: "Git reset",
      scope: "global",
    }),
  ];

  it("simple git push is caught (no competing rules)", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git push --force-with-lease origin main"),
      rules,
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("ask");
  });

  it("compound command with commit + push — push ask wins (most restrictive)", () => {
    const cmd =
      "cd /Users/testuser/workspace/oppi && git add -A && git commit --amend --no-edit && git push --force-with-lease origin main 2>&1 | tail -5";
    const result = engine.evaluateWithRules(bashRequest(cmd), rules, SESSION_ID, WORKSPACE_ID);
    expect(result.action).toBe("ask");
    expect(result.ruleLabel).toBe("Git push");
  });

  it("git commit alone is correctly allowed", () => {
    const result = engine.evaluateWithRules(
      bashRequest("git commit --amend --no-edit"),
      rules,
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("allow");
  });
});

// ─── Edge case: executable mismatch in compound commands ─────────────

describe("executable matching in compound commands", () => {
  const engine = new PolicyEngine("default");

  const gitPushRule = makeRule({
    tool: "bash",
    decision: "ask",
    executable: "git",
    pattern: "git push*",
    label: "Git push",
    scope: "global",
  });

  it("catches git push even when cd is the first command", () => {
    const result = engine.evaluateWithRules(
      bashRequest("cd /tmp && git push origin main"),
      [gitPushRule],
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("ask");
  });

  it("catches git push when preceded by non-git commands", () => {
    // Primary executable is "echo" (first non-helper), not "git"
    // This tests whether the executable check uses primary vs per-segment
    const result = engine.evaluateWithRules(
      bashRequest("echo starting && git push origin main"),
      [gitPushRule],
      SESSION_ID,
      WORKSPACE_ID,
    );
    // If primary exe is "echo" and rule.executable is "git", this might FAIL
    // That would be the bug
    expect(result.action).toBe("ask");
  });

  it("catches git push when preceded by npm install (per-segment exe check)", () => {
    const result = engine.evaluateWithRules(
      bashRequest("npm install && git push origin main"),
      [gitPushRule],
      SESSION_ID,
      WORKSPACE_ID,
    );
    expect(result.action).toBe("ask");
  });
});

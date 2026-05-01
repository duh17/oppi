import { describe, it, expect } from "vitest";
import { PolicyEngine } from "../src/policy.js";
import type { GateRequest } from "../src/policy-types.js";
import { defaultPresetRules } from "../src/policy-presets.js";

function toolCall(tool: string, input: Record<string, unknown> = {}): GateRequest {
  return {
    tool,
    input,
    toolCallId: `tc-admin-${Math.random().toString(36).slice(2)}`,
  };
}

describe("oppi-admin policy presets", () => {
  const engine = new PolicyEngine("default");
  const rules = defaultPresetRules();

  it("asks before workspace create via oppi-admin tool", () => {
    const decision = engine.evaluateWithRules(
      toolCall("oppi_admin_create_workspace", { name: "oppi-admin", skills: ["oppi-admin"] }),
      rules,
      "s1",
      "oppi-admin",
    );
    expect(decision.action).toBe("ask");
  });

  it("asks before workspace delete via oppi-admin tool", () => {
    const decision = engine.evaluateWithRules(
      toolCall("oppi_admin_delete_workspace", { workspaceId: "ws-123" }),
      rules,
      "s1",
      "oppi-admin",
    );
    expect(decision.action).toBe("ask");
  });

  it("asks before building a theme", () => {
    const decision = engine.evaluateWithRules(
      toolCall("build_theme", { name: "Test", colorScheme: "dark", colors: {} }),
      rules,
      "s1",
      "oppi-admin",
    );
    expect(decision.action).toBe("ask");
  });

  it("allows workspace list via oppi-admin tool", () => {
    const decision = engine.evaluateWithRules(
      toolCall("oppi_admin_list_workspaces"),
      rules,
      "s1",
      "oppi-admin",
    );
    expect(decision.action).toBe("allow");
  });
});

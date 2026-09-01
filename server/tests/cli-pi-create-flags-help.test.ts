import { describe, expect, it } from "vitest";

import { renderHelpTopic, resolveHelpTopic } from "../src/cli/help.js";

const EXAMPLE_SESSION_ID = "11111111-1111-4111-8111-111111111111";

function helpText(path: string[]): string {
  const topic = resolveHelpTopic(path);
  expect(topic).toBeDefined();
  return topic ? renderHelpTopic(topic) : "";
}

describe("Pi create-flag help", () => {
  it("documents session create tool flags, model suffix, and UUID examples", () => {
    const text = helpText(["session", "create"]);
    expect(text).toContain("--tools");
    expect(text).toContain("-t");
    expect(text).toContain("--exclude-tools");
    expect(text).toContain("-xt");
    expect(text).toContain("--no-tools");
    expect(text).toContain("-nt");
    expect(text).toContain("--no-builtin-tools");
    expect(text).toContain("-nbt");
    expect(text).toContain("-n");
    expect(text).toContain(":thinking");
    expect(text).toContain("--thinking");
    expect(text).toContain("wins");
    expect(text).toContain("--auto-stop");
    expect(text).toContain("when the turn is done");
    expect(text).toContain("no idle wait");
    expect(text).toContain("ask/select/confirm/input");
    expect(text).toContain(EXAMPLE_SESSION_ID);
    expect(text).not.toContain("sess_123");
  });

  it("documents the same first-class flags on agent create and update", () => {
    for (const path of [
      ["agent", "create"],
      ["agent", "update"],
    ]) {
      const text = helpText(path);
      expect(text, path.join(" ")).toContain("--model");
      expect(text, path.join(" ")).toContain("--thinking");
      expect(text, path.join(" ")).toContain("--tools");
      expect(text, path.join(" ")).toContain("-t");
      expect(text, path.join(" ")).toContain("--exclude-tools");
      expect(text, path.join(" ")).toContain("-xt");
      expect(text, path.join(" ")).toContain("--no-tools");
      expect(text, path.join(" ")).toContain("-nt");
      expect(text, path.join(" ")).toContain("--no-builtin-tools");
      expect(text, path.join(" ")).toContain("-nbt");
      expect(text, path.join(" ")).toContain("sessionDefaults");
      expect(text, path.join(" ")).toContain(":thinking");
    }
  });

  it("replaces sess_123 session-id examples with a full UUID", () => {
    const sessionHelp = helpText(["session"]);
    expect(sessionHelp).toContain(EXAMPLE_SESSION_ID);
    expect(sessionHelp).not.toContain("sess_123");
  });
});

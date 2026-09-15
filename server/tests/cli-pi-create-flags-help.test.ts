import { describe, expect, it } from "vitest";

import { helpTopicToJson, renderHelpTopic, resolveHelpTopic } from "../src/cli/help.js";

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

  it("leads agent parent/create/update help with flag-only examples", () => {
    for (const path of [["agent"], ["agent", "create"], ["agent", "update"]]) {
      const topic = resolveHelpTopic(path);
      expect(topic, path.join(" ")).toBeDefined();
      const first = topic?.examples?.[0]?.command ?? "";
      expect(first, path.join(" ")).toContain("oppi agent");
      expect(first, path.join(" ")).not.toContain("--definition");
      expect(first, path.join(" ")).not.toContain("--definition-json");
      expect(first, path.join(" ")).not.toMatch(/--skills\s+review\b/);
      expect(first, path.join(" ")).not.toMatch(/--extensions\s+git\b/);
      if (path[1] === "update") {
        expect(first).toContain("--expected-version");
      }
      expect(topic?.examples?.some((example) => example.command.includes("--definition"))).toBe(
        true,
      );
    }
  });

  it("documents native-editor flags, JSON bulk use, and agent get --json guidance", () => {
    const editorFlags = [
      "--name",
      "--description",
      "--icon",
      "--instructions",
      "--instructions-file",
      "--instructions-mode",
      "--skills",
      "--extensions",
      "--allowed-workspaces",
      "--required-runtime",
    ];
    const resetFlags = [
      "--clear-description",
      "--clear-icon",
      "--clear-instructions",
      "--clear-skills",
      "--clear-extensions",
      "--clear-allowed-workspaces",
      "--clear-required-runtime",
    ];
    const mappings = [
      "resources.skillPaths",
      "resources.extensionIds",
      "launchConstraints.allowedWorkspaceIds",
    ];

    for (const path of [
      ["agent", "create"],
      ["agent", "update"],
    ]) {
      const topic = resolveHelpTopic(path);
      expect(topic, path.join(" ")).toBeDefined();
      if (!topic) continue;
      const text = renderHelpTopic(topic);
      const json = helpTopicToJson(topic);
      const flagNames = (json.flags ?? []).map((flag) => flag.name).join("\n");
      for (const flag of editorFlags) {
        expect(text, path.join(" ")).toContain(flag);
        expect(flagNames, path.join(" ")).toContain(flag);
        expect(topic.usage, path.join(" ")).toContain(flag);
      }
      for (const mapping of mappings) {
        expect(text, path.join(" ")).toContain(mapping);
      }
      expect(text).toContain("target, workspaceId, worktreeId, cwd, schedule, attachments, images");
      expect(text).toContain("default, one Unicode emoji, or an SF Symbol name");
    }

    const update = helpText(["agent", "update"]);
    const create = helpText(["agent", "create"]);
    for (const flag of resetFlags) {
      expect(update).toContain(flag);
      expect(create).not.toContain(flag);
    }
    expect(update).toContain("omit them to inherit");
    expect(create).toContain("empty CSV is none");
    expect(create).toContain("<skill-path>");
    expect(create).toContain("extension_<id>");
    expect(create).not.toMatch(/--skills\s+review\b/);
    expect(create).not.toMatch(/--extensions\s+git\b/);

    const get = helpText(["agent", "get"]);
    expect(get).toContain("For the full definition, run `oppi agent get <agent> --json`");
    const getJson = helpTopicToJson(resolveHelpTopic(["agent", "get"])!);
    expect(JSON.stringify(getJson)).toContain(
      "For the full definition, run `oppi agent get <agent> --json`",
    );
  });

  it("replaces sess_123 session-id examples with a full UUID", () => {
    const sessionHelp = helpText(["session"]);
    expect(sessionHelp).toContain(EXAMPLE_SESSION_ID);
    expect(sessionHelp).not.toContain("sess_123");
  });
});

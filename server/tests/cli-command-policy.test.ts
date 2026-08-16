import { describe, expect, it } from "vitest";

import { classifyCliAgentCommand, listCliAgentCommandPolicies } from "../src/cli/command-policy.js";

describe("CLI agent access policy", () => {
  it.each([
    ["status", "read"],
    ["quota", "read"],
    ["workspace list", "read"],
    ["workspace update", "mutation"],
    ["workspace delete", "destructive"],
    ["worktree preview", "read"],
    ["worktree create", "mutation"],
    ["worktree remove", "destructive"],
    ["agent get", "read"],
    ["agent update", "mutation"],
    ["agent archive", "destructive"],
    ["session wait", "read"],
    ["session send", "mutation"],
    ["session delete", "destructive"],
    ["schedule runs", "read"],
    ["schedule pause", "mutation"],
    ["schedule archive", "destructive"],
    ["config show", "read"],
    ["config get", "read"],
    ["config validate", "read"],
    ["config set", "mutation"],
  ])("classifies %s as %s", (command, access) => {
    const args = command.split(" ");
    const result = classifyCliAgentCommand(args);

    expect(result).toMatchObject({
      ok: true,
      invocation: { path: args, access },
    });
  });

  it("denies agent config validate against an explicit --config-file", () => {
    expect(
      classifyCliAgentCommand(["config", "validate", "--config-file", "/etc/hosts"]),
    ).toMatchObject({
      ok: false,
      access: "denied",
    });
    expect(classifyCliAgentCommand(["config", "validate"])).toMatchObject({
      ok: true,
      invocation: { access: "read", path: ["config", "validate"] },
    });
  });

  it.each([
    ["pair"],
    ["token", "rotate"],
    ["server", "restart"],
    ["update"],
    ["doctor"],
    ["init"],
    ["serve"],
    ["version"],
    ["wait", "session", "sess-1"],
    ["credentials", "list"],
    ["host", "shell"],
  ])("denies non-agent CLI command %s", (...args) => {
    expect(classifyCliAgentCommand(args)).toMatchObject({ ok: false, access: "denied" });
  });

  it.each([
    ["session", "changes", "sess-1"],
    ["session", "diff", "sess-1"],
    ["session", "dialogs", "sess-1"],
    ["session", "respond", "sess-1"],
    ["skill", "list"],
    ["skill", "get", "skill-1"],
    ["skill", "file", "skill-1", "--path", "SKILL.md"],
    ["skill", "update-file", "skill-1", "--path", "SKILL.md"],
  ])("does not expose removed command %s", (...args) => {
    expect(classifyCliAgentCommand(args)).toMatchObject({
      ok: false,
      access: "denied",
      path: args.slice(0, 2),
    });
    expect(classifyCliAgentCommand([...args.slice(0, 2), "--help"])).toMatchObject({
      ok: false,
      access: "denied",
      path: args.slice(0, 2),
    });
  });

  it("exposes one classification for every allowlisted command policy", () => {
    const policies = listCliAgentCommandPolicies().filter(({ access }) => access !== "denied");

    expect(policies.length).toBeGreaterThan(0);
    for (const policy of policies) {
      const result = classifyCliAgentCommand([...policy.path]);
      expect(result, policy.path.join(" ")).toMatchObject({
        ok: true,
        invocation: { path: policy.path, access: policy.access },
      });
    }
  });

  it("maps one-session watch to bounded wait without exposing streaming watch", () => {
    const result = classifyCliAgentCommand([
      "session",
      "watch",
      "sess-1",
      "--until",
      "attention",
      "--interval",
      "500ms",
      "--timeout",
      "30s",
    ]);

    expect(result).toMatchObject({
      ok: true,
      invocation: {
        args: [
          "session",
          "wait",
          "sess-1",
          "--for",
          "attention",
          "--poll",
          "500ms",
          "--timeout",
          "30s",
        ],
        path: ["session", "wait"],
        access: "read",
      },
    });
  });

  it("keeps agent watch help on the bounded wait surface", () => {
    expect(classifyCliAgentCommand(["session", "watch", "help"])).toMatchObject({
      ok: true,
      invocation: { args: ["session", "wait", "help"], path: ["session", "wait"], isHelp: true },
    });
    expect(classifyCliAgentCommand(["session", "watch", "--help"])).toMatchObject({
      ok: true,
      invocation: { args: ["session", "wait", "--help"], path: ["session", "wait"], isHelp: true },
    });
  });

  it.each([
    ["session", "watch", "sess-1", "sess-2"],
    ["session", "watch", "sess-1", "--all"],
    ["session", "watch", "sess-1", "--until", "any-change"],
    ["session", "watch", "sess-1", "--until", "idle", "--for", "attention"],
  ])("rejects streaming or conflicting watch input %s", (...args) => {
    expect(classifyCliAgentCommand(args)).toMatchObject({ ok: false, access: "denied" });
  });

  it("allows help only for the canonical agent command surface", () => {
    expect(classifyCliAgentCommand(["session", "delete", "--help"])).toMatchObject({
      ok: true,
      invocation: { access: "read", path: ["session", "delete"] },
    });
    expect(classifyCliAgentCommand(["help", "workspace"])).toMatchObject({
      ok: true,
      invocation: { access: "read", path: ["workspace"] },
    });
    expect(classifyCliAgentCommand(["help", "config"])).toMatchObject({
      ok: true,
      invocation: { access: "read", path: ["config"] },
    });
    expect(classifyCliAgentCommand(["help"])).toMatchObject({ ok: false, access: "denied" });
  });
});

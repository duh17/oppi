import { describe, expect, it } from "vitest";

import {
  restrictSandboxOppiCommand,
  sandboxOppiAllowsPath,
  workspaceMatchesScope,
} from "../src/sandbox-oppi-policy.js";

const scope = { workspaceId: "MGXU8ses", workspaceName: "deep-research" };

describe("sandboxOppiAllowsPath", () => {
  it.each([
    [["session", "create"], true],
    [["session", "send"], true],
    [["session", "inspect"], true],
    [["session", "wait"], true],
    [["session", "list"], true],
    [["agent", "get"], true],
    [["quota"], true],
    [["session", "delete"], false],
    [["session", "search"], false],
    [["workspace", "create"], false],
    [["agent", "update"], false],
    [["schedule", "create"], false],
    [["config", "set"], false],
  ])("%j => %s", (path, allowed) => {
    expect(sandboxOppiAllowsPath(path)).toBe(allowed);
  });
});

describe("restrictSandboxOppiCommand", () => {
  it("denies host-escaping verbs", () => {
    expect(
      restrictSandboxOppiCommand({
        path: ["workspace", "create"],
        args: ["workspace", "create", "--name", "x", "--host-mount", "~"],
        scope,
      }),
    ).toMatchObject({ ok: false });
  });

  it("denies session list --all and nested delegation, but allows wait --all", () => {
    expect(
      restrictSandboxOppiCommand({
        path: ["session", "list"],
        args: ["session", "list", "--all"],
        scope,
      }),
    ).toMatchObject({ ok: false });
    expect(
      restrictSandboxOppiCommand({
        path: ["session", "wait"],
        args: ["session", "wait", "child-1", "--all"],
        scope,
      }),
    ).toMatchObject({ ok: true });
    expect(
      restrictSandboxOppiCommand({
        path: ["session", "create"],
        args: [
          "session",
          "create",
          "--workspace",
          "deep-research",
          "--prompt",
          "x",
          "--allow-nested-delegation",
        ],
        scope,
      }),
    ).toMatchObject({ ok: false });
  });

  it("pins session create to the caller workspace id", () => {
    const result = restrictSandboxOppiCommand({
      path: ["session", "create"],
      args: ["session", "create", "--workspace", "deep-research", "--prompt", "go"],
      scope,
    });
    expect(result).toMatchObject({ ok: true });
    if (!result.ok) return;
    expect(result.args).toEqual(["session", "create", "--workspace", "MGXU8ses", "--prompt", "go"]);
  });

  it("injects --workspace when session create omits it", () => {
    const result = restrictSandboxOppiCommand({
      path: ["session", "create"],
      args: ["session", "create", "--prompt", "go"],
      scope,
    });
    expect(result).toEqual({
      ok: true,
      args: ["session", "create", "--prompt", "go", "--workspace", "MGXU8ses"],
    });
  });

  it("rejects session create for another workspace", () => {
    expect(
      restrictSandboxOppiCommand({
        path: ["session", "create"],
        args: ["session", "create", "--workspace", "oppi", "--prompt", "go"],
        scope,
      }),
    ).toMatchObject({ ok: false });
  });

  it("rejects workspace get for another workspace", () => {
    expect(
      restrictSandboxOppiCommand({
        path: ["workspace", "get"],
        args: ["workspace", "get", "oppi"],
        scope,
      }),
    ).toMatchObject({ ok: false });
  });
});

describe("workspaceMatchesScope", () => {
  it("accepts id or unique name", () => {
    expect(workspaceMatchesScope("MGXU8ses", scope)).toBe(true);
    expect(workspaceMatchesScope("deep-research", scope)).toBe(true);
    expect(workspaceMatchesScope("oppi", scope)).toBe(false);
  });
});

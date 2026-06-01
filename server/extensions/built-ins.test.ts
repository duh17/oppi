import { describe, expect, it } from "vitest";

import {
  isBuiltInExtensionName,
  isManagedExtensionName,
  isWorkspaceBuiltInExtensionEnabled,
} from "./built-ins.js";
import type { Workspace } from "../src/types.js";

function makeWorkspace(extensions?: string[]): Workspace {
  return {
    id: "ws-1",
    name: "test",
    skills: [],
    systemPromptMode: "append",
    extensions,
    createdAt: 1,
    updatedAt: 1,
  };
}

describe("isManagedExtensionName", () => {
  it("does not reserve permission-gate away from native Pi loading", () => {
    expect(isManagedExtensionName("permission-gate")).toBe(false);
    expect(isManagedExtensionName("ask")).toBe(false);
    expect(isManagedExtensionName("subagents")).toBe(false);
    expect(isManagedExtensionName("voice")).toBe(false);
  });

  it("does not mark regular host extensions as managed", () => {
    expect(isManagedExtensionName("memory")).toBe(false);
    expect(isManagedExtensionName("todos")).toBe(false);
  });
});

describe("built-in extension names", () => {
  it("detects Oppi built-ins distinctly from managed names", () => {
    expect(isBuiltInExtensionName("ask")).toBe(true);
    expect(isBuiltInExtensionName("subagents")).toBe(true);
    expect(isBuiltInExtensionName("voice")).toBe(true);
    expect(isBuiltInExtensionName("oppi-admin")).toBe(true);
    expect(isBuiltInExtensionName("permission-gate")).toBe(false);
    expect(isBuiltInExtensionName("memory")).toBe(false);
  });
});

describe("isWorkspaceBuiltInExtensionEnabled", () => {
  it("keeps built-ins off when no allowlist is set", () => {
    expect(isWorkspaceBuiltInExtensionEnabled(undefined, "ask")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace(undefined), "subagents")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace(undefined), "voice")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace(undefined), "oppi-admin")).toBe(false);
  });

  it("treats an explicit empty allowlist as disabling built-ins", () => {
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace([]), "ask")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace([]), "subagents")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace([]), "voice")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(makeWorkspace([]), "oppi-admin")).toBe(false);
  });

  it("respects the workspace allowlist", () => {
    const workspace = makeWorkspace(["ask", "memory"]);
    expect(isWorkspaceBuiltInExtensionEnabled(workspace, "ask")).toBe(true);
    expect(isWorkspaceBuiltInExtensionEnabled(workspace, "subagents")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(workspace, "voice")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(workspace, "oppi-admin")).toBe(false);
  });

  it("requires canonical extension names in workspace allowlists", () => {
    const workspace = makeWorkspace(["spawn_agent"]);
    expect(isWorkspaceBuiltInExtensionEnabled(workspace, "subagents")).toBe(false);
    expect(isWorkspaceBuiltInExtensionEnabled(workspace, "voice")).toBe(false);
  });
});

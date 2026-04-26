import { describe, expect, it } from "vitest";

import { isManagedExtensionName, isWorkspaceExtensionEnabled } from "./first-party.js";
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
  it("marks server-managed extensions as managed", () => {
    expect(isManagedExtensionName("permission-gate")).toBe(true);
    expect(isManagedExtensionName("ask")).toBe(true);
    expect(isManagedExtensionName("subagents")).toBe(true);
    expect(isManagedExtensionName("voice")).toBe(true);
  });

  it("does not mark regular host extensions as managed", () => {
    expect(isManagedExtensionName("memory")).toBe(false);
    expect(isManagedExtensionName("todos")).toBe(false);
  });
});

describe("isWorkspaceExtensionEnabled", () => {
  it("defaults first-party extensions to enabled when no allowlist is set", () => {
    expect(isWorkspaceExtensionEnabled(undefined, "ask")).toBe(true);
    expect(isWorkspaceExtensionEnabled(makeWorkspace(undefined), "subagents")).toBe(true);
    expect(isWorkspaceExtensionEnabled(makeWorkspace(undefined), "voice")).toBe(true);
  });

  it("treats an explicit empty allowlist as disabling first-party extensions", () => {
    expect(isWorkspaceExtensionEnabled(makeWorkspace([]), "ask")).toBe(false);
    expect(isWorkspaceExtensionEnabled(makeWorkspace([]), "subagents")).toBe(false);
    expect(isWorkspaceExtensionEnabled(makeWorkspace([]), "voice")).toBe(false);
  });

  it("respects the workspace allowlist", () => {
    const workspace = makeWorkspace(["ask", "memory"]);
    expect(isWorkspaceExtensionEnabled(workspace, "ask")).toBe(true);
    expect(isWorkspaceExtensionEnabled(workspace, "subagents")).toBe(false);
    expect(isWorkspaceExtensionEnabled(workspace, "voice")).toBe(false);
  });

  it("requires canonical extension names in workspace allowlists", () => {
    const workspace = makeWorkspace(["spawn_agent"]);
    expect(isWorkspaceExtensionEnabled(workspace, "subagents")).toBe(false);
    expect(isWorkspaceExtensionEnabled(workspace, "voice")).toBe(false);
  });
});

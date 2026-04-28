import { describe, expect, it } from "vitest";

import {
  isFirstPartyExtensionName,
  isManagedExtensionName,
  isWorkspaceExtensionEnabled,
} from "./first-party.js";
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
  it("marks only truly server-managed extensions as managed", () => {
    expect(isManagedExtensionName("permission-gate")).toBe(true);
    expect(isManagedExtensionName("ask")).toBe(false);
    expect(isManagedExtensionName("subagents")).toBe(false);
    expect(isManagedExtensionName("voice")).toBe(false);
  });

  it("does not mark regular host extensions as managed", () => {
    expect(isManagedExtensionName("memory")).toBe(false);
    expect(isManagedExtensionName("todos")).toBe(false);
  });
});

describe("first-party extension names", () => {
  it("detects first-party names distinctly from managed names", () => {
    expect(isFirstPartyExtensionName("ask")).toBe(true);
    expect(isFirstPartyExtensionName("subagents")).toBe(true);
    expect(isFirstPartyExtensionName("voice")).toBe(true);
    expect(isFirstPartyExtensionName("memory")).toBe(false);
  });
});

describe("isWorkspaceExtensionEnabled", () => {
  it("keeps first-party extensions off when no allowlist is set", () => {
    expect(isWorkspaceExtensionEnabled(undefined, "ask")).toBe(false);
    expect(isWorkspaceExtensionEnabled(makeWorkspace(undefined), "subagents")).toBe(false);
    expect(isWorkspaceExtensionEnabled(makeWorkspace(undefined), "voice")).toBe(false);
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

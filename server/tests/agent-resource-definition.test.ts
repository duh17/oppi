import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { AgentDefinitionStore, validateAgentDefinition } from "../src/agent-definitions.js";
import { openDatabase } from "../src/sqlite-compat.js";

describe("saved Agent resource definitions", () => {
  it("starts with no saved Agents in a fresh store", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-definition-fresh-"));
    const store = new AgentDefinitionStore(dataDir);

    try {
      expect(store.listAgents()).toEqual([]);
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("preserves inherit versus exact-empty capability selection", () => {
    expect(validateAgentDefinition({ name: "Inherited" }).capabilities).toBeUndefined();
    expect(validateAgentDefinition({ name: "Inherited" }).context).toBeUndefined();
    const exact = validateAgentDefinition({
      name: "No plugins, no servers, no Skills",
      capabilities: { plugins: [], mcp: {} },
      context: { skills: [] },
    });
    expect(exact.capabilities).toEqual({ plugins: [], mcp: {} });
    expect(exact.context).toEqual({ skills: [] });
  });

  it("preserves portable launch constraints", () => {
    expect(
      validateAgentDefinition({
        name: "Sandbox Scout",
        launchConstraints: {
          allowedWorkspaceIds: ["research-workspace"],
          requiredRuntime: "sandbox",
        },
      }).launchConstraints,
    ).toEqual({
      allowedWorkspaceIds: ["research-workspace"],
      requiredRuntime: "sandbox",
    });
  });

  it.each([
    [{ allowedWorkspaceIds: [] }, "launchConstraints.allowedWorkspaceIds must not be empty"],
    [{ requiredRuntime: "remote" }, "launchConstraints.requiredRuntime must be host or sandbox"],
  ])("rejects invalid launch constraints %#", (launchConstraints, message) => {
    expect(() => validateAgentDefinition({ name: "Invalid", launchConstraints })).toThrow(message);
  });

  it("rejects a v1 tool list, naming what replaced it", () => {
    expect(() =>
      validateAgentDefinition({
        name: "Invalid tools",
        sessionDefaults: { excludeTools: ["gmail"] },
      }),
    ).toThrow("Agent definitions are v2: sessionDefaults.excludeTools was replaced by");
  });

  it("rewrites a stored v1 definition and its history", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-resource-migration-"));
    const databasePath = join(dataDir, "session-state.db");
    let store = new AgentDefinitionStore(dataDir);

    try {
      const agent = store.createAgent({ name: "Historical" });
      store.close();

      const db = openDatabase(databasePath);
      const historicalDefinition = JSON.stringify({
        name: "Historical",
        resources: {
          skillPaths: [],
          promptTemplateIds: ["review"],
          extensionIds: [],
        },
      });
      db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
        historicalDefinition,
        agent.id,
      );
      db.prepare(
        "UPDATE agent_definition_versions SET definition_json = ? WHERE id = ? AND version = ?",
      ).run(historicalDefinition, agent.id, agent.version);
      db.close();

      store = new AgentDefinitionStore(dataDir);
      expect(store.hasV1Definitions()).toBe(true);
      store.migrateStoredDefinitions({
        extensions: new Map(),
        pluginByTool: new Map(),
        plugins: new Map(),
        userMcpServers: [],
        workspaceMcpServers: new Map(),
        mcpServerTools: new Map(),
      });
      expect(store.hasV1Definitions()).toBe(false);
      // An empty Skill list means no Skills, which v2 states the same way.
      expect(store.getAgent(agent.id)?.definition.context).toEqual({ skills: [] });
      expect(store.getAgentVersion(agent.id, agent.version)?.definition.context).toEqual({
        skills: [],
      });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

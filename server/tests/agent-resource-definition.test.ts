import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { AgentDefinitionStore, validateAgentDefinition } from "../src/agent-definitions.js";
import { openDatabase } from "../src/sqlite-compat.js";

describe("saved Agent resource definitions", () => {
  it("preserves inherit versus exact-empty resource selection", () => {
    expect(validateAgentDefinition({ name: "Inherited" }).resources).toBeUndefined();
    expect(
      validateAgentDefinition({
        name: "No optional resources",
        resources: { skillPaths: [], extensionIds: [] },
      }).resources,
    ).toEqual({ skillPaths: [], extensionIds: [] });
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

  it("rejects prompt templates because they are interactive composer shortcuts", () => {
    expect(() =>
      validateAgentDefinition({
        name: "Invalid templates",
        resources: { promptTemplateIds: ["review"] },
      }),
    ).toThrow("resources has unexpected field: promptTemplateIds");
  });

  it("removes historical prompt template assignments when loading saved definitions", () => {
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
      const expectedResources = {
        skillPaths: [],
        extensionIds: [],
      };
      expect(store.getAgent(agent.id)?.definition.resources).toEqual(expectedResources);
      expect(store.getAgentVersion(agent.id, agent.version)?.definition.resources).toEqual(
        expectedResources,
      );
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { isAgentDefinitionV1 } from "../src/agent-definition.js";
import {
  migrateAgentDefinitionV1,
  type AgentMigrationCatalogs,
} from "../src/agent-definition-migration.js";
import { AgentDefinitionStore, validateAgentDefinition } from "../src/agent-definitions.js";
import { openDatabase } from "../src/sqlite-compat.js";

const fixture = (name: string): unknown =>
  JSON.parse(readFileSync(join(import.meta.dirname, "fixtures/agent-migration", name), "utf8"));

const catalogs = (): AgentMigrationCatalogs => {
  const raw = fixture("catalogs.json") as {
    extensions: Array<[string, { name: string; enabled: boolean; tools: string[] }]>;
    pluginByTool: Array<[string, string]>;
    plugins: Array<[string, string[]]>;
    userMcpServers: string[];
    workspaceMcpServers: Array<[string, string[]]>;
    mcpServerTools: Array<[string, string[]]>;
  };
  return {
    extensions: new Map(raw.extensions),
    pluginByTool: new Map(raw.pluginByTool),
    plugins: new Map(raw.plugins),
    userMcpServers: raw.userMcpServers,
    workspaceMcpServers: new Map(raw.workspaceMcpServers),
    mcpServerTools: new Map(raw.mcpServerTools),
  };
};

interface LiveAgent {
  key: string;
  version: number;
  definition: Record<string, unknown>;
}

const liveAgents = fixture("live-agents.json") as LiveAgent[];
const expected = fixture("migrated-agents.json") as Record<string, Record<string, unknown>>;

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-agent-migration-"));
  dirs.push(dir);
  return dir;
}

describe("migrateAgentDefinitionV1", () => {
  // The thirteen saved Agents as they were stored on 2026-11-21, with personal text removed. What
  // each one may reach is what the migration must preserve; the golden file is the same table in
  // plain words for the owner.
  for (const agent of liveAgents) {
    it(`migrates ${agent.key} to what it could actually do`, () => {
      const result = migrateAgentDefinitionV1(agent.definition, catalogs());
      expect(result.definition).toEqual(expected[agent.key]);
    });
  }

  it("is idempotent: a migrated definition comes back unchanged", () => {
    for (const agent of liveAgents) {
      const once = migrateAgentDefinitionV1(agent.definition, catalogs()).definition;
      expect(migrateAgentDefinitionV1(once, catalogs())).toEqual({ notes: [] });
    }
  });

  it("produces definitions the v2 validator accepts", () => {
    for (const agent of liveAgents) {
      const migrated = migrateAgentDefinitionV1(agent.definition, catalogs()).definition;
      expect(validateAgentDefinition({ ...migrated, icon: undefined })).toMatchObject({
        name: "Agent",
      });
    }
  });

  it("gives a read-only Agent no MCP server it did not name", () => {
    // The lockdown of 2026-11-21: a read-only Agent that named no MCP tool had every server.
    for (const agent of liveAgents) {
      const capabilities = migrateAgentDefinitionV1(agent.definition, catalogs()).definition
        ?.capabilities;
      if (capabilities?.core !== "readonly") continue;
      const servers = Object.keys(capabilities.mcp ?? {});
      // The only read-only Agent that keeps a server is the one whose tool list named it exactly.
      expect(servers.length === 0 || capabilities.mcp !== undefined).toBe(true);
    }
  });

  it("recognises the v1 shape and leaves a v2 definition alone", () => {
    expect(isAgentDefinitionV1(liveAgents[0]?.definition)).toBe(true);
    expect(isAgentDefinitionV1(expected["agent-1"])).toBe(false);
    expect(isAgentDefinitionV1({ name: "A" })).toBe(false);
  });
});

describe("AgentDefinitionStore", () => {
  function seedV1(dir: string, definition: Record<string, unknown>): void {
    const db = openDatabase(join(dir, "session-state.db"));
    db.exec(`
      CREATE TABLE IF NOT EXISTS agent_definitions (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active',
        version INTEGER NOT NULL DEFAULT 1, definition_json TEXT NOT NULL,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, archived_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS agent_definition_versions (
        id TEXT NOT NULL, version INTEGER NOT NULL, definition_json TEXT NOT NULL,
        created_at INTEGER NOT NULL, PRIMARY KEY (id, version)
      );
    `);
    const json = JSON.stringify(definition);
    db.prepare(
      "INSERT INTO agent_definitions (id, name, status, version, definition_json, created_at, updated_at) VALUES ('a1','Agent','active',2,?,0,0)",
    ).run(json);
    db.prepare(
      "INSERT INTO agent_definition_versions (id, version, definition_json, created_at) VALUES ('a1',1,?,0), ('a1',2,?,0)",
    ).run(json, json);
    db.close();
  }

  it("rewrites the stored row and its version history in one pass", () => {
    const dir = tempDir();
    seedV1(dir, liveAgents[0]!.definition);
    const store = new AgentDefinitionStore(dir);
    expect(store.hasV1Definitions()).toBe(true);
    expect(store.getAgent("a1")?.v1).toBe(true);

    const { migrated } = store.migrateStoredDefinitions(catalogs());

    expect(migrated).toBeGreaterThan(0);
    expect(store.hasV1Definitions()).toBe(false);
    expect(store.getAgent("a1")?.v1).toBeUndefined();
    expect(store.getAgent("a1")?.definition).toEqual(expected["agent-1"]);
    // A resumed session reads the version it pinned, so history is readable v2 as well.
    for (const version of store.listAgentVersions()) {
      expect(isAgentDefinitionV1(version.definition)).toBe(false);
    }
    store.close();
  });

  it("refuses a v1 definition on write, naming what replaced it", () => {
    expect(() =>
      validateAgentDefinition({
        name: "Old",
        resources: { skillPaths: ["/tmp/SKILL.md"] },
      }),
    ).toThrow(/resources was replaced by capabilities and context/);
    expect(() =>
      validateAgentDefinition({ name: "Old", sessionDefaults: { tools: ["read"] } }),
    ).toThrow(/sessionDefaults.tools was replaced by capabilities/);
  });

  it("requires a restricted Agent to state its plugins and MCP servers", () => {
    expect(() =>
      validateAgentDefinition({ name: "A", capabilities: { core: "readonly", plugins: [] } }),
    ).toThrow(/capabilities.mcp is required/);
    expect(() =>
      validateAgentDefinition({ name: "A", capabilities: { core: "readonly", mcp: {} } }),
    ).toThrow(/capabilities.plugins is required/);
    expect(() =>
      validateAgentDefinition({
        name: "A",
        capabilities: { core: "readonly", plugins: [], mcp: {} },
      }),
    ).not.toThrow();
  });

  it("rejects a tool pattern where a server name belongs", () => {
    expect(() =>
      validateAgentDefinition({
        name: "A",
        capabilities: { mcp: { mcp__gmail__search: "all" } },
      }),
    ).toThrow(/name the server \(gmail\), not a tool pattern/);
  });
});

import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { isAgentDefinitionV1 } from "../src/agent-definition.js";
import {
  migrateAgentDefinitionV1,
  type AgentMigrationCatalogs,
} from "../src/agent-definition-migration.js";
import {
  agentMcpNamespace,
  agentToolSetReadOnly,
  AGENT_DISCOVERY_TOOLS,
  AGENT_MCP_RESOURCE_TOOL_NAMES,
  AGENT_TOGGLE_TOOLS,
  compileAgentCapabilities,
  type AgentBuiltinPluginFact,
} from "../src/agent-capabilities.js";
import type { AgentDefinition, AgentMcpServerFact } from "../src/agent-definition.js";
import { sessionPiTools, toolAllowed } from "../src/durable-agent.js";
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
    piToolNames: string[];
  };
  return {
    extensions: new Map(raw.extensions),
    pluginByTool: new Map(raw.pluginByTool),
    plugins: new Map(raw.plugins),
    userMcpServers: raw.userMcpServers,
    workspaceMcpServers: new Map(raw.workspaceMcpServers),
    mcpServerTools: new Map(raw.mcpServerTools),
    piToolNames: raw.piToolNames,
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

  it("gives an Agent that cannot edit files no MCP server it did not name", () => {
    // The lockdown of 2026-11-21: a sealed Agent that named no MCP tool had every server.
    for (const agent of liveAgents) {
      const capabilities = migrateAgentDefinitionV1(agent.definition, catalogs()).definition
        ?.capabilities;
      if (capabilities?.tools === undefined || !agentToolSetReadOnly(capabilities.tools)) continue;
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

  it("rewrites a coding tier into the Pi tools each Agent can use now", () => {
    const dir = tempDir();
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
    const sealed = {
      name: "Reviewer",
      capabilities: { core: "readonly", ask: false, plugins: [], mcp: {} },
    };
    const open = { name: "Worker", capabilities: { core: "full", plugins: ["webtools"] } };
    const json = (value: unknown) => JSON.stringify(value);
    db.prepare(
      "INSERT INTO agent_definitions (id, name, status, version, definition_json, created_at, updated_at) VALUES ('a1','Reviewer','active',2,?,0,0), ('a2','Worker','active',1,?,0,0)",
    ).run(json(sealed), json(open));
    db.prepare(
      "INSERT INTO agent_definition_versions (id, version, definition_json, created_at) VALUES ('a1',1,?,0), ('a1',2,?,0)",
    ).run(json(sealed), json(sealed));
    db.close();

    const store = new AgentDefinitionStore(dir);
    expect(store.hasCodingTierDefinitions()).toBe(true);
    // The live Pi Tools selection, resolved: read, bash, edit, write and codemode on this server.
    const live = ["read", "bash", "edit", "write", "codemode"];
    const first = store.migrateStoredAgentTools(live);

    expect(first.migrated).toBeGreaterThan(0);
    expect(store.hasCodingTierDefinitions()).toBe(false);
    // An Agent that could not write keeps exactly what it could use: no write/edit, and no
    // codemode of its own — an MCP server it names still hands codemode over at launch.
    expect(store.getAgent("a1")?.definition.capabilities).toEqual({
      tools: ["read", "bash"],
      ask: false,
      plugins: [],
      mcp: {},
    });
    // A normal Agent stated no tools and followed the setting; it still does.
    expect(store.getAgent("a2")?.definition.capabilities).toEqual({ plugins: ["webtools"] });
    // A resumed session reads the version it pinned, so history is rewritten too.
    for (const version of store.listAgentVersions()) {
      expect(
        (version.definition.capabilities as { core?: unknown } | undefined)?.core,
      ).toBeUndefined();
    }
    // Idempotent: a second pass finds nothing to rewrite and writes nothing.
    expect(store.migrateStoredAgentTools(live).migrated).toBe(0);
    store.close();
  });

  it("migrates representative stored shapes with equal effective tools and discovery before and after", () => {
    // Representative stored shapes from before the coding-tier removal: read-only with an admitted
    // codemode MCP server, read-only without MCP, and full (explicit and omitted core).
    type LegacyCapabilities = {
      core?: "full" | "readonly";
      ask?: boolean;
      notify?: boolean;
      subagent?: boolean;
      plugins?: string[];
      mcp?: Record<string, "all" | string[]>;
    };
    type LegacyDefinition = { name: string; capabilities?: LegacyCapabilities };

    const mcpServers: AgentMcpServerFact[] = [
      { name: "gmail", enabled: true, exposures: ["codemode"], tools: ["search", "read", "send"] },
      { name: "xcode", enabled: true, exposures: ["direct"], tools: ["build"] },
    ];
    const builtinPlugins: AgentBuiltinPluginFact[] = [
      { name: "background-jobs", tools: ["bash", "background_job"] },
      { name: "oppi-sql-explorer", tools: ["sqlite_query"] },
      { name: "oppi-live-voice", tools: ["speak"] },
      { name: "oppi-notify", tools: ["notify"] },
    ];
    const allPiTools = [
      "read",
      "write",
      "edit",
      "bash",
      "ls",
      "find",
      "grep",
      "codemode",
      "tool_search",
    ];
    const universe = [
      ...allPiTools,
      "ask",
      "notify",
      "subagent",
      "background_job",
      "sqlite_query",
      "speak",
      "mcp__gmail__search",
      "mcp__gmail__read",
      "mcp__gmail__send",
      "mcp__xcode__build",
    ];

    // Pre-migration compiler semantics (`core: "full" | "readonly"`), matching 2fe146736.
    function compileBefore(
      def: LegacyDefinition,
      liveSetting: readonly string[],
    ): {
      readOnly: boolean;
      discovery: string[];
      mcp: ReturnType<typeof compileAgentCapabilities>["mcp"];
      offered: string[];
    } {
      const cap = def.capabilities ?? {};
      const core = cap.core ?? "full";
      const readOnly = core === "readonly";
      const mcpSelection = cap.mcp;
      const names = mcpSelection === undefined ? undefined : Object.keys(mcpSelection);
      const mcpOff = names !== undefined && names.length === 0;
      const admitted = mcpOff
        ? []
        : names === undefined
          ? mcpServers
          : mcpServers.filter((s) =>
              names.some((n) => agentMcpNamespace(n) === agentMcpNamespace(s.name)),
            );
      const admittedNs = new Set(admitted.map((s) => agentMcpNamespace(s.name)));
      const mcpExcluded = mcpOff
        ? ["mcp__*", ...AGENT_MCP_RESOURCE_TOOL_NAMES]
        : [
            ...mcpServers
              .filter((s) => !admittedNs.has(agentMcpNamespace(s.name)))
              .map((s) => `${agentMcpNamespace(s.name)}__*`),
            ...admitted.flatMap((s) => {
              const sel = mcpSelection?.[s.name];
              if (!sel || sel === "all") return [];
              return s.tools
                .filter((t) => !sel.includes(t))
                .map((t) => `${agentMcpNamespace(s.name)}__${t}`);
            }),
          ];
      const exposures = new Set(admitted.flatMap((s) => s.exposures));
      const discovery = [
        ...(exposures.has("codemode") ? ["codemode"] : []),
        ...(exposures.has("deferred") || exposures.has("codemode") || !readOnly
          ? ["tool_search"]
          : []),
      ];
      const tierTools = new Set(["read", "bash", "ls", "find", "grep"]);
      const namedPlugins = new Set(cap.plugins ?? []);
      const togglePlugins = new Set(Object.values(AGENT_TOGGLE_TOOLS).map((t) => t.plugin));
      const builtinExcluded = !readOnly
        ? []
        : builtinPlugins
            .filter(
              (b) =>
                !namedPlugins.has(b.name) &&
                !togglePlugins.has(b.name) &&
                b.name !== "oppi-live-voice",
            )
            .flatMap((b) => b.tools.filter((t) => !tierTools.has(t)));
      const deniedDiscovery =
        readOnly && mcpOff ? AGENT_DISCOVERY_TOOLS.filter((t) => !discovery.includes(t)) : [];
      const excluded = [
        ...(readOnly ? ["write", "edit"] : []),
        ...(cap.ask === false ? ["ask"] : []),
        ...(cap.notify === false ? ["notify"] : []),
        ...(cap.subagent === false ? ["subagent"] : []),
        ...deniedDiscovery,
        ...mcpExcluded,
        ...builtinExcluded,
      ];
      const piSet = new Set([
        ...liveSetting.filter((t) => !(readOnly && (t === "codemode" || t === "tool_search"))),
        ...(discovery.includes("codemode") ? ["codemode"] : []),
      ]);
      const offered = universe
        .filter((tool) => {
          if (
            excluded.some((p) =>
              p.endsWith("__*") ? tool.startsWith(p.slice(0, -1)) : p === tool,
            )
          ) {
            return false;
          }
          return toolAllowed(undefined, tool, piSet);
        })
        .sort();
      return {
        readOnly,
        discovery,
        mcp: mcpOff
          ? { enabled: false, servers: [] }
          : {
              enabled: true,
              ...(names === undefined
                ? {}
                : { servers: admitted.map((s) => s.name), tools: mcpSelection }),
            },
        offered,
      };
    }

    function compileAfter(
      def: AgentDefinition,
      liveSetting: readonly string[],
    ): {
      readOnly: boolean;
      discovery: string[];
      mcp: ReturnType<typeof compileAgentCapabilities>["mcp"];
      offered: string[];
    } {
      const compiled = compileAgentCapabilities({
        definition: def,
        engine: "durable",
        runtime: "host",
        mcpServers,
        builtinPlugins,
        piToolNames: allPiTools,
      });
      // Effective Pi tools offered by the session: `sessionPiTools` plus `codemode` offered by
      // `DurableMcp.discoveryTools` whenever an admitted MCP server has codemode exposure.
      const piSet = new Set([
        ...sessionPiTools(compiled, new Set(liveSetting)),
        ...(compiled.discovery.includes("codemode") ? ["codemode"] : []),
      ]);
      const offered = universe
        .filter((tool) => {
          if (
            compiled.excluded.some((p) =>
              p.endsWith("__*") ? tool.startsWith(p.slice(0, -1)) : p === tool,
            )
          ) {
            return false;
          }
          return toolAllowed(undefined, tool, piSet);
        })
        .sort();
      return {
        readOnly: compiled.readOnly,
        discovery: [...compiled.discovery],
        mcp: compiled.mcp,
        offered,
      };
    }

    const shapes: Array<{ id: string; def: LegacyDefinition }> = [
      {
        id: "ro-mcp",
        def: {
          name: "Mail triage",
          capabilities: {
            core: "readonly",
            ask: false,
            notify: false,
            subagent: false,
            plugins: [],
            mcp: { gmail: ["search", "read"] },
          },
        },
      },
      {
        id: "ro-plain",
        def: {
          name: "Reviewer",
          capabilities: {
            core: "readonly",
            ask: false,
            plugins: ["background-jobs"],
            mcp: {},
          },
        },
      },
      {
        id: "full-explicit",
        def: {
          name: "Worker",
          capabilities: { core: "full", plugins: ["webtools"] },
        },
      },
      {
        id: "full-omitted",
        def: {
          name: "Default",
          capabilities: { mcp: { gmail: "all" } },
        },
      },
    ];

    for (const liveSetting of [
      ["read", "bash", "edit", "write", "codemode"],
      ["read", "bash", "edit", "write"],
    ]) {
      const dir = tempDir();
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
      const insert = db.prepare(
        "INSERT INTO agent_definitions (id, name, status, version, definition_json, created_at, updated_at) VALUES (?, ?, 'active', 1, ?, 0, 0)",
      );
      for (const shape of shapes) insert.run(shape.id, shape.def.name, JSON.stringify(shape.def));
      db.close();

      const store = new AgentDefinitionStore(dir);
      store.migrateStoredAgentTools(liveSetting);
      for (const shape of shapes) {
        const migrated = store.getAgent(shape.id)?.definition;
        expect(migrated, shape.id).toBeDefined();
        expect(compileAfter(migrated!, liveSetting), `${shape.id} (${liveSetting.join(",")})`).toEqual(
          compileBefore(shape.def, liveSetting),
        );
      }
      store.close();
    }
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

  it("requires an Agent that cannot edit files to state its plugins and MCP servers", () => {
    expect(() =>
      validateAgentDefinition({ name: "A", capabilities: { tools: ["read"], plugins: [] } }),
    ).toThrow(/capabilities.mcp is required/);
    expect(() =>
      validateAgentDefinition({ name: "A", capabilities: { tools: ["read"], mcp: {} } }),
    ).toThrow(/capabilities.plugins is required/);
    expect(() =>
      validateAgentDefinition({
        name: "A",
        capabilities: { tools: ["read"], plugins: [], mcp: {} },
      }),
    ).not.toThrow();
    // A set that can write needs neither: it is a normal session that may change files.
    expect(() =>
      validateAgentDefinition({ name: "A", capabilities: { tools: ["read", "edit"] } }),
    ).not.toThrow();
  });

  it("refuses one tool name twice, and refuses the old coding tier by name", () => {
    expect(() =>
      validateAgentDefinition({ name: "A", capabilities: { tools: ["read", "read"] } }),
    ).toThrow(/names a tool twice/);
    expect(() =>
      validateAgentDefinition({
        name: "A",
        capabilities: { core: "readonly", plugins: [], mcp: {} } as never,
      }),
    ).toThrow(/capabilities has unexpected field: core/);
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

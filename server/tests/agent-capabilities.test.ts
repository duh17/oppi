import { describe, expect, it } from "vitest";

import {
  AGENT_CORE_TIER_TOOLS,
  AGENT_MCP_RESOURCE_TOOL_NAMES,
  agentMcpNamespace,
  compileAgentCapabilities,
  createBuiltinPluginFactsReader,
  selectAgentSkills,
  type AgentBuiltinPluginFact,
} from "../src/agent-capabilities.js";
import type { AgentDefinition, AgentMcpServerFact } from "../src/agent-definition.js";
import { AgentConfigurationError } from "../src/agent-launch-errors.js";

const server = (
  name: string,
  exposures: AgentMcpServerFact["exposures"],
  tools: string[] = [],
): AgentMcpServerFact => ({ name, enabled: true, exposures, tools });

const servers: AgentMcpServerFact[] = [
  server("gmail", ["codemode"], ["search", "read", "send"]),
  server("xcode", ["direct"], ["BuildProject", "RunAllTests"]),
  server("coros", ["deferred"], ["querySleepOverview"]),
  { ...server("off", ["codemode"]), enabled: false },
];

function compile(
  definition: AgentDefinition,
  overrides: Partial<Parameters<typeof compileAgentCapabilities>[0]> = {},
) {
  return compileAgentCapabilities({
    definition,
    engine: "durable",
    runtime: "host",
    mcpServers: servers,
    ...overrides,
  });
}

describe("compileAgentCapabilities", () => {
  it("makes a default Agent a normal session", () => {
    const compiled = compile({ name: "A" });
    expect(compiled.core).toBe("full");
    expect(compiled.allowed).toBeUndefined();
    expect(compiled.excluded).toEqual([]);
    expect(compiled.mcp).toEqual({ enabled: true });
    expect(compiled.plugins).toBeUndefined();
    expect(compiled.skills).toBeUndefined();
    expect(compiled.contextFiles).toBe(true);
    expect(compiled.sessionHistory).toBe(true);
    expect(compiled.ask).toBe(true);
    expect(compiled.notify).toBe(true);
    expect(compiled.subagent).toBe(true);
    expect(compiled.warnings).toEqual([]);
  });

  it("never needs an allow list, even for a read-only Agent", () => {
    const compiled = compile({
      name: "A",
      capabilities: { core: "readonly", plugins: [], mcp: {} },
    });
    expect(compiled.allowed).toBeUndefined();
    // Read and shell only: the two tools that write, plus the MCP transport tools it cannot need.
    expect([...compiled.excluded].sort()).toEqual(
      [
        "codemode",
        "edit",
        "mcp__*",
        "tool_search",
        "write",
        ...AGENT_MCP_RESOURCE_TOOL_NAMES,
      ].sort(),
    );
    expect(compiled.mcp).toEqual({ enabled: false, servers: [] });
  });

  it("derives codemode from a codemode-exposed server, and tool search from a deferred one", () => {
    const compiled = compile({
      name: "A",
      capabilities: { mcp: { gmail: "all" } },
    });
    expect(compiled.discovery).toEqual(["codemode", "tool_search"]);
    expect(compiled.mcp).toEqual({
      enabled: true,
      servers: ["gmail"],
      tools: { gmail: "all" },
    });
    // Every other configured server is excluded by pattern, so it cannot be reached by name.
    expect(compiled.excluded).toEqual(["mcp__xcode__*", "mcp__coros__*"]);
  });

  it("keeps an explicit per-server tool list, and excludes the rest of that server's tools", () => {
    const compiled = compile({
      name: "A",
      capabilities: { core: "readonly", plugins: [], mcp: { gmail: ["search", "read"] } },
    });
    expect(compiled.mcp.tools).toEqual({ gmail: ["search", "read"] });
    expect(compiled.excluded).toContain("mcp__gmail__send");
    expect(compiled.excluded).not.toContain("mcp__gmail__search");
    expect(compiled.excluded).not.toContain("mcp__gmail__read");
  });

  it("matches a server by namespace, so the hyphen and underscore spellings agree", () => {
    const facts = [server("chrome-devtools", ["direct"], ["click"])];
    const compiled = compileAgentCapabilities({
      definition: { name: "A", capabilities: { mcp: { chrome_devtools: "all" } } },
      engine: "classic",
      runtime: "host",
      mcpServers: facts,
    });
    expect(compiled.mcp.servers).toEqual(["chrome-devtools"]);
    expect(compiled.excluded).toEqual([]);
    expect(agentMcpNamespace("chrome-devtools")).toBe("mcp__chrome_devtools");
  });

  it("turns the toggles into exclusions and the plugin selection into names", () => {
    const compiled = compile({
      name: "A",
      capabilities: { ask: false, notify: false, subagent: false, plugins: ["webtools"] },
    });
    expect(compiled.excluded).toEqual(["ask", "notify", "subagent"]);
    expect(compiled.plugins).toEqual(["webtools"]);
  });

  it("names only the plugins the Agent stated, never a toggle's package", () => {
    const compiled = compile({ name: "A", capabilities: { plugins: ["webtools"] } });
    // The toggles are switches, not plugin names: a classic session adds their packages itself,
    // so listing `ask` or `subagents` here would make a launch fail on a package the Agent never
    // asked for.
    expect(compiled.plugins).toEqual(["webtools"]);
    expect(compiled.plugins).not.toContain("ask");
    expect(compiled.plugins).not.toContain("subagents");
  });

  it("gives a classic sandbox no codemode, even for a codemode-exposed server", () => {
    const compiled = compile(
      { name: "A", capabilities: { mcp: { gmail: "all" } } },
      { engine: "classic", runtime: "sandbox" },
    );
    expect(compiled.discovery).toEqual(["tool_search"]);
  });

  it("reaches no MCP server while the server's MCP switch is off", () => {
    const compiled = compile({ name: "A" }, { mcpAvailable: false });
    expect(compiled.mcp).toEqual({ enabled: false, servers: [] });
    expect(compiled.excluded).toContain("mcp__*");
    // The search is not an MCP tool: a full Agent keeps it for its plugins' deferred tools, and
    // with no server it reaches nothing.
    expect(compiled.discovery).toEqual(["tool_search"]);
  });

  it("affords tool search to a full Agent, not to a read-only one", () => {
    // A plugin's deferred tool is declared to the model only once tool_search loads it. A full
    // Agent may reach every loaded plugin, so the search is part of a normal session. A read-only
    // Agent states what it reaches: Oppi's catalog reports tool names, not exposures, so nothing
    // can say whether a plugin it named defers a tool, and the search would hand it unnamed tools.
    expect(compile({ name: "A" }, { mcpServers: [] }).discovery).toEqual(["tool_search"]);
    const sealed = compile({
      name: "A",
      capabilities: { core: "readonly", plugins: ["imagen", "secret"], mcp: {} },
    });
    expect(sealed.discovery).toEqual([]);
    expect(sealed.excluded).toContain("tool_search");
  });

  it("carries the context toggles straight through", () => {
    const compiled = compile({
      name: "A",
      context: { skills: ["qa", "qa", "testing"], contextFiles: false, sessionHistory: false },
    });
    expect(compiled.skills).toEqual(["qa", "testing"]);
    expect(compiled.contextFiles).toBe(false);
    expect(compiled.sessionHistory).toBe(false);
  });

  it("warns when a tool subset cannot be narrowed without the server's tool list", () => {
    const compiled = compileAgentCapabilities({
      definition: { name: "A", capabilities: { mcp: { gmail: ["search"] } } },
      engine: "classic",
      runtime: "host",
      mcpServers: [server("gmail", ["codemode"])],
    });
    expect(compiled.warnings).toHaveLength(1);
    expect(compiled.warnings[0]).toContain("gmail");
  });
});

describe("selectAgentSkills", () => {
  const skills = [
    { filePath: "/w/.pi/skills/qa/SKILL.md", name: "qa" },
    { filePath: "/home/skills/testing/SKILL.md", name: "testing" },
  ];

  it("keeps discovery when the Agent names nothing", () => {
    expect(selectAgentSkills(skills, undefined)).toEqual({ skills, missing: [] });
  });

  it("filters by folder name and reports the names nothing answers", () => {
    const selected = selectAgentSkills(skills, ["testing", "gone"]);
    expect(selected.skills.map((skill) => skill.name)).toEqual(["testing"]);
    expect(selected.missing).toEqual(["gone"]);
  });
});

describe("an unmigrated definition", () => {
  it("is refused by name instead of compiling as a full session", () => {
    // A row the one-time migration could not rewrite still holds v1 wiring. Reading it as
    // "capabilities not stated" would grant every plugin and every MCP server.
    for (const definition of [
      { name: "Legacy", resources: { skillPaths: ["/x/SKILL.md"] } },
      { name: "Legacy", sessionDefaults: { tools: ["read", "write"] } },
    ]) {
      let thrown: unknown;
      try {
        compile(definition as unknown as AgentDefinition);
      } catch (error) {
        thrown = error;
      }
      expect(thrown).toBeInstanceOf(AgentConfigurationError);
      expect((thrown as AgentConfigurationError).code).toBe("agent_definition_v2_required");
    }
  });
});

describe("Oppi's own plugins, by the names its catalog uses", () => {
  // The server's catalog, abbreviated: the plugins a real session always has, with their tools.
  const catalog: AgentBuiltinPluginFact[] = [
    { name: "background-jobs", tools: ["bash", "background_job"] },
    { name: "oppi-sql-explorer", tools: ["sqlite_query", "sqlite_schema"] },
    { name: "oppi-godot", tools: ["godot_export", "godot_status"] },
    { name: "secret", tools: ["secret_run", "secret_list"] },
    { name: "oppi-live-voice", tools: ["speak"] },
    { name: "oppi-notify", tools: ["notify"] },
    { name: "oppi-control", tools: ["agents_create", "sessions_send"] },
  ];

  it("keeps every unnamed plugin's tools out of a read-only Agent", () => {
    const compiled = compile({ name: "Reviewer", capabilities: { core: "readonly" } }, {
      builtinPlugins: catalog,
    });
    for (const tool of ["sqlite_query", "godot_export", "secret_run", "background_job", "agents_create"]) {
      expect(compiled.excluded, tool).toContain(tool);
    }
  });

  it("keeps the tier's own tools and the switch tools a read-only Agent has", () => {
    // `bash` arrives through background-jobs, but it is the read-only tier's own tool.
    const compiled = compile({ name: "Reviewer", capabilities: { core: "readonly" } }, {
      builtinPlugins: catalog,
    });
    expect(compiled.excluded).not.toContain("bash");
    // Notify is the notify switch's, and live voice is the session's own call.
    expect(compiled.excluded).not.toContain("notify");
    expect(compiled.excluded).not.toContain("speak");
  });

  it("gives back a named plugin's tools", () => {
    const compiled = compile(
      { name: "Reviewer", capabilities: { core: "readonly", plugins: ["background-jobs"] } },
      { builtinPlugins: catalog },
    );
    expect(compiled.excluded).not.toContain("background_job");
    expect(compiled.excluded).toContain("sqlite_query");
  });

  it("refuses a read-only Agent when the catalog could not be read, and starts a full one", () => {
    let refused: unknown;
    try {
      compile(
        { name: "Reviewer", capabilities: { core: "readonly" } },
        { builtinPluginsUnknown: true },
      );
    } catch (error) {
      refused = error;
    }
    expect(refused).toBeInstanceOf(AgentConfigurationError);
    expect((refused as AgentConfigurationError).code).toBe("agent_builtin_plugins_unavailable");

    const full = compile({ name: "Worker" }, { builtinPluginsUnknown: true });
    expect(full.core).toBe("full");
  });
});

describe("createBuiltinPluginFactsReader", () => {
  const facts: AgentBuiltinPluginFact[] = [{ name: "notebook", tools: ["notebook_todo"] }];

  it("answers unknown, never empty, when the catalog cannot be read", async () => {
    const read = createBuiltinPluginFactsReader(async () => {
      throw new Error("extensions unavailable");
    });
    expect(await read()).toBeNull();
  });

  it("keeps the last answer through a failed re-read, and caches a good one", async () => {
    let now = 1_000;
    let fail = false;
    let reads = 0;
    const read = createBuiltinPluginFactsReader(
      async () => {
        reads += 1;
        if (fail) throw new Error("extensions unavailable");
        return facts;
      },
      { now: () => now, ttlMs: 60_000 },
    );
    expect(await read()).toEqual(facts);
    expect(await read()).toEqual(facts);
    expect(reads).toBe(1);
    fail = true;
    now += 120_000;
    expect(await read()).toEqual(facts);
  });
});

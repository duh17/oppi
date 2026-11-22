import { describe, expect, it } from "vitest";

import {
  AGENT_MCP_RESOURCE_TOOL_NAMES,
  agentMcpNamespace,
  agentPiTools,
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

/** Every Pi tool name a session's Pi Tools setting can govern on this server. */
const piToolNames = [
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

function compile(
  definition: AgentDefinition,
  overrides: Partial<Parameters<typeof compileAgentCapabilities>[0]> = {},
) {
  return compileAgentCapabilities({
    definition,
    engine: "durable",
    runtime: "host",
    mcpServers: servers,
    piToolNames,
    ...overrides,
  });
}

describe("compileAgentCapabilities", () => {
  it("makes a default Agent a normal session", () => {
    const compiled = compile({ name: "A" });
    expect(compiled.tools).toBeUndefined();
    expect(compiled.readOnly).toBe(false);
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

  it("states its own Pi tools, and denies every other one Pi governs", () => {
    // A selection is what the Agent keeps; Pi's tool policy can only deny a name, so the rest of
    // Pi's own tools become exclusions. Plugin and MCP tools are untouched by it.
    const compiled = compile({
      name: "A",
      capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} },
    });
    expect(compiled.tools).toEqual(["read", "bash"]);
    expect(compiled.readOnly).toBe(true);
    expect([...compiled.excluded].sort()).toEqual(
      [
        "codemode",
        "edit",
        "find",
        "grep",
        "ls",
        "mcp__*",
        "tool_search",
        "write",
        ...AGENT_MCP_RESOURCE_TOOL_NAMES,
      ].sort(),
    );
    expect(compiled.mcp).toEqual({ enabled: false, servers: [] });
  });

  it("keeps the Pi tools an Agent names, even one the setting leaves off", () => {
    // `grep` is not in the setting's own list; naming it is the Agent saying it wants it.
    const compiled = compile({
      name: "A",
      capabilities: { tools: ["read", "bash", "grep"] },
    });
    expect(compiled.excluded).not.toContain("grep");
    expect(compiled.excluded).toContain("ls");
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
      capabilities: { tools: ["read"], plugins: [], mcp: { gmail: ["search", "read"] } },
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
      piToolNames,
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

  it("affords tool search to an Agent that follows the setting, not to one with its own tools", () => {
    // A plugin's deferred tool is declared to the model only once tool_search loads it. An Agent
    // with no tool set of its own is a normal session, so the search is part of it. An Agent that
    // states its tools gets exactly what it named.
    expect(compile({ name: "A" }, { mcpServers: [] }).discovery).toEqual(["tool_search"]);
    const sealed = compile({
      name: "A",
      capabilities: { tools: ["read", "bash"], plugins: ["imagen", "secret"], mcp: {} },
    });
    expect(sealed.discovery).toEqual([]);
    expect(sealed.excluded).toContain("tool_search");
  });

  it("turns codemode on for a read-only Agent that names it", () => {
    // The owner's own case: an Agent that cannot edit files may still batch its work through
    // codemode, with no MCP server at all.
    const compiled = compile({
      name: "Reviewer",
      capabilities: { tools: ["read", "bash", "codemode"], plugins: [], mcp: {} },
    });
    expect(compiled.readOnly).toBe(true);
    expect(compiled.discovery).toEqual(["codemode"]);
    expect(compiled.excluded).not.toContain("codemode");
  });

  it("keeps codemode off for a read-only Agent that does not name it", () => {
    const compiled = compile({
      name: "Reviewer",
      capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} },
    });
    expect(compiled.readOnly).toBe(true);
    expect(compiled.discovery).toEqual([]);
    expect(compiled.excluded).toContain("codemode");
  });

  it("hands codemode to a read-only Agent whose named MCP server needs it", () => {
    // The regression the plan protects: a server exposing codemode arrives that way whether or
    // not the Agent named the transport.
    const compiled = compile({
      name: "Mail triage",
      capabilities: { tools: ["read", "bash"], plugins: [], mcp: { gmail: "all" } },
    });
    expect(compiled.readOnly).toBe(true);
    expect(compiled.discovery).toEqual(["codemode", "tool_search"]);
    expect(compiled.excluded).not.toContain("codemode");
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
      piToolNames,
    });
    expect(compiled.warnings).toHaveLength(1);
    expect(compiled.warnings[0]).toContain("gmail");
  });
});

describe("agentPiTools", () => {
  it("returns undefined when the Agent follows the server's Pi Tools setting", () => {
    expect(agentPiTools(undefined)).toBeUndefined();
    expect(agentPiTools(compile({ name: "Worker" }))).toBeUndefined();
  });

  it("includes codemode from discovery without duplicating it or adding tool_search", () => {
    const withServer = compile({
      name: "Mail triage",
      capabilities: { tools: ["read", "bash"], plugins: [], mcp: { gmail: "all" } },
    });
    expect(withServer.discovery).toEqual(["codemode", "tool_search"]);
    expect(agentPiTools(withServer)).toEqual(["read", "bash", "codemode"]);

    const namedCodemode = compile({
      name: "Batching",
      capabilities: { tools: ["read", "bash", "codemode"], plugins: [], mcp: { gmail: "all" } },
    });
    expect(agentPiTools(namedCodemode)).toEqual(["read", "bash", "codemode"]);

    const deferredOnly = compile({
      name: "Deferred",
      capabilities: { tools: ["read", "bash"], plugins: [], mcp: { coros: "all" } },
    });
    expect(deferredOnly.discovery).toEqual(["tool_search"]);
    expect(agentPiTools(deferredOnly)).toEqual(["read", "bash"]);
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

  it("keeps every unnamed plugin's tools out of an Agent that cannot edit files", () => {
    const compiled = compile(
      { name: "Reviewer", capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} } },
      { builtinPlugins: catalog },
    );
    for (const tool of [
      "sqlite_query",
      "godot_export",
      "secret_run",
      "background_job",
      "agents_create",
    ]) {
      expect(compiled.excluded, tool).toContain(tool);
    }
  });

  it("keeps the tools the Agent names and the switch tools it has", () => {
    // `bash` arrives through background-jobs, but the Agent names it, so it stays.
    const compiled = compile(
      { name: "Reviewer", capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} } },
      { builtinPlugins: catalog },
    );
    expect(compiled.excluded).not.toContain("bash");
    // Notify is the notify switch's, and live voice is the session's own call.
    expect(compiled.excluded).not.toContain("notify");
    expect(compiled.excluded).not.toContain("speak");
  });

  it("gives back a named plugin's tools", () => {
    const compiled = compile(
      {
        name: "Reviewer",
        capabilities: { tools: ["read", "bash"], plugins: ["background-jobs"], mcp: {} },
      },
      { builtinPlugins: catalog },
    );
    expect(compiled.excluded).not.toContain("background_job");
    expect(compiled.excluded).toContain("sqlite_query");
  });

  it("keeps an unnamed plugin's tool out even when a read-only Agent names it in tools", () => {
    // Only Pi's own governed tools (such as `bash` wrapped by background-jobs) are protected from
    // unnamed built-in exclusions; naming a feature plugin's tool in `capabilities.tools` must not
    // bypass the read-only plugin rule.
    const compiled = compile(
      {
        name: "Reviewer",
        capabilities: {
          tools: ["read", "bash", "sqlite_query", "godot_export"],
          plugins: [],
          mcp: {},
        },
      },
      { builtinPlugins: catalog },
    );
    expect(compiled.excluded).toContain("sqlite_query");
    expect(compiled.excluded).toContain("godot_export");
    expect(compiled.excluded).not.toContain("bash");
  });

  it("refuses an Agent that cannot edit files when the catalog could not be read", () => {
    let refused: unknown;
    try {
      compile(
        { name: "Reviewer", capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} } },
        { builtinPluginsUnknown: true },
      );
    } catch (error) {
      refused = error;
    }
    expect(refused).toBeInstanceOf(AgentConfigurationError);
    expect((refused as AgentConfigurationError).code).toBe("agent_builtin_plugins_unavailable");

    const writable = compile(
      { name: "Worker", capabilities: { tools: ["read", "bash", "edit"] } },
      { builtinPluginsUnknown: true },
    );
    expect(writable.readOnly).toBe(false);
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

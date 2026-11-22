import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  compileAgentCapabilities,
  missingDurablePlugins,
  skippedPluginsWarning,
  type CompiledAgentCapabilities,
} from "../src/agent-capabilities.js";
import { durableLoadablePlugins } from "../src/durable-agent-warnings.js";
import type { AgentDefinition } from "../src/agent-definition.js";
import {
  migrateAgentDefinitionV1,
  type AgentMigrationCatalogs,
} from "../src/agent-definition-migration.js";
import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { DurableMcp, mcpServerFacts, type DurableMcpOptions } from "../src/durable-mcp.js";
import { McpToolCache, mcpToolCachePath } from "../src/mcp-tool-cache.js";
import { SdkBackend } from "../src/sdk-backend.js";
import type { Session, Workspace } from "../src/types.js";

const dirs: string[] = [];
function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
}

let agentDir: string;
let previousAgentDir: string | undefined;

beforeEach(() => {
  agentDir = tempDir("oppi-capability-engines-agent-");
  previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  writeFileSync(join(agentDir, "auth.json"), "{}");
});

afterEach(() => {
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** Three servers, one per exposure, plus one this Agent never reaches. */
function writeServers(): void {
  const command = { command: process.execPath, args: ["-e", "process.exit(0)"] };
  writeFileSync(
    join(agentDir, "mcp.json"),
    JSON.stringify({
      mcpServers: {
        gmail: command,
        xcode: { ...command, exposure: "direct" },
        coros: { ...command, exposure: "deferred" },
      },
    }),
  );
}

/** One server at Pi's default exposure (codemode): nothing in it asks for the search. */
function writeCodemodeServer(): void {
  writeFileSync(
    join(agentDir, "mcp.json"),
    JSON.stringify({
      mcpServers: {
        gmail: { command: process.execPath, args: ["-e", "process.exit(0)"] },
      },
    }),
  );
}

/** Every Pi tool name this server's Pi Tools setting can govern, for the compiler calls below. */
const PI_TOOL_NAMES = [
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

const mailTriageShape: AgentDefinition = {
  name: "Mail triage",
  instructions: { mode: "append", text: "Triage mail." },
  capabilities: {
    tools: ["read", "bash"],
    ask: false,
    notify: false,
    subagent: false,
    plugins: [],
    mcp: { gmail: ["search", "read"] },
  },
};

function makeSession(): Session {
  const now = Date.now();
  return {
    id: "capability-engine-session",
    workspaceId: "workspace-1",
    status: "starting",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, cacheRead: 0, cacheWrite: 0, output: 0 },
    cost: 0,
    runtime: "oppi",
    launch: { status: "launching", requestedAt: now, agentId: "agent-1" },
  };
}

describe("classic engine", () => {
  // One real launch below; the two compiler tests after it are named for what they check.
  it("launches an Agent with the tools it names and nothing that writes", async () => {
    const cwd = tempDir("oppi-capability-classic-");
    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Capability Test",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      agentDefinition: mailTriageShape,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });

    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toEqual(expect.arrayContaining(["read", "bash"]));
      expect(active).not.toContain("write");
      expect(active).not.toContain("edit");
      // The toggles are off, so their tools never reach the model.
      expect(active).not.toContain("ask");
      expect(active).not.toContain("subagent");
    } finally {
      await backend.dispose();
    }
  });

  it("narrows MCP to the servers the Agent names, whatever their exposure", async () => {
    writeServers();
    const definition: AgentDefinition = {
      ...mailTriageShape,
      capabilities: { ...mailTriageShape.capabilities, mcp: { gmail: "all" } },
    };
    const facts = await mcpServerFacts({
      agentDir,
      cwd: agentDir,
      projectTrusted: false,
      dataDir: agentDir,
    });
    const compiled = compileAgentCapabilities({
      definition,
      engine: "classic",
      runtime: "host",
      mcpServers: facts,
      piToolNames: PI_TOOL_NAMES,
    });
    // Every server that is configured but not admitted is excluded by pattern, so no exposure
    // change can open it later; the admitted server needs codemode to be reachable at all.
    expect([...compiled.excluded].sort()).toEqual(
      expect.arrayContaining(["mcp__coros__*", "mcp__xcode__*", "write", "edit"]),
    );
    expect(compiled.excluded).not.toContain("mcp__gmail__*");
    expect(compiled.discovery).toContain("codemode");
    expect(compiled.mcp).toEqual({ enabled: true, servers: ["gmail"], tools: { gmail: "all" } });
  });

  it("reaches no server at all when the Agent selects none", async () => {
    writeServers();
    const compiled = compileAgentCapabilities({
      definition: {
        name: "Sealed",
        capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} },
      },
      engine: "classic",
      runtime: "host",
      mcpServers: await mcpServerFacts({
        agentDir,
        cwd: agentDir,
        projectTrusted: false,
        dataDir: agentDir,
      }),
      piToolNames: PI_TOOL_NAMES,
    });
    expect(compiled.mcp).toEqual({ enabled: false, servers: [] });
    expect(compiled.excluded).toContain("mcp__*");
    expect(compiled.discovery).toEqual([]);
  });

  /**
   * A global extension whose tool is declared `deferred`: Pi registers it and declares it to the
   * model only once `tool_search` loads it, so an inactive search means the tool is unreachable.
   */
  function writeDeferredPlugin(): void {
    const extensions = join(agentDir, "extensions");
    mkdirSync(extensions, { recursive: true });
    writeFileSync(
      join(extensions, "probe-plugin.ts"),
      [
        "export default function (pi) {",
        "  pi.registerTool({",
        "    name: 'probe_deferred',",
        "    label: 'Probe',",
        "    description: 'A deferred probe',",
        "    exposure: 'deferred',",
        "    parameters: { type: 'object', properties: {} },",
        "    execute: async () => ({ content: [{ type: 'text', text: 'probe-ran' }] }),",
        "  });",
        "}",
      ].join("\n"),
    );
  }

  async function launch(definition: AgentDefinition, cwd: string): Promise<SdkBackend> {
    return SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Deferred",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      agentDefinition: definition,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
    });
  }

  it("gives a full Agent the search that declares a plugin's deferred tool", async () => {
    writeDeferredPlugin();
    const backend = await launch(
      { name: "Maker", capabilities: { plugins: ["probe-plugin"] } },
      tempDir("oppi-deferred-full-"),
    );
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("tool_search");
      // Registered and callable, but never declared on its own: only the search loads it.
      expect(backend.session.getToolDefinition("probe_deferred")).toBeDefined();
      expect(active).not.toContain("probe_deferred");
    } finally {
      await backend.dispose();
    }
  });

  it("leaves a read-only Agent without the search, so a deferred tool stays out of reach", async () => {
    writeDeferredPlugin();
    const backend = await launch(
      {
        name: "Sealed",
        capabilities: { tools: ["read", "bash"], plugins: ["probe-plugin"], mcp: {} },
      },
      tempDir("oppi-deferred-readonly-"),
    );
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("read");
      expect(active).not.toContain("tool_search");
      expect(active).not.toContain("probe_deferred");
    } finally {
      await backend.dispose();
    }
  });

  it("leaves a read-only Agent's codemode server without the search too", async () => {
    // `compileMcp` reports both transports a default-exposure server needs, but the search is the
    // one that loads deferred plugin tools, which only a full Agent may reach. The server here is
    // at Pi's default exposure, so this is the engine's own rule and not Pi turning the search on
    // for a deferred server. The durable engine never offers it for codemode alone either
    // (`durable-mcp.ts`, `discoveryTools`): the two engines agree.
    writeCodemodeServer();
    const definition: AgentDefinition = {
      name: "Mail triage",
      capabilities: { tools: ["read", "bash"], plugins: [], mcp: { gmail: "all" } },
    };
    const compiled = compileAgentCapabilities({
      definition,
      engine: "classic",
      runtime: "host",
      mcpServers: await mcpServerFacts({
        agentDir,
        cwd: agentDir,
        projectTrusted: false,
        dataDir: agentDir,
      }),
      piToolNames: PI_TOOL_NAMES,
    });
    expect(compiled.discovery).toEqual(["codemode", "tool_search"]);

    const backend = await launch(definition, tempDir("oppi-search-readonly-"));
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("codemode");
      expect(active).not.toContain("tool_search");
    } finally {
      await backend.dispose();
    }
  });

  /** Pi's own Pi Tools setting, as the Pi page writes it. */
  function writePiToolsSetting(defaultTools: string[]): void {
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ defaultTools }));
  }

  it("turns codemode on for an Agent that names it, with no MCP server at all", async () => {
    // The owner's case: a sealed Agent may batch its own reads through codemode. Nothing in this
    // workspace reaches an MCP server, so only the Agent's own tool set can explain it.
    const backend = await launch(
      {
        name: "Batching Reviewer",
        capabilities: { tools: ["read", "bash", "codemode"], plugins: [], mcp: {} },
      },
      tempDir("oppi-codemode-named-"),
    );
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("codemode");
      expect(active).toContain("read");
      // Still sealed: naming codemode does not hand it the tools that write.
      expect(active).not.toContain("write");
      expect(active).not.toContain("edit");
    } finally {
      await backend.dispose();
    }
  });

  it("keeps codemode off for an Agent that does not name it", async () => {
    // The setting turns codemode on for every normal session; this Agent stated its own tools, so
    // the setting does not reach it.
    writePiToolsSetting(["read", "bash", "edit", "write", "codemode"]);
    const backend = await launch(
      { name: "Sealed", capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} } },
      tempDir("oppi-codemode-unnamed-"),
    );
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("read");
      expect(active).not.toContain("codemode");
    } finally {
      await backend.dispose();
    }
  });

  it("leaves an Agent that follows the setting exactly as the setting has it", async () => {
    writePiToolsSetting(["read", "bash", "edit", "write", "codemode"]);
    const backend = await launch({ name: "Worker" }, tempDir("oppi-inherit-tools-"));
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("codemode");
      expect(active).toContain("write");
      expect(active).toContain("edit");
    } finally {
      await backend.dispose();
    }
  });

  it("turns codemode on for a read-only Agent with a codemode server even when the setting leaves codemode off", async () => {
    // Classic passes `agentPiTools(compiled)` through the settings Proxy so `getDefaultTools()`
    // includes `codemode` from discovery, matching durable's `sessionPiTools`.
    writePiToolsSetting(["read", "bash"]);
    writeCodemodeServer();
    const backend = await launch(
      {
        name: "Mail triage",
        capabilities: { tools: ["read", "bash"], plugins: [], mcp: { gmail: "all" } },
      },
      tempDir("oppi-codemode-proxy-discovery-"),
    );
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("codemode");
      expect(active).toContain("read");
      expect(active).not.toContain("write");
      expect(active).not.toContain("tool_search");
      expect(backend.session.settingsManager.getDefaultTools()).toEqual([
        "read",
        "bash",
        "codemode",
      ]);
    } finally {
      await backend.dispose();
    }
  });

  it("keeps the read-only rule: a plugin it did not name brings no tool", async () => {
    writeDeferredPlugin();
    const backend = await launch(
      {
        name: "Sealed",
        capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} },
      },
      tempDir("oppi-sealed-plugin-"),
    );
    try {
      const active = backend.session.getActiveToolNames();
      expect(active).toContain("read");
      expect(active).not.toContain("probe_deferred");
      expect(active).not.toContain("tool_search");
    } finally {
      await backend.dispose();
    }
  });
});

describe("durable engine", () => {
  async function openMcp(servers: readonly string[]): Promise<DurableMcp | undefined> {
    const options: DurableMcpOptions = {
      sessionId: "s1",
      cwd: agentDir,
      agentDir,
      projectTrusted: false,
      servers,
      policy: undefined,
      piTools: new Set(["read", "bash", "codemode"]),
      providerToken: async () => undefined,
      toolCache: new McpToolCache(mcpToolCachePath(agentDir), "host"),
      install: () => {},
      uninstall: () => {},
    };
    return DurableMcp.open(options);
  }

  it("drops a server the Agent does not admit before it declares a namespace", async () => {
    writeServers();
    const mcp = await openMcp(["gmail"]);
    try {
      expect(mcp).toBeDefined();
      const names = mcp!.selection.map((extension) => extension.name);
      expect(names).toContain("oppi.mcp/s1/gmail");
      // The blocked servers never connect and never print into codemode's section.
      expect(names).not.toContain("oppi.mcp/s1/xcode");
      expect(names).not.toContain("oppi.mcp/s1/coros");
    } finally {
      await mcp?.close();
    }
  });

  it("admits every configured server when the Agent names none", async () => {
    writeServers();
    const mcp = await openMcp(undefined as unknown as readonly string[]);
    try {
      const names = mcp!.selection.map((extension) => extension.name);
      expect(names).toEqual(
        expect.arrayContaining(["oppi.mcp/s1/gmail", "oppi.mcp/s1/xcode", "oppi.mcp/s1/coros"]),
      );
    } finally {
      await mcp?.close();
    }
  });
});

describe("an unmigrated Agent", () => {
  const catalogs = {
    extensions: new Map(),
    pluginByTool: new Map(),
    plugins: new Map(),
    userMcpServers: [],
    workspaceMcpServers: new Map(),
    mcpServerTools: new Map(),
    piToolNames: PI_TOOL_NAMES,
  } satisfies AgentMigrationCatalogs;

  // The row the migration could not rewrite still holds v1 wiring. Every path that compiles a
  // definition refuses it, so it can never run as "capabilities not stated" (full access).
  const legacy = { name: "Legacy", resources: { skillPaths: ["/x/SKILL.md"] } };

  it("refuses a classic launch and a resume pinned to it", async () => {
    await expect(
      SdkBackend.create({
        session: makeSession(),
        workspace: {
          id: "workspace-1",
          name: "Unmigrated",
          runtime: "host",
          hostMount: agentDir,
        } as Workspace,
        // A resume compiles the version the session pinned, through this same call.
        agentDefinition: legacy as unknown as AgentDefinition,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      }),
    ).rejects.toMatchObject({ code: "agent_definition_v2_required" });
  });

  it("keeps such a row listed, marked, and refused by name", () => {
    const dir = tempDir("oppi-capability-v1-");
    const store = new AgentDefinitionStore(dir);
    try {
      const agent = store.createAgent({ name: "Fresh" });
      const raw = JSON.stringify(legacy);
      const db = store as unknown as {
        db: { prepare: (sql: string) => { run: (...a: unknown[]) => void } };
      };
      db.db
        .prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?")
        .run(raw, agent.id);
      const reloaded = new AgentDefinitionStore(dir);
      expect(reloaded.getAgent(agent.id)?.v1).toBe(true);
      reloaded.close();
    } finally {
      store.close();
    }
  });

  it("leaves a row whose rewrite would be invalid in its old shape, with a note", () => {
    // A stored thinking level the migration carries through but the store would refuse: the row
    // stays exactly as it was (so it still refuses to launch) instead of being written.
    const dir = tempDir("oppi-capability-invalid-");
    const store = new AgentDefinitionStore(dir);
    const raw = JSON.stringify({
      name: "Corrupt",
      sessionDefaults: { tools: ["read"], thinkingLevel: "bogus" },
    } satisfies Record<string, unknown>);
    try {
      const agent = store.createAgent({ name: "Corrupt row" });
      const db = store as unknown as {
        db: {
          prepare: (sql: string) => {
            run: (...a: unknown[]) => void;
            get: (...a: unknown[]) => unknown;
          };
        };
      };
      db.db
        .prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?")
        .run(raw, agent.id);
      const { migrated, notes } = store.migrateStoredDefinitions(catalogs);
      expect(migrated).toBe(0);
      expect(
        notes.some((entry) => entry.notes.some((line) => line.includes("could not migrate"))),
      ).toBe(true);
      const row = db.db
        .prepare("SELECT definition_json FROM agent_definitions WHERE id = ?")
        .get(agent.id) as { definition_json: string };
      expect(row.definition_json).toBe(raw);
    } finally {
      store.close();
    }
  });
});

describe("the compiler gives both engines the same plan", () => {
  // Oppi's own plugins, as the server's catalog reports them to both engines at launch.
  // The server's catalog names, as `listExtensions({ plugins: true })` reports them.
  const builtinPlugins = [
    { name: "background-jobs", tools: ["background_job", "bash"] },
    { name: "oppi-sql-explorer", tools: ["sqlite_query", "sqlite_schema"] },
    { name: "oppi-godot", tools: ["godot_capture", "godot_export"] },
    { name: "oppi-live-voice", tools: ["speak"] },
    { name: "oppi-notify", tools: ["notify"] },
    { name: "ask", tools: ["ask"] },
    { name: "subagents", tools: ["subagent"] },
  ];
  const factServers = [
    {
      name: "gmail",
      enabled: true,
      exposures: ["codemode" as const],
      tools: ["search", "read", "send"],
    },
    { name: "xcode", enabled: true, exposures: ["direct" as const], tools: ["BuildProject"] },
    {
      name: "coros",
      enabled: true,
      exposures: ["deferred" as const],
      tools: ["querySleepOverview"],
    },
  ];
  // Every tool name a session of these definitions could be offered.
  const universe = [
    "read",
    "write",
    "edit",
    "bash",
    "ls",
    "find",
    "grep",
    "ask",
    "notify",
    "subagent",
    "codemode",
    "tool_search",
    "background_job",
    "speak",
    "sqlite_query",
    "sqlite_schema",
    "godot_capture",
    "godot_export",
    "mcp__gmail__search",
    "mcp__gmail__read",
    "mcp__gmail__send",
    "mcp__xcode__BuildProject",
    "mcp__coros__querySleepOverview",
  ];

  /** What the plan leaves available, with `mcp__server__*` patterns expanded over the universe. */
  function offered(compiled: CompiledAgentCapabilities): string[] {
    const kept = universe.filter((tool) => {
      if (compiled.allowed && !compiled.allowed.includes(tool)) return false;
      return !compiled.excluded.some((pattern) =>
        pattern.endsWith("__*") ? tool.startsWith(pattern.slice(0, -1)) : pattern === tool,
      );
    });
    return kept.sort();
  }

  const definitions: Array<[string, AgentDefinition]> = [
    ["a full Agent", { name: "Full" }],
    [
      "a read-only Agent",
      { name: "Sealed", capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} } },
    ],
    [
      "a read-only Agent that names a plugin",
      { name: "Named", capabilities: { tools: ["read", "bash"], plugins: ["notebook"], mcp: {} } },
    ],
    [
      "a read-only Agent with a named server's tools",
      {
        name: "Mail",
        capabilities: { tools: ["read", "bash"], plugins: [], mcp: { gmail: ["search", "read"] } },
      },
    ],
  ];

  // Both calls are this compiler with `engine` changed, so this pins the plan the two runtimes are
  // handed, not what the runtimes then offer; each runtime's own tests cover that.
  for (const [label, definition] of definitions) {
    it(`compiles ${label} to the same plan for classic and durable`, () => {
      const classic = compileAgentCapabilities({
        definition,
        engine: "classic",
        runtime: "host",
        mcpServers: factServers,
        builtinPlugins,
        piToolNames: PI_TOOL_NAMES,
      });
      const durable = compileAgentCapabilities({
        definition,
        engine: "durable",
        runtime: "host",
        mcpServers: factServers,
        builtinPlugins,
        piToolNames: PI_TOOL_NAMES,
      });
      expect(offered(classic)).toEqual(offered(durable));
    });
  }

  it("gives an Agent that cannot edit files no built-in plugin tool it did not name", () => {
    const compiled = compileAgentCapabilities({
      definition: {
        name: "Sealed",
        capabilities: { tools: ["read", "bash", "ls", "find", "grep"], plugins: [], mcp: {} },
      },
      engine: "durable",
      runtime: "host",
      mcpServers: factServers,
      builtinPlugins,
      piToolNames: PI_TOOL_NAMES,
    });
    const tools = offered(compiled);
    expect(tools).toEqual(expect.arrayContaining(["read", "bash", "ls", "find", "grep"]));
    for (const tool of [
      "sqlite_query",
      "sqlite_schema",
      "godot_capture",
      "godot_export",
      "background_job",
    ]) {
      expect(tools).not.toContain(tool);
    }
    // The switches are not the plugin rule: they still govern their own tools.
    expect(tools).toContain("ask");
    expect(tools).toContain("notify");
    expect(tools).toContain("subagent");
  });

  it("leaves a full Agent every built-in plugin tool", () => {
    const compiled = compileAgentCapabilities({
      definition: { name: "Full" },
      engine: "classic",
      runtime: "host",
      mcpServers: factServers,
      builtinPlugins,
      piToolNames: PI_TOOL_NAMES,
    });
    expect(offered(compiled)).toEqual(
      expect.arrayContaining(["sqlite_query", "godot_export", "background_job"]),
    );
  });

  it("warns about a named plugin only when the session really lacks it", () => {
    // The built-in owner packages are loaded by the harness, not by `loadedPackages`; counting only
    // the latter reported `background-jobs` — the plugin seven live Agents name — every time. The
    // reader is asked for a real harness answer, which is where that bug lived.
    const harness = {
      loadedPackages: [{ name: "notebook" }, { name: "oppi-sql-explorer" }],
      builtInsFor: (which: "host" | "sandbox") =>
        which === "host" ? [{ name: "background-jobs" }] : [],
    };
    const loadable = durableLoadablePlugins(harness, "host");
    expect(loadable).toEqual(["notebook", "oppi-sql-explorer", "background-jobs"]);
    expect(missingDurablePlugins(["background-jobs", "notebook"], loadable)).toBeUndefined();
    // `secret` is a classic-only Pi extension: a durable session naming it says so.
    expect(missingDurablePlugins(["secret"], loadable)).toEqual(["secret"]);
    expect(skippedPluginsWarning(["secret"])).toContain("no durable version");
    // A sandbox host reports no built-ins, and the reader says so rather than guessing.
    expect(durableLoadablePlugins(harness, "sandbox")).toEqual(["notebook", "oppi-sql-explorer"]);
  });
});

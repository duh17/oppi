import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { defineExtension, type ToolRegistration } from "@earendil-works/pi-durable";
import { CodingTools } from "@earendil-works/pi-durable/tools";

import { resolveDurableAgent, sessionPiTools } from "../src/durable-agent.js";
import { compileChildCapabilities } from "../src/durable-threads.js";
import { loadDurableProjectResources } from "../src/durable-project-resources.js";

const dirs: string[] = [];

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
}

function writeSkill(root: string, name: string, description: string): void {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "SKILL.md"),
    `---\nname: ${name}\ndescription: ${description}\n---\n\n# ${name}\n\nDo it.\n`,
  );
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** Pi's own tool names, as the parent session's plan lists them. */
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

describe("a child Agent spawned as a subagent", () => {
  it("keeps the built-in plugin tools its definition never named out of the child", () => {
    // A bound child's policy is the document written at spawn, so the child's compile needs the
    // same inventory as its parent: without it, `sqlite_*` and `background_job` came back.
    const facts = [
      { name: "oppi-sql-explorer", tools: ["sqlite_query", "sqlite_schema"] },
      { name: "background-jobs", tools: ["bash", "background_job"] },
      { name: "oppi-live-voice", tools: ["speak"] },
    ];
    const compiled = compileChildCapabilities({
      definition: {
        name: "Reviewer",
        capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} },
      },
      runtime: "host",
      mcpServers: [],
      builtinFacts: facts,
      piToolNames: PI_TOOL_NAMES,
    });
    expect(compiled.excluded).toEqual(expect.arrayContaining(["sqlite_query", "background_job"]));
    expect(compiled.excluded).not.toContain("bash");
    expect(compiled.excluded).not.toContain("speak");
  });

  it("refuses a read-only child when the inventory is unknown, and starts a full one", () => {
    expect(() =>
      compileChildCapabilities({
        definition: {
          name: "Reviewer",
          capabilities: { tools: ["read", "bash"], plugins: [], mcp: {} },
        },
        runtime: "host",
        mcpServers: [],
        builtinFacts: null,
        piToolNames: PI_TOOL_NAMES,
      }),
    ).toThrow(/cannot edit files/);
    const full = compileChildCapabilities({
      definition: { name: "Worker" },
      runtime: "host",
      mcpServers: [],
      builtinFacts: null,
      piToolNames: PI_TOOL_NAMES,
    });
    expect(full.readOnly).toBe(false);
    expect(full.tools).toBeUndefined();
  });

  it("runs a child Agent with its own Pi tools (and discovery codemode), not the parent's", () => {
    // Parent offers only read/bash/edit/write (no grep, no codemode).
    const parentTools: ReadonlySet<string> = new Set(["read", "bash", "edit", "write"]);
    const codemode = defineExtension({
      name: "codemode",
      tools: [{ name: "codemode" } as unknown as ToolRegistration],
    });
    const fileTools = defineExtension({
      name: "file-tools",
      tools: [
        { name: "grep" } as unknown as ToolRegistration,
        { name: "find" } as unknown as ToolRegistration,
        { name: "ls" } as unknown as ToolRegistration,
      ],
    });
    const spawn = (
      definition: { name: string; capabilities?: Record<string, unknown> },
      mcpServers: Array<{
        name: string;
        enabled: boolean;
        exposures: Array<"direct" | "deferred" | "codemode">;
        tools: string[];
      }> = [],
    ) => {
      const compiled = compileChildCapabilities({
        definition,
        runtime: "host",
        mcpServers,
        builtinFacts: [],
        piToolNames: PI_TOOL_NAMES,
      });
      return resolveDurableAgent({
        saved: { id: "child-agent", version: 1, definition },
        compiled,
        runtime: "host",
        base: [CodingTools, fileTools, codemode],
        loaded: [],
        enabled: () => true,
        piTools: sessionPiTools(compiled, parentTools),
        codemode,
        sessions: defineExtension({ name: "oppi.sessions" }),
        spawn: false,
        grant: false,
        notify: defineExtension({ name: "oppi.notify" }),
        notifies: false,
      }).change.tools.map((tool) => tool.name);
    };

    // Child Agent states its own tools including grep and codemode that the parent lacks.
    const ownSet = spawn({
      name: "Searcher",
      capabilities: { tools: ["read", "bash", "grep", "codemode"], plugins: [], mcp: {} },
    });
    expect(ownSet.sort()).toEqual(["bash", "codemode", "grep", "read"]);

    // Child Agent with an admitted codemode MCP server gets codemode even without naming it.
    const viaMcp = spawn(
      {
        name: "Mail triage",
        capabilities: { tools: ["read", "bash"], plugins: [], mcp: { gmail: "all" } },
      },
      [{ name: "gmail", enabled: true, exposures: ["codemode"], tools: ["search"] }],
    );
    expect(viaMcp.sort()).toEqual(["bash", "codemode", "read"]);

    // Child Agent following Pi defaults falls back to the parent's tools.
    const inherited = spawn({ name: "Worker" });
    expect(inherited.sort()).toEqual(["bash", "edit", "read", "write"]);
  });
});

describe("a durable session's named Skills", () => {
  it("names the Skills it could not read, so the session can say so", async () => {
    const cwd = tempDir("oppi-skills-cwd-");
    const agentDir = tempDir("oppi-skills-agent-");
    writeSkill(join(agentDir, "skills"), "testing", "How to test");
    const resources = await loadDurableProjectResources({
      hostCwd: cwd,
      agentDir,
      projectTrusted: true,
      resources: { skills: ["testing", "household"] },
    });
    expect(resources.skills.map((skill) => skill.name)).toEqual(["testing"]);
    expect(resources.missingSkills).toEqual(["household"]);
  });

  it("says nothing when every named Skill is there", async () => {
    const cwd = tempDir("oppi-skills-cwd-");
    const agentDir = tempDir("oppi-skills-agent-");
    writeSkill(join(agentDir, "skills"), "testing", "How to test");
    const resources = await loadDurableProjectResources({
      hostCwd: cwd,
      agentDir,
      projectTrusted: true,
      resources: { skills: ["testing"] },
    });
    expect(resources.missingSkills).toBeUndefined();
  });
});

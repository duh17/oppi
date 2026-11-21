import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

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
      definition: { name: "Reviewer", capabilities: { core: "readonly" } },
      runtime: "host",
      mcpServers: [],
      builtinFacts: facts,
    });
    expect(compiled.excluded).toEqual(expect.arrayContaining(["sqlite_query", "background_job"]));
    expect(compiled.excluded).not.toContain("bash");
    expect(compiled.excluded).not.toContain("speak");
  });

  it("refuses a read-only child when the inventory is unknown, and starts a full one", () => {
    expect(() =>
      compileChildCapabilities({
        definition: { name: "Reviewer", capabilities: { core: "readonly" } },
        runtime: "host",
        mcpServers: [],
        builtinFacts: null,
      }),
    ).toThrow(/read-only/);
    const full = compileChildCapabilities({
      definition: { name: "Worker" },
      runtime: "host",
      mcpServers: [],
      builtinFacts: null,
    });
    expect(full.core).toBe("full");
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

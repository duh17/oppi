import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import { loadDurableProjectResources } from "../src/durable-project-resources.js";
import type { GondolinVm } from "../src/gondolin-ops.js";

const GUEST = "/workspace/project";
const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
}

function writeSkill(dir: string, name: string): string {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "SKILL.md"),
    ["---", `name: ${name}`, `description: ${name} skill.`, "---", `${name} body.`].join("\n"),
  );
  return dir;
}

/** A sandbox workspace with an agent directory and a host directory outside both. */
function layout() {
  const root = tempDir("oppi-durable-resources-");
  const hostCwd = join(root, "workspace");
  const agentDir = join(root, "agent");
  const outside = join(root, "outside");
  mkdirSync(hostCwd, { recursive: true });
  mkdirSync(agentDir, { recursive: true });
  mkdirSync(outside, { recursive: true });
  return { root, hostCwd, agentDir, outside };
}

/** A VM that serves nothing: every guest read is refused. */
function refusingEnv(): GondolinExecutionEnv {
  const refuse = async (): Promise<never> => {
    throw new Error("ENOENT");
  };
  const vm: GondolinVm = {
    fs: { access: refuse, mkdir: refuse, readFile: refuse, writeFile: refuse },
    exec: () => {
      throw new Error("no guest exec in this test");
    },
  };
  return new GondolinExecutionEnv(vm, "w1", GUEST);
}

describe("durable project resources", () => {
  it("host sessions discover the agent directory's and the project's Skills", async () => {
    const { hostCwd, agentDir } = layout();
    writeSkill(join(agentDir, "skills", "global-skill"), "global-skill");
    writeSkill(join(hostCwd, ".pi", "skills", "project-skill"), "project-skill");

    const host = await loadDurableProjectResources({ hostCwd, agentDir, projectTrusted: true });
    expect(host.skills.map((skill) => skill.name).sort()).toEqual([
      "global-skill",
      "project-skill",
    ]);
  });

  it("a sandbox presents saved AGENTS files only inside the workspace, at guest paths, redacted", async () => {
    const { hostCwd, agentDir, outside } = layout();
    symlinkSync(outside, join(hostCwd, "linked"));
    // A host file the VM refuses is never read from the host instead.
    writeFileSync(join(hostCwd, "AGENTS.md"), "HOST_AGENTS_TEXT");
    const content = `Build in ${hostCwd}/src; notes in ${homedir()}/notes.`;

    const resources = await loadDurableProjectResources({
      hostCwd,
      agentDir,
      sandbox: refusingEnv(),
      projectTrusted: true,
      resources: {
        agentsFiles: [
          { path: "docs/AGENTS.md", content },
          { path: "linked/AGENTS.md", content: "ESCAPED" },
        ],
      },
    });

    expect(resources.contextFiles).toEqual([
      {
        path: `${GUEST}/docs/AGENTS.md`,
        content: `Build in ${GUEST}/src; notes in /workspace/.host-home/notes.`,
      },
    ]);
  });
});

import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  expandSkillCommand,
  loadDurableProjectResources,
} from "../src/durable-project-resources.js";

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

describe("durable sandbox project resources", () => {
  it("refuses saved Agent Skills outside the sandbox workspace before any mount", async () => {
    const { hostCwd, agentDir, outside } = layout();
    const outsideSkill = writeSkill(join(outside, "secret-skill"), "secret-skill");
    writeSkill(join(hostCwd, "skills", "local-skill"), "local-skill");
    // Inside the workspace by name, outside by its real path.
    symlinkSync(outsideSkill, join(hostCwd, "skills", "linked-skill"));
    const load = (skillPaths: string[]) =>
      loadDurableProjectResources({
        hostCwd,
        agentDir,
        sandboxGuestCwd: GUEST,
        projectTrusted: true,
        resources: { skillPaths },
      });

    for (const [skillPaths, named] of [
      [[outsideSkill], outsideSkill],
      [["../outside/secret-skill"], join(hostCwd, "../outside/secret-skill")],
      [["skills/linked-skill"], join(hostCwd, "skills/linked-skill")],
      // A selected directory inside the workspace whose Skill links outside.
      [["skills"], "secret-skill"],
    ] as const) {
      await expect(load([...skillPaths]), skillPaths.join()).rejects.toMatchObject({
        code: "agent_skills_unavailable",
        details: { unavailableSkills: [named] },
      });
    }

    const allowed = await load(["skills/local-skill"]);
    expect(allowed.skills.map((skill) => skill.name)).toEqual(["local-skill"]);
    expect(allowed.readonlyMounts).toEqual([
      {
        hostPath: expect.stringContaining(join("workspace", "skills", "local-skill")),
        guestPath: `${GUEST}/.pi/skills/local-skill`,
      },
    ]);
  });

  it("drops discovered Skills outside the sandbox workspace and keeps the workspace's", async () => {
    const { hostCwd, agentDir } = layout();
    writeSkill(join(agentDir, "skills", "global-skill"), "global-skill");
    writeSkill(join(hostCwd, ".pi", "skills", "project-skill"), "project-skill");

    const resources = await loadDurableProjectResources({
      hostCwd,
      agentDir,
      sandboxGuestCwd: GUEST,
      projectTrusted: true,
    });

    expect(resources.skills.map((skill) => skill.name)).toEqual(["project-skill"]);
    expect(resources.readonlyMounts.map((mount) => mount.guestPath)).toEqual([
      `${GUEST}/.pi/skills/project-skill`,
    ]);
    // `/skill:` reads through the session's view: a sandbox asks its VM for the guest path,
    // never the host file. The dropped Skill is not expanded at all.
    const reads: string[] = [];
    const vmRead = async (path: string) => {
      reads.push(path);
      return "project-skill body.";
    };
    expect(await expandSkillCommand("/skill:global-skill go", resources, vmRead)).toBe(
      "/skill:global-skill go",
    );
    expect(await expandSkillCommand("/skill:project-skill go", resources, vmRead)).toContain(
      "project-skill body.",
    );
    expect(reads).toEqual([`${GUEST}/.pi/skills/project-skill/SKILL.md`]);

    // A host session still discovers the agent directory's Skills.
    const host = await loadDurableProjectResources({ hostCwd, agentDir, projectTrusted: true });
    expect(host.skills.map((skill) => skill.name).sort()).toEqual([
      "global-skill",
      "project-skill",
    ]);
  });

  it("presents saved AGENTS files only inside the workspace, at guest paths, redacted", async () => {
    const { hostCwd, agentDir, outside } = layout();
    symlinkSync(outside, join(hostCwd, "linked"));
    const content = `Build in ${hostCwd}/src; notes in ${homedir()}/notes.`;

    const resources = await loadDurableProjectResources({
      hostCwd,
      agentDir,
      sandboxGuestCwd: GUEST,
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

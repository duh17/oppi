import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { ServerResourceService } from "../src/server-resource-service.js";
import { readSkillFileSnapshot } from "../src/skill-files.js";
import { OppiExtensionSettingsStore } from "../src/storage/oppi-extension-settings-store.js";

interface Fixture {
  root: string;
  homeDir: string;
  agentDir: string;
  dataDir: string;
}

const fixtures: Fixture[] = [];
const originalHome = process.env.HOME;
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalOffline = process.env.PI_OFFLINE;

function makeFixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), "oppi-server-resources-"));
  const fixture = {
    root,
    homeDir: join(root, "home"),
    agentDir: join(root, "home", ".pi", "agent"),
    dataDir: join(root, "oppi-data"),
  };
  mkdirSync(fixture.agentDir, { recursive: true });
  mkdirSync(fixture.dataDir, { recursive: true });
  process.env.HOME = fixture.homeDir;
  process.env.PI_CODING_AGENT_DIR = fixture.agentDir;
  process.env.PI_OFFLINE = "1";
  fixtures.push(fixture);
  return fixture;
}

function writeSkill(baseDir: string, name: string, description = `${name} description`): string {
  const skillDir = join(baseDir, name);
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(
    join(skillDir, "SKILL.md"),
    ["---", `name: ${name}`, `description: ${description}`, "---", `# ${name}`].join("\n"),
  );
  return skillDir;
}

function makeService(fixture: Fixture): ServerResourceService {
  return new ServerResourceService({
    dataDir: fixture.dataDir,
    agentDir: fixture.agentDir,
    oppiSettings: new OppiExtensionSettingsStore(fixture.dataDir),
  });
}

afterEach(() => {
  if (originalHome === undefined) delete process.env.HOME;
  else process.env.HOME = originalHome;
  if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
  if (originalOffline === undefined) delete process.env.PI_OFFLINE;
  else process.env.PI_OFFLINE = originalOffline;

  for (const fixture of fixtures.splice(0)) {
    rmSync(fixture.root, { recursive: true, force: true });
  }
});

describe("contained Skill file race safety", () => {
  it("does not follow a target symlink substituted between resolution and open", () => {
    const fixture = makeFixture();
    const skillDir = writeSkill(join(fixture.agentDir, "skills"), "read-race");
    const notesPath = join(skillDir, "notes.md");
    const outside = join(fixture.root, "outside-secret.md");
    writeFileSync(notesPath, "safe\n");
    writeFileSync(outside, "secret\n");

    expect(() =>
      readSkillFileSnapshot(skillDir, "notes.md", {
        beforeOpen: () => {
          rmSync(notesPath);
          symlinkSync(outside, notesPath);
        },
      }),
    ).toThrow(/not found/i);
    expect(readFileSync(outside, "utf8")).toBe("secret\n");
  });

  it("rejects an intermediate parent symlink substituted before descriptor open", () => {
    const fixture = makeFixture();
    const skillDir = writeSkill(join(fixture.agentDir, "skills"), "parent-race");
    const refsDir = join(skillDir, "refs");
    const outsideDir = join(fixture.root, "outside-refs");
    mkdirSync(refsDir);
    mkdirSync(outsideDir);
    writeFileSync(join(refsDir, "note.md"), "safe\n");
    writeFileSync(join(outsideDir, "note.md"), "secret\n");

    expect(() =>
      readSkillFileSnapshot(skillDir, "refs/note.md", {
        beforeOpen: () => {
          rmSync(refsDir, { recursive: true });
          symlinkSync(outsideDir, refsDir);
        },
      }),
    ).toThrow(/not found/i);
  });
});

describe("ServerResourceService catalogs", () => {
  it("projects only user-scope Pi candidates, preserves disabled rows, and keeps Oppi first", async () => {
    const fixture = makeFixture();
    writeSkill(join(fixture.agentDir, "skills"), "global-skill", "Global skill");
    writeSkill(
      join(fixture.dataDir, "resource-catalog-cwd", ".pi", "skills"),
      "project-leak",
      "Must not leak",
    );
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(fixture.agentDir, "extensions", "enabled.js"),
      "export default function (pi) { pi.registerCommand('enabled-command', { handler: async () => {} }); pi.registerTool({ name: 'enabled_tool', label: 'Enabled', description: 'Inspect enabled resources', parameters: { type: 'object', properties: {} }, execute: async () => ({ content: [{ type: 'text', text: 'ok' }] }) }); }\n",
    );
    writeFileSync(
      join(fixture.agentDir, "extensions", "disabled.js"),
      `import { writeFileSync } from "node:fs";\nwriteFileSync(${JSON.stringify(join(fixture.root, "disabled-executed"))}, "bad");\nthrow new Error("disabled extension executed");\n`,
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({
        skills: ["-skills/global-skill/SKILL.md"],
        extensions: ["-extensions/disabled.js"],
      }),
    );

    const service = makeService(fixture);
    const [skillsResult, extensionsResult] = await Promise.all([
      service.listSkills(),
      service.listExtensions(),
    ]);

    expect(skillsResult.skills.map((skill) => skill.name)).toContain("global-skill");
    expect(skillsResult.skills.find((skill) => skill.name === "global-skill")?.state).toBe(
      "disabled",
    );
    expect(skillsResult.skills.map((skill) => skill.name)).not.toContain("project-leak");
    expect(skillsResult.skills[0]?.id).toMatch(/^skill_[a-f0-9]{64}$/);

    expect(extensionsResult.extensions[0]).toEqual(
      expect.objectContaining({
        id: "oppi",
        name: "Oppi",
        kind: "builtIn",
        state: "off",
        isRemovable: false,
      }),
    );
    expect(extensionsResult.extensions[0]).not.toHaveProperty("path");
    expect(extensionsResult.oppiConfiguration).toEqual({
      enabled: false,
      approvalPolicy: "confirmDestructiveOnly",
      mobileOutputGuideEnabled: false,
      revision: 0,
    });
    expect(
      extensionsResult.extensions.find((extension) => extension.name === "disabled")?.state,
    ).toBe("off");
    expect(existsSync(join(fixture.root, "disabled-executed"))).toBe(false);
    const enabled = extensionsResult.extensions.find((extension) => extension.name === "enabled");
    expect(enabled?.contributedCommands).toEqual(["enabled-command"]);
    expect(enabled?.contributedTools).toEqual(["enabled_tool"]);
    expect(enabled?.contributedToolDetails).toEqual([
      { name: "enabled_tool", description: "Inspect enabled resources" },
    ]);
    expect(extensionsResult.builtInTools.map((tool) => tool.name)).toEqual([
      "read",
      "bash",
      "edit",
      "write",
      "grep",
      "find",
      "ls",
    ]);
  });

  it("inspects tools from one explicitly selected disabled extension without enabling it", async () => {
    const fixture = makeFixture();
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(fixture.agentDir, "extensions", "selected-off.js"),
      "export default function (pi) { pi.registerTool({ name: 'off_tool', label: 'Off Tool', description: 'Runs only for this Agent', parameters: { type: 'object', properties: {} }, execute: async () => ({ content: [{ type: 'text', text: 'ok' }] }) }); }\n",
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ extensions: ["-extensions/selected-off.js"] }),
    );

    const service = makeService(fixture);
    const listed = await service.listExtensions();
    const selected = listed.extensions.find((extension) => extension.name === "selected-off");
    expect(selected?.state).toBe("off");
    expect(selected?.contributedTools).toBeUndefined();

    const ordinaryDetail = await service.getExtensionDetail(selected!.id);
    expect(ordinaryDetail.summary.state).toBe("off");
    expect(ordinaryDetail.contributedToolDetails).toBeUndefined();

    const detail = await service.inspectAgentExtensionTools(selected!.id);
    expect(detail.summary.state).toBe("off");
    expect(detail.contributedToolDetails).toEqual([
      { name: "off_tool", description: "Runs only for this Agent" },
    ]);

    const listedAgain = await service.listExtensions();
    expect(listedAgain.extensions.find((extension) => extension.id === selected!.id)?.state).toBe(
      "off",
    );
  });

  it("uses semantic Pi provenance and configured package source", async () => {
    const fixture = makeFixture();
    const packageDir = join(fixture.root, "resource-package");
    writeSkill(join(packageDir, "skills"), "package-skill", "Packaged skill");
    mkdirSync(join(packageDir, "extensions"), { recursive: true });
    writeFileSync(
      join(packageDir, "extensions", "package-extension.js"),
      "export default function (pi) { pi.registerCommand('package-command', { handler: async () => {} }); }\n",
    );
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "truthful-resource-package",
        version: "1.0.0",
        pi: {
          skills: ["skills/package-skill/SKILL.md"],
          extensions: ["extensions/package-extension.js"],
        },
      }),
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: [packageDir] }),
    );

    const service = makeService(fixture);
    const [skillsResult, extensionsResult] = await Promise.all([
      service.listSkills(),
      service.listExtensions(),
    ]);
    const skill = skillsResult.skills.find((item) => item.name === "package-skill");
    const extension = extensionsResult.extensions.find((item) => item.name === "package-extension");

    expect(skill?.provenance).toEqual({ kind: "package", label: packageDir });
    expect(extension?.provenance).toEqual({ kind: "package", label: packageDir });
    expect(extension?.kind).toBe("package");
    expect(extension?.contributedCommands).toEqual(["package-command"]);
  });

  it("bounds skill warnings and extension load errors without executing disabled extensions", async () => {
    const fixture = makeFixture();
    const malformedDir = join(fixture.agentDir, "skills", "malformed");
    mkdirSync(malformedDir, { recursive: true });
    writeFileSync(
      join(malformedDir, "SKILL.md"),
      "---\nname: malformed\n---\nmissing description\n",
    );
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(fixture.agentDir, "extensions", "bad.js"),
      `throw new Error(${JSON.stringify(`bad\u0000${"x".repeat(10_000)}`)});\n`,
    );

    const service = makeService(fixture);
    const [skillsResult, extensionsResult] = await Promise.all([
      service.listSkills(),
      service.listExtensions(),
    ]);
    const malformed = skillsResult.skills.find((skill) => skill.name === "malformed");
    const bad = extensionsResult.extensions.find((extension) => extension.name === "bad");

    expect(malformed?.state).toBe("error");
    expect(malformed?.loadError).toContain("description is required");
    expect(bad?.state).toBe("error");
    expect(bad?.loadError?.length).toBeLessThanOrEqual(2048);
    expect(bad?.loadError).not.toContain("\u0000");
    expect(bad?.warnings.length).toBeLessThanOrEqual(8);
  });

  it("skips missing configured packages and never installs them during listing", async () => {
    const fixture = makeFixture();
    const missingPackage = join(fixture.root, "missing-package");
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: [missingPackage] }),
    );

    const service = makeService(fixture);
    await service.listExtensions();
    await service.listSkills();

    expect(existsSync(missingPackage)).toBe(false);
  });

  it("surfaces malformed Oppi settings as a bounded built-in load error", async () => {
    const fixture = makeFixture();
    mkdirSync(join(fixture.dataDir, "extensions"), { recursive: true });
    writeFileSync(join(fixture.dataDir, "extensions", "oppi.json"), "{" + "x".repeat(10_000));

    const result = await makeService(fixture).listExtensions();
    const oppi = result.extensions[0];

    expect(oppi?.state).toBe("error");
    expect(oppi?.loadError?.length).toBeLessThanOrEqual(2048);
    expect(result.oppiConfiguration.enabled).toBe(false);
  });
});

describe("ServerResourceService mutations and skill details", () => {
  it("serializes fresh same-array mutations and returns authoritative summaries", async () => {
    const fixture = makeFixture();
    writeSkill(join(fixture.agentDir, "skills"), "alpha");
    writeSkill(join(fixture.agentDir, "skills"), "beta");
    const service = makeService(fixture);
    const initial = await service.listSkills();
    const alpha = initial.skills.find((skill) => skill.name === "alpha");
    const beta = initial.skills.find((skill) => skill.name === "beta");
    expect(alpha).toBeDefined();
    expect(beta).toBeDefined();

    const [updatedAlpha, updatedBeta] = await Promise.all([
      service.setSkillEnabled(alpha!.id, false),
      service.setSkillEnabled(beta!.id, false),
    ]);

    expect(updatedAlpha.state).toBe("disabled");
    expect(updatedBeta.state).toBe("disabled");
    const settings = JSON.parse(readFileSync(join(fixture.agentDir, "settings.json"), "utf8")) as {
      skills?: string[];
    };
    expect(settings.skills?.filter((entry) => entry.startsWith("-")).sort()).toEqual([
      "-skills/alpha/SKILL.md",
      "-skills/beta/SKILL.md",
    ]);
  });

  it("preserves package filters while toggling one package resource", async () => {
    const fixture = makeFixture();
    const packageDir = join(fixture.root, "filter-package");
    const extensionDir = join(packageDir, "extensions");
    mkdirSync(extensionDir, { recursive: true });
    writeFileSync(join(extensionDir, "one.js"), "export default function () {}\n");
    writeFileSync(join(extensionDir, "two.js"), "export default function () {}\n");
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "filter-package",
        version: "1.0.0",
        pi: { extensions: ["extensions/*.js"] },
      }),
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({
        packages: [{ source: packageDir, extensions: ["-extensions/two.js"], skills: [] }],
      }),
    );

    const service = makeService(fixture);
    const initial = await service.listExtensions();
    const one = initial.extensions.find((extension) => extension.name === "one");
    const two = initial.extensions.find((extension) => extension.name === "two");
    expect(one).toBeDefined();
    expect(two?.state).toBe("off");

    const updated = await service.setExtensionEnabled(one!.id, false);

    expect(updated.state).toBe("off");
    const settings = JSON.parse(readFileSync(join(fixture.agentDir, "settings.json"), "utf8")) as {
      packages: Array<{ extensions?: string[]; skills?: string[] }>;
    };
    expect(settings.packages[0]?.extensions).toEqual(["-extensions/two.js", "-extensions/one.js"]);
    expect(settings.packages[0]?.skills).toEqual([]);
  });

  it("reads skill detail through a symlinked user skill directory", async () => {
    const fixture = makeFixture();
    const externalSkills = join(fixture.root, "external-skills");
    const skillDir = writeSkill(externalSkills, "linked-skill");
    writeFileSync(join(skillDir, "reference.md"), "# Reference");
    const agentSkills = join(fixture.agentDir, "skills");
    mkdirSync(agentSkills, { recursive: true });
    symlinkSync(skillDir, join(agentSkills, "linked-skill"));

    const service = makeService(fixture);
    const summary = (await service.listSkills()).skills.find(
      (skill) => skill.name === "linked-skill",
    );
    expect(summary).toBeDefined();

    const detail = await service.getSkillDetail(summary!.id);
    expect(detail.skillMarkdown).toContain("# linked-skill");
    expect(detail.files).toEqual(["reference.md", "SKILL.md"]);
    expect(await service.readSkillFile(summary!.id, "reference.md")).toBe("# Reference");
  });

  it("provides bounded symlink-safe skill detail and file reads", async () => {
    const fixture = makeFixture();
    const skillDir = writeSkill(join(fixture.agentDir, "skills"), "detail-skill");
    writeFileSync(join(skillDir, "notes.txt"), "safe notes");
    const secret = join(fixture.root, "secret.txt");
    writeFileSync(secret, "outside secret");
    symlinkSync(secret, join(skillDir, "secret-link.txt"));

    const service = makeService(fixture);
    const summary = (await service.listSkills()).skills.find(
      (skill) => skill.name === "detail-skill",
    );
    expect(summary).toBeDefined();

    const detail = await service.getSkillDetail(summary!.id);
    expect(detail.skillMarkdown).toContain("# detail-skill");
    expect(detail.files).toContain("notes.txt");
    expect(detail.files).not.toContain("secret-link.txt");
    expect(await service.readSkillFile(summary!.id, "notes.txt")).toBe("safe notes");
    await expect(service.readSkillFile(summary!.id, "secret-link.txt")).rejects.toThrow(
      /not found/i,
    );
    await expect(service.readSkillFile(summary!.id, "../secret.txt")).rejects.toThrow(/not found/i);
  });

  it("marks only top-level non-package Skills editable", async () => {
    const fixture = makeFixture();
    writeSkill(join(fixture.agentDir, "skills"), "editable-skill");

    const packageDir = join(fixture.root, "resource-package");
    writeSkill(join(packageDir, "skills"), "package-skill");
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "read-only-skill-package",
        version: "1.0.0",
        pi: { skills: ["skills/package-skill/SKILL.md"] },
      }),
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: [packageDir] }),
    );

    const skills = (await makeService(fixture).listSkills()).skills;
    expect(skills.find((skill) => skill.name === "editable-skill")?.editable).toBe(true);
    expect(skills.find((skill) => skill.name === "package-skill")?.editable).toBe(false);
  });

  it("keeps package Skill metadata read-only when a top-level symlink aliases it", async () => {
    const fixture = makeFixture();
    const packageDir = join(fixture.root, "aliased-package");
    const packagedSkill = writeSkill(join(packageDir, "skills"), "package-skill");
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "aliased-package",
        version: "1.0.0",
        pi: { skills: ["skills/package-skill/SKILL.md"] },
      }),
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: [packageDir] }),
    );
    const agentSkills = join(fixture.agentDir, "skills");
    mkdirSync(agentSkills, { recursive: true });
    symlinkSync(packagedSkill, join(agentSkills, "package-alias"));

    const matching = (await makeService(fixture).listSkills()).skills.filter(
      (skill) => skill.name === "package-skill",
    );

    expect(matching).toHaveLength(1);
    expect(matching[0]).toMatchObject({ editable: false, provenance: { kind: "package" } });
  });

  it("deduplicates a package Extension when a top-level symlink aliases its canonical path", async () => {
    const fixture = makeFixture();
    const packageDir = join(fixture.root, "aliased-extension-package");
    const packagedExtension = join(packageDir, "extensions", "package-extension.js");
    mkdirSync(join(packageDir, "extensions"), { recursive: true });
    writeFileSync(packagedExtension, "export default function () {}\n");
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "aliased-extension-package",
        version: "1.0.0",
        pi: { extensions: ["extensions/package-extension.js"] },
      }),
    );
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: [packageDir] }),
    );
    const agentExtensions = join(fixture.agentDir, "extensions");
    mkdirSync(agentExtensions, { recursive: true });
    symlinkSync(packagedExtension, join(agentExtensions, "extension-alias.js"));

    const listed = (await makeService(fixture).listExtensions()).extensions.filter(
      (extension) => extension.id !== "oppi",
    );

    expect(listed).toHaveLength(1);
    expect(listed[0]?.id).toMatch(/^extension_[a-f0-9]{64}$/);
  });

  it("uses kind plus canonical path for opaque IDs", async () => {
    const fixture = makeFixture();
    const sharedName = "same-name";
    writeSkill(join(fixture.agentDir, "skills"), sharedName);
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(fixture.agentDir, "extensions", `${sharedName}.js`),
      "export default function () {}\n",
    );

    const service = makeService(fixture);
    const skill = (await service.listSkills()).skills.find((item) => item.name === sharedName);
    const extension = (await service.listExtensions()).extensions.find(
      (item) => item.name === sharedName,
    );

    expect(skill?.id).toMatch(/^skill_[a-f0-9]{64}$/);
    expect(extension?.id).toMatch(/^extension_[a-f0-9]{64}$/);
    expect(skill?.id.slice("skill_".length)).not.toBe(extension?.id.slice("extension_".length));
    expect(basename(skill?.path ?? "")).toMatch(/same-name|SKILL\.md/);
  });
});

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { ServerResourceService } from "../src/server-resource-service.js";
import { canonicalServerResourcePath } from "../src/server-resource-id.js";
import { readSkillFileSnapshot } from "../src/skill-files.js";

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
  it("lists every path a Skill is linked in under, beside its canonical path", async () => {
    const fixture = makeFixture();
    const realDir = writeSkill(join(fixture.root, "real-skills"), "linked-skill");
    mkdirSync(join(fixture.agentDir, "skills"), { recursive: true });
    const linkedDir = join(fixture.agentDir, "skills", "linked-skill");
    symlinkSync(realDir, linkedDir);

    const { skills } = await makeService(fixture).listSkills();
    const skill = skills.find((entry) => entry.name === "linked-skill");

    // The canonical path identifies the Skill; the link's path names the same one, which is
    // the form an Agent selection made through that library stores.
    expect(skill?.path).toBe(canonicalServerResourcePath(join(realDir, "SKILL.md")));
    expect(skill?.paths).toEqual([
      canonicalServerResourcePath(join(realDir, "SKILL.md")),
      join(linkedDir, "SKILL.md"),
    ]);
    expect(skill?.selectionPath).toBe(join(linkedDir, "SKILL.md"));
  });

  it("deduplicates a Skill linked in two places with canonical path first and prefers the first discovered link", async () => {
    const fixture = makeFixture();
    const realRoot = realpathSync(fixture.root);
    const homeDir = join(realRoot, "home");
    const agentDir = join(homeDir, ".pi", "agent");
    process.env.HOME = homeDir;
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const directDir = writeSkill(join(agentDir, "skills"), "direct-skill");
    const realDir = writeSkill(join(realRoot, "real-skills"), "shared-skill");
    const agentLinkDir = join(agentDir, "skills", "shared-skill");
    const agentsLinkDir = join(homeDir, ".agents", "skills", "shared-skill");
    mkdirSync(join(homeDir, ".agents", "skills"), { recursive: true });
    // Pi's package manager deduplicates by realpath and keeps only the higher-precedence
    // ~/.pi/agent/skills link; the alias walk then scans both user roots, deduplicates the
    // already-seen ~/.pi/agent/skills link, and appends the ~/.agents/skills link.
    symlinkSync(realDir, agentLinkDir);
    symlinkSync(realDir, agentsLinkDir);

    const service = new ServerResourceService({ dataDir: fixture.dataDir, agentDir });
    const { skills } = await service.listSkills();

    const matching = skills.filter((entry) => entry.name === "shared-skill");
    expect(matching).toHaveLength(1);
    const shared = matching[0]!;
    const canonical = canonicalServerResourcePath(join(realDir, "SKILL.md"));
    const agentLinkPath = join(agentLinkDir, "SKILL.md");
    const agentsLinkPath = join(agentsLinkDir, "SKILL.md");
    expect(shared.path).toBe(canonical);
    expect(shared.paths).toEqual([canonical, agentLinkPath, agentsLinkPath]);
    expect(shared.selectionPath).toBe(agentLinkPath);

    const direct = skills.find((entry) => entry.name === "direct-skill");
    const directPath = join(directDir, "SKILL.md");
    expect(direct?.path).toBe(directPath);
    expect(direct?.paths).toEqual([directPath]);
    expect(direct?.selectionPath).toBe(directPath);
  });

  it("bounds the user Skill alias walk across diamonds, deep trees, and large non-skill folders", async () => {
    const fixture = makeFixture();
    const realRoot = realpathSync(fixture.root);
    const homeDir = join(realRoot, "home");
    const agentDir = join(homeDir, ".pi", "agent");
    process.env.HOME = homeDir;
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const realDir = writeSkill(join(realRoot, "real-skills"), "bounded-skill");
    mkdirSync(join(agentDir, "skills"), { recursive: true });
    const agentLinkDir = join(agentDir, "skills", "bounded-skill");
    symlinkSync(realDir, agentLinkDir);

    const agentsSkillsDir = join(homeDir, ".agents", "skills");
    mkdirSync(agentsSkillsDir, { recursive: true });

    // A 6-level 3-way symlink diamond (3^6 = 729 paths > 500-dir budget, only 7 real dirs).
    // Whole-walk visited-realpath tracking visits each real dir once so `z-after-diamond` is
    // still discovered instead of exhausting the directory budget.
    const diamondLevels = Array.from({ length: 7 }, (_, i) => join(realRoot, `diamond-${i}`));
    for (const dir of diamondLevels) mkdirSync(dir, { recursive: true });
    for (let i = 0; i < diamondLevels.length - 1; i += 1) {
      for (const branch of ["a", "b", "c"]) {
        symlinkSync(diamondLevels[i + 1]!, join(diamondLevels[i]!, branch));
      }
    }
    symlinkSync(diamondLevels[0]!, join(agentsSkillsDir, "a-diamond"));
    const afterDiamondDir = join(agentsSkillsDir, "z-after-diamond");
    symlinkSync(realDir, afterDiamondDir);

    // A link nested past the depth cap (depth 11 > 8) is skipped.
    let deepParent = join(agentsSkillsDir, "deep");
    for (let i = 0; i < 9; i += 1) deepParent = join(deepParent, `d${i}`);
    mkdirSync(deepParent, { recursive: true });
    symlinkSync(realDir, join(deepParent, "too-deep"));

    const service = new ServerResourceService({ dataDir: fixture.dataDir, agentDir });
    const firstPass = (await service.listSkills()).skills.find(
      (entry) => entry.name === "bounded-skill",
    );
    const canonical = canonicalServerResourcePath(join(realDir, "SKILL.md"));
    expect(firstPass?.paths).toEqual([
      canonical,
      join(agentLinkDir, "SKILL.md"),
      join(afterDiamondDir, "SKILL.md"),
    ]);

    // Over 500 non-skill sibling directories exhaust the total directory budget before a
    // trailing link (`zz-past-budget`), capping the synchronous walk.
    for (let i = 0; i < 510; i += 1) {
      mkdirSync(join(agentsSkillsDir, `pad-${String(i).padStart(3, "0")}`));
    }
    const pastBudgetDir = join(agentsSkillsDir, "zz-past-budget");
    symlinkSync(realDir, pastBudgetDir);

    const secondPass = (await service.listSkills()).skills.find(
      (entry) => entry.name === "bounded-skill",
    );
    expect(secondPass?.paths).not.toContain(join(pastBudgetDir, "SKILL.md"));
    expect(secondPass?.paths).toContain(join(agentLinkDir, "SKILL.md"));
  });

  it("projects only user-scope Pi candidates and preserves disabled rows without a synthetic Oppi extension", async () => {
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

    expect(extensionsResult.extensions.some((extension) => extension.id === "oppi")).toBe(false);
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

  it("gives a classic extension's tool definitions in its detail", async () => {
    const fixture = makeFixture();
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(fixture.agentDir, "extensions", "classic.js"),
      `export default function (pi) { pi.registerTool({ ...${JSON.stringify({
        name: "classic_tool",
        label: "Classic",
        description: "Counts things.\nOne line per thing.",
        // As Pi sends them: the snippet on one line, the guidelines trimmed, without
        // blanks or repeats.
        promptSnippet: "  Count things\n  with classic_tool ",
        promptGuidelines: [
          " Prefer classic_tool for counting. ",
          "",
          "Prefer classic_tool for counting.",
        ],
        parameters: {
          type: "object",
          properties: { n: { type: "number", description: "How many" } },
        },
      })}, execute: async () => ({ content: [] }) }); }\n`,
    );

    const service = makeService(fixture);
    const listed = await service.listExtensions();
    const classic = listed.extensions.find((extension) => extension.name === "classic")!;
    // The list stays slim: definitions are the detail's.
    expect(classic).not.toHaveProperty("toolDefinitions");

    const detail = await service.getExtensionDetail(classic.id);
    expect(detail.toolDefinitions).toEqual([
      {
        name: "classic_tool",
        description: "Counts things.\nOne line per thing.",
        parameters: {
          type: "object",
          properties: { n: { type: "number", description: "How many" } },
        },
        promptSnippet: "Count things with classic_tool",
        promptGuidelines: ["Prefer classic_tool for counting."],
        from: "pi-extension",
      },
    ]);
    // No plugin: no prompt sections to show.
    expect(detail.promptSections).toBeUndefined();
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
});

describe("ServerResourceService optional Pi tools", () => {
  it("discovers tools registered off, honors -builtin settings, and validates defaultTools against them", async () => {
    const fixture = makeFixture();
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(fixture.agentDir, "extensions", "opt-in.js"),
      "export default function (pi) { pi.registerTool({ name: 'opt_in_tool', label: 'Opt in', description: 'Off until enabled', defaultActive: false, parameters: { type: 'object', properties: {} }, execute: async () => ({ content: [{ type: 'text', text: 'ok' }] }) }); }\n",
    );
    const service = makeService(fixture);

    expect((await service.listExtensions()).optionalTools.map((tool) => tool.name)).toEqual([
      "codemode",
      "opt_in_tool",
      "tool_search",
    ]);
    expect(await service.setPiDefaultTools(["+codemode", "-bash", "+opt_in_tool"])).toEqual({
      defaultTools: ["+codemode", "-bash", "+opt_in_tool"],
    });

    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ extensions: ["-builtin:codemode"], defaultTools: ["read"] }),
    );
    expect((await service.listExtensions()).optionalTools.map((tool) => tool.name)).toEqual([
      "opt_in_tool",
      "tool_search",
    ]);
    await expect(service.setPiDefaultTools(["read", "codemode"])).rejects.toThrow(/built-in/i);
    expect(JSON.parse(readFileSync(join(fixture.agentDir, "settings.json"), "utf8"))).toEqual({
      extensions: ["-builtin:codemode"],
      defaultTools: ["read"],
    });
  });
});

describe("ServerResourceService mutations and skill details", () => {
  it("persists the Pi default provider and model without replacing other settings", async () => {
    const fixture = makeFixture();
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ defaultTools: ["read"] }),
    );
    const saved = await makeService(fixture).setPiDefaultModel("xai", "grok-4.6");
    expect(saved).toEqual({ model: "xai/grok-4.6" });
    expect(JSON.parse(readFileSync(join(fixture.agentDir, "settings.json"), "utf8"))).toMatchObject(
      {
        defaultProvider: "xai",
        defaultModel: "grok-4.6",
        defaultTools: ["read"],
      },
    );
  });

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

  it("offers Oppi's Auto-Name off without writing Pi's settings, and lists it there only while it is on", async () => {
    const fixture = makeFixture();
    const settingsPath = join(fixture.agentDir, "settings.json");
    writeFileSync(settingsPath, JSON.stringify({ packages: ["npm:other"] }));
    const service = makeService(fixture);
    const readPackages = (): unknown =>
      (JSON.parse(readFileSync(settingsPath, "utf8")) as { packages?: unknown }).packages;

    const offered = (await service.listExtensions()).extensions.find(
      (row) => row.name === "auto-name",
    );
    expect(offered).toMatchObject({ state: "off", kinds: ["plugin", "pi-extension"] });
    expect(readPackages()).toEqual(["npm:other"]);

    expect(await service.setExtensionEnabled(offered!.id, true)).toMatchObject({ state: "on" });
    const autoName = join(import.meta.dirname, "../plugins/auto-name");
    expect(readPackages()).toEqual(["npm:other", { source: autoName, extensions: ["+index.ts"] }]);

    expect(await service.setExtensionEnabled(offered!.id, false)).toMatchObject({ state: "off" });
    expect(readPackages()).toEqual(["npm:other"]);
  });

  it("offers nothing beside the user's own linked copy of Auto-Name", async () => {
    const fixture = makeFixture();
    mkdirSync(join(fixture.agentDir, "extensions"), { recursive: true });
    symlinkSync(
      join(import.meta.dirname, "../plugins/auto-name"),
      join(fixture.agentDir, "extensions", "auto-name"),
    );

    const rows = (await makeService(fixture).listExtensions()).extensions.filter(
      (row) => row.name === "auto-name",
    );

    expect(rows).toHaveLength(1);
    expect(rows[0]?.provenance).not.toMatchObject({ kind: "package" });
  });

  it("says whether the package behind an extension holds a plugin", async () => {
    const fixture = makeFixture();
    const packages = ["classic-only", "with-plugin", "listed-plugin", "broken-list"].map((name) => {
      const dir = join(fixture.root, name);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "index.ts"), "export default function () {}\n");
      if (name === "with-plugin") writeFileSync(join(dir, "server.ts"), "export default {};\n");
      if (name === "listed-plugin" || name === "broken-list") {
        // A plugin in a folder its manifest lists.
        mkdirSync(join(dir, "server"));
        writeFileSync(
          join(dir, "server", "package.json"),
          JSON.stringify({ name: `${name}-facet` }),
        );
        writeFileSync(join(dir, "server", "server.ts"), "export default {};\n");
      }
      const chord =
        name === "listed-plugin"
          ? { plugins: ["./server"] }
          : name === "broken-list"
            ? { plugins: "./server" } // not a list: an invalid manifest
            : undefined;
      writeFileSync(
        join(dir, "package.json"),
        JSON.stringify({ name, version: "1.0.0", pi: { extensions: ["./index.ts"] }, chord }),
      );
      return dir;
    });
    writeFileSync(
      join(fixture.agentDir, "settings.json"),
      JSON.stringify({ packages: packages.map((source) => ({ source })) }),
    );

    const service = makeService(fixture);
    const listed = (await service.listExtensions()).extensions;
    const hasPlugin = async (name: string): Promise<boolean> =>
      service.hasPlugin(listed.find((extension) => extension.name === name)!.id);

    expect(await hasPlugin("classic-only")).toBe(false);
    expect(await hasPlugin("with-plugin")).toBe(true);
    expect(await hasPlugin("listed-plugin")).toBe(true);
    expect(await hasPlugin("broken-list")).toBe(false);

    // No plugin of theirs is loaded here (no plugin host), so a row with a plugin on disk has
    // both kinds and no plugin block: a package keeps its Plugin kind while it is switched off.
    const kinds = (name: string) => listed.find((extension) => extension.name === name)!;
    expect(kinds("classic-only")).toMatchObject({ kinds: ["pi-extension"] });
    expect(kinds("with-plugin")).toMatchObject({ kinds: ["plugin", "pi-extension"] });
    expect(kinds("listed-plugin")).toMatchObject({ kinds: ["plugin", "pi-extension"] });
    expect(kinds("with-plugin").plugin).toBeUndefined();
    const withPlugin = kinds("with-plugin");
    const off = await service.setExtensionEnabled(withPlugin.id, false);
    expect(off).toMatchObject({ state: "off", kinds: ["plugin", "pi-extension"] });
  });

  it("lists classic rows when the plugins cannot be listed, and says so on rows with a plugin", async () => {
    const fixture = makeFixture();
    for (const name of ["classic-only", "with-plugin"]) {
      const dir = join(fixture.agentDir, "extensions", name);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "index.ts"), "export default function () {}\n");
      writeFileSync(
        join(dir, "package.json"),
        JSON.stringify({ name, pi: { extensions: ["./index.ts"] } }),
      );
      if (name === "with-plugin") writeFileSync(join(dir, "server.ts"), "export default {};\n");
    }
    // The durable runtime did not open: a required built-in failed.
    const service = new ServerResourceService({
      dataDir: fixture.dataDir,
      agentDir: fixture.agentDir,
      plugins: {
        listPlugins: async () => {
          throw new Error("Oppi's built-in plugins failed to load: ask (server.ts): boom");
        },
        setPluginEnabled: async () => undefined,
      },
    });

    const catalog = await service.listExtensions({ plugins: true });
    // A client that asked for plugins learns why there are none.
    expect(catalog.pluginsUnavailable).toContain("Oppi's built-in plugins failed to load");
    expect((await service.listExtensions()).pluginsUnavailable).toBeUndefined();
    // Oppi's own Auto-Name is offered beside them (see its own test).
    const listed = catalog.extensions.filter((row) => row.name !== "auto-name");
    expect(listed.map((row) => row.name)).toEqual(["classic-only", "with-plugin"]);
    const withPlugin = listed.find((row) => row.name === "with-plugin")!;
    expect(withPlugin).toMatchObject({ state: "on", kinds: ["plugin", "pi-extension"] });
    expect(withPlugin.warnings).toEqual([
      expect.stringContaining("Plugins could not be loaded: Oppi's built-in plugins failed"),
    ]);
    expect(listed.find((row) => row.name === "classic-only")!.warnings).toEqual([]);
    // Detail and a toggle work the same way.
    expect((await service.getExtensionDetail(withPlugin.id)).summary.warnings).toEqual(
      withPlugin.warnings,
    );
    expect(await service.setExtensionEnabled(withPlugin.id, false)).toMatchObject({
      state: "off",
      warnings: withPlugin.warnings,
    });
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
      (row) => row.name !== "auto-name",
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

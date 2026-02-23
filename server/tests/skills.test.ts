import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  UserSkillStore,
  SkillValidationError,
  SkillRegistry,
  extractFrontmatterField,
  type SkillsChangedEvent,
} from "../src/skills.js";

// ─── Helpers ───

const VALID_SKILL_MD = `---
name: test-skill
description: A test skill for unit tests
---

# Test Skill

Does test things.
`;

const NO_DESC_SKILL_MD = `---
name: no-desc
---

No description here.
`;

function makeSkillDir(baseDir: string, name: string, content?: string): string {
  const dir = join(baseDir, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SKILL.md"), content ?? VALID_SKILL_MD);
  return dir;
}

// ─── Tests ───

describe("UserSkillStore", () => {
  let storeDir: string;
  let store: UserSkillStore;
  let workDir: string; // simulates session workspace

  beforeEach(() => {
    storeDir = mkdtempSync(join(tmpdir(), "pi-skills-store-"));
    workDir = mkdtempSync(join(tmpdir(), "pi-skills-work-"));
    store = new UserSkillStore(storeDir);
    store.init();
  });

  afterEach(() => {
    rmSync(storeDir, { recursive: true, force: true });
    rmSync(workDir, { recursive: true, force: true });
  });

  // ─── List ───

  describe("listSkills", () => {
    it("returns empty for new user", () => {
      expect(store.listSkills()).toEqual([]);
    });

    it("returns saved skills", () => {
      makeSkillDir(workDir, "my-skill");
      store.saveSkill("my-skill", join(workDir, "my-skill"));

      const skills = store.listSkills();
      expect(skills).toHaveLength(1);
      expect(skills[0].name).toBe("my-skill");
      expect(skills[0].description).toBe("A test skill for unit tests");
      expect(skills[0].builtIn).toBe(false);
    });

    it("skips directories without SKILL.md", () => {
      // Create a user dir with a random directory (no SKILL.md)
      mkdirSync(join(storeDir, "junk"), { recursive: true });
      writeFileSync(join(storeDir, "junk", "notes.txt"), "hello");

      expect(store.listSkills()).toEqual([]);
    });

    it("single owner sees own skills", () => {
      makeSkillDir(workDir, "skill-a");
      store.saveSkill("skill-a", join(workDir, "skill-a"));

      expect(store.listSkills()).toHaveLength(1);
    });
  });

  // ─── Get ───

  describe("getSkill", () => {
    it("returns null for missing skill", () => {
      expect(store.getSkill("nonexistent")).toBeNull();
    });

    it("returns skill with metadata", () => {
      makeSkillDir(workDir, "analyzer");
      store.saveSkill("analyzer", join(workDir, "analyzer"));

      const skill = store.getSkill("analyzer");
      expect(skill).not.toBeNull();
      expect(skill!.name).toBe("analyzer");
      expect(skill!.description).toBe("A test skill for unit tests");
      expect(skill!.sizeBytes).toBeGreaterThan(0);
    });
  });

  // ─── Save ───

  describe("saveSkill", () => {
    it("copies source directory to store", () => {
      const src = makeSkillDir(workDir, "copier");
      writeFileSync(join(src, "helper.py"), "print('hello')");

      store.saveSkill("copier", src);

      const destDir = join(storeDir, "copier");
      expect(existsSync(join(destDir, "SKILL.md"))).toBe(true);
      expect(existsSync(join(destDir, "helper.py"))).toBe(true);
    });

    it("overwrites existing skill", () => {
      const src = makeSkillDir(workDir, "evolving");
      writeFileSync(join(src, "v1.txt"), "version 1");
      store.saveSkill("evolving", src);

      // Update source
      writeFileSync(join(src, "SKILL.md"), VALID_SKILL_MD);
      writeFileSync(join(src, "v2.txt"), "version 2");
      rmSync(join(src, "v1.txt"));
      store.saveSkill("evolving", src);

      const destDir = join(storeDir, "evolving");
      expect(existsSync(join(destDir, "v2.txt"))).toBe(true);
      expect(existsSync(join(destDir, "v1.txt"))).toBe(false);
    });

    it("rejects invalid name", () => {
      const src = makeSkillDir(workDir, "Bad_Name");
      expect(() => store.saveSkill("Bad_Name", src))
        .toThrow("Invalid skill name");
    });

    it("rejects name starting with number", () => {
      const src = makeSkillDir(workDir, "1bad");
      expect(() => store.saveSkill("1bad", src))
        .toThrow("Invalid skill name");
    });

    it("rejects missing source dir", () => {
      expect(() => store.saveSkill("ghost", "/nonexistent/path"))
        .toThrow("Source directory not found");
    });

    it("rejects source without SKILL.md", () => {
      const src = join(workDir, "no-skill-md");
      mkdirSync(src, { recursive: true });
      writeFileSync(join(src, "readme.md"), "not a skill");

      expect(() => store.saveSkill("no-skill-md", src))
        .toThrow("SKILL.md not found");
    });

    it("rejects skill exceeding size limit", () => {
      const src = makeSkillDir(workDir, "chonky");
      // Write a 200KB file (limit is 100KB)
      writeFileSync(join(src, "big.bin"), Buffer.alloc(200 * 1024));

      expect(() => store.saveSkill("chonky", src))
        .toThrow("too large");
    });

    it("rejects skill exceeding file count", () => {
      const src = makeSkillDir(workDir, "many-files");
      for (let i = 0; i < 55; i++) {
        writeFileSync(join(src, `file-${i}.txt`), `content ${i}`);
      }

      expect(() => store.saveSkill("many-files", src))
        .toThrow("Too many files");
    });

    it("rejects SKILL.md without description", () => {
      const src = join(workDir, "no-desc");
      mkdirSync(src, { recursive: true });
      writeFileSync(join(src, "SKILL.md"), NO_DESC_SKILL_MD);

      expect(() => store.saveSkill("no-desc", src))
        .toThrow("Failed to read saved skill");
    });
  });

  // ─── Delete ───

  describe("deleteSkill", () => {
    it("removes a saved skill", () => {
      makeSkillDir(workDir, "doomed");
      store.saveSkill("doomed", join(workDir, "doomed"));
      expect(store.getSkill("doomed")).not.toBeNull();

      const result = store.deleteSkill("doomed");
      expect(result).toBe(true);
      expect(store.getSkill("doomed")).toBeNull();
    });

    it("returns false for nonexistent skill", () => {
      expect(store.deleteSkill("nope")).toBe(false);
    });
  });

  // ─── File Access ───

  describe("listFiles", () => {
    it("returns relative file paths", () => {
      const src = makeSkillDir(workDir, "with-files");
      mkdirSync(join(src, "scripts"), { recursive: true });
      writeFileSync(join(src, "scripts", "run.sh"), "#!/bin/bash");
      store.saveSkill("with-files", src);

      const files = store.listFiles("with-files");
      expect(files).toContain("SKILL.md");
      expect(files).toContain("scripts/run.sh");
    });

    it("returns empty for missing skill", () => {
      expect(store.listFiles("nope")).toEqual([]);
    });
  });

  describe("readFile", () => {
    it("reads a file from a saved skill", () => {
      const src = makeSkillDir(workDir, "readable");
      writeFileSync(join(src, "data.txt"), "hello world");
      store.saveSkill("readable", src);

      const content = store.readFile("readable", "data.txt");
      expect(content).toBe("hello world");
    });

    it("returns SKILL.md content", () => {
      makeSkillDir(workDir, "readable");
      store.saveSkill("readable", join(workDir, "readable"));

      const content = store.readFile("readable", "SKILL.md");
      expect(content).toContain("A test skill for unit tests");
    });

    it("blocks path traversal", () => {
      makeSkillDir(workDir, "trapped");
      store.saveSkill("trapped", join(workDir, "trapped"));

      // Attempt to escape skill directory
      expect(store.readFile("trapped", "../../etc/passwd")).toBeUndefined();
      // Attempt to read another user's skill
      expect(store.readFile("trapped", "../../other-user/other-skill/SKILL.md")).toBeUndefined();
    });

    it("returns undefined for missing file", () => {
      makeSkillDir(workDir, "sparse");
      store.saveSkill("sparse", join(workDir, "sparse"));

      expect(store.readFile("sparse", "nonexistent.txt")).toBeUndefined();
    });

    it("returns undefined for missing skill", () => {
      expect(store.readFile("ghost", "SKILL.md")).toBeUndefined();
    });
  });

  // ─── getPath ───

  describe("getPath", () => {
    it("returns path for saved skill", () => {
      makeSkillDir(workDir, "findable");
      store.saveSkill("findable", join(workDir, "findable"));

      const path = store.getPath("findable");
      expect(path).not.toBeNull();
      expect(existsSync(path!)).toBe(true);
    });

    it("returns null for missing skill", () => {
      expect(store.getPath("missing")).toBeNull();
    });
  });
});

// ─── SkillRegistry Tests ───

const SKILL_A = `---
name: skill-a
description: "First test skill"
---
# Skill A
`;

const SKILL_B = `---
name: skill-b
description: "Second test skill"
---
# Skill B
`;

describe("SkillRegistry", () => {
  let scanDir: string;
  let registry: SkillRegistry;

  beforeEach(() => {
    scanDir = mkdtempSync(join(tmpdir(), "pi-skill-registry-"));
    registry = new SkillRegistry([], { debounceMs: 50 });
    // Replace default scan dirs with our temp dir
    (registry as any).scanDirs = [scanDir];
  });

  afterEach(() => {
    registry.stopWatching();
    rmSync(scanDir, { recursive: true, force: true });
  });

  describe("scan", () => {
    it("discovers skills from directories with SKILL.md", () => {
      makeSkillDir(scanDir, "skill-a", SKILL_A);
      makeSkillDir(scanDir, "skill-b", SKILL_B);

      const event = registry.scan();
      expect(registry.list()).toHaveLength(2);
      expect(registry.get("skill-a")?.description).toBe("First test skill");
      expect(registry.get("skill-b")?.description).toBe("Second test skill");
      expect(event.added).toContain("skill-a");
      expect(event.added).toContain("skill-b");
      expect(event.removed).toEqual([]);
    });

    it("skips directories without SKILL.md", () => {
      mkdirSync(join(scanDir, "no-skill"), { recursive: true });
      writeFileSync(join(scanDir, "no-skill", "README.md"), "not a skill");

      registry.scan();
      expect(registry.list()).toHaveLength(0);
    });

    it("skips SKILL.md without description", () => {
      makeSkillDir(scanDir, "bad-skill", NO_DESC_SKILL_MD);
      registry.scan();
      expect(registry.list()).toHaveLength(0);
    });

    it("emits skills:changed on catalog change", () => {
      const events: SkillsChangedEvent[] = [];
      registry.on("skills:changed", (e) => events.push(e));

      makeSkillDir(scanDir, "skill-a", SKILL_A);
      registry.scan();

      expect(events).toHaveLength(1);
      expect(events[0].added).toEqual(["skill-a"]);
    });

    it("does not emit when nothing changed", () => {
      makeSkillDir(scanDir, "skill-a", SKILL_A);
      registry.scan(); // first scan

      const events: SkillsChangedEvent[] = [];
      registry.on("skills:changed", (e) => events.push(e));
      registry.scan(); // second scan — same data

      expect(events).toHaveLength(0);
    });

    it("detects removed skills", () => {
      makeSkillDir(scanDir, "skill-a", SKILL_A);
      registry.scan();

      rmSync(join(scanDir, "skill-a"), { recursive: true });
      const event = registry.scan();

      expect(event.removed).toEqual(["skill-a"]);
      expect(registry.list()).toHaveLength(0);
    });

    it("detects modified skills (description change)", () => {
      makeSkillDir(scanDir, "skill-a", SKILL_A);
      registry.scan();

      // Change description
      const updated = SKILL_A.replace("First test skill", "Updated skill");
      writeFileSync(join(scanDir, "skill-a", "SKILL.md"), updated);
      const event = registry.scan();

      expect(event.modified).toEqual(["skill-a"]);
      expect(registry.get("skill-a")?.description).toBe("Updated skill");
    });

    it("first dir wins on name collision", () => {
      const dir2 = mkdtempSync(join(tmpdir(), "pi-skill-registry2-"));
      (registry as any).scanDirs = [scanDir, dir2];

      const SHARED_A = `---\nname: shared\ndescription: "First version"\n---\n# A\n`;
      const SHARED_B = `---\nname: shared\ndescription: "Second version"\n---\n# B\n`;
      makeSkillDir(scanDir, "shared", SHARED_A);
      makeSkillDir(dir2, "shared", SHARED_B);
      registry.scan();

      // scanDir is first, so its version wins
      expect(registry.get("shared")?.description).toBe("First version");

      rmSync(dir2, { recursive: true, force: true });
    });
  });

  describe("getDetail", () => {
    it("returns SKILL.md content and file list", () => {
      const DETAILED = `---\nname: detailed\ndescription: "A detailed skill"\n---\n# Detailed\n`;
      const dir = makeSkillDir(scanDir, "detailed", DETAILED);
      writeFileSync(join(dir, "helper.py"), "print('hi')");
      registry.scan();

      const detail = registry.getDetail("detailed");
      expect(detail).toBeDefined();
      expect(detail!.content).toContain("A detailed skill");
      expect(detail!.files).toContain("SKILL.md");
      expect(detail!.files).toContain("helper.py");
    });

    it("returns undefined for missing skill", () => {
      registry.scan();
      expect(registry.getDetail("nope")).toBeUndefined();
    });
  });

  describe("getFileContent", () => {
    it("reads a file from a skill", () => {
      const READABLE = `---\nname: readable\ndescription: "A readable skill"\n---\n# Readable\n`;
      const dir = makeSkillDir(scanDir, "readable", READABLE);
      writeFileSync(join(dir, "data.txt"), "hello");
      registry.scan();

      expect(registry.getFileContent("readable", "data.txt")).toBe("hello");
    });

    it("blocks path traversal", () => {
      const TRAPPED = `---\nname: trapped\ndescription: "A trapped skill"\n---\n# Trapped\n`;
      makeSkillDir(scanDir, "trapped", TRAPPED);
      registry.scan();
      expect(registry.getFileContent("trapped", "../../etc/passwd")).toBeUndefined();
    });
  });

  describe("watch", () => {
    async function triggerDebouncedRescan(): Promise<void> {
      (registry as any).debouncedRescan();
      await new Promise((r) => setTimeout(r, 120));
    }

    // Node 25 + macOS has flaky fs.watch delivery in tests. Instead of
    // asserting OS watcher behavior, assert the registry logic that watch
    // relies on: debounced re-scan updates add/remove/modify state.
    it("debounced re-scan picks up newly added skills", async () => {
      registry.scan();

      const NEW_SKILL = `---\nname: new-skill\ndescription: "A newly added skill"\n---\n# New Skill\n`;
      makeSkillDir(scanDir, "new-skill", NEW_SKILL);
      await triggerDebouncedRescan();

      expect(registry.get("new-skill")).toBeDefined();
    });

    it("debounced re-scan picks up removed skills", async () => {
      const DOOMED_SKILL = `---\nname: doomed\ndescription: "A doomed skill"\n---\n# Doomed\n`;
      makeSkillDir(scanDir, "doomed", DOOMED_SKILL);
      registry.scan();
      expect(registry.get("doomed")).toBeDefined();

      rmSync(join(scanDir, "doomed"), { recursive: true });
      await triggerDebouncedRescan();

      expect(registry.get("doomed")).toBeUndefined();
    });

    it("debounced re-scan picks up SKILL.md modifications", async () => {
      const EVOLVING = `---\nname: evolving\ndescription: "First description"\n---\n# Evolving\n`;
      makeSkillDir(scanDir, "evolving", EVOLVING);
      registry.scan();
      expect(registry.get("evolving")?.description).toBe("First description");

      const updated = EVOLVING.replace("First description", "Changed description");
      writeFileSync(join(scanDir, "evolving", "SKILL.md"), updated);
      await triggerDebouncedRescan();

      expect(registry.get("evolving")?.description).toBe("Changed description");
    });

    it("stopWatching prevents further re-scans", async () => {
      registry.scan();
      registry.watch();
      registry.stopWatching();

      const events: SkillsChangedEvent[] = [];
      registry.on("skills:changed", (e) => events.push(e));

      makeSkillDir(scanDir, "ignored", SKILL_A);
      await new Promise((r) => setTimeout(r, 200));

      expect(events).toHaveLength(0);
    });
  });

  describe("registerUserSkills", () => {
    it("adds user skills to the registry", () => {
      const CUSTOM = `---\nname: custom\ndescription: "A custom skill"\n---\n# Custom\n`;
      const userDir = mkdtempSync(join(tmpdir(), "pi-user-skill-"));
      makeSkillDir(userDir, "custom", CUSTOM);

      registry.scan();
      registry.registerUserSkills([
        {
          name: "custom",
          description: "A custom skill",
          builtIn: false,
          createdAt: Date.now(),
          sizeBytes: 100,
          path: join(userDir, "custom"),
        },
      ]);

      expect(registry.get("custom")).toBeDefined();
      expect(registry.get("custom")?.description).toBe("A custom skill");

      rmSync(userDir, { recursive: true, force: true });
    });
  });
});

// ─── Frontmatter Extraction ───

describe("extractFrontmatterField", () => {
  it("extracts a simple field", () => {
    const content = `---\nname: test\ncontainer: true\n---\n# Hello`;
    expect(extractFrontmatterField(content, "container")).toBe("true");
  });

  it("extracts quoted field", () => {
    const content = `---\ndescription: "hello world"\n---\n# Hello`;
    expect(extractFrontmatterField(content, "description")).toBe("hello world");
  });

  it("returns undefined when field missing", () => {
    const content = `---\nname: test\n---\n# Hello`;
    expect(extractFrontmatterField(content, "container")).toBeUndefined();
  });

  it("returns undefined when no frontmatter", () => {
    expect(extractFrontmatterField("# No frontmatter", "name")).toBeUndefined();
  });
});

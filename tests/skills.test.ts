import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { UserSkillStore, SkillValidationError } from "../src/skills.js";

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
      expect(store.listSkills("u1")).toEqual([]);
    });

    it("returns saved skills", () => {
      makeSkillDir(workDir, "my-skill");
      store.saveSkill("u1", "my-skill", join(workDir, "my-skill"));

      const skills = store.listSkills("u1");
      expect(skills).toHaveLength(1);
      expect(skills[0].name).toBe("my-skill");
      expect(skills[0].description).toBe("A test skill for unit tests");
      expect(skills[0].builtIn).toBe(false);
      expect(skills[0].userId).toBe("u1");
    });

    it("skips directories without SKILL.md", () => {
      // Create a user dir with a random directory (no SKILL.md)
      mkdirSync(join(storeDir, "u1", "junk"), { recursive: true });
      writeFileSync(join(storeDir, "u1", "junk", "notes.txt"), "hello");

      expect(store.listSkills("u1")).toEqual([]);
    });

    it("isolates users", () => {
      makeSkillDir(workDir, "skill-a");
      store.saveSkill("u1", "skill-a", join(workDir, "skill-a"));

      expect(store.listSkills("u1")).toHaveLength(1);
      expect(store.listSkills("u2")).toHaveLength(0);
    });
  });

  // ─── Get ───

  describe("getSkill", () => {
    it("returns null for missing skill", () => {
      expect(store.getSkill("u1", "nonexistent")).toBeNull();
    });

    it("returns skill with metadata", () => {
      makeSkillDir(workDir, "analyzer");
      store.saveSkill("u1", "analyzer", join(workDir, "analyzer"));

      const skill = store.getSkill("u1", "analyzer");
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

      store.saveSkill("u1", "copier", src);

      const destDir = join(storeDir, "u1", "copier");
      expect(existsSync(join(destDir, "SKILL.md"))).toBe(true);
      expect(existsSync(join(destDir, "helper.py"))).toBe(true);
    });

    it("overwrites existing skill", () => {
      const src = makeSkillDir(workDir, "evolving");
      writeFileSync(join(src, "v1.txt"), "version 1");
      store.saveSkill("u1", "evolving", src);

      // Update source
      writeFileSync(join(src, "SKILL.md"), VALID_SKILL_MD);
      writeFileSync(join(src, "v2.txt"), "version 2");
      rmSync(join(src, "v1.txt"));
      store.saveSkill("u1", "evolving", src);

      const destDir = join(storeDir, "u1", "evolving");
      expect(existsSync(join(destDir, "v2.txt"))).toBe(true);
      expect(existsSync(join(destDir, "v1.txt"))).toBe(false);
    });

    it("rejects invalid name", () => {
      const src = makeSkillDir(workDir, "Bad_Name");
      expect(() => store.saveSkill("u1", "Bad_Name", src))
        .toThrow("Invalid skill name");
    });

    it("rejects name starting with number", () => {
      const src = makeSkillDir(workDir, "1bad");
      expect(() => store.saveSkill("u1", "1bad", src))
        .toThrow("Invalid skill name");
    });

    it("rejects missing source dir", () => {
      expect(() => store.saveSkill("u1", "ghost", "/nonexistent/path"))
        .toThrow("Source directory not found");
    });

    it("rejects source without SKILL.md", () => {
      const src = join(workDir, "no-skill-md");
      mkdirSync(src, { recursive: true });
      writeFileSync(join(src, "readme.md"), "not a skill");

      expect(() => store.saveSkill("u1", "no-skill-md", src))
        .toThrow("SKILL.md not found");
    });

    it("rejects skill exceeding size limit", () => {
      const src = makeSkillDir(workDir, "chonky");
      // Write a 200KB file (limit is 100KB)
      writeFileSync(join(src, "big.bin"), Buffer.alloc(200 * 1024));

      expect(() => store.saveSkill("u1", "chonky", src))
        .toThrow("too large");
    });

    it("rejects skill exceeding file count", () => {
      const src = makeSkillDir(workDir, "many-files");
      for (let i = 0; i < 55; i++) {
        writeFileSync(join(src, `file-${i}.txt`), `content ${i}`);
      }

      expect(() => store.saveSkill("u1", "many-files", src))
        .toThrow("Too many files");
    });

    it("rejects SKILL.md without description", () => {
      const src = join(workDir, "no-desc");
      mkdirSync(src, { recursive: true });
      writeFileSync(join(src, "SKILL.md"), NO_DESC_SKILL_MD);

      expect(() => store.saveSkill("u1", "no-desc", src))
        .toThrow("Failed to read saved skill");
    });
  });

  // ─── Delete ───

  describe("deleteSkill", () => {
    it("removes a saved skill", () => {
      makeSkillDir(workDir, "doomed");
      store.saveSkill("u1", "doomed", join(workDir, "doomed"));
      expect(store.getSkill("u1", "doomed")).not.toBeNull();

      const result = store.deleteSkill("u1", "doomed");
      expect(result).toBe(true);
      expect(store.getSkill("u1", "doomed")).toBeNull();
    });

    it("returns false for nonexistent skill", () => {
      expect(store.deleteSkill("u1", "nope")).toBe(false);
    });
  });

  // ─── File Access ───

  describe("listFiles", () => {
    it("returns relative file paths", () => {
      const src = makeSkillDir(workDir, "with-files");
      mkdirSync(join(src, "scripts"), { recursive: true });
      writeFileSync(join(src, "scripts", "run.sh"), "#!/bin/bash");
      store.saveSkill("u1", "with-files", src);

      const files = store.listFiles("u1", "with-files");
      expect(files).toContain("SKILL.md");
      expect(files).toContain("scripts/run.sh");
    });

    it("returns empty for missing skill", () => {
      expect(store.listFiles("u1", "nope")).toEqual([]);
    });
  });

  describe("readFile", () => {
    it("reads a file from a saved skill", () => {
      const src = makeSkillDir(workDir, "readable");
      writeFileSync(join(src, "data.txt"), "hello world");
      store.saveSkill("u1", "readable", src);

      const content = store.readFile("u1", "readable", "data.txt");
      expect(content).toBe("hello world");
    });

    it("returns SKILL.md content", () => {
      makeSkillDir(workDir, "readable");
      store.saveSkill("u1", "readable", join(workDir, "readable"));

      const content = store.readFile("u1", "readable", "SKILL.md");
      expect(content).toContain("A test skill for unit tests");
    });

    it("blocks path traversal", () => {
      makeSkillDir(workDir, "trapped");
      store.saveSkill("u1", "trapped", join(workDir, "trapped"));

      // Attempt to escape skill directory
      expect(store.readFile("u1", "trapped", "../../etc/passwd")).toBeUndefined();
      // Attempt to read another user's skill
      expect(store.readFile("u1", "trapped", "../../other-user/other-skill/SKILL.md")).toBeUndefined();
    });

    it("returns undefined for missing file", () => {
      makeSkillDir(workDir, "sparse");
      store.saveSkill("u1", "sparse", join(workDir, "sparse"));

      expect(store.readFile("u1", "sparse", "nonexistent.txt")).toBeUndefined();
    });

    it("returns undefined for missing skill", () => {
      expect(store.readFile("u1", "ghost", "SKILL.md")).toBeUndefined();
    });
  });

  // ─── getPath ───

  describe("getPath", () => {
    it("returns path for saved skill", () => {
      makeSkillDir(workDir, "findable");
      store.saveSkill("u1", "findable", join(workDir, "findable"));

      const path = store.getPath("u1", "findable");
      expect(path).not.toBeNull();
      expect(existsSync(path!)).toBe(true);
    });

    it("returns null for missing skill", () => {
      expect(store.getPath("u1", "missing")).toBeNull();
    });
  });
});

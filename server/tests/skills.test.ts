import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SkillRegistry, extractFrontmatterField, type SkillsChangedEvent } from "../src/skills.js";

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
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    async function triggerDebouncedRescan(): Promise<void> {
      (registry as any).debouncedRescan();
      vi.advanceTimersByTime(50);
      await Promise.resolve();
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

    it("stopWatching clears pending debounced re-scans", () => {
      registry.scan();

      const events: SkillsChangedEvent[] = [];
      registry.on("skills:changed", (e) => events.push(e));

      makeSkillDir(scanDir, "ignored", SKILL_A);
      (registry as any).debouncedRescan();
      registry.stopWatching();
      vi.advanceTimersByTime(200);

      expect(registry.get("ignored")).toBeUndefined();
      expect(events).toHaveLength(0);
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

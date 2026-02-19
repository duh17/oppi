/**
 * Sandbox skill re-sync tests.
 *
 * Tests that workspace skills are re-synced when:
 * - Workspace skill list is updated (PUT /workspaces/:id)
 * - Skill files change on disk (FSWatcher → handleSkillsChanged)
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  existsSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SandboxManager } from "../src/sandbox.js";
import { SkillRegistry } from "../src/skills.js";
import type { Workspace } from "../src/types.js";

// ─── Helpers ───

let tmp: string;
let skillDir: string;
let sandbox: SandboxManager;
let registry: SkillRegistry;

function makeSkill(name: string, content: string): void {
  const dir = join(skillDir, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SKILL.md"), content);
}

function makeWorkspace(id: string, skills: string[], runtime: "host" | "container" = "container"): Workspace {
  const now = Date.now();
  return {
    id,
    name: `ws-${id}`,
    runtime,
    skills,
    createdAt: now,
    updatedAt: now,
  };
}

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "oppi-skill-resync-"));
  skillDir = join(tmp, "skills-source");

  makeSkill("search", '---\nname: search\ndescription: "Search"\n---\n# Search v1');
  makeSkill("fetch", '---\nname: fetch\ndescription: "Fetch"\n---\n# Fetch v1');
  makeSkill("browser", '---\nname: browser\ndescription: "Browser"\n---\n# Browser v1');

  registry = new SkillRegistry([], { debounceMs: 50 });
  (registry as any).scanDirs = [skillDir];
  registry.scan();

  sandbox = new SandboxManager({ sandboxBaseDir: join(tmp, "sandboxes") });
  sandbox.setSkillRegistry(registry);
});

afterEach(() => {
  registry.stopWatching();
  rmSync(tmp, { recursive: true, force: true });
});

// ─── resyncWorkspaceSkills ───

describe("resyncWorkspaceSkills", () => {
  it("syncs skills into an existing workspace dir", () => {
    // Create workspace dir structure (as if initSession had run)
    const wsDir = sandbox.getWorkspaceDir("w1");
    mkdirSync(wsDir, { recursive: true });

    const installed = sandbox.resyncWorkspaceSkills("w1", ["search", "fetch"]);

    expect(installed).toEqual(["search", "fetch"]);
    expect(existsSync(join(wsDir, "skills", "search", "SKILL.md"))).toBe(true);
    expect(existsSync(join(wsDir, "skills", "fetch", "SKILL.md"))).toBe(true);
  });

  it("skips if workspace dir does not exist", () => {
    const installed = sandbox.resyncWorkspaceSkills("nonexistent", ["search"]);
    expect(installed).toEqual([]);
  });

  it("updates skill content when source changes", () => {
    const wsDir = sandbox.getWorkspaceDir("w1");
    mkdirSync(wsDir, { recursive: true });

    // Initial sync
    sandbox.resyncWorkspaceSkills("w1", ["search"]);
    const v1 = readFileSync(join(wsDir, "skills", "search", "SKILL.md"), "utf-8");
    expect(v1).toContain("Search v1");

    // Update source
    writeFileSync(
      join(skillDir, "search", "SKILL.md"),
      '---\nname: search\ndescription: "Search"\n---\n# Search v2',
    );

    // Re-sync picks up change
    sandbox.resyncWorkspaceSkills("w1", ["search"]);
    const v2 = readFileSync(join(wsDir, "skills", "search", "SKILL.md"), "utf-8");
    expect(v2).toContain("Search v2");
  });
});

// ─── handleSkillsChanged ───

describe("handleSkillsChanged", () => {
  it("re-syncs container workspaces that use changed skills", () => {
    const wsDir = sandbox.getWorkspaceDir("w1");
    mkdirSync(wsDir, { recursive: true });

    // Initial sync
    sandbox.resyncWorkspaceSkills("w1", ["search", "fetch"]);

    // Simulate skill change on disk
    writeFileSync(
      join(skillDir, "search", "SKILL.md"),
      '---\nname: search\ndescription: "Search"\n---\n# Search UPDATED',
    );

    // Trigger change handler
    sandbox.handleSkillsChanged(
      ["search"],
      () => [makeWorkspace("w1", ["search", "fetch"])],
    );

    const content = readFileSync(join(wsDir, "skills", "search", "SKILL.md"), "utf-8");
    expect(content).toContain("Search UPDATED");
  });

  it("skips host-mode workspaces", () => {
    const wsDir = sandbox.getWorkspaceDir("w-host");
    mkdirSync(join(wsDir, "skills", "search"), { recursive: true });
    writeFileSync(join(wsDir, "skills", "search", "SKILL.md"), "old");

    sandbox.handleSkillsChanged(
      ["search"],
      () => [makeWorkspace("w-host", ["search"], "host")],
    );

    // Host workspace untouched
    const content = readFileSync(join(wsDir, "skills", "search", "SKILL.md"), "utf-8");
    expect(content).toBe("old");
  });

  it("skips workspaces that dont use changed skills", () => {
    const wsDir = sandbox.getWorkspaceDir("w2");
    mkdirSync(wsDir, { recursive: true });
    sandbox.resyncWorkspaceSkills("w2", ["fetch"]);

    // Change search — w2 only uses fetch
    writeFileSync(
      join(skillDir, "search", "SKILL.md"),
      '---\nname: search\ndescription: "Search"\n---\n# CHANGED',
    );

    sandbox.handleSkillsChanged(
      ["search"],
      () => [makeWorkspace("w2", ["fetch"])],
    );

    // fetch unchanged
    const content = readFileSync(join(wsDir, "skills", "fetch", "SKILL.md"), "utf-8");
    expect(content).toContain("Fetch v1");
  });

  it("handles empty changed list as no-op", () => {
    let called = false;
    sandbox.handleSkillsChanged([], () => {
      called = true;
      return [];
    });
    expect(called).toBe(false);
  });

  it("re-syncs multiple workspaces that share a skill", () => {
    const ws1Dir = sandbox.getWorkspaceDir("w1");
    const ws2Dir = sandbox.getWorkspaceDir("w2");
    mkdirSync(ws1Dir, { recursive: true });
    mkdirSync(ws2Dir, { recursive: true });
    sandbox.resyncWorkspaceSkills("w1", ["search"]);
    sandbox.resyncWorkspaceSkills("w2", ["search", "fetch"]);

    writeFileSync(
      join(skillDir, "search", "SKILL.md"),
      '---\nname: search\ndescription: "Search"\n---\n# BOTH',
    );

    sandbox.handleSkillsChanged(
      ["search"],
      () => [
        makeWorkspace("w1", ["search"]),
        makeWorkspace("w2", ["search", "fetch"]),
      ],
    );

    expect(readFileSync(join(ws1Dir, "skills", "search", "SKILL.md"), "utf-8")).toContain("BOTH");
    expect(readFileSync(join(ws2Dir, "skills", "search", "SKILL.md"), "utf-8")).toContain("BOTH");
  });
});

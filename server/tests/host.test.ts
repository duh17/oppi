import { describe, it, expect } from "vitest";
import { scanDirectories, discoverProjects } from "../src/host.js";

describe("scanDirectories", () => {
  it("finds projects in ~/workspace", () => {
    const dirs = scanDirectories("~/workspace");
    expect(dirs.length).toBeGreaterThan(0);
  });

  it("finds pios with correct metadata", () => {
    const dirs = scanDirectories("~/workspace");
    const pios = dirs.find((d) => d.name === "pios");
    expect(pios).toBeDefined();
    expect(pios!.isGitRepo).toBe(true);
    expect(pios!.hasAgentsMd).toBe(true);
    expect(pios!.path).toMatch(/^~/);
  });

  it("returns empty for non-existent directory", () => {
    const dirs = scanDirectories("~/nonexistent-dir-xyz");
    expect(dirs).toHaveLength(0);
  });

  it("skips hidden directories and node_modules", () => {
    const dirs = scanDirectories("~/workspace");
    const names = dirs.map((d) => d.name);
    expect(names).not.toContain("node_modules");
    expect(names).not.toContain(".git");
  });
});

describe("discoverProjects", () => {
  it("finds projects across all roots", () => {
    const all = discoverProjects();
    expect(all.length).toBeGreaterThan(0);
  });
});

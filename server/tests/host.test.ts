import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { discoverProjects, scanDirectories } from "../src/host.js";

let tempRoots: string[] = [];

function makeTempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-host-test-"));
  tempRoots.push(root);
  return root;
}

function makeProject(root: string, name: string, files: Record<string, string> = {}): string {
  const project = join(root, name);
  mkdirSync(project, { recursive: true });
  for (const [relativePath, content] of Object.entries(files)) {
    const filePath = join(project, relativePath);
    mkdirSync(join(filePath, ".."), { recursive: true });
    writeFileSync(filePath, content);
  }
  return project;
}

afterEach(() => {
  for (const root of tempRoots) {
    rmSync(root, { recursive: true, force: true });
  }
  tempRoots = [];
});

describe("scanDirectories", () => {
  it("finds projects in a root directory", async () => {
    const root = makeTempRoot();
    makeProject(root, "oppi", { "package.json": "{}", "tsconfig.json": "{}" });

    const dirs = await scanDirectories(root);

    expect(dirs.map((dir) => dir.name)).toEqual(["oppi"]);
  });

  it("finds a git project with correct metadata", async () => {
    const root = makeTempRoot();
    makeProject(root, "oppi", { "AGENTS.md": "# Agent guide\n" });
    mkdirSync(join(root, "oppi", ".git"));

    const dirs = await scanDirectories(root);
    const oppi = dirs.find((d) => d.name === "oppi");

    expect(oppi).toBeDefined();
    expect(oppi!.isGitRepo).toBe(true);
    expect(oppi!.hasAgentsMd).toBe(true);
    expect(oppi!.path).toContain("oppi");
  });

  it("returns empty for non-existent directory", async () => {
    const dirs = await scanDirectories("~/nonexistent-dir-xyz");
    expect(dirs).toHaveLength(0);
  });

  it("skips hidden directories and node_modules", async () => {
    const root = makeTempRoot();
    makeProject(root, "visible", { "go.mod": "module example.com/visible\n" });
    makeProject(root, ".hidden", { "package.json": "{}" });
    makeProject(root, "node_modules", { "package.json": "{}" });

    const dirs = await scanDirectories(root);
    const names = dirs.map((d) => d.name);

    expect(names).toEqual(["visible"]);
  });
});

describe("discoverProjects", () => {
  it("finds projects across supplied roots", async () => {
    const firstRoot = makeTempRoot();
    const secondRoot = makeTempRoot();
    makeProject(firstRoot, "alpha", { "pyproject.toml": "[project]\nname = 'alpha'\n" });
    makeProject(secondRoot, "beta", { "Package.swift": "// swift-tools-version: 6.0\n" });

    const all = await discoverProjects([firstRoot, secondRoot]);

    expect(all.map((dir) => dir.name)).toEqual(["alpha", "beta"]);
  });
});

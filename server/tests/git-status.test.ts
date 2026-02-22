import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { getGitStatus } from "../src/git-status.js";

// ─── Helpers ───

function gitIn(dir: string, cmd: string): string {
  return execSync(`git ${cmd}`, { cwd: dir, encoding: "utf-8" }).trim();
}

// ─── Fixtures ───

let repoDir: string;
let nonGitDir: string;

beforeAll(() => {
  // Create a real git repo with commits
  repoDir = mkdtempSync(join(tmpdir(), "git-status-test-repo-"));
  gitIn(repoDir, "init -b main");
  gitIn(repoDir, 'config user.email "test@test.com"');
  gitIn(repoDir, 'config user.name "Test"');

  writeFileSync(join(repoDir, "file1.txt"), "hello\n");
  gitIn(repoDir, "add file1.txt");
  gitIn(repoDir, 'commit -m "initial commit"');

  // Create a non-git directory
  nonGitDir = mkdtempSync(join(tmpdir(), "git-status-test-noGit-"));
  writeFileSync(join(nonGitDir, "readme.txt"), "not a repo\n");
});

afterAll(() => {
  rmSync(repoDir, { recursive: true, force: true });
  rmSync(nonGitDir, { recursive: true, force: true });
});

// ─── Tests ───

describe("getGitStatus", () => {
  it("returns isGitRepo false for non-git directory", async () => {
    const status = await getGitStatus(nonGitDir);
    expect(status.isGitRepo).toBe(false);
    expect(status.branch).toBeNull();
    expect(status.dirtyCount).toBe(0);
  });

  it("returns isGitRepo false for nonexistent directory", async () => {
    const status = await getGitStatus("/tmp/does-not-exist-xyz-abc");
    expect(status.isGitRepo).toBe(false);
  });

  it("detects branch name", async () => {
    const status = await getGitStatus(repoDir);
    expect(status.isGitRepo).toBe(true);
    expect(status.branch).toBe("main");
  });

  it("detects HEAD sha", async () => {
    const status = await getGitStatus(repoDir);
    expect(status.headSha).toBeTruthy();
    expect(status.headSha!.length).toBeGreaterThanOrEqual(7);
  });

  it("shows clean status when no changes", async () => {
    const status = await getGitStatus(repoDir);
    expect(status.dirtyCount).toBe(0);
    expect(status.untrackedCount).toBe(0);
    expect(status.stagedCount).toBe(0);
    expect(status.totalFiles).toBe(0);
    expect(status.files).toHaveLength(0);
    expect(status.addedLines).toBe(0);
    expect(status.removedLines).toBe(0);
  });

  it("detects untracked files (no line stats)", async () => {
    writeFileSync(join(repoDir, "untracked.txt"), "new file\n");
    try {
      const status = await getGitStatus(repoDir);
      expect(status.untrackedCount).toBe(1);
      const file = status.files.find((f) => f.path === "untracked.txt" && f.status === "??");
      expect(file).toBeDefined();
      // Untracked files have no numstat data
      expect(file!.addedLines).toBeNull();
      expect(file!.removedLines).toBeNull();
    } finally {
      rmSync(join(repoDir, "untracked.txt"));
    }
  });

  it("detects modified files with per-file line stats", async () => {
    writeFileSync(join(repoDir, "file1.txt"), "modified\nline2\nline3\n");
    try {
      const status = await getGitStatus(repoDir);
      expect(status.dirtyCount).toBe(1);
      const file = status.files.find((f) => f.path === "file1.txt");
      expect(file).toBeDefined();
      // "hello\n" → "modified\nline2\nline3\n" = 3 added, 1 removed
      expect(file!.addedLines).toBe(3);
      expect(file!.removedLines).toBe(1);
      // Totals
      expect(status.addedLines).toBe(3);
      expect(status.removedLines).toBe(1);
    } finally {
      gitIn(repoDir, "checkout -- file1.txt");
    }
  });

  it("detects staged files", async () => {
    writeFileSync(join(repoDir, "staged.txt"), "staged\n");
    gitIn(repoDir, "add staged.txt");
    try {
      const status = await getGitStatus(repoDir);
      expect(status.stagedCount).toBe(1);
      expect(status.files.some((f) => f.path === "staged.txt")).toBe(true);
    } finally {
      gitIn(repoDir, "reset HEAD staged.txt");
      rmSync(join(repoDir, "staged.txt"));
    }
  });

  it("detects stash entries", async () => {
    writeFileSync(join(repoDir, "file1.txt"), "stash me\n");
    gitIn(repoDir, "stash push -m test-stash");
    try {
      const status = await getGitStatus(repoDir);
      expect(status.stashCount).toBeGreaterThanOrEqual(1);
    } finally {
      gitIn(repoDir, "stash drop");
    }
  });

  it("returns last commit message and date", async () => {
    const status = await getGitStatus(repoDir);
    expect(status.lastCommitMessage).toBe("initial commit");
    expect(status.lastCommitDate).toBeTruthy();
    // ISO date format
    expect(status.lastCommitDate).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it("returns null ahead/behind when no upstream", async () => {
    const status = await getGitStatus(repoDir);
    // No remote configured → null
    expect(status.ahead).toBeNull();
    expect(status.behind).toBeNull();
  });

  it("handles detached HEAD", async () => {
    const sha = gitIn(repoDir, "rev-parse HEAD");
    gitIn(repoDir, `checkout ${sha}`);
    try {
      const status = await getGitStatus(repoDir);
      expect(status.isGitRepo).toBe(true);
      expect(status.branch).toBeNull();
      expect(status.headSha).toBeTruthy();
    } finally {
      gitIn(repoDir, "checkout main");
    }
  });

  it("caps files at 500", async () => {
    // Create 510 untracked files in repo root (not a subdir — git shows subdir as single entry)
    for (let i = 0; i < 510; i++) {
      writeFileSync(join(repoDir, `bulk-${String(i).padStart(3, "0")}.txt`), `content-${i}\n`);
    }
    try {
      const status = await getGitStatus(repoDir);
      expect(status.files.length).toBeLessThanOrEqual(500);
      expect(status.untrackedCount).toBe(510);
      expect(status.totalFiles).toBeGreaterThanOrEqual(510);
    } finally {
      for (let i = 0; i < 510; i++) {
        rmSync(join(repoDir, `bulk-${String(i).padStart(3, "0")}.txt`), { force: true });
      }
    }
  });

  it("resolves tilde paths", async () => {
    // This test runs against the actual oppi repo
    const status = await getGitStatus("~/workspace/oppi");
    expect(status.isGitRepo).toBe(true);
    expect(status.branch).toBeTruthy();
  });

  it("handles mixed status (staged + dirty + untracked)", async () => {
    // Create a staged file
    writeFileSync(join(repoDir, "a-staged.txt"), "staged\n");
    gitIn(repoDir, "add a-staged.txt");

    // Create a modified tracked file
    writeFileSync(join(repoDir, "file1.txt"), "modified\n");

    // Create an untracked file
    writeFileSync(join(repoDir, "z-untracked.txt"), "new\n");

    try {
      const status = await getGitStatus(repoDir);
      expect(status.stagedCount).toBe(1);
      expect(status.dirtyCount).toBe(1);
      expect(status.untrackedCount).toBe(1);
      expect(status.totalFiles).toBe(3);
    } finally {
      gitIn(repoDir, "reset HEAD a-staged.txt");
      rmSync(join(repoDir, "a-staged.txt"));
      gitIn(repoDir, "checkout -- file1.txt");
      rmSync(join(repoDir, "z-untracked.txt"));
    }
  });
});

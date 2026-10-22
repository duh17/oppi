import { execFileSync } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  CommitDiffError,
  getCommitDetail,
  getCommitFileDiff,
  getCommitGraph,
} from "../src/git-commits.js";
import { HOST_GIT_TRUST } from "../src/git-safe.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" });
}

async function createRepo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "oppi-git-commits-"));
  git(dir, ["init"]);
  git(dir, ["config", "user.email", "test@example.com"]);
  git(dir, ["config", "user.name", "Test User"]);
  return dir;
}

describe("getCommitDetail", () => {
  it("returns the full commit message including its body", async () => {
    const dir = await createRepo();

    await writeFile(join(dir, "README.md"), "seed\n");
    git(dir, ["add", "README.md"]);
    git(dir, ["commit", "-m", "initial"]);

    await writeFile(join(dir, "README.md"), "updated\n");
    git(dir, ["add", "README.md"]);
    git(dir, [
      "commit",
      "-m",
      "docs: explain contributor workflow",
      "-m",
      "Ask contributors to open an issue before submitting a pull request.",
    ]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();
    const detail = await getCommitDetail(dir, HOST_GIT_TRUST, sha);

    expect(detail.message).toBe(
      "docs: explain contributor workflow\n\nAsk contributors to open an issue before submitting a pull request.",
    );
  });
});

describe("getCommitGraph", () => {
  async function commit(dir: string, message: string): Promise<string> {
    // A file per commit, so branches merge without conflicts.
    const file = `${message.replaceAll(" ", "-")}.txt`;
    await writeFile(join(dir, file), `${message}\n`);
    git(dir, ["add", file]);
    git(dir, ["commit", "-m", message]);
    return git(dir, ["rev-parse", "HEAD"]).trim();
  }

  it("lists every local branch with parents and refs, paged without a count", async () => {
    const dir = await createRepo();
    git(dir, ["checkout", "-b", "main"]);
    const base = await commit(dir, "base");
    git(dir, ["tag", "v1"]);
    git(dir, ["checkout", "-b", "feat/side"]);
    const side = await commit(dir, "side");
    git(dir, ["checkout", "main"]);
    const tip = await commit(dir, "main tip");
    // A remote-tracking ref shows as a remote, never as a local branch.
    git(dir, ["update-ref", "refs/remotes/origin/main", base]);

    const first = await getCommitGraph(dir, HOST_GIT_TRUST, 0, 2);
    const rest = await getCommitGraph(dir, HOST_GIT_TRUST, 2, 2);
    const all = [...first.commits, ...rest.commits];

    expect(first.hasMore).toBe(true);
    expect(rest.hasMore).toBe(false);
    expect(all.map((entry) => entry.sha).sort()).toEqual([base, side, tip].sort());
    // Topological: both children come before the base they share.
    expect(all[2].sha).toBe(base);
    expect(base.startsWith(all[2].shortSha)).toBe(true);
    const byMessage = new Map(all.map((entry) => [entry.message, entry]));
    expect(byMessage.get("main tip")?.parents).toEqual([base]);
    expect(byMessage.get("main tip")?.refs).toEqual([
      { kind: "branch", name: "main", isHead: true },
    ]);
    expect(byMessage.get("side")?.refs).toEqual([{ kind: "branch", name: "feat/side" }]);
    expect(byMessage.get("base")?.parents).toEqual([]);
    expect(byMessage.get("base")?.refs).toEqual(
      expect.arrayContaining([
        { kind: "tag", name: "v1" },
        { kind: "remote", name: "origin/main" },
      ]),
    );
  });

  it("marks a detached HEAD and gives a merge both parents", async () => {
    const dir = await createRepo();
    git(dir, ["checkout", "-b", "main"]);
    await commit(dir, "base");
    git(dir, ["checkout", "-b", "feat"]);
    const side = await commit(dir, "side");
    git(dir, ["checkout", "main"]);
    const mainTip = await commit(dir, "main tip");
    git(dir, ["merge", "--no-ff", "feat", "-m", "merge feat"]);
    git(dir, ["checkout", "--detach", "HEAD"]);

    const { commits } = await getCommitGraph(dir, HOST_GIT_TRUST, 0, 10);

    expect(commits[0].message).toBe("merge feat");
    expect(commits[0].parents).toEqual([mainTip, side]);
    expect(commits[0].refs).toEqual([
      { kind: "head", name: "HEAD" },
      { kind: "branch", name: "main" },
    ]);
  });

  it("is empty before the first commit and fails outside a repository", async () => {
    const empty = await createRepo();
    await expect(getCommitGraph(empty, HOST_GIT_TRUST, 0, 10)).resolves.toEqual({
      commits: [],
      hasMore: false,
    });

    const notRepo = await mkdtemp(join(tmpdir(), "oppi-git-commits-plain-"));
    await expect(getCommitGraph(notRepo, HOST_GIT_TRUST, 0, 10)).rejects.toThrow(
      "Commit graph unavailable",
    );
  });
});

describe("getCommitFileDiff", () => {
  it("renders tiny commit diffs for large text files", async () => {
    const dir = await createRepo();
    const filePath = "ds4_cuda.cu";
    const lines = Array.from({ length: 20_000 }, (_, index) => `int value_${index} = ${index};`);

    await writeFile(join(dir, filePath), `${lines.join("\n")}\n`);
    git(dir, ["add", filePath]);
    git(dir, ["commit", "-m", "initial"]);

    // Edit from the end so earlier line numbers stay stable on the old side.
    lines.splice(15_000, 1);
    lines[10_000] = "int value_10000 = 42;";
    lines.splice(51, 0, "int inserted_only = 1;");
    await writeFile(join(dir, filePath), `${lines.join("\n")}\n`);
    git(dir, ["add", filePath]);
    git(dir, ["commit", "-m", "tiny change"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();
    const diff = await getCommitFileDiff(dir, HOST_GIT_TRUST, sha, filePath, "test-workspace");

    expect(diff.addedLines).toBe(2);
    expect(diff.removedLines).toBe(2);
    expect(diff.baselineText).toBe("");
    expect(diff.currentText).toBe("");
    expect(Buffer.byteLength(diff.baselineText, "utf8")).toBe(0);
    expect(Buffer.byteLength(diff.currentText, "utf8")).toBe(0);
    expect(diff.hunks.length).toBeGreaterThanOrEqual(3);

    const allLines = diff.hunks.flatMap((hunk) => hunk.lines);
    const removedPaired = allLines.find((line) => line.text === "int value_10000 = 10000;");
    const addedPaired = allLines.find((line) => line.text === "int value_10000 = 42;");
    const addedOnly = allLines.find((line) => line.text === "int inserted_only = 1;");
    const removedOnly = allLines.find((line) => line.text === "int value_15000 = 15000;");

    expect(removedPaired?.kind).toBe("removed");
    expect(addedPaired?.kind).toBe("added");
    expect(removedPaired?.oldLine).toBe(10001);
    expect(addedPaired?.newLine).toBe(10002);
    expect(removedPaired?.spans?.length).toBeGreaterThan(0);
    expect(addedPaired?.spans?.length).toBeGreaterThan(0);
    expect(addedOnly?.kind).toBe("added");
    expect(addedOnly?.spans).toBeUndefined();
    expect(removedOnly?.kind).toBe("removed");
    expect(removedOnly?.spans).toBeUndefined();
  });

  it("returns full text diff for newly added files", async () => {
    const dir = await createRepo();

    await writeFile(join(dir, "README.md"), "seed\n");
    git(dir, ["add", "README.md"]);
    git(dir, ["commit", "-m", "initial"]);

    const filePath = "notes.txt";
    await writeFile(join(dir, filePath), "alpha\nbeta\n");
    git(dir, ["add", filePath]);
    git(dir, ["commit", "-m", "add notes"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();
    const diff = await getCommitFileDiff(dir, HOST_GIT_TRUST, sha, filePath, "workspace-1");

    expect(diff.workspaceId).toBe("workspace-1");
    expect(diff.path).toBe(filePath);
    expect(diff.baselineText).toBe("");
    expect(diff.currentText).toBe("");
    expect(diff.hunks.flatMap((hunk) => hunk.lines.map((line) => line.text))).toEqual([
      "alpha",
      "beta",
    ]);
    expect(diff.addedLines).toBe(2);
    expect(diff.removedLines).toBe(0);
  });

  it("rejects invalid commit SHAs before shelling out", async () => {
    const dir = await createRepo();

    await expect(
      getCommitFileDiff(dir, HOST_GIT_TRUST, "bad;sha", "file.txt", "workspace-1"),
    ).rejects.toThrow("Invalid commit SHA");
  });

  it("rejects blank paths", async () => {
    const dir = await createRepo();

    await writeFile(join(dir, "README.md"), "seed\n");
    git(dir, ["add", "README.md"]);
    git(dir, ["commit", "-m", "initial"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();

    await expect(
      getCommitFileDiff(dir, HOST_GIT_TRUST, sha, "   ", "workspace-1"),
    ).rejects.toMatchObject({
      name: "CommitDiffError",
      status: 400,
      message: "path parameter required",
    } satisfies Partial<CommitDiffError>);
  });

  it("returns not found when a path is absent from the commit", async () => {
    const dir = await createRepo();

    await writeFile(join(dir, "README.md"), "seed\n");
    git(dir, ["add", "README.md"]);
    git(dir, ["commit", "-m", "initial"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();

    await expect(
      getCommitFileDiff(dir, HOST_GIT_TRUST, sha, "missing.txt", "workspace-1"),
    ).rejects.toMatchObject({
      name: "CommitDiffError",
      status: 404,
      message: "File not found in commit",
    } satisfies Partial<CommitDiffError>);
  });

  it("rejects binary files in diff view", async () => {
    const dir = await createRepo();
    const filePath = "image.bin";

    await writeFile(join(dir, filePath), Buffer.from([0xde, 0xad, 0x00, 0xbe, 0xef]));
    git(dir, ["add", filePath]);
    git(dir, ["commit", "-m", "add binary"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();

    await expect(
      getCommitFileDiff(dir, HOST_GIT_TRUST, sha, filePath, "workspace-1"),
    ).rejects.toMatchObject({
      name: "CommitDiffError",
      status: 422,
      message: "Binary files are not supported in diff view.",
    } satisfies Partial<CommitDiffError>);
  });
});

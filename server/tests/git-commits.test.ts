import { execFileSync } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { CommitDiffError, getCommitDetail, getCommitFileDiff } from "../src/git-commits.js";

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
    const detail = await getCommitDetail(dir, sha);

    expect(detail.message).toBe(
      "docs: explain contributor workflow\n\nAsk contributors to open an issue before submitting a pull request.",
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

    lines[10_000] = "int value_10000 = 42;";
    lines.splice(10_001, 0, "int inserted_a = 1;", "int inserted_b = 2;", "int inserted_c = 3;");
    await writeFile(join(dir, filePath), `${lines.join("\n")}\n`);
    git(dir, ["add", filePath]);
    git(dir, ["commit", "-m", "tiny change"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();
    const diff = await getCommitFileDiff(dir, sha, filePath, "test-workspace");

    expect(diff.addedLines).toBe(4);
    expect(diff.removedLines).toBe(1);
    expect(diff.hunks).toHaveLength(1);
    expect(diff.hunks[0]?.lines.some((line) => line.text === "int value_10000 = 42;")).toBe(true);
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
    const diff = await getCommitFileDiff(dir, sha, filePath, "workspace-1");

    expect(diff.workspaceId).toBe("workspace-1");
    expect(diff.path).toBe(filePath);
    expect(diff.baselineText).toBe("");
    expect(diff.currentText).toBe("alpha\nbeta\n");
    expect(diff.addedLines).toBe(2);
    expect(diff.removedLines).toBe(0);
  });

  it("rejects invalid commit SHAs before shelling out", async () => {
    const dir = await createRepo();

    await expect(getCommitFileDiff(dir, "bad;sha", "file.txt", "workspace-1")).rejects.toThrow(
      "Invalid commit SHA",
    );
  });

  it("rejects blank paths", async () => {
    const dir = await createRepo();

    await writeFile(join(dir, "README.md"), "seed\n");
    git(dir, ["add", "README.md"]);
    git(dir, ["commit", "-m", "initial"]);

    const sha = git(dir, ["rev-parse", "--short", "HEAD"]).trim();

    await expect(getCommitFileDiff(dir, sha, "   ", "workspace-1")).rejects.toMatchObject({
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

    await expect(getCommitFileDiff(dir, sha, "missing.txt", "workspace-1")).rejects.toMatchObject({
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

    await expect(getCommitFileDiff(dir, sha, filePath, "workspace-1")).rejects.toMatchObject({
      name: "CommitDiffError",
      status: 422,
      message: "Binary files are not supported in diff view.",
    } satisfies Partial<CommitDiffError>);
  });
});

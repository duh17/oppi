import { execFileSync } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { getCommitFileDiff } from "../src/git-commits.js";

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
});

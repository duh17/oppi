import { execFileSync } from "node:child_process";
import { rm, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { getCommitFileDiff } from "../src/git-commits.js";
import { HOST_GIT_TRUST } from "../src/git-safe.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import type { Workspace } from "../src/types.js";
import { buildWorkspaceReviewDiff } from "../src/workspace-review-diff.js";
import { makeTempDir } from "./harness/temp-dir.js";
import { makeRequest, MockWritableResponse } from "./harness/route-test-helpers.js";

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

/** A tiny but real PNG header, and a second one that differs, both with NUL bytes. */
const PNG_V1 = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4",
  "hex",
);
const PNG_V2 = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000020000000208060000007b1a43",
  "hex",
);

async function commitAll(dir: string, message: string): Promise<string> {
  git(dir, ["add", "-A"]);
  git(dir, ["commit", "-m", message]);
  return git(dir, ["rev-parse", "HEAD"]);
}

/** Commits: add logo.png (v1) + data.bin, modify logo.png (v2), delete both. */
async function binaryHistory(): Promise<{
  dir: string;
  added: string;
  modified: string;
  deleted: string;
}> {
  const dir = makeTempDir("oppi-git-blobs-");
  git(dir, ["init", "--initial-branch=main"]);
  git(dir, ["config", "user.email", "test@example.com"]);
  git(dir, ["config", "user.name", "Test User"]);
  await writeFile(join(dir, "logo.png"), PNG_V1);
  await writeFile(join(dir, "data.bin"), Buffer.from([1, 0, 2, 0, 3]));
  const added = await commitAll(dir, "add binaries");
  await writeFile(join(dir, "logo.png"), PNG_V2);
  const modified = await commitAll(dir, "change logo");
  await unlink(join(dir, "logo.png"));
  await unlink(join(dir, "data.bin"));
  const deleted = await commitAll(dir, "remove binaries");
  return { dir, added, modified, deleted };
}

async function getBlob(
  dir: string,
  query: Record<string, string>,
  range?: string,
): Promise<{ status: number; headers: Record<string, string>; body: Buffer }> {
  const workspace: Workspace = {
    id: "ws-1",
    name: "Default",
    hostMount: dir,
    systemPromptMode: "append",
    createdAt: 0,
    updatedAt: 0,
  };
  const ctx = {
    storage: { getWorkspace: vi.fn(() => workspace), getDataDir: vi.fn(() => dir) },
  } as unknown as RouteContext;
  const dispatch = createWorkspaceRoutes(ctx, createRouteHelpers());
  const req = makeRequest();
  if (range) req.headers.range = range;
  const res = new MockWritableResponse();
  const finished = new Promise<void>((done) => res.on("end", () => done()));
  const url = new URL("http://localhost/workspaces/ws-1/git/blob");
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
  const handled = await dispatch({
    method: "GET",
    path: url.pathname,
    url,
    req,
    res: res as never,
  });
  expect(handled).toBe(true);
  await finished;
  return { status: res.statusCode, headers: res.headers, body: res.body };
}

describe("binary files in a commit diff", () => {
  it("reports which sides of an added, modified and deleted binary exist", async () => {
    const { dir, added, modified, deleted } = await binaryHistory();
    const diff = (sha: string) => getCommitFileDiff(dir, HOST_GIT_TRUST, sha, "logo.png", "ws-1");

    await expect(diff(added)).resolves.toMatchObject({
      hunks: [],
      nonText: { before: false, after: true },
    });
    await expect(diff(modified)).resolves.toMatchObject({
      hunks: [],
      nonText: { before: true, after: true },
    });
    await expect(diff(deleted)).resolves.toMatchObject({
      hunks: [],
      nonText: { before: true, after: false },
    });
  });

  it("still reports a binary larger than the text diff limit as a file, not a missing one", async () => {
    const dir = makeTempDir("oppi-git-blobs-large-");
    git(dir, ["init", "--initial-branch=main"]);
    git(dir, ["config", "user.email", "test@example.com"]);
    git(dir, ["config", "user.name", "Test User"]);
    await writeFile(join(dir, "big.bin"), Buffer.alloc(2 * 1024 * 1024, 0));
    await commitAll(dir, "seed");
    await writeFile(join(dir, "big.bin"), Buffer.alloc(2 * 1024 * 1024, 1));
    const sha = await commitAll(dir, "change");

    await expect(
      getCommitFileDiff(dir, HOST_GIT_TRUST, sha, "big.bin", "ws-1"),
    ).resolves.toMatchObject({ nonText: { before: true, after: true } });
  });
});

describe("binary files in the workspace review diff", () => {
  it("reports a changed, a new and a deleted binary, including one over the review size limit", async () => {
    const { dir } = await binaryHistory();
    await writeFile(join(dir, "logo.png"), PNG_V1);
    git(dir, ["add", "logo.png"]);
    git(dir, ["commit", "-m", "restore logo"]);
    const review = (path: string) =>
      buildWorkspaceReviewDiff({
        workspaceId: "ws-1",
        workspaceRoot: dir,
        trust: HOST_GIT_TRUST,
        path,
      });

    // Modified in the working tree.
    await writeFile(join(dir, "logo.png"), PNG_V2);
    await expect(review("logo.png")).resolves.toMatchObject({
      hunks: [],
      nonText: { before: true, after: true },
    });
    // New, and large: still a file, not "too large".
    await writeFile(join(dir, "new.bin"), Buffer.alloc(600 * 1024, 0));
    await expect(review("new.bin")).resolves.toMatchObject({
      nonText: { before: false, after: true },
    });
    // Deleted from the working tree.
    await rm(join(dir, "logo.png"));
    await expect(review("logo.png")).resolves.toMatchObject({
      nonText: { before: true, after: false },
    });
  });
});

describe("GET /workspaces/{id}/git/blob", () => {
  it("serves the bytes each commit stored, not the working tree", async () => {
    const { dir, added, modified, deleted } = await binaryHistory();
    // The working tree holds neither version.
    await writeFile(join(dir, "logo.png"), Buffer.from("working tree"));

    const atAdded = await getBlob(dir, { rev: added, path: "logo.png" });
    expect(atAdded.status).toBe(200);
    expect(atAdded.headers["Content-Type"]).toBe("image/png");
    expect(atAdded.body.equals(PNG_V1)).toBe(true);

    // Modified: the new side is the commit, the old side its parent.
    expect((await getBlob(dir, { rev: modified, path: "logo.png" })).body.equals(PNG_V2)).toBe(
      true,
    );
    expect(
      (await getBlob(dir, { rev: `${modified}^`, path: "logo.png" })).body.equals(PNG_V1),
    ).toBe(true);

    // Deleted: the old side only; the commit itself no longer has it.
    expect((await getBlob(dir, { rev: `${deleted}^`, path: "data.bin" })).body).toEqual(
      Buffer.from([1, 0, 2, 0, 3]),
    );
    expect((await getBlob(dir, { rev: deleted, path: "data.bin" })).status).toBe(404);
    expect((await getBlob(dir, { rev: `${added}^`, path: "logo.png" })).status).toBe(404);
  });

  it("serves one byte range and refuses anything that is not a revision", async () => {
    const { dir, added } = await binaryHistory();

    const ranged = await getBlob(dir, { rev: added, path: "logo.png" }, "bytes=0-3");
    expect(ranged.status).toBe(206);
    expect(ranged.headers["Content-Range"]).toBe(`bytes 0-3/${PNG_V1.length}`);
    expect(ranged.body).toEqual(PNG_V1.subarray(0, 4));

    for (const rev of ["", "--output=/tmp/x", "main", "HEAD~1"]) {
      expect((await getBlob(dir, { rev, path: "logo.png" })).status).toBe(400);
    }
    expect((await getBlob(dir, { rev: added, path: "" })).status).toBe(400);
  });
});

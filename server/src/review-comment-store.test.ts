import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { ReviewCommentStore, ReviewCommentStoreError } from "./review-comment-store.js";

let root: string;
let store: ReviewCommentStore;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "oppi-review-comments-"));
  store = new ReviewCommentStore(root, "w1");
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("ReviewCommentStore", () => {
  it("creates and lists staged comments", async () => {
    const comment = await store.create({
      sessionId: "s1",
      body: "Please check this response shape.",
      reference: {
        source: "git_diff",
        path: "server/src/foo.ts",
        side: "new",
        startLine: 42,
        selectedText: "return json;",
      },
    });

    expect(comment.workspaceId).toBe("w1");
    expect(comment.status).toBe("staged");
    expect(comment.author).toBe("human");

    const comments = await store.list({ sessionId: "s1", status: "staged" });
    expect(comments).toHaveLength(1);
    expect(comments[0]?.reference.path).toBe("server/src/foo.ts");

    const persistedPath = join(root, "review-comments", "w1.json");
    expect(existsSync(persistedPath)).toBe(true);
    expect(existsSync(join(root, ".oppi", "review-comments.json"))).toBe(false);
    const persisted = JSON.parse(await readFile(persistedPath, "utf8")) as {
      comments: Array<{ body: string }>;
    };
    expect(persisted.comments[0]?.body).toBe("Please check this response shape.");
  });

  it("marks comments sent", async () => {
    const comment = await store.create({
      sessionId: "s1",
      body: "Comment body",
      reference: { source: "timeline_text", selectedText: "selected" },
    });

    const updated = await store.attachToTurn({ ids: [comment.id], sessionId: "s1", turnId: "t1" });

    expect(updated).toHaveLength(1);
    expect(updated[0]?.status).toBe("sent");
    expect(updated[0]?.turnId).toBe("t1");
    expect(updated[0]?.sentAt).toBeTypeOf("number");
  });

  it("serializes writes across store instances for the same workspace", async () => {
    const firstStore = new ReviewCommentStore(root, "w1");
    const secondStore = new ReviewCommentStore(root, "w1");

    await Promise.all([
      firstStore.create({
        sessionId: "s1",
        body: "First comment",
        reference: { source: "file", path: "README.md", startLine: 1 },
      }),
      secondStore.create({
        sessionId: "s1",
        body: "Second comment",
        reference: { source: "file", path: "README.md", startLine: 2 },
      }),
    ]);

    const comments = await store.list({ sessionId: "s1" });
    expect(comments.map((comment) => comment.body).sort()).toEqual([
      "First comment",
      "Second comment",
    ]);
  });

  it("rejects empty comment bodies", async () => {
    await expect(
      store.create({
        body: "   ",
        reference: { source: "file", path: "README.md" },
      }),
    ).rejects.toMatchObject(new ReviewCommentStoreError(400, "body required"));
  });

  it("fails loudly when the persisted store is corrupted", async () => {
    await mkdir(join(root, "review-comments"), { recursive: true, mode: 0o700 });
    await writeFile(join(root, "review-comments", "w1.json"), "{not-json", { mode: 0o600 });

    await expect(store.list()).rejects.toMatchObject(
      new ReviewCommentStoreError(500, "Review comment store is corrupted"),
    );
  });
});

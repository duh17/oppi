import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { openDatabase } from "../src/sqlite-compat.js";
import { Storage } from "../src/storage.js";
import { ReviewCommentStore, ReviewCommentStoreError } from "../src/review-comment-store.js";

let root: string;
let stores: ReviewCommentStore[];

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "oppi-review-comments-"));
  stores = [];
});

afterEach(async () => {
  for (const store of stores) {
    store.close();
  }
  await rm(root, { recursive: true, force: true });
});

function track(store: ReviewCommentStore): ReviewCommentStore {
  stores.push(store);
  return store;
}

async function writeLegacyComments(workspaceId: string, comments: unknown[]): Promise<void> {
  await mkdir(join(root, "review-comments"), { recursive: true, mode: 0o700 });
  await writeFile(
    join(root, "review-comments", `${workspaceId}.json`),
    JSON.stringify({ version: 1, comments }),
    { mode: 0o600 },
  );
}

describe("ReviewCommentStore", () => {
  it("creates and lists staged comments from SQLite", async () => {
    const store = track(new ReviewCommentStore(root, "w1"));

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

    expect(existsSync(join(root, "session-state.db"))).toBe(true);
    expect(existsSync(join(root, "review-comments", "w1.json"))).toBe(false);
    expect(existsSync(join(root, ".oppi", "review-comments.json"))).toBe(false);

    const db = openDatabase(join(root, "session-state.db"));
    try {
      const row = db
        .prepare("SELECT comment_json FROM review_comments WHERE workspace_id = ? AND id = ?")
        .get("w1", comment.id) as { comment_json: string } | undefined;
      const persisted = JSON.parse(row?.comment_json ?? "{}") as { body?: string };
      expect(persisted.body).toBe("Please check this response shape.");
    } finally {
      db.close();
    }
  });

  it("marks comments sent", async () => {
    const store = track(new ReviewCommentStore(root, "w1"));
    const comment = await store.create({
      sessionId: "s1",
      body: "Comment body",
      reference: { source: "timeline_text", selectedText: "selected" },
    });

    const updated = await store.markSent({ ids: [comment.id], sessionId: "s1", turnId: "t1" });

    expect(updated).toHaveLength(1);
    expect(updated[0]?.status).toBe("sent");
    expect(updated[0]?.turnId).toBe("t1");
    expect(updated[0]?.sentAt).toBeTypeOf("number");
  });

  it("serializes writes across store instances for the same workspace", async () => {
    const firstStore = track(new ReviewCommentStore(root, "w1"));
    const secondStore = track(new ReviewCommentStore(root, "w1"));
    const listStore = track(new ReviewCommentStore(root, "w1"));

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

    const comments = await listStore.list({ sessionId: "s1" });
    expect(comments.map((comment) => comment.body).sort()).toEqual([
      "First comment",
      "Second comment",
    ]);
  });

  it("recovers an interrupted SQLite primary-key rebuild", async () => {
    const dbPath = join(root, "session-state.db");
    const db = openDatabase(dbPath);
    const comment = {
      id: "rescued-1",
      workspaceId: "w1",
      sessionId: "s1",
      author: "human" as const,
      status: "staged" as const,
      body: "Rescued body",
      reference: { source: "file" as const, path: "README.md" },
      createdAt: 1,
      updatedAt: 1,
    };
    try {
      db.exec(`
        CREATE TABLE review_comments_next (
          id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          session_id TEXT,
          turn_id TEXT,
          author TEXT NOT NULL,
          status TEXT NOT NULL,
          severity TEXT,
          body TEXT NOT NULL,
          reference_source TEXT NOT NULL,
          reference_path TEXT,
          reference_timeline_item_id TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          sent_at INTEGER,
          comment_json TEXT NOT NULL,
          PRIMARY KEY (workspace_id, id)
        );
      `);
      db.prepare(
        `
        INSERT INTO review_comments_next (
          id,
          workspace_id,
          session_id,
          author,
          status,
          body,
          reference_source,
          reference_path,
          created_at,
          updated_at,
          comment_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `,
      ).run(
        comment.id,
        comment.workspaceId,
        comment.sessionId,
        comment.author,
        comment.status,
        comment.body,
        comment.reference.source,
        comment.reference.path,
        comment.createdAt,
        comment.updatedAt,
        JSON.stringify(comment),
      );
    } finally {
      db.close();
    }

    const store = track(new ReviewCommentStore(root, "w1"));
    const comments = await store.list({ sessionId: "s1" });

    expect(comments).toHaveLength(1);
    expect(comments[0]?.body).toBe("Rescued body");

    const reopened = openDatabase(dbPath);
    try {
      const nextTable = reopened
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'review_comments_next'",
        )
        .get();
      expect(nextTable).toBeUndefined();
    } finally {
      reopened.close();
    }
  });

  it("is exposed through the main Storage DAO seam", () => {
    const storage = new Storage(root);
    const comment = storage.createReviewComment("w1", {
      sessionId: "s1",
      body: "DAO comment",
      reference: { source: "file", path: "README.md" },
    });

    expect(storage.listReviewComments("w1", { path: "README.md" })).toEqual([comment]);
    expect(new Storage(root).listReviewComments("w1", { sessionId: "s1" })[0]?.body).toBe(
      "DAO comment",
    );
  });

  it("imports legacy workspace JSON into SQLite", async () => {
    await writeLegacyComments("w1", [
      {
        id: "legacy-1",
        workspaceId: "w1",
        sessionId: "s1",
        author: "human",
        status: "staged",
        body: "Legacy body",
        reference: { source: "file", path: "README.md" },
        createdAt: 1,
        updatedAt: 1,
      },
    ]);

    const store = track(new ReviewCommentStore(root, "w1"));
    const comments = await store.list({ sessionId: "s1" });

    expect(comments).toHaveLength(1);
    expect(comments[0]?.id).toBe("legacy-1");
    expect(comments[0]?.body).toBe("Legacy body");
  });

  it("does not reimport successful workspaces after another legacy file fails", async () => {
    await writeLegacyComments("w1", [
      {
        id: "legacy-1",
        workspaceId: "w1",
        sessionId: "s1",
        author: "human",
        status: "staged",
        body: "Legacy body",
        reference: { source: "file", path: "README.md" },
        createdAt: 1,
        updatedAt: 1,
      },
    ]);
    await writeFile(join(root, "review-comments", "w2.json"), "{not-json", { mode: 0o600 });

    const firstStore = track(new ReviewCommentStore(root, "w1"));
    expect((await firstStore.list({ sessionId: "s1" }))[0]?.status).toBe("staged");
    await firstStore.update("legacy-1", { status: "resolved" });

    const restartedStore = track(new ReviewCommentStore(root, "w1"));
    const comments = await restartedStore.list({ sessionId: "s1" });

    expect(comments).toHaveLength(1);
    expect(comments[0]?.status).toBe("resolved");
  });

  it("retries a workspace legacy import after its corrupt JSON is fixed", async () => {
    await mkdir(join(root, "review-comments"), { recursive: true, mode: 0o700 });
    await writeFile(join(root, "review-comments", "w1.json"), "{not-json", { mode: 0o600 });

    const corruptStore = track(new ReviewCommentStore(root, "w1"));
    await expect(corruptStore.list()).rejects.toMatchObject(
      new ReviewCommentStoreError(500, "Review comment store is corrupted"),
    );

    await writeLegacyComments("w1", [
      {
        id: "legacy-1",
        workspaceId: "w1",
        author: "human",
        status: "staged",
        body: "Fixed body",
        reference: { source: "file", path: "README.md" },
        createdAt: 1,
        updatedAt: 1,
      },
    ]);

    const fixedStore = track(new ReviewCommentStore(root, "w1"));
    const comments = await fixedStore.list();

    expect(comments).toHaveLength(1);
    expect(comments[0]?.body).toBe("Fixed body");
  });

  it("keeps duplicate legacy comment ids isolated by workspace", async () => {
    await writeLegacyComments("w1", [
      {
        id: "same-id",
        workspaceId: "w1",
        author: "human",
        status: "staged",
        body: "Workspace one",
        reference: { source: "file", path: "one.md" },
        createdAt: 1,
        updatedAt: 1,
      },
    ]);
    await writeLegacyComments("w2", [
      {
        id: "same-id",
        workspaceId: "w2",
        author: "human",
        status: "open",
        body: "Workspace two",
        reference: { source: "file", path: "two.md" },
        createdAt: 2,
        updatedAt: 2,
      },
    ]);

    const w1Store = track(new ReviewCommentStore(root, "w1"));
    const w2Store = track(new ReviewCommentStore(root, "w2"));

    expect((await w1Store.list())[0]?.body).toBe("Workspace one");
    expect((await w2Store.list())[0]?.body).toBe("Workspace two");
  });

  it("rejects empty comment bodies", async () => {
    const store = track(new ReviewCommentStore(root, "w1"));

    await expect(
      store.create({
        body: "   ",
        reference: { source: "file", path: "README.md" },
      }),
    ).rejects.toMatchObject(new ReviewCommentStoreError(400, "body required"));
  });

  it("fails loudly when the legacy store is corrupted", async () => {
    await mkdir(join(root, "review-comments"), { recursive: true, mode: 0o700 });
    await writeFile(join(root, "review-comments", "w1.json"), "{not-json", { mode: 0o600 });

    const store = track(new ReviewCommentStore(root, "w1"));
    await expect(store.list()).rejects.toMatchObject(
      new ReviewCommentStoreError(500, "Review comment store is corrupted"),
    );
  });
});

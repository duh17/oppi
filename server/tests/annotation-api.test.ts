import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, readFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  listAnnotations,
  createAnnotation,
  updateAnnotation,
  deleteAnnotation,
  AnnotationStoreError,
} from "../src/annotation-store.js";
import type { CreateAnnotationRequest } from "../src/types.js";

let workspaceRoot: string;
const workspaceId = "test-ws";

beforeEach(async () => {
  workspaceRoot = await mkdtemp(join(tmpdir(), "oppi-annotation-test-"));
});

afterEach(async () => {
  await rm(workspaceRoot, { recursive: true, force: true });
});

function makeRequest(overrides: Partial<CreateAnnotationRequest> = {}): CreateAnnotationRequest {
  return {
    path: "src/server.ts",
    side: "new",
    startLine: 42,
    body: "Hardcoded retry count — pull from config.",
    author: "agent",
    sessionId: "session-1",
    severity: "warn",
    ...overrides,
  };
}

describe("annotation CRUD", () => {
  it("creates and lists annotations", async () => {
    const created = await createAnnotation(workspaceId, workspaceRoot, makeRequest());
    expect(created.id).toBeTruthy();
    expect(created.workspaceId).toBe(workspaceId);
    expect(created.path).toBe("src/server.ts");
    expect(created.side).toBe("new");
    expect(created.startLine).toBe(42);
    expect(created.body).toBe("Hardcoded retry count — pull from config.");
    expect(created.author).toBe("agent");
    expect(created.sessionId).toBe("session-1");
    expect(created.severity).toBe("warn");
    expect(created.resolution).toBe("pending");

    const all = await listAnnotations(workspaceId, workspaceRoot);
    expect(all).toHaveLength(1);
    expect(all[0].id).toBe(created.id);
  });

  it("filters by path", async () => {
    await createAnnotation(workspaceId, workspaceRoot, makeRequest({ path: "a.ts" }));
    await createAnnotation(workspaceId, workspaceRoot, makeRequest({ path: "b.ts" }));

    const filtered = await listAnnotations(workspaceId, workspaceRoot, "a.ts");
    expect(filtered).toHaveLength(1);
    expect(filtered[0].path).toBe("a.ts");
  });

  it("filters by sessionId", async () => {
    await createAnnotation(workspaceId, workspaceRoot, makeRequest({ sessionId: "s1" }));
    await createAnnotation(workspaceId, workspaceRoot, makeRequest({ sessionId: "s2" }));

    const filtered = await listAnnotations(workspaceId, workspaceRoot, undefined, "s1");
    expect(filtered).toHaveLength(1);
    expect(filtered[0].sessionId).toBe("s1");
  });

  it("updates body and resolution", async () => {
    const created = await createAnnotation(workspaceId, workspaceRoot, makeRequest());

    const updated = await updateAnnotation(workspaceRoot, created.id, {
      body: "Updated body.",
      resolution: "accepted",
    });

    expect(updated.body).toBe("Updated body.");
    expect(updated.resolution).toBe("accepted");
    expect(updated.updatedAt).toBeGreaterThanOrEqual(created.updatedAt);

    const all = await listAnnotations(workspaceId, workspaceRoot);
    expect(all[0].body).toBe("Updated body.");
  });

  it("updates resolution only", async () => {
    const created = await createAnnotation(workspaceId, workspaceRoot, makeRequest());

    const updated = await updateAnnotation(workspaceRoot, created.id, {
      resolution: "rejected",
    });

    expect(updated.resolution).toBe("rejected");
    expect(updated.body).toBe(created.body);
  });

  it("deletes an annotation", async () => {
    const a1 = await createAnnotation(workspaceId, workspaceRoot, makeRequest());
    const a2 = await createAnnotation(
      workspaceId,
      workspaceRoot,
      makeRequest({ path: "other.ts" }),
    );

    await deleteAnnotation(workspaceRoot, a1.id);

    const remaining = await listAnnotations(workspaceId, workspaceRoot);
    expect(remaining).toHaveLength(1);
    expect(remaining[0].id).toBe(a2.id);
  });

  it("persists to disk as JSON", async () => {
    await createAnnotation(workspaceId, workspaceRoot, makeRequest());

    const raw = await readFile(join(workspaceRoot, ".oppi", "annotations.json"), "utf8");
    const parsed = JSON.parse(raw);
    expect(parsed.version).toBe(1);
    expect(parsed.annotations).toHaveLength(1);
  });
});

describe("annotation validation", () => {
  it("rejects empty path", async () => {
    await expect(
      createAnnotation(workspaceId, workspaceRoot, makeRequest({ path: "" })),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("rejects empty body", async () => {
    await expect(
      createAnnotation(workspaceId, workspaceRoot, makeRequest({ body: "  " })),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("rejects invalid side", async () => {
    await expect(
      createAnnotation(
        workspaceId,
        workspaceRoot,
        makeRequest({ side: "invalid" as "old" }),
      ),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("rejects invalid author", async () => {
    await expect(
      createAnnotation(
        workspaceId,
        workspaceRoot,
        makeRequest({ author: "bot" as "agent" }),
      ),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("rejects invalid severity", async () => {
    await expect(
      createAnnotation(
        workspaceId,
        workspaceRoot,
        makeRequest({ severity: "critical" as "error" }),
      ),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("requires startLine for non-file annotations", async () => {
    await expect(
      createAnnotation(
        workspaceId,
        workspaceRoot,
        makeRequest({ side: "new", startLine: null }),
      ),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("allows null startLine for file-level annotations", async () => {
    const created = await createAnnotation(
      workspaceId,
      workspaceRoot,
      makeRequest({ side: "file", startLine: null }),
    );
    expect(created.side).toBe("file");
    expect(created.startLine).toBeNull();
  });

  it("rejects invalid resolution on update", async () => {
    const created = await createAnnotation(workspaceId, workspaceRoot, makeRequest());
    await expect(
      updateAnnotation(workspaceRoot, created.id, {
        resolution: "invalid" as "pending",
      }),
    ).rejects.toThrow(AnnotationStoreError);
  });

  it("returns 404 for update of nonexistent annotation", async () => {
    try {
      await updateAnnotation(workspaceRoot, "nonexistent-id", { body: "x" });
      expect.unreachable("should have thrown");
    } catch (error) {
      expect(error).toBeInstanceOf(AnnotationStoreError);
      expect((error as AnnotationStoreError).status).toBe(404);
    }
  });

  it("returns 404 for delete of nonexistent annotation", async () => {
    try {
      await deleteAnnotation(workspaceRoot, "nonexistent-id");
      expect.unreachable("should have thrown");
    } catch (error) {
      expect(error).toBeInstanceOf(AnnotationStoreError);
      expect((error as AnnotationStoreError).status).toBe(404);
    }
  });
});

describe("annotation edge cases", () => {
  it("returns empty array when no annotations file exists", async () => {
    const all = await listAnnotations(workspaceId, workspaceRoot);
    expect(all).toEqual([]);
  });

  it("supports human annotations with attachments", async () => {
    const created = await createAnnotation(
      workspaceId,
      workspaceRoot,
      makeRequest({
        author: "human",
        sessionId: null,
        attachments: [{ data: "base64data", mimeType: "image/jpeg" }],
      }),
    );

    expect(created.attachments).toHaveLength(1);
    expect(created.attachments?.[0].mimeType).toBe("image/jpeg");
  });

  it("handles multiple sequential creates without data loss", async () => {
    for (let i = 0; i < 5; i++) {
      await createAnnotation(
        workspaceId,
        workspaceRoot,
        makeRequest({ path: `file-${i}.ts`, startLine: i + 1 }),
      );
    }

    const all = await listAnnotations(workspaceId, workspaceRoot);
    expect(all).toHaveLength(5);
  });

  it("preserves severity as null when not provided", async () => {
    const created = await createAnnotation(
      workspaceId,
      workspaceRoot,
      makeRequest({ severity: undefined }),
    );
    expect(created.severity).toBeNull();
  });
});

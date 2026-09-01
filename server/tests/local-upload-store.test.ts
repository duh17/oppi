import { afterEach, describe, expect, it } from "vitest";
import type { IncomingMessage } from "node:http";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

import {
  type UploadRecord,
  type UploadStoreConfigResolved,
  UploadStoreError,
  createUploadRecord,
  garbageCollectUploadStore,
  resolveUploadAttachment,
  writeUploadContent,
} from "../src/uploads/local-upload-store.js";

function makeRequest(body: Buffer): IncomingMessage {
  const stream = new PassThrough();
  stream.end(body);
  return stream as unknown as IncomingMessage;
}

async function waitForFile(path: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (existsSync(path)) return;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  throw new Error(`Timed out waiting for file: ${path}`);
}

function pngBytes(): Buffer {
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    Buffer.from("oppi-png-test"),
  ]);
}

function jpegBytes(): Buffer {
  return Buffer.concat([
    Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]),
    Buffer.from("oppi-jpeg-test"),
  ]);
}

describe("local upload store", () => {
  let root: string;

  it("creates uploads directories as owner-only when the store path is new", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-parent-"));
    const storeRoot = join(root, "uploads");
    const config: UploadStoreConfigResolved = {
      rootPath: storeRoot,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };

    await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "note.txt",
      mimeType: "text/plain",
      sizeBytes: 4,
      purpose: "chat_attachment",
    });

    expect(statSync(storeRoot).mode & 0o777).toBe(0o700);
    expect(statSync(join(storeRoot, "records")).mode & 0o777).toBe(0o700);
    expect(statSync(join(storeRoot, "tmp")).mode & 0o777).toBe(0o700);
    expect(statSync(join(storeRoot, "blobs", "sha256")).mode & 0o777).toBe(0o700);
  });

  it("does not chmod an existing custom upload root", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-custom-"));
    const storeRoot = join(root, "shared-uploads");
    mkdirSync(storeRoot, { recursive: true, mode: 0o770 });
    chmodSync(storeRoot, 0o770);
    const config: UploadStoreConfigResolved = {
      rootPath: storeRoot,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };

    await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "note.txt",
      mimeType: "text/plain",
      sizeBytes: 4,
      purpose: "chat_attachment",
    });

    expect(statSync(storeRoot).mode & 0o777).toBe(0o770);
    expect(statSync(join(storeRoot, "records")).mode & 0o777).toBe(0o700);
  });

  afterEach(() => {
    if (root) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("accepts configured allowed MIME types and stores the detected MIME", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: ["image/png"],
    };
    const body = pngBytes();

    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "screenshot.png",
      mimeType: "image/png",
      sizeBytes: body.length,
      purpose: "chat_attachment",
    });

    const completed = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      uploadId: record.id,
      req: makeRequest(body),
    });

    expect(completed.status).toBe("complete");
    expect(completed.mimeType).toBe("image/png");
    expect(statSync(root).mode & 0o777).toBe(0o700);
    expect(statSync(join(root, "records")).mode & 0o777).toBe(0o700);
    expect(statSync(join(root, "tmp")).mode & 0o777).toBe(0o700);
    expect(statSync(join(root, "blobs", "sha256")).mode & 0o777).toBe(0o700);
    expect(statSync(join(root, "records", `${record.id}.json`)).mode & 0o777).toBe(0o600);
    expect(completed.detectedMimeType).toBe("image/png");
    expect(completed.sizeBytes).toBe(body.length);
    expect(completed.expiresAt).toBeGreaterThan(completed.completedAt ?? 0);
  });

  it("binds uploads to their owning session when provided", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };
    const body = Buffer.from("hello", "utf8");

    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      name: "note.txt",
      mimeType: "text/plain",
      sizeBytes: body.length,
      purpose: "chat_attachment",
    });

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-2",
        uploadId: record.id,
        req: makeRequest(body),
      }),
    ).rejects.toMatchObject({ status: 404, message: "Upload not found" });

    const completed = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      uploadId: record.id,
      req: makeRequest(body),
    });

    await expect(
      resolveUploadAttachment({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-2",
        ref: {
          type: "attachment",
          id: completed.id,
          source: "upload",
          name: completed.safeName,
          mimeType: completed.mimeType,
          sizeBytes: completed.sizeBytes ?? 0,
          sha256: completed.sha256,
        },
      }),
    ).rejects.toMatchObject({ status: 404, message: "Upload not found" });
  });

  it("rejects declared MIME types outside the configured allowlist", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: ["image/png"],
    };

    await expect(
      createUploadRecord({
        config,
        workspaceId: "ws-1",
        name: "notes.txt",
        mimeType: "text/plain",
        sizeBytes: 12,
        purpose: "chat_attachment",
      }),
    ).rejects.toMatchObject({
      status: 415,
      message: "Declared MIME type not allowed: text/plain",
    });
  });

  it("rejects detected MIME mismatches after upload", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: ["image/jpeg", "image/png"],
    };
    const body = jpegBytes();

    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "screenshot.png",
      mimeType: "image/png",
      sizeBytes: body.length,
      purpose: "chat_attachment",
    });

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        uploadId: record.id,
        req: makeRequest(body),
      }),
    ).rejects.toMatchObject({
      status: 415,
      message: "Upload MIME type mismatch: declared image/png, detected image/jpeg",
    });
  });

  it("rejects unknown bytes declared as a sniffed allowlisted MIME type", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024 * 1024,
      maxTurnBytes: 2 * 1024 * 1024,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: ["image/png"],
    };
    const body = Buffer.from("not actually a png", "utf8");

    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "screenshot.png",
      mimeType: "image/png",
      sizeBytes: body.length,
      purpose: "chat_attachment",
    });

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        uploadId: record.id,
        req: makeRequest(body),
      }),
    ).rejects.toMatchObject({
      status: 415,
    });
  });

  it("cleans a failed size-mismatch write and allows an exact retry", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-size-retry-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 32,
      maxTurnBytes: 64,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      name: "note.txt",
      mimeType: "text/plain",
      sizeBytes: 5,
      purpose: "chat_attachment",
    });

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-1",
        uploadId: record.id,
        req: makeRequest(Buffer.from("four")),
      }),
    ).rejects.toMatchObject({
      status: 400,
      message: "Upload size mismatch: expected 5, got 4",
    });
    expect(existsSync(join(root, "tmp", `${record.id}.part`))).toBe(false);
    expect(
      JSON.parse(readFileSync(join(root, "records", `${record.id}.json`), "utf8")),
    ).toMatchObject({ status: "created", declaredSizeBytes: 5 });

    const completed = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      uploadId: record.id,
      req: makeRequest(Buffer.from("hello")),
    });
    expect(completed).toMatchObject({ status: "complete", sizeBytes: 5 });
    expect(existsSync(completed.blobPath ?? "")).toBe(true);
  });

  it("cancels and cleans an oversized streaming upload before it becomes durable", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-stream-limit-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 5,
      maxTurnBytes: 10,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "payload.bin",
      mimeType: "application/octet-stream",
      sizeBytes: 5,
      purpose: "chat_attachment",
    });
    const request = new PassThrough() as unknown as IncomingMessage;
    const tmpPath = join(root, "tmp", `${record.id}.part`);
    const write = writeUploadContent({
      config,
      workspaceId: "ws-1",
      uploadId: record.id,
      req: request,
    });

    await waitForFile(tmpPath);
    request.write(Buffer.from("123456"));
    await expect(write).rejects.toMatchObject({
      status: 413,
      message: "Upload exceeds max file size",
    });
    expect(request.destroyed).toBe(true);
    expect(existsSync(tmpPath)).toBe(false);
    expect(
      JSON.parse(readFileSync(join(root, "records", `${record.id}.json`), "utf8")),
    ).toMatchObject({ status: "created" });
  });

  it("deduplicates identical blobs, rejects duplicate writes, and validates attachment integrity", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-dedupe-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024,
      maxTurnBytes: 2048,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };
    const body = Buffer.from("same bytes", "utf8");
    const create = (name: string) =>
      createUploadRecord({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-1",
        name,
        mimeType: "text/plain",
        sizeBytes: body.length,
        purpose: "chat_attachment",
      });
    const firstRecord = await create("first.txt");
    const secondRecord = await create("second.txt");
    const first = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      uploadId: firstRecord.id,
      req: makeRequest(body),
    });
    const second = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      uploadId: secondRecord.id,
      req: makeRequest(body),
    });

    expect(first.blobPath).toBe(second.blobPath);
    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-1",
        uploadId: first.id,
        req: makeRequest(body),
      }),
    ).rejects.toMatchObject({ status: 409, message: "Upload is not in created state" });

    const ref = {
      type: "attachment" as const,
      id: first.id,
      source: "upload" as const,
      name: first.safeName,
      mimeType: first.mimeType,
      sizeBytes: first.sizeBytes ?? 0,
      sha256: first.sha256,
    };
    await expect(
      resolveUploadAttachment({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-1",
        ref: { ...ref, sizeBytes: ref.sizeBytes + 1 },
      }),
    ).rejects.toMatchObject({ status: 409, message: "Upload size mismatch" });
    await expect(
      resolveUploadAttachment({
        config,
        workspaceId: "ws-1",
        sessionId: "sess-1",
        ref: { ...ref, sha256: "0".repeat(64) },
      }),
    ).rejects.toMatchObject({ status: 409, message: "Upload hash mismatch" });

    const firstFetch = await resolveUploadAttachment({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      ref,
    });
    const duplicateFetch = await resolveUploadAttachment({
      config,
      workspaceId: "ws-1",
      sessionId: "sess-1",
      ref,
    });
    expect(firstFetch.usedAt).toBeTypeOf("number");
    expect(duplicateFetch.usedAt).toBe(firstFetch.usedAt);
  });

  it("rejects expired uploads without creating partial content", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-expired-"));
    const config: UploadStoreConfigResolved = {
      rootPath: root,
      maxFileBytes: 1024,
      maxTurnBytes: 2048,
      unusedTtlMs: 60_000,
      retainedTtlMs: 120_000,
      allowedMimeTypes: [],
    };
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "expired.txt",
      mimeType: "text/plain",
      sizeBytes: 5,
      purpose: "chat_attachment",
    });
    writeFileSync(
      join(root, "records", `${record.id}.json`),
      `${JSON.stringify({ ...record, expiresAt: 0 }, null, 2)}\n`,
    );

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        uploadId: record.id,
        req: makeRequest(Buffer.from("hello")),
      }),
    ).rejects.toMatchObject({ status: 409, message: "Upload has expired" });
    expect(existsSync(join(root, "tmp", `${record.id}.part`))).toBe(false);
  });

  it("garbage-collects expired records plus orphan tmp files and blobs without breaking dedupe", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-gc-"));
    mkdirSync(join(root, "records"), { recursive: true });
    mkdirSync(join(root, "tmp"), { recursive: true });
    mkdirSync(join(root, "blobs", "sha256", "aa", "11"), { recursive: true });
    mkdirSync(join(root, "blobs", "sha256", "bb", "22"), { recursive: true });
    mkdirSync(join(root, "blobs", "sha256", "cc", "33"), { recursive: true });

    const keepBlob = join(root, "blobs", "sha256", "aa", "11", "aa11keep");
    const dropBlob = join(root, "blobs", "sha256", "bb", "22", "bb22drop");
    const orphanBlob = join(root, "blobs", "sha256", "cc", "33", "cc33orphan");
    writeFileSync(keepBlob, "keep", "utf8");
    writeFileSync(dropBlob, "drop", "utf8");
    writeFileSync(orphanBlob, "orphan", "utf8");
    writeFileSync(join(root, "tmp", "upl_created.part"), "partial", "utf8");
    writeFileSync(join(root, "tmp", "orphan.part"), "orphan", "utf8");

    const now = 1_700_000_000_000;
    const oldEnoughForBlobGc = new Date(now - 10 * 60_000);
    utimesSync(dropBlob, oldEnoughForBlobGc, oldEnoughForBlobGc);
    utimesSync(orphanBlob, oldEnoughForBlobGc, oldEnoughForBlobGc);

    const records: UploadRecord[] = [
      {
        id: "upl_created",
        workspaceId: "ws-1",
        status: "created",
        originalName: "pending.png",
        safeName: "pending.png",
        declaredMimeType: "image/png",
        mimeType: "image/png",
        kind: "image",
        declaredSizeBytes: 7,
        purpose: "chat_attachment",
        createdAt: now - 10_000,
        updatedAt: now - 10_000,
        expiresAt: now - 1,
      },
      {
        id: "upl_unused_complete",
        workspaceId: "ws-1",
        status: "complete",
        originalName: "old.png",
        safeName: "old.png",
        declaredMimeType: "image/png",
        detectedMimeType: "image/png",
        mimeType: "image/png",
        kind: "image",
        declaredSizeBytes: 4,
        sizeBytes: 4,
        sha256: "bb22drop",
        blobPath: dropBlob,
        purpose: "chat_attachment",
        createdAt: now - 20_000,
        updatedAt: now - 15_000,
        completedAt: now - 15_000,
        expiresAt: now - 1,
      },
      {
        id: "upl_used_complete",
        workspaceId: "ws-1",
        status: "complete",
        originalName: "keep.png",
        safeName: "keep.png",
        declaredMimeType: "image/png",
        detectedMimeType: "image/png",
        mimeType: "image/png",
        kind: "image",
        declaredSizeBytes: 4,
        sizeBytes: 4,
        sha256: "aa11keep",
        blobPath: keepBlob,
        purpose: "chat_attachment",
        createdAt: now - 20_000,
        updatedAt: now - 5_000,
        completedAt: now - 15_000,
        usedAt: now - 5_000,
        expiresAt: now - 1,
      },
    ];

    for (const record of records) {
      writeFileSync(
        join(root, "records", `${record.id}.json`),
        `${JSON.stringify(record, null, 2)}\n`,
      );
    }

    const result = await garbageCollectUploadStore(
      {
        rootPath: root,
        maxFileBytes: 1024 * 1024,
        maxTurnBytes: 2 * 1024 * 1024,
        unusedTtlMs: 60_000,
        retainedTtlMs: 120_000,
        allowedMimeTypes: [],
      },
      now,
    );

    expect(result).toEqual({ removedRecords: 2, removedTmpFiles: 2, removedBlobs: 2 });
    expect(existsSync(join(root, "records", "upl_created.json"))).toBe(false);
    expect(existsSync(join(root, "records", "upl_unused_complete.json"))).toBe(false);
    expect(existsSync(join(root, "records", "upl_used_complete.json"))).toBe(true);
    expect(existsSync(join(root, "tmp", "upl_created.part"))).toBe(false);
    expect(existsSync(join(root, "tmp", "orphan.part"))).toBe(false);
    expect(existsSync(keepBlob)).toBe(true);
    expect(existsSync(dropBlob)).toBe(false);
    expect(existsSync(orphanBlob)).toBe(false);

    const kept = JSON.parse(
      readFileSync(join(root, "records", "upl_used_complete.json"), "utf8"),
    ) as UploadRecord;
    expect(kept.usedAt).toBe(now - 5_000);
  });

  it("does not traverse symlinked directories during garbage collection", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-gc-symlink-"));
    const outside = mkdtempSync(join(tmpdir(), "oppi-upload-store-outside-"));
    try {
      mkdirSync(join(root, "blobs", "sha256", "aa"), { recursive: true });
      const outsideFile = join(outside, "do-not-delete.txt");
      writeFileSync(outsideFile, "keep me", "utf8");
      symlinkSync(outside, join(root, "blobs", "sha256", "aa", "outside"), "dir");

      const result = await garbageCollectUploadStore(
        {
          rootPath: root,
          maxFileBytes: 1024 * 1024,
          maxTurnBytes: 2 * 1024 * 1024,
          unusedTtlMs: 60_000,
          retainedTtlMs: 120_000,
          allowedMimeTypes: [],
        },
        Date.now(),
      );

      expect(result.removedBlobs).toBe(0);
      expect(existsSync(outsideFile)).toBe(true);
    } finally {
      rmSync(outside, { recursive: true, force: true });
    }
  });

  it("leaves recent orphan blobs for a later garbage collection pass", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-gc-recent-"));
    mkdirSync(join(root, "blobs", "sha256", "dd", "44"), { recursive: true });
    const recentBlob = join(root, "blobs", "sha256", "dd", "44", "dd44recent");
    writeFileSync(recentBlob, "recent", "utf8");
    const now = 1_700_000_000_000;
    const recentDate = new Date(now);
    utimesSync(recentBlob, recentDate, recentDate);

    const result = await garbageCollectUploadStore(
      {
        rootPath: root,
        maxFileBytes: 1024 * 1024,
        maxTurnBytes: 2 * 1024 * 1024,
        unusedTtlMs: 60_000,
        retainedTtlMs: 120_000,
        allowedMimeTypes: [],
      },
      now,
    );

    expect(result.removedBlobs).toBe(0);
    expect(existsSync(recentBlob)).toBe(true);
  });

  it("surfaces upload store validation errors as typed errors", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-store-"));

    await expect(
      createUploadRecord({
        config: {
          rootPath: root,
          maxFileBytes: 10,
          maxTurnBytes: 10,
          unusedTtlMs: 1,
          retainedTtlMs: 1,
          allowedMimeTypes: ["image/png"],
        },
        workspaceId: "ws-1",
        name: "",
        mimeType: "application/octet-stream",
        sizeBytes: 0,
        purpose: "chat_attachment",
      }),
    ).rejects.toBeInstanceOf(UploadStoreError);
  });
});

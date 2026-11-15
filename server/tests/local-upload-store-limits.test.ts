import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, Readable } from "node:stream";

import { afterEach, describe, expect, it, vi } from "vitest";

import type { ServerConfig } from "../src/types.js";
import {
  createUploadRecord,
  garbageCollectUploadStore,
  resolveUploadStoreConfig,
  writeUploadContent,
} from "../src/uploads/local-upload-store.js";

const GIB = 1024 * 1024 * 1024;
const MIB = 1024 * 1024;

// The volume the upload store sees. Tests set it; unset reads the real disk.
const volume = vi.hoisted(() => ({
  current: undefined as { totalBytes: number; availableBytes: number } | undefined,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    statfs: async (path: string) => {
      const real = await actual.statfs(path);
      if (!volume.current) return real;
      const bsize = 4096;
      return {
        ...real,
        bsize,
        blocks: Math.floor(volume.current.totalBytes / bsize),
        bavail: Math.floor(volume.current.availableBytes / bsize),
      };
    },
  };
});

function storeConfig(root: string, uploadStore: ServerConfig["uploadStore"] = {}) {
  return resolveUploadStoreConfig({
    dataDir: root,
    uploadStore: { path: join(root, "uploads"), ...uploadStore },
  } as ServerConfig);
}

function requestFrom(stream: Readable): IncomingMessage {
  return stream as unknown as IncomingMessage;
}

/** `totalBytes` of generated, non-repeating-per-chunk bytes, hashed as they are produced. */
function generatedBody(totalBytes: number, chunkBytes = MIB) {
  const hash = createHash("sha256");
  let sent = 0;
  let index = 0;
  const stream = new Readable({
    read() {
      if (sent >= totalBytes) {
        this.push(null);
        return;
      }
      const size = Math.min(chunkBytes, totalBytes - sent);
      const chunk = Buffer.alloc(size, index % 251);
      chunk.writeUInt32BE(index, 0);
      index += 1;
      sent += size;
      hash.update(chunk);
      this.push(chunk);
    },
  });
  return { stream, digest: () => hash.digest("hex") };
}

describe("upload size limits", () => {
  let root: string;

  afterEach(() => {
    volume.current = undefined;
    if (root) rmSync(root, { recursive: true, force: true });
  });

  it("has no fixed file or turn cap unless the owner sets one", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-"));
    volume.current = { totalBytes: 1000 * GIB, availableBytes: 500 * GIB };
    const config = storeConfig(root);

    expect(config.maxFileBytes).toBeUndefined();
    expect(config.maxTurnBytes).toBeUndefined();
    // Far past the old 50 MiB default.
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "screen-recording.mov",
      mimeType: "video/quicktime",
      sizeBytes: 40 * GIB,
      purpose: "chat_attachment",
    });
    expect(record.declaredSizeBytes).toBe(40 * GIB);
  });

  it("streams a large body to disk with its size and sha256", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-stream-"));
    volume.current = { totalBytes: 1000 * GIB, availableBytes: 500 * GIB };
    const config = storeConfig(root);
    const sizeBytes = 160 * MIB + 7;
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "recording.mov",
      mimeType: "video/quicktime",
      sizeBytes,
      purpose: "chat_attachment",
    });
    const body = generatedBody(sizeBytes);

    const completed = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      uploadId: record.id,
      req: requestFrom(body.stream),
    });

    expect(completed).toMatchObject({ status: "complete", sizeBytes, sha256: body.digest() });
    expect(statSync(completed.blobPath ?? "").size).toBe(sizeBytes);
  });

  it("refuses an upload that would leave less than the free-space reserve", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-disk-"));
    // Reserve on a 100 GiB volume is 5 GiB (5% beats the 2 GiB floor); 6 GiB free.
    volume.current = { totalBytes: 100 * GIB, availableBytes: 6 * GIB };
    const config = storeConfig(root);
    const create = (sizeBytes: number) =>
      createUploadRecord({
        config,
        workspaceId: "ws-1",
        name: "recording.mov",
        mimeType: "video/quicktime",
        sizeBytes,
        purpose: "chat_attachment",
      });

    await expect(create(Math.floor(1.5 * GIB))).rejects.toMatchObject({
      status: 507,
      message:
        "Not enough free disk space on the server for this 1.5 GB upload: 6.0 GB free, " +
        "and uploads always leave 5.0 GB free.",
    });
    await expect(create(GIB)).resolves.toMatchObject({ status: "created" });
  });

  it("keeps a 2 GiB floor on a small volume", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-floor-"));
    volume.current = { totalBytes: 20 * GIB, availableBytes: 3 * GIB };
    const config = storeConfig(root);

    await expect(
      createUploadRecord({
        config,
        workspaceId: "ws-1",
        name: "recording.mov",
        mimeType: "video/quicktime",
        sizeBytes: Math.floor(1.5 * GIB),
        purpose: "chat_attachment",
      }),
    ).rejects.toMatchObject({ status: 507 });
  });

  it("checks free space again when the content arrives and writes nothing when short", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-put-"));
    volume.current = { totalBytes: 100 * GIB, availableBytes: 50 * GIB };
    const config = storeConfig(root);
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "recording.mov",
      mimeType: "video/quicktime",
      sizeBytes: 10 * GIB,
      purpose: "chat_attachment",
    });
    volume.current = { totalBytes: 100 * GIB, availableBytes: 12 * GIB };
    const request = new PassThrough();

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        uploadId: record.id,
        req: requestFrom(request),
      }),
    ).rejects.toMatchObject({ status: 507 });
    expect(readdirSync(join(config.rootPath, "tmp"))).toEqual([]);
  });

  it("still enforces an owner-set file cap when the upload is created", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-cap-"));
    volume.current = { totalBytes: 1000 * GIB, availableBytes: 500 * GIB };
    const config = storeConfig(root, { maxFileBytes: 10 * MIB });

    await expect(
      createUploadRecord({
        config,
        workspaceId: "ws-1",
        name: "recording.mov",
        mimeType: "video/quicktime",
        sizeBytes: 10 * MIB + 1,
        purpose: "chat_attachment",
      }),
    ).rejects.toMatchObject({
      status: 413,
      message: "Upload exceeds this server's 10.0 MB file size limit (uploadStore.maxFileBytes)",
    });
  });

  it("drops a cut body's partial file and completes the same upload when it is sent again", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-abort-"));
    volume.current = { totalBytes: 1000 * GIB, availableBytes: 500 * GIB };
    const config = storeConfig(root);
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "recording.mov",
      mimeType: "video/quicktime",
      sizeBytes: 10 * MIB,
      purpose: "chat_attachment",
    });
    const request = new PassThrough();
    const write = writeUploadContent({
      config,
      workspaceId: "ws-1",
      uploadId: record.id,
      req: requestFrom(request),
    });
    const tmpDir = join(config.rootPath, "tmp");
    request.write(Buffer.alloc(MIB));
    while (readdirSync(tmpDir).length === 0) await new Promise((resolve) => setTimeout(resolve, 1));
    request.destroy(new Error("aborted"));

    await expect(write).rejects.toThrow("aborted");
    expect(readdirSync(tmpDir)).toEqual([]);

    // iOS resends a dropped background upload to the same URL.
    const body = generatedBody(10 * MIB);
    const resent = await writeUploadContent({
      config,
      workspaceId: "ws-1",
      uploadId: record.id,
      req: requestFrom(body.stream),
    });
    expect(resent).toMatchObject({ status: "complete", sizeBytes: 10 * MIB, sha256: body.digest() });
  });

  it("removes a created upload nothing wrote to for an hour, and crash-leftover partial files", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-abandoned-"));
    volume.current = { totalBytes: 1000 * GIB, availableBytes: 500 * GIB };
    const config = storeConfig(root);
    const create = () =>
      createUploadRecord({
        config,
        workspaceId: "ws-1",
        name: "recording.mov",
        mimeType: "video/quicktime",
        sizeBytes: 10 * MIB,
        purpose: "chat_attachment",
      });
    const abandoned = await create();
    const recent = await create();
    writeFileSync(join(config.rootPath, "tmp", `${abandoned.id}.deadbeef.part`), "partial");
    const now = abandoned.updatedAt + 61 * 60 * 1000;
    const recentPath = join(config.rootPath, "records", `${recent.id}.json`);
    writeFileSync(recentPath, JSON.stringify({ ...recent, updatedAt: now - 60_000 }));

    const result = await garbageCollectUploadStore(config, now);

    expect(result).toMatchObject({ removedRecords: 1, removedTmpFiles: 1 });
    expect(existsSync(join(config.rootPath, "records", `${abandoned.id}.json`))).toBe(false);
    expect(existsSync(recentPath)).toBe(true);
    expect(readdirSync(join(config.rootPath, "tmp"))).toEqual([]);
  });

  it("stops a body that runs past its declared size before writing the excess", async () => {
    root = mkdtempSync(join(tmpdir(), "oppi-upload-limits-overrun-"));
    volume.current = { totalBytes: 1000 * GIB, availableBytes: 500 * GIB };
    const config = storeConfig(root);
    const record = await createUploadRecord({
      config,
      workspaceId: "ws-1",
      name: "notes.txt",
      mimeType: "text/plain",
      sizeBytes: 5,
      purpose: "chat_attachment",
    });

    await expect(
      writeUploadContent({
        config,
        workspaceId: "ws-1",
        uploadId: record.id,
        req: requestFrom(Readable.from([Buffer.from("hello"), Buffer.from(" world")])),
      }),
    ).rejects.toMatchObject({ status: 400, message: "Upload size mismatch: expected 5, got more" });
    expect(readdirSync(join(config.rootPath, "tmp"))).toEqual([]);
  });
});

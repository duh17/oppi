import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const gc = vi.hoisted(() => ({
  finished: false,
  release: undefined as (() => void) | undefined,
}));

// The pass the server starts at boot creates the upload store's directories. Hold it open
// so the test controls when it ends.
vi.mock("../src/uploads/local-upload-store.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/uploads/local-upload-store.js")>()),
  garbageCollectUploadStore: vi.fn(async () => {
    await new Promise<void>((resolve) => {
      gc.release = resolve;
    });
    gc.finished = true;
    return { removedRecords: 0, removedTmpFiles: 0, removedBlobs: 0 };
  }),
}));

const { Server } = await import("../src/server.js");
const { Storage } = await import("../src/storage.js");

describe("Server.stop", () => {
  let dataDir: string | undefined;

  afterEach(() => {
    gc.release?.();
    gc.release = undefined;
    gc.finished = false;
    if (dataDir) rmSync(dataDir, { recursive: true, force: true });
    dataDir = undefined;
  });

  it("waits for the upload GC pass in flight, so nothing writes into the data dir after it returns", async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-stop-upload-gc-"));
    const storage = new Storage(dataDir);
    storage.updateConfig({ port: 0, host: "127.0.0.1", tls: { mode: "self-signed" } });
    storage.ensurePaired();
    const server = new Server(storage);
    await server.start();
    expect(gc.release).toBeDefined();

    let stopped = false;
    const stopping = server.stop().then(() => {
      stopped = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 750));
    expect(stopped).toBe(false);

    gc.release?.();
    await stopping;
    expect(gc.finished).toBe(true);
  }, 30_000);
});

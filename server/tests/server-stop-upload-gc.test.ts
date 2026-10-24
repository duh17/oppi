import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hasOpenSSL, logSkip } from "./harness/cli-test-env.js";

const gc = vi.hoisted(() => ({
  events: [] as string[],
  release: undefined as (() => void) | undefined,
}));

// The pass the server starts at boot creates the upload store's directories. Hold it open
// so the test decides when it ends.
vi.mock("../src/uploads/local-upload-store.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/uploads/local-upload-store.js")>()),
  garbageCollectUploadStore: vi.fn(async () => {
    await new Promise<void>((resolve) => {
      gc.release = resolve;
    });
    gc.events.push("gc finished");
    return { removedRecords: 0, removedTmpFiles: 0, removedBlobs: 0 };
  }),
}));

const { Server } = await import("../src/server.js");
const { Storage } = await import("../src/storage.js");

/** Resolves true once `condition` holds, false at the deadline. */
async function waitUntil(condition: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return condition();
}

describe.skipIf(logSkip(!hasOpenSSL, "server-stop-upload-gc", "openssl is not available"))(
  "Server.stop",
  () => {
    let dataDir: string | undefined;

    afterEach(() => {
      gc.release?.();
      gc.release = undefined;
      gc.events.length = 0;
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

      const stopping = server.stop().then(() => {
        gc.events.push("stop resolved");
      });

      // Every other shutdown step ends with the network listener closing. Without the
      // wait that happens on its own, so stop() resolves before the pass is released.
      // With it, the listener stays up while the pass is held, and this deadline passes.
      await waitUntil(() => !server.remoteAvailable, 2_500);
      gc.events.push("released");
      gc.release?.();
      await stopping;

      expect(gc.events).toEqual(["released", "gc finished", "stop resolved"]);
    }, 30_000);
  },
);

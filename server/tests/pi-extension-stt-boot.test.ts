import { afterEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { TranscriptionHost } from "../src/pi-extension-stt-host.js";

const tempDirs: string[] = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function writePackage(dir: string, files: Record<string, string>): string {
  mkdirSync(dir, { recursive: true });
  for (const [rel, contents] of Object.entries(files)) {
    const path = join(dir, rel);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, contents);
  }
  return dir;
}

type ServerDictationInternals = {
  createDictationManager: () => unknown;
  getTranscriptionHost: () => Promise<TranscriptionHost>;
  dictationConfig: { backend?: string; sttEndpoint?: string } | undefined;
  searchIndex: { close: () => void } | null;
};

describe("Server pi-extension dictation boot enablement", () => {
  it("keeps dictation available so a post-boot host install can serve", async () => {
    const dataDir = tempDir("oppi-stt-boot-");
    const pkgDir = join(dataDir, "stt-pkg");
    const storage = new Storage(dataDir);
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "disabled" },
      asr: {
        backend: "pi-extension",
        extension: pkgDir,
        sttEndpoint: "http://127.0.0.1:7936",
      },
    });

    const server = new Server(storage) as unknown as ServerDictationInternals;
    try {
      expect(server.dictationConfig?.backend).toBe("pi-extension");
      expect(server.dictationConfig?.sttEndpoint).toBeUndefined();
      expect(server.createDictationManager()).toBeDefined();

      writePackage(pkgDir, {
        "package.json": JSON.stringify({
          name: "fake-stt",
          type: "module",
          exports: { "./host": "./host.mjs" },
        }),
        "host.mjs": `
          export function createTranscriptionHost() {
            return {
              name: "boot-host",
              model: "boot-model",
              prepare: async () => {},
              createDictation: () => ({
                ready: Promise.resolve(),
                feed: async () => undefined,
                finalize: async () => ({ text: "" }),
                cancel: () => {},
              }),
              shutdown: async () => {},
            };
          }
        `,
      });

      const host = await server.getTranscriptionHost();
      expect(host.name).toBe("boot-host");
      expect(host.model).toBe("boot-model");
    } finally {
      server.searchIndex?.close();
    }
  });
});

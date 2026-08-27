import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { PiExtensionSttProvider } from "../src/pi-extension-stt-provider.js";
import {
  importTranscriptionHost,
  resolvePiExtensionHostExport,
} from "../src/pi-extension-stt-host.js";
import type {
  DictationStream,
  TranscriptionHost,
  TranscriptUpdate,
} from "../src/pi-extension-stt-host.js";

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

function s16le(samples: number[]): Buffer {
  const buf = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    buf.writeInt16LE(samples[i]!, i * 2);
  }
  return buf;
}

function createFakeStream(opts?: {
  onFeed?: (
    pcm: Float32Array,
  ) => Promise<TranscriptUpdate | undefined> | TranscriptUpdate | undefined;
  onFinalize?: () => Promise<TranscriptUpdate> | TranscriptUpdate;
  onCancel?: () => void;
}): DictationStream {
  return {
    ready: Promise.resolve(),
    feed: async (pcm) => opts?.onFeed?.(pcm),
    finalize: async () =>
      opts?.onFinalize?.() ?? { text: "final", committedText: "final", activeText: "" },
    cancel: () => opts?.onCancel?.(),
  };
}

function createFakeHost(opts?: {
  model?: string;
  prepare?: () => Promise<void>;
  createDictation?: () => DictationStream;
}): TranscriptionHost & { createCount: number } {
  const host = {
    name: "fake-host",
    model: opts?.model ?? "fake-model",
    createCount: 0,
    prepare: opts?.prepare ?? (async () => {}),
    createDictation: () => {
      host.createCount += 1;
      if (opts?.createDictation) return opts.createDictation();
      return createFakeStream();
    },
    shutdown: async () => {},
  };
  return host;
}

describe("resolvePiExtensionHostExport", () => {
  it("resolves an absolute package directory that exports ./host", () => {
    const dir = writePackage(join(tempDir("oppi-stt-host-"), "pkg"), {
      "package.json": JSON.stringify({
        name: "fake-stt",
        type: "module",
        exports: { "./host": "./host.mjs" },
      }),
      "host.mjs": "export function createTranscriptionHost() { return {}; }\n",
    });

    const resolved = resolvePiExtensionHostExport(dir);
    expect(resolved?.packageDir).toBe(dir);
    expect(resolved?.hostPath).toBe(join(dir, "host.mjs"));
  });

  it("resolves a package name from the Pi npm package store", () => {
    const store = tempDir("oppi-stt-store-");
    const pkgDir = writePackage(join(store, "@earendil-works", "pi-transcribe"), {
      "package.json": JSON.stringify({
        name: "@earendil-works/pi-transcribe",
        type: "module",
        exports: { "./host": "./host.mjs" },
      }),
      "host.mjs": "export function createTranscriptionHost() { return {}; }\n",
    });

    const resolved = resolvePiExtensionHostExport("@earendil-works/pi-transcribe", {
      packageStoreDir: store,
    });
    expect(resolved?.packageDir).toBe(pkgDir);
  });

  it("resolves an npm: spec from the Pi npm package store", () => {
    const store = tempDir("oppi-stt-npm-");
    writePackage(join(store, "pi-transcribe"), {
      "package.json": JSON.stringify({
        name: "pi-transcribe",
        type: "module",
        exports: { "./host": { import: "./host.mjs" } },
      }),
      "host.mjs": "export function createTranscriptionHost() { return {}; }\n",
    });

    const resolved = resolvePiExtensionHostExport("npm:pi-transcribe", {
      packageStoreDir: store,
    });
    expect(resolved?.packageDir).toBe(join(store, "pi-transcribe"));
  });

  it("does not resolve a package directory that lacks a ./host export", () => {
    const dir = writePackage(join(tempDir("oppi-stt-nohost-"), "pkg"), {
      "package.json": JSON.stringify({
        name: "fake-stt",
        type: "module",
        exports: { ".": "./index.mjs" },
      }),
      "index.mjs": "export function createTuiExtension() { return {}; }\n",
    });

    expect(resolvePiExtensionHostExport(dir)).toBeUndefined();
  });

  it("rejects a Node subpath spec", () => {
    expect(resolvePiExtensionHostExport("@earendil-works/pi-transcribe/host")).toBeUndefined();
    expect(resolvePiExtensionHostExport("npm:@earendil-works/pi-transcribe/host")).toBeUndefined();
  });

  it("rejects a TUI entry spec", () => {
    expect(resolvePiExtensionHostExport("./extensions/transcribe.ts")).toBeUndefined();
    expect(resolvePiExtensionHostExport("extensions/transcribe.ts")).toBeUndefined();
    expect(
      resolvePiExtensionHostExport("@earendil-works/pi-transcribe/dist/extension.js"),
    ).toBeUndefined();
  });
});

describe("importTranscriptionHost", () => {
  it("fails closed when createTranscriptionHost is missing", async () => {
    const dir = writePackage(join(tempDir("oppi-stt-missing-factory-"), "pkg"), {
      "package.json": JSON.stringify({
        name: "fake-stt",
        type: "module",
        exports: { "./host": "./host.mjs" },
      }),
      "host.mjs": "export const notAHost = true;\n",
    });

    await expect(importTranscriptionHost(dir)).rejects.toThrow(/createTranscriptionHost/i);
  });

  it("does not import the package main / TUI factory", async () => {
    const dir = writePackage(join(tempDir("oppi-stt-no-tui-"), "pkg"), {
      "package.json": JSON.stringify({
        name: "fake-stt",
        type: "module",
        exports: {
          ".": "./tui.mjs",
          "./host": "./host.mjs",
        },
      }),
      "tui.mjs": `throw new Error("TUI factory must not load");\n`,
      "host.mjs": `
        export function createTranscriptionHost() {
          return {
            name: "host-only",
            model: "host-model",
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

    const host = await importTranscriptionHost(dir);
    expect(host.name).toBe("host-only");
    expect(host.model).toBe("host-model");
  });
});

describe("PiExtensionSttProvider", () => {
  it("converts s16le audio and forwards committed/active updates", async () => {
    const feeds: number[][] = [];
    const host = createFakeHost({
      createDictation: () =>
        createFakeStream({
          onFeed: (pcm) => {
            feeds.push(Array.from(pcm));
            return {
              text: "hello there",
              committedText: "hello",
              activeText: "there",
              snap: true,
            };
          },
        }),
    });

    const provider = new PiExtensionSttProvider({ host });
    expect(provider.name).toBe("pi-extension");
    expect(provider.model).toBe("fake-model");

    const updates: TranscriptUpdate[] = [];
    provider.onToken((update) => updates.push(update));
    await provider.start();
    provider.feedAudio(s16le([32767, -32768, 0]));
    await provider.stop();

    expect(feeds).toHaveLength(1);
    expect(feeds[0]?.[0]).toBeCloseTo(32767 / 32768, 6);
    expect(feeds[0]?.[1]).toBeCloseTo(-1, 6);
    expect(feeds[0]?.[2]).toBe(0);
    expect(updates).toEqual([
      { text: "hello there", committedText: "hello", activeText: "there", snap: true },
    ]);
  });

  it("maps stop() to host finalize() and returns the final transcript", async () => {
    let finalized = 0;
    let cancelled = 0;
    const host = createFakeHost({
      createDictation: () =>
        createFakeStream({
          onFinalize: () => {
            finalized += 1;
            return { text: "done", committedText: "done", activeText: "" };
          },
          onCancel: () => {
            cancelled += 1;
          },
        }),
    });

    const provider = new PiExtensionSttProvider({ host });
    await provider.start();
    const result = await provider.stop();

    expect(finalized).toBe(1);
    expect(cancelled).toBe(0);
    expect(result).toEqual({ text: "done", committedText: "done", activeText: "" });
  });

  it("serializes host feed() while feedAudio stays sync", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    let releaseFirst: (() => void) | undefined;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    let feeds = 0;

    const host = createFakeHost({
      createDictation: () =>
        createFakeStream({
          onFeed: async () => {
            feeds += 1;
            inFlight += 1;
            maxInFlight = Math.max(maxInFlight, inFlight);
            if (feeds === 1) await firstGate;
            inFlight -= 1;
            return { text: `n${feeds}` };
          },
        }),
    });

    const provider = new PiExtensionSttProvider({ host });
    await provider.start();
    provider.feedAudio(s16le([1]));
    provider.feedAudio(s16le([2]));
    expect(maxInFlight).toBeLessThanOrEqual(1);
    releaseFirst?.();
    await provider.stop();
    expect(maxInFlight).toBe(1);
    expect(feeds).toBe(2);
  });

  it("fails start() when prepare() fails", async () => {
    const host = createFakeHost({
      prepare: async () => {
        throw new Error("model missing");
      },
    });
    const provider = new PiExtensionSttProvider({ host });
    await expect(provider.start()).rejects.toThrow(/model missing/);
  });

  it("rejects a second live createDictation() on a shared host", async () => {
    let live = false;
    const host = createFakeHost({
      createDictation: () => {
        if (live) throw new Error("Dictation already active");
        live = true;
        return createFakeStream({
          onFinalize: () => {
            live = false;
            return { text: "done" };
          },
          onCancel: () => {
            live = false;
          },
        });
      },
    });

    const first = new PiExtensionSttProvider({ host });
    const second = new PiExtensionSttProvider({ host });
    await first.start();
    await expect(second.start()).rejects.toThrow(/already active/i);
    await first.stop();
  });

  it("releases an in-flight start so a later provider can createDictation()", async () => {
    let live = false;
    let releasePrepare: (() => void) | undefined;
    const prepareGate = new Promise<void>((resolve) => {
      releasePrepare = resolve;
    });
    const host = createFakeHost({
      prepare: async () => {
        await prepareGate;
      },
      createDictation: () => {
        if (live) throw new Error("Dictation already active");
        live = true;
        return createFakeStream({
          onFinalize: () => {
            live = false;
            return { text: "done" };
          },
          onCancel: () => {
            live = false;
          },
        });
      },
    });

    const first = new PiExtensionSttProvider({ host });
    const starting = first.start();
    const stopping = first.stop();
    releasePrepare?.();
    await Promise.all([starting, stopping]);

    const second = new PiExtensionSttProvider({ host });
    await expect(second.start()).resolves.toBeUndefined();
    await second.stop();
  });

  it("loads a host through getHost() only in start(), not the constructor", async () => {
    let loaded = 0;
    const host = createFakeHost();
    const provider = new PiExtensionSttProvider({
      getHost: async () => {
        loaded += 1;
        return host;
      },
    });
    expect(loaded).toBe(0);
    expect(provider.name).toBe("pi-extension");
    await provider.start();
    expect(loaded).toBe(1);
    await provider.stop();
  });
});

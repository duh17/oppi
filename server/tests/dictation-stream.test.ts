import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { isDictationStreamEnabled } from "../src/dictation-types.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

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

type ServerDictationInternals = {
  createDictationManager: () => unknown;
  dictationConfig: { backend?: string; provider?: string; sttEndpoint?: string } | undefined;
  searchIndex: { close: () => void } | null;
};

describe("isDictationStreamEnabled", () => {
  it("is true when sttEndpoint is non-empty", () => {
    expect(isDictationStreamEnabled({ sttEndpoint: "http://127.0.0.1:7936" })).toBe(true);
  });

  it("is false when asr is missing or sttEndpoint is blank", () => {
    expect(isDictationStreamEnabled(undefined)).toBe(false);
    expect(isDictationStreamEnabled({})).toBe(false);
    expect(isDictationStreamEnabled({ sttEndpoint: "  " })).toBe(false);
  });

  it("only enables xai without sttEndpoint", () => {
    expect(isDictationStreamEnabled({ provider: "openai-codex" })).toBe(false);
    expect(isDictationStreamEnabled({ provider: "openai" })).toBe(false);
    expect(
      isDictationStreamEnabled({ provider: "openai-codex", sttEndpoint: "https://api.openai.com" }),
    ).toBe(false);
    expect(isDictationStreamEnabled({ provider: "xai" })).toBe(true);
  });

  it("infers xai from its official API host", () => {
    expect(isDictationStreamEnabled({ sttEndpoint: "https://api.x.ai" })).toBe(true);
  });

  it("does not treat pi-extension as available", () => {
    expect(
      isDictationStreamEnabled({
        backend: "pi-extension",
        extension: "@earendil-works/pi-transcribe",
      }),
    ).toBe(false);
  });

  it("still enables HTTP when sttEndpoint is set next to leftover pi-extension keys", () => {
    expect(
      isDictationStreamEnabled({
        backend: "pi-extension",
        extension: "@earendil-works/pi-transcribe",
        sttEndpoint: "http://127.0.0.1:7936",
      }),
    ).toBe(true);
  });
});

describe("Server HTTP dictation boot enablement", () => {
  it("enables dictation from asr.sttEndpoint", () => {
    const dataDir = tempDir("oppi-stt-http-boot-");
    const storage = new Storage(dataDir);
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "disabled" },
      asr: { sttEndpoint: "http://127.0.0.1:7936" },
    });

    const server = new Server(storage) as unknown as ServerDictationInternals;
    try {
      expect(server.dictationConfig?.backend).toBe("http");
      expect(server.dictationConfig?.sttEndpoint).toBe("http://127.0.0.1:7936");
      expect(server.createDictationManager()).toBeDefined();
    } finally {
      server.searchIndex?.close();
    }
  });

  it("enables dictation from asr.provider xai without sttEndpoint", () => {
    const dataDir = tempDir("oppi-stt-xai-boot-");
    const storage = new Storage(dataDir);
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "disabled" },
      asr: { provider: "xai" },
    });

    const server = new Server(storage) as unknown as ServerDictationInternals;
    try {
      expect(server.dictationConfig?.provider).toBe("xai");
      expect(server.createDictationManager()).toBeDefined();
    } finally {
      server.searchIndex?.close();
    }
  });

  it("does not enable dictation from leftover pi-extension asr without sttEndpoint", () => {
    const dataDir = tempDir("oppi-stt-pi-boot-");
    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        ...Storage.getDefaultConfig(dataDir),
        host: "127.0.0.1",
        port: 0,
        tls: { mode: "disabled" },
        asr: {
          backend: "pi-extension",
          extension: "@earendil-works/pi-transcribe",
        },
      }),
    );

    const storage = new Storage(dataDir);
    const server = new Server(storage) as unknown as ServerDictationInternals;
    try {
      expect(storage.getConfig().asr).toBeUndefined();
      expect(server.dictationConfig).toBeUndefined();
      expect(server.createDictationManager()).toBeUndefined();
    } finally {
      server.searchIndex?.close();
    }
  });
});

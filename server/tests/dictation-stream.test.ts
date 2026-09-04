import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { isDictationStreamEnabled } from "../src/dictation-types.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { makeResponse } from "./harness/route-test-helpers.js";

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

async function getServerInfo(asr: unknown): Promise<{
  dictationStream?: { version: number };
}> {
  const ctx = {
    storage: {
      getConfig: () => ({
        configVersion: 2,
        asr,
        uploadStore: { maxFileBytes: 1, maxTurnBytes: 2 },
        images: { autoResize: false },
      }),
      listWorkspaces: () => [],
      listSessions: () => [],
      getDataDir: () => tempDirs[0] ?? tmpdir(),
    },
    sessions: { getActiveSessionIds: () => new Set() },
    sessionRuntimes: { getActiveSessionIds: () => new Set() },
    skillRegistry: { list: () => [] },
    getModelCatalog: () => [],
    serverStartedAt: Date.now(),
    serverVersion: "test",
    piVersion: "test",
  } as unknown as RouteContext;

  const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
  const res = makeResponse();
  const handled = await dispatch({
    method: "GET",
    path: "/server/info",
    url: new URL("http://localhost/server/info"),
    req: {} as never,
    res: res as never,
  });
  expect(handled).toBe(true);
  expect(res.statusCode).toBe(200);
  const body = JSON.parse(res.body) as {
    capabilities: { dictationStream?: { version: number } };
  };
  return body.capabilities;
}

type ServerDictationInternals = {
  createDictationManager: () => unknown;
  dictationConfig: { backend?: string; sttEndpoint?: string } | undefined;
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

describe("GET /server/info dictationStream", () => {
  it("advertises when omitted backend has a non-empty sttEndpoint", async () => {
    const capabilities = await getServerInfo({ sttEndpoint: "http://127.0.0.1:7936" });
    expect(capabilities.dictationStream).toEqual({ version: 1 });
  });

  it("does not advertise a pi-extension backend without sttEndpoint", async () => {
    const capabilities = await getServerInfo({
      backend: "pi-extension",
      extension: "@earendil-works/pi-transcribe",
    });
    expect(capabilities.dictationStream).toBeUndefined();
  });

  it("advertises HTTP when sttEndpoint is set even if leftover backend is pi-extension", async () => {
    const capabilities = await getServerInfo({
      backend: "pi-extension",
      extension: "@earendil-works/pi-transcribe",
      sttEndpoint: "http://127.0.0.1:7936",
    });
    expect(capabilities.dictationStream).toEqual({ version: 1 });
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

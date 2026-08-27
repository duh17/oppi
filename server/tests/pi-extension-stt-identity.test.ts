import { afterEach, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeResponse } from "./harness/route-test-helpers.js";

const tempDirs: string[] = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

function writePackage(files: Record<string, string>): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-stt-identity-"));
  tempDirs.push(dir);
  for (const [rel, contents] of Object.entries(files)) {
    const path = join(dir, rel);
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, contents);
  }
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

describe("GET /server/info dictationStream", () => {
  it("advertises when omitted backend has a non-empty sttEndpoint", async () => {
    const capabilities = await getServerInfo({ sttEndpoint: "http://127.0.0.1:7936" });
    expect(capabilities.dictationStream).toEqual({ version: 1 });
  });

  it("advertises when backend is pi-extension and the package exports ./host", async () => {
    const dir = writePackage({
      "package.json": JSON.stringify({
        name: "fake-stt",
        type: "module",
        exports: { "./host": "./host.mjs" },
      }),
      "host.mjs": `
        import { writeFileSync } from "node:fs";
        writeFileSync(new URL("./loaded", import.meta.url), "imported");
        export function createTranscriptionHost() {
          writeFileSync(new URL("./created", import.meta.url), "created");
          return {
            name: "fake",
            model: "fake-model",
            prepare: async () => {
              writeFileSync(new URL("./prepared", import.meta.url), "prepared");
            },
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

    const capabilities = await getServerInfo({
      backend: "pi-extension",
      extension: dir,
      sttEndpoint: "http://127.0.0.1:7936",
    });
    expect(capabilities.dictationStream).toEqual({ version: 1 });
    expect(existsSync(join(dir, "loaded"))).toBe(false);
    expect(existsSync(join(dir, "created"))).toBe(false);
    expect(existsSync(join(dir, "prepared"))).toBe(false);
  });

  it("does not advertise when backend is pi-extension and ./host is missing", async () => {
    const dir = writePackage({
      "package.json": JSON.stringify({
        name: "fake-stt",
        type: "module",
        exports: { ".": "./tui.mjs" },
      }),
      "tui.mjs": "export function createTuiExtension() { return {}; }\n",
    });

    const capabilities = await getServerInfo({
      backend: "pi-extension",
      extension: dir,
      sttEndpoint: "http://127.0.0.1:7936",
    });
    expect(capabilities.dictationStream).toBeUndefined();
  });

  it("does not advertise a pi-extension backend that has no resolvable extension", async () => {
    const capabilities = await getServerInfo({
      backend: "pi-extension",
      extension: "@earendil-works/missing-stt-package",
    });
    expect(capabilities.dictationStream).toBeUndefined();
  });
});

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as PiSdk from "@earendil-works/pi-coding-agent";

import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "../src/oppi-cli-prompt.js";
import { buildOppiSystemPromptAppend } from "../src/oppi-docs.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createPromptHintSettingsRoutes } from "../src/routes/prompt-hint-settings.js";
import type { RouteContext } from "../src/routes/types.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let dataDir: string;
let cwd: string;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-prompt-hints-"));
  cwd = mkdtempSync(join(tmpdir(), "oppi-prompt-hints-ws-"));
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(cwd, { recursive: true, force: true });
});

const configPath = () => join(dataDir, "config.json");
const onDisk = () => JSON.parse(readFileSync(configPath(), "utf8")) as Record<string, unknown>;

/** A config.json as a server from before the hints were opt-in left it: no hint keys. */
function writeLegacyConfig(extra: Record<string, unknown> = {}) {
  const {
    oppiDocsPrompt: _docs,
    oppiCliPrompt: _cli,
    ...legacy
  } = Storage.getDefaultConfig(dataDir);
  writeFileSync(configPath(), JSON.stringify({ ...legacy, ...extra }, null, 2));
}

/** What a new host session on this storage appends to Pi's system prompt. */
async function hostSessionAppends(storage: Storage): Promise<string[]> {
  const session: Session = {
    id: `sess-${Date.now()}`,
    workspaceId: "w1",
    status: "starting",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
  const backend = await SdkBackend.create({
    session,
    workspace: { id: "w1", name: "Hints", runtime: "host", hostMount: cwd } as Workspace,
    getPromptHints: () => storage.getConfig(),
    onEvent: () => {},
    onEnd: () => {},
  });
  try {
    const loader = (
      backend as unknown as { runtime: { services: { resourceLoader: PiSdk.ResourceLoader } } }
    ).runtime.services.resourceLoader;
    return loader.getAppendSystemPrompt();
  } finally {
    await backend.dispose();
  }
}

describe("prompt hints are opt-in", () => {
  it("a new server saves both hints off and a new session gets neither", async () => {
    const storage = new Storage(dataDir);

    expect(onDisk()).toMatchObject({
      oppiDocsPrompt: { enabled: false },
      oppiCliPrompt: { enabled: false },
    });
    expect(await hostSessionAppends(storage)).toEqual([]);
  });

  it("a server that never chose keeps both hints on, saved once as its choice", async () => {
    writeLegacyConfig();
    const storage = new Storage(dataDir);

    expect(onDisk()).toMatchObject({
      oppiDocsPrompt: { enabled: true },
      oppiCliPrompt: { enabled: true },
    });
    expect(await hostSessionAppends(storage)).toEqual([
      buildOppiSystemPromptAppend(),
      OPPI_CLI_SYSTEM_PROMPT_HINT,
    ]);

    // Saved, so turning one off sticks across restarts rather than migrating again.
    storage.mutateConfig(() => ({ oppiDocsPrompt: { enabled: false } }));
    expect(new Storage(dataDir).getConfig()).toMatchObject({
      oppiDocsPrompt: { enabled: false },
      oppiCliPrompt: { enabled: true },
    });
  });

  it("keeps a saved choice as it is", async () => {
    writeLegacyConfig({
      oppiDocsPrompt: { enabled: false, revision: 3 },
      oppiCliPrompt: { enabled: true },
    });
    const before = readFileSync(configPath(), "utf8");
    const storage = new Storage(dataDir);

    expect(readFileSync(configPath(), "utf8")).toBe(before);
    expect(await hostSessionAppends(storage)).toEqual([OPPI_CLI_SYSTEM_PROMPT_HINT]);
  });
});

describe("/server/oppi-docs-prompt and /server/oppi-cli-prompt", () => {
  async function call(storage: Storage, method: string, path: string, body?: unknown) {
    const dispatch = createPromptHintSettingsRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const res = makeResponse();
    const handled = await dispatch({
      method,
      path,
      url: new URL(`http://localhost${path}`),
      req: makeRequest(body),
      res: res as never,
    });
    expect(handled).toBe(true);
    return { status: res.statusCode, json: JSON.parse(res.body) as Record<string, unknown> };
  }

  it("saves each hint with a revision, applies it to the next session, and refuses a stale write", async () => {
    const storage = new Storage(dataDir);
    const docs = "/server/oppi-docs-prompt";
    const cli = "/server/oppi-cli-prompt";

    expect((await call(storage, "GET", docs)).json).toEqual({ enabled: false, revision: 0 });
    expect((await call(storage, "PUT", docs, { enabled: true, baseRevision: 0 })).json).toEqual({
      enabled: true,
      revision: 1,
    });
    expect((await call(storage, "GET", cli)).json).toEqual({ enabled: false, revision: 0 });
    expect(await hostSessionAppends(storage)).toEqual([buildOppiSystemPromptAppend()]);

    expect(await call(storage, "PUT", docs, { enabled: false, baseRevision: 0 })).toEqual({
      status: 409,
      json: {
        error: "Oppi Docs Hint setting changed",
        code: "revision_conflict",
        current: { enabled: true, revision: 1 },
      },
    });
    expect((await call(storage, "PUT", cli, { enabled: "yes" })).status).toBe(400);
    expect(new Storage(dataDir).getConfig()).toMatchObject({
      oppiDocsPrompt: { enabled: true, revision: 1 },
      oppiCliPrompt: { enabled: false },
    });
  });
});

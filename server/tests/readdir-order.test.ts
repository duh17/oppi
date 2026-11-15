/**
 * Node's readdir returns names in byte order; Bun's returns directory order. These tests hand the
 * code under test every listing in reverse, as an unsorted runtime may, and check that what the
 * user sees (and which "last one wins") is still Node's order.
 */
import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>();
  return {
    ...actual,
    readdirSync: ((...args: Parameters<typeof actual.readdirSync>) =>
      (actual.readdirSync(...args) as unknown[]).reverse()) as typeof actual.readdirSync,
  };
});

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    readdir: (async (...args: Parameters<typeof actual.readdir>) =>
      ((await actual.readdir(...args)) as unknown[]).reverse()) as typeof actual.readdir,
  };
});

import { compareDirEntryNames } from "../src/dir-order.js";
import { listDirectoryEntries } from "../src/directory-listing.js";
import { discoverLocalSessions, invalidateLocalSessionsCache } from "../src/local-sessions.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createThemeRoutes } from "../src/routes/themes.js";
import type { RouteContext } from "../src/routes/types.js";
import { ConfigStore } from "../src/storage/config-store.js";
import { WorkspaceStore } from "../src/storage/workspace-store.js";
import { makeResponse } from "./harness/route-test-helpers.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "oppi-readdir-order-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("compareDirEntryNames", () => {
  it("orders names as the bytes of their UTF-8 encodings do", () => {
    const names = [
      "b",
      "a",
      "B",
      "_x",
      "10",
      "9",
      "é",
      "ä",
      "a.json",
      "a-b.json",
      "\uFFFD",
      "😀",
      "",
    ];
    const byBytes = [...names].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    expect([...names].sort(compareDirEntryNames)).toEqual(byBytes);
  });
});

describe("listings do not depend on the runtime's readdir order", () => {
  it("lists user themes in filename order", async () => {
    const themes = join(dir, "themes");
    mkdirSync(themes);
    for (const name of ["delta", "alpha", "charlie", "bravo"]) {
      writeFileSync(join(themes, `${name}.json`), JSON.stringify({ name, colorScheme: "dark" }));
    }
    const ctx = { storage: { getDataDir: () => dir } } as unknown as RouteContext;
    const res = makeResponse();
    await createThemeRoutes(
      ctx,
      createRouteHelpers(),
    )({
      method: "GET",
      path: "/themes",
      url: new URL("http://localhost/themes"),
      req: {} as never,
      res: res as never,
    });

    const { themes: listed } = JSON.parse(res.body) as {
      themes: { filename: string; source: string }[];
    };
    expect(listed.filter((t) => t.source === "user").map((t) => t.filename)).toEqual([
      "alpha",
      "bravo",
      "charlie",
      "delta",
    ]);
  });

  it("lets the last mobile renderer file in filename order win a shared tool name", async () => {
    for (const file of ["a.ts", "c.ts", "b.ts"]) {
      writeFileSync(
        join(dir, file),
        `export default { bash: {
          renderCall() { return [{ text: ${JSON.stringify(file)} }]; },
          renderResult() { return []; },
        } };`,
      );
    }
    const registry = new MobileRendererRegistry();
    await registry.loadAllRenderers(dir);

    expect(registry.renderCall("bash", {})?.map((s) => s.text)).toEqual(["c.ts"]);
  });

  it("lists workspaces created in the same millisecond in filename order", () => {
    const configStore = new ConfigStore(dir);
    const workspacesDir = configStore.getWorkspacesDir();
    for (const id of ["w-delta", "w-alpha", "w-charlie", "w-bravo"]) {
      writeFileSync(
        join(workspacesDir, `${id}.json`),
        JSON.stringify({
          id,
          name: id,
          hostMount: join(dir, id),
          runtime: "host",
          createdAt: 1_700_000_000_000,
          updatedAt: 1_700_000_000_000,
        }),
      );
    }

    expect(new WorkspaceStore(configStore).listWorkspaces().map((w) => w.id)).toEqual([
      "w-alpha",
      "w-bravo",
      "w-charlie",
      "w-delta",
    ]);
  });

  it("pages a directory listing in name order, not an arbitrary 1000 first", async () => {
    const root = join(dir, "big");
    mkdirSync(root);
    const names = Array.from({ length: 1005 }, (_, i) => `f${String(i).padStart(4, "0")}`);
    for (const name of names.toReversed()) writeFileSync(join(root, name), "");

    const first = await listDirectoryEntries(root, ".");
    expect(first.kind === "ok" && first.entries.map((e) => e.name)).toEqual(names.slice(0, 1000));
    expect(first.kind === "ok" && first.next).toBe("f0999");
    const rest = await listDirectoryEntries(root, ".", { after: "f0999" });
    expect(rest).toMatchObject({ kind: "ok", next: null });
    expect(rest.kind === "ok" && rest.entries.map((e) => e.name)).toEqual(names.slice(1000));
  });

  describe("local sessions", () => {
    const savedRoot = process.env.OPPI_LOCAL_SESSIONS_ROOT;

    afterEach(() => {
      if (savedRoot === undefined) delete process.env.OPPI_LOCAL_SESSIONS_ROOT;
      else process.env.OPPI_LOCAL_SESSIONS_ROOT = savedRoot;
      invalidateLocalSessionsCache();
    });

    it("lists sessions with the same modified time in path order", async () => {
      process.env.OPPI_LOCAL_SESSIONS_ROOT = dir;
      invalidateLocalSessionsCache();
      const cwdDir = join(dir, "project");
      mkdirSync(cwdDir);
      const when = new Date("2026-02-20T00:00:00.000Z");
      const paths = ["c", "a", "b"].map((id) =>
        join(cwdDir, `2026-02-20T00-00-00-000Z_${id}.jsonl`),
      );
      for (const [i, path] of paths.entries()) {
        const id = ["c", "a", "b"][i];
        writeFileSync(
          path,
          `${JSON.stringify({ type: "session", version: 3, id, timestamp: when.toISOString(), cwd: cwdDir })}\n`,
        );
        utimesSync(path, when, when);
      }

      const sessions = await discoverLocalSessions();

      expect(sessions.map((s) => s.piSessionId)).toEqual(["a", "b", "c"]);
    });
  });
});

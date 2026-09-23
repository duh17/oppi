import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { createDictationDictionaryRoutes } from "../src/routes/dictation-dictionary.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

describe("authenticated dictation dictionary HTTP boundary", () => {
  it("shares global and workspace lists and refuses unknown workspaces and stale edits", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dictionary-route-"));
    const ctx = {
      storage: {
        getDataDir: () => dir,
        getWorkspace: (id: string) => (id === "w1" || id === "w2" ? { id } : undefined),
        getConfig: () => ({ asr: { provider: "xai" } }),
      },
    } as unknown as RouteContext;
    const route = createDictationDictionaryRoutes(ctx, createRouteHelpers());
    async function call(method: string, path: string, body?: unknown) {
      const res = makeResponse();
      const handled = await route({
        method,
        path,
        url: new URL(`http://localhost${path}`),
        req: makeRequest(body),
        res: res as never,
      });
      expect(handled).toBe(true);
      return { status: res.statusCode, json: JSON.parse(res.body) as Record<string, unknown> };
    }
    expect(
      (await call("POST", "/dictation/dictionary/global", { phrase: "Duh Ifone" })).json,
    ).toMatchObject({ phrases: ["Duh Ifone"], revision: 1, added: 1, skipped: [] });
    expect(
      (await call("POST", "/dictation/dictionary/workspaces/w1", { phrase: "Yuwp" })).status,
    ).toBe(200);
    expect((await call("GET", "/dictation/dictionary/workspaces/w2")).json.phrases).toEqual([]);
    expect((await call("GET", "/dictation/dictionary/global")).json).toMatchObject({
      phrases: ["Duh Ifone"],
      provider: "xai",
    });
    expect(
      (await call("POST", "/dictation/dictionary/workspaces/unknown", { phrase: "bad" })).status,
    ).toBe(404);
    expect(
      (await call("PUT", "/dictation/dictionary/workspaces/w1", { revision: 0, phrases: [] }))
        .status,
    ).toBe(409);
    expect((await call("DELETE", "/dictation/dictionary/workspaces/w1", {})).status).toBe(200);
    expect((await call("GET", "/dictation/dictionary/workspaces/w1")).json.phrases).toEqual([]);
    expect((await call("GET", "/dictation/dictionary/global")).json.phrases).toEqual(["Duh Ifone"]);
  });

  it("accepts a 100-phrase POST and reports partial overflow without losing saved entries", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dictionary-bulk-route-"));
    const ctx = {
      storage: {
        getDataDir: () => dir,
        getConfig: () => ({ asr: { provider: "xai" } }),
      },
    } as unknown as RouteContext;
    const route = createDictationDictionaryRoutes(ctx, createRouteHelpers());
    async function post(body: unknown) {
      const res = makeResponse();
      await route({
        method: "POST",
        path: "/dictation/dictionary/global",
        url: new URL("http://localhost/dictation/dictionary/global"),
        req: makeRequest(body),
        res: res as never,
      });
      return { status: res.statusCode, json: JSON.parse(res.body) as Record<string, unknown> };
    }
    const phrases = Array.from({ length: 100 }, (_, i) => `${i} ${"x".repeat(254)}`.slice(0, 256));
    const first = await post({ phrases }); // JSON exceeds the old 2 KiB POST body limit.
    expect(first.status).toBe(200);
    expect(first.json).toMatchObject({ phrases, revision: 1, added: 100, skipped: [] });
    const overflow = await post({ phrases: [phrases[0], "new", "é".repeat(129)] });
    expect(overflow.json).toMatchObject({
      phrases,
      revision: 1,
      added: 0,
      skipped: [
        { phrase: phrases[0], reason: "duplicate" },
        { phrase: "new", reason: "cap" },
        { phrase: "é".repeat(129), reason: "phrase-bytes" },
      ],
    });
    const invalid = await post({ phrases: ["private\ntext"] });
    expect(invalid.status).toBe(400);
    expect(JSON.stringify(invalid.json)).not.toContain("private");
    expect((await post({ phrases: [42] })).status).toBe(400);
    expect((await post({ phrase: "solo", phrases: ["ambiguous"] })).status).toBe(400);
  });
});

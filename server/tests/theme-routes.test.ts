import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createThemeRoutes } from "../src/routes/themes.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

describe("themes module", () => {
  it("returns 404 for nonexistent theme", async () => {
    const ctx = {
      storage: {
        getDataDir: vi.fn(() => "/tmp/oppi-test-nonexistent"),
      },
    } as unknown as RouteContext;

    const dispatch = createThemeRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/themes/ghost",
      url: new URL("http://localhost/themes/ghost"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
  });

  it("lists a user theme once with its absolute file path", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-theme-routes-"));
    try {
      const userThemes = join(dataDir, "themes");
      mkdirSync(userThemes);
      writeFileSync(
        join(userThemes, "tokyo-night.json"),
        JSON.stringify({ name: "My Tokyo", colorScheme: "dark", colors: {} }),
      );
      const ctx = { storage: { getDataDir: () => dataDir } } as unknown as RouteContext;
      const dispatch = createThemeRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "GET",
        path: "/themes",
        url: new URL("http://localhost/themes"),
        req: {} as never,
        res: res as never,
      });

      const { themes } = JSON.parse(res.body) as {
        themes: { filename: string; name: string; source: string; path: string }[];
      };
      const overridden = themes.filter((theme) => theme.filename === "tokyo-night");
      expect(overridden).toEqual([
        {
          name: "My Tokyo",
          filename: "tokyo-night",
          colorScheme: "dark",
          source: "user",
          path: join(userThemes, "tokyo-night.json"),
        },
      ]);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("does not handle theme writes", async () => {
    const ctx = {
      storage: {
        getDataDir: vi.fn(() => "/tmp/oppi-test-nonexistent"),
      },
    } as unknown as RouteContext;

    const dispatch = createThemeRoutes(ctx, createRouteHelpers());

    const handled = await dispatch({
      method: "PUT",
      path: "/themes/my-theme",
      url: new URL("http://localhost/themes/my-theme"),
      req: makeRequest({}) as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });

  it("returns false for unrelated routes", async () => {
    const dispatch = createThemeRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/not/themes",
      url: new URL("http://localhost/not/themes"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });
});

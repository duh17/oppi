import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { apiRouteSpecs } from "../src/routes/registry.js";
import {
  ROUTES_SNAPSHOT_PATH,
  buildRouteRows,
  pathParamNames,
  serializeRouteFixture,
} from "./route-fixtures.js";

describe("route fixture", () => {
  it("matches the committed protocol/routes.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    const committed = readFileSync(ROUTES_SNAPSHOT_PATH, "utf8");
    expect(serializeRouteFixture()).toBe(committed);
  });

  it("lists every registry row once, in registry order", () => {
    const committed = JSON.parse(readFileSync(ROUTES_SNAPSHOT_PATH, "utf8")) as {
      routes: { method: string; path: string }[];
    };
    expect(committed.routes.map((row) => `${row.method} ${row.path}`)).toEqual(
      apiRouteSpecs.map((route) => `${route.method} ${route.path}`),
    );
  });

  it("names every path param the template declares", () => {
    expect(pathParamNames("/workspaces/{workspaceId}/sessions/{sessionId}/tool-output/{toolCallId}")).toEqual(
      ["workspaceId", "sessionId", "toolCallId"],
    );
    expect(pathParamNames("/workspaces/{path+}")).toEqual(["path"]);
    expect(pathParamNames("/workspaces/:workspaceId/sessions")).toEqual(["workspaceId"]);
    expect(pathParamNames("/health")).toEqual([]);
  });

  it("keeps each row's params in step with its path", () => {
    for (const row of buildRouteRows()) {
      const braces = row.path.match(/\{[^}]+\}/g) ?? [];
      expect(row.params.length, `${row.method} ${row.path}`).toBe(braces.length);
    }
  });
});

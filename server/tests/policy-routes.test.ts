import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createPolicyRoutes } from "../src/routes/policy.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeResponse } from "./harness/route-test-helpers.js";

describe("policy module", () => {
  it("handles GET /policy/fallback in isolation", async () => {
    const ctx = {
      gate: {
        getDefaultFallback: vi.fn(() => "ask" as const),
      },
    } as unknown as RouteContext;

    const dispatch = createPolicyRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/policy/fallback",
      url: new URL("http://localhost/policy/fallback"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({ fallback: "ask" });
  });

  it("validates scope on GET /policy/rules", async () => {
    const dispatch = createPolicyRoutes({} as RouteContext, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/policy/rules",
      url: new URL("http://localhost/policy/rules?scope=bad"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({
      error: 'scope must be one of: "session", "workspace", "global"',
    });
  });

  it("returns false for unrelated routes", async () => {
    const dispatch = createPolicyRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/policy/nope",
      url: new URL("http://localhost/policy/nope"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });
});

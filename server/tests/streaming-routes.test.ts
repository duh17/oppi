import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createStreamingRoutes } from "../src/routes/streaming.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRawRequest, makeRequest, makeResponse } from "./harness/route-test-helpers.js";

function makeContext(resolveDecision = vi.fn(() => true)): RouteContext {
  return {
    gate: {
      resolveDecision,
    },
  } as unknown as RouteContext;
}

describe("streaming module", () => {
  it("returns false for unrelated routes", async () => {
    const dispatch = createStreamingRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/definitely/not-streaming",
      url: new URL("http://localhost/definitely/not-streaming"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });

  it("responds to a permission request with default once scope", async () => {
    const resolveDecision = vi.fn(() => true);
    const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/permissions/perm-1/respond",
      url: new URL("http://localhost/permissions/perm-1/respond"),
      req: makeRequest({ action: "allow" }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(resolveDecision).toHaveBeenCalledWith("perm-1", "allow", "once", undefined);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({
      ok: true,
      id: "perm-1",
      action: "allow",
      scope: "once",
    });
  });

  it("decodes permission ids in respond routes", async () => {
    const resolveDecision = vi.fn(() => true);
    const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());

    await dispatch({
      method: "POST",
      path: "/permissions/perm%2Fwith%20space/respond",
      url: new URL("http://localhost/permissions/perm%2Fwith%20space/respond"),
      req: makeRequest({ action: "deny", scope: "session", expiresInMs: 1500 }) as never,
      res: makeResponse() as never,
    });

    expect(resolveDecision).toHaveBeenCalledWith("perm/with space", "deny", "session", 1500);
  });

  it("returns 400 for invalid JSON bodies", async () => {
    const dispatch = createStreamingRoutes(makeContext(), createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/permissions/perm-1/respond",
      url: new URL("http://localhost/permissions/perm-1/respond"),
      req: makeRawRequest("{") as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "Invalid JSON" });
  });

  it("returns 400 for invalid actions", async () => {
    const resolveDecision = vi.fn(() => true);
    const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());
    const res = makeResponse();

    await dispatch({
      method: "POST",
      path: "/permissions/perm-1/respond",
      url: new URL("http://localhost/permissions/perm-1/respond"),
      req: makeRequest({ action: "maybe" }) as never,
      res: res as never,
    });

    expect(resolveDecision).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: 'action must be "allow" or "deny"' });
  });

  it("returns 400 for invalid scopes", async () => {
    const resolveDecision = vi.fn(() => true);
    const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());
    const res = makeResponse();

    await dispatch({
      method: "POST",
      path: "/permissions/perm-1/respond",
      url: new URL("http://localhost/permissions/perm-1/respond"),
      req: makeRequest({ action: "allow", scope: "workspace" }) as never,
      res: res as never,
    });

    expect(resolveDecision).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({
      error: 'scope must be "once", "session", or "global"',
    });
  });

  it("returns 400 for non-positive or non-finite expirations", async () => {
    const cases = [0, -1, "nope", Infinity];

    for (const expiresInMs of cases) {
      const resolveDecision = vi.fn(() => true);
      const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: "/permissions/perm-1/respond",
        url: new URL("http://localhost/permissions/perm-1/respond"),
        req: makeRequest({ action: "allow", expiresInMs }) as never,
        res: res as never,
      });

      expect(resolveDecision).not.toHaveBeenCalled();
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({
        error: "expiresInMs must be a positive number when provided",
      });
    }
  });

  it("returns 404 when the permission request no longer exists", async () => {
    const resolveDecision = vi.fn(() => false);
    const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());
    const res = makeResponse();

    await dispatch({
      method: "POST",
      path: "/permissions/perm-404/respond",
      url: new URL("http://localhost/permissions/perm-404/respond"),
      req: makeRequest({ action: "deny", scope: "global", expiresInMs: 3000 }) as never,
      res: res as never,
    });

    expect(resolveDecision).toHaveBeenCalledWith("perm-404", "deny", "global", 3000);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Permission request not found" });
  });

  it("returns 400 for malformed permission ids", async () => {
    const resolveDecision = vi.fn(() => true);
    const dispatch = createStreamingRoutes(makeContext(resolveDecision), createRouteHelpers());
    const res = makeResponse();

    await dispatch({
      method: "POST",
      path: "/permissions/%E0%A4%A/respond",
      url: new URL("http://localhost/permissions/%E0%A4%A/respond"),
      req: makeRequest({ action: "allow" }) as never,
      res: res as never,
    });

    expect(resolveDecision).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "Invalid permission id" });
  });
});

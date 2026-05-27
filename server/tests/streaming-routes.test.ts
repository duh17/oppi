import { describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createStreamingRoutes } from "../src/routes/streaming.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeResponse } from "./harness/route-test-helpers.js";

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
});

import { describe, expect, it } from "vitest";

import { shouldRecordHttpRequestMetric } from "../src/http-request-metrics.js";

describe("shouldRecordHttpRequestMetric", () => {
  it.each([
    {
      name: "drops a fast successful session events poll",
      path: "/sessions/:sessionId/events",
      status: 200,
      ms: 1,
      record: false,
    },
    {
      name: "drops a fast successful session dialogs poll",
      path: "/sessions/:sessionId/dialogs",
      status: 200,
      ms: 0,
      record: false,
    },
    {
      name: "keeps a slow successful session events poll",
      path: "/sessions/:sessionId/events",
      status: 200,
      ms: 50,
      record: true,
    },
    {
      name: "keeps a failed session dialogs poll",
      path: "/sessions/:sessionId/dialogs",
      status: 401,
      ms: 1,
      record: true,
    },
    {
      name: "keeps a fast successful non-routine session route",
      path: "/sessions/:sessionId/trace",
      status: 200,
      ms: 1,
      record: true,
    },
    {
      name: "still drops a fast successful health check",
      path: "/health",
      status: 200,
      ms: 1,
      record: false,
    },
  ])("$name", ({ path, status, ms, record }) => {
    expect(shouldRecordHttpRequestMetric(path, status, ms)).toBe(record);
  });
});

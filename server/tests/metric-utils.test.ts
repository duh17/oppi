import { describe, expect, it } from "vitest";

import { jsonlMaxBytesFromEnv } from "../src/metric-utils.js";

describe("metric JSONL byte caps", () => {
  it("uses only explicit positive-integer env caps", () => {
    const previous = process.env.OPPI_TEST_JSONL_MAX_BYTES;
    try {
      delete process.env.OPPI_TEST_JSONL_MAX_BYTES;
      expect(jsonlMaxBytesFromEnv("OPPI_TEST_JSONL_MAX_BYTES")).toBe(null);

      process.env.OPPI_TEST_JSONL_MAX_BYTES = "0";
      expect(jsonlMaxBytesFromEnv("OPPI_TEST_JSONL_MAX_BYTES")).toBe(null);

      process.env.OPPI_TEST_JSONL_MAX_BYTES = "64";
      expect(jsonlMaxBytesFromEnv("OPPI_TEST_JSONL_MAX_BYTES")).toBe(64);
    } finally {
      if (previous === undefined) delete process.env.OPPI_TEST_JSONL_MAX_BYTES;
      else process.env.OPPI_TEST_JSONL_MAX_BYTES = previous;
    }
  });
});

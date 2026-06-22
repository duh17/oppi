import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { appendJsonlLineWithByteLimit, jsonlMaxBytesFromEnv } from "../src/metric-utils.js";

describe("metric JSONL byte caps", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-metric-utils-"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  it("appends records while the daily file remains under the byte cap", () => {
    const filePath = join(tempDir, "server-metrics-2026-06-22.jsonl");

    const wroteFirst = appendJsonlLineWithByteLimit(filePath, '{"one":true}\n', 64);
    const wroteSecond = appendJsonlLineWithByteLimit(filePath, '{"two":true}\n', 64);

    expect(wroteFirst).toBe(true);
    expect(wroteSecond).toBe(true);
    expect(readFileSync(filePath, "utf8")).toBe('{"one":true}\n{"two":true}\n');
  });

  it("drops records that would push a daily file over the byte cap", () => {
    const filePath = join(tempDir, "server-metrics-2026-06-22.jsonl");
    writeFileSync(filePath, '{"existing":true}\n');
    const beforeSize = statSync(filePath).size;

    const wrote = appendJsonlLineWithByteLimit(
      filePath,
      '{"large":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}\n',
      beforeSize + 8,
    );

    expect(wrote).toBe(false);
    expect(statSync(filePath).size).toBe(beforeSize);
    expect(readFileSync(filePath, "utf8")).toBe('{"existing":true}\n');
  });

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

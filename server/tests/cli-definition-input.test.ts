import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { readDefinitionInput } from "../src/cli/definition-input.js";

describe("CLI structured definition input", () => {
  it("parses inline JSON objects directly", () => {
    expect(
      readDefinitionInput({ "definition-json": '{"name":"Reviewer"}' }, { required: true }),
    ).toEqual({ name: "Reviewer" });
  });

  it("keeps file definitions available without mixing input sources", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-cli-definition-input-"));
    try {
      const path = join(dir, "definition.json");
      writeFileSync(path, '{"name":"Reviewer"}');
      expect(readDefinitionInput({ definition: path }, { required: true })).toEqual({
        name: "Reviewer",
      });
      expect(() =>
        readDefinitionInput(
          { definition: path, "definition-json": '{"name":"Inline"}' },
          { required: true },
        ),
      ).toThrow("exactly one of --definition or --definition-json is required");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it.each(["not-json", "[]", "null", '"text"', "42"])(
    "rejects malformed or non-object inline input: %s",
    (value) => {
      const read = () => readDefinitionInput({ "definition-json": value }, { required: true });
      if (value === "not-json") expect(read).toThrow("--definition-json must be valid JSON");
      else expect(read).toThrow("definition must be a JSON object");
    },
  );

  it("rejects missing and empty update definitions", () => {
    expect(() => readDefinitionInput({}, { required: true, update: true })).toThrow(
      "exactly one of --definition or --definition-json is required",
    );
    expect(() =>
      readDefinitionInput({ "definition-json": "{}" }, { required: true, update: true }),
    ).toThrow("definition update must not be empty");
  });

  it("enforces the inline payload byte limit deterministically", () => {
    expect(() =>
      readDefinitionInput(
        { "definition-json": JSON.stringify({ name: "x".repeat(65_536) }) },
        { required: true },
      ),
    ).toThrow("--definition-json exceeds maximum size of 65536 bytes");
  });
});

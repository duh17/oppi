import { describe, expect, it } from "vitest";
import { parseCliArgs } from "../src/cli/args.js";

describe("parseCliArgs", () => {
  it("treats arguments after -- as positional", () => {
    expect(parseCliArgs(["session", "diff", "sess-1", "--json", "--", "--odd-path"])).toEqual({
      command: "session",
      flags: { json: "true" },
      positional: ["diff", "sess-1", "--odd-path"],
    });
  });

  it("rejects duplicate flags instead of silently overwriting them", () => {
    expect(() => parseCliArgs(["session", "list", "--limit", "5", "--limit", "10"])).toThrow(
      "Duplicate flag: --limit",
    );
  });

  it("rejects duplicate help flags", () => {
    expect(() => parseCliArgs(["session", "-h", "--help"])).toThrow("Duplicate flag: --help");
  });
});

import { describe, expect, it } from "vitest";
import { isHelpFlag, parseCliArgs } from "../src/cli/args.js";

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

  it.each(["--help", "-h"])("does not consume a following positional after %s", (helpFlag) => {
    const parsed = parseCliArgs(["server", "install", helpFlag, "ignored"]);

    expect(parsed).toEqual({
      command: "server",
      flags: { help: "true" },
      positional: ["install", "ignored"],
    });
    expect(isHelpFlag(parsed.flags)).toBe(true);
  });

  it("fails safe for an equals-form help token that the generic parser leaves opaque", () => {
    const parsed = parseCliArgs(["server", "install", "--help=false"]);

    expect(isHelpFlag(parsed.flags)).toBe(true);
  });
});

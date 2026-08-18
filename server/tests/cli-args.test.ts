import { describe, expect, it } from "vitest";
import { isHelpFlag, parseCliArgs } from "../src/cli/args.js";

describe("parseCliArgs", () => {
  it("treats arguments after -- as positional", () => {
    expect(parseCliArgs(["session", "read", "sess-1", "--json", "--", "--odd-path"])).toEqual({
      command: "session",
      flags: { json: "true" },
      positional: ["read", "sess-1", "--odd-path"],
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

  it("maps the explicit Pi short-flag table and leaves other tokens positional", () => {
    expect(
      parseCliArgs([
        "session",
        "create",
        "-n",
        "Review",
        "-t",
        "read, grep",
        "-xt",
        "bash",
        "-nt",
        "--workspace",
        "ws-1",
      ]),
    ).toEqual({
      command: "session",
      flags: {
        name: "Review",
        tools: "read, grep",
        "exclude-tools": "bash",
        "no-tools": "true",
        workspace: "ws-1",
      },
      positional: ["create"],
    });
  });

  it("does not consume the next argv after boolean shorts", () => {
    expect(parseCliArgs(["agent", "create", "-nbt", "Reviewer", "-nt"])).toEqual({
      command: "agent",
      flags: {
        "no-builtin-tools": "true",
        "no-tools": "true",
      },
      positional: ["create", "Reviewer"],
    });
  });

  it("rejects unknown short flags instead of treating them as positionals", () => {
    expect(() => parseCliArgs(["session", "create", "-z", "oops"])).toThrow("Unknown flag: -z");
  });

  it("rejects a short flag that collides with its long form", () => {
    expect(() => parseCliArgs(["session", "create", "-n", "A", "--name", "B"])).toThrow(
      "Duplicate flag: --name",
    );
  });
});

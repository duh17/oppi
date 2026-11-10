import { describe, expect, test } from "bun:test";
import { applyGoModuleFixes, bump, forkBaseTag, forkStatus, parseGoModuleFixes, parseProjectYmlPackages } from "./deps-check";

describe("Go module overrides", () => {
  const script = [
    'BUILD_ID="x"',
    "GO_MODULE_FIXES=(",
    "  # why",
    "  golang.org/x/net@v0.62.0",
    "  golang.org/x/crypto@v0.58.1-0.20261009181718-2f1f834330b2  # pseudo",
    "  github.com/new/mod@v1.0.0",
    ")",
    'go get "${GO_MODULE_FIXES[@]}"',
  ].join("\n");

  test("parses module@version entries, skipping comments", () => {
    expect(parseGoModuleFixes(script)).toEqual([
      { name: "golang.org/x/net", version: "0.62.0" },
      { name: "golang.org/x/crypto", version: "0.58.1-0.20261009181718-2f1f834330b2" },
      { name: "github.com/new/mod", version: "1.0.0" },
    ]);
    expect(parseGoModuleFixes("no array here")).toEqual([]);
  });

  test("overrides replace declared versions and add missing modules", () => {
    const out = applyGoModuleFixes(
      [
        { name: "golang.org/x/net", version: "0.50.0" },
        { name: "golang.org/x/sys", version: "0.1.0" },
      ],
      parseGoModuleFixes(script),
    );
    expect(out.find((r) => r.name === "golang.org/x/net")).toEqual({ name: "golang.org/x/net", version: "0.62.0", override: true });
    expect(out.find((r) => r.name === "golang.org/x/sys")?.override).toBeUndefined();
    expect(out.map((r) => r.name)).toContain("github.com/new/mod");
  });
});

describe("fork tags", () => {
  test("strips only the -oppi.N suffix", () => {
    expect(forkBaseTag("0.25.0-oppi.1")).toBe("0.25.0");
    expect(forkBaseTag("v0.25.0-oppi.12")).toBe("v0.25.0");
    expect(forkBaseTag("0.25.0")).toBeUndefined();
    expect(forkBaseTag("0.25.0-oppi.x")).toBeUndefined();
    expect(forkBaseTag("0.25.0-rc.1")).toBeUndefined();
  });

  test("rebase is due only when the base trails upstream's latest", () => {
    expect(forkStatus("0.25.0", "v0.26.0")).toBe("rebase due");
    expect(forkStatus("0.25.0", "0.25.1")).toBe("rebase due");
    expect(forkStatus("0.25.0", "v0.25.0")).toBe("up to date");
    expect(forkStatus("0.25.1", "0.25.0")).toBe("up to date");
    expect(forkStatus("nightly", "0.25.0")).toBe("unknown");
  });
});

describe("bump", () => {
  test("classifies by the first differing component", () => {
    expect(bump("2.9.5", "2.9.6")).toBe("patch");
    expect(bump("2.9.5", "2.10.0")).toBe("minor");
    expect(bump("2.9.5", "3.0.0")).toBe("major");
    expect(bump("2.9.5", "v2.9.5")).toBe("current");
    expect(bump("2.9.5", "2.9.4")).toBe("ahead");
    expect(bump("2.9.5", "nightly")).toBe("unknown");
  });
});

describe("parseProjectYmlPackages", () => {
  test("keeps each pin with the nearest comment block above it", () => {
    const yml = [
      "packages:",
      "  A:",
      "    url: https://github.com/o/a.git",
      '    from: "1.0.0"',
      "  # scanner.c is hardcoded;",
      "  # pin exact.",
      "  B:",
      "    url: https://github.com/o/b",
      '    exactVersion: "0.23.1"',
      "  C:",
      "    url: https://github.com/o/c",
      "    revision: abc123",
      "options:",
      '  x: "1"',
    ].join("\n");
    const [a, b, c] = parseProjectYmlPackages(yml);
    expect([a.rule, a.value, a.comment]).toEqual(["from", "1.0.0", ""]);
    expect([b.rule, b.value, b.comment]).toEqual(["exactVersion", "0.23.1", "scanner.c is hardcoded; pin exact."]);
    expect([c.rule, c.comment]).toEqual(["revision", "scanner.c is hardcoded; pin exact."]);
  });
});

import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { expandHome, isPathWithinRoot } from "../src/path-utils.js";

describe("isPathWithinRoot(candidate, root)", () => {
  it.each([
    ["the root itself", "/a/b", "/a/b", true],
    ["a descendant", "/a/b/c/d", "/a/b", true],
    ["a sibling sharing a name prefix", "/a/bc", "/a/b", false],
    ["a `..` escape", "/a/b/../c", "/a/b", false],
    ["a `..` that stays inside", "/a/b/x/../y", "/a/b", true],
    ["the parent itself via `..`", "/a/b/..", "/a/b", false],
    ["a child named like `..cache`", "/a/b/..cache", "/a/b", true],
    ["a trailing slash on the candidate", "/a/b/", "/a/b", true],
    ["a trailing slash on the root", "/a/b/c", "/a/b/", true],
    ["a trailing slash on a sibling prefix", "/a/bc/", "/a/b/", false],
    ["everything under the filesystem root", "/a/b", "/", true],
    ["a different case", "/a/B/c", "/a/b", false],
    ["an empty candidate", "", "/a/b", false],
    ["an empty root", "/a/b", "", false],
    ["relative paths", "a/b/c", "a/b", false],
    ["an unexpanded tilde", "~/x", "~", false],
  ])("%s", (_name, candidate, root, expected) => {
    expect(isPathWithinRoot(candidate, root)).toBe(expected);
  });

  describe("symlinks", () => {
    let base: string | undefined;
    afterEach(() => base && rmSync(base, { recursive: true, force: true }));

    it("is lexical: a link under the root passes until the caller passes realpaths", () => {
      base = realpathSync(mkdtempSync(join(tmpdir(), "oppi-path-utils-")));
      mkdirSync(join(base, "root"));
      mkdirSync(join(base, "outside"));
      symlinkSync(join(base, "outside"), join(base, "root", "escape"));
      const root = join(base, "root");

      expect(isPathWithinRoot(join(root, "escape", "secret"), root)).toBe(true);
      const real = join(realpathSync(join(root, "escape")), "secret");
      expect(isPathWithinRoot(real, realpathSync(root))).toBe(false);
    });
  });
});

describe("expandHome", () => {
  const home = homedir();

  it.each([
    ["~", home],
    ["~/x/y", `${home}/x/y`],
    ["~/", `${home}/`],
    ["~bob", "~bob"],
    ["~bob/x", "~bob/x"],
    ["~.hidden", "~.hidden"],
    ["", ""],
    ["/abs/~/x", "/abs/~/x"],
    ["rel/~", "rel/~"],
    [" ~", " ~"],
  ])("%j -> %j", (input, expected) => {
    expect(expandHome(input)).toBe(expected);
  });
});

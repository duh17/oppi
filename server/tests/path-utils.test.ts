import { homedir } from "node:os";
import { describe, expect, it } from "vitest";

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
    ["everything under the filesystem root", "/a/b", "/", true],
    ["a different case", "/a/B/c", "/a/b", false],
    ["an empty candidate", "", "/a/b", false],
    ["an empty root", "/a/b", "", false],
    ["relative paths", "a/b/c", "a/b", false],
  ])("%s", (_name, candidate, root, expected) => {
    expect(isPathWithinRoot(candidate, root)).toBe(expected);
  });
});

describe("expandHome", () => {
  const home = homedir();

  it.each([
    ["~", home],
    ["~/x/y", `${home}/x/y`],
    ["~bob/x", "~bob/x"],
    [" ~", " ~"],
  ])("%j -> %j", (input, expected) => {
    expect(expandHome(input)).toBe(expected);
  });
});

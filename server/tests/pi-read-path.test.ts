import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { normalizeWindowsShellPath, resolvePiReadPath } from "../src/pi-read-path.js";

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("Pi 0.84.1 read path parity", () => {
  it("does not normalize Unicode spaces in the base cwd", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-pi-read-cwd-"));
    dirs.push(root);
    const cwd = join(root, "review\u202fworkspace");
    const primary = join(cwd, "testing", "SKILL.md");
    mkdirSync(join(cwd, "testing"), { recursive: true });
    writeFileSync(primary, "# Testing\n");

    expect(resolvePiReadPath("testing/SKILL.md", cwd)).toBe(primary);
  });

  it.each([
    ["/c/Users/test/SKILL.md", "C:\\Users\\test\\SKILL.md"],
    ["/mnt/d/work/SKILL.md", "D:\\work\\SKILL.md"],
    ["/cygdrive/e/work/SKILL.md", "E:\\work\\SKILL.md"],
    ["//server/share/SKILL.md", "//server/share/SKILL.md"],
    ["/workspace/SKILL.md", "/workspace/SKILL.md"],
  ])("converts Windows shell path %s exactly like Pi", (input, expected) => {
    expect(normalizeWindowsShellPath(input)).toBe(expected);
  });
});

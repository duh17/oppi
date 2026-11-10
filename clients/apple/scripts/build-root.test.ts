import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildRoot, buildRootFor, ensureBuildLink, isManagedBuildLink } from "./build-root";

const made: string[] = [];
function temp(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "build-root-")));
  made.push(dir);
  return dir;
}
function checkout(base: string, name: string): string {
  const apple = join(base, name, "clients", "apple");
  mkdirSync(apple, { recursive: true });
  return apple;
}
afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("build root", () => {
  test("without a mounted root, .build stays an ordinary folder and a dead link is dropped", () => {
    const base = temp();
    const apple = checkout(base, "wt-a");
    expect(ensureBuildLink(apple, {})).toBeUndefined();
    expect(existsSync(join(apple, ".build"))).toBe(false);
    const env = { OPPI_BUILD_ROOT: join(base, "absent") };
    symlinkSync(join(base, "absent", "gone"), join(apple, ".build"));
    expect(buildRoot(env)).toBeUndefined();
    expect(ensureBuildLink(apple, env)).toBeUndefined();
    expect(() => lstatSync(join(apple, ".build"))).toThrow();
  });

  test("each checkout links to its own folder and an existing folder moves over", () => {
    const base = temp();
    const root = join(base, "ram");
    mkdirSync(root);
    const env = { OPPI_BUILD_ROOT: root };
    const a = checkout(base, "wt-a");
    const b = checkout(base, "wt-b");
    mkdirSync(join(a, ".build", "dd"), { recursive: true });
    const folderA = ensureBuildLink(a, env)!;
    const folderB = ensureBuildLink(b, env)!;
    expect(folderA).not.toBe(folderB);
    expect(readlinkSync(join(a, ".build"))).toBe(folderA);
    expect(existsSync(join(folderA, "dd"))).toBe(false);
    expect(isManagedBuildLink(a)).toBe(true);
    expect(ensureBuildLink(a, env)).toBe(folderA);
  });

  test("a deleted link finds its folder again; folders of removed checkouts are reaped", () => {
    const base = temp();
    const root = join(base, "ram");
    mkdirSync(root);
    const env = { OPPI_BUILD_ROOT: root };
    const a = checkout(base, "wt-a");
    const b = checkout(base, "wt-b");
    const folderA = ensureBuildLink(a, env)!;
    const folderB = ensureBuildLink(b, env)!;
    writeFileSync(join(folderA, "kept"), "x");
    rmSync(join(a, ".build"));
    rmSync(join(base, "wt-b"), { recursive: true });
    expect(ensureBuildLink(a, env)).toBe(folderA);
    expect(existsSync(join(folderA, "kept"))).toBe(true);
    expect(existsSync(folderB)).toBe(false);
  });

  test("a link to another checkout's folder is relinked; a link outside the root is left alone", () => {
    const base = temp();
    const root = join(base, "ram");
    mkdirSync(join(root, "elsewhere"), { recursive: true });
    const env = { OPPI_BUILD_ROOT: root };
    const a = checkout(base, "wt-a");
    symlinkSync(join(root, "elsewhere"), join(a, ".build"));
    const folder = ensureBuildLink(a, env)!;
    expect(readlinkSync(join(a, ".build"))).toBe(folder);
    const b = checkout(base, "wt-b");
    const own = join(base, "own");
    mkdirSync(own);
    symlinkSync(own, join(b, ".build"));
    expect(ensureBuildLink(b, env)).toBeUndefined();
    expect(readlinkSync(join(b, ".build"))).toBe(own);
  });

  test("managed means the folder names this checkout, with or without the env; folders on an unmounted volume are kept", () => {
    const base = temp();
    const root = join(base, "ram");
    mkdirSync(root);
    const env = { OPPI_BUILD_ROOT: root };
    const a = checkout(base, "wt-a");
    const b = checkout(base, "wt-b");
    const folderA = ensureBuildLink(a, env)!;
    ensureBuildLink(b, env);
    expect(isManagedBuildLink(a)).toBe(true);
    expect(buildRootFor(a, {})).toBe(root);
    // b's link points at a's folder: not b's own.
    rmSync(join(b, ".build"));
    symlinkSync(folderA, join(b, ".build"));
    expect(isManagedBuildLink(b)).toBe(false);
    // A checkout whose volume is unmounted (its worktree's parent is absent) is not reaped.
    const gone = join(base, "unmounted", "wt-x", "clients", "apple");
    mkdirSync(join(root, "wt-x-1234abcd"));
    writeFileSync(join(root, "wt-x-1234abcd", ".checkout"), `${gone}\n`);
    ensureBuildLink(checkout(base, "wt-c"), env);
    expect(existsSync(join(root, "wt-x-1234abcd"))).toBe(true);
  });
});

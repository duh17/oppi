import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { buildRoot, buildRootFor, buildVolumeLost, buildVolumeMissing, buildVolumeOf, ensureBuildLink, isManagedBuildLink, relieveBuildRoot } from "./build-root";

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
  test("without a root, .build stays an ordinary folder; a link into a configured root that is gone stays and is named", () => {
    const base = temp();
    const apple = checkout(base, "wt-a");
    expect(ensureBuildLink(apple, {})).toBeUndefined();
    expect(existsSync(join(apple, ".build"))).toBe(false);
    const env = { OPPI_BUILD_ROOT: join(base, "absent") };
    symlinkSync(join(base, "absent", "gone"), join(apple, ".build"));
    expect(buildRoot(env)).toBeUndefined();
    expect(ensureBuildLink(apple, env)).toBeUndefined();
    expect(lstatSync(join(apple, ".build")).isSymbolicLink()).toBe(true);
    expect(buildVolumeMissing(apple, env)).toContain("build volume missing:");
    expect(buildVolumeMissing(apple, env)).toContain("oppi-ramdisk.sh");
    // A detached RAM disk leaves its mount point behind, empty and unwritable: still not mounted.
    mkdirSync(join(base, "absent"), { mode: 0o111 });
    expect(buildRoot(env)).toBeUndefined();
    expect(buildVolumeMissing(apple, env)).toContain("is not mounted");
    chmodSync(join(base, "absent"), 0o755);
    // Mounted again (empty): the link is made again.
    expect(buildVolumeMissing(apple, env)).toBeUndefined();
    expect(ensureBuildLink(apple, env)).toBe(readlinkSync(join(apple, ".build")));
    expect(existsSync(join(apple, ".build"))).toBe(true);
    // With no root configured any more, a dead link is dropped and .build is an ordinary folder again.
    const other = checkout(base, "wt-b");
    symlinkSync(join(base, "elsewhere", "gone"), join(other, ".build"));
    expect(buildVolumeMissing(other, {})).toBeUndefined();
    expect(ensureBuildLink(other, {})).toBeUndefined();
    expect(() => lstatSync(join(other, ".build"))).toThrow();
  });

  test("a build volume is lost when .build stops resolving, moves to another device, or a watched path vanishes", () => {
    const base = temp();
    const root = join(base, "ram");
    mkdirSync(root);
    const apple = checkout(base, "wt-a");
    const folder = ensureBuildLink(apple, { OPPI_BUILD_ROOT: root })!;
    const log = join(folder, "logs", "build.log");
    mkdirSync(dirname(log));
    writeFileSync(log, "");
    const start = buildVolumeOf(apple)!;
    expect(buildVolumeLost(apple, start, [log])).toBeUndefined();
    expect(buildVolumeLost(apple, { ...start, dev: start.dev + 1 }, [log])).toContain("was replaced mid-build");
    rmSync(log);
    expect(buildVolumeLost(apple, start, [log])).toBe(`build volume lost: ${log} disappeared mid-build`);
    rmSync(root, { recursive: true });
    expect(buildVolumeLost(apple, start, [log])).toBe(`build volume lost: ${folder} disappeared mid-build`);
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
    // A checkout whose link is already in place reaps too: removing a worktree only drops its link.
    const c = checkout(base, "wt-c");
    const folderC = ensureBuildLink(c, env)!;
    rmSync(join(base, "wt-c"), { recursive: true });
    expect(ensureBuildLink(a, env)).toBe(folderA);
    expect(existsSync(folderC)).toBe(false);
    expect(existsSync(join(folderA, "kept"))).toBe(true);
  });

  test("low on space, a build start frees stale runs oldest first, then the compile cache only while no xcodebuild runs", () => {
    const base = temp();
    const root = join(base, "ram");
    mkdirSync(root);
    const folder = ensureBuildLink(checkout(base, "wt-a"), { OPPI_BUILD_ROOT: root })!;
    const file = (path: string, bytes: number, ageHours = 0) => {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, "x".repeat(bytes));
      const at = new Date(Date.now() - ageHours * 3_600_000);
      utimesSync(path, at, at);
      utimesSync(dirname(path), at, at);
    };
    file(join(folder, "runs", "older", "out"), 1000, 30);
    file(join(folder, "runs", "old", "out"), 1000, 20);
    file(join(folder, "runs", "busy", "out"), 1000, 40);
    file(join(folder, "runs", "fresh", "out"), 1000);
    file(join(folder, "dd", "out"), 1000, 40);
    file(join(root, "xcode-cache", "Xcode-1.app", "cas", "blob"), 3000, 40);
    file(join(root, "xcode-cache", "Xcode-1.app", "modulecache", "m"), 1000, 40);
    // A volume of 10,000 bytes: free space is what the files under the root leave (about 900 now).
    const used = (dir: string): number =>
      readdirSync(dir, { withFileTypes: true }).reduce((n, e) => n + (e.isDirectory() ? used(join(dir, e.name)) : statSync(join(dir, e.name)).size), 0);
    let building = true;
    const probe = { freeBytes: () => 10_000 - used(root), inUse: (dir: string) => dir.endsWith("busy"), xcodebuildRunning: () => building };
    const runs = () => readdirSync(join(folder, "runs")).sort();

    // Enough room: nothing goes.
    expect(relieveBuildRoot(root, 500, probe)).toEqual([]);
    // Short by about 600 bytes: the oldest stale run that nothing uses goes, and that is enough.
    expect(relieveBuildRoot(root, 1500, probe).join("\n")).toContain(join(folder, "runs", "older"));
    expect(runs()).toEqual(["busy", "fresh", "old"]);
    // Still short after every stale run: the cache stays while a build runs, and the log says why.
    const kept = relieveBuildRoot(root, 3000, probe);
    expect(runs()).toEqual(["busy", "fresh"]);
    expect(kept.join("\n")).toContain("xcodebuild is running");
    expect(existsSync(join(root, "xcode-cache", "Xcode-1.app", "cas", "blob"))).toBe(true);
    // With no build running, cas and modulecache go; a live checkout's runs in use, fresh runs, and DerivedData stay.
    building = false;
    const cleared = relieveBuildRoot(root, 3000, probe);
    expect(cleared.join("\n")).toContain(join(root, "xcode-cache", "Xcode-1.app", "cas"));
    expect(readdirSync(join(root, "xcode-cache", "Xcode-1.app"))).toEqual([]);
    expect(runs()).toEqual(["busy", "fresh"]);
    expect(existsSync(join(folder, "dd", "out"))).toBe(true);
    expect(existsSync(join(folder, ".checkout"))).toBe(true);
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

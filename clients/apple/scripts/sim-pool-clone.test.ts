import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cloneDirectory } from "./sim-pool-clone";

const temps: string[] = [];
afterEach(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** A small products-like tree: nested files, an executable, a relative symlink, an empty directory. */
function makeTree(): { root: string; src: string } {
  const root = mkdtempSync(join(tmpdir(), "sim-pool-clone-"));
  temps.push(root);
  const src = join(root, "Products");
  mkdirSync(join(src, "Debug-iphonesimulator", "Oppi.app", "Frameworks"), { recursive: true });
  mkdirSync(join(src, "empty"));
  writeFileSync(join(src, "Debug-iphonesimulator", "Oppi.app", "Oppi"), "binary");
  writeFileSync(join(src, "Debug-iphonesimulator", "Oppi.app", "Frameworks", "a.txt"), "a");
  writeFileSync(join(src, "run.sh"), "#!/bin/sh\n", { mode: 0o755 });
  symlinkSync("run.sh", join(src, "latest"));
  return { root, src };
}

// clonefile(2) is APFS; the fallback path is covered wherever the tests run.
describe("cloneDirectory", () => {
  test.skipIf(process.platform !== "darwin")("clones the whole tree with one call and the clone is independent of the source", () => {
    const { root, src } = makeTree();
    const dest = join(root, "runs", "Products");
    mkdirSync(join(root, "runs"));
    const logged: string[] = [];
    expect(cloneDirectory(src, dest, (line) => logged.push(line))).toBe("clonefile");
    expect(logged).toEqual([]);
    expect(readFileSync(join(dest, "Debug-iphonesimulator", "Oppi.app", "Oppi"), "utf8")).toBe("binary");
    expect(readFileSync(join(dest, "Debug-iphonesimulator", "Oppi.app", "Frameworks", "a.txt"), "utf8")).toBe("a");
    expect(statSync(join(dest, "empty")).isDirectory()).toBe(true);
    expect(statSync(join(dest, "run.sh")).mode & 0o777).toBe(0o755);
    // A symlink stays a symlink: the clone does not read through it.
    expect(lstatSync(join(dest, "latest")).isSymbolicLink()).toBe(true);
    expect(readlinkSync(join(dest, "latest"))).toBe("run.sh");
    // Writing to the clone leaves the source's bytes alone (the point of copy-on-write).
    writeFileSync(join(dest, "Debug-iphonesimulator", "Oppi.app", "Oppi"), "changed");
    expect(readFileSync(join(src, "Debug-iphonesimulator", "Oppi.app", "Oppi"), "utf8")).toBe("binary");
  });

  test("a destination that exists makes clonefile fail; the copy merges into it, not under it, and says why", () => {
    const { root, src } = makeTree();
    const dest = join(root, "runs", "Products");
    mkdirSync(dest, { recursive: true });
    writeFileSync(join(dest, "kept.txt"), "already here");
    const logged: string[] = [];
    expect(cloneDirectory(src, dest, (line) => logged.push(line))).toBe("copy");
    expect(logged).toHaveLength(1);
    expect(logged[0]).toContain("clonefile");
    expect(logged[0]).toContain(src);
    if (process.platform === "darwin") expect(logged[0]).toContain("EEXIST");
    expect(readFileSync(join(dest, "Debug-iphonesimulator", "Oppi.app", "Oppi"), "utf8")).toBe("binary");
    expect(readFileSync(join(dest, "kept.txt"), "utf8")).toBe("already here");
    expect(existsSync(join(dest, "Products"))).toBe(false);
    expect(readlinkSync(join(dest, "latest"))).toBe("run.sh");
  });

  test("a missing parent directory falls back to a copy that creates it", () => {
    const { root, src } = makeTree();
    const dest = join(root, "no", "such", "parent", "Products");
    const logged: string[] = [];
    expect(cloneDirectory(src, dest, (line) => logged.push(line))).toBe("copy");
    expect(logged).toHaveLength(1);
    expect(readFileSync(join(dest, "Debug-iphonesimulator", "Oppi.app", "Frameworks", "a.txt"), "utf8")).toBe("a");
  });

  test("throws when neither the clone nor the copy can read the source", () => {
    const { root } = makeTree();
    expect(() => cloneDirectory(join(root, "missing"), join(root, "dest"), () => {})).toThrow("failed");
  });
});

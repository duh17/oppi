import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync, writeFileSync, symlinkSync, mkdirSync,
  existsSync, lstatSync, readFileSync, rmSync, utimesSync,
  cpSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  copyFileDereferenced, syncFile, syncOptionalFile, isNewer,
} from "../src/sync.js";

function isSymlink(path: string): boolean {
  try {
    return lstatSync(path).isSymbolicLink();
  } catch {
    return false;
  }
}

let tmp: string;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "oppi-server-sync-test-"));
});

afterEach(() => {
  rmSync(tmp, { recursive: true });
});

// ─── copyFileDereferenced ───

describe("copyFileDereferenced", () => {
  it("dereferences symlink to regular file", () => {
    const real = join(tmp, "real.txt");
    const link = join(tmp, "link.txt");
    const dest = join(tmp, "dest.txt");

    writeFileSync(real, "hello world");
    symlinkSync(real, link);
    copyFileDereferenced(link, dest);

    expect(isSymlink(dest)).toBe(false);
    expect(readFileSync(dest, "utf-8")).toBe("hello world");
  });

  it("dereferences nested symlink chain", () => {
    const real = join(tmp, "real.txt");
    const link1 = join(tmp, "link1.txt");
    const link2 = join(tmp, "link2.txt");
    const dest = join(tmp, "dest.txt");

    writeFileSync(real, "deep content");
    symlinkSync(real, link1);
    symlinkSync(link1, link2);
    copyFileDereferenced(link2, dest);

    expect(isSymlink(dest)).toBe(false);
    expect(readFileSync(dest, "utf-8")).toBe("deep content");
  });

  it("preserves file mode", () => {
    const src = join(tmp, "secret.json");
    const dest = join(tmp, "dest.json");

    writeFileSync(src, '{"key":"value"}');
    copyFileDereferenced(src, dest, { mode: 0o600 });

    const mode = lstatSync(dest).mode & 0o777;
    expect(readFileSync(dest, "utf-8")).toBe('{"key":"value"}');
    expect(mode).toBe(0o600);
  });

  it("copies regular file (no symlink)", () => {
    const src = join(tmp, "src.txt");
    const dest = join(tmp, "dest.txt");

    writeFileSync(src, "plain content");
    copyFileDereferenced(src, dest);

    expect(isSymlink(dest)).toBe(false);
    expect(readFileSync(dest, "utf-8")).toBe("plain content");
  });
});

// ─── syncFile ───

describe("syncFile", () => {
  it("syncs from symlinked source to regular dest", () => {
    const real = join(tmp, "real.json");
    const link = join(tmp, "link.json");
    const dest = join(tmp, "dest.json");

    writeFileSync(real, '{"auth":true}');
    symlinkSync(real, link);
    syncFile(link, dest);

    expect(existsSync(dest)).toBe(true);
    expect(isSymlink(dest)).toBe(false);
    expect(readFileSync(dest, "utf-8")).toBe('{"auth":true}');
  });

  it("skips when dest is newer", () => {
    const src = join(tmp, "src.txt");
    const dest = join(tmp, "dest.txt");

    writeFileSync(src, "old content");
    const past = new Date(Date.now() - 10_000);
    utimesSync(src, past, past);

    writeFileSync(dest, "newer content");
    syncFile(src, dest);

    expect(readFileSync(dest, "utf-8")).toBe("newer content");
  });

  it("copies when dest is older", () => {
    const src = join(tmp, "src.txt");
    const dest = join(tmp, "dest.txt");

    writeFileSync(dest, "old content");
    const past = new Date(Date.now() - 10_000);
    utimesSync(dest, past, past);

    writeFileSync(src, "new content");
    syncFile(src, dest);

    expect(readFileSync(dest, "utf-8")).toBe("new content");
  });

  it("no-ops when src is missing", () => {
    const dest = join(tmp, "dest.txt");
    syncFile(join(tmp, "nonexistent.txt"), dest);
    expect(existsSync(dest)).toBe(false);
  });
});

// ─── syncOptionalFile ───

describe("syncOptionalFile", () => {
  it("copies when enabled + symlink source", () => {
    const real = join(tmp, "memory.ts");
    const link = join(tmp, "memory-link.ts");
    const dest = join(tmp, "dest.ts");

    writeFileSync(real, 'export default function() {}');
    symlinkSync(real, link);
    syncOptionalFile(link, dest, true);

    expect(existsSync(dest)).toBe(true);
    expect(isSymlink(dest)).toBe(false);
    expect(readFileSync(dest, "utf-8")).toBe('export default function() {}');
  });

  it("removes existing dest when disabled", () => {
    const dest = join(tmp, "memory.ts");
    writeFileSync(dest, "should be removed");

    syncOptionalFile(join(tmp, "whatever"), dest, false);
    expect(existsSync(dest)).toBe(false);
  });

  it("no-ops when disabled and dest already absent", () => {
    const dest = join(tmp, "memory.ts");
    syncOptionalFile(join(tmp, "whatever"), dest, false);
    expect(existsSync(dest)).toBe(false);
  });

  it("no-ops when enabled but src is missing", () => {
    const dest = join(tmp, "memory.ts");
    syncOptionalFile(join(tmp, "nonexistent.ts"), dest, true);
    expect(existsSync(dest)).toBe(false);
  });
});

// ─── isNewer ───

describe("isNewer", () => {
  it("detects newer and older files correctly", () => {
    const older = join(tmp, "older.txt");
    const newer = join(tmp, "newer.txt");

    writeFileSync(older, "old");
    const past = new Date(Date.now() - 10_000);
    utimesSync(older, past, past);

    writeFileSync(newer, "new");

    expect(isNewer(newer, older)).toBe(true);
    expect(isNewer(older, newer)).toBe(false);
    expect(isNewer(join(tmp, "missing"), older)).toBe(false);
  });
});

// ─── Regression canaries ───

describe("regression canaries", () => {
  it("cpSync preserves symlinks (the bug copyFileDereferenced fixes)", () => {
    const real = join(tmp, "real.txt");
    const link = join(tmp, "link.txt");
    const cpDest = join(tmp, "cp-dest.txt");
    const derefDest = join(tmp, "deref-dest.txt");

    writeFileSync(real, "test content");
    symlinkSync(real, link);

    cpSync(link, cpDest);
    expect(isSymlink(cpDest)).toBe(true);

    copyFileDereferenced(link, derefDest);
    expect(isSymlink(derefDest)).toBe(false);

    expect(readFileSync(cpDest, "utf-8")).toBe(readFileSync(derefDest, "utf-8"));
  });

  it("fetch allowlist: symlinked host file becomes regular dest", () => {
    const dotfilesDir = join(tmp, "dotfiles");
    const configDir = join(tmp, "config", "fetch");
    mkdirSync(dotfilesDir, { recursive: true });
    mkdirSync(configDir, { recursive: true });

    const realAllowlist = join(dotfilesDir, "allowed_domains.txt");
    writeFileSync(realAllowlist, "github.com\nstackoverflow.com\n");

    const hostAllowlist = join(tmp, "host-allowlist.txt");
    symlinkSync(realAllowlist, hostAllowlist);

    const destAllowlist = join(configDir, "allowed_domains.txt");
    copyFileDereferenced(hostAllowlist, destAllowlist);

    expect(isSymlink(destAllowlist)).toBe(false);
    expect(readFileSync(destAllowlist, "utf-8")).toBe("github.com\nstackoverflow.com\n");
  });

  it("symlinked directory sync produces regular file", () => {
    // Ensure syncFile handles a symlinked source file in a dotfiles scenario
    const dotfilesDir = join(tmp, "dotfiles");
    mkdirSync(dotfilesDir, { recursive: true });

    const real = join(dotfilesDir, "auth.json");
    writeFileSync(real, '{"token":"x"}');

    const link = join(tmp, "host-auth.json");
    symlinkSync(real, link);

    const dest = join(tmp, "sandbox-auth.json");
    syncFile(link, dest);

    expect(existsSync(dest)).toBe(true);
    expect(isSymlink(dest)).toBe(false);
    expect(readFileSync(dest, "utf-8")).toBe('{"token":"x"}');
  });
});

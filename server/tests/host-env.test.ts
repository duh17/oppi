import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir, homedir } from "node:os";

import { loadHostEnv, buildHostEnv, wellKnownPathDirs } from "../src/host-env.js";

function tmpEnvFile(content: string): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-env-"));
  const path = join(dir, "env");
  writeFileSync(path, content);
  return path;
}

describe("wellKnownPathDirs", () => {
  it("returns array of existing directories", () => {
    const dirs = wellKnownPathDirs();
    expect(Array.isArray(dirs)).toBe(true);
    // /usr/bin and /bin should always exist
    expect(dirs).toContain("/usr/bin");
    expect(dirs).toContain("/bin");
  });

  it("does not include nonexistent directories", () => {
    const dirs = wellKnownPathDirs();
    for (const d of dirs) {
      expect(d).not.toContain("nonexistent");
    }
  });
});

describe("loadHostEnv", () => {
  it("returns empty object for nonexistent path", () => {
    const result = loadHostEnv("/tmp/nonexistent-oppi-env-file");
    expect(result).toEqual({});
  });

  it("parses KEY=VALUE lines", () => {
    const path = tmpEnvFile("EDITOR=nvim\nSHELL=/bin/zsh");
    const result = loadHostEnv(path);
    expect(result.EDITOR).toBe("nvim");
    expect(result.SHELL).toBe("/bin/zsh");
    rmSync(join(path, ".."), { recursive: true });
  });

  it("skips comments and blank lines", () => {
    const path = tmpEnvFile("# comment\n\nFOO=bar\n  # another\n");
    const result = loadHostEnv(path);
    expect(Object.keys(result)).toEqual(["FOO"]);
    expect(result.FOO).toBe("bar");
    rmSync(join(path, ".."), { recursive: true });
  });

  it("skips lines without =", () => {
    const path = tmpEnvFile("NOEQUALS\nGOOD=yes");
    const result = loadHostEnv(path);
    expect(result.GOOD).toBe("yes");
    expect(result.NOEQUALS).toBeUndefined();
    rmSync(join(path, ".."), { recursive: true });
  });

  it("strips optional quotes", () => {
    const path = tmpEnvFile('SINGLE=\'hello\'\nDOUBLE="world"');
    const result = loadHostEnv(path);
    expect(result.SINGLE).toBe("hello");
    expect(result.DOUBLE).toBe("world");
    rmSync(join(path, ".."), { recursive: true });
  });

  it("expands tilde to home directory", () => {
    const path = tmpEnvFile("PATH=~/bin:~/.local/bin");
    const result = loadHostEnv(path);
    const home = homedir();
    expect(result.PATH).toBe(`${home}/bin:${home}/.local/bin`);
    rmSync(join(path, ".."), { recursive: true });
  });

  it("handles PATH with colons correctly", () => {
    const path = tmpEnvFile("PATH=/usr/local/bin:/usr/bin:/bin");
    const result = loadHostEnv(path);
    expect(result.PATH).toBe("/usr/local/bin:/usr/bin:/bin");
    rmSync(join(path, ".."), { recursive: true });
  });
});

describe("buildHostEnv", () => {
  it("merges PATH from overrides + well-known + process.env", () => {
    const env = buildHostEnv({ PATH: "/custom/bin" });
    const pathEntries = env.PATH!.split(":");

    // /custom/bin should be first (highest priority)
    expect(pathEntries[0]).toBe("/custom/bin");

    // Well-known and inherited should follow
    expect(pathEntries.length).toBeGreaterThan(1);
  });

  it("deduplicates PATH entries", () => {
    const env = buildHostEnv({ PATH: "/usr/bin:/usr/bin" });
    const pathEntries = env.PATH!.split(":");
    const usrBinCount = pathEntries.filter((p) => p === "/usr/bin").length;
    expect(usrBinCount).toBe(1);
  });

  it("applies non-PATH overrides", () => {
    const env = buildHostEnv({ EDITOR: "nvim", LANG: "en_US.UTF-8" });
    expect(env.EDITOR).toBe("nvim");
    expect(env.LANG).toBe("en_US.UTF-8");
  });

  it("preserves existing process.env entries", () => {
    const env = buildHostEnv({});
    // HOME should always be in process.env
    expect(env.HOME).toBeTruthy();
  });

  it("handles empty overrides", () => {
    const env = buildHostEnv({});
    expect(env.PATH).toBeTruthy();
  });
});

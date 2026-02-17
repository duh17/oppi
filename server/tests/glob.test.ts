import { describe, expect, it } from "vitest";
import { globMatch } from "../src/glob.js";

describe("globMatch", () => {
  // ── Basic literals ──
  it("matches exact strings", () => {
    expect(globMatch("foo.txt", "foo.txt")).toBe(true);
    expect(globMatch("foo.txt", "bar.txt")).toBe(false);
  });

  // ── Single star (*) — matches within one path segment ──
  it("* matches any chars except /", () => {
    expect(globMatch("src/index.ts", "src/*.ts")).toBe(true);
    expect(globMatch("src/deep/index.ts", "src/*.ts")).toBe(false);
    expect(globMatch(".env", "*.env")).toBe(true); // dot:true — * matches dotfiles
    expect(globMatch("app.env", "*.env")).toBe(true);
  });

  it("* at end matches rest of segment", () => {
    expect(globMatch("git push origin main", "git push*")).toBe(true);
    expect(globMatch("git pushx", "git push*")).toBe(true);
    expect(globMatch("git pull", "git push*")).toBe(false);
  });

  // ── Double star (**) — matches across path separators ──
  it("** matches any depth", () => {
    expect(globMatch("/home/pi/.pi/agent/auth.json", "**/agent/auth.json")).toBe(true);
    expect(globMatch("agent/auth.json", "**/agent/auth.json")).toBe(true);
    expect(globMatch("/deep/nested/agent/auth.json", "**/agent/auth.json")).toBe(true);
    expect(globMatch("/agent/other.json", "**/agent/auth.json")).toBe(false);
  });

  it("** at end matches everything below", () => {
    expect(globMatch("src/a/b/c.ts", "src/**")).toBe(true);
    expect(globMatch("src/x.ts", "src/**")).toBe(true);
    expect(globMatch("other/x.ts", "src/**")).toBe(false);
  });

  it("** in middle", () => {
    expect(globMatch("a/b/c/d.ts", "a/**/d.ts")).toBe(true);
    expect(globMatch("a/d.ts", "a/**/d.ts")).toBe(true);
    expect(globMatch("a/b/d.ts", "a/**/d.ts")).toBe(true);
  });

  // ── Question mark (?) ──
  it("? matches single char except /", () => {
    expect(globMatch("a.ts", "?.ts")).toBe(true);
    expect(globMatch("ab.ts", "?.ts")).toBe(false);
    expect(globMatch("/.ts", "?.ts")).toBe(false);
  });

  // ── Dotfiles ──
  it("matches dotfiles (dot: true behavior)", () => {
    expect(globMatch(".gitignore", "*")).toBe(true);
    expect(globMatch(".env", ".*")).toBe(true);
    expect(globMatch("src/.hidden", "src/*")).toBe(true);
  });

  // ── Character classes ──
  it("matches [abc] character classes", () => {
    expect(globMatch("a.ts", "[abc].ts")).toBe(true);
    expect(globMatch("d.ts", "[abc].ts")).toBe(false);
  });

  it("matches [a-z] ranges", () => {
    expect(globMatch("m.ts", "[a-z].ts")).toBe(true);
    expect(globMatch("M.ts", "[a-z].ts")).toBe(false);
  });

  it("matches [!abc] negated classes", () => {
    expect(globMatch("d.ts", "[!abc].ts")).toBe(true);
    expect(globMatch("a.ts", "[!abc].ts")).toBe(false);
  });

  // ── Brace expansion ──
  it("expands {a,b} alternations", () => {
    expect(globMatch("foo.ts", "foo.{ts,js}")).toBe(true);
    expect(globMatch("foo.js", "foo.{ts,js}")).toBe(true);
    expect(globMatch("foo.py", "foo.{ts,js}")).toBe(false);
  });

  // ── Escape ──
  it("\\x escapes special characters", () => {
    expect(globMatch("a*b", "a\\*b")).toBe(true);
    expect(globMatch("axb", "a\\*b")).toBe(false);
  });

  // ── Real policy patterns ──
  it("matches auth.json denial pattern", () => {
    expect(globMatch("/home/user/.pi/agent/auth.json", "**/agent/auth.json")).toBe(true);
    expect(globMatch("~/.pi/agent/auth.json", "**/agent/auth.json")).toBe(true);
    expect(globMatch("/var/agent/auth.json", "**/agent/auth.json")).toBe(true);
    expect(globMatch("auth.json", "**/agent/auth.json")).toBe(false);
  });

  it("matches *auth.json* pattern", () => {
    expect(globMatch("auth.json", "*auth.json*")).toBe(true);
    expect(globMatch("auth.json.bak", "*auth.json*")).toBe(true);
    // * doesn't cross / — this is for file-path matching
    expect(globMatch("/path/to/auth.json.bak", "*auth.json*")).toBe(false);
    expect(globMatch("/path/to/auth.json.bak", "**/*auth.json*")).toBe(true);
    expect(globMatch("other.json", "*auth.json*")).toBe(false);
  });

  // ── Edge cases ──
  it("empty pattern matches empty string", () => {
    expect(globMatch("", "")).toBe(true);
    expect(globMatch("x", "")).toBe(false);
  });

  it("handles multiple wildcards", () => {
    expect(globMatch("a/b/c/d/e", "**/c/**")).toBe(true);
    expect(globMatch("c/d", "**/c/**")).toBe(true);
  });

  // ── Fuzz: ReDoS resistance ──
  it("resists ReDoS with pathological patterns", () => {
    // Classic ReDoS: many stars against a long non-matching string
    const longPath = "a/".repeat(100) + "b";
    const evilPattern = "*".repeat(50) + "c";
    const start = Date.now();
    globMatch(longPath, evilPattern);
    expect(Date.now() - start).toBeLessThan(500);
  });

  it("resists ReDoS with nested ** patterns", () => {
    const longPath = "/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z";
    const evilPattern = "**/**/**/**/**/**/**/NOMATCH";
    const start = Date.now();
    globMatch(longPath, evilPattern);
    expect(Date.now() - start).toBeLessThan(500);
  });

  // ── Fuzz: random path/pattern combos don't crash ──
  it("10K random paths and patterns do not crash", () => {
    const pathChars = "abcdefghijklmnopqrstuvwxyz0123456789._-/";
    const patChars = "abcdefghijklmnopqrstuvwxyz0123456789._-/*?[]{}\\!";
    let crashes = 0;

    for (let i = 0; i < 10_000; i++) {
      const pathLen = Math.floor(Math.random() * 100) + 1;
      const patLen = Math.floor(Math.random() * 50) + 1;
      let path = "";
      let pat = "";
      for (let j = 0; j < pathLen; j++) path += pathChars[Math.floor(Math.random() * pathChars.length)];
      for (let j = 0; j < patLen; j++) pat += patChars[Math.floor(Math.random() * patChars.length)];
      try {
        globMatch(path, pat);
      } catch {
        crashes++;
      }
    }
    expect(crashes).toBe(0);
  });

  it("100K glob evaluations in under 5s", () => {
    const paths = [
      "/home/user/.pi/agent/auth.json",
      "/workspace/project/src/index.ts",
      "node_modules/.package-lock.json",
      "/var/log/system.log",
      "src/deeply/nested/path/to/file.test.ts",
    ];
    const patterns = [
      "**/agent/auth.json",
      "src/**/*.ts",
      "**/node_modules/**",
      "*.log",
      "**/*.test.ts",
      "src/*",
      "**",
      "*",
    ];
    const start = Date.now();
    for (let i = 0; i < 100_000; i++) {
      const path = paths[i % paths.length];
      const pat = patterns[i % patterns.length];
      globMatch(path, pat);
    }
    expect(Date.now() - start).toBeLessThan(5000);
  });
});

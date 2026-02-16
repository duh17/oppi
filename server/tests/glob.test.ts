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
});

import { describe, it, expect } from "vitest";
import { matchBashPattern, parseBashCommand, splitBashCommandChain } from "../src/policy-bash.js";

// ─── splitBashCommandChain ───────────────────────────────────────────

describe("splitBashCommandChain", () => {
  it("splits compound && command into segments", () => {
    const cmd =
      "cd /Users/testuser/workspace/oppi && git add -A && git commit --amend --no-edit && git push --force-with-lease origin main 2>&1 | tail -5";
    const segments = splitBashCommandChain(cmd);
    expect(segments).toEqual([
      "cd /Users/testuser/workspace/oppi",
      "git add -A",
      "git commit --amend --no-edit",
      "git push --force-with-lease origin main 2>&1 | tail -5",
    ]);
  });

  it("returns single command as-is", () => {
    expect(splitBashCommandChain("git push origin main")).toEqual(["git push origin main"]);
  });

  it("handles semicolons", () => {
    expect(splitBashCommandChain("cd foo; git push origin main")).toEqual([
      "cd foo",
      "git push origin main",
    ]);
  });
});

// ─── parseBashCommand ────────────────────────────────────────────────

describe("parseBashCommand", () => {
  it("extracts executable from simple command", () => {
    const parsed = parseBashCommand("git push --force-with-lease origin main");
    expect(parsed.executable).toBe("git");
    expect(parsed.args).toContain("push");
    expect(parsed.args).toContain("--force-with-lease");
  });

  it("extracts executable from command with redirects", () => {
    const parsed = parseBashCommand("git push --force-with-lease origin main 2>&1 | tail -5");
    expect(parsed.executable).toBe("git");
    expect(parsed.hasPipe).toBe(true);
  });
});

// ─── matchBashPattern ────────────────────────────────────────────────

describe("matchBashPattern", () => {
  describe("git push* pattern", () => {
    const pattern = "git push*";

    it("matches simple git push", () => {
      expect(matchBashPattern("git push origin main", pattern)).toBe(true);
    });

    it("matches git push --force", () => {
      expect(matchBashPattern("git push --force origin main", pattern)).toBe(true);
    });

    it("matches git push --force-with-lease", () => {
      expect(matchBashPattern("git push --force-with-lease origin main", pattern)).toBe(true);
    });

    it("matches git push --force-with-lease with pipe/redirect", () => {
      expect(
        matchBashPattern("git push --force-with-lease origin main 2>&1 | tail -5", pattern),
      ).toBe(true);
    });

    it("does NOT match git add", () => {
      expect(matchBashPattern("git add -A", pattern)).toBe(false);
    });

    it("does NOT match git commit", () => {
      expect(matchBashPattern("git commit --amend --no-edit", pattern)).toBe(false);
    });

    it("does NOT match cd", () => {
      expect(matchBashPattern("cd /Users/testuser/workspace/oppi", pattern)).toBe(false);
    });
  });

  describe("git push*--force* pattern", () => {
    const pattern = "git push*--force*";

    it("matches git push --force", () => {
      expect(matchBashPattern("git push --force origin main", pattern)).toBe(true);
    });

    it("matches git push --force-with-lease", () => {
      expect(matchBashPattern("git push --force-with-lease origin main", pattern)).toBe(true);
    });

    it("matches git push --force-with-lease with pipe/redirect", () => {
      expect(
        matchBashPattern("git push --force-with-lease origin main 2>&1 | tail -5", pattern),
      ).toBe(true);
    });

    it("does NOT match normal git push", () => {
      expect(matchBashPattern("git push origin main", pattern)).toBe(false);
    });
  });

  describe("git push*-f* pattern", () => {
    const pattern = "git push*-f*";

    it("matches git push -f", () => {
      expect(matchBashPattern("git push -f origin main", pattern)).toBe(true);
    });

    it("matches git push --force-with-lease (contains -f substring)", () => {
      // Note: -f appears inside --force-with-lease
      expect(matchBashPattern("git push --force-with-lease origin main", pattern)).toBe(true);
    });
  });
});

// ─── End-to-end: compound command split + per-segment matching ───────

describe("compound git push detection (end-to-end)", () => {
  const fullCmd =
    "cd /Users/testuser/workspace/oppi && git add -A && git commit --amend --no-edit && git push --force-with-lease origin main 2>&1 | tail -5";

  it("at least one segment matches git push*", () => {
    const segments = splitBashCommandChain(fullCmd);
    const matched = segments.some((seg) => matchBashPattern(seg, "git push*"));
    expect(matched).toBe(true);
  });

  it("at least one segment matches git push*--force*", () => {
    const segments = splitBashCommandChain(fullCmd);
    const matched = segments.some((seg) => matchBashPattern(seg, "git push*--force*"));
    expect(matched).toBe(true);
  });

  it("the matching segment is the git push segment", () => {
    const segments = splitBashCommandChain(fullCmd);
    const pushSegment = segments.find((seg) => matchBashPattern(seg, "git push*"));
    expect(pushSegment).toBe("git push --force-with-lease origin main 2>&1 | tail -5");
  });

  it("git executable is correctly parsed from push segment", () => {
    const segments = splitBashCommandChain(fullCmd);
    const pushSegment = segments.find((seg) => matchBashPattern(seg, "git push*"));
    const parsed = parseBashCommand(pushSegment!);
    expect(parsed.executable).toBe("git");
  });
});

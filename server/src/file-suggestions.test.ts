import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { _testing, getFileSuggestions, isWithinWorkspace } from "./file-suggestions.js";

const { basename, matchScore, normalizeAbsoluteQuery, sanitizeQuery } = _testing;
const testRoot = join(tmpdir(), `oppi-file-suggestions-test-${Date.now()}`);
const extraRoot = join(tmpdir(), `oppi-file-suggestions-extra-${Date.now()}`);
const outsideRoot = join(tmpdir(), `oppi-file-suggestions-outside-${Date.now()}`);

beforeAll(() => createFixture());
afterAll(() => {
  rmSync(testRoot, { recursive: true, force: true });
  rmSync(extraRoot, { recursive: true, force: true });
  rmSync(outsideRoot, { recursive: true, force: true });
});

function createFixture(): void {
  const dirs = [
    "src/chat",
    "src/models",
    "src/networking",
    "docs",
    "node_modules/dep",
    ".git",
    "build",
  ];
  for (const dir of dirs) {
    mkdirSync(join(testRoot, dir), { recursive: true });
  }

  const files = [
    "src/chat/ChatView.swift",
    "src/chat/ChatInputBar.swift",
    "src/chat/ComposerAutocomplete.swift",
    "src/models/Session.swift",
    "src/models/Workspace.swift",
    "src/networking/ServerConnection.swift",
    "README.md",
    ".env",
    ".gitignore",
    "node_modules/dep/index.js",
    ".git/HEAD",
    "build/output.js",
    "docs/guide.md",
    "docs/changelog.md",
  ];
  for (const file of files) {
    writeFileSync(join(testRoot, file), `// ${file}`);
  }

  mkdirSync(extraRoot, { recursive: true });
  writeFileSync(join(extraRoot, "notes.md"), "# notes");

  mkdirSync(outsideRoot, { recursive: true });
  mkdirSync(join(outsideRoot, "secret"), { recursive: true });
  writeFileSync(join(outsideRoot, "secret/hidden.txt"), "hidden");

  try {
    symlinkSync(outsideRoot, join(testRoot, "linked-outside"), "dir");
  } catch {
    // Ignore on platforms/filesystems where symlinks are unavailable.
  }
}

function paths(query: string): string[] {
  return getFileSuggestions(testRoot, query).items.map((item) => item.path);
}

describe("sanitizeQuery", () => {
  it("strips leading slashes", () => {
    expect(sanitizeQuery("/etc/passwd")).toBe("etc/passwd");
    expect(sanitizeQuery("///foo")).toBe("foo");
  });

  it("removes .. segments", () => {
    expect(sanitizeQuery("../../../etc/passwd")).toBe("etc/passwd");
    expect(sanitizeQuery("src/../../secret")).toBe("src/secret");
    expect(sanitizeQuery("./src/./chat")).toBe("src/chat");
  });

  it("collapses multiple slashes", () => {
    expect(sanitizeQuery("src///chat")).toBe("src/chat");
  });

  it("clamps long queries", () => {
    expect(sanitizeQuery("a".repeat(200)).length).toBe(120);
  });

  it("trims whitespace", () => {
    expect(sanitizeQuery("  src/chat  ")).toBe("src/chat");
  });
});

describe("normalizeAbsoluteQuery", () => {
  it("normalizes absolute paths and preserves trailing slash", () => {
    expect(normalizeAbsoluteQuery("/tmp///foo/").endsWith("/")).toBe(true);
  });
});

describe("matchScore", () => {
  it("scores basename prefix highest", () => {
    expect(matchScore("src/chat/ChatView.swift", "chat")).toBe(3);
  });

  it("scores basename contains as 2", () => {
    expect(matchScore("src/chat/ComposerAutocomplete.swift", "auto")).toBe(2);
  });

  it("scores path component match as 1", () => {
    expect(matchScore("src/chat/ChatView.swift", "src")).toBe(1);
  });

  it("returns 1 for empty fragment", () => {
    expect(matchScore("anything.txt", "")).toBe(1);
  });
});

describe("basename", () => {
  it("extracts filename", () => {
    expect(basename("src/chat/ChatView.swift")).toBe("ChatView.swift");
  });

  it("handles directory paths", () => {
    expect(basename("src/chat/")).toBe("chat");
  });

  it("handles root-level files", () => {
    expect(basename("README.md")).toBe("README.md");
  });
});

describe("isWithinWorkspace", () => {
  it("accepts paths within root", () => {
    expect(isWithinWorkspace(join(testRoot, "src"), testRoot)).toBe(true);
    expect(isWithinWorkspace(join(testRoot, "src/chat"), testRoot)).toBe(true);
  });

  it("accepts root itself", () => {
    expect(isWithinWorkspace(testRoot, testRoot)).toBe(true);
  });

  it("rejects paths outside root", () => {
    expect(isWithinWorkspace("/etc/passwd", testRoot)).toBe(false);
    expect(isWithinWorkspace(join(testRoot, ".."), testRoot)).toBe(false);
  });

  it("rejects traversal attempts", () => {
    expect(isWithinWorkspace(join(testRoot, "src/../../etc"), testRoot)).toBe(false);
  });
});

describe("getFileSuggestions", () => {
  it("returns files matching a basename prefix", () => {
    const result = getFileSuggestions(testRoot, "Chat");
    expect(result.items.length).toBeGreaterThan(0);
    for (const item of result.items) {
      expect(item.path.toLowerCase()).toContain("chat");
    }
  });

  it("returns files for path prefix query", () => {
    const result = getFileSuggestions(testRoot, "src/chat/");
    expect(result.items.length).toBeGreaterThan(0);
    for (const item of result.items) {
      expect(item.path.startsWith("src/chat/")).toBe(true);
    }
  });

  it("filters within a directory", () => {
    const result = getFileSuggestions(testRoot, "src/chat/Comp");
    expect(result.items.length).toBe(1);
    expect(result.items[0].path).toBe("src/chat/ComposerAutocomplete.swift");
    expect(result.items[0].isDirectory).toBe(false);
  });

  it("includes directories with trailing slash", () => {
    const result = getFileSuggestions(testRoot, "src/");
    const dirs = result.items.filter((item) => item.isDirectory);
    expect(dirs.length).toBeGreaterThan(0);
    for (const dir of dirs) {
      expect(dir.path.endsWith("/")).toBe(true);
    }
  });

  it("returns empty results for traversal queries", () => {
    expect(getFileSuggestions(testRoot, "../../../etc/passwd").items).toEqual([]);
  });

  it("returns empty results for absolute path queries outside allowed roots", () => {
    expect(getFileSuggestions(testRoot, "/etc/passwd").items).toEqual([]);
  });

  it("returns absolute path suggestions for configured additional roots", () => {
    const result = getFileSuggestions(testRoot, `${extraRoot}/no`, [extraRoot]);
    expect(result.items.some((item) => item.path === `${extraRoot}/notes.md`)).toBe(true);
  });

  it("excludes ignored directories", () => {
    const allPaths = paths("");
    expect(allPaths.some((path) => path.startsWith(".git/") || path === ".git/")).toBe(false);
    expect(allPaths.some((path) => path.includes("node_modules"))).toBe(false);
    expect(allPaths.some((path) => path.startsWith("build/") && !path.endsWith("/"))).toBe(false);
  });

  it("includes dotfiles", () => {
    const allPaths = paths(".git");
    expect(allPaths).toContain(".gitignore");
    expect(paths(".env")).toContain(".env");
  });

  it("returns empty array for empty workspace query with no matching files", () => {
    const emptyDir = join(testRoot, "_empty_workspace_");
    mkdirSync(emptyDir, { recursive: true });

    const result = getFileSuggestions(emptyDir, "nonexistent");
    expect(result.items).toEqual([]);
    expect(result.truncated).toBe(false);

    rmSync(emptyDir, { recursive: true });
  });

  it("ranks basename prefix above substring", () => {
    const result = getFileSuggestions(testRoot, "Chat");
    const chatPrefixIdx = result.items.findIndex((item) => basename(item.path).startsWith("Chat"));
    const composerIdx = result.items.findIndex(
      (item) => basename(item.path) === "ComposerAutocomplete.swift",
    );

    if (chatPrefixIdx >= 0 && composerIdx >= 0) {
      expect(chatPrefixIdx).toBeLessThan(composerIdx);
    }
  });

  it("handles empty query (lists top-level entries)", () => {
    const result = getFileSuggestions(testRoot, "");
    expect(result.items.length).toBeGreaterThan(0);
    expect(result.items.map((item) => item.path)).toContain("README.md");
  });

  it("caps results at limit", () => {
    expect(getFileSuggestions(testRoot, "").items.length).toBeLessThanOrEqual(12);
  });

  it("does not recurse through symlinked directories outside workspace", () => {
    const result = getFileSuggestions(testRoot, "hidden");
    expect(result.items.some((item) => item.path.includes("hidden.txt"))).toBe(false);
  });
});

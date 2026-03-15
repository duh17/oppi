import { describe, expect, test, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { execSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  ALLOWED_EXTENSIONS,
  IGNORE_DIRS,
  SENSITIVE_FILE_PATTERNS,
  resolveWorkspaceFilePath,
  isSensitivePath,
  getContentType,
  listDirectoryEntries,
  searchWorkspaceFiles,
} from "./workspace-files.js";

// MARK: - ALLOWED_EXTENSIONS

describe("ALLOWED_EXTENSIONS", () => {
  test("allows image extensions", () => {
    for (const ext of [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]) {
      expect(ALLOWED_EXTENSIONS.has(ext), `should allow ${ext}`).toBe(true);
    }
  });

  test("rejects non-image extensions", () => {
    for (const ext of [".env", ".key", ".ts", ".js", ".json", ".txt", ".sh", ".py", ""]) {
      expect(ALLOWED_EXTENSIONS.has(ext), `should reject ${ext}`).toBe(false);
    }
  });
});

// MARK: - resolveWorkspaceFilePath

describe("resolveWorkspaceFilePath", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-test-"));
    // Create a real file inside the workspace
    mkdirSync(join(tmpRoot, "charts"), { recursive: true });
    writeFileSync(join(tmpRoot, "charts", "mockup.png"), Buffer.alloc(16, 0xff));
    writeFileSync(join(tmpRoot, "image.jpg"), Buffer.alloc(8, 0xab));
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("resolves a valid file inside workspace root", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, "image.jpg");
    expect(result).not.toBeNull();
    expect(result).toBeTruthy();
  });

  test("resolves a file in a subdirectory", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, "charts/mockup.png");
    expect(result).not.toBeNull();
    expect(result).toBeTruthy();
  });

  test("returns null for non-existent file", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, "missing.png");
    expect(result).toBeNull();
  });

  test("returns null for path traversal (../)", async () => {
    // Create a file outside the workspace root to try to access
    const outsideFile = join(tmpdir(), "secret.png");
    writeFileSync(outsideFile, "secret");
    try {
      const result = await resolveWorkspaceFilePath(tmpRoot, "../secret.png");
      expect(result).toBeNull();
    } finally {
      rmSync(outsideFile, { force: true });
    }
  });

  test("returns null for deep path traversal", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, "charts/../../etc/passwd");
    expect(result).toBeNull();
  });

  test("returns null for absolute path escape", async () => {
    // An absolute path component won't traverse out, but join handles it —
    // join('/workspace', '/etc/passwd') = '/etc/passwd'
    const result = await resolveWorkspaceFilePath(tmpRoot, "/etc/passwd");
    // This should be null because /etc/passwd is not under tmpRoot
    expect(result).toBeNull();
  });

  test("returns null for symlink that points outside workspace", async () => {
    // Create a symlink inside workspace pointing outside
    const outsideFile = join(tmpdir(), "escape-target.png");
    writeFileSync(outsideFile, "escape");
    const symlinkPath = join(tmpRoot, "escape.png");
    symlinkSync(outsideFile, symlinkPath);

    try {
      const result = await resolveWorkspaceFilePath(tmpRoot, "escape.png");
      expect(result).toBeNull();
    } finally {
      rmSync(outsideFile, { force: true });
    }
  });

  test("allows symlink pointing inside workspace", async () => {
    // Create a symlink inside workspace pointing to another file inside workspace
    const symlinkPath = join(tmpRoot, "alias.png");
    symlinkSync(join(tmpRoot, "image.jpg"), symlinkPath);

    const result = await resolveWorkspaceFilePath(tmpRoot, "alias.png");
    // The resolved path should not be null — it points to image.jpg inside the workspace
    expect(result).not.toBeNull();
  });

  test("resolves workspace root with empty path", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, "");
    expect(result).not.toBeNull();
  });

  test("resolves workspace root with dot path", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, ".");
    expect(result).not.toBeNull();
  });
});

// MARK: - IGNORE_DIRS

describe("IGNORE_DIRS", () => {
  test("contains common build/dependency directories", () => {
    for (const dir of [".git", "node_modules", ".next", "dist", "build", "__pycache__"]) {
      expect(IGNORE_DIRS.has(dir), `should ignore ${dir}`).toBe(true);
    }
  });

  test("contains platform-specific directories", () => {
    for (const dir of ["DerivedData", ".build", "Pods"]) {
      expect(IGNORE_DIRS.has(dir), `should ignore ${dir}`).toBe(true);
    }
  });

  test("does not contain normal project directories", () => {
    for (const dir of ["src", "lib", "test", "docs", ".github", ".vscode"]) {
      expect(IGNORE_DIRS.has(dir), `should not ignore ${dir}`).toBe(false);
    }
  });
});

// MARK: - SENSITIVE_FILE_PATTERNS

describe("SENSITIVE_FILE_PATTERNS", () => {
  function matchesAny(filename: string): boolean {
    return SENSITIVE_FILE_PATTERNS.some((p) => p.test(filename));
  }

  test("matches .env files", () => {
    expect(matchesAny(".env")).toBe(true);
    expect(matchesAny(".env.local")).toBe(true);
    expect(matchesAny(".env.production")).toBe(true);
    expect(matchesAny(".env.development.local")).toBe(true);
  });

  test("matches private key files", () => {
    expect(matchesAny("server.pem")).toBe(true);
    expect(matchesAny("private.key")).toBe(true);
    expect(matchesAny("cert.PEM")).toBe(true);
    expect(matchesAny("tls.KEY")).toBe(true);
  });

  test("matches SSH private keys", () => {
    expect(matchesAny("id_rsa")).toBe(true);
    expect(matchesAny("id_ed25519")).toBe(true);
    expect(matchesAny("id_ecdsa")).toBe(true);
    expect(matchesAny("id_dsa")).toBe(true);
  });

  test("matches credential files", () => {
    expect(matchesAny(".netrc")).toBe(true);
    expect(matchesAny(".npmrc")).toBe(true);
    expect(matchesAny(".pypirc")).toBe(true);
    expect(matchesAny(".htpasswd")).toBe(true);
  });

  test("does not match normal files", () => {
    expect(matchesAny("index.ts")).toBe(false);
    expect(matchesAny("README.md")).toBe(false);
    expect(matchesAny("package.json")).toBe(false);
    expect(matchesAny("image.png")).toBe(false);
    expect(matchesAny("environment.ts")).toBe(false);
  });
});

// MARK: - isSensitivePath

describe("isSensitivePath", () => {
  test("blocks .env files at any level", () => {
    expect(isSensitivePath(".env")).toBe(true);
    expect(isSensitivePath(".env.local")).toBe(true);
    expect(isSensitivePath("config/.env.production")).toBe(true);
  });

  test("blocks private key files", () => {
    expect(isSensitivePath("certs/server.pem")).toBe(true);
    expect(isSensitivePath("ssl/private.key")).toBe(true);
  });

  test("blocks SSH private keys", () => {
    expect(isSensitivePath("id_rsa")).toBe(true);
    expect(isSensitivePath("keys/id_ed25519")).toBe(true);
  });

  test("blocks .git directory contents", () => {
    expect(isSensitivePath(".git/objects/abc123")).toBe(true);
    expect(isSensitivePath(".git/config")).toBe(true);
    expect(isSensitivePath(".git/HEAD")).toBe(true);
    expect(isSensitivePath("submodule/.git/config")).toBe(true);
  });

  test("allows normal files", () => {
    expect(isSensitivePath("src/index.ts")).toBe(false);
    expect(isSensitivePath("README.md")).toBe(false);
    expect(isSensitivePath("package.json")).toBe(false);
    expect(isSensitivePath("charts/mockup.png")).toBe(false);
    expect(isSensitivePath(".gitignore")).toBe(false);
    expect(isSensitivePath(".github/workflows/ci.yml")).toBe(false);
  });

  test("does not false-positive on env-like names", () => {
    expect(isSensitivePath("environment.ts")).toBe(false);
    expect(isSensitivePath("config.env.ts")).toBe(false);
    expect(isSensitivePath("src/env-utils.ts")).toBe(false);
  });
});

// MARK: - getContentType

describe("getContentType", () => {
  test("returns image content types", () => {
    expect(getContentType(".png", "image.png")).toBe("image/png");
    expect(getContentType(".jpg", "photo.jpg")).toBe("image/jpeg");
    expect(getContentType(".gif", "anim.gif")).toBe("image/gif");
    expect(getContentType(".webp", "photo.webp")).toBe("image/webp");
    expect(getContentType(".svg", "icon.svg")).toBe("image/svg+xml");
  });

  test("returns special structured content types", () => {
    expect(getContentType(".json", "package.json")).toBe("application/json; charset=utf-8");
    expect(getContentType(".html", "index.html")).toBe("text/html; charset=utf-8");
    expect(getContentType(".css", "styles.css")).toBe("text/css; charset=utf-8");
    expect(getContentType(".xml", "config.xml")).toBe("text/xml; charset=utf-8");
    expect(getContentType(".csv", "data.csv")).toBe("text/csv; charset=utf-8");
    expect(getContentType(".pdf", "doc.pdf")).toBe("application/pdf");
  });

  test("returns text/plain for code files", () => {
    expect(getContentType(".ts", "index.ts")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".py", "script.py")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".rs", "main.rs")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".go", "main.go")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".swift", "App.swift")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".sh", "build.sh")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".yml", "config.yml")).toBe("text/plain; charset=utf-8");
    expect(getContentType(".md", "README.md")).toBe("text/plain; charset=utf-8");
  });

  test("returns text/plain for well-known extensionless filenames", () => {
    expect(getContentType("", "Makefile")).toBe("text/plain; charset=utf-8");
    expect(getContentType("", "Dockerfile")).toBe("text/plain; charset=utf-8");
    expect(getContentType("", "LICENSE")).toBe("text/plain; charset=utf-8");
    expect(getContentType("", "README")).toBe("text/plain; charset=utf-8");
  });

  test("is case-insensitive for extensionless filenames", () => {
    expect(getContentType("", "makefile")).toBe("text/plain; charset=utf-8");
    expect(getContentType("", "MAKEFILE")).toBe("text/plain; charset=utf-8");
    expect(getContentType("", "dockerfile")).toBe("text/plain; charset=utf-8");
  });

  test("returns octet-stream for unknown extensions", () => {
    expect(getContentType(".bin", "data.bin")).toBe("application/octet-stream");
    expect(getContentType(".wasm", "module.wasm")).toBe("application/octet-stream");
    expect(getContentType("", "unknownfile")).toBe("application/octet-stream");
  });
});

// MARK: - listDirectoryEntries

describe("listDirectoryEntries", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-listing-"));
    mkdirSync(join(tmpRoot, "src"), { recursive: true });
    mkdirSync(join(tmpRoot, ".github"), { recursive: true });
    mkdirSync(join(tmpRoot, "node_modules", "dep"), { recursive: true });
    mkdirSync(join(tmpRoot, ".git", "objects"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "package.json"), '{"name":"test"}');
    writeFileSync(join(tmpRoot, "src", "index.ts"), "console.log('hi')");
    writeFileSync(join(tmpRoot, "src", "utils.ts"), "export function foo() {}");
    writeFileSync(join(tmpRoot, ".github", "ci.yml"), "name: CI");
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "module.exports = {}");
    writeFileSync(join(tmpRoot, ".git", "HEAD"), "ref: refs/heads/main");
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("lists root directory entries", async () => {
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).toContain("src");
    expect(names).toContain(".github");
    expect(names).toContain("README.md");
    expect(names).toContain("package.json");
  });

  test("skips ignored directories", async () => {
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).not.toContain("node_modules");
    expect(names).not.toContain(".git");
  });

  test("does not skip non-ignored dotdirs", async () => {
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).toContain(".github");
  });

  test("lists subdirectory entries", async () => {
    const result = await listDirectoryEntries(tmpRoot, "src");
    expect(result).not.toBeNull();
    expect(result!.entries).toHaveLength(2);
    const names = result!.entries.map((e) => e.name);
    expect(names).toContain("index.ts");
    expect(names).toContain("utils.ts");
  });

  test("sorts directories before files, alphabetically within each", async () => {
    mkdirSync(join(tmpRoot, "zzz-dir"), { recursive: true });
    writeFileSync(join(tmpRoot, "aaa-file.txt"), "");

    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();

    const dirs = result!.entries.filter((e) => e.type === "directory");
    const files = result!.entries.filter((e) => e.type === "file");

    // Directories come before files
    const lastDirIdx = result!.entries.lastIndexOf(dirs[dirs.length - 1]);
    const firstFileIdx = result!.entries.indexOf(files[0]);
    expect(lastDirIdx).toBeLessThan(firstFileIdx);

    // Directories are alphabetically sorted (localeCompare)
    const dirNames = dirs.map((e) => e.name);
    expect(dirNames).toEqual([...dirNames].sort((a, b) => a.localeCompare(b)));

    // Files are alphabetically sorted (localeCompare)
    const fileNames = files.map((e) => e.name);
    expect(fileNames).toEqual([...fileNames].sort((a, b) => a.localeCompare(b)));
  });

  test("entries include correct type, size, and modifiedAt", async () => {
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();

    const readme = result!.entries.find((e) => e.name === "README.md");
    expect(readme).toBeDefined();
    expect(readme!.type).toBe("file");
    expect(readme!.size).toBe(7); // "# Hello" = 7 bytes
    expect(readme!.modifiedAt).toBeGreaterThan(0);

    const srcDir = result!.entries.find((e) => e.name === "src");
    expect(srcDir).toBeDefined();
    expect(srcDir!.type).toBe("directory");
  });

  test("returns null for non-existent directory", async () => {
    const result = await listDirectoryEntries(tmpRoot, "nonexistent");
    expect(result).toBeNull();
  });

  test("returns null when path points to a file", async () => {
    const result = await listDirectoryEntries(tmpRoot, "README.md");
    expect(result).toBeNull();
  });

  test("rejects path traversal", async () => {
    const result = await listDirectoryEntries(tmpRoot, "..");
    expect(result).toBeNull();
  });

  test("handles empty directory", async () => {
    mkdirSync(join(tmpRoot, "empty"), { recursive: true });
    const result = await listDirectoryEntries(tmpRoot, "empty");
    expect(result).not.toBeNull();
    expect(result!.entries).toHaveLength(0);
    expect(result!.truncated).toBe(false);
  });

  test("skips .DS_Store files", async () => {
    writeFileSync(join(tmpRoot, ".DS_Store"), Buffer.alloc(4));
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).not.toContain(".DS_Store");
  });
});

// MARK: - searchWorkspaceFiles

describe("searchWorkspaceFiles", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-search-"));
    mkdirSync(join(tmpRoot, "src", "components"), { recursive: true });
    mkdirSync(join(tmpRoot, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "package.json"), "{}");
    writeFileSync(join(tmpRoot, "src", "index.ts"), "console.log('hi')");
    writeFileSync(join(tmpRoot, "src", "App.tsx"), "export const App = () => {}");
    writeFileSync(
      join(tmpRoot, "src", "components", "Button.tsx"),
      "export const Button = () => {}",
    );
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "module.exports = {}");
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("finds files matching query by name", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "index");
    expect(result.entries.length).toBeGreaterThanOrEqual(1);
    const paths = result.entries.map((e) => e.path);
    expect(paths).toContain("src/index.ts");
  });

  test("search is case-insensitive", async () => {
    const upper = await searchWorkspaceFiles(tmpRoot, "README");
    expect(upper.entries.length).toBeGreaterThanOrEqual(1);

    const lower = await searchWorkspaceFiles(tmpRoot, "readme");
    expect(lower.entries.length).toBeGreaterThanOrEqual(1);
  });

  test("matches path components", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "components");
    expect(result.entries.length).toBeGreaterThanOrEqual(1);
    expect(result.entries.some((e) => e.path?.includes("components"))).toBe(true);
  });

  test("returns empty for no matches", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "zzzznotfound");
    expect(result.entries).toHaveLength(0);
  });

  test("returns empty for empty query", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "");
    expect(result.entries).toHaveLength(0);
  });

  test("returns empty for whitespace-only query", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "   ");
    expect(result.entries).toHaveLength(0);
  });

  test("entries include name, path, type, size, modifiedAt", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "Button");
    expect(result.entries.length).toBeGreaterThanOrEqual(1);
    const button = result.entries.find((e) => e.name === "Button.tsx");
    expect(button).toBeDefined();
    expect(button!.path).toBe("src/components/Button.tsx");
    expect(button!.type).toBe("file");
    expect(button!.size).toBeGreaterThan(0);
    expect(button!.modifiedAt).toBeGreaterThan(0);
  });

  test("skips files in ignored directories (walk fallback)", async () => {
    // tmpRoot is not a git repo, so the walk fallback is used
    const result = await searchWorkspaceFiles(tmpRoot, "dep");
    const paths = result.entries.map((e) => e.path);
    expect(paths).not.toContain("node_modules/dep/index.js");
  });

  test("finds files with extension in query", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, ".tsx");
    expect(result.entries.length).toBeGreaterThanOrEqual(2);
    const paths = result.entries.map((e) => e.path);
    expect(paths).toContain("src/App.tsx");
    expect(paths).toContain("src/components/Button.tsx");
  });
});

// MARK: - searchWorkspaceFiles (git-backed)

describe("searchWorkspaceFiles with git repo", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-git-search-"));
    execSync("git init", { cwd: tmpRoot, stdio: "ignore" });
    execSync("git config user.email test@test.com", { cwd: tmpRoot, stdio: "ignore" });
    execSync("git config user.name Test", { cwd: tmpRoot, stdio: "ignore" });

    mkdirSync(join(tmpRoot, "src"), { recursive: true });
    mkdirSync(join(tmpRoot, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "src", "app.ts"), "console.log('hi')");
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "module.exports = {}");
    // .gitignore to exclude node_modules
    writeFileSync(join(tmpRoot, ".gitignore"), "node_modules/\n");

    execSync("git add -A && git commit -m init", { cwd: tmpRoot, stdio: "ignore" });
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("uses git ls-files and respects .gitignore", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "index");
    const paths = result.entries.map((e) => e.path);
    // node_modules/dep/index.js is gitignored — should not appear
    expect(paths).not.toContain("node_modules/dep/index.js");
  });

  test("finds tracked files", async () => {
    const result = await searchWorkspaceFiles(tmpRoot, "app");
    const paths = result.entries.map((e) => e.path);
    expect(paths).toContain("src/app.ts");
  });

  test("finds untracked but non-ignored files", async () => {
    // Create an untracked file that's not in .gitignore
    writeFileSync(join(tmpRoot, "src", "new-feature.ts"), "export {}");

    const result = await searchWorkspaceFiles(tmpRoot, "new-feature");
    const paths = result.entries.map((e) => e.path);
    expect(paths).toContain("src/new-feature.ts");
  });
});

// MARK: - resolveWorkspaceFilePath (security verification)

describe("resolveWorkspaceFilePath — security edge cases", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-security-"));
    mkdirSync(join(tmpRoot, "sub"), { recursive: true });
    writeFileSync(join(tmpRoot, "file.txt"), "content");
    writeFileSync(join(tmpRoot, "sub", "nested.txt"), "nested");
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("rejects URL-encoded traversal (%2e%2e) as literal path", async () => {
    // %2e%2e is decoded by URL parser to ".." before reaching the route,
    // but if it somehow arrives encoded, it becomes a literal directory name
    // that doesn't exist — realpath fails and returns null
    const result = await resolveWorkspaceFilePath(tmpRoot, "%2e%2e/etc/passwd");
    expect(result).toBeNull();
  });

  test("rejects double-encoded traversal (%252e%252e) as literal path", async () => {
    const result = await resolveWorkspaceFilePath(tmpRoot, "%252e%252e/etc/passwd");
    expect(result).toBeNull();
  });

  test("rejects null bytes in path", async () => {
    // Node.js fs rejects null bytes with ERR_INVALID_ARG_VALUE
    const result = await resolveWorkspaceFilePath(tmpRoot, "file.txt\x00.png");
    expect(result).toBeNull();
  });

  test("rejects symlink chain escaping workspace", async () => {
    // symlink A -> B -> outside
    const outsideFile = join(tmpdir(), `oppi-escape-chain-${Date.now()}`);
    writeFileSync(outsideFile, "escaped");
    const linkB = join(tmpRoot, "link-b");
    symlinkSync(outsideFile, linkB);
    const linkA = join(tmpRoot, "link-a");
    symlinkSync(linkB, linkA);

    try {
      const result = await resolveWorkspaceFilePath(tmpRoot, "link-a");
      // realpath resolves the full chain; the final target is outside workspace
      expect(result).toBeNull();
    } finally {
      rmSync(outsideFile, { force: true });
    }
  });

  test("rejects directory symlink pointing outside workspace", async () => {
    const outsideDir = mkdtempSync(join(tmpdir(), "oppi-escape-dir-"));
    writeFileSync(join(outsideDir, "secret.txt"), "secret");
    symlinkSync(outsideDir, join(tmpRoot, "escape-dir"));

    try {
      // The symlink dir resolves outside workspace root
      const result = await resolveWorkspaceFilePath(tmpRoot, "escape-dir/secret.txt");
      expect(result).toBeNull();
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
    }
  });

  test("handles workspace root that is itself a symlink", async () => {
    // Create a symlink to our tmpRoot, use that as the workspace root
    const symlinkRoot = join(tmpdir(), `oppi-ws-symlink-root-${Date.now()}`);
    symlinkSync(tmpRoot, symlinkRoot);

    try {
      // Should still resolve files correctly — realpath normalizes both sides
      const result = await resolveWorkspaceFilePath(symlinkRoot, "file.txt");
      expect(result).not.toBeNull();

      // Traversal should still be blocked
      const escaped = await resolveWorkspaceFilePath(symlinkRoot, "../etc/passwd");
      expect(escaped).toBeNull();
    } finally {
      rmSync(symlinkRoot, { force: true });
    }
  });
});

// MARK: - isSensitivePath (security verification)

describe("isSensitivePath — security edge cases", () => {
  test("blocks id_rsa.pub (matches id_rsa prefix)", () => {
    // Note: this IS the current behavior — id_rsa pattern matches the prefix
    // of id_rsa.pub. This is arguably over-protective but safe.
    expect(isSensitivePath("id_rsa.pub")).toBe(true);
  });

  test("blocks deeply nested .env", () => {
    expect(isSensitivePath("a/b/c/d/.env")).toBe(true);
    expect(isSensitivePath("deploy/config/.env.staging")).toBe(true);
  });

  test("blocks .git at any directory depth", () => {
    expect(isSensitivePath(".git/refs/heads/main")).toBe(true);
    expect(isSensitivePath("vendor/.git/config")).toBe(true);
  });

  test("does not block .gitignore or .github", () => {
    // .git is a path segment check, not a prefix match on filenames
    expect(isSensitivePath(".gitignore")).toBe(false);
    expect(isSensitivePath(".github/workflows/ci.yml")).toBe(false);
    expect(isSensitivePath(".gitattributes")).toBe(false);
  });

  test("does not block .env-like filenames that are actually code", () => {
    expect(isSensitivePath("src/env.ts")).toBe(false);
    expect(isSensitivePath("config/environment.yaml")).toBe(false);
    expect(isSensitivePath("lib/dotenv-parser.js")).toBe(false);
  });

  test("blocks files with mixed case extensions", () => {
    expect(isSensitivePath("cert.PEM")).toBe(true);
    expect(isSensitivePath("private.KEY")).toBe(true);
    expect(isSensitivePath("cert.Pem")).toBe(true);
  });
});

// MARK: - listDirectoryEntries (security verification)

describe("listDirectoryEntries — security edge cases", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-list-sec-"));
    mkdirSync(join(tmpRoot, "src"), { recursive: true });
    writeFileSync(join(tmpRoot, "src", "app.ts"), "code");
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("rejects directory listing via symlink pointing outside workspace", async () => {
    const outsideDir = mkdtempSync(join(tmpdir(), "oppi-escape-list-"));
    writeFileSync(join(outsideDir, "secret.txt"), "secret");
    symlinkSync(outsideDir, join(tmpRoot, "escape-dir"));

    try {
      const result = await listDirectoryEntries(tmpRoot, "escape-dir");
      // resolveWorkspaceFilePath rejects symlinks outside the root
      expect(result).toBeNull();
    } finally {
      rmSync(outsideDir, { recursive: true, force: true });
    }
  });

  test("sensitive files appear in listings (visible but not servable)", async () => {
    writeFileSync(join(tmpRoot, ".env"), "SECRET=x");
    writeFileSync(join(tmpRoot, "id_rsa"), "-----BEGIN RSA PRIVATE KEY-----");
    writeFileSync(join(tmpRoot, "cert.pem"), "cert data");

    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    // Sensitive files ARE listed — users should know they exist
    expect(names).toContain(".env");
    expect(names).toContain("id_rsa");
    expect(names).toContain("cert.pem");
    // But isSensitivePath would block serving them (tested separately)
  });

  test("handles filenames with spaces and special characters", async () => {
    writeFileSync(join(tmpRoot, "my file.txt"), "content");
    writeFileSync(join(tmpRoot, "file (copy).ts"), "copy");

    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).toContain("my file.txt");
    expect(names).toContain("file (copy).ts");
  });
});

// MARK: - resolveWorkspaceFilePath (filenames with special characters)

describe("resolveWorkspaceFilePath — special characters", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-special-"));
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("resolves filenames with spaces", async () => {
    writeFileSync(join(tmpRoot, "my file.txt"), "content");
    const result = await resolveWorkspaceFilePath(tmpRoot, "my file.txt");
    expect(result).not.toBeNull();
  });

  test("resolves filenames with unicode characters", async () => {
    writeFileSync(join(tmpRoot, "日本語.txt"), "content");
    const result = await resolveWorkspaceFilePath(tmpRoot, "日本語.txt");
    expect(result).not.toBeNull();
  });

  test("resolves filenames with parentheses and brackets", async () => {
    writeFileSync(join(tmpRoot, "file (1).txt"), "content");
    writeFileSync(join(tmpRoot, "file [draft].md"), "content");
    const r1 = await resolveWorkspaceFilePath(tmpRoot, "file (1).txt");
    const r2 = await resolveWorkspaceFilePath(tmpRoot, "file [draft].md");
    expect(r1).not.toBeNull();
    expect(r2).not.toBeNull();
  });
});

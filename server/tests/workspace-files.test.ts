import { describe, expect, test, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { execSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";

import { parseByteRangeHeader } from "../src/http-range.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import type { RouteContext } from "../src/routes/types.js";
import { createWorkspaceWorktree } from "../src/worktrees.js";
import type { Workspace } from "../src/types.js";
import { makeResponse } from "./harness/route-test-helpers.js";

import {
  ALLOWED_EXTENSIONS,
  SEARCH_IGNORE_DIRS,
  SEARCH_ROOT_IGNORE_DIRS,
  SENSITIVE_FILE_PATTERNS,
  resolveWorkspaceFilePath,
  isSensitivePath,
  getContentType,
  isBrowseMediaContentType,
  isStreamingMediaContentType,
  listDirectoryEntries,
  getFileIndex,
} from "../src/routes/workspace-files.js";

// MARK: - ALLOWED_EXTENSIONS

describe("ALLOWED_EXTENSIONS", () => {
  test("allows image extensions", () => {
    for (const ext of [
      ".png",
      ".jpg",
      ".jpeg",
      ".gif",
      ".webp",
      ".bmp",
      ".tif",
      ".tiff",
      ".ico",
      ".svg",
    ]) {
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

// MARK: - File-browser visibility filters

describe("file-browser visibility filters", () => {
  test("search skips common bulky generated/dependency directories", () => {
    for (const dir of [".git", "node_modules", ".next", "dist", "build", "__pycache__"]) {
      expect(SEARCH_IGNORE_DIRS.has(dir), `search should ignore ${dir}`).toBe(true);
    }
  });

  test("search skips platform-specific generated directories", () => {
    for (const dir of ["DerivedData", ".build", "Pods"]) {
      expect(SEARCH_IGNORE_DIRS.has(dir), `search should ignore ${dir}`).toBe(true);
    }
  });

  test("search does not control directory browsing visibility", () => {
    for (const dir of [".git", "node_modules", ".build", "dist"]) {
      expect(SEARCH_IGNORE_DIRS.has(dir), `search may ignore ${dir}`).toBe(true);
    }
  });

  test("search does not ignore normal project directories", () => {
    for (const dir of ["src", "lib", "test", "docs", ".github", ".vscode"]) {
      expect(SEARCH_IGNORE_DIRS.has(dir), `search should not ignore ${dir}`).toBe(false);
    }
  });

  test("keeps root-only private state separate from generic directory exclusions", () => {
    expect(SEARCH_IGNORE_DIRS.has(".pi")).toBe(false);
    expect(SEARCH_ROOT_IGNORE_DIRS.has(".pi")).toBe(true);
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

  test("returns video content types", () => {
    expect(getContentType(".mp4", "clip.mp4")).toBe("video/mp4");
    expect(getContentType(".mov", "recording.mov")).toBe("video/quicktime");
    expect(getContentType(".m4v", "movie.m4v")).toBe("video/x-m4v");
    expect(getContentType(".avi", "old.avi")).toBe("video/x-msvideo");
    expect(getContentType(".webm", "web.webm")).toBe("video/webm");
  });

  test("returns audio content types", () => {
    expect(getContentType(".mp3", "song.mp3")).toBe("audio/mpeg");
    expect(getContentType(".m4a", "voice.m4a")).toBe("audio/mp4");
    expect(getContentType(".wav", "sample.wav")).toBe("audio/wav");
    expect(getContentType(".aac", "track.aac")).toBe("audio/aac");
    expect(getContentType(".ogg", "podcast.ogg")).toBe("audio/ogg");
    expect(getContentType(".flac", "lossless.flac")).toBe("audio/flac");
    expect(getContentType(".opus", "voice.opus")).toBe("audio/opus");
  });

  test("infers additional audio and video content types from filename", () => {
    expect(getContentType(".aiff", "clip.aiff")).toBe("audio/x-aiff");
    expect(getContentType(".caf", "recording.caf")).toBe("audio/x-caf");
    expect(getContentType(".mkv", "movie.mkv")).toBe("video/x-matroska");
    expect(getContentType(".m3u8", "stream.m3u8")).toBe("application/vnd.apple.mpegurl");
    expect(getContentType(".oga", "voice.oga")).toBe("audio/ogg");
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

// MARK: - media content helpers

describe("media content helpers", () => {
  test("recognizes streaming media content types", () => {
    expect(isStreamingMediaContentType("video/x-matroska")).toBe(true);
    expect(isStreamingMediaContentType("audio/x-caf")).toBe(true);
    expect(isStreamingMediaContentType("application/vnd.apple.mpegurl")).toBe(true);
    expect(isStreamingMediaContentType("text/plain; charset=utf-8")).toBe(false);
  });

  test("recognizes browse media content types", () => {
    expect(isBrowseMediaContentType("image/png")).toBe(true);
    expect(isBrowseMediaContentType("application/pdf")).toBe(true);
    expect(isBrowseMediaContentType("video/mp4")).toBe(true);
    expect(isBrowseMediaContentType("application/octet-stream")).toBe(false);
  });
});

// MARK: - parseByteRangeHeader

describe("parseByteRangeHeader", () => {
  test("parses a bounded byte range", () => {
    expect(parseByteRangeHeader("bytes=0-1", 10)).toEqual({ kind: "valid", start: 0, end: 1 });
  });

  test("parses an open-ended byte range", () => {
    expect(parseByteRangeHeader("bytes=4-", 10)).toEqual({ kind: "valid", start: 4, end: 9 });
  });

  test("parses a suffix byte range", () => {
    expect(parseByteRangeHeader("bytes=-4", 10)).toEqual({ kind: "valid", start: 6, end: 9 });
  });

  test("clamps an oversized end offset to the file size", () => {
    expect(parseByteRangeHeader("bytes=7-100", 10)).toEqual({ kind: "valid", start: 7, end: 9 });
  });

  test("ignores unsupported range units", () => {
    expect(parseByteRangeHeader("items=0-1", 10)).toEqual({ kind: "none" });
  });

  test("rejects multipart ranges instead of generating multipart bodies", () => {
    expect(parseByteRangeHeader("bytes=0-1,4-5", 10)).toEqual({ kind: "invalid" });
  });

  test("marks empty or out-of-bounds ranges unsatisfiable", () => {
    expect(parseByteRangeHeader("bytes=-0", 10)).toEqual({ kind: "unsatisfiable" });
    expect(parseByteRangeHeader("bytes=10-12", 10)).toEqual({ kind: "unsatisfiable" });
    expect(parseByteRangeHeader("bytes=0-1", 0)).toEqual({ kind: "unsatisfiable" });
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
    mkdirSync(join(tmpRoot, ".build", "videos"), { recursive: true });
    mkdirSync(join(tmpRoot, ".git", "objects"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "package.json"), '{"name":"test"}');
    writeFileSync(join(tmpRoot, "src", "index.ts"), "console.log('hi')");
    writeFileSync(join(tmpRoot, "src", "utils.ts"), "export function foo() {}");
    writeFileSync(join(tmpRoot, ".github", "ci.yml"), "name: CI");
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "module.exports = {}");
    writeFileSync(join(tmpRoot, ".build", "videos", "recording.mp4"), "video");
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

  test("shows generated, dependency, and dot directories", async () => {
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).toContain("node_modules");
    expect(names).toContain(".build");
    expect(names).toContain(".git");
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

  test("shows dotfiles in directory listings", async () => {
    writeFileSync(join(tmpRoot, ".DS_Store"), Buffer.alloc(4));
    const result = await listDirectoryEntries(tmpRoot, "");
    expect(result).not.toBeNull();
    const names = result!.entries.map((e) => e.name);
    expect(names).toContain(".DS_Store");
  });
});

// MARK: - getFileIndex

describe("getFileIndex", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-index-"));
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

  test("returns flat file paths for client-side search", async () => {
    const result = await getFileIndex(tmpRoot);
    expect(result.paths).toContain("README.md");
    expect(result.paths).toContain("src/index.ts");
    expect(result.paths).toContain("src/App.tsx");
    expect(result.paths).toContain("src/components/Button.tsx");
    expect(result.truncated).toBe(false);
  });

  test("skips files in ignored directories when walking", async () => {
    const result = await getFileIndex(tmpRoot);
    expect(result.paths).not.toContain("node_modules/dep/index.js");
  });

  test("omits root .pi but includes nested .pi", async () => {
    mkdirSync(join(tmpRoot, ".pi", "private"), { recursive: true });
    mkdirSync(join(tmpRoot, "src", ".pi", "notes"), { recursive: true });
    writeFileSync(join(tmpRoot, ".pi", "private", "state.json"), "private");
    writeFileSync(join(tmpRoot, "src", ".pi", "notes", "user-note.md"), "note");

    const result = await getFileIndex(tmpRoot);

    expect(result.paths).not.toContain(".pi/private/state.json");
    expect(result.paths).toContain("src/.pi/notes/user-note.md");
  });

  test("omits sensitive files from the search index", async () => {
    mkdirSync(join(tmpRoot, "config", "secrets"), { recursive: true });
    writeFileSync(join(tmpRoot, ".env"), "SECRET=value");
    writeFileSync(join(tmpRoot, "config", "secrets", "server.pem"), "private key");
    writeFileSync(join(tmpRoot, "config", "secrets", ".netrc"), "machine example");

    const result = await getFileIndex(tmpRoot);

    expect(result.paths).not.toContain(".env");
    expect(result.paths).not.toContain("config/secrets/server.pem");
    expect(result.paths).not.toContain("config/secrets/.netrc");
  });

  test("omits generic ignored directories at any depth", async () => {
    for (const directory of SEARCH_IGNORE_DIRS) {
      const ignoredDirectory = join(tmpRoot, "nested", directory, "deeper");
      mkdirSync(ignoredDirectory, { recursive: true });
      writeFileSync(join(ignoredDirectory, "ignored.txt"), "ignored");
    }
    writeFileSync(join(tmpRoot, "nested", "visible.txt"), "visible");

    const result = await getFileIndex(tmpRoot);

    expect(result.paths).toContain("nested/visible.txt");
    for (const directory of SEARCH_IGNORE_DIRS) {
      expect(result.paths).not.toContain(`nested/${directory}/deeper/ignored.txt`);
    }
  });
});

// MARK: - workspace file routes

describe("workspace file routes", () => {
  test("lists data-dir worktree contents when worktreeId is supplied", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ws-route-worktree-"));
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-ws-route-worktree-data-"));

    try {
      execSync("git init -b main", { cwd: root, stdio: "ignore" });
      execSync("git config user.email test@test.com", { cwd: root, stdio: "ignore" });
      execSync("git config user.name Test", { cwd: root, stdio: "ignore" });
      writeFileSync(join(root, "main-only.txt"), "main\n");
      writeFileSync(join(root, "shared.txt"), "main shared\n");
      execSync("git add -A && git commit -m init", { cwd: root, stdio: "ignore" });

      const workspace: Workspace = {
        id: "ws-1",
        name: "Workspace",
        hostMount: root,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const worktree = createWorkspaceWorktree(workspace, { branch: "feature/files" }, { dataDir });
      rmSync(join(worktree.path, "main-only.txt"), { force: true });
      writeFileSync(join(worktree.path, "worktree-only.txt"), "worktree\n");
      writeFileSync(join(worktree.path, "shared.txt"), "worktree shared\n");

      const dispatch = createWorkspaceFileRoutes(
        {
          storage: {
            getWorkspace: (workspaceId: string) => (workspaceId === "ws-1" ? workspace : undefined),
            getDataDir: () => dataDir,
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();

      const handled = await dispatch({
        method: "GET",
        path: "/workspaces/ws-1/contents",
        url: new URL(`http://localhost/workspaces/ws-1/contents?worktreeId=${worktree.id}`),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as { entries: Array<{ name: string }> };
      const names = body.entries.map((entry) => entry.name);
      expect(names).toContain("worktree-only.txt");
      expect(names).not.toContain("main-only.txt");
    } finally {
      rmSync(root, { recursive: true, force: true });
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

describe("workspace file symlink security", () => {
  test("does not index or serve a symlink alias to a sensitive file", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ws-symlink-security-"));
    try {
      mkdirSync(join(root, "notes"), { recursive: true });
      writeFileSync(join(root, ".env"), "SECRET=value");
      writeFileSync(join(root, "notes", "safe.md"), "safe");
      symlinkSync("../.env", join(root, "notes", "report.md"));
      symlinkSync("safe.md", join(root, "notes", "safe-alias.md"));

      const index = await getFileIndex(root);
      expect(index.paths).toContain("notes/safe.md");
      expect(index.paths).not.toContain("notes/report.md");
      expect(index.paths).not.toContain("notes/safe-alias.md");

      const workspace: Workspace = {
        id: "ws-1",
        name: "Workspace",
        hostMount: root,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
      const dispatch = createWorkspaceFileRoutes(
        {
          storage: {
            getWorkspace: (workspaceId: string) => (workspaceId === "ws-1" ? workspace : undefined),
            getDataDir: () => root,
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const sensitiveResponse = makeResponse();
      const sensitiveHandled = await dispatch({
        method: "HEAD",
        path: "/workspaces/ws-1/raw/notes/report.md",
        url: new URL("http://localhost/workspaces/ws-1/raw/notes/report.md"),
        req: { headers: {} } as never,
        res: sensitiveResponse as never,
      });
      expect(sensitiveHandled).toBe(true);
      expect(sensitiveResponse.statusCode).toBe(403);

      const safeResponse = makeResponse();
      const safeHandled = await dispatch({
        method: "HEAD",
        path: "/workspaces/ws-1/raw/notes/safe.md",
        url: new URL("http://localhost/workspaces/ws-1/raw/notes/safe.md"),
        req: { headers: {} } as never,
        res: safeResponse as never,
      });
      expect(safeHandled).toBe(true);
      expect(safeResponse.statusCode).toBe(200);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

// MARK: - getFileIndex (git-backed)

describe("getFileIndex with git repo", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-git-index-"));
    execSync("git init", { cwd: tmpRoot, stdio: "ignore" });
    execSync("git config user.email test@test.com", { cwd: tmpRoot, stdio: "ignore" });
    execSync("git config user.name Test", { cwd: tmpRoot, stdio: "ignore" });

    mkdirSync(join(tmpRoot, "src"), { recursive: true });
    mkdirSync(join(tmpRoot, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "src", "app.ts"), "console.log('hi')");
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "module.exports = {}");
    writeFileSync(join(tmpRoot, "ignored-report.md"), "ignored");
    writeFileSync(join(tmpRoot, ".gitignore"), "node_modules/\nignored-report.md\n");

    execSync("git add -A && git commit -m init", { cwd: tmpRoot, stdio: "ignore" });
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("includes files ignored by Git", async () => {
    const result = await getFileIndex(tmpRoot);
    expect(result.paths).toContain("ignored-report.md");
    expect(result.paths).not.toContain("node_modules/dep/index.js");
  });

  test("Git and non-Git workspaces use the same filesystem visibility", async () => {
    const nonGitRoot = mkdtempSync(join(tmpdir(), "oppi-ws-no-git-index-"));
    try {
      mkdirSync(join(nonGitRoot, "src"), { recursive: true });
      mkdirSync(join(nonGitRoot, "node_modules", "dep"), { recursive: true });
      writeFileSync(join(nonGitRoot, "README.md"), "# Hello");
      writeFileSync(join(nonGitRoot, "src", "app.ts"), "");
      writeFileSync(join(nonGitRoot, "node_modules", "dep", "index.js"), "");
      writeFileSync(join(nonGitRoot, "ignored-report.md"), "ignored");
      writeFileSync(join(nonGitRoot, ".gitignore"), "node_modules/\nignored-report.md\n");

      const gitResult = await getFileIndex(tmpRoot);
      const nonGitResult = await getFileIndex(nonGitRoot);

      expect(nonGitResult).toEqual(gitResult);
    } finally {
      rmSync(nonGitRoot, { recursive: true, force: true });
    }
  });

  test("includes untracked but non-ignored files", async () => {
    writeFileSync(join(tmpRoot, "src", "new-feature.ts"), "export {}");

    const result = await getFileIndex(tmpRoot);
    expect(result.paths).toContain("src/new-feature.ts");
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

// MARK: - getFileIndex

describe("getFileIndex", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-index-"));
    mkdirSync(join(tmpRoot, "src", "components"), { recursive: true });
    mkdirSync(join(tmpRoot, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "package.json"), "{}");
    writeFileSync(join(tmpRoot, "src", "index.ts"), "");
    writeFileSync(join(tmpRoot, "src", "App.tsx"), "");
    writeFileSync(join(tmpRoot, "src", "components", "Button.tsx"), "");
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "");
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("returns flat list of file paths", async () => {
    const result = await getFileIndex(tmpRoot);
    expect(result.paths.length).toBeGreaterThanOrEqual(4);
    expect(result.paths).toContain("README.md");
    expect(result.paths).toContain("src/index.ts");
    expect(result.paths).toContain("src/App.tsx");
    expect(result.paths).toContain("src/components/Button.tsx");
  });

  test("skips files in ignored directories", async () => {
    const result = await getFileIndex(tmpRoot);
    const hasNodeModules = result.paths.some((p) => p.startsWith("node_modules/"));
    expect(hasNodeModules).toBe(false);
  });

  test("returns truncated: false for small file sets", async () => {
    const result = await getFileIndex(tmpRoot);
    expect(result.truncated).toBe(false);
  });

  test("returns consistent results on second call (cache hit)", async () => {
    const first = await getFileIndex(tmpRoot);
    const second = await getFileIndex(tmpRoot);
    expect(second.paths).toEqual(first.paths);
    expect(second.truncated).toBe(first.truncated);
  });

  test("walks entries in deterministic code-unit order", async () => {
    mkdirSync(join(tmpRoot, "z-directory"), { recursive: true });
    mkdirSync(join(tmpRoot, "a-directory"), { recursive: true });
    writeFileSync(join(tmpRoot, "z-directory", "file.txt"), "z");
    writeFileSync(join(tmpRoot, "a-directory", "file.txt"), "a");
    const unicodeNames = ["é-report.md", "e\u0301-report.md"];
    for (const name of unicodeNames) {
      writeFileSync(join(tmpRoot, name), name);
    }

    const result = await getFileIndex(tmpRoot);
    const compareCodeUnits = (lhs: string, rhs: string): number =>
      lhs === rhs ? 0 : lhs < rhs ? -1 : 1;

    expect(result.paths).toEqual([...result.paths].sort(compareCodeUnits));
    const presentUnicodeNames = result.paths.filter((path) => unicodeNames.includes(path));
    if (presentUnicodeNames.length === unicodeNames.length) {
      expect(presentUnicodeNames).toEqual([...unicodeNames].sort(compareCodeUnits));
    }
  });

  test("reports a filesystem read failure as truncated", async () => {
    const result = await getFileIndex(join(tmpRoot, "does-not-exist"));

    expect(result).toEqual({ paths: [], truncated: true });
  });

  test("reports exact path and entry caps, then rejects over-budget work", async () => {
    const capDirectory = join(tmpRoot, "cap");
    mkdirSync(capDirectory, { recursive: true });
    for (let i = 0; i < 50_000; i += 1) {
      const suffix = i.toString().padStart(5, "0");
      writeFileSync(join(capDirectory, `entry-${suffix}.txt`), "");
      writeFileSync(join(capDirectory, `.env.${suffix}.txt`), "");
    }

    const exactResult = await getFileIndex(capDirectory);

    expect(exactResult.paths).toHaveLength(50_000);
    expect(exactResult.truncated).toBe(false);

    writeFileSync(join(capDirectory, "entry-50000.txt"), "");
    const overResult = await getFileIndex(`${capDirectory}${sep}.`);

    expect(overResult.paths).toEqual([]);
    expect(overResult.truncated).toBe(true);
  }, 60_000);

  test("reports a depth cap as truncated", async () => {
    let currentDirectory = tmpRoot;
    const pathParts: string[] = [];
    for (let depth = 0; depth < 13; depth += 1) {
      const name = `level-${depth}`;
      pathParts.push(name);
      currentDirectory = join(currentDirectory, name);
      mkdirSync(currentDirectory, { recursive: true });
    }
    writeFileSync(join(currentDirectory, "too-deep.md"), "too deep");

    const result = await getFileIndex(tmpRoot);

    expect(result.truncated).toBe(true);
    expect(result.paths).not.toContain(`${pathParts.join("/")}/too-deep.md`);
  });

  test("reports bounded directory work for many empty directories", async () => {
    for (let i = 0; i <= 10_000; i += 1) {
      mkdirSync(join(tmpRoot, `empty-${i.toString().padStart(5, "0")}`));
    }

    const result = await getFileIndex(tmpRoot);

    expect(result.truncated).toBe(true);
  }, 30_000);

  test("does not traverse directory symlinks or symlink cycles", async () => {
    const outsideDirectory = mkdtempSync(join(tmpdir(), "oppi-ws-index-outside-"));
    writeFileSync(join(outsideDirectory, "outside-secret.txt"), "outside");
    symlinkSync(outsideDirectory, join(tmpRoot, "outside-link"));
    symlinkSync(tmpRoot, join(tmpRoot, "cycle-link"));

    try {
      const result = await getFileIndex(tmpRoot);

      expect(result.paths).not.toContain("outside-link/outside-secret.txt");
      expect(result.paths).not.toContain("cycle-link/README.md");
    } finally {
      rmSync(outsideDirectory, { recursive: true, force: true });
    }
  });
});

describe("getFileIndex with git repo", () => {
  let tmpRoot: string;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "oppi-ws-git-index-"));
    execSync("git init", { cwd: tmpRoot, stdio: "ignore" });
    execSync("git config user.email test@test.com", { cwd: tmpRoot, stdio: "ignore" });
    execSync("git config user.name Test", { cwd: tmpRoot, stdio: "ignore" });

    mkdirSync(join(tmpRoot, "src"), { recursive: true });
    mkdirSync(join(tmpRoot, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(tmpRoot, "README.md"), "# Hello");
    writeFileSync(join(tmpRoot, "src", "app.ts"), "");
    writeFileSync(join(tmpRoot, "node_modules", "dep", "index.js"), "");
    writeFileSync(join(tmpRoot, ".gitignore"), "node_modules/\n");
    execSync("git add -A && git commit -m init", { cwd: tmpRoot, stdio: "ignore" });
  });

  afterEach(() => {
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("omits generic ignored directories in Git workspaces", async () => {
    const result = await getFileIndex(tmpRoot);
    const hasNodeModules = result.paths.some((p) => p.startsWith("node_modules/"));
    expect(hasNodeModules).toBe(false);
  });

  test("includes tracked and untracked non-ignored files", async () => {
    writeFileSync(join(tmpRoot, "src", "new.ts"), "");
    const result = await getFileIndex(tmpRoot);
    expect(result.paths).toContain("src/new.ts");
    expect(result.paths).toContain("src/app.ts");
  });
});

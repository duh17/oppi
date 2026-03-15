import { describe, expect, test, beforeEach, afterEach } from "vitest";
import { mkdirSync, writeFileSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ALLOWED_EXTENSIONS, resolveWorkspaceFilePath } from "./workspace-files.js";

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
});

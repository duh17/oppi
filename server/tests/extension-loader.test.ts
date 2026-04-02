import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import {
  isValidExtensionName,
  listHostExtensions,
  resolveWorkspaceExtensions,
  extensionInstallName,
  type ResolvedExtension,
} from "../src/extension-loader.js";

// ─── isValidExtensionName ───

describe("isValidExtensionName", () => {
  it("accepts simple names", () => {
    expect(isValidExtensionName("memory")).toBe(true);
    expect(isValidExtensionName("todos")).toBe(true);
    expect(isValidExtensionName("my-extension")).toBe(true);
    expect(isValidExtensionName("ext_v2")).toBe(true);
    expect(isValidExtensionName("a")).toBe(true);
  });

  it("accepts names with dots", () => {
    expect(isValidExtensionName("my.ext")).toBe(true);
  });

  it("rejects empty/whitespace", () => {
    expect(isValidExtensionName("")).toBe(false);
    expect(isValidExtensionName("  ")).toBe(false);
  });

  it("rejects names starting with special chars", () => {
    expect(isValidExtensionName("-bad")).toBe(false);
    expect(isValidExtensionName(".hidden")).toBe(false);
    expect(isValidExtensionName("_under")).toBe(false);
  });

  it("rejects names over 64 chars", () => {
    expect(isValidExtensionName("a".repeat(65))).toBe(false);
    expect(isValidExtensionName("a".repeat(64))).toBe(true);
  });

  it("rejects names with slashes or spaces", () => {
    expect(isValidExtensionName("foo/bar")).toBe(false);
    expect(isValidExtensionName("foo bar")).toBe(false);
  });
});

// ─── extensionInstallName ───

describe("extensionInstallName", () => {
  it("returns directory name for directory extensions", () => {
    const ext: ResolvedExtension = { name: "myext", path: "/some/dir/myext", kind: "directory" };
    expect(extensionInstallName(ext)).toBe("myext");
  });

  it("preserves .ts suffix for file extensions", () => {
    const ext: ResolvedExtension = { name: "memory", path: "/ext/memory.ts", kind: "file" };
    expect(extensionInstallName(ext)).toBe("memory.ts");
  });

  it("preserves .js suffix for file extensions", () => {
    const ext: ResolvedExtension = { name: "helper", path: "/ext/helper.js", kind: "file" };
    expect(extensionInstallName(ext)).toBe("helper.js");
  });

  it("returns bare name when no suffix on path", () => {
    const ext: ResolvedExtension = { name: "bare", path: "/ext/bare", kind: "file" };
    expect(extensionInstallName(ext)).toBe("bare");
  });
});

// ─── resolveWorkspaceExtensions ───

describe("resolveWorkspaceExtensions", () => {
  it("returns empty for undefined extensions", () => {
    const result = resolveWorkspaceExtensions(undefined);
    expect(result.extensions).toHaveLength(0);
    expect(result.warnings).toHaveLength(0);
  });

  it("returns empty for empty array", () => {
    const result = resolveWorkspaceExtensions([]);
    expect(result.extensions).toHaveLength(0);
  });

  it("warns on invalid extension name", () => {
    const result = resolveWorkspaceExtensions(["-bad", ""]);
    expect(result.warnings.length).toBeGreaterThanOrEqual(1);
    expect(result.warnings.some((w) => w.includes("invalid"))).toBe(true);
  });

  it("warns when extension not found", () => {
    const result = resolveWorkspaceExtensions(["nonexistent-ext-xyz"]);
    expect(result.warnings.some((w) => w.includes("not found"))).toBe(true);
  });

  it("warns and ignores managed extensions in explicit list", () => {
    for (const name of ["permission-gate", "ask", "spawn_agent"]) {
      const result = resolveWorkspaceExtensions([name]);
      expect(result.extensions).toHaveLength(0);
      expect(result.warnings.some((w) => w.includes("managed"))).toBe(true);
    }
  });

  it("deduplicates repeated names", () => {
    const result = resolveWorkspaceExtensions(["zzz-fake", "zzz-fake"]);
    const notFoundWarnings = result.warnings.filter((w) => w.includes("not found"));
    expect(notFoundWarnings.length).toBeGreaterThanOrEqual(1);
  });
});

// ─── listHostExtensions ───

describe("listHostExtensions", () => {
  it("returns an array (may be empty in test environments)", () => {
    const extensions = listHostExtensions();
    expect(Array.isArray(extensions)).toBe(true);
  });

  it("excludes managed extensions", () => {
    const extensions = listHostExtensions();
    expect(extensions.find((e) => e.name === "permission-gate")).toBeUndefined();
    expect(extensions.find((e) => e.name === "ask")).toBeUndefined();
    expect(extensions.find((e) => e.name === "spawn_agent")).toBeUndefined();
  });

  it("does not list mobile renderers (they live in ~/.pi/agent/mobile-renderers/)", () => {
    const extensions = listHostExtensions();
    // Mobile renderers are in a separate directory, so they should never appear here
    expect(extensions.every((e) => !e.name.includes("mobile"))).toBe(true);
  });

  it("includes project-local .pi/extensions when cwd is provided", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-"));
    const globalDir = join(root, "global");
    const cwd = join(root, "workspace");
    const localDir = join(cwd, ".pi", "extensions");

    mkdirSync(globalDir, { recursive: true });
    mkdirSync(localDir, { recursive: true });
    writeFileSync(join(globalDir, "global-only.ts"), "export default function() {}\n");
    writeFileSync(join(localDir, "local-only.ts"), "export default function() {}\n");

    const extensions = listHostExtensions({ cwd, globalDir });
    expect(extensions.map((e) => e.name)).toContain("global-only");
    expect(extensions.map((e) => e.name)).toContain("local-only");
  });

  it("excludes test and spec files", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-"));
    const globalDir = join(root, "global");
    mkdirSync(globalDir, { recursive: true });

    writeFileSync(join(globalDir, "real-ext.ts"), "export default function() {}\n");
    writeFileSync(join(globalDir, "real-ext.test.ts"), "test file\n");
    writeFileSync(join(globalDir, "another.spec.ts"), "spec file\n");
    writeFileSync(join(globalDir, "helper.test.js"), "test js\n");

    const extensions = listHostExtensions({ globalDir });
    const names = extensions.map((e) => e.name);
    expect(names).toContain("real-ext");
    expect(names).not.toContain("real-ext.test");
    expect(names).not.toContain("another.spec");
    expect(names).not.toContain("helper.test");
  });

  it("prefers project-local extension names over global duplicates", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-"));
    const globalDir = join(root, "global");
    const cwd = join(root, "workspace");
    const localDir = join(cwd, ".pi", "extensions");

    mkdirSync(globalDir, { recursive: true });
    mkdirSync(localDir, { recursive: true });
    writeFileSync(join(globalDir, "shared.ts"), "export default function() {}\n");
    writeFileSync(join(localDir, "shared.ts"), "export default function() {}\n");

    const extensions = listHostExtensions({ cwd, globalDir });
    const shared = extensions.find((e) => e.name === "shared");
    expect(shared?.path).toBe(join(localDir, "shared.ts"));
  });
});

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

  it("warns and ignores permission-gate in explicit list", () => {
    const result = resolveWorkspaceExtensions(["permission-gate"]);
    expect(result.extensions).toHaveLength(0);
    expect(result.warnings.some((w) => w.includes("managed"))).toBe(true);
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

  it("excludes permission-gate", () => {
    const extensions = listHostExtensions();
    expect(extensions.find((e) => e.name === "permission-gate")).toBeUndefined();
  });

  it("does not list mobile renderers (they live in ~/.pi/agent/mobile-renderers/)", () => {
    const extensions = listHostExtensions();
    // Mobile renderers are in a separate directory, so they should never appear here
    expect(extensions.every((e) => !e.name.includes("mobile"))).toBe(true);
  });
});

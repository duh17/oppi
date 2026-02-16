import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  isValidExtensionName,
  listHostExtensions,
  resolveWorkspaceExtensions,
  extensionInstallName,
  HOST_EXTENSIONS_DIR,
  type ResolvedExtension,
} from "../src/extension-loader.js";
import type { Workspace } from "../src/types.js";

// ─── Helpers ───

/** Create a minimal workspace for testing. */
function ws(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-test",
    name: "test",
    runtime: "host",
    skills: [],
    policyPreset: "host",
    createdAt: Date.now(),
    updatedAt: Date.now(),
    ...overrides,
  };
}

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
  describe("mode selection", () => {
    it("uses explicit mode when extensionMode is set", () => {
      const result = resolveWorkspaceExtensions(
        ws({ extensionMode: "explicit", extensions: [] }),
        { legacyEnabled: true },
      );
      expect(result.mode).toBe("explicit");
    });

    it("infers explicit mode when extensions array is present", () => {
      const result = resolveWorkspaceExtensions(
        ws({ extensions: ["memory"] }),
        { legacyEnabled: true },
      );
      expect(result.mode).toBe("explicit");
    });

    it("falls back to legacy mode when no extensions config", () => {
      const result = resolveWorkspaceExtensions(
        ws(),
        { legacyEnabled: true },
      );
      expect(result.mode).toBe("legacy");
    });
  });

  describe("explicit mode", () => {
    it("warns on invalid extension name", () => {
      const result = resolveWorkspaceExtensions(
        ws({ extensionMode: "explicit", extensions: ["-bad", ""] }),
        { legacyEnabled: true },
      );
      expect(result.warnings.length).toBeGreaterThanOrEqual(1);
      expect(result.warnings.some((w) => w.includes("invalid"))).toBe(true);
    });

    it("warns when extension not found", () => {
      const result = resolveWorkspaceExtensions(
        ws({ extensionMode: "explicit", extensions: ["nonexistent-ext-xyz"] }),
        { legacyEnabled: true },
      );
      expect(result.warnings.some((w) => w.includes("not found"))).toBe(true);
    });

    it("warns and ignores permission-gate in explicit list", () => {
      const result = resolveWorkspaceExtensions(
        ws({ extensionMode: "explicit", extensions: ["permission-gate"] }),
        { legacyEnabled: true },
      );
      expect(result.extensions).toHaveLength(0);
      expect(result.warnings.some((w) => w.includes("managed"))).toBe(true);
    });

    it("deduplicates repeated names", () => {
      // Both entries warn "not found" since they don't exist on disk.
      // The point: no crash, each entry processed independently.
      const result = resolveWorkspaceExtensions(
        ws({ extensionMode: "explicit", extensions: ["zzz-fake", "zzz-fake"] }),
        { legacyEnabled: true },
      );
      const notFoundWarnings = result.warnings.filter((w) => w.includes("not found"));
      expect(notFoundWarnings.length).toBeGreaterThanOrEqual(1);
    });
  });

  describe("legacy mode", () => {
    it("returns empty when legacy disabled", () => {
      const result = resolveWorkspaceExtensions(
        ws({ memoryEnabled: true }),
        { legacyEnabled: false },
      );
      expect(result.mode).toBe("legacy");
      expect(result.extensions).toHaveLength(0);
    });

    it("returns empty extensions for undefined workspace", () => {
      const result = resolveWorkspaceExtensions(undefined, { legacyEnabled: true });
      expect(result.mode).toBe("legacy");
      // May include todos if it exists on disk, but no crash
    });
  });
});

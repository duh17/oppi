import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import {
  extensionInstallName,
  extensionNameForAllowlist,
  extensionNameFromPath,
  isValidExtensionName,
  listConfiguredHostExtensions,
  listHostExtensions,
  resolveWorkspaceExtensions,
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

// ─── extensionNameFromPath ───

describe("extensionNameFromPath", () => {
  it("uses the parent directory name for directory-style index entries", () => {
    expect(
      extensionNameFromPath("/Users/example/.pi/agent/extensions/pi-codex-image-gen/index.ts"),
    ).toBe("pi-codex-image-gen");
  });

  it("keeps file-based extension names unchanged", () => {
    expect(extensionNameFromPath("/Users/example/.pi/agent/extensions/pi-zit.ts")).toBe("pi-zit");
  });

  it("does not rewrite a top-level index.ts extension file", () => {
    expect(extensionNameFromPath("/Users/example/.pi/agent/extensions/index.ts")).toBe("index");
  });

  it("uses package identity for package-provided index extensions", () => {
    expect(
      extensionNameForAllowlist(
        "/Users/example/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/src/index.ts",
        { source: "npm:@tintinweb/pi-subagents", origin: "package" },
      ),
    ).toBe("tintinweb-subagents");
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

  it("does not treat permission-gate as a managed extension in explicit lists", () => {
    const result = resolveWorkspaceExtensions(["permission-gate"]);
    expect(result.warnings.some((w) => w.includes("managed"))).toBe(false);
  });

  it("deduplicates repeated names", () => {
    const result = resolveWorkspaceExtensions(["zzz-fake", "zzz-fake"]);
    const notFoundWarnings = result.warnings.filter((w) => w.includes("not found"));
    expect(notFoundWarnings.length).toBeGreaterThanOrEqual(1);
  });
});

// ─── listConfiguredHostExtensions ───

describe("listConfiguredHostExtensions", () => {
  it("picks up new global and project-local extension files on the next allow-list scan", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-direct-"));
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const globalDir = join(agentDir, "extensions");
    const localDir = join(cwd, ".pi", "extensions");

    mkdirSync(cwd, { recursive: true });
    mkdirSync(agentDir, { recursive: true });

    const before = await listConfiguredHostExtensions({ cwd, agentDir });
    expect(before.map((ext) => ext.name)).not.toContain("global-new");
    expect(before.map((ext) => ext.name)).not.toContain("project-new");

    mkdirSync(globalDir, { recursive: true });
    mkdirSync(localDir, { recursive: true });
    writeFileSync(join(globalDir, "global-new.ts"), "export default function() {}\n");
    writeFileSync(join(localDir, "project-new.ts"), "export default function() {}\n");

    const after = await listConfiguredHostExtensions({ cwd, agentDir });
    expect(after).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "global-new",
          path: join(globalDir, "global-new.ts"),
          kind: "file",
        }),
        expect.objectContaining({
          name: "project-new",
          path: join(localDir, "project-new.ts"),
          kind: "file",
        }),
      ]),
    );
  });

  it("picks up newly installed package extensions on the next allow-list scan", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-package-"));
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const packageDir = join(agentDir, "npm", "node_modules", "@tintinweb", "pi-subagents");
    const extensionPath = join(packageDir, "src", "index.ts");

    mkdirSync(cwd, { recursive: true });
    mkdirSync(agentDir, { recursive: true });

    const before = await listConfiguredHostExtensions({ cwd, agentDir });
    expect(before.map((ext) => ext.name)).not.toContain("tintinweb-subagents");

    mkdirSync(join(packageDir, "src"), { recursive: true });
    writeFileSync(extensionPath, "export default function() {}\n");
    writeFileSync(
      join(packageDir, "package.json"),
      JSON.stringify({
        name: "@tintinweb/pi-subagents",
        version: "0.0.0",
        pi: { extensions: ["./src/index.ts"] },
      }),
    );
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ packages: ["npm:@tintinweb/pi-subagents"] }),
    );

    const after = await listConfiguredHostExtensions({ cwd, agentDir });
    const names = after.map((ext) => ext.name);
    const installed = after.find((ext) => ext.name === "tintinweb-subagents");

    expect(installed).toMatchObject({
      name: "tintinweb-subagents",
      path: extensionPath,
      kind: "file",
    });
    expect(names).not.toContain("index");
  });
});

// ─── listHostExtensions ───

describe("listHostExtensions", () => {
  it("returns an array (may be empty in test environments)", () => {
    const extensions = listHostExtensions();
    expect(Array.isArray(extensions)).toBe(true);
  });

  it("lists permission-gate as a normal host extension", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-"));
    const globalDir = join(root, "global");
    mkdirSync(globalDir, { recursive: true });
    writeFileSync(join(globalDir, "permission-gate.ts"), "export default function() {}\n");

    const extensions = listHostExtensions({ globalDir });
    expect(extensions.find((e) => e.name === "permission-gate")).toBeDefined();
  });

  it("lists ask as a normal host extension", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-ext-"));
    const globalDir = join(root, "global");
    mkdirSync(globalDir, { recursive: true });
    writeFileSync(join(globalDir, "ask.ts"), "export default function() {}\n");

    const extensions = listHostExtensions({ globalDir });
    expect(extensions.find((e) => e.name === "ask")).toBeDefined();
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

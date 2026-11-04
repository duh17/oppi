import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

import {
  extensionNameForAllowlist,
  extensionNameFromPath,
  isValidExtensionName,
  listConfiguredHostExtensionResources,
} from "../src/extension-loader.js";
import { makeTempDir } from "./harness/temp-dir.js";

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

// ─── listConfiguredHostExtensionResources ───

describe("listConfiguredHostExtensionResources", () => {
  /** Names Pi would load: the catalog filtered to enabled resources. */
  async function listEnabled(options: { cwd: string; agentDir: string }) {
    const resources = await listConfiguredHostExtensionResources(options);
    return resources.filter((ext) => ext.enabled);
  }

  it("picks up new global and project-local extension files on the next allow-list scan", async () => {
    const root = makeTempDir("oppi-ext-direct-");
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const globalDir = join(agentDir, "extensions");
    const localDir = join(cwd, ".pi", "extensions");

    mkdirSync(cwd, { recursive: true });
    mkdirSync(agentDir, { recursive: true });

    const before = await listEnabled({ cwd, agentDir });
    expect(before.map((ext) => ext.name)).not.toContain("global-new");
    expect(before.map((ext) => ext.name)).not.toContain("project-new");

    mkdirSync(globalDir, { recursive: true });
    mkdirSync(localDir, { recursive: true });
    writeFileSync(join(globalDir, "global-new.ts"), "export default function() {}\n");
    writeFileSync(join(localDir, "project-new.ts"), "export default function() {}\n");
    writeFileSync(join(globalDir, "global-new.test.ts"), "test file\n");

    const after = await listEnabled({ cwd, agentDir });
    expect(after.map((ext) => ext.name)).not.toContain("global-new.test");
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
    const root = makeTempDir("oppi-ext-package-");
    const cwd = join(root, "workspace");
    const agentDir = join(root, "agent");
    const packageDir = join(agentDir, "npm", "node_modules", "@tintinweb", "pi-subagents");
    const extensionPath = join(packageDir, "src", "index.ts");

    mkdirSync(cwd, { recursive: true });
    mkdirSync(agentDir, { recursive: true });

    const before = await listEnabled({ cwd, agentDir });
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

    const after = await listEnabled({ cwd, agentDir });
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

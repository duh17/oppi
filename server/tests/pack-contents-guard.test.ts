import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import {
  checkPackContents,
  checkPackedRouteContents,
  extractRegistryPaths,
  sourceCandidatesForPackedJs,
} from "../scripts/check-pack-contents.mjs";

describe("npm pack contents guard", () => {
  it("runs a clean build and contents check before creating a release tarball", () => {
    const manifest = JSON.parse(
      readFileSync(new URL("../package.json", import.meta.url), "utf8"),
    ) as { scripts?: Record<string, string> };

    expect(manifest.scripts?.prepack).toContain("npm run build");
    expect(manifest.scripts?.prepack).toContain("npm run check:pi-release-versions");
    expect(manifest.scripts?.prepack).toContain("npm run check:pack-contents");
  });

  it("maps packed JS onto TypeScript, ESM, or JS sources", () => {
    expect(sourceCandidatesForPackedJs("default-agent.js")).toEqual([
      "default-agent.ts",
      "default-agent.mts",
      "default-agent.js",
    ]);
    expect(sourceCandidatesForPackedJs("storage/oppi-extension-settings-store.js")).toEqual([
      "storage/oppi-extension-settings-store.ts",
      "storage/oppi-extension-settings-store.mts",
      "storage/oppi-extension-settings-store.js",
    ]);
  });

  it("passes when every packed JS file has matching server source", () => {
    const source = new Set(["cli.ts", "storage/config-store.ts"]);
    expect(
      checkPackContents({
        jsRelPaths: ["cli.js", "storage/config-store.js"],
        sourceExists: (rel) => source.has(rel),
      }),
    ).toEqual([]);
  });

  it("fails when packed JS has no matching source, including the 0.47.3 leftover agent files", () => {
    const source = new Set(["cli.ts"]);
    expect(
      checkPackContents({
        jsRelPaths: [
          "cli.js",
          "default-agent.js",
          "default-agent-tool.js",
          "oppi-tool-extension.js",
          "oppi-extension-settings.js",
          "storage/oppi-extension-settings-store.js",
          "cli/command-policy.js",
        ],
        sourceExists: (rel) => source.has(rel),
      }),
    ).toEqual([
      "default-agent.js: packed JS has no matching server source",
      "default-agent-tool.js: packed JS has no matching server source",
      "oppi-tool-extension.js: packed JS has no matching server source",
      "oppi-extension-settings.js: packed JS has no matching server source",
      "storage/oppi-extension-settings-store.js: packed JS has no matching server source",
      "cli/command-policy.js: packed JS has no matching server source",
    ]);
  });

  it("extracts registry path literals from current source", () => {
    expect(
      extractRegistryPaths(`
        path: "/health",
        path: "/server/mobile-output-guide",
        path: "/server/mobile-output-guide",
      `),
    ).toEqual(["/health", "/server/mobile-output-guide"]);
  });

  it("fails when packed server-resources.js is missing Mobile Output Guide", () => {
    expect(
      checkPackedRouteContents({
        registrySource: `path: "/server/mobile-output-guide",`,
        distJsByRelativePath: {
          "src/routes/registry.js": `path: "/server/mobile-output-guide"`,
          "src/routes/server-resources.js": `path === "/server/resources/skills"`,
        },
      }),
    ).toEqual([
      "routes/server-resources.js does not include /server/mobile-output-guide",
    ]);
  });

  it("fails when packed dist is missing a source registry path", () => {
    expect(
      checkPackedRouteContents({
        registrySource: `path: "/server/mobile-output-guide",\npath: "/server/info",`,
        distJsByRelativePath: {
          "src/routes/server-resources.js": `if (path === "/server/mobile-output-guide")`,
        },
      }),
    ).toEqual(["packed dist is missing registry path /server/info"]);
  });

  it("passes when compiled dist includes registry paths and the guide handler", () => {
    expect(
      checkPackedRouteContents({
        registrySource: `path: "/server/mobile-output-guide",\npath: "/health",`,
        distJsByRelativePath: {
          "src/routes/registry.js": `path: "/health"`,
          "src/routes/server-resources.js": `if (path === "/server/mobile-output-guide")`,
        },
      }),
    ).toEqual([]);
  });

  it("runs as a CLI against a dist tree", () => {
    const root = mkdtempSync(path.join(tmpdir(), "oppi-pack-contents-"));
    const scriptPath = path.join(root, "scripts", "check-pack-contents.mjs");
    try {
      mkdirSync(path.join(root, "scripts"));
      mkdirSync(path.join(root, "src", "routes"), { recursive: true });
      mkdirSync(path.join(root, "dist", "src", "routes"), { recursive: true });
      writeFileSync(path.join(root, "src", "cli.ts"), "export {};\n");
      writeFileSync(
        path.join(root, "src", "routes", "registry.ts"),
        'path: "/server/mobile-output-guide";\npath: "/health";\n',
      );
      writeFileSync(path.join(root, "src", "routes", "server-resources.ts"), "export {};\n");
      writeFileSync(path.join(root, "dist", "src", "cli.js"), "export {};\n");
      writeFileSync(
        path.join(root, "dist", "src", "routes", "registry.js"),
        'path: "/health";\n',
      );
      writeFileSync(
        path.join(root, "dist", "src", "routes", "server-resources.js"),
        'if (path === "/server/mobile-output-guide") {}\n',
      );
      writeFileSync(path.join(root, "dist", "src", "default-agent.js"), "export {};\n");
      writeFileSync(
        scriptPath,
        readFileSync(new URL("../scripts/check-pack-contents.mjs", import.meta.url), "utf8"),
      );

      const result = spawnSync(process.execPath, [scriptPath], {
        cwd: path.join(root, "scripts"),
        encoding: "utf8",
      });

      expect(result.status).not.toBe(0);
      expect(result.stderr).toContain("default-agent.js: packed JS has no matching server source");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

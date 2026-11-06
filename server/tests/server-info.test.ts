/**
 * GET /server/info endpoint contract tests.
 */

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { Server } from "../src/server.js";

function readImportedPiCodingAgentVersion(): string {
  const entry = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"));
  let dir = dirname(entry);
  for (let i = 0; i < 8; i++) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate)) {
      const raw = JSON.parse(readFileSync(candidate, "utf-8")) as {
        name?: unknown;
        version?: unknown;
      };
      if (raw.name === "@earendil-works/pi-coding-agent" && typeof raw.version === "string") {
        return raw.version;
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error("missing @earendil-works/pi-coding-agent package.json");
}

describe("GET /server/info", () => {
  it("Server.VERSION is a semver string", () => {
    expect(Server.VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });

  describe("readPiCliVersion", () => {
    let root: string;

    beforeEach(() => {
      root = mkdtempSync(join(tmpdir(), "oppi-pi-cli-version-"));
    });

    afterEach(() => {
      rmSync(root, { recursive: true, force: true });
    });

    function installPi(packageName: string, version: string): string {
      const pkg = join(root, "lib", "node_modules", "@earendil-works", "pi-coding-agent");
      mkdirSync(join(pkg, "dist", "bundle"), { recursive: true });
      writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: packageName, version }));
      writeFileSync(join(pkg, "dist", "bundle", "cli.js"), "#!/usr/bin/env node\n", { mode: 0o755 });
      mkdirSync(join(root, "bin"), { recursive: true });
      const bin = join(root, "bin", "pi");
      symlinkSync(join(pkg, "dist", "bundle", "cli.js"), bin);
      return bin;
    }

    it("reads the version of the package behind a symlinked pi binary without running it", () => {
      const bin = installPi("@earendil-works/pi-coding-agent", "9.8.7");
      expect(Server.readPiCliVersion(bin)).toBe("9.8.7");
    });

    it("finds a bare pi name on PATH", () => {
      const bin = installPi("@earendil-works/pi-coding-agent", "9.8.7");
      const previous = process.env.PATH;
      process.env.PATH = `${dirname(bin)}:${previous ?? ""}`;
      try {
        expect(Server.readPiCliVersion("pi")).toBe("9.8.7");
      } finally {
        process.env.PATH = previous;
      }
    });

    it("returns 'unknown' for a missing executable or a different package", () => {
      expect(Server.readPiCliVersion("/nonexistent/pi")).toBe("unknown");
      const bin = installPi("some-other-cli", "1.0.0");
      expect(Server.readPiCliVersion(bin)).toBe("unknown");
    });
  });

  it("readEmbeddedPiAgentVersion returns the imported package version, not a CLI spawn", () => {
    const expected = readImportedPiCodingAgentVersion();

    expect(Server.readEmbeddedPiAgentVersion()).toBe(expected);
    expect(Server.readEmbeddedPiAgentVersion()).not.toBe(Server.VERSION);
    expect(expected).toMatch(/^\d+\.\d+\.\d+/);
  });
});

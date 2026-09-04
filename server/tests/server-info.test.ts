/**
 * GET /server/info endpoint contract tests.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
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

  it("detectPiVersion returns 'unknown' for bad executable", () => {
    const version = Server.detectPiVersion("/nonexistent/pi");
    expect(version).toBe("unknown");
  });

  it("readEmbeddedPiAgentVersion returns the imported package version, not a CLI spawn", () => {
    const expected = readImportedPiCodingAgentVersion();

    expect(Server.readEmbeddedPiAgentVersion()).toBe(expected);
    expect(Server.readEmbeddedPiAgentVersion()).not.toBe(Server.VERSION);
    expect(expected).toMatch(/^\d+\.\d+\.\d+/);
  });
});

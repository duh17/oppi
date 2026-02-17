/**
 * GET /server/info endpoint contract tests.
 */

import { describe, expect, it, vi } from "vitest";
import { Server } from "../src/server.js";

describe("GET /server/info", () => {
  it("Server.VERSION is a semver string", () => {
    expect(Server.VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });

  it("detectPiVersion returns 'unknown' for bad executable", () => {
    const version = Server.detectPiVersion("/nonexistent/pi");
    expect(version).toBe("unknown");
  });
});

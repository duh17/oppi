import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";
import { Server, validateStartupSecurityConfig } from "../src/server.js";

describe("startup security validation", () => {
  it("fails non-loopback bind when token is missing", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-startup-security-no-token");
    config.host = "0.0.0.0";
    config.token = undefined;

    const error = validateStartupSecurityConfig(config);
    expect(error).toContain("Cannot bind to 0.0.0.0 without a token configured");
  });

  it("allows loopback bind without token", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-startup-security-loopback");
    config.host = "127.0.0.1";
    config.token = undefined;

    const error = validateStartupSecurityConfig(config);
    expect(error).toBeNull();
  });

  it("allows non-loopback bind with token", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-startup-security-token");
    config.host = "0.0.0.0";
    config.token = "sk_test_token";

    const error = validateStartupSecurityConfig(config);
    expect(error).toBeNull();
  });
});

describe("server.start hard bind guard", () => {
  it("throws before startup when non-loopback bind has no token", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-startup-hard-bind-"));

    try {
      const storage = new Storage(dataDir);
      storage.updateConfig({ host: "0.0.0.0", token: undefined });

      const server = new Server(storage);
      await expect(server.start()).rejects.toThrow(
        "Cannot bind to 0.0.0.0 without a token configured",
      );
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

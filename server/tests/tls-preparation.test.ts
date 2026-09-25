import { execSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { prepareTlsForServerOffMainThread } from "../src/tls-preparation.js";

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

describe("prepareTlsForServerOffMainThread", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "oppi-tls-worker-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("resolves disabled TLS without a worker", async () => {
    const result = await prepareTlsForServerOffMainThread({ tls: { mode: "disabled" } }, tmpDir);
    expect(result.enabled).toBe(false);
  });

  it("prepares self-signed TLS in a worker from TypeScript source", async () => {
    expect(hasOpenSSL).toBe(true);
    const result = await prepareTlsForServerOffMainThread({ tls: { mode: "self-signed" } }, tmpDir);
    expect(result.enabled).toBe(true);
    expect(result.mode).toBe("self-signed");
    expect(result.certPath).toContain("self-signed");
    expect(result.keyPath).toContain("self-signed");
  });
});

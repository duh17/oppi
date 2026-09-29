import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { AuthStore, MAX_PAIRING_TOKEN_TTL_MS } from "../src/storage/auth-store.js";
import { ConfigStore } from "../src/storage/config-store.js";

describe("AuthStore.issuePairingToken lifetime bounds", () => {
  let dataDir: string;
  let config: ConfigStore;
  let auth: AuthStore;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-auth-store-ttl-"));
    config = new ConfigStore(dataDir);
    auth = new AuthStore(config);
  });

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("accepts exactly the maximum lifetime", () => {
    const before = Date.now();
    const token = auth.issuePairingToken(MAX_PAIRING_TOKEN_TTL_MS);
    const stored = config.getConfig();
    expect(stored.pairingToken).toBe(token);
    expect(stored.pairingTokenExpiresAt).toBeGreaterThanOrEqual(before + MAX_PAIRING_TOKEN_TTL_MS);
    expect(stored.pairingTokenExpiresAt).toBeLessThanOrEqual(Date.now() + MAX_PAIRING_TOKEN_TTL_MS);
  });

  it("raises a sub-second lifetime to the 1s floor", () => {
    const before = Date.now();
    auth.issuePairingToken(1);
    expect(config.getConfig().pairingTokenExpiresAt).toBeGreaterThanOrEqual(before + 1_000);
  });

  it.each([
    ["above the maximum", MAX_PAIRING_TOKEN_TTL_MS + 1],
    ["NaN", Number.NaN],
    ["Infinity", Number.POSITIVE_INFINITY],
    ["-Infinity", Number.NEGATIVE_INFINITY],
  ])("rejects a lifetime %s without replacing the outstanding invite", (_label, ttlMs) => {
    const outstanding = auth.issuePairingToken(60_000);
    const expiresAt = config.getConfig().pairingTokenExpiresAt;

    expect(() => auth.issuePairingToken(ttlMs)).toThrow(/ttl/);

    expect(config.getConfig().pairingToken).toBe(outstanding);
    expect(config.getConfig().pairingTokenExpiresAt).toBe(expiresAt);
  });
});

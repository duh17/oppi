import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";

describe("Storage config validation", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "pi-remote-config-test-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("accepts default config", () => {
    const raw = Storage.getDefaultConfig(dir);
    const result = Storage.validateConfig(raw, dir, true);

    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.config?.configVersion).toBe(2);
    expect(result.config?.security?.profile).toBe("tailscale-permissive");
    expect(result.config?.invite?.format).toBe("v2-signed");
  });

  it("rejects unknown top-level keys in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      unknownKey: 123,
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.unknownKey: unknown key"))).toBe(true);
  });

  it("rejects invalid security profile", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      security: {
        ...Storage.getDefaultConfig(dir).security,
        profile: "invalid-profile",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.security.profile"))).toBe(true);
  });

  it("backfills v2 security fields for legacy config in non-strict normalization", () => {
    const legacy = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: dir,
      defaultModel: "anthropic/claude-sonnet-4-0",
      sessionTimeout: 600_000,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      legacyExtensionsEnabled: true,
    };

    const result = Storage.validateConfig(legacy, dir, false);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.config?.configVersion).toBe(2);
    expect(result.config?.security).toBeDefined();
    expect(result.config?.identity).toBeDefined();
    expect(result.config?.invite).toBeDefined();
  });

  it("loadConfig rewrites legacy config with v2 defaults", () => {
    const legacy = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: dir,
      defaultModel: "anthropic/claude-sonnet-4-0",
      sessionTimeout: 600_000,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      legacyExtensionsEnabled: true,
    };

    writeFileSync(join(dir, "config.json"), JSON.stringify(legacy, null, 2));

    const storage = new Storage(dir);
    const config = storage.getConfig();

    expect(config.configVersion).toBe(2);
    expect(config.security?.profile).toBe("tailscale-permissive");
    expect(config.identity?.algorithm).toBe("ed25519");
    expect(config.invite?.format).toBe("v2-signed");

    const rewritten = JSON.parse(readFileSync(join(dir, "config.json"), "utf-8")) as {
      configVersion?: number;
      security?: { profile?: string };
      identity?: { algorithm?: string };
      invite?: { format?: string };
    };

    expect(rewritten.configVersion).toBe(2);
    expect(rewritten.security?.profile).toBe("tailscale-permissive");
    expect(rewritten.identity?.algorithm).toBe("ed25519");
    expect(rewritten.invite?.format).toBe("v2-signed");
  });

  it("warns when strict profile still allows legacy unsigned invites", () => {
    const raw = Storage.getDefaultConfig(dir);
    raw.security = {
      ...raw.security!,
      profile: "strict",
    };
    raw.invite = {
      ...raw.invite!,
      format: "v2-signed",
      allowLegacyV1Unsigned: true,
    };

    const result = Storage.validateConfig(raw, dir, true);

    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(
      result.warnings.some((warning) =>
        warning.includes("allowLegacyV1Unsigned=true weakens strict bootstrap posture"),
      ),
    ).toBe(true);
  });

  it("validateConfigFile reports parse errors with file path", () => {
    const configPath = join(dir, "bad-config.json");
    writeFileSync(configPath, "{ invalid json }");

    const result = Storage.validateConfigFile(configPath, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.startsWith(configPath))).toBe(true);
  });
});

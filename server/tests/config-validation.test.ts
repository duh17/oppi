import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";

describe("Storage config validation", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-config-test-"));
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
    expect(result.config?.allowedCidrs.length).toBeGreaterThan(0);
    expect(result.config?.approvalTimeoutMs).toBe(120_000);
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

  it("rejects invalid top-level allowedCidrs", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      allowedCidrs: ["not-a-cidr"],
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.allowedCidrs[0]"))).toBe(true);
  });

  it("accepts approvalTimeoutMs = 0 for non-expiring approvals", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      approvalTimeoutMs: 0,
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.config?.approvalTimeoutMs).toBe(0);
  });

  it("rejects negative approvalTimeoutMs", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      approvalTimeoutMs: -1,
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.approvalTimeoutMs: expected >= 0"))).toBe(true);
  });

  it("backfills defaults for minimal config in non-strict normalization", () => {
    const minimalConfig = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: dir,
      defaultModel: "anthropic/claude-sonnet-4-0",
      sessionTimeout: 600_000,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
    };

    const result = Storage.validateConfig(minimalConfig, dir, false);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.config?.configVersion).toBe(2);
    expect(result.config?.allowedCidrs.length).toBeGreaterThan(0);
  });

  it("rejects unknown top-level keys in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      unknownField: "bad",
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.unknownField: unknown key"))).toBe(true);
  });

  it("accepts declarative policy config", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      policy: {
        schemaVersion: 1,
        mode: "balanced",
        fallback: "ask",
        guardrails: [
          {
            id: "block-secret-files",
            decision: "block",
            risk: "critical",
            match: { tool: "read", pathMatches: "*identity_ed25519*" },
          },
        ],
        permissions: [
          {
            id: "ask-git-push",
            decision: "ask",
            risk: "high",
            label: "Push code to remote",
            match: { tool: "bash", executable: "git", commandMatches: "git push*" },
          },
        ],
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.policy?.fallback).toBe("ask");
    expect(result.config?.policy?.guardrails[0]?.decision).toBe("block");
  });

  it("rejects unknown keys in policy config in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      policy: {
        schemaVersion: 1,
        fallback: "ask",
        guardrails: [],
        permissions: [],
        unknownKey: true,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.policy.unknownKey: unknown key"))).toBe(true);
  });

  it("validateConfigFile reports parse errors with file path", () => {
    const configPath = join(dir, "bad-config.json");
    writeFileSync(configPath, "{ invalid json }");

    const result = Storage.validateConfigFile(configPath, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.startsWith(configPath))).toBe(true);
  });
});

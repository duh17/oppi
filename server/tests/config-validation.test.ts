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
    expect(result.config?.runtimePathEntries?.length).toBeGreaterThan(0);
    expect(result.config?.approvalTimeoutMs).toBe(120_000);
    expect(result.config?.tls?.mode).toBe("self-signed");
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
    expect(result.errors.some((e) => e.includes("config.approvalTimeoutMs: expected >= 0"))).toBe(
      true,
    );
  });

  it("accepts tls self-signed config", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      tls: {
        mode: "self-signed",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.tls?.mode).toBe("self-signed");
  });

  it("accepts tls tailscale config without explicit paths", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      tls: {
        mode: "tailscale",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.tls?.mode).toBe("tailscale");
  });

  it("requires certPath/keyPath for tls manual mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      tls: {
        mode: "manual",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(
      result.errors.some((e) => e.includes("config.tls.certPath: required when mode=manual")),
    ).toBe(true);
    expect(
      result.errors.some((e) => e.includes("config.tls.keyPath: required when mode=manual")),
    ).toBe(true);
  });

  it("backfills defaults for minimal config in non-strict normalization", () => {
    const minimalConfig = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: dir,
      defaultModel: "anthropic/claude-sonnet-4-0",
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
    };

    const result = Storage.validateConfig(minimalConfig, dir, false);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
    expect(result.config?.configVersion).toBe(2);
    expect(result.config?.runtimePathEntries?.length).toBeGreaterThan(0);
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
    expect(result.errors.some((e) => e.includes("config.policy.unknownKey: unknown key"))).toBe(
      true,
    );
  });

  it("accepts extensions.subagents config with all fields", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      extensions: {
        subagents: {
          maxDepth: 3,
          autoStopWhenDone: false,
          startupGraceMs: 120_000,
          defaultWaitTimeoutMs: 60 * 60_000,
          modelPolicy: {
            approvedModels: ["openai-codex/gpt-5.4-mini", "openai-codex/gpt-5.5"],
            defaultModel: "openai-codex/gpt-5.5",
            defaultThinking: "high",
            profiles: {
              discovery: {
                description: "Fast discovery lane",
                model: "openai-codex/gpt-5.4-mini",
                thinking: "minimal",
                guidelines: ["Prefer search before edits"],
              },
            },
          },
        },
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.extensions?.subagents?.maxDepth).toBe(3);
    expect(result.config?.extensions?.subagents?.autoStopWhenDone).toBe(false);
    expect(result.config?.extensions?.subagents?.startupGraceMs).toBe(120_000);
    expect(result.config?.extensions?.subagents?.defaultWaitTimeoutMs).toBe(3_600_000);
    expect(result.config?.extensions?.subagents?.modelPolicy?.defaultModel).toBe(
      "openai-codex/gpt-5.5",
    );
    expect(result.config?.extensions?.subagents?.modelPolicy?.profiles?.discovery?.model).toBe(
      "openai-codex/gpt-5.4-mini",
    );
  });

  it("rejects extensions.subagents.maxDepth < 0", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      extensions: { subagents: { maxDepth: -1 } },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("extensions.subagents.maxDepth"))).toBe(true);
  });

  it("rejects unknown keys in extensions.subagents in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      extensions: { subagents: { unknownField: true } },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(
      result.errors.some((e) =>
        e.includes("config.extensions.subagents.unknownField: unknown key"),
      ),
    ).toBe(true);
  });

  it("backfills extensions.subagents defaults when partially specified", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      extensions: { subagents: { maxDepth: 2 } },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.extensions?.subagents?.maxDepth).toBe(2);
    // Other fields use defaults
    expect(result.config?.extensions?.subagents?.autoStopWhenDone).toBe(false);
    expect(result.config?.extensions?.subagents?.startupGraceMs).toBe(60_000);
    expect(result.config?.extensions?.subagents?.defaultWaitTimeoutMs).toBe(1_800_000);
  });

  it("rejects subagent default/profile models outside approvedModels", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      extensions: {
        subagents: {
          modelPolicy: {
            approvedModels: ["openai-codex/gpt-5.4-mini"],
            defaultModel: "openai-codex/gpt-5.5",
            profiles: {
              review: {
                model: "openai-codex/gpt-5.5",
              },
            },
          },
        },
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(
      result.errors.some((e) =>
        e.includes(
          "config.extensions.subagents.modelPolicy.defaultModel: must be included in approvedModels",
        ),
      ),
    ).toBe(true);
    expect(
      result.errors.some((e) =>
        e.includes(
          "config.extensions.subagents.modelPolicy.profiles.review.model: must be included in approvedModels",
        ),
      ),
    ).toBe(true);
  });

  // ── ASR config regression ──
  // The config normalizer silently dropped config.asr because it was missing
  // from the whitelist + had no parsing code. This caused /dictation to 404
  // and the iOS app to crash.

  it("preserves asr config with sttEndpoint", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      asr: {
        sttEndpoint: "http://localhost:9847",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.asr?.sttEndpoint).toBe("http://localhost:9847");
  });

  it("rejects legacy asr config fields in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      asr: {
        sttEndpoint: "http://localhost:9847",
        sttModel: "Qwen3-ASR-1.7B-bf16",
        preserveAudio: false,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.asr.sttModel: unknown key");
    expect(result.errors).toContain("config.asr.preserveAudio: unknown key");
  });

  it("omits asr when not present in config", () => {
    const raw = Storage.getDefaultConfig(dir);
    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.asr).toBeUndefined();
  });

  it("omits asr when sttEndpoint is empty", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      asr: { sttEndpoint: "  " },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    // Empty endpoint means no valid fields → asr omitted entirely
    expect(result.config?.asr).toBeUndefined();
  });

  it("rejects unknown asr config keys in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      asr: {
        sttEndpoint: "http://localhost:9847",
        termSheetEnabled: true,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.asr.termSheetEnabled: unknown key");
  });

  it("survives round-trip through Storage constructor with asr config", () => {
    const configPath = join(dir, "config.json");
    writeFileSync(
      configPath,
      JSON.stringify({
        ...Storage.getDefaultConfig(dir),
        asr: {
          sttEndpoint: "http://localhost:9847",
        },
      }),
    );

    const storage = new Storage(dir);
    const config = storage.getConfig();
    expect(config.asr).toEqual({ sttEndpoint: "http://localhost:9847" });
  });

  it("validateConfigFile reports parse errors with file path", () => {
    const configPath = join(dir, "bad-config.json");
    writeFileSync(configPath, "{ invalid json }");

    const result = Storage.validateConfigFile(configPath, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.startsWith(configPath))).toBe(true);
  });
});

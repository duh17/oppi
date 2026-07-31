import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
    expect(result.config?.maxSessionsPerWorkspace).toBe(100);
    expect(result.config?.maxSessionsGlobal).toBe(200);
    expect(result.config?.runtimePathEntries?.length).toBeGreaterThan(0);
    expect(result.config?.oppiDocsPrompt?.enabled).toBe(true);
    expect(result.config?.oppiCliPrompt?.enabled).toBe(true);
    expect(result.config?.iroh?.enabled).toBe(false);
    expect(result.config?.tls?.mode).toBe("self-signed");
    expect(result.config?.images?.autoResize).toBe(false);
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

  it("accepts explicit insecure network HTTP escape hatch", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      tls: {
        mode: "disabled",
        allowInsecureNetworkHttp: true,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.tls?.allowInsecureNetworkHttp).toBe(true);
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

  it("warns and ignores unknown top-level keys in non-strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      obsoleteField: true,
      extraConfig: { enabled: true },
    };

    const result = Storage.validateConfig(raw, dir, false);
    expect(result.valid).toBe(true);
    expect(result.config).not.toHaveProperty("obsoleteField");
    expect(result.config).not.toHaveProperty("extraConfig");
    expect(result.warnings).toContain("config: ignored 2 unknown top-level keys");
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

  it("preserves Oppi docs prompt config", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      oppiDocsPrompt: {
        enabled: false,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.oppiDocsPrompt?.enabled).toBe(false);
  });

  it("rejects invalid Oppi docs prompt config in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      oppiDocsPrompt: {
        enabled: "nope",
        unknownField: true,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.oppiDocsPrompt.enabled: expected boolean");
    expect(result.errors).toContain("config.oppiDocsPrompt.unknownField: unknown key");
  });

  it("preserves and validates the Oppi CLI prompt experiment", () => {
    const enabled = Storage.validateConfig(
      { ...Storage.getDefaultConfig(dir), oppiCliPrompt: { enabled: true } },
      dir,
      true,
    );
    expect(enabled.valid).toBe(true);
    expect(enabled.config?.oppiCliPrompt?.enabled).toBe(true);

    const invalid = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        oppiCliPrompt: { enabled: "yes", unknownField: true },
      },
      dir,
      true,
    );
    expect(invalid.valid).toBe(false);
    expect(invalid.errors).toContain("config.oppiCliPrompt.enabled: expected boolean");
    expect(invalid.errors).toContain("config.oppiCliPrompt.unknownField: unknown key");
  });

  it("preserves and validates durable Iroh transport config", () => {
    const enabled = Storage.validateConfig(
      { ...Storage.getDefaultConfig(dir), iroh: { enabled: true } },
      dir,
      true,
    );
    expect(enabled.valid).toBe(true);
    expect(enabled.config?.iroh?.enabled).toBe(true);

    const invalid = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        iroh: { enabled: "yes", unknownField: true },
      },
      dir,
      true,
    );
    expect(invalid.valid).toBe(false);
    expect(invalid.errors).toContain("config.iroh.enabled: expected boolean");
    expect(invalid.errors).toContain("config.iroh.unknownField: unknown key");
  });

  it("keeps valid relay normalization when a non-strict load reports another invalid field", () => {
    const result = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        port: "not-a-port",
        iroh: { enabled: true, relays: [{ url: "https://relay.example" }] },
      },
      dir,
      false,
    );

    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.port: expected number");
    expect(result.config?.iroh).toEqual({
      enabled: true,
      relays: [{ url: "https://relay.example/", quicPort: 7842 }],
    });
  });

  it("normalizes custom Iroh relays deterministically and preserves Iroh siblings", () => {
    const normalized = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        iroh: {
          enabled: true,
          relays: [
            { url: "https://Relay.Example" },
            { url: "https://relay.example/", quicPort: 7842 },
            { url: "https://relay-eu.example", quicPort: 7842 },
          ],
        },
      },
      dir,
      true,
    );

    expect(normalized.valid).toBe(true);
    expect(normalized.config?.iroh).toEqual({
      enabled: true,
      relays: [
        { url: "https://relay.example/", quicPort: 7842 },
        { url: "https://relay-eu.example/", quicPort: 7842 },
      ],
    });

    const storage = new Storage(dir);
    storage.updateConfig({ iroh: { relays: normalized.config?.iroh?.relays } });
    storage.updateConfig({ iroh: { enabled: true } });
    expect(storage.getConfig().iroh).toEqual(normalized.config?.iroh);
  });

  it.each([
    ["non-HTTPS URL", { url: "http://relay.example" }, "expected HTTPS URL"],
    ["missing host", { url: "https:///" }, "expected HTTPS URL with host"],
    ["userinfo", { url: "https://user@relay.example" }, "must not include userinfo"],
    ["query", { url: "https://relay.example?debug=true" }, "must not include a query"],
    ["fragment", { url: "https://relay.example#fragment" }, "must not include a fragment"],
    ["path", { url: "https://relay.example/relay" }, "must use the root path"],
    ["IPv4 loopback", { url: "https://127.0.0.1" }, "must not use a loopback"],
    ["IPv4 private", { url: "https://192.168.1.1" }, "must not use a private"],
    ["IPv4 link-local", { url: "https://169.254.1.1" }, "must not use a link-local"],
    ["IPv4 unspecified", { url: "https://0.0.0.0" }, "must not use an unspecified"],
    ["IPv4 carrier-grade NAT", { url: "https://100.64.0.1" }, "must not use a carrier-grade NAT"],
    ["IPv4 benchmarking", { url: "https://198.18.0.1" }, "must not use a benchmarking"],
    ["IPv4 multicast", { url: "https://224.0.0.1" }, "must not use a multicast"],
    ["IPv4 broadcast", { url: "https://255.255.255.255" }, "must not use a broadcast"],
    ["IPv6 loopback", { url: "https://[::1]" }, "must not use a loopback"],
    ["IPv6 private", { url: "https://[fd00::1]" }, "must not use a private"],
    ["IPv6 link-local", { url: "https://[fe80::1]" }, "must not use a link-local"],
    ["IPv6 unspecified", { url: "https://[::]" }, "must not use an unspecified"],
    ["IPv6 multicast", { url: "https://[ff02::1]" }, "must not use a multicast"],
    ["zero QUIC port", { url: "https://relay.example", quicPort: 0 }, "expected integer 1-65535"],
    [
      "fractional QUIC port",
      { url: "https://relay.example", quicPort: 7842.5 },
      "expected integer 1-65535",
    ],
    ["auth token", { url: "https://relay.example", authToken: "not-yet" }, "unknown key"],
  ])("rejects Iroh relay entries with %s", (_label, relay, expectedError) => {
    const result = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        iroh: { enabled: true, relays: [relay] },
      },
      dir,
      true,
    );

    expect(result.valid).toBe(false);
    expect(result.errors.join("\n")).toContain(expectedError);
  });

  it("allows public relay DNS hostnames without resolving them", () => {
    const result = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        iroh: { enabled: true, relays: [{ url: "https://relay.example" }] },
      },
      dir,
      true,
    );

    expect(result.valid).toBe(true);
    expect(result.config?.iroh?.relays).toEqual([
      { url: "https://relay.example/", quicPort: 7842 },
    ]);
  });

  it("rejects more than eight Iroh relays without persisting invalid updates", () => {
    const storage = new Storage(dir);
    const before = readFileSync(storage.getConfigPath(), "utf8");
    const relays = Array.from({ length: 9 }, (_, index) => ({
      url: `https://relay-${index}.example`,
    }));

    expect(() => storage.updateConfig({ iroh: { relays } })).toThrow("config.iroh.relays");
    expect(readFileSync(storage.getConfigPath(), "utf8")).toBe(before);
    expect(storage.getConfig().iroh?.relays).toBeUndefined();
  });

  it("preserves image auto-resize config", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      images: {
        autoResize: true,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.images?.autoResize).toBe(true);
  });

  it("rejects invalid image config in strict mode", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      images: {
        autoResize: "yes",
        unknownField: true,
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.images.autoResize: expected boolean");
    expect(result.errors).toContain("config.images.unknownField: unknown key");
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

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

  it("rejects unknown transport configuration keys", () => {
    const result = Storage.validateConfig(
      { ...Storage.getDefaultConfig(dir), removedTransport: { enabled: true } },
      dir,
      true,
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.removedTransport: unknown key");
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

  it("preserves asr backend http with sttEndpoint", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      asr: {
        backend: "http",
        sttEndpoint: "http://localhost:9847",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.asr).toEqual({
      backend: "http",
      sttEndpoint: "http://localhost:9847",
    });
  });

  it("preserves asr backend pi-extension with a package name", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      asr: {
        backend: "pi-extension",
        extension: "@earendil-works/pi-transcribe",
      },
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.asr).toEqual({
      backend: "pi-extension",
      extension: "@earendil-works/pi-transcribe",
    });
  });

  it("preserves asr backend pi-extension with an npm: spec or absolute directory", () => {
    const npmSpec = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        asr: { backend: "pi-extension", extension: "npm:@earendil-works/pi-transcribe" },
      },
      dir,
      true,
    );
    expect(npmSpec.valid).toBe(true);
    expect(npmSpec.config?.asr?.extension).toBe("npm:@earendil-works/pi-transcribe");

    const abs = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        asr: { backend: "pi-extension", extension: "/opt/pi-transcribe" },
      },
      dir,
      true,
    );
    expect(abs.valid).toBe(true);
    expect(abs.config?.asr?.extension).toBe("/opt/pi-transcribe");
  });

  it("requires extension when backend is pi-extension", () => {
    const result = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        asr: { backend: "pi-extension" },
      },
      dir,
      true,
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.asr.extension: required when backend=pi-extension");
  });

  it("rejects a Node subpath or TUI entry as asr.extension", () => {
    const subpath = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        asr: {
          backend: "pi-extension",
          extension: "@earendil-works/pi-transcribe/host",
        },
      },
      dir,
      true,
    );
    expect(subpath.valid).toBe(false);
    expect(subpath.errors).toContain(
      "config.asr.extension: expected package name, npm: spec, or absolute package directory",
    );

    const tui = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        asr: {
          backend: "pi-extension",
          extension: "./extensions/transcribe.ts",
        },
      },
      dir,
      true,
    );
    expect(tui.valid).toBe(false);
    expect(tui.errors).toContain(
      "config.asr.extension: expected package name, npm: spec, or absolute package directory",
    );
  });

  it("rejects an invalid asr.backend", () => {
    const result = Storage.validateConfig(
      {
        ...Storage.getDefaultConfig(dir),
        asr: { backend: "yuwp", sttEndpoint: "http://localhost:9847" },
      },
      dir,
      true,
    );
    expect(result.valid).toBe(false);
    expect(result.errors).toContain("config.asr.backend: expected http or pi-extension");
  });

  it("survives round-trip through Storage constructor with pi-extension asr config", () => {
    const configPath = join(dir, "config.json");
    writeFileSync(
      configPath,
      JSON.stringify({
        ...Storage.getDefaultConfig(dir),
        asr: {
          backend: "pi-extension",
          extension: "@earendil-works/pi-transcribe",
        },
      }),
    );

    const storage = new Storage(dir);
    expect(storage.getConfig().asr).toEqual({
      backend: "pi-extension",
      extension: "@earendil-works/pi-transcribe",
    });
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

  it("rejects a pairHost that includes a scheme or port", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      pairHost: "server.local:7749",
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.includes("config.pairHost"))).toBe(true);
    expect(result.errors.some((e) => e.includes("hostname or IP only"))).toBe(true);
    expect(result.config?.pairHost).toBeUndefined();
  });

  it("does not apply an invalid pairHost already present on disk", () => {
    const first = new Storage(dir);
    const raw = JSON.parse(readFileSync(first.getConfigPath(), "utf8")) as Record<string, unknown>;
    raw.pairHost = "server.local:7749";
    writeFileSync(first.getConfigPath(), JSON.stringify(raw, null, 2));

    const reloaded = new Storage(dir);
    expect(reloaded.getConfig().pairHost).toBeUndefined();
  });

  it("accepts a hostname pairHost", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      pairHost: "studio.local",
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.pairHost).toBe("studio.local");
  });

  it("brackets a bare IPv6 pairHost", () => {
    const raw = {
      ...Storage.getDefaultConfig(dir),
      pairHost: "2001:db8::1",
    };

    const result = Storage.validateConfig(raw, dir, true);
    expect(result.valid).toBe(true);
    expect(result.config?.pairHost).toBe("[2001:db8::1]");
  });

  it("validateConfigFile reports parse errors with file path", () => {
    const configPath = join(dir, "bad-config.json");
    writeFileSync(configPath, "{ invalid json }");

    const result = Storage.validateConfigFile(configPath, dir, true);
    expect(result.valid).toBe(false);
    expect(result.errors.some((e) => e.startsWith(configPath))).toBe(true);
  });

  it("does not overwrite a truncated config.json and fails closed on load", () => {
    const configPath = join(dir, "config.json");
    const truncated = '{"port": 7749, "host": "0.0.0.0"';
    writeFileSync(configPath, truncated);

    expect(() => new Storage(dir)).toThrow(/invalid JSON|config\.json/i);
    expect(readFileSync(configPath, "utf8")).toBe(truncated);
  });
});

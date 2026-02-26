import { execSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  collectSubjectAltNames,
  isTailscaleHostname,
  normalizeHostForSan,
  prepareTlsForServer,
  readCertificateExpiryMs,
  readCertificateFingerprint,
  renderOpenSslConfig,
  resolveTlsConfig,
  tlsSchemeForConfig,
} from "../src/tls.js";
import type { ServerConfig } from "../src/types.js";

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

function makeConfig(overrides: Partial<ServerConfig> = {}): ServerConfig {
  return {
    port: 7749,
    host: "127.0.0.1",
    dataDir: "/tmp/oppi-test",
    defaultModel: "anthropic/claude-sonnet-4-0",
    sessionIdleTimeoutMs: 600_000,
    workspaceIdleTimeoutMs: 1_800_000,
    maxSessionsPerWorkspace: 3,
    maxSessionsGlobal: 5,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// resolveTlsConfig
// ---------------------------------------------------------------------------

describe("resolveTlsConfig", () => {
  it("returns disabled when tls is absent", () => {
    const config = makeConfig();
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("disabled");
    expect(result.enabled).toBe(false);
    expect(result.certPath).toBeUndefined();
    expect(result.keyPath).toBeUndefined();
    expect(result.caPath).toBeUndefined();
  });

  it("returns disabled for tls.mode=disabled", () => {
    const config = makeConfig({ tls: { mode: "disabled" } });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("disabled");
    expect(result.enabled).toBe(false);
  });

  it("returns self-signed defaults under dataDir", () => {
    const config = makeConfig({ tls: { mode: "self-signed" } });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("self-signed");
    expect(result.enabled).toBe(true);
    expect(result.certPath).toBe("/data/tls/self-signed/server.crt");
    expect(result.keyPath).toBe("/data/tls/self-signed/server.key");
    expect(result.caPath).toBe("/data/tls/self-signed/ca.crt");
  });

  it("uses custom certPath/keyPath/caPath for self-signed when provided", () => {
    const config = makeConfig({
      tls: {
        mode: "self-signed",
        certPath: "/custom/cert.pem",
        keyPath: "/custom/key.pem",
        caPath: "/custom/ca.pem",
      },
    });
    const result = resolveTlsConfig(config, "/data");

    expect(result.certPath).toBe("/custom/cert.pem");
    expect(result.keyPath).toBe("/custom/key.pem");
    expect(result.caPath).toBe("/custom/ca.pem");
  });

  it("expands ~ in self-signed paths", () => {
    const config = makeConfig({
      tls: {
        mode: "self-signed",
        certPath: "~/tls/cert.pem",
        keyPath: "~/tls/key.pem",
        caPath: "~/tls/ca.pem",
      },
    });
    const result = resolveTlsConfig(config, "/data");

    expect(result.certPath).toBe(`${homedir()}/tls/cert.pem`);
    expect(result.keyPath).toBe(`${homedir()}/tls/key.pem`);
    expect(result.caPath).toBe(`${homedir()}/tls/ca.pem`);
  });

  it("returns tailscale defaults under dataDir", () => {
    const config = makeConfig({ tls: { mode: "tailscale" } });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("tailscale");
    expect(result.enabled).toBe(true);
    expect(result.certPath).toBe("/data/tls/tailscale/server.crt");
    expect(result.keyPath).toBe("/data/tls/tailscale/server.key");
    expect(result.caPath).toBeUndefined();
  });

  it("uses custom paths for tailscale when provided", () => {
    const config = makeConfig({
      tls: {
        mode: "tailscale",
        certPath: "/custom/ts.crt",
        keyPath: "/custom/ts.key",
        caPath: "/custom/ts-ca.crt",
      },
    });
    const result = resolveTlsConfig(config, "/data");

    expect(result.certPath).toBe("/custom/ts.crt");
    expect(result.keyPath).toBe("/custom/ts.key");
    expect(result.caPath).toBe("/custom/ts-ca.crt");
  });

  it("returns manual mode with paths when provided", () => {
    const config = makeConfig({
      tls: {
        mode: "manual",
        certPath: "/etc/ssl/cert.pem",
        keyPath: "/etc/ssl/key.pem",
      },
    });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("manual");
    expect(result.enabled).toBe(true);
    expect(result.certPath).toBe("/etc/ssl/cert.pem");
    expect(result.keyPath).toBe("/etc/ssl/key.pem");
    expect(result.caPath).toBeUndefined();
  });

  it("returns manual mode with undefined paths when not provided", () => {
    const config = makeConfig({ tls: { mode: "manual" } });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("manual");
    expect(result.enabled).toBe(true);
    expect(result.certPath).toBeUndefined();
    expect(result.keyPath).toBeUndefined();
  });

  it("returns auto mode enabled with optional paths", () => {
    const config = makeConfig({ tls: { mode: "auto" } });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("auto");
    expect(result.enabled).toBe(true);
  });

  it("returns cloudflare mode enabled with optional paths", () => {
    const config = makeConfig({ tls: { mode: "cloudflare" } });
    const result = resolveTlsConfig(config, "/data");

    expect(result.mode).toBe("cloudflare");
    expect(result.enabled).toBe(true);
  });

  it("expands ~ in manual mode paths", () => {
    const config = makeConfig({
      tls: {
        mode: "manual",
        certPath: "~/ssl/cert.pem",
        keyPath: "~/ssl/key.pem",
        caPath: "~/ssl/ca.pem",
      },
    });
    const result = resolveTlsConfig(config, "/data");

    expect(result.certPath).toBe(`${homedir()}/ssl/cert.pem`);
    expect(result.keyPath).toBe(`${homedir()}/ssl/key.pem`);
    expect(result.caPath).toBe(`${homedir()}/ssl/ca.pem`);
  });
});

// ---------------------------------------------------------------------------
// tlsSchemeForConfig
// ---------------------------------------------------------------------------

describe("tlsSchemeForConfig", () => {
  it("returns http when tls is absent", () => {
    expect(tlsSchemeForConfig(makeConfig())).toBe("http");
  });

  it("returns http for disabled mode", () => {
    expect(tlsSchemeForConfig(makeConfig({ tls: { mode: "disabled" } }))).toBe("http");
  });

  const enabledModes = ["self-signed", "tailscale", "manual", "auto", "cloudflare"] as const;
  for (const mode of enabledModes) {
    it(`returns https for ${mode} mode`, () => {
      expect(tlsSchemeForConfig(makeConfig({ tls: { mode } }))).toBe("https");
    });
  }
});

// ---------------------------------------------------------------------------
// isTailscaleHostname
// ---------------------------------------------------------------------------

describe("isTailscaleHostname", () => {
  it("accepts *.ts.net hostnames", () => {
    expect(isTailscaleHostname("mac-studio.taila3ebc.ts.net")).toBe(true);
  });

  it("accepts *.beta.tailscale.net hostnames", () => {
    expect(isTailscaleHostname("node.beta.tailscale.net")).toBe(true);
  });

  it("is case-insensitive", () => {
    expect(isTailscaleHostname("Mac-Studio.Taila3ebc.TS.NET")).toBe(true);
  });

  it("rejects plain hostnames", () => {
    expect(isTailscaleHostname("localhost")).toBe(false);
  });

  it("rejects IP addresses", () => {
    expect(isTailscaleHostname("192.168.1.1")).toBe(false);
  });

  it("rejects empty string", () => {
    expect(isTailscaleHostname("")).toBe(false);
  });

  it("rejects whitespace-only", () => {
    expect(isTailscaleHostname("   ")).toBe(false);
  });

  it("rejects partial suffix match", () => {
    expect(isTailscaleHostname("evil.fakets.net")).toBe(false);
  });

  it("strips brackets from IPv6-style input", () => {
    // Bracketed IPv6 is an IP, not a tailscale hostname
    expect(isTailscaleHostname("[::1]")).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// normalizeHostForSan
// ---------------------------------------------------------------------------

describe("normalizeHostForSan", () => {
  it("trims whitespace", () => {
    expect(normalizeHostForSan("  example.com  ")).toBe("example.com");
  });

  it("lowercases", () => {
    expect(normalizeHostForSan("EXAMPLE.COM")).toBe("example.com");
  });

  it("strips brackets from IPv6", () => {
    expect(normalizeHostForSan("[::1]")).toBe("::1");
    expect(normalizeHostForSan("[fe80::1]")).toBe("fe80::1");
  });

  it("returns empty string for empty input", () => {
    expect(normalizeHostForSan("")).toBe("");
  });

  it("returns empty string for whitespace-only", () => {
    expect(normalizeHostForSan("   ")).toBe("");
  });

  it("passes through plain hostnames", () => {
    expect(normalizeHostForSan("localhost")).toBe("localhost");
  });

  it("passes through IPs without brackets", () => {
    expect(normalizeHostForSan("127.0.0.1")).toBe("127.0.0.1");
  });
});

// ---------------------------------------------------------------------------
// collectSubjectAltNames
// ---------------------------------------------------------------------------

describe("collectSubjectAltNames", () => {
  it("includes localhost and loopback by default", () => {
    const sans = collectSubjectAltNames([]);

    expect(sans.dns).toContain("localhost");
    expect(sans.ips).toContain("127.0.0.1");
    expect(sans.ips).toContain("::1");
  });

  it("adds additional DNS hostnames", () => {
    const sans = collectSubjectAltNames(["myhost.local", "other.example.com"]);

    expect(sans.dns).toContain("myhost.local");
    expect(sans.dns).toContain("other.example.com");
  });

  it("adds additional IP addresses", () => {
    const sans = collectSubjectAltNames(["10.0.0.1"]);

    expect(sans.ips).toContain("10.0.0.1");
  });

  it("filters out wildcard bind hosts 0.0.0.0 and ::", () => {
    const sans = collectSubjectAltNames(["0.0.0.0", "::"]);

    expect(sans.dns).not.toContain("0.0.0.0");
    expect(sans.ips).not.toContain("0.0.0.0");
    expect(sans.dns).not.toContain("::");
    expect(sans.ips).not.toContain("::");
  });

  it("normalizes bracketed IPv6 to plain IP", () => {
    const sans = collectSubjectAltNames(["[fe80::1]"]);

    expect(sans.ips).toContain("fe80::1");
  });

  it("deduplicates entries", () => {
    const sans = collectSubjectAltNames(["localhost", "localhost", "127.0.0.1"]);

    const localhostCount = sans.dns.filter((d) => d === "localhost").length;
    expect(localhostCount).toBe(1);

    const loopbackCount = sans.ips.filter((ip) => ip === "127.0.0.1").length;
    expect(loopbackCount).toBe(1);
  });

  it("lowercases hostnames", () => {
    const sans = collectSubjectAltNames(["MyHost.LOCAL"]);

    expect(sans.dns).toContain("myhost.local");
    expect(sans.dns).not.toContain("MyHost.LOCAL");
  });
});

// ---------------------------------------------------------------------------
// renderOpenSslConfig
// ---------------------------------------------------------------------------

describe("renderOpenSslConfig", () => {
  it("renders config with DNS and IP SANs", () => {
    const config = renderOpenSslConfig({
      dns: ["localhost", "myhost.local"],
      ips: ["127.0.0.1", "::1"],
    });

    expect(config).toContain("[ req ]");
    expect(config).toContain("[ dn ]");
    expect(config).toContain("CN = localhost");
    expect(config).toContain("[ v3_req ]");
    expect(config).toContain("[ alt_names ]");
    expect(config).toContain("DNS.1 = localhost");
    expect(config).toContain("DNS.2 = myhost.local");
    expect(config).toContain("IP.1 = 127.0.0.1");
    expect(config).toContain("IP.2 = ::1");
  });

  it("uses first DNS as CN", () => {
    const config = renderOpenSslConfig({ dns: ["example.com"], ips: [] });

    expect(config).toContain("CN = example.com");
  });

  it("falls back to first IP as CN when no DNS", () => {
    const config = renderOpenSslConfig({ dns: [], ips: ["10.0.0.1"] });

    expect(config).toContain("CN = 10.0.0.1");
  });

  it("falls back to localhost CN when empty", () => {
    const config = renderOpenSslConfig({ dns: [], ips: [] });

    expect(config).toContain("CN = localhost");
  });

  it("includes serverAuth extended key usage", () => {
    const config = renderOpenSslConfig({ dns: ["localhost"], ips: [] });

    expect(config).toContain("extendedKeyUsage = serverAuth");
  });
});

// ---------------------------------------------------------------------------
// readCertificateFingerprint + readCertificateExpiryMs
// ---------------------------------------------------------------------------

describe.skipIf(!hasOpenSSL)("certificate reading (requires openssl)", () => {
  let tmpDir: string;
  let certPath: string;
  let keyPath: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "oppi-tls-cert-read-"));
    certPath = join(tmpDir, "test.crt");
    keyPath = join(tmpDir, "test.key");

    // Generate a self-signed cert valid for 30 days
    execSync(
      `openssl req -x509 -newkey rsa:2048 -nodes ` +
        `-keyout "${keyPath}" -out "${certPath}" ` +
        `-days 30 -subj "/CN=test-cert"`,
      { stdio: "ignore" },
    );
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  describe("readCertificateFingerprint", () => {
    it("returns sha256: prefixed base64url fingerprint", () => {
      const fp = readCertificateFingerprint(certPath);

      expect(fp).toMatch(/^sha256:[A-Za-z0-9_-]+$/);
    });

    it("returns consistent fingerprint for same cert", () => {
      const fp1 = readCertificateFingerprint(certPath);
      const fp2 = readCertificateFingerprint(certPath);

      expect(fp1).toBe(fp2);
    });

    it("throws on non-existent file", () => {
      expect(() => readCertificateFingerprint("/nonexistent/cert.pem")).toThrow();
    });
  });

  describe("readCertificateExpiryMs", () => {
    it("returns a timestamp in the future for a valid cert", () => {
      const expiryMs = readCertificateExpiryMs(certPath);

      expect(expiryMs).toBeGreaterThan(Date.now());
    });

    it("returns a timestamp roughly 30 days from now", () => {
      const expiryMs = readCertificateExpiryMs(certPath);
      const thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;
      const tolerance = 2 * 24 * 60 * 60 * 1000; // 2 day tolerance

      expect(Math.abs(expiryMs - Date.now() - thirtyDaysMs)).toBeLessThan(tolerance);
    });

    it("throws on non-existent file", () => {
      expect(() => readCertificateExpiryMs("/nonexistent/cert.pem")).toThrow();
    });
  });
});

// ---------------------------------------------------------------------------
// prepareTlsForServer
// ---------------------------------------------------------------------------

describe("prepareTlsForServer", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "oppi-tls-prepare-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns disabled config for tls.mode=disabled", () => {
    const config = makeConfig({ tls: { mode: "disabled" }, dataDir: tmpDir });
    const result = prepareTlsForServer(config, tmpDir);

    expect(result.mode).toBe("disabled");
    expect(result.enabled).toBe(false);
  });

  it("returns disabled config when tls is absent", () => {
    const config = makeConfig({ dataDir: tmpDir });
    const result = prepareTlsForServer(config, tmpDir);

    expect(result.mode).toBe("disabled");
    expect(result.enabled).toBe(false);
  });

  it("throws for auto mode (not implemented)", () => {
    const config = makeConfig({ tls: { mode: "auto" }, dataDir: tmpDir });

    expect(() => prepareTlsForServer(config, tmpDir)).toThrow(/not implemented/i);
  });

  it("throws for cloudflare mode (not implemented)", () => {
    const config = makeConfig({ tls: { mode: "cloudflare" }, dataDir: tmpDir });

    expect(() => prepareTlsForServer(config, tmpDir)).toThrow(/not implemented/i);
  });

  it("throws for manual mode when cert file does not exist", () => {
    const certPath = join(tmpDir, "missing.crt");
    const keyPath = join(tmpDir, "missing.key");
    const config = makeConfig({
      tls: { mode: "manual", certPath, keyPath },
      dataDir: tmpDir,
    });

    expect(() => prepareTlsForServer(config, tmpDir)).toThrow(/cert not found/i);
  });

  it("throws for manual mode when key file does not exist", () => {
    const certPath = join(tmpDir, "server.crt");
    const keyPath = join(tmpDir, "missing.key");
    writeFileSync(certPath, "dummy cert");
    const config = makeConfig({
      tls: { mode: "manual", certPath, keyPath },
      dataDir: tmpDir,
    });

    expect(() => prepareTlsForServer(config, tmpDir)).toThrow(/key not found/i);
  });

  it("throws for manual mode when certPath/keyPath are undefined", () => {
    const config = makeConfig({ tls: { mode: "manual" }, dataDir: tmpDir });

    expect(() => prepareTlsForServer(config, tmpDir)).toThrow(/requires.*certPath.*keyPath/i);
  });

  describe.skipIf(!hasOpenSSL)("self-signed generation (requires openssl)", () => {
    it("generates cert material in dataDir", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });
      const result = prepareTlsForServer(config, tmpDir);

      expect(result.mode).toBe("self-signed");
      expect(result.enabled).toBe(true);
      expect(result.certPath).toBeDefined();
      expect(result.keyPath).toBeDefined();
      expect(result.caPath).toBeDefined();
      expect(existsSync(result.certPath!)).toBe(true);
      expect(existsSync(result.keyPath!)).toBe(true);
      expect(existsSync(result.caPath!)).toBe(true);
    });

    it("produces a cert with valid fingerprint and future expiry", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });
      const result = prepareTlsForServer(config, tmpDir);

      const fp = readCertificateFingerprint(result.certPath!);
      expect(fp).toMatch(/^sha256:/);

      const expiryMs = readCertificateExpiryMs(result.certPath!);
      expect(expiryMs).toBeGreaterThan(Date.now());
    });

    it("skips generation when material already exists", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });

      // First call generates
      const result1 = prepareTlsForServer(config, tmpDir);
      const fp1 = readCertificateFingerprint(result1.certPath!);

      // Second call reuses existing
      const result2 = prepareTlsForServer(config, tmpDir);
      const fp2 = readCertificateFingerprint(result2.certPath!);

      expect(fp1).toBe(fp2);
    });

    it("does not generate when ensureSelfSigned is false", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });

      // No cert material exists — with ensureSelfSigned=false, it should fail
      // because the cert file won't exist
      expect(() => prepareTlsForServer(config, tmpDir, { ensureSelfSigned: false })).toThrow(
        /cert not found/i,
      );
    });

    it("includes additional hosts in SAN", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });
      prepareTlsForServer(config, tmpDir, { additionalHosts: ["myhost.example.com"] });

      const resolved = resolveTlsConfig(config, tmpDir);
      const certText = execSync(`openssl x509 -in "${resolved.certPath}" -noout -text`, {
        encoding: "utf-8",
      });

      expect(certText).toContain("myhost.example.com");
    });

    it("regenerates when partial material is present", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });

      // Create only the cert dir with partial files
      const certDir = join(tmpDir, "tls", "self-signed");
      mkdirSync(certDir, { recursive: true });
      writeFileSync(join(certDir, "server.crt"), "partial cert");
      // Missing key and ca — should trigger regeneration

      const result = prepareTlsForServer(config, tmpDir);
      expect(existsSync(result.certPath!)).toBe(true);
      expect(existsSync(result.keyPath!)).toBe(true);
      expect(existsSync(result.caPath!)).toBe(true);

      // Verify the cert is real (not our dummy text)
      const fp = readCertificateFingerprint(result.certPath!);
      expect(fp).toMatch(/^sha256:/);
    });
  });
});

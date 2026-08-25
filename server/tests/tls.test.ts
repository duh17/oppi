import { execFile, execSync } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir, homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  certificateMatchesHost,
  collectSubjectAltNames,
  isTailscaleHostname,
  normalizeHostForSan,
  prepareTlsForServer,
  promoteTailscaleMaterial,
  readCertificateExpiryMs,
  readCertificateFingerprint,
  readValidTailnetDnsName,
  renderOpenSslConfig,
  resolveTlsConfig,
  tlsSchemeForConfig,
  validateTailscaleMaterial,
} from "../src/tls.js";
import type { ServerConfig } from "../src/types.js";

const execFileAsync = promisify(execFile);

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

function logSkip(unavailable: boolean, suite: string, reason: string): boolean {
  if (unavailable) console.warn(`[test] Skipping ${suite}: ${reason}`);
  return unavailable;
}

async function waitForCondition(condition: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for test condition");
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
}

function makeConfig(overrides: Partial<ServerConfig> = {}): ServerConfig {
  return {
    port: 7749,
    host: "127.0.0.1",
    dataDir: "/tmp/oppi-test",
    sessionIdleTimeoutMs: 600_000,
    workspaceIdleTimeoutMs: 1_800_000,
    maxSessionsPerWorkspace: 3,
    maxSessionsGlobal: 5,
    ...overrides,
  };
}

function generateLeafCertificate(
  certPath: string,
  keyPath: string,
  options: { dnsSans?: string[]; commonName?: string; days?: number } = {},
): void {
  const commonName = options.commonName ?? options.dnsSans?.[0] ?? "test-cert";
  const sanArg = options.dnsSans?.length
    ? ` -addext "subjectAltName=${options.dnsSans.map((name) => `DNS:${name}`).join(",")}"`
    : "";
  execSync(
    `openssl req -x509 -newkey rsa:2048 -nodes` +
      ` -keyout "${keyPath}" -out "${certPath}"` +
      ` -days ${options.days ?? 30} -subj "/CN=${commonName}"${sanArg}`,
    { stdio: "ignore" },
  );
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
    expect(isTailscaleHostname("my-server.tail00000.ts.net")).toBe(true);
  });

  it("accepts *.beta.tailscale.net hostnames", () => {
    expect(isTailscaleHostname("node.beta.tailscale.net")).toBe(true);
  });

  it("is case-insensitive", () => {
    expect(isTailscaleHostname("My-Server.Tail00000.TS.NET")).toBe(true);
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

describe.skipIf(
  logSkip(
    !hasOpenSSL,
    "certificate reading (requires openssl)",
    "openssl executable is unavailable",
  ),
)("certificate reading (requires openssl)", () => {
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
// Tailnet certificate identity
// ---------------------------------------------------------------------------

describe.skipIf(
  logSkip(!hasOpenSSL, "Tailnet certificate identity", "openssl executable is unavailable"),
)("Tailnet certificate identity", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "oppi-tailnet-cert-"));
  });

  afterEach(() => {
    vi.useRealTimers();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("selects an exact Tailnet DNS SAN and can require a preferred SAN", () => {
    const certPath = join(tmpDir, "server.crt");
    const keyPath = join(tmpDir, "server.key");
    generateLeafCertificate(certPath, keyPath, {
      dnsSans: ["first.tail00000.ts.net", "second.tail00000.ts.net"],
    });

    expect(readValidTailnetDnsName(certPath)).toBe("first.tail00000.ts.net");
    expect(readValidTailnetDnsName(certPath, "SECOND.TAIL00000.TS.NET")).toBe(
      "second.tail00000.ts.net",
    );
  });

  it("rejects a Tailnet-looking common name when the certificate has no DNS SAN", () => {
    const certPath = join(tmpDir, "server.crt");
    const keyPath = join(tmpDir, "server.key");
    generateLeafCertificate(certPath, keyPath, {
      commonName: "node.tail00000.ts.net",
    });

    expect(() => readValidTailnetDnsName(certPath)).toThrow(/no valid Tailnet DNS SAN/);
  });

  it("rejects malformed, expired, and not-yet-valid certificates", () => {
    const malformedPath = join(tmpDir, "malformed.crt");
    writeFileSync(malformedPath, "not a certificate");
    expect(() => readValidTailnetDnsName(malformedPath)).toThrow(/malformed/);

    const certPath = join(tmpDir, "server.crt");
    const keyPath = join(tmpDir, "server.key");
    generateLeafCertificate(certPath, keyPath, {
      dnsSans: ["node.tail00000.ts.net"],
      days: 1,
    });
    const cert = new X509Certificate(readFileSync(certPath));
    expect(() =>
      readValidTailnetDnsName(certPath, undefined, Date.parse(cert.validTo) + 1),
    ).toThrow(/expired/);
    expect(() =>
      readValidTailnetDnsName(certPath, undefined, Date.parse(cert.validFrom) - 1),
    ).toThrow(/not yet valid/);
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

  describe.skipIf(
    logSkip(
      !hasOpenSSL,
      "Tailscale certificate lifecycle (requires openssl)",
      "openssl executable is unavailable",
    ),
  )("Tailscale certificate lifecycle (requires openssl)", () => {
    let previousPath: string | undefined;
    let fakeBinDir: string;

    beforeEach(() => {
      previousPath = process.env.PATH;
      fakeBinDir = join(tmpDir, "bin");
      mkdirSync(fakeBinDir, { recursive: true });
    });

    afterEach(() => {
      process.env.PATH = previousPath;
      vi.useRealTimers();
    });

    function tailscaleConfig(): ServerConfig {
      return makeConfig({ tls: { mode: "tailscale" }, dataDir: tmpDir });
    }

    function stopTailscale(): void {
      process.env.PATH = fakeBinDir;
    }

    function writeExistingMaterial(days = 30): { certPath: string; keyPath: string } {
      const resolved = resolveTlsConfig(tailscaleConfig(), tmpDir);
      mkdirSync(join(tmpDir, "tls", "tailscale"), { recursive: true });
      generateLeafCertificate(resolved.certPath!, resolved.keyPath!, {
        dnsSans: ["node.tail00000.ts.net"],
        days,
      });
      return { certPath: resolved.certPath!, keyPath: resolved.keyPath! };
    }

    function renewalLockDir(resolved: { certPath?: string; keyPath?: string }): string {
      const identity = `${resolved.certPath ?? ""}\0${resolved.keyPath ?? ""}`;
      const digest = createHash("sha256").update(identity).digest("hex").slice(0, 24);
      return join(tmpDir, "tls", "locks", `tailscale-${digest}`);
    }

    it("reuses locally consistent self-signed material without asserting public-chain trust", () => {
      const paths = writeExistingMaterial();
      const fingerprint = readCertificateFingerprint(paths.certPath);
      stopTailscale();

      const resolved = prepareTlsForServer(tailscaleConfig(), tmpDir);

      expect(resolved.certPath).toBe(paths.certPath);
      expect(readCertificateFingerprint(paths.certPath)).toBe(fingerprint);
    });

    it("reuses valid offline custom material from a read-only directory", () => {
      const customDir = join(tmpDir, "read-only-custom-tls");
      const certPath = join(customDir, "server.crt");
      const keyPath = join(customDir, "server.key");
      mkdirSync(customDir);
      generateLeafCertificate(certPath, keyPath, {
        dnsSans: ["node.tail00000.ts.net"],
      });
      chmodSync(customDir, 0o555);
      stopTailscale();
      const config = makeConfig({
        dataDir: tmpDir,
        tls: { mode: "tailscale", certPath, keyPath },
      });

      try {
        const resolved = prepareTlsForServer(config, tmpDir);

        expect(resolved.certPath).toBe(certPath);
        expect(validateTailscaleMaterial(resolved)).toBe("node.tail00000.ts.net");
        expect(readdirSync(customDir).filter((entry) => entry.includes("oppi-renew"))).toEqual([]);
        expect(existsSync(renewalLockDir(resolved))).toBe(true);
      } finally {
        chmodSync(customDir, 0o755);
      }
    });

    it("keeps valid existing material when live renewal fails", () => {
      const paths = writeExistingMaterial();
      const fingerprint = readCertificateFingerprint(paths.certPath);
      const fakeTailscalePath = join(fakeBinDir, "tailscale");
      writeFileSync(
        fakeTailscalePath,
        `#!/bin/sh\nif [ "$1" = "status" ]; then\n  printf '%s\\n' '{"Self":{"DNSName":"node.tail00000.ts.net."}}'\n  exit 0\nfi\nprintf '%s\\n' 'daemon stopped during renewal' >&2\nexit 1\n`,
        { mode: 0o755 },
      );
      stopTailscale();

      const resolved = prepareTlsForServer(tailscaleConfig(), tmpDir);

      expect(resolved.certPath).toBe(paths.certPath);
      expect(readCertificateFingerprint(paths.certPath)).toBe(fingerprint);
    });

    it("fails closed when stopped Tailscale has missing, malformed, or expired material", () => {
      stopTailscale();
      expect(() => prepareTlsForServer(tailscaleConfig(), tmpDir)).toThrow(
        /Tailscale is unavailable.*certificate not found/,
      );

      const resolved = resolveTlsConfig(tailscaleConfig(), tmpDir);
      mkdirSync(join(tmpDir, "tls", "tailscale"), { recursive: true });
      writeFileSync(resolved.certPath!, "not a certificate");
      writeFileSync(resolved.keyPath!, "not a key");
      expect(() => prepareTlsForServer(tailscaleConfig(), tmpDir)).toThrow(
        /Tailscale is unavailable.*certificate is malformed/,
      );

      rmSync(resolved.certPath!, { force: true });
      rmSync(resolved.keyPath!, { force: true });
      process.env.PATH = previousPath;
      const paths = writeExistingMaterial(1);
      const expiry = readCertificateExpiryMs(paths.certPath);
      stopTailscale();
      vi.useFakeTimers();
      vi.setSystemTime(expiry + 1);
      expect(() => prepareTlsForServer(tailscaleConfig(), tmpDir)).toThrow(
        /Tailscale is unavailable.*certificate is expired/,
      );
    });

    it("rejects a mismatched private key even when the certificate is valid", () => {
      const paths = writeExistingMaterial();
      const replacementCert = join(tmpDir, "replacement.crt");
      generateLeafCertificate(replacementCert, paths.keyPath, {
        dnsSans: ["node.tail00000.ts.net"],
      });
      stopTailscale();

      expect(() => prepareTlsForServer(tailscaleConfig(), tmpDir)).toThrow(
        /certificate\/key material is malformed or mismatched/,
      );
    });

    it("rolls back the original generation when key promotion fails after certificate promotion", () => {
      const paths = writeExistingMaterial();
      const originalFingerprint = readCertificateFingerprint(paths.certPath);
      const originalKey = readFileSync(paths.keyPath, "utf8");
      const stagedDir = join(tmpDir, "staged");
      const stagedCertPath = join(stagedDir, "server.crt");
      const stagedKeyPath = join(stagedDir, "server.key");
      mkdirSync(stagedDir);
      generateLeafCertificate(stagedCertPath, stagedKeyPath, {
        dnsSans: ["node.tail00000.ts.net"],
      });
      let forcedFailure = false;

      expect(() =>
        promoteTailscaleMaterial(
          resolveTlsConfig(tailscaleConfig(), tmpDir),
          stagedCertPath,
          stagedKeyPath,
          "node.tail00000.ts.net",
          (source, destination) => {
            if (!forcedFailure && source === stagedKeyPath && destination === paths.keyPath) {
              forcedFailure = true;
              throw new Error("forced between-rename failure");
            }
            renameSync(source, destination);
          },
        ),
      ).toThrow(
        /forced between-rename failure.*previous certificate\/key generation was restored/i,
      );
      expect(forcedFailure).toBe(true);
      expect(readCertificateFingerprint(paths.certPath)).toBe(originalFingerprint);
      expect(readFileSync(paths.keyPath, "utf8")).toBe(originalKey);
    });

    it.each([
      ["certificate backup", "certificate"],
      ["key backup after certificate cleanup", "key"],
    ])("keeps the committed live pair when %s deletion fails", (_label, failureTarget) => {
      const paths = writeExistingMaterial();
      const stagedDir = join(tmpDir, `cleanup-${failureTarget}`);
      const stagedCertPath = join(stagedDir, "server.crt");
      const stagedKeyPath = join(stagedDir, "server.key");
      mkdirSync(stagedDir);
      generateLeafCertificate(stagedCertPath, stagedKeyPath, {
        dnsSans: ["node.tail00000.ts.net"],
      });
      const committedFingerprint = readCertificateFingerprint(stagedCertPath);
      const certBackupPath = `${paths.certPath}.oppi-renew-backup`;
      const keyBackupPath = `${paths.keyPath}.oppi-renew-backup`;

      expect(() =>
        promoteTailscaleMaterial(
          resolveTlsConfig(tailscaleConfig(), tmpDir),
          stagedCertPath,
          stagedKeyPath,
          "node.tail00000.ts.net",
          renameSync,
          (path) => {
            if (
              (failureTarget === "certificate" && path === certBackupPath) ||
              (failureTarget === "key" && path === keyBackupPath)
            ) {
              throw new Error(`forced ${failureTarget} backup cleanup failure`);
            }
            rmSync(path, { force: true });
          },
        ),
      ).toThrow(/cleanup failure.*committed live pair remains valid/i);

      expect(readCertificateFingerprint(paths.certPath)).toBe(committedFingerprint);
      expect(
        validateTailscaleMaterial(
          resolveTlsConfig(tailscaleConfig(), tmpDir),
          "node.tail00000.ts.net",
        ),
      ).toBe("node.tail00000.ts.net");
      expect(existsSync(keyBackupPath)).toBe(failureTarget === "key");
      expect(existsSync(certBackupPath)).toBe(failureTarget === "certificate");
    });

    it.each(["certificate", "key"])(
      "prefers a complete valid live pair over one-sided %s backup residue",
      (residue) => {
        const paths = writeExistingMaterial();
        const oldDir = join(tmpDir, `old-${residue}`);
        const oldCertPath = join(oldDir, "server.crt");
        const oldKeyPath = join(oldDir, "server.key");
        mkdirSync(oldDir);
        generateLeafCertificate(oldCertPath, oldKeyPath, {
          dnsSans: ["node.tail00000.ts.net"],
        });
        generateLeafCertificate(paths.certPath, paths.keyPath, {
          dnsSans: ["node.tail00000.ts.net"],
        });
        const committedFingerprint = readCertificateFingerprint(paths.certPath);
        const backupPath =
          residue === "certificate"
            ? `${paths.certPath}.oppi-renew-backup`
            : `${paths.keyPath}.oppi-renew-backup`;
        renameSync(residue === "certificate" ? oldCertPath : oldKeyPath, backupPath);
        stopTailscale();

        prepareTlsForServer(tailscaleConfig(), tmpDir);

        expect(readCertificateFingerprint(paths.certPath)).toBe(committedFingerprint);
        expect(
          validateTailscaleMaterial(
            resolveTlsConfig(tailscaleConfig(), tmpDir),
            "node.tail00000.ts.net",
          ),
        ).toBe("node.tail00000.ts.net");
        expect(existsSync(backupPath)).toBe(false);
      },
    );

    it("recovers an interrupted partial destination from the preserved generation", () => {
      const paths = writeExistingMaterial();
      const originalFingerprint = readCertificateFingerprint(paths.certPath);
      const originalKey = readFileSync(paths.keyPath, "utf8");
      const certBackupPath = `${paths.certPath}.oppi-renew-backup`;
      const keyBackupPath = `${paths.keyPath}.oppi-renew-backup`;
      renameSync(paths.certPath, certBackupPath);
      renameSync(paths.keyPath, keyBackupPath);

      const interruptedDir = join(tmpDir, "interrupted");
      const interruptedCertPath = join(interruptedDir, "server.crt");
      const interruptedKeyPath = join(interruptedDir, "server.key");
      mkdirSync(interruptedDir);
      generateLeafCertificate(interruptedCertPath, interruptedKeyPath, {
        dnsSans: ["node.tail00000.ts.net"],
      });
      renameSync(interruptedCertPath, paths.certPath);
      stopTailscale();

      prepareTlsForServer(tailscaleConfig(), tmpDir);

      expect(readCertificateFingerprint(paths.certPath)).toBe(originalFingerprint);
      expect(readFileSync(paths.keyPath, "utf8")).toBe(originalKey);
      expect(existsSync(certBackupPath)).toBe(false);
      expect(existsSync(keyBackupPath)).toBe(false);
    });

    it("serializes concurrent renewal attempts for the same destination", async () => {
      const stateDir = join(tmpDir, "renewal-state");
      mkdirSync(stateDir, { recursive: true });
      const fakeTailscalePath = join(fakeBinDir, "tailscale");
      writeFileSync(
        fakeTailscalePath,
        `#!/bin/sh\nset -eu\nif [ "$1" = "status" ]; then\n  printf '%s\\n' '{"Self":{"DNSName":"node.tail00000.ts.net."}}'\n  exit 0\nfi\nprintf 'arrival\\n' >> "$OPPI_TEST_RENEWAL_STATE/arrivals"\ni=0\nwhile [ "$(wc -l < "$OPPI_TEST_RENEWAL_STATE/arrivals")" -lt 2 ] && [ "$i" -lt 20 ]; do\n  sleep 0.1\n  i=$((i + 1))\ndone\nif ! mkdir "$OPPI_TEST_RENEWAL_STATE/active" 2>/dev/null; then\n  : > "$OPPI_TEST_RENEWAL_STATE/overlap"\n  exit 1\nfi\ntrap 'rmdir "$OPPI_TEST_RENEWAL_STATE/active"' EXIT\nshift\ncert_file=''\nkey_file=''\nwhile [ "$#" -gt 0 ]; do\n  case "$1" in\n    --cert-file) cert_file="$2"; shift 2 ;;\n    --key-file) key_file="$2"; shift 2 ;;\n    --min-validity) shift 2 ;;\n    *) host="$1"; shift ;;\n  esac\ndone\nsleep 0.5\nopenssl req -x509 -newkey rsa:2048 -nodes -keyout "$key_file" -out "$cert_file" -days 30 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1\n`,
        { mode: 0o755 },
      );
      const workerPath = join(tmpDir, "renew-worker.ts");
      const tlsSourcePath = resolve(__dirname, "../src/tls.ts");
      writeFileSync(
        workerPath,
        `import { prepareTlsForServer } from ${JSON.stringify(tlsSourcePath)};\n` +
          `const dataDir = ${JSON.stringify(tmpDir)};\n` +
          `prepareTlsForServer({ host: "127.0.0.1", port: 7749, dataDir, sessionIdleTimeoutMs: 600000, workspaceIdleTimeoutMs: 1800000, maxSessionsPerWorkspace: 3, maxSessionsGlobal: 5, tls: { mode: "tailscale" } }, dataDir);\n`,
      );
      const env = {
        ...process.env,
        PATH: `${fakeBinDir}:${previousPath ?? ""}`,
        OPPI_TEST_RENEWAL_STATE: stateDir,
      };
      const tsxPath = join(process.cwd(), "node_modules", ".bin", "tsx");

      await Promise.all([
        execFileAsync(tsxPath, [workerPath], { env, timeout: 20_000 }),
        execFileAsync(tsxPath, [workerPath], { env, timeout: 20_000 }),
      ]);

      expect(existsSync(join(stateDir, "overlap"))).toBe(false);
      const resolved = resolveTlsConfig(tailscaleConfig(), tmpDir);
      expect(readValidTailnetDnsName(resolved.certPath!)).toBe("node.tail00000.ts.net");
      const lockDir = renewalLockDir(resolved);
      expect(
        existsSync(lockDir)
          ? readdirSync(lockDir).filter((entry) => /^\d+-\d+-[0-9a-f-]+\.ticket$/.test(entry))
          : [],
      ).toEqual([]);
    }, 30_000);

    it("keeps three long queued renewals mutually exclusive when a waiter becomes active", async () => {
      const stateDir = join(tmpDir, "three-process-lock-state");
      mkdirSync(stateDir);
      const fakeTailscalePath = join(fakeBinDir, "tailscale");
      writeFileSync(
        fakeTailscalePath,
        `#!/bin/sh\nset -eu\nif [ "$1" = "status" ]; then\n  printf '%s\\n' '{"Self":{"DNSName":"node.tail00000.ts.net."}}'\n  exit 0\nfi\nprintf '%s\\n' "$OPPI_TEST_WORKER" >> "$OPPI_TEST_RENEWAL_STATE/arrivals"\nowns_active=0\nif mkdir "$OPPI_TEST_RENEWAL_STATE/active" 2>/dev/null; then\n  owns_active=1\nelse\n  : > "$OPPI_TEST_RENEWAL_STATE/overlap"\nfi\nsleep "$OPPI_TEST_CERT_SLEEP"\nif [ "$owns_active" -eq 1 ]; then\n  rmdir "$OPPI_TEST_RENEWAL_STATE/active"\nfi\nshift\ncert_file=''\nkey_file=''\nwhile [ "$#" -gt 0 ]; do\n  case "$1" in\n    --cert-file) cert_file="$2"; shift 2 ;;\n    --key-file) key_file="$2"; shift 2 ;;\n    --min-validity) shift 2 ;;\n    *) host="$1"; shift ;;\n  esac\ndone\nopenssl req -x509 -newkey rsa:2048 -nodes -keyout "$key_file" -out "$cert_file" -days 30 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1\n`,
        { mode: 0o755 },
      );
      const workerPath = join(tmpDir, "long-queue-worker.ts");
      const tlsSourcePath = resolve(__dirname, "../src/tls.ts");
      writeFileSync(
        workerPath,
        `import { prepareTlsForServer } from ${JSON.stringify(tlsSourcePath)};\n` +
          `const dataDir = ${JSON.stringify(tmpDir)};\n` +
          `prepareTlsForServer({ host: "127.0.0.1", port: 7749, dataDir, sessionIdleTimeoutMs: 600000, workspaceIdleTimeoutMs: 1800000, maxSessionsPerWorkspace: 3, maxSessionsGlobal: 5, tls: { mode: "tailscale" } }, dataDir);\n`,
      );
      const baseEnv = {
        ...process.env,
        PATH: `${fakeBinDir}:${previousPath ?? ""}`,
        OPPI_TEST_RENEWAL_STATE: stateDir,
      };
      const tsxPath = join(process.cwd(), "node_modules", ".bin", "tsx");
      const first = execFileAsync(tsxPath, [workerPath], {
        env: { ...baseEnv, OPPI_TEST_WORKER: "A", OPPI_TEST_CERT_SLEEP: "2" },
        timeout: 20_000,
      }).then(
        (result) => ({ result }),
        (error: unknown) => ({ error }),
      );
      await waitForCondition(() => existsSync(join(stateDir, "active")));

      const second = execFileAsync(tsxPath, [workerPath], {
        env: {
          ...baseEnv,
          OPPI_TEST_WORKER: "B",
          OPPI_TEST_CERT_SLEEP: "4",
        },
        timeout: 20_000,
      }).then(
        (result) => ({ result }),
        (error: unknown) => ({ error }),
      );
      const resolved = resolveTlsConfig(tailscaleConfig(), tmpDir);
      const lockDir = renewalLockDir(resolved);
      await waitForCondition(
        () =>
          existsSync(lockDir) &&
          readdirSync(lockDir).filter((entry) => entry.endsWith(".ticket")).length >= 2,
      );
      const third = execFileAsync(tsxPath, [workerPath], {
        env: { ...baseEnv, OPPI_TEST_WORKER: "C", OPPI_TEST_CERT_SLEEP: "1" },
        timeout: 20_000,
      }).then(
        (result) => ({ result }),
        (error: unknown) => ({ error }),
      );

      await waitForCondition(
        () =>
          existsSync(join(stateDir, "arrivals")) &&
          readFileSync(join(stateDir, "arrivals"), "utf8").split("\n").includes("B"),
      );
      const activeTicket = readdirSync(lockDir)
        .filter((entry) => entry.endsWith(".ticket"))
        .map((entry) => join(lockDir, entry))
        .find((ticketPath) => {
          try {
            return (
              (
                JSON.parse(readFileSync(join(ticketPath, "state.json"), "utf8")) as {
                  active?: boolean;
                }
              ).active === true
            );
          } catch {
            return false;
          }
        });
      expect(activeTicket).toBeDefined();
      const oldQueueTime = new Date(Date.now() - 120_000);
      utimesSync(activeTicket!, oldQueueTime, oldQueueTime);

      const results = await Promise.all([first, second, third]);
      const failures = results.flatMap((result) => ("error" in result ? [result.error] : []));
      expect(failures).toEqual([]);
      expect(existsSync(join(stateDir, "overlap"))).toBe(false);
      expect(readFileSync(join(stateDir, "arrivals"), "utf8").trim().split("\n")).toEqual([
        "A",
        "B",
        "C",
      ]);
      expect(validateTailscaleMaterial(resolved)).toBe("node.tail00000.ts.net");
    }, 25_000);

    it("waits across the 60/90 boundary for a fresh empty current-v2 ticket, then reclaims it", async () => {
      const paths = writeExistingMaterial();
      const resolved = resolveTlsConfig(tailscaleConfig(), tmpDir);
      const lockDir = renewalLockDir(resolved);
      mkdirSync(lockDir, { recursive: true });
      const emptyTicket = join(
        lockDir,
        `${Date.now()}-${process.pid}-00000000-0000-4000-8000-000000000001.ticket`,
      );
      mkdirSync(emptyTicket);
      const sixtyOneSecondsAgo = new Date(Date.now() - 61_000);
      utimesSync(emptyTicket, sixtyOneSecondsAgo, sixtyOneSecondsAgo);

      const workerPath = join(tmpDir, "empty-lock-worker.ts");
      const tlsSourcePath = resolve(__dirname, "../src/tls.ts");
      writeFileSync(
        workerPath,
        `import { prepareTlsForServer } from ${JSON.stringify(tlsSourcePath)};\n` +
          `const dataDir = ${JSON.stringify(tmpDir)};\n` +
          `prepareTlsForServer({ host: "127.0.0.1", port: 7749, dataDir, sessionIdleTimeoutMs: 600000, workspaceIdleTimeoutMs: 1800000, maxSessionsPerWorkspace: 3, maxSessionsGlobal: 5, tls: { mode: "tailscale" } }, dataDir);\n`,
      );
      const tsxPath = join(process.cwd(), "node_modules", ".bin", "tsx");
      writeFileSync(join(fakeBinDir, "tailscale"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
      let settled = false;
      const runWorker = execFileAsync(tsxPath, [workerPath], {
        env: { ...process.env, PATH: `${fakeBinDir}:${previousPath ?? ""}` },
        timeout: 5_000,
      }).finally(() => {
        settled = true;
      });

      await new Promise((resolveWait) => setTimeout(resolveWait, 300));
      expect(settled).toBe(false);
      const almostStale = new Date(Date.now() - 89_900);
      utimesSync(emptyTicket, almostStale, almostStale);
      await expect(runWorker).resolves.toBeDefined();
      expect(existsSync(emptyTicket)).toBe(false);
      expect(readCertificateFingerprint(paths.certPath)).toMatch(/^sha256:/);
    }, 10_000);

    it("atomically reclaims an aged live-PID owner under simultaneous claimants", async () => {
      const resolved = resolveTlsConfig(tailscaleConfig(), tmpDir);
      mkdirSync(dirname(resolved.certPath!), { recursive: true });
      const lockDir = renewalLockDir(resolved);
      mkdirSync(lockDir, { recursive: true });
      const staleTicket = `${Date.now()}-${process.pid}-00000000-0000-4000-8000-000000000000.ticket`;
      const staleTicketPath = join(lockDir, staleTicket);
      mkdirSync(staleTicketPath);
      const staleTime = new Date(Date.now() - 120_000);
      utimesSync(staleTicketPath, staleTime, staleTime);
      mkdirSync(join(lockDir, "empty.ticket"));

      const stateDir = join(tmpDir, "stale-lock-state");
      mkdirSync(stateDir);
      const fakeTailscalePath = join(fakeBinDir, "tailscale");
      writeFileSync(
        fakeTailscalePath,
        `#!/bin/sh\nset -eu\nif [ "$1" = "status" ]; then\n  printf '%s\\n' '{"Self":{"DNSName":"node.tail00000.ts.net."}}'\n  exit 0\nfi\nprintf 'arrival\\n' >> "$OPPI_TEST_RENEWAL_STATE/arrivals"\nif ! mkdir "$OPPI_TEST_RENEWAL_STATE/active" 2>/dev/null; then\n  : > "$OPPI_TEST_RENEWAL_STATE/overlap"\n  exit 1\nfi\ntrap 'rmdir "$OPPI_TEST_RENEWAL_STATE/active"' EXIT\nshift\ncert_file=''\nkey_file=''\nwhile [ "$#" -gt 0 ]; do\n  case "$1" in\n    --cert-file) cert_file="$2"; shift 2 ;;\n    --key-file) key_file="$2"; shift 2 ;;\n    --min-validity) shift 2 ;;\n    *) host="$1"; shift ;;\n  esac\ndone\nsleep 0.5\nopenssl req -x509 -newkey rsa:2048 -nodes -keyout "$key_file" -out "$cert_file" -days 30 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1\n`,
        { mode: 0o755 },
      );
      const workerPath = join(tmpDir, "stale-lock-worker.ts");
      const tlsSourcePath = resolve(__dirname, "../src/tls.ts");
      writeFileSync(
        workerPath,
        `import { prepareTlsForServer } from ${JSON.stringify(tlsSourcePath)};\n` +
          `const dataDir = ${JSON.stringify(tmpDir)};\n` +
          `prepareTlsForServer({ host: "127.0.0.1", port: 7749, dataDir, sessionIdleTimeoutMs: 600000, workspaceIdleTimeoutMs: 1800000, maxSessionsPerWorkspace: 3, maxSessionsGlobal: 5, tls: { mode: "tailscale" } }, dataDir);\n`,
      );
      const env = {
        ...process.env,
        PATH: `${fakeBinDir}:${previousPath ?? ""}`,
        OPPI_TEST_RENEWAL_STATE: stateDir,
      };
      const tsxPath = join(process.cwd(), "node_modules", ".bin", "tsx");

      await Promise.all([
        execFileAsync(tsxPath, [workerPath], { env, timeout: 15_000 }),
        execFileAsync(tsxPath, [workerPath], { env, timeout: 15_000 }),
      ]);

      expect(existsSync(join(stateDir, "overlap"))).toBe(false);
      expect(readFileSync(join(stateDir, "arrivals"), "utf8").trim().split("\n")).toHaveLength(2);
      expect(existsSync(staleTicketPath)).toBe(false);
      expect(
        readdirSync(lockDir).filter((entry) => /^\d+-\d+-[0-9a-f-]+\.ticket$/.test(entry)),
      ).toEqual([]);
      expect(existsSync(join(lockDir, "empty.ticket"))).toBe(true);
      expect(validateTailscaleMaterial(resolved)).toBe("node.tail00000.ts.net");
    }, 25_000);
  });

  describe.skipIf(
    logSkip(
      !hasOpenSSL,
      "self-signed generation (requires openssl)",
      "openssl executable is unavailable",
    ),
  )("self-signed generation (requires openssl)", () => {
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

    it("reports true when cert SAN covers the requested host", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });
      const resolved = prepareTlsForServer(config, tmpDir, {
        additionalHosts: ["myhost.example.com", "192.0.2.42"],
      });

      expect(certificateMatchesHost(resolved.certPath!, "myhost.example.com")).toBe(true);
      expect(certificateMatchesHost(resolved.certPath!, "192.0.2.42")).toBe(true);
    });

    it("reports false when cert SAN does not cover the requested host", () => {
      const config = makeConfig({ tls: { mode: "self-signed" }, dataDir: tmpDir });
      const resolved = prepareTlsForServer(config, tmpDir, {
        additionalHosts: ["myhost.example.com"],
      });

      expect(certificateMatchesHost(resolved.certPath!, "203.0.113.77")).toBe(false);
      expect(certificateMatchesHost(resolved.certPath!, "other.example.com")).toBe(false);
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

import { execFileSync } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { isIP } from "node:net";
import { homedir, networkInterfaces } from "node:os";
import { dirname, join } from "node:path";
import type { ServerConfig, TlsMode } from "./types.js";

const WILDCARD_BIND_HOSTS = new Set(["0.0.0.0", "::"]);

export interface ResolvedTlsConfig {
  mode: TlsMode;
  enabled: boolean;
  certPath?: string;
  keyPath?: string;
  caPath?: string;
}

export interface TlsPreparationOptions {
  additionalHosts?: string[];
  /**
   * Generate self-signed cert material when missing.
   * Disable for diagnostics that should report missing artifacts.
   */
  ensureSelfSigned?: boolean;
}

interface SelfSignedPaths {
  certPath: string;
  keyPath: string;
  caPath: string;
  caKeyPath: string;
  serialPath: string;
}

interface TailscaleStatus {
  Self?: {
    DNSName?: string;
  };
}

const TAILNET_SUFFIXES = [".ts.net", ".beta.tailscale.net"];
const TAILSCALE_MIN_VALIDITY = "720h";

function expandHome(path: string): string {
  if (!path.startsWith("~/")) return path;
  return path.replace(/^~\//, `${homedir()}/`);
}

function defaultSelfSignedPaths(dataDir: string): SelfSignedPaths {
  const baseDir = join(dataDir, "tls", "self-signed");
  return {
    certPath: join(baseDir, "server.crt"),
    keyPath: join(baseDir, "server.key"),
    caPath: join(baseDir, "ca.crt"),
    caKeyPath: join(baseDir, "ca.key"),
    serialPath: join(baseDir, "ca.srl"),
  };
}

function defaultTailscalePaths(dataDir: string): { certPath: string; keyPath: string } {
  const baseDir = join(dataDir, "tls", "tailscale");
  return {
    certPath: join(baseDir, "server.crt"),
    keyPath: join(baseDir, "server.key"),
  };
}

function isTailnetDnsName(host: string): boolean {
  return TAILNET_SUFFIXES.some((suffix) => host.endsWith(suffix));
}

export function isTailscaleHostname(host: string): boolean {
  const normalized = normalizeHostForSan(host);
  return normalized.length > 0 && isTailnetDnsName(normalized);
}

export function tlsSchemeForConfig(config: ServerConfig): "http" | "https" {
  const mode = config.tls?.mode ?? "disabled";
  return mode === "disabled" ? "http" : "https";
}

export function resolveTlsConfig(config: ServerConfig, dataDir: string): ResolvedTlsConfig {
  const mode = config.tls?.mode ?? "disabled";
  if (mode === "disabled") {
    return { mode, enabled: false };
  }

  if (mode === "self-signed") {
    const defaults = defaultSelfSignedPaths(dataDir);
    return {
      mode,
      enabled: true,
      certPath: expandHome(config.tls?.certPath ?? defaults.certPath),
      keyPath: expandHome(config.tls?.keyPath ?? defaults.keyPath),
      caPath: expandHome(config.tls?.caPath ?? defaults.caPath),
    };
  }

  if (mode === "tailscale") {
    const defaults = defaultTailscalePaths(dataDir);
    return {
      mode,
      enabled: true,
      certPath: expandHome(config.tls?.certPath ?? defaults.certPath),
      keyPath: expandHome(config.tls?.keyPath ?? defaults.keyPath),
      caPath: config.tls?.caPath ? expandHome(config.tls.caPath) : undefined,
    };
  }

  return {
    mode,
    enabled: true,
    certPath: config.tls?.certPath ? expandHome(config.tls.certPath) : undefined,
    keyPath: config.tls?.keyPath ? expandHome(config.tls.keyPath) : undefined,
    caPath: config.tls?.caPath ? expandHome(config.tls.caPath) : undefined,
  };
}

export function prepareTlsForServer(
  config: ServerConfig,
  dataDir: string,
  options: TlsPreparationOptions = {},
): ResolvedTlsConfig {
  const resolved = resolveTlsConfig(config, dataDir);
  if (!resolved.enabled) {
    return resolved;
  }

  if (resolved.mode === "auto" || resolved.mode === "cloudflare") {
    throw new Error(
      `TLS mode "${resolved.mode}" is not implemented yet. Use tls.mode=tailscale|self-signed|manual|disabled for now.`,
    );
  }

  if (resolved.mode === "self-signed" && options.ensureSelfSigned !== false) {
    ensureSelfSignedMaterial(resolved, options.additionalHosts ?? []);
  }

  if (resolved.mode === "tailscale") {
    ensureTailscaleMaterial(resolved, options.additionalHosts ?? []);
  }

  if (!resolved.certPath || !resolved.keyPath) {
    throw new Error(`TLS mode "${resolved.mode}" requires tls.certPath and tls.keyPath`);
  }

  if (!existsSync(resolved.certPath)) {
    throw new Error(`TLS cert not found: ${resolved.certPath}`);
  }

  if (!existsSync(resolved.keyPath)) {
    throw new Error(`TLS key not found: ${resolved.keyPath}`);
  }

  return resolved;
}

export function readCertificateFingerprint(certPath: string): string {
  const certRaw = readFileSync(certPath);
  const cert = new X509Certificate(certRaw);
  const digest = createHash("sha256").update(cert.raw).digest("base64url");
  return `sha256:${digest}`;
}

export function readCertificateExpiryMs(certPath: string): number {
  const certRaw = readFileSync(certPath);
  const cert = new X509Certificate(certRaw);
  const expiresAt = Date.parse(cert.validTo);

  if (!Number.isFinite(expiresAt)) {
    throw new Error(`Unable to parse certificate expiry: ${cert.validTo}`);
  }

  return expiresAt;
}

function ensureSelfSignedMaterial(resolved: ResolvedTlsConfig, additionalHosts: string[]): void {
  if (!resolved.certPath || !resolved.keyPath || !resolved.caPath) {
    throw new Error("self-signed TLS mode requires certPath/keyPath/caPath");
  }

  const certPath = resolved.certPath;
  const keyPath = resolved.keyPath;
  const caPath = resolved.caPath;

  const caDir = dirname(caPath);
  const paths: SelfSignedPaths = {
    certPath,
    keyPath,
    caPath,
    caKeyPath: join(caDir, "ca.key"),
    serialPath: join(caDir, "ca.srl"),
  };

  const hasAllMaterial =
    existsSync(paths.certPath) && existsSync(paths.keyPath) && existsSync(paths.caPath);

  if (hasAllMaterial) {
    return;
  }

  ensureOpenSslAvailable();

  for (const dir of new Set([
    dirname(paths.certPath),
    dirname(paths.keyPath),
    dirname(paths.caPath),
  ])) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  // Ensure a clean regeneration if files are partially present.
  for (const path of [
    paths.certPath,
    paths.keyPath,
    paths.caPath,
    paths.caKeyPath,
    paths.serialPath,
  ]) {
    if (existsSync(path)) {
      rmSync(path, { force: true });
    }
  }

  const tempDir = mkdtempSync(join(dirname(paths.certPath), ".tls-build-"));
  const opensslConfigPath = join(tempDir, "openssl.cnf");
  const csrPath = join(tempDir, "server.csr");

  try {
    const sans = collectSubjectAltNames(additionalHosts);
    writeFileSync(opensslConfigPath, renderOpenSslConfig(sans), { mode: 0o600 });

    runOpenSsl(["genrsa", "-out", paths.caKeyPath, "2048"]);
    runOpenSsl([
      "req",
      "-x509",
      "-new",
      "-nodes",
      "-key",
      paths.caKeyPath,
      "-sha256",
      "-days",
      "3650",
      "-subj",
      "/CN=oppi-local-ca",
      "-out",
      paths.caPath,
    ]);

    runOpenSsl(["genrsa", "-out", paths.keyPath, "2048"]);
    runOpenSsl([
      "req",
      "-new",
      "-key",
      paths.keyPath,
      "-out",
      csrPath,
      "-config",
      opensslConfigPath,
    ]);

    runOpenSsl([
      "x509",
      "-req",
      "-in",
      csrPath,
      "-CA",
      paths.caPath,
      "-CAkey",
      paths.caKeyPath,
      "-CAcreateserial",
      "-out",
      paths.certPath,
      "-days",
      "825",
      "-sha256",
      "-extensions",
      "v3_req",
      "-extfile",
      opensslConfigPath,
    ]);

    chmodSync(paths.caKeyPath, 0o600);
    chmodSync(paths.keyPath, 0o600);
    chmodSync(paths.caPath, 0o644);
    chmodSync(paths.certPath, 0o644);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

function ensureTailscaleMaterial(resolved: ResolvedTlsConfig, additionalHosts: string[]): void {
  if (!resolved.certPath || !resolved.keyPath) {
    throw new Error("tailscale TLS mode requires certPath/keyPath");
  }

  const certHost = resolveTailscaleCertHostname(additionalHosts);
  if (!certHost) {
    throw new Error(
      "Could not determine Tailscale DNS hostname. Ensure Tailscale is connected and use a *.ts.net host.",
    );
  }

  for (const dir of new Set([dirname(resolved.certPath), dirname(resolved.keyPath)])) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  runTailscale([
    "cert",
    "--cert-file",
    resolved.certPath,
    "--key-file",
    resolved.keyPath,
    "--min-validity",
    TAILSCALE_MIN_VALIDITY,
    certHost,
  ]);

  chmodSync(resolved.keyPath, 0o600);
  chmodSync(resolved.certPath, 0o644);
}

function resolveTailscaleCertHostname(additionalHosts: string[]): string | null {
  for (const host of additionalHosts) {
    const normalized = normalizeHostForSan(host);
    if (normalized && isTailnetDnsName(normalized)) {
      return normalized;
    }
  }

  return detectTailscaleHostname();
}

function detectTailscaleHostname(): string | null {
  try {
    const output = execFileSync("tailscale", ["status", "--json"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10_000,
    });

    const parsed = JSON.parse(output) as TailscaleStatus;
    const dnsName = typeof parsed.Self?.DNSName === "string" ? parsed.Self.DNSName : "";
    const normalized = dnsName.trim().replace(/\.$/, "").toLowerCase();

    if (!normalized || !isTailnetDnsName(normalized)) {
      return null;
    }

    return normalized;
  } catch {
    return null;
  }
}

function runTailscale(args: string[]): void {
  try {
    execFileSync("tailscale", args, {
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 45_000,
    });
  } catch (err: unknown) {
    const stderr =
      typeof err === "object" && err !== null && "stderr" in err
        ? String((err as { stderr?: Buffer | string }).stderr ?? "")
        : "";

    const stdout =
      typeof err === "object" && err !== null && "stdout" in err
        ? String((err as { stdout?: Buffer | string }).stdout ?? "")
        : "";

    const detail =
      stderr.trim() || stdout.trim() || (err instanceof Error ? err.message : String(err));
    throw new Error(`tailscale ${args.join(" ")} failed: ${detail}`);
  }
}

function ensureOpenSslAvailable(): void {
  try {
    execFileSync("openssl", ["version"], {
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 5000,
    });
  } catch {
    throw new Error(
      "OpenSSL is required for tls.mode=self-signed but was not found on PATH. Install openssl or use tls.mode=manual.",
    );
  }
}

function runOpenSsl(args: string[]): void {
  try {
    execFileSync("openssl", args, {
      stdio: ["ignore", "ignore", "pipe"],
      timeout: 30_000,
    });
  } catch (err: unknown) {
    const stderr =
      typeof err === "object" && err !== null && "stderr" in err
        ? String((err as { stderr?: Buffer | string }).stderr ?? "")
        : "";
    const message = stderr.trim() || (err instanceof Error ? err.message : String(err));
    throw new Error(`openssl ${args.join(" ")} failed: ${message}`);
  }
}

/** Exported for testing. */
export function collectSubjectAltNames(additionalHosts: string[]): {
  dns: string[];
  ips: string[];
} {
  const dns = new Set<string>(["localhost"]);
  const ips = new Set<string>(["127.0.0.1", "::1"]);

  for (const interfaces of Object.values(networkInterfaces())) {
    if (!interfaces) continue;
    for (const entry of interfaces) {
      if (entry.internal) continue;
      const normalized = entry.address.split("%")[0];
      if (!normalized) continue;
      if (isIP(normalized)) {
        ips.add(normalized);
      }
    }
  }

  for (const host of additionalHosts) {
    const normalized = normalizeHostForSan(host);
    if (!normalized || WILDCARD_BIND_HOSTS.has(normalized)) continue;

    if (isIP(normalized)) {
      ips.add(normalized);
    } else {
      dns.add(normalized);
    }
  }

  return {
    dns: Array.from(dns),
    ips: Array.from(ips),
  };
}

/** Exported for testing. */
export function normalizeHostForSan(host: string): string {
  const trimmed = host.trim().toLowerCase();
  if (!trimmed) return "";

  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    return trimmed.slice(1, -1);
  }

  return trimmed;
}

/** Exported for testing. */
export function renderOpenSslConfig(sans: { dns: string[]; ips: string[] }): string {
  const commonName = sans.dns[0] ?? sans.ips[0] ?? "localhost";

  const altNames: string[] = [];
  sans.dns.forEach((value, index) => altNames.push(`DNS.${index + 1} = ${value}`));
  sans.ips.forEach((value, index) => altNames.push(`IP.${index + 1} = ${value}`));

  return [
    "[ req ]",
    "default_bits = 2048",
    "prompt = no",
    "default_md = sha256",
    "distinguished_name = dn",
    "req_extensions = v3_req",
    "",
    "[ dn ]",
    `CN = ${commonName}`,
    "",
    "[ v3_req ]",
    "keyUsage = critical, digitalSignature, keyEncipherment",
    "extendedKeyUsage = serverAuth",
    "subjectAltName = @alt_names",
    "",
    "[ alt_names ]",
    ...altNames,
    "",
  ].join("\n");
}

import { execFileSync } from "node:child_process";
import { createHash, randomUUID, X509Certificate } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { isIP } from "node:net";
import { homedir, networkInterfaces } from "node:os";
import { dirname, join } from "node:path";
import { createSecureContext } from "node:tls";
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

export class TailscaleRemoteUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TailscaleRemoteUnavailableError";
  }
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
const TAILSCALE_RENEW_LOCK_WAIT_MS = 120_000;
// Longer than the bounded 10s status probe + 45s certificate command. Age
// therefore fences PID reuse without reclaiming a legitimate renewal.
const TAILSCALE_STALE_LOCK_MS = 90_000;
const TAILSCALE_LOCK_POLL_MS = 25;

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
  if (host.length > 253 || !/^[a-z0-9.-]+$/.test(host)) {
    return false;
  }

  const labels = host.split(".");
  if (
    labels.some(
      (label) =>
        label.length === 0 || label.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label),
    )
  ) {
    return false;
  }

  return TAILNET_SUFFIXES.some((suffix) => host.endsWith(suffix) && host.length > suffix.length);
}

export function isTailscaleHostname(host: string): boolean {
  const normalized = normalizeHostForSan(host);
  return normalized.length > 0 && isTailnetDnsName(normalized);
}

export function tlsSchemeForConfig(config: ServerConfig): "http" | "https" {
  const mode = config.tls?.mode ?? "disabled";
  return mode === "disabled" ? "http" : "https";
}

export function resolveTlsConfig(
  config: Pick<ServerConfig, "tls">,
  dataDir: string,
): ResolvedTlsConfig {
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
  config: Pick<ServerConfig, "tls">,
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
    ensureTailscaleMaterial(resolved, options.additionalHosts ?? [], dataDir);
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

export function certificateMatchesHost(certPath: string, host: string): boolean {
  const normalizedHost = normalizeHostForSan(host);
  if (!normalizedHost) {
    return false;
  }

  const certRaw = readFileSync(certPath);
  const cert = new X509Certificate(certRaw);

  if (isIP(normalizedHost)) {
    return cert.checkIP(normalizedHost) !== undefined;
  }

  return cert.checkHost(normalizedHost, { subject: "never" }) !== undefined;
}

/**
 * Returns an exact Tailnet DNS SAN from a currently valid leaf certificate.
 * The certificate subject/CN is intentionally ignored: local clients use this
 * name as the verified TLS identity while dialing the configured local bind
 * address separately.
 */
export function readValidTailnetDnsName(
  certPath: string,
  preferredHost?: string,
  nowMs = Date.now(),
): string {
  if (!existsSync(certPath)) {
    throw new Error(`Tailscale TLS certificate not found: ${certPath}`);
  }

  let cert: X509Certificate;
  try {
    cert = new X509Certificate(readFileSync(certPath));
  } catch {
    throw new Error(`Tailscale TLS certificate is malformed: ${certPath}`);
  }

  const validFrom = Date.parse(cert.validFrom);
  if (!Number.isFinite(validFrom)) {
    throw new Error(`Tailscale TLS certificate has an invalid start date: ${certPath}`);
  }
  if (validFrom > nowMs) {
    throw new Error(`Tailscale TLS certificate is not yet valid: ${certPath}`);
  }

  const expiresAt = Date.parse(cert.validTo);
  if (!Number.isFinite(expiresAt)) {
    throw new Error(`Tailscale TLS certificate has an invalid expiry: ${certPath}`);
  }
  if (expiresAt <= nowMs) {
    throw new Error(`Tailscale TLS certificate is expired: ${certPath}`);
  }

  const tailnetNames = readDnsSubjectAltNames(cert.subjectAltName).filter(
    (name) => isTailnetDnsName(name) && cert.checkHost(name, { subject: "never" }) === name,
  );
  if (tailnetNames.length === 0) {
    throw new Error(
      `Tailscale TLS certificate has no valid Tailnet DNS SAN (*.ts.net or *.beta.tailscale.net): ${certPath}`,
    );
  }

  if (preferredHost !== undefined) {
    const normalizedPreferredHost = normalizeHostForSan(preferredHost);
    if (
      !isTailnetDnsName(normalizedPreferredHost) ||
      !tailnetNames.includes(normalizedPreferredHost)
    ) {
      throw new Error(
        `Tailscale TLS certificate does not cover ${preferredHost} with a Tailnet DNS SAN: ${certPath}`,
      );
    }
    return normalizedPreferredHost;
  }

  const selectedName = tailnetNames[0];
  if (!selectedName) {
    throw new Error(`Tailscale TLS certificate has no selectable Tailnet DNS SAN: ${certPath}`);
  }
  return selectedName;
}

function readDnsSubjectAltNames(subjectAltName: string | undefined): string[] {
  if (!subjectAltName) {
    return [];
  }

  const names: string[] = [];
  const dnsEntry = /(?:^|,\s*)DNS:([a-zA-Z0-9.-]+)(?=,\s*|$)/g;
  for (const match of subjectAltName.matchAll(dnsEntry)) {
    const normalized = normalizeHostForSan(match[1] ?? "");
    if (normalized) {
      names.push(normalized);
    }
  }
  return names;
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

function ensureTailscaleMaterial(
  resolved: ResolvedTlsConfig,
  additionalHosts: string[],
  dataDir: string,
): void {
  if (!resolved.certPath || !resolved.keyPath) {
    throw new Error("tailscale TLS mode requires certPath/keyPath");
  }

  for (const dir of new Set([dirname(resolved.certPath), dirname(resolved.keyPath)])) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }

  withTailscaleRenewalLock(tailscaleRenewalLockDir(dataDir, resolved), () => {
    recoverInterruptedTailscalePromotion(resolved);

    const requestedHost = resolveRequestedTailnetHostname(additionalHosts);
    const liveHost = detectTailscaleHostname();

    if (liveHost) {
      const renewalHost = requestedHost ?? liveHost;
      try {
        renewTailscaleMaterial(resolved, renewalHost);
        return;
      } catch (renewalError: unknown) {
        try {
          validateTailscaleMaterial(resolved, requestedHost ?? undefined);
          return;
        } catch (existingError: unknown) {
          throw new TailscaleRemoteUnavailableError(
            `Unable to renew Tailscale TLS material and no usable existing certificate remains. ` +
              `Renewal error: ${errorMessage(renewalError)}. Existing material: ${errorMessage(existingError)}`,
          );
        }
      }
    }

    try {
      validateTailscaleMaterial(resolved, requestedHost ?? undefined);
    } catch (error: unknown) {
      throw new TailscaleRemoteUnavailableError(
        `Tailscale is unavailable and existing TLS material is unusable: ${errorMessage(error)}. ` +
          "Start Tailscale to obtain or renew the certificate.",
      );
    }
  });
}

function renewTailscaleMaterial(resolved: ResolvedTlsConfig, certHost: string): void {
  if (!resolved.certPath || !resolved.keyPath) {
    throw new Error("tailscale TLS mode requires certPath/keyPath");
  }
  const certPath = resolved.certPath;
  const keyPath = resolved.keyPath;
  const certTempDir = mkdtempSync(join(dirname(certPath), ".tailscale-cert-"));
  const keyTempDir =
    dirname(keyPath) === dirname(certPath)
      ? certTempDir
      : mkdtempSync(join(dirname(keyPath), ".tailscale-key-"));
  const tempCertPath = join(certTempDir, "server.crt");
  const tempKeyPath = join(keyTempDir, "server.key");

  try {
    runTailscale([
      "cert",
      "--cert-file",
      tempCertPath,
      "--key-file",
      tempKeyPath,
      "--min-validity",
      TAILSCALE_MIN_VALIDITY,
      certHost,
    ]);

    validateTailscaleMaterial(
      { ...resolved, certPath: tempCertPath, keyPath: tempKeyPath },
      certHost,
    );
    promoteTailscaleMaterial(resolved, tempCertPath, tempKeyPath, certHost);
  } finally {
    rmSync(certTempDir, { recursive: true, force: true });
    if (keyTempDir !== certTempDir) {
      rmSync(keyTempDir, { recursive: true, force: true });
    }
  }
}

/**
 * Install one staged certificate/key generation while retaining the previous
 * pair until the final destination has been validated. The optional rename
 * function keeps the failure boundary deterministic in tests.
 */
export function promoteTailscaleMaterial(
  resolved: ResolvedTlsConfig,
  stagedCertPath: string,
  stagedKeyPath: string,
  preferredHost: string,
  renameFile: typeof renameSync = renameSync,
  removeBackup: (path: string) => void = (path) => rmSync(path, { force: true }),
): void {
  if (!resolved.certPath || !resolved.keyPath) {
    throw new Error("tailscale TLS mode requires certPath/keyPath");
  }
  const certPath = resolved.certPath;
  const keyPath = resolved.keyPath;
  const certBackupPath = tailscaleBackupPath(certPath);
  const keyBackupPath = tailscaleBackupPath(keyPath);
  let certBackedUp = false;
  let keyBackedUp = false;

  recoverInterruptedTailscalePromotion(resolved, preferredHost);
  const hadCert = existsSync(certPath);
  const hadKey = existsSync(keyPath);

  try {
    if (hadCert) {
      renameFile(certPath, certBackupPath);
      certBackedUp = true;
    }
    if (hadKey) {
      renameFile(keyPath, keyBackupPath);
      keyBackedUp = true;
    }

    renameFile(stagedCertPath, certPath);
    renameFile(stagedKeyPath, keyPath);
    chmodSync(keyPath, 0o600);
    chmodSync(certPath, 0o644);
    validateTailscaleMaterial(resolved, preferredHost);
  } catch (promotionError: unknown) {
    const rollbackErrors: string[] = [];
    try {
      if (certBackedUp || !hadCert) rmSync(certPath, { force: true });
    } catch (error: unknown) {
      rollbackErrors.push(`new certificate removal failed: ${errorMessage(error)}`);
    }
    try {
      if (keyBackedUp || !hadKey) rmSync(keyPath, { force: true });
    } catch (error: unknown) {
      rollbackErrors.push(`new private-key removal failed: ${errorMessage(error)}`);
    }

    try {
      if (certBackedUp) renameFile(certBackupPath, certPath);
    } catch (error: unknown) {
      rollbackErrors.push(`certificate restore failed: ${errorMessage(error)}`);
    }
    try {
      if (keyBackedUp) renameFile(keyBackupPath, keyPath);
    } catch (error: unknown) {
      rollbackErrors.push(`private-key restore failed: ${errorMessage(error)}`);
    }

    if (rollbackErrors.length === 0 && hadCert && hadKey) {
      try {
        validateTailscaleMaterial(resolved);
      } catch (error: unknown) {
        rollbackErrors.push(`restored generation is invalid: ${errorMessage(error)}`);
      }
    }

    const rollbackDetail =
      rollbackErrors.length === 0
        ? "The previous certificate/key generation was restored."
        : `Rollback errors: ${rollbackErrors.join("; ")}`;
    throw new Error(
      `Failed to promote Tailscale TLS material: ${errorMessage(promotionError)}. ${rollbackDetail}`,
    );
  }

  const cleanupErrors: string[] = [];
  for (const backupPath of [certBackupPath, keyBackupPath]) {
    try {
      removeBackup(backupPath);
    } catch (error: unknown) {
      cleanupErrors.push(errorMessage(error));
    }
  }
  if (cleanupErrors.length > 0) {
    throw new Error(
      `Tailscale TLS backup cleanup failure: ${cleanupErrors.join("; ")}. ` +
        "The committed live pair remains valid.",
    );
  }
}

/**
 * Side-effect-free local consistency validation. This checks the full leaf
 * validity interval, Tailnet DNS SAN, parseability, and cert/key match. It does
 * not establish certificate provenance or validate a public trust chain;
 * HTTPS clients retain normal trust verification for that boundary.
 */
export function validateTailscaleMaterial(
  resolved: ResolvedTlsConfig,
  preferredHost?: string,
): string {
  if (!resolved.certPath || !resolved.keyPath) {
    throw new Error("tailscale TLS mode requires certPath/keyPath");
  }
  const certPath = resolved.certPath;
  const keyPath = resolved.keyPath;
  const certHost = readValidTailnetDnsName(certPath, preferredHost);

  if (!existsSync(keyPath)) {
    throw new Error(`Tailscale TLS private key not found: ${keyPath}`);
  }

  try {
    createSecureContext({ cert: readFileSync(certPath), key: readFileSync(keyPath) });
  } catch {
    throw new Error(`Tailscale TLS certificate/key material is malformed or mismatched`);
  }

  return certHost;
}

function tailscaleBackupPath(path: string): string {
  return `${path}.oppi-renew-backup`;
}

function recoverInterruptedTailscalePromotion(
  resolved: ResolvedTlsConfig,
  preferredHost?: string,
): void {
  if (!resolved.certPath || !resolved.keyPath) return;
  const certBackupPath = tailscaleBackupPath(resolved.certPath);
  const keyBackupPath = tailscaleBackupPath(resolved.keyPath);
  const hasCertBackup = existsSync(certBackupPath);
  const hasKeyBackup = existsSync(keyBackupPath);
  if (!hasCertBackup && !hasKeyBackup) return;

  let livePairValid = false;
  try {
    validateTailscaleMaterial(resolved, preferredHost);
    livePairValid = true;
  } catch {
    // The live destination is partial or mismatched; restore available backups.
  }

  if (livePairValid) {
    try {
      chmodSync(resolved.keyPath, 0o600);
      chmodSync(resolved.certPath, 0o644);
    } catch {
      // A permission cleanup error must not replace a validated live pair.
    }
    for (const backupPath of [certBackupPath, keyBackupPath]) {
      try {
        rmSync(backupPath, { force: true });
      } catch {
        // Backup cleanup is best-effort after the live generation validates.
      }
    }
    return;
  }

  if (hasCertBackup) {
    rmSync(resolved.certPath, { force: true });
    renameSync(certBackupPath, resolved.certPath);
  }
  if (hasKeyBackup) {
    rmSync(resolved.keyPath, { force: true });
    renameSync(keyBackupPath, resolved.keyPath);
  }
}

type TailscaleRenewalTicket = {
  token: string;
  path: string;
  pid: number;
  createdAtMs: number;
  state?: { choosing: boolean; number: number; active: boolean; updatedAtMs: number };
};

function tailscaleRenewalLockDir(dataDir: string, resolved: ResolvedTlsConfig): string {
  const identity = `${resolved.certPath ?? ""}\0${resolved.keyPath ?? ""}`;
  const digest = createHash("sha256").update(identity).digest("hex").slice(0, 24);
  return join(dataDir, "tls", "locks", `tailscale-${digest}`);
}

function withTailscaleRenewalLock<T>(lockDir: string, operation: () => T): T {
  mkdirSync(lockDir, { recursive: true, mode: 0o700 });

  // This is Lamport's bakery lock over unique ticket directories. State file
  // replacement is atomic, and release/reclamation removes only one
  // never-reused ticket path. No read-then-unlink of shared ownership exists.
  const token = `${Date.now()}-${process.pid}-${randomUUID()}`;
  const ticketPath = join(lockDir, `${token}.ticket`);
  mkdirSync(ticketPath, { mode: 0o700 });
  const deadline = Date.now() + TAILSCALE_RENEW_LOCK_WAIT_MS;

  try {
    writeTailscaleTicketState(ticketPath, { choosing: true, number: 0, active: false });
    removeStaleTailscaleTickets(lockDir, token);
    const nextNumber =
      1 +
      Math.max(
        0,
        ...readTailscaleRenewalTickets(lockDir).map((ticket) => ticket.state?.number ?? 0),
      );
    writeTailscaleTicketState(ticketPath, {
      choosing: false,
      number: nextNumber,
      active: false,
    });

    while (Date.now() < deadline) {
      removeStaleTailscaleTickets(lockDir, token);
      const blocked = readTailscaleRenewalTickets(lockDir).some((ticket) => {
        if (ticket.token === token) return false;
        if (!ticket.state || ticket.state.choosing) return true;
        if (ticket.state.number <= 0) return false;
        return (
          ticket.state.number < nextNumber ||
          (ticket.state.number === nextNumber && ticket.token.localeCompare(token) < 0)
        );
      });
      if (!blocked) {
        // Reset stale age at critical-section acquisition. A long queue cannot
        // consume the active owner's bounded 90-second lease.
        writeTailscaleTicketState(ticketPath, {
          choosing: false,
          number: nextNumber,
          active: true,
        });
        return operation();
      }
      sleepSync(TAILSCALE_LOCK_POLL_MS);
    }

    throw new Error(`Timed out waiting for Tailscale TLS renewal lock: ${lockDir}`);
  } finally {
    // Empty or fully initialized tickets are both ownership-safe: this path is
    // unique to this attempt and can never name a successor.
    rmSync(ticketPath, { recursive: true, force: true });
  }
}

function writeTailscaleTicketState(
  ticketPath: string,
  state: { choosing: boolean; number: number; active: boolean },
): void {
  const statePath = join(ticketPath, "state.json");
  const tempPath = join(ticketPath, `.state-${randomUUID()}.tmp`);
  try {
    writeFileSync(tempPath, JSON.stringify(state), { mode: 0o600 });
    renameSync(tempPath, statePath);
  } finally {
    rmSync(tempPath, { force: true });
  }
}

function readTailscaleRenewalTickets(lockDir: string): TailscaleRenewalTicket[] {
  const tickets: TailscaleRenewalTicket[] = [];
  for (const entry of readdirSync(lockDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const match = /^(\d+)-(\d+)-([0-9a-f-]+)\.ticket$/.exec(entry.name);
    if (!match) continue;
    const pid = Number(match[2]);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    const path = join(lockDir, entry.name);
    try {
      tickets.push({
        token: entry.name.slice(0, -".ticket".length),
        path,
        pid,
        createdAtMs: statSync(path).mtimeMs,
        state: readTailscaleTicketState(path),
      });
    } catch {
      // A concurrent owner may have released its unique ticket.
    }
  }
  return tickets;
}

function readTailscaleTicketState(
  ticketPath: string,
): { choosing: boolean; number: number; active: boolean; updatedAtMs: number } | undefined {
  try {
    const statePath = join(ticketPath, "state.json");
    const parsed = JSON.parse(readFileSync(statePath, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object") return undefined;
    const choosing = (parsed as { choosing?: unknown }).choosing;
    const number = (parsed as { number?: unknown }).number;
    const active = (parsed as { active?: unknown }).active;
    if (
      typeof choosing !== "boolean" ||
      !Number.isInteger(number) ||
      Number(number) < 0 ||
      typeof active !== "boolean"
    ) {
      return undefined;
    }
    return {
      choosing,
      number: Number(number),
      active,
      updatedAtMs: statSync(statePath).mtimeMs,
    };
  } catch {
    return undefined;
  }
}

function removeStaleTailscaleTickets(lockDir: string, ownToken: string): void {
  const nowMs = Date.now();
  for (const ticket of readTailscaleRenewalTickets(lockDir)) {
    if (ticket.token === ownToken) continue;
    const staleSinceMs = ticket.state?.updatedAtMs ?? ticket.createdAtMs;
    const tooOld = nowMs - staleSinceMs >= TAILSCALE_STALE_LOCK_MS;
    if (!tooOld && isProcessRunning(ticket.pid)) continue;

    // Simultaneous claimants can remove the same stale ticket safely. The
    // unique path is never reused, so it cannot become a successor's lock.
    rmSync(ticket.path, { recursive: true, force: true });
  }
}

function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error: unknown) {
    return errorCode(error) !== "ESRCH";
  }
}

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function errorCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}

function resolveRequestedTailnetHostname(additionalHosts: string[]): string | null {
  for (const host of additionalHosts) {
    const normalized = normalizeHostForSan(host);
    if (normalized && isTailnetDnsName(normalized)) {
      return normalized;
    }
  }
  return null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
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

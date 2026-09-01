/**
 * Pure doctor checks for bind posture and Tailscale TLS mismatch.
 * cmdDoctor in cli.ts still owns I/O (files, launchd, certs).
 */

export type DoctorCheckLevel = "pass" | "warn" | "fail";
export type DoctorCheck = { level: DoctorCheckLevel; message: string };

const WILDCARD_BIND_HOSTS = new Set(["0.0.0.0", "::"]);

export function isWildcardBindHost(host: string): boolean {
  return WILDCARD_BIND_HOSTS.has(host.trim().toLowerCase());
}

/**
 * Listening on all interfaces is the npm/VPS footgun. Fail closed with a
 * one-line bind fix. Loopback binds are not this check.
 */
export function wildcardBindDoctorCheck(host: string): DoctorCheck | null {
  if (!isWildcardBindHost(host)) return null;
  return {
    level: "fail",
    message:
      `host=${host} binds all interfaces. Bind a Tailscale or LAN IP: ` +
      "oppi config set host <tailscale-ip-or-lan>",
  };
}

/**
 * MagicDNS (`*.ts.net`) plus self-signed is the wrong remote path.
 * The phone should use tls.mode=tailscale (`tailscale cert`).
 */
export function magicDnsSelfSignedDoctorCheck(
  tlsMode: string | undefined,
  tailscaleHostname: string | null,
): DoctorCheck | null {
  if (!tailscaleHostname) return null;
  if ((tlsMode ?? "disabled") !== "self-signed") return null;
  return {
    level: "warn",
    message:
      `Tailscale MagicDNS is present (${tailscaleHostname}) but tls.mode=self-signed. ` +
      "Use tls.mode=tailscale so the phone can use https://<machine>.ts.net:7749 with a real cert.",
  };
}

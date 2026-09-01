/**
 * Pure doctor checks for bind posture and Tailscale TLS mismatch.
 * cmdDoctor in cli.ts still owns I/O (files, launchd, certs).
 */

export type DoctorCheckLevel = "pass" | "warn" | "fail";
export type DoctorCheck = { level: DoctorCheckLevel; message: string };

/**
 * Node's listen() treats more than the literal "0.0.0.0" / "::" as
 * unspecified: "0", hex IPv4, "::0", the expanded IPv6 form, and
 * bracketed IPv6. Normalize through the URL hostname parser so doctor
 * fails closed on every spelling. Keep the original host in messages.
 */
export function isWildcardBindHost(host: string): boolean {
  const trimmed = host.trim();
  if (trimmed.length === 0) return false;
  const unbracketed =
    trimmed.startsWith("[") && trimmed.endsWith("]") ? trimmed.slice(1, -1) : trimmed;
  try {
    const parsed = new URL(
      `http://${unbracketed.includes(":") ? `[${unbracketed}]` : unbracketed}/`,
    );
    return (
      parsed.hostname === "0.0.0.0" ||
      parsed.hostname === "[::]" ||
      parsed.hostname === "[::ffff:0:0]"
    );
  } catch {
    return unbracketed === "::" || unbracketed === "::0";
  }
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

import { BlockList, isIP } from "node:net";

/** User-facing migration for the non-working tls.mode=cloudflare placeholder. */
export const CLOUDFLARE_TLS_MODE_MIGRATION =
  "tls.mode=cloudflare is not supported. Terminate TLS at your reverse proxy and set publicUrl plus proxy.trustedPeers. See docs/onboarding.md.";

export type ParsedPublicUrl = {
  /** Normalized https URL without a trailing slash. Port omitted when 443. */
  href: string;
  /** Hostname without brackets. */
  host: string;
  port: number;
  origin: string;
};

export type ParseResult<T> = { ok: true; value: T } | { ok: false; error: string };

export type RequestTrustConfig = {
  publicUrl?: ParsedPublicUrl;
  trustedPeers: readonly string[];
};

function formatHostForUrl(host: string): string {
  return isIP(host) === 6 ? `[${host}]` : host;
}

/**
 * Parse the phone-facing public origin.
 *
 * HTTPS only. Optional port defaults to 443. Rejects userinfo, query, fragment,
 * and any non-root path. Trailing `/` is normalized away.
 */
export function parsePublicUrl(raw: string): ParseResult<ParsedPublicUrl> {
  const trimmed = raw.trim();
  if (!trimmed) {
    return { ok: false, error: "expected non-empty https URL" };
  }

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return { ok: false, error: "expected a valid https URL" };
  }

  if (url.protocol !== "https:") {
    return { ok: false, error: "must use https" };
  }
  if (url.username || url.password) {
    return { ok: false, error: "must not include userinfo" };
  }
  if (url.search) {
    return { ok: false, error: "must not include a query string" };
  }
  if (url.hash) {
    return { ok: false, error: "must not include a fragment" };
  }
  if (url.pathname !== "/" && url.pathname !== "") {
    return {
      ok: false,
      error: "must not include a path (path-prefix deployment is not supported)",
    };
  }
  if (!url.hostname) {
    return { ok: false, error: "must include a host" };
  }

  const port = url.port ? Number(url.port) : 443;
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    return { ok: false, error: "port must be between 1 and 65535" };
  }

  const host = url.hostname;
  const href =
    port === 443
      ? `https://${formatHostForUrl(host)}`
      : `https://${formatHostForUrl(host)}:${port}`;
  return {
    ok: true,
    value: {
      href,
      host,
      port,
      origin: new URL(href).origin,
    },
  };
}

export function parseCidr(
  spec: string,
): ParseResult<{ ip: string; prefix: number; type: "ipv4" | "ipv6" }> {
  const trimmed = spec.trim();
  if (!trimmed) {
    return { ok: false, error: "expected IP or CIDR" };
  }

  const slash = trimmed.lastIndexOf("/");
  const ipRaw = slash === -1 ? trimmed : trimmed.slice(0, slash);
  const prefixRaw = slash === -1 ? undefined : trimmed.slice(slash + 1);
  const ip = normalizeIp(ipRaw);
  if (!ip) {
    return { ok: false, error: `invalid IP address: ${spec}` };
  }

  const type = isIP(ip) === 6 ? "ipv6" : "ipv4";
  const maxPrefix = type === "ipv6" ? 128 : 32;
  let prefix: number;
  if (prefixRaw === undefined) {
    prefix = maxPrefix;
  } else if (!/^\d+$/.test(prefixRaw)) {
    return { ok: false, error: `invalid CIDR prefix: ${spec}` };
  } else {
    prefix = Number(prefixRaw);
  }

  if (!Number.isInteger(prefix) || prefix < 0 || prefix > maxPrefix) {
    return { ok: false, error: `CIDR prefix out of range: ${spec}` };
  }
  if (prefix === 0) {
    return { ok: false, error: `refusing default-route CIDR: ${spec}` };
  }

  return { ok: true, value: { ip, prefix, type } };
}

export function parseTrustedPeers(raw: unknown): ParseResult<string[]> {
  if (!Array.isArray(raw)) {
    return { ok: false, error: "expected an array of IP/CIDR strings" };
  }
  if (raw.length === 0) {
    return { ok: false, error: "expected a non-empty IP/CIDR list" };
  }

  const peers: string[] = [];
  for (const entry of raw) {
    if (typeof entry !== "string") {
      return { ok: false, error: "each trusted peer must be an IP or CIDR string" };
    }
    const parsed = parseCidr(entry);
    if (!parsed.ok) return parsed;
    const canonical =
      parsed.value.prefix === (parsed.value.type === "ipv6" ? 128 : 32)
        ? parsed.value.ip
        : `${parsed.value.ip}/${parsed.value.prefix}`;
    peers.push(canonical);
  }
  return { ok: true, value: peers };
}

/** Strip IPv4-mapped IPv6 and zone IDs so CIDR checks see the address Oppi got. */
export function normalizeIp(address: string | undefined | null): string | null {
  if (!address) return null;
  let ip = address.trim();
  if (!ip) return null;
  const zone = ip.indexOf("%");
  if (zone !== -1) ip = ip.slice(0, zone);
  if (ip.startsWith("[") && ip.endsWith("]")) {
    ip = ip.slice(1, -1);
  }
  const mapped = ip.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i);
  if (mapped?.[1] && isIP(mapped[1]) === 4) {
    return mapped[1];
  }
  if (isIP(ip) === 0) return null;
  return ip;
}

export function ipMatchesCidrs(
  address: string | undefined | null,
  cidrs: readonly string[],
): boolean {
  const ip = normalizeIp(address);
  if (!ip || cidrs.length === 0) return false;

  const list = new BlockList();
  for (const spec of cidrs) {
    const parsed = parseCidr(spec);
    if (!parsed.ok) continue;
    list.addSubnet(parsed.value.ip, parsed.value.prefix, parsed.value.type);
  }

  const kind = isIP(ip);
  if (kind === 4) return list.check(ip, "ipv4");
  if (kind === 6) return list.check(ip, "ipv6");
  return false;
}

export function trustConfigFromServerConfig(config: {
  publicUrl?: string;
  proxy?: { trustedPeers?: string[] };
}): RequestTrustConfig {
  const trustedPeers = config.proxy?.trustedPeers ?? [];
  let publicUrl: ParsedPublicUrl | undefined;
  if (typeof config.publicUrl === "string") {
    const parsed = parsePublicUrl(config.publicUrl);
    if (parsed.ok) publicUrl = parsed.value;
  }
  return { publicUrl, trustedPeers };
}

/** Non-loopback plaintext bind is allowed when a public origin and trusted peers are set. */
export function allowsTrustedPrivateHttpBind(config: {
  publicUrl?: string;
  proxy?: { trustedPeers?: string[] };
}): boolean {
  const trust = trustConfigFromServerConfig(config);
  return Boolean(trust.publicUrl && trust.trustedPeers.length > 0);
}

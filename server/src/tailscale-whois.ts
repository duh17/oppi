/**
 * Same-user Tailscale proof for one-tap pairing.
 *
 * Identity is `tailscale whois --json <socket peer IP>` versus the server
 * node's own Tailscale login (status Self/User, or whois of a Self Tailscale
 * IP). Whois JSON uses `UserProfile.LoginName` (not `User.LoginName`). Tagged
 * nodes and the synthetic `tagged-devices` profile are never a human login.
 * The socket peer must also differ from status Self by node ID and Tailscale IP.
 * CGNAT ranges are never treated as proof.
 *
 * `tailscale` runs off the request thread. Callers must take admission before
 * spawn so a hung CLI cannot stall Unix/live traffic or fork unbounded
 * processes.
 */

import { execFile } from "node:child_process";
import { isIP } from "node:net";

import { ipMatchesCidrs, normalizeIp } from "./proxy-config.js";
import { isTailscaleHostname } from "./tls.js";
import type { TlsMode } from "./types.js";

const TAILSCALE_TIMEOUT_MS = 10_000;
const TAILSCALE_MAX_BUFFER_BYTES = 1024 * 1024;

/** Synthetic login Tailscale assigns to tagged nodes. */
const TAGGED_DEVICES_LOGIN = "tagged-devices";

export type TailscaleWhoisProof =
  | {
      ok: true;
      login: string;
      dnsName: string | null;
      tailscaleIPv4: string | null;
    }
  | { ok: false; status: 403 | 503; reason: string };

export type TailscaleSelfIdentity = {
  login: string | null;
  dnsName: string | null;
  tailscaleIPv4: string | null;
  stableNodeId: string | null;
  tailscaleIPs: string[];
  tagged: boolean;
};

export type WhoisIdentityParse =
  | { ok: true; login: string; stableNodeId: string | null }
  | { ok: false; reason: "invalid" | "tagged" };

export function parseWhoisIdentity(json: string): WhoisIdentityParse {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json) as unknown;
  } catch {
    return { ok: false, reason: "invalid" };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, reason: "invalid" };
  }
  const root = parsed as { Node?: unknown; UserProfile?: unknown };
  if (nodeIsTagged(root.Node)) {
    return { ok: false, reason: "tagged" };
  }
  const login = loginNameFromUserProfile(root.UserProfile);
  if (!login) {
    return { ok: false, reason: "invalid" };
  }
  if (loginIsTagged(login)) {
    return { ok: false, reason: "tagged" };
  }
  const node = root.Node as { StableID?: unknown } | undefined;
  return { ok: true, login, stableNodeId: stableNodeId(node?.StableID) };
}

/** Login from authentic whois JSON, or null when missing/tagged/invalid. */
export function parseWhoisLogin(json: string): string | null {
  const parsed = parseWhoisIdentity(json);
  return parsed.ok ? parsed.login : null;
}

export function parseStatusSelf(json: string): TailscaleSelfIdentity {
  const empty: TailscaleSelfIdentity = {
    login: null,
    dnsName: null,
    tailscaleIPv4: null,
    stableNodeId: null,
    tailscaleIPs: [],
    tagged: false,
  };
  let parsed: unknown;
  try {
    parsed = JSON.parse(json) as unknown;
  } catch {
    return empty;
  }
  if (!parsed || typeof parsed !== "object") return empty;
  const root = parsed as {
    Self?: {
      DNSName?: unknown;
      ID?: unknown;
      UserID?: unknown;
      TailscaleIPs?: unknown;
      Tags?: unknown;
    };
    User?: unknown;
    TailscaleIPs?: unknown;
  };
  const dnsName = normalizeDnsName(root.Self?.DNSName);
  const tailscaleIPs = Array.isArray(root.Self?.TailscaleIPs)
    ? root.Self.TailscaleIPs.flatMap((ip) => {
        const normalized = typeof ip === "string" ? normalizeIp(ip) : null;
        return normalized ? [normalized] : [];
      })
    : [];
  const tailscaleIPv4 =
    firstIPv4(root.Self?.TailscaleIPs) ?? firstIPv4(root.TailscaleIPs);
  const selfStableId = stableNodeId(root.Self?.ID);
  if (nodeIsTagged(root.Self)) {
    return { login: null, dnsName, tailscaleIPv4, stableNodeId: selfStableId, tailscaleIPs, tagged: true };
  }
  const userId = root.Self?.UserID;
  const login = loginFromStatusUsers(root.User, userId);
  if (login && loginIsTagged(login)) {
    return { login: null, dnsName, tailscaleIPv4, stableNodeId: selfStableId, tailscaleIPs, tagged: true };
  }
  return { login, dnsName, tailscaleIPv4, stableNodeId: selfStableId, tailscaleIPs, tagged: false };
}

export function loginsMatch(left: string, right: string): boolean {
  return left.trim().toLowerCase() === right.trim().toLowerCase();
}

/**
 * Same-user pairing advertises only MagicDNS names that SOCKS `matchDomains`
 * can route (`tls.mode=tailscale` public-CA hosts). Tailscale IPs are not an
 * invite host: the embedded node proxy does not match raw IPs.
 */
export function inviteHostForTlsMode(
  mode: TlsMode | undefined,
  identity: Pick<TailscaleSelfIdentity, "dnsName">,
): string | null {
  if (mode !== "tailscale") return null;
  const dnsName = identity.dnsName;
  if (dnsName && isTailscaleHostname(dnsName)) return dnsName;
  return null;
}

export async function proveSameTailscaleUser(peerIp: string): Promise<TailscaleWhoisProof> {
  const status = await runTailscale(["status", "--json"]);
  if (!status.ok) {
    return { ok: false, status: 503, reason: status.reason };
  }
  const self = parseStatusSelf(status.stdout);
  if (self.tagged) {
    return { ok: false, status: 403, reason: "Tagged Tailscale identity" };
  }
  if (ipMatchesCidrs(peerIp, self.tailscaleIPs)) {
    return { ok: false, status: 403, reason: "Server Tailscale node is not a peer" };
  }
  let selfLogin = self.login;
  if (!selfLogin && self.tailscaleIPv4) {
    const selfWhois = await runTailscale(["whois", "--json", self.tailscaleIPv4]);
    if (!selfWhois.ok) {
      return { ok: false, status: 503, reason: selfWhois.reason };
    }
    const parsed = parseWhoisIdentity(selfWhois.stdout);
    if (!parsed.ok) {
      if (parsed.reason === "tagged") {
        return { ok: false, status: 403, reason: "Tagged Tailscale identity" };
      }
      selfLogin = null;
    } else {
      selfLogin = parsed.login;
    }
  }
  if (!selfLogin) {
    return { ok: false, status: 503, reason: "Tailscale login is unavailable" };
  }

  const peerWhois = await runTailscale(["whois", "--json", peerIp]);
  if (!peerWhois.ok) {
    return { ok: false, status: 403, reason: "Tailscale whois failed" };
  }
  const peer = parseWhoisIdentity(peerWhois.stdout);
  if (!peer.ok) {
    return {
      ok: false,
      status: 403,
      reason: peer.reason === "tagged" ? "Tagged Tailscale identity" : "Tailscale whois failed",
    };
  }
  if (!self.stableNodeId || !peer.stableNodeId) {
    return { ok: false, status: 403, reason: "Tailscale node identity is unavailable" };
  }
  if (peer.stableNodeId === self.stableNodeId) {
    return { ok: false, status: 403, reason: "Server Tailscale node is not a peer" };
  }
  if (!loginsMatch(selfLogin, peer.login)) {
    return { ok: false, status: 403, reason: "Different Tailscale user" };
  }
  return {
    ok: true,
    login: selfLogin,
    dnsName: self.dnsName,
    tailscaleIPv4: self.tailscaleIPv4,
  };
}

function runTailscale(
  args: string[],
): Promise<{ ok: true; stdout: string } | { ok: false; reason: string }> {
  return new Promise((resolve) => {
    execFile(
      "tailscale",
      args,
      {
        encoding: "utf-8",
        timeout: TAILSCALE_TIMEOUT_MS,
        maxBuffer: TAILSCALE_MAX_BUFFER_BYTES,
      },
      (error, stdout, stderr) => {
        if (!error) {
          resolve({ ok: true, stdout });
          return;
        }
        if (isMissingBinary(error)) {
          resolve({ ok: false, reason: "Tailscale is unavailable" });
          return;
        }
        const detail = tailscaleErrorDetail(error, stdout, stderr);
        resolve({ ok: false, reason: detail || "Tailscale is unavailable" });
      },
    );
  });
}

function tailscaleErrorDetail(error: unknown, stdout: string, stderr: string): string {
  const fromStdio = (stderr.trim() || stdout.trim()).slice(0, 200);
  if (fromStdio) return fromStdio;
  if (typeof error === "object" && error !== null) {
    const nestedStderr =
      "stderr" in error ? String((error as { stderr?: Buffer | string }).stderr ?? "") : "";
    const nestedStdout =
      "stdout" in error ? String((error as { stdout?: Buffer | string }).stdout ?? "") : "";
    const nested = (nestedStderr.trim() || nestedStdout.trim()).slice(0, 200);
    if (nested) return nested;
  }
  return (error instanceof Error ? error.message : String(error)).slice(0, 200);
}

function isMissingBinary(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const code = "code" in error ? (error as { code?: unknown }).code : undefined;
  return code === "ENOENT";
}

function loginNameFromUserProfile(profile: unknown): string | null {
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) return null;
  const login = (profile as { LoginName?: unknown }).LoginName;
  if (typeof login !== "string") return null;
  const trimmed = login.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function loginFromStatusUsers(users: unknown, userId: unknown): string | null {
  if (!users || typeof users !== "object" || Array.isArray(users) || userId == null) {
    return null;
  }
  const record = users as Record<string, { LoginName?: unknown } | undefined>;
  const direct = record[String(userId)];
  const login = direct?.LoginName;
  if (typeof login === "string" && login.trim()) return login.trim();
  return null;
}

function stableNodeId(id: unknown): string | null {
  if (typeof id !== "string") return null;
  const trimmed = id.trim();
  return trimmed || null;
}

function nodeIsTagged(node: unknown): boolean {
  if (!node || typeof node !== "object" || Array.isArray(node)) return false;
  const tags = (node as { Tags?: unknown }).Tags;
  if (!Array.isArray(tags) || tags.length === 0) return false;
  return tags.some((tag) => typeof tag === "string" && tag.trim().length > 0);
}

function loginIsTagged(login: string): boolean {
  return login.trim().toLowerCase() === TAGGED_DEVICES_LOGIN;
}

function normalizeDnsName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().replace(/\.$/, "").toLowerCase();
  return normalized.length > 0 ? normalized : null;
}

function firstIPv4(value: unknown): string | null {
  if (!Array.isArray(value)) return null;
  for (const entry of value) {
    if (typeof entry !== "string") continue;
    const ip = entry.trim();
    if (isIP(ip) === 4) return ip;
  }
  return null;
}

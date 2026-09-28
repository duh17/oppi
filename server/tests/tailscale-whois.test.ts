import { describe, expect, it } from "vitest";

import {
  inviteHostForTlsMode,
  loginsMatch,
  parseStatusSelf,
  parseWhoisIdentity,
  parseWhoisLogin,
} from "../src/tailscale-whois.js";

/** Trimmed `tailscale whois --json` for a human-owned node (`apitype.WhoIsResponse`). */
const humanWhois = `{
  "Node": {
    "ID": 1,
    "StableID": "nPhone1CNTRL",
    "Name": "iphone.tail1234.ts.net.",
    "User": 123,
    "Key": "nodekey:abc",
    "Addresses": ["100.90.1.2/32"],
    "AllowedIPs": ["100.90.1.2/32"],
    "Hostinfo": { "OS": "iOS", "Hostname": "iPhone" },
    "Online": true
  },
  "UserProfile": {
    "ID": 123,
    "LoginName": "chen@example.com",
    "DisplayName": "Chen"
  },
  "CapMap": {}
}`;

/** Tagged node: `Node.Tags` plus the synthetic `tagged-devices` profile. */
const taggedWhois = `{
  "Node": {
    "ID": 2,
    "StableID": "nCi1CNTRL",
    "Name": "ci.tail1234.ts.net.",
    "User": 1,
    "Tags": ["tag:ci"],
    "Addresses": ["100.64.0.9/32"],
    "AllowedIPs": ["100.64.0.9/32"],
    "Hostinfo": { "OS": "linux", "Hostname": "ci" },
    "Online": true
  },
  "UserProfile": {
    "ID": 1,
    "LoginName": "tagged-devices",
    "DisplayName": "tagged-devices"
  },
  "CapMap": {}
}`;

describe("tailscale whois proof helpers", () => {
  it("reads LoginName from UserProfile, not User", () => {
    expect(parseWhoisIdentity(humanWhois)).toEqual({ ok: true, login: "chen@example.com" });
    expect(parseWhoisLogin(humanWhois)).toBe("chen@example.com");
    expect(parseWhoisIdentity(`{"User":{"ID":1,"LoginName":"chen@example.com","DisplayName":"Chen"}}`)).toEqual(
      { ok: false, reason: "invalid" },
    );
    expect(parseWhoisLogin(`{"User":{"ID":1,"LoginName":"chen@example.com"}}`)).toBeNull();
    expect(parseWhoisLogin(`{"Node":{"Name":"phone"}}`)).toBeNull();
    expect(parseWhoisLogin("not-json")).toBeNull();
  });

  it("explicitly rejects tagged whois identities instead of a synthetic login", () => {
    expect(parseWhoisIdentity(taggedWhois)).toEqual({ ok: false, reason: "tagged" });
    expect(parseWhoisLogin(taggedWhois)).toBeNull();
    expect(
      parseWhoisIdentity(`{
        "Node": { "ID": 3, "Name": "bot.tail1234.ts.net.", "User": 1 },
        "UserProfile": { "ID": 1, "LoginName": "tagged-devices", "DisplayName": "tagged-devices" }
      }`),
    ).toEqual({ ok: false, reason: "tagged" });
  });

  it("reads self login, MagicDNS name, and IPv4 from status JSON", () => {
    const self = parseStatusSelf(`{
      "Self": {
        "DNSName": "mac-studio.tail1234.ts.net.",
        "UserID": 123,
        "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"]
      },
      "User": {"123": {"ID": 123, "LoginName": "chen@example.com"}}
    }`);
    expect(self).toEqual({
      login: "chen@example.com",
      dnsName: "mac-studio.tail1234.ts.net",
      tailscaleIPv4: "100.101.102.103",
      tagged: false,
    });
  });

  it("does not treat a tagged status Self as a human login", () => {
    const self = parseStatusSelf(`{
      "Self": {
        "DNSName": "ci.tail1234.ts.net.",
        "UserID": 1,
        "Tags": ["tag:ci"],
        "TailscaleIPs": ["100.64.0.9"]
      },
      "User": {"1": {"ID": 1, "LoginName": "tagged-devices", "DisplayName": "tagged-devices"}}
    }`);
    expect(self.login).toBeNull();
    expect(self.tagged).toBe(true);
    expect(self.dnsName).toBe("ci.tail1234.ts.net");
  });

  it("does not treat a CGNAT address as a Tailscale login", () => {
    expect(parseWhoisLogin(`{"Node":{"Addresses":["100.64.0.9/32"]}}`)).toBeNull();
    expect(parseStatusSelf(`{"Self":{"TailscaleIPs":["100.64.0.9"]}}`).login).toBeNull();
  });

  it("compares Tailscale logins case-insensitively", () => {
    expect(loginsMatch("Chen@example.com", "chen@example.com")).toBe(true);
    expect(loginsMatch("chen@example.com", "other@example.com")).toBe(false);
  });

  it("advertises MagicDNS only in tailscale TLS mode", () => {
    const identity = {
      dnsName: "mac-studio.tail1234.ts.net",
      tailscaleIPv4: "100.101.102.103",
    };
    expect(inviteHostForTlsMode("tailscale", identity)).toBe("mac-studio.tail1234.ts.net");
    expect(inviteHostForTlsMode("self-signed", identity)).toBeNull();
    expect(inviteHostForTlsMode("manual", identity)).toBeNull();
    expect(inviteHostForTlsMode("disabled", identity)).toBeNull();
    expect(inviteHostForTlsMode("tailscale", { dnsName: null })).toBeNull();
    expect(inviteHostForTlsMode("tailscale", { dnsName: "oppi.example.com" })).toBeNull();
  });
});

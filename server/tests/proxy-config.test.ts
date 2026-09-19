import { describe, expect, it } from "vitest";
import {
  allowsTrustedPrivateHttpBind,
  ipMatchesCidrs,
  normalizeIp,
  parseCidr,
  parsePublicUrl,
  parseTrustedPeers,
  trustConfigFromServerConfig,
} from "../src/proxy-config.js";

describe("parsePublicUrl", () => {
  it("accepts https and defaults port 443", () => {
    const parsed = parsePublicUrl("https://oppi.example.com");
    expect(parsed).toEqual({
      ok: true,
      value: {
        href: "https://oppi.example.com",
        host: "oppi.example.com",
        port: 443,
        origin: "https://oppi.example.com",
      },
    });
  });

  it("normalizes a trailing root slash", () => {
    const parsed = parsePublicUrl("https://oppi.example.com/");
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.value.href).toBe("https://oppi.example.com");
  });

  it("preserves a custom public port", () => {
    const parsed = parsePublicUrl("https://oppi.example.com:8443");
    expect(parsed.ok).toBe(true);
    if (parsed.ok) {
      expect(parsed.value.port).toBe(8443);
      expect(parsed.value.href).toBe("https://oppi.example.com:8443");
      expect(parsed.value.origin).toBe("https://oppi.example.com:8443");
    }
  });

  it("rejects http", () => {
    expect(parsePublicUrl("http://oppi.example.com").ok).toBe(false);
  });

  it("rejects userinfo", () => {
    const parsed = parsePublicUrl("https://user:pass@oppi.example.com");
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error).toContain("userinfo");
  });

  it("rejects query strings", () => {
    const parsed = parsePublicUrl("https://oppi.example.com?x=1");
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error).toContain("query");
  });

  it("rejects fragments", () => {
    const parsed = parsePublicUrl("https://oppi.example.com#x");
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error).toContain("fragment");
  });

  it("rejects non-root paths", () => {
    const parsed = parsePublicUrl("https://oppi.example.com/oppi");
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error).toContain("path");
  });
});

describe("parseTrustedPeers", () => {
  it("accepts IPs and CIDRs", () => {
    const parsed = parseTrustedPeers(["127.0.0.1", "::1/128", "10.0.10.0/24"]);
    expect(parsed).toEqual({
      ok: true,
      value: ["127.0.0.1", "::1", "10.0.10.0/24"],
    });
  });

  it("rejects an empty list", () => {
    const parsed = parseTrustedPeers([]);
    expect(parsed.ok).toBe(false);
  });

  it("rejects hostnames", () => {
    const parsed = parseTrustedPeers(["proxy.example.com"]);
    expect(parsed.ok).toBe(false);
  });

  it("rejects default-route CIDRs", () => {
    expect(parseCidr("0.0.0.0/0").ok).toBe(false);
    expect(parseCidr("::/0").ok).toBe(false);
  });
});

describe("ip matching", () => {
  it("normalizes IPv4-mapped IPv6", () => {
    expect(normalizeIp("::ffff:127.0.0.1")).toBe("127.0.0.1");
    expect(ipMatchesCidrs("::ffff:127.0.0.1", ["127.0.0.1/32"])).toBe(true);
  });

  it("does not treat a publicUrl as a trusted peer", () => {
    const trust = trustConfigFromServerConfig({
      publicUrl: "https://oppi.example.com",
    });
    expect(trust.trustedPeers).toEqual([]);
    expect(allowsTrustedPrivateHttpBind({ publicUrl: "https://oppi.example.com" })).toBe(false);
    expect(
      allowsTrustedPrivateHttpBind({
        publicUrl: "https://oppi.example.com",
        proxy: { trustedPeers: ["127.0.0.1/32"] },
      }),
    ).toBe(true);
  });
});

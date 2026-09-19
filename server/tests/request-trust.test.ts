import { Socket } from "node:net";
import type { IncomingMessage } from "node:http";
import { describe, expect, it } from "vitest";
import {
  isAllowedWebSocketOrigin,
  isSecureNetworkRequest,
  markLocalRequest,
  resolveRequestProvenance,
} from "../src/request-trust.js";
import { parsePublicUrl } from "../src/proxy-config.js";

function request(opts: {
  remoteAddress?: string;
  encrypted?: boolean;
  headers?: Record<string, string | string[]>;
  local?: boolean;
}): IncomingMessage {
  const socket = new Socket();
  Object.defineProperty(socket, "remoteAddress", {
    value: opts.remoteAddress ?? "127.0.0.1",
    configurable: true,
  });
  if (opts.encrypted) {
    (socket as Socket & { encrypted?: boolean }).encrypted = true;
  }
  const req = {
    headers: opts.headers ?? {},
    socket,
  } as IncomingMessage;
  if (opts.local) markLocalRequest(req);
  return req;
}

const publicUrl = (() => {
  const parsed = parsePublicUrl("https://oppi.example.com");
  if (!parsed.ok) throw new Error("fixture");
  return parsed.value;
})();

const trusted = { publicUrl, trustedPeers: ["127.0.0.1/32", "::1/128"] };

describe("request provenance", () => {
  it("requires socket TLS when no trusted peers are configured", () => {
    const plaintext = request({ encrypted: false, headers: { "x-forwarded-proto": "https" } });
    expect(isSecureNetworkRequest(plaintext)).toBe(false);
    expect(isSecureNetworkRequest(request({ encrypted: true }))).toBe(true);
  });

  it("uses overwritten XFF for rate-limit identity on TLS from a trusted peer", () => {
    const req = request({
      encrypted: true,
      headers: { "x-forwarded-for": "203.0.113.10" },
    });
    const provenance = resolveRequestProvenance(req, trusted);
    expect(provenance.isSecure).toBe(true);
    expect(provenance.socketEncrypted).toBe(true);
    expect(provenance.trustedPeer).toBe(true);
    expect(provenance.clientIdentity).toBe("xff:203.0.113.10");
  });

  it("does not take XFF identity without trusted peers even on TLS", () => {
    const req = request({
      encrypted: true,
      headers: { "x-forwarded-for": "203.0.113.10" },
    });
    const provenance = resolveRequestProvenance(req, { publicUrl, trustedPeers: [] });
    expect(provenance.isSecure).toBe(true);
    expect(provenance.trustedPeer).toBe(false);
    expect(provenance.clientIdentity).toBe("peer:127.0.0.1");
  });

  it("does not treat publicUrl alone as authorization for plaintext", () => {
    const req = request({
      headers: { "x-forwarded-proto": "https", "x-forwarded-for": "203.0.113.10" },
    });
    const provenance = resolveRequestProvenance(req, { publicUrl, trustedPeers: [] });
    expect(provenance.isSecure).toBe(false);
    expect(provenance.insecureReason).toBe("insecure");
  });

  it("accepts plaintext from a trusted peer with a single https assertion", () => {
    const req = request({
      headers: { "x-forwarded-proto": "https", "x-forwarded-for": "203.0.113.10" },
    });
    const provenance = resolveRequestProvenance(req, trusted);
    expect(provenance.isSecure).toBe(true);
    expect(provenance.trustedPeer).toBe(true);
    expect(provenance.clientIdentity).toBe("xff:203.0.113.10");
  });

  it("fails closed on missing, duplicate, or unsupported forwarded proto", () => {
    const peer = { headers: { "x-forwarded-for": "203.0.113.10" } };
    expect(resolveRequestProvenance(request(peer), trusted).isSecure).toBe(false);
    expect(
      resolveRequestProvenance(
        request({ ...peer, headers: { ...peer.headers, "x-forwarded-proto": "http" } }),
        trusted,
      ).insecureReason,
    ).toBe("unsupported_forwarded_proto");
    expect(
      resolveRequestProvenance(
        request({
          ...peer,
          headers: { ...peer.headers, "x-forwarded-proto": "https, https" },
        }),
        trusted,
      ).insecureReason,
    ).toBe("duplicate_forwarded_proto");
    expect(
      resolveRequestProvenance(
        request({
          ...peer,
          headers: { ...peer.headers, "x-forwarded-proto": ["https", "https"] },
        }),
        trusted,
      ).insecureReason,
    ).toBe("duplicate_forwarded_proto");
  });

  it("never uses a forwarded address to decide whether the sender is trusted", () => {
    const req = request({
      remoteAddress: "203.0.113.99",
      headers: {
        "x-forwarded-proto": "https",
        "x-forwarded-for": "127.0.0.1",
        host: "oppi.example.com",
      },
    });
    const provenance = resolveRequestProvenance(req, trusted);
    expect(provenance.trustedPeer).toBe(false);
    expect(provenance.isSecure).toBe(false);
    expect(provenance.clientIdentity).toBe("peer:203.0.113.99");
  });

  it("falls back to the socket peer when XFF is a chain or malformed", () => {
    const chained = request({
      headers: { "x-forwarded-proto": "https", "x-forwarded-for": "198.51.100.1, 203.0.113.10" },
    });
    expect(resolveRequestProvenance(chained, trusted).clientIdentity).toBe("peer:127.0.0.1");

    const bad = request({
      headers: { "x-forwarded-proto": "https", "x-forwarded-for": "not-an-ip" },
    });
    expect(resolveRequestProvenance(bad, trusted).clientIdentity).toBe("peer:127.0.0.1");
  });

  it("does not treat Unix-socket requests as secure network requests", () => {
    const req = request({ local: true, encrypted: true });
    expect(isSecureNetworkRequest(req, trusted)).toBe(false);
  });
});

describe("WebSocket Origin", () => {
  it("uses publicUrl as the origin authority, not Host", () => {
    const req = request({
      headers: {
        origin: "https://oppi.example.com",
        host: "127.0.0.1:7750",
      },
    });
    expect(isAllowedWebSocketOrigin(req, "http", trusted)).toBe(true);
    expect(
      isAllowedWebSocketOrigin(
        request({ headers: { origin: "https://evil.example", host: "oppi.example.com" } }),
        "http",
        trusted,
      ),
    ).toBe(false);
  });

  it("keeps Host comparison when publicUrl is unset", () => {
    const req = request({
      headers: { origin: "https://127.0.0.1:7749", host: "127.0.0.1:7749" },
    });
    expect(isAllowedWebSocketOrigin(req, "https")).toBe(true);
    expect(isAllowedWebSocketOrigin(req, "http")).toBe(false);
  });
});

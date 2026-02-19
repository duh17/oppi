import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import {
  buildClientAllowlist,
  isClientAllowed,
  normalizeRemoteAddress,
  formatStartupSecurityWarnings,
} from "../src/server.js";

describe("network allowlist", () => {
  it("normalizes IPv4-mapped IPv6 addresses", () => {
    expect(normalizeRemoteAddress("::ffff:192.168.1.10")).toEqual({
      ip: "192.168.1.10",
      family: "ipv4",
    });
  });

  it("allows private source addresses by default", () => {
    const cfg = Storage.getDefaultConfig("/tmp/oppi-server-network-default");
    const list = buildClientAllowlist(cfg.allowedCidrs);

    expect(isClientAllowed("127.0.0.1", list)).toBe(true);
    expect(isClientAllowed("::1", list)).toBe(true);
    expect(isClientAllowed("192.168.1.42", list)).toBe(true);
    expect(isClientAllowed("::ffff:10.0.0.5", list)).toBe(true);
  });

  it("denies public source addresses by default", () => {
    const cfg = Storage.getDefaultConfig("/tmp/oppi-server-network-public");
    const list = buildClientAllowlist(cfg.allowedCidrs);

    expect(isClientAllowed("8.8.8.8", list)).toBe(false);
    expect(isClientAllowed("1.1.1.1", list)).toBe(false);
  });

  it("emits startup warning for global CIDR", () => {
    const cfg = Storage.getDefaultConfig("/tmp/oppi-server-network-warn");
    cfg.allowedCidrs = ["0.0.0.0/0"];

    const warnings = formatStartupSecurityWarnings(cfg);
    expect(warnings.some((w) => w.includes("allowedCidrs contains a global range"))).toBe(true);
  });
});

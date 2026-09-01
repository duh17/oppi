import { describe, expect, it } from "vitest";

import {
  isWildcardBindHost,
  magicDnsSelfSignedDoctorCheck,
  wildcardBindDoctorCheck,
} from "../src/cli/doctor-checks.js";

describe("wildcard bind doctor check", () => {
  it("fails closed on 0.0.0.0 with a one-line bind fix", () => {
    const check = wildcardBindDoctorCheck("0.0.0.0");
    expect(check?.level).toBe("fail");
    expect(check?.message).toContain("host=0.0.0.0");
    expect(check?.message).toContain("oppi config set host <tailscale-ip-or-lan>");
  });

  it("fails closed on IPv6 wildcard bind", () => {
    const check = wildcardBindDoctorCheck("::");
    expect(check?.level).toBe("fail");
    expect(check?.message).toContain("host=::");
  });

  it("fails closed on every Node unspecified-address spelling", () => {
    const spellings = [
      "0",
      "0x00000000",
      "::0",
      "0:0:0:0:0:0:0:0",
      "[::]",
      "[::0]",
      "0.0.0",
      "::ffff:0.0.0.0",
    ];
    for (const host of spellings) {
      expect(isWildcardBindHost(host), host).toBe(true);
      const check = wildcardBindDoctorCheck(host);
      expect(check?.level, host).toBe("fail");
      expect(check?.message, host).toContain(`host=${host}`);
      expect(check?.message, host).toContain("oppi config set host <tailscale-ip-or-lan>");
    }
  });

  it("does not flag loopback or specific LAN/Tailscale binds", () => {
    expect(isWildcardBindHost("127.0.0.1")).toBe(false);
    expect(isWildcardBindHost("0x7f000001")).toBe(false);
    expect(wildcardBindDoctorCheck("127.0.0.1")).toBeNull();
    expect(wildcardBindDoctorCheck("100.64.1.20")).toBeNull();
    expect(wildcardBindDoctorCheck("192.168.1.44")).toBeNull();
    expect(wildcardBindDoctorCheck("::1")).toBeNull();
  });
});

describe("MagicDNS + self-signed doctor check", () => {
  const magicDns = "cos-1.taila3ebc.ts.net";

  it("warns when MagicDNS is present and tls.mode is self-signed", () => {
    const check = magicDnsSelfSignedDoctorCheck("self-signed", magicDns);
    expect(check?.level).toBe("warn");
    expect(check?.message).toContain(magicDns);
    expect(check?.message).toContain("tls.mode=self-signed");
    expect(check?.message).toContain("tls.mode=tailscale");
  });

  it("does not warn when tls.mode is tailscale", () => {
    expect(magicDnsSelfSignedDoctorCheck("tailscale", magicDns)).toBeNull();
  });

  it("does not warn when MagicDNS is absent", () => {
    expect(magicDnsSelfSignedDoctorCheck("self-signed", null)).toBeNull();
  });
});

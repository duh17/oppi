import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import { formatStartupSecurityWarnings } from "../src/server.js";

describe("startup security warnings", () => {
  it("warns when server binds to all interfaces", () => {
    const config = Storage.getDefaultConfig("/tmp/pi-remote-security-warnings-default");

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("host=0.0.0.0"))).toBe(true);
  });

  it("does not warn for strict loopback-only hardened posture", () => {
    const config = Storage.getDefaultConfig("/tmp/pi-remote-security-warnings-hardened");
    config.host = "127.0.0.1";
    config.security = {
      profile: "strict",
      requireTlsOutsideTailnet: true,
      allowInsecureHttpInTailnet: false,
      requirePinnedServerIdentity: true,
    };
    config.identity = {
      ...config.identity!,
      enabled: true,
    };
    config.invite = {
      ...config.invite!,
      maxAgeSeconds: 600,
    };

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings).toHaveLength(0);
  });

  it("warns when non-loopback bind allows plaintext outside tailnet", () => {
    const config = Storage.getDefaultConfig("/tmp/pi-remote-security-warnings-public");
    config.host = "192.168.1.20";
    config.security = {
      ...config.security!,
      requireTlsOutsideTailnet: false,
    };

    const warnings = formatStartupSecurityWarnings(config);

    expect(
      warnings.some((warning) =>
        warning.includes("security.requireTlsOutsideTailnet=false"),
      ),
    ).toBe(true);
  });

  it("warns on legacy profile and disabled trust pinning", () => {
    const config = Storage.getDefaultConfig("/tmp/pi-remote-security-warnings-legacy");
    config.host = "127.0.0.1";
    config.security = {
      ...config.security!,
      profile: "legacy",
      requirePinnedServerIdentity: false,
    };
    config.identity = {
      ...config.identity!,
      enabled: false,
    };

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("security.profile=legacy"))).toBe(true);
    expect(
      warnings.some((warning) => warning.includes("security.requirePinnedServerIdentity=false")),
    ).toBe(true);
    expect(warnings.some((warning) => warning.includes("identity.enabled=false"))).toBe(true);
  });

  it("warns when invite TTL is too long", () => {
    const config = Storage.getDefaultConfig("/tmp/pi-remote-security-warnings-ttl");
    config.host = "127.0.0.1";
    config.invite = {
      ...config.invite!,
      maxAgeSeconds: 7200,
    };

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("invite.maxAgeSeconds=7200"))).toBe(true);
  });
});

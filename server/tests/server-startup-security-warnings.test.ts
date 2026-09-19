import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import { formatStartupSecurityWarnings } from "../src/server.js";

describe("startup security warnings", () => {
  it("warns when server binds to all interfaces", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-default");

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("host=0.0.0.0"))).toBe(true);
  });

  it("warns when tls is disabled on non-loopback host", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-tls");
    config.host = "192.168.1.50";
    config.tls = { mode: "disabled" };

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("TLS is disabled"))).toBe(true);
  });

  it("has no warnings for loopback bind", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-loopback");
    config.host = "127.0.0.1";

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings).toHaveLength(0);
  });

  it("names trusted-proxy HTTP instead of the insecure escape hatch", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-proxy");
    config.host = "0.0.0.0";
    config.tls = { mode: "disabled" };
    config.publicUrl = "https://oppi.example.com";
    config.proxy = { trustedPeers: ["10.0.10.25/32"] };

    const warnings = formatStartupSecurityWarnings(config);
    const httpWarning = warnings.find((warning) => warning.includes("TLS is disabled"));

    expect(httpWarning).toContain("trusted-proxy HTTP");
    expect(httpWarning).not.toContain("allowInsecureNetworkHttp");
  });
});

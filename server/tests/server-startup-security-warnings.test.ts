import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import { formatStartupSecurityWarnings } from "../src/server.js";

describe("startup security warnings", () => {
  it("warns when server binds to all interfaces", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-default");

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("host=0.0.0.0"))).toBe(true);
  });

  it("warns when allowedCidrs include global ranges", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-global-cidr");
    config.allowedCidrs = ["0.0.0.0/0"];

    const warnings = formatStartupSecurityWarnings(config);

    expect(
      warnings.some((warning) => warning.includes("allowedCidrs contains a global range")),
    ).toBe(true);
  });

  it("has no warnings for loopback bind with private CIDRs", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-loopback");
    config.host = "127.0.0.1";
    config.allowedCidrs = ["127.0.0.0/8"];

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings).toHaveLength(0);
  });
});

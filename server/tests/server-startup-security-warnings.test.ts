import { describe, expect, it } from "vitest";
import { Storage } from "../src/storage.js";
import { formatStartupSecurityWarnings } from "../src/server.js";

describe("startup security warnings", () => {
  it("warns when server binds to all interfaces", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-default");

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings.some((warning) => warning.includes("host=0.0.0.0"))).toBe(true);
  });

  it("has no warnings for loopback bind", () => {
    const config = Storage.getDefaultConfig("/tmp/oppi-server-security-warnings-loopback");
    config.host = "127.0.0.1";

    const warnings = formatStartupSecurityWarnings(config);

    expect(warnings).toHaveLength(0);
  });
});

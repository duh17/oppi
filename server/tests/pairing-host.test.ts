import { afterEach, describe, expect, it, vi } from "vitest";

const {
  mockGetLocalHostname,
  mockGetLocalIp,
  mockGetTailscaleHostname,
  mockGetTailscaleIp,
  mockResolveTlsConfig,
  mockValidateTailscaleMaterial,
} = vi.hoisted(() => ({
  mockGetLocalHostname: vi.fn(),
  mockGetLocalIp: vi.fn(),
  mockGetTailscaleHostname: vi.fn(),
  mockGetTailscaleIp: vi.fn(),
  mockResolveTlsConfig: vi.fn(),
  mockValidateTailscaleMaterial: vi.fn(),
}));

vi.mock("../src/cli/status.js", () => ({
  getLocalHostname: (...args: unknown[]) => mockGetLocalHostname(...args),
  getLocalIp: (...args: unknown[]) => mockGetLocalIp(...args),
  getTailscaleHostname: (...args: unknown[]) => mockGetTailscaleHostname(...args),
  getTailscaleIp: (...args: unknown[]) => mockGetTailscaleIp(...args),
}));

vi.mock("../src/tls.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/tls.js")>();
  return {
    ...actual,
    resolveTlsConfig: (...args: unknown[]) => mockResolveTlsConfig(...args),
    validateTailscaleMaterial: (...args: unknown[]) => mockValidateTailscaleMaterial(...args),
  };
});

import {
  assertPairingAdvertiseHostGrammar,
  assertPairingAdvertiseHostSuffix,
  rememberPairingAdvertiseHost,
  rememberValidatedPairingAdvertiseHost,
  resolvePairingAdvertiseHost,
} from "../src/cli/pairing-host.js";

describe("resolvePairingAdvertiseHost", () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it("prefers --host over OPPI_PAIR_HOST and never uses config.host", () => {
    const host = resolvePairingAdvertiseHost(
      { tls: { mode: "self-signed" } },
      "cos-1.taila3ebc.ts.net",
      { OPPI_PAIR_HOST: "192.168.1.44" },
    );
    expect(host).toBe("cos-1.taila3ebc.ts.net");
    expect(mockGetTailscaleHostname).not.toHaveBeenCalled();
  });

  it("uses OPPI_PAIR_HOST when --host is omitted", () => {
    const host = resolvePairingAdvertiseHost({ tls: { mode: "self-signed" } }, undefined, {
      OPPI_PAIR_HOST: "cos-1.taila3ebc.ts.net",
    });
    expect(host).toBe("cos-1.taila3ebc.ts.net");
  });

  it("ignores empty OPPI_PAIR_HOST and does not treat bind 0.0.0.0 as advertise", () => {
    mockGetLocalHostname.mockReturnValue("studio.local");
    const host = resolvePairingAdvertiseHost({ tls: { mode: "self-signed" } }, undefined, {
      OPPI_PAIR_HOST: "  ",
    });
    expect(host).toBe("studio.local");
  });

  it("uses live Tailscale hostname in tls.mode=tailscale when no override is set", () => {
    mockGetTailscaleHostname.mockReturnValue("cos-1.taila3ebc.ts.net");
    const host = resolvePairingAdvertiseHost({ tls: { mode: "tailscale" } }, undefined, {});
    expect(host).toBe("cos-1.taila3ebc.ts.net");
  });

  it("uses persisted pairHost after OPPI_PAIR_HOST and before auto-detect", () => {
    mockGetLocalHostname.mockReturnValue("studio.local");
    const host = resolvePairingAdvertiseHost(
      { tls: { mode: "self-signed" }, pairHost: "cos-1.taila3ebc.ts.net" },
      undefined,
      {},
    );
    expect(host).toBe("cos-1.taila3ebc.ts.net");
    expect(mockGetLocalHostname).not.toHaveBeenCalled();
  });

  it("remembers an explicit --host on the pairing store", () => {
    const updateConfig = vi.fn();
    rememberPairingAdvertiseHost({ updateConfig }, "  cos-1.taila3ebc.ts.net  ");
    expect(updateConfig).toHaveBeenCalledWith({ pairHost: "cos-1.taila3ebc.ts.net" });
    rememberPairingAdvertiseHost({ updateConfig }, "  ");
    expect(updateConfig).toHaveBeenCalledTimes(1);
  });

  it("validates and persists serve --host when already paired", () => {
    const updateConfig = vi.fn();
    const getDataDir = () => "/tmp/oppi-pair-host-test";
    rememberValidatedPairingAdvertiseHost(
      { getConfig: () => ({ tls: { mode: "self-signed" } }), getDataDir, updateConfig },
      "  studio.local  ",
    );
    expect(updateConfig).toHaveBeenCalledWith({ pairHost: "studio.local" });
    expect(mockValidateTailscaleMaterial).not.toHaveBeenCalled();

    expect(() =>
      rememberValidatedPairingAdvertiseHost(
        { getConfig: () => ({ tls: { mode: "tailscale" } }), getDataDir, updateConfig },
        "not-a-tailnet.example",
      ),
    ).toThrow(/Tailscale TLS mode requires a \*\.ts\.net pairing host/);
    expect(updateConfig).toHaveBeenCalledTimes(1);
    expect(mockValidateTailscaleMaterial).not.toHaveBeenCalled();

    mockResolveTlsConfig.mockReturnValue({ mode: "tailscale", certPath: "/tmp/server.crt" });
    mockValidateTailscaleMaterial.mockImplementation(() => {
      throw new Error("Tailscale TLS certificate does not cover typo.tail00000.ts.net");
    });
    expect(() =>
      rememberValidatedPairingAdvertiseHost(
        { getConfig: () => ({ tls: { mode: "tailscale" } }), getDataDir, updateConfig },
        "typo.tail00000.ts.net",
      ),
    ).toThrow(/does not cover typo\.tail00000\.ts\.net/);
    expect(updateConfig).toHaveBeenCalledTimes(1);

    mockValidateTailscaleMaterial.mockReturnValue("cos-1.taila3ebc.ts.net");
    rememberValidatedPairingAdvertiseHost(
      { getConfig: () => ({ tls: { mode: "tailscale" } }), getDataDir, updateConfig },
      "cos-1.taila3ebc.ts.net",
    );
    expect(mockValidateTailscaleMaterial).toHaveBeenCalled();
    expect(updateConfig).toHaveBeenCalledWith({ pairHost: "cos-1.taila3ebc.ts.net" });
  });

  it("rejects scheme, port, and path in an advertised pairing host", () => {
    const updateConfig = vi.fn();
    for (const host of [
      "server.local:7749",
      "https://server.local",
      "http://127.0.0.1",
      "server.local/path",
      "user@server.local",
      "[::1]:7749",
    ]) {
      expect(() => assertPairingAdvertiseHostGrammar(host)).toThrow(/hostname or IP only/);
      expect(() => rememberPairingAdvertiseHost({ updateConfig }, host)).toThrow(
        /hostname or IP only/,
      );
      expect(() =>
        rememberValidatedPairingAdvertiseHost(
          {
            getConfig: () => ({ tls: { mode: "self-signed" } }),
            getDataDir: () => "/tmp/oppi-pair-host-test",
            updateConfig,
          },
          host,
        ),
      ).toThrow(/hostname or IP only/);
    }
    expect(updateConfig).not.toHaveBeenCalled();
  });

  it("accepts hostname, IPv4, and bracketed IPv6 advertise hosts", () => {
    for (const host of [
      "studio.local",
      "cos-1.taila3ebc.ts.net",
      "127.0.0.1",
      "192.168.1.44",
      "[::1]",
      "[2001:db8::1]",
    ]) {
      expect(() => assertPairingAdvertiseHostGrammar(host)).not.toThrow();
    }
  });

  it("checks Tailscale suffix without requiring cert material", () => {
    assertPairingAdvertiseHostSuffix({ tls: { mode: "tailscale" } }, "cos-1.taila3ebc.ts.net");
    expect(mockValidateTailscaleMaterial).not.toHaveBeenCalled();
    expect(() =>
      assertPairingAdvertiseHostSuffix({ tls: { mode: "tailscale" } }, "not-a-tailnet.example"),
    ).toThrow(/Tailscale TLS mode requires a \*\.ts\.net pairing host/);
  });
});

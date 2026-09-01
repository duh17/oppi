import { afterEach, describe, expect, it, vi } from "vitest";

const {
  mockGetLocalHostname,
  mockGetLocalIp,
  mockGetTailscaleHostname,
  mockGetTailscaleIp,
} = vi.hoisted(() => ({
  mockGetLocalHostname: vi.fn(),
  mockGetLocalIp: vi.fn(),
  mockGetTailscaleHostname: vi.fn(),
  mockGetTailscaleIp: vi.fn(),
}));

vi.mock("../src/cli/status.js", () => ({
  getLocalHostname: (...args: unknown[]) => mockGetLocalHostname(...args),
  getLocalIp: (...args: unknown[]) => mockGetLocalIp(...args),
  getTailscaleHostname: (...args: unknown[]) => mockGetTailscaleHostname(...args),
  getTailscaleIp: (...args: unknown[]) => mockGetTailscaleIp(...args),
}));

import { rememberPairingAdvertiseHost, resolvePairingAdvertiseHost } from "../src/cli/pairing-host.js";

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
});

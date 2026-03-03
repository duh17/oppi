import { describe, expect, it } from "vitest";
import { resolveBonjourLanHost } from "../src/server.js";

type NetworkInterfaces = NodeJS.Dict<import("node:os").NetworkInterfaceInfo[]>;

describe("resolveBonjourLanHost", () => {
  it("returns null for loopback-only binds", () => {
    const interfaces: NetworkInterfaces = {
      en0: [
        {
          address: "192.168.1.44",
          netmask: "255.255.255.0",
          family: "IPv4",
          mac: "00:11:22:33:44:55",
          internal: false,
          cidr: "192.168.1.44/24",
        },
      ],
    };

    expect(resolveBonjourLanHost("127.0.0.1", interfaces)).toBeNull();
    expect(resolveBonjourLanHost("localhost", interfaces)).toBeNull();
    expect(resolveBonjourLanHost("::1", interfaces)).toBeNull();
  });

  it("uses explicit non-wildcard IPv4 bind host directly", () => {
    const interfaces: NetworkInterfaces = {
      en0: [
        {
          address: "192.168.1.44",
          netmask: "255.255.255.0",
          family: "IPv4",
          mac: "00:11:22:33:44:55",
          internal: false,
          cidr: "192.168.1.44/24",
        },
      ],
    };

    expect(resolveBonjourLanHost("192.168.1.99", interfaces)).toBe("192.168.1.99");
  });

  it("selects first valid LAN IPv4 for wildcard binds", () => {
    const interfaces: NetworkInterfaces = {
      lo0: [
        {
          address: "127.0.0.1",
          netmask: "255.0.0.0",
          family: "IPv4",
          mac: "00:00:00:00:00:00",
          internal: true,
          cidr: "127.0.0.1/8",
        },
      ],
      en0: [
        {
          address: "169.254.10.2",
          netmask: "255.255.0.0",
          family: "IPv4",
          mac: "00:11:22:33:44:55",
          internal: false,
          cidr: "169.254.10.2/16",
        },
        {
          address: "192.168.1.44",
          netmask: "255.255.255.0",
          family: "IPv4",
          mac: "00:11:22:33:44:55",
          internal: false,
          cidr: "192.168.1.44/24",
        },
      ],
    };

    expect(resolveBonjourLanHost("0.0.0.0", interfaces)).toBe("192.168.1.44");
    expect(resolveBonjourLanHost("::", interfaces)).toBe("192.168.1.44");
  });

  it("returns null when no routable LAN IPv4 address is available", () => {
    const interfaces: NetworkInterfaces = {
      lo0: [
        {
          address: "127.0.0.1",
          netmask: "255.0.0.0",
          family: "IPv4",
          mac: "00:00:00:00:00:00",
          internal: true,
          cidr: "127.0.0.1/8",
        },
      ],
      en0: [
        {
          address: "169.254.10.2",
          netmask: "255.255.0.0",
          family: "IPv4",
          mac: "00:11:22:33:44:55",
          internal: false,
          cidr: "169.254.10.2/16",
        },
      ],
    };

    expect(resolveBonjourLanHost("0.0.0.0", interfaces)).toBeNull();
  });
});

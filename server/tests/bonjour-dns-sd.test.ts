import { describe, expect, it } from "vitest";
import { buildDnsSdAdvertiseArgs } from "../src/bonjour-dns-sd.js";

describe("buildDnsSdAdvertiseArgs", () => {
  it("builds dns-sd register args with txt key-values", () => {
    const args = buildDnsSdAdvertiseArgs({
      serviceType: "_oppi._tcp",
      serviceName: "oppi-abcdef",
      port: 7749,
      txt: {
        v: "1",
        sid: "abcdef1234567890",
        tfp: "deadbeef",
        ip: "192.168.1.42",
        p: "7749",
      },
    });

    expect(args).toEqual([
      "-R",
      "oppi-abcdef",
      "_oppi._tcp",
      "local",
      "7749",
      "v=1",
      "sid=abcdef1234567890",
      "tfp=deadbeef",
      "ip=192.168.1.42",
      "p=7749",
    ]);
  });

  it("omits empty txt values", () => {
    const args = buildDnsSdAdvertiseArgs({
      serviceType: "_oppi._tcp",
      serviceName: "oppi-abcdef",
      port: 7749,
      txt: {
        v: "1",
        sid: "abcdef1234567890",
        tfp: "",
      },
    });

    expect(args).toEqual([
      "-R",
      "oppi-abcdef",
      "_oppi._tcp",
      "local",
      "7749",
      "v=1",
      "sid=abcdef1234567890",
    ]);
  });
});

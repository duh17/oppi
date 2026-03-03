import { describe, expect, it } from "vitest";
import {
  BonjourAdvertiser,
  buildBonjourServiceName,
  buildBonjourTxtRecord,
  fingerprintPrefix,
  isBonjourEnabled,
  normalizeFingerprint,
  OPPI_BONJOUR_PROTOCOL_VERSION,
  OPPI_BONJOUR_SERVICE_TYPE,
  type BonjourAdvertiseInput,
  type BonjourPublisher,
} from "../src/bonjour-advertiser.js";

describe("normalizeFingerprint", () => {
  it("strips sha256 prefix", () => {
    expect(normalizeFingerprint("sha256:abcdef")).toBe("abcdef");
  });

  it("keeps raw fingerprint values", () => {
    expect(normalizeFingerprint("abcdef")).toBe("abcdef");
  });

  it("returns empty for blank strings", () => {
    expect(normalizeFingerprint("   ")).toBe("");
  });
});

describe("fingerprintPrefix", () => {
  it("returns first 16 chars after sha256 prefix", () => {
    expect(fingerprintPrefix("sha256:ABCDEFGHIJKLMNOPQRSTUVWXYZ")).toBe("ABCDEFGHIJKLMNOP");
  });

  it("caps by actual fingerprint length", () => {
    expect(fingerprintPrefix("sha256:abc", 16)).toBe("abc");
  });

  it("returns empty when prefix length is zero", () => {
    expect(fingerprintPrefix("sha256:abcdef", 0)).toBe("");
  });
});

describe("buildBonjourTxtRecord", () => {
  it("includes sid and protocol version", () => {
    const txt = buildBonjourTxtRecord({
      serverFingerprint: "sha256:ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    });

    expect(txt).toEqual({
      v: OPPI_BONJOUR_PROTOCOL_VERSION,
      sid: "ABCDEFGHIJKLMNOP",
    });
  });

  it("includes tls fingerprint prefix when provided", () => {
    const txt = buildBonjourTxtRecord({
      serverFingerprint: "sha256:ABCDEFGHIJKLMNOPQRSTUVWXYZ",
      tlsCertFingerprint: "sha256:1234567890abcdefghijkl",
    });

    expect(txt).toEqual({
      v: OPPI_BONJOUR_PROTOCOL_VERSION,
      sid: "ABCDEFGHIJKLMNOP",
      tfp: "1234567890abcdef",
    });
  });

  it("includes lan host and port when provided", () => {
    const txt = buildBonjourTxtRecord({
      serverFingerprint: "sha256:ABCDEFGHIJKLMNOPQRSTUVWXYZ",
      lanHost: "192.168.1.42",
      port: 7749,
    });

    expect(txt).toEqual({
      v: OPPI_BONJOUR_PROTOCOL_VERSION,
      sid: "ABCDEFGHIJKLMNOP",
      ip: "192.168.1.42",
      p: "7749",
    });
  });

  it("throws when server fingerprint is empty", () => {
    expect(() =>
      buildBonjourTxtRecord({
        serverFingerprint: "   ",
      }),
    ).toThrow("serverFingerprint is required");
  });
});

describe("buildBonjourServiceName", () => {
  it("builds name from sid prefix", () => {
    expect(buildBonjourServiceName("sha256:ABCDEFGHIJKLMNOPQRSTUVWXYZ")).toBe("oppi-ABCDEFGHIJKLMNOP");
  });

  it("supports custom prefix", () => {
    expect(buildBonjourServiceName("sha256:ABCDEFGHIJKLMNOPQRSTUVWXYZ", "myoppi")).toBe(
      "myoppi-ABCDEFGHIJKLMNOP",
    );
  });
});

describe("isBonjourEnabled", () => {
  it("defaults to enabled", () => {
    expect(isBonjourEnabled({})).toBe(true);
  });

  it("parses explicit false values", () => {
    expect(isBonjourEnabled({ OPPI_BONJOUR: "false" })).toBe(false);
    expect(isBonjourEnabled({ OPPI_BONJOUR: "0" })).toBe(false);
  });

  it("parses explicit true values", () => {
    expect(isBonjourEnabled({ OPPI_BONJOUR: "true" })).toBe(true);
    expect(isBonjourEnabled({ OPPI_BONJOUR: "1" })).toBe(true);
  });

  it("treats unknown values as enabled", () => {
    expect(isBonjourEnabled({ OPPI_BONJOUR: "wat" })).toBe(true);
  });
});

describe("BonjourAdvertiser", () => {
  it("starts advertisement through publisher", () => {
    const calls: BonjourAdvertiseInput[] = [];

    const publisher: BonjourPublisher = {
      advertise(input) {
        calls.push(input);
        return { stop() {} };
      },
    };

    const advertiser = new BonjourAdvertiser(publisher);
    advertiser.start({
      serviceType: OPPI_BONJOUR_SERVICE_TYPE,
      serviceName: "oppi-abc",
      port: 7749,
      txt: {
        v: OPPI_BONJOUR_PROTOCOL_VERSION,
        sid: "abcdef",
      },
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].serviceType).toBe(OPPI_BONJOUR_SERVICE_TYPE);
    expect(advertiser.isAdvertising).toBe(true);
  });

  it("stops previous ad when restarting", () => {
    let stopCount = 0;

    const publisher: BonjourPublisher = {
      advertise() {
        return {
          stop() {
            stopCount += 1;
          },
        };
      },
    };

    const advertiser = new BonjourAdvertiser(publisher);
    advertiser.start({
      serviceType: OPPI_BONJOUR_SERVICE_TYPE,
      serviceName: "oppi-a",
      port: 7749,
      txt: { v: "1", sid: "a" },
    });
    advertiser.start({
      serviceType: OPPI_BONJOUR_SERVICE_TYPE,
      serviceName: "oppi-b",
      port: 7750,
      txt: { v: "1", sid: "b" },
    });

    // First start's handle should be stopped by second start.
    expect(stopCount).toBe(1);
    expect(advertiser.isAdvertising).toBe(true);
  });

  it("stop is idempotent", () => {
    let stopCount = 0;

    const publisher: BonjourPublisher = {
      advertise() {
        return {
          stop() {
            stopCount += 1;
          },
        };
      },
    };

    const advertiser = new BonjourAdvertiser(publisher);
    advertiser.start({
      serviceType: OPPI_BONJOUR_SERVICE_TYPE,
      serviceName: "oppi-a",
      port: 7749,
      txt: { v: "1", sid: "a" },
    });

    advertiser.stop();
    advertiser.stop();

    expect(stopCount).toBe(1);
    expect(advertiser.isAdvertising).toBe(false);
  });
});

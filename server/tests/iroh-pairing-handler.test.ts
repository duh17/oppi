import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { handleIrohPairingRequest } from "../src/iroh-pairing.js";
import { Storage } from "../src/storage.js";

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-iroh-pairing-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

describe("Iroh pairing request handling", () => {
  it("exchanges an existing Oppi pairing token for a real device token", () => {
    const pairingToken = storage.issuePairingToken(60_000);

    const response = handleIrohPairingRequest(storage, { pairingToken });

    expect(response.ok).toBe(true);
    if (!response.ok) return;
    expect(response.deviceToken).toMatch(/^dt_/);
    expect(storage.getAuthDeviceTokens()).toContain(response.deviceToken);

    const replay = handleIrohPairingRequest(storage, { pairingToken });
    expect(replay).toEqual({
      ok: false,
      status: 401,
      error: "Invalid or expired pairing token",
    });
  });

  it("rejects invalid and expired tokens deterministically", () => {
    expect(handleIrohPairingRequest(storage, { pairingToken: "pt_invalid" })).toEqual({
      ok: false,
      status: 401,
      error: "Invalid or expired pairing token",
    });

    const expiredToken = storage.issuePairingToken(60_000);
    storage.updateConfig({ pairingTokenExpiresAt: Date.now() - 1 });

    expect(handleIrohPairingRequest(storage, { pairingToken: expiredToken })).toEqual({
      ok: false,
      status: 401,
      error: "Invalid or expired pairing token",
    });
  });

  it("binds Iroh-issued device tokens to the pairing token transport constraints", () => {
    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });

    const httpFallback = handleIrohPairingRequest(storage, { pairingToken });
    expect(httpFallback).toEqual({
      ok: false,
      status: 401,
      error: "Invalid or expired pairing token",
    });
    expect(storage.getConfig().pairingToken).toBe(pairingToken);

    const response = handleIrohPairingRequest(
      storage,
      { pairingToken },
      {
        clientNodeId: "client-node-1",
      },
    );
    expect(response.ok).toBe(true);
    if (!response.ok) return;
    expect(storage.hasAuthTokenForTransport(response.deviceToken, "iroh")).toBe(true);
    expect(storage.hasAuthTokenForTransport(response.deviceToken, "http")).toBe(false);
  });

  it("keeps constant-time token checks and throttles Iroh lastSeen writes to five minutes", () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date("2026-01-01T00:00:00Z"));
      const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });
      const response = handleIrohPairingRequest(
        storage,
        { pairingToken },
        { clientNodeId: "client-node" },
      );
      if (!response.ok) throw new Error("pairing failed");

      expect(storage.validateIrohDeviceToken(response.deviceToken, "client-node")).toEqual({
        ok: true,
      });
      const firstSeen = storage.getConfig().irohDeviceTokenBindings?.[0]?.lastSeenAt;
      expect(firstSeen).toBe(Date.now());

      vi.advanceTimersByTime(5 * 60_000 - 1);
      expect(storage.validateIrohDeviceToken(response.deviceToken, "client-node")).toEqual({
        ok: true,
      });
      expect(storage.getConfig().irohDeviceTokenBindings?.[0]?.lastSeenAt).toBe(firstSeen);

      vi.advanceTimersByTime(1);
      expect(storage.validateIrohDeviceToken(response.deviceToken, "client-node")).toEqual({
        ok: true,
      });
      expect(storage.getConfig().irohDeviceTokenBindings?.[0]?.lastSeenAt).toBe(Date.now());
      const sameLengthWrongToken = `x${response.deviceToken.slice(1)}`;
      expect(storage.validateIrohDeviceToken(sameLengthWrongToken, "client-node")).toEqual({
        ok: false,
        code: "unknown_token",
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it("rejects missing tokens without consuming storage", () => {
    const pairingToken = storage.issuePairingToken(60_000);

    expect(handleIrohPairingRequest(storage, { pairingToken: "   " })).toEqual({
      ok: false,
      status: 400,
      error: "pairingToken required",
    });
    expect(storage.getConfig().pairingToken).toBe(pairingToken);
  });
});

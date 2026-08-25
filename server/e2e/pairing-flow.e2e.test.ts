/**
 * E2E: Pairing flow
 *
 * Exercises the full pairing lifecycle that a new iOS device goes through:
 *   1. Server generates invite (QR payload with one-time pairing token)
 *   2. Client decodes the invite payload (simulates QR scan)
 *   3. Client POST /pair with the pairing token → receives deviceToken
 *   4. Replayed pairing token is rejected (one-time use)
 *   5. Device token authenticates all subsequent API calls
 *   6. Device can list workspaces, create sessions, and access split streams
 *
 * Requires: Docker, OMLX server on localhost:8400
 */

import { describe, it, expect, beforeAll, inject } from "vitest";
import {
  api,
  generateTestInvite,
  openSessionStream,
  closeStream,
  sessionStreamURL,
  isSecureTransport,
} from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
    e2eModel: string;
  }
}

async function waitForUpgradeStatus(url: string, deviceToken?: string): Promise<number> {
  const WebSocket = (await import("ws")).default;
  return new Promise((resolve) => {
    const ws = new WebSocket(url, {
      ...(deviceToken ? { headers: { Authorization: `Bearer ${deviceToken}` } } : {}),
      ...(isSecureTransport() ? { rejectUnauthorized: false } : {}),
    });
    const timer = setTimeout(() => {
      ws.terminate();
      resolve(0);
    }, 120_000);
    ws.once("unexpected-response", (_req, res) => {
      clearTimeout(timer);
      res.resume();
      resolve(res.statusCode || 0);
    });
    ws.once("open", () => {
      clearTimeout(timer);
      ws.close();
      resolve(200);
    });
    ws.once("error", (error) => {
      clearTimeout(timer);
      const match = error.message.match(/Unexpected server response:\s*(\d+)/i);
      resolve(match ? Number(match[1]) : 0);
    });
  });
}

describe("E2E: Pairing Flow", { timeout: 300_000 }, () => {
  // Server is started by globalSetup (e2e/setup.ts)
  const lmsReady = () => inject("e2eLmsReady");

  // ── 1. Pre-pairing: unauthenticated access is rejected ──

  it("rejects unauthenticated /me", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", "/me");
    expect(res.status).toBe(401);
  });

  it("rejects unauthenticated /workspaces", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", "/workspaces");
    expect(res.status).toBe(401);
  });

  it("rejects unauthenticated split stream WebSocket", async () => {
    if (!lmsReady()) return;

    const status = await waitForUpgradeStatus(
      sessionStreamURL("missing-workspace", "missing-session"),
    );

    expect(status).toBe(401);
  });

  // ── 2. Invite generation and payload decode ──

  it("generates a valid invite with pairing token", async () => {
    if (!lmsReady()) return;

    const invite = await generateTestInvite();

    expect(invite.pairingToken).toBeTruthy();
    expect(invite.fingerprint).toBeTruthy();
    expect(invite.inviteURL).toContain("oppi://connect");

    // Decode the invite URL (simulates what iOS app does)
    const url = new URL(invite.inviteURL);
    const inviteParam = url.searchParams.get("invite");
    expect(inviteParam).toBeTruthy();

    const envelope = JSON.parse(Buffer.from(inviteParam!, "base64url").toString("utf-8"));
    expect(envelope.v).toBe(3);
    expect(envelope.publicKey).toBeTruthy();
    expect(envelope.signature).toBeTruthy();

    const decoded = JSON.parse(Buffer.from(envelope.signedPayload, "base64url").toString("utf-8"));
    expect(decoded.v).toBe(3);
    expect(decoded.pairingToken).toBe(invite.pairingToken);
    expect(decoded.fingerprint).toBe(invite.fingerprint);
    expect(decoded.token).toBe(""); // Pairing flow uses pairingToken, not token
  });

  // ── 3. Pairing exchange ──

  describe("pairing exchange", () => {
    let deviceToken = "";
    let workspaceId = "";
    let sessionId = "";
    let invite: Awaited<ReturnType<typeof generateTestInvite>>;

    beforeAll(async () => {
      if (!lmsReady()) return;
      invite = await generateTestInvite();
    });

    it("rejects pairing with empty token", async () => {
      if (!lmsReady()) return;

      const res = await api("POST", "/pair", undefined, { pairingToken: "" });
      expect(res.status).toBe(400);
    });

    it("rejects pairing with invalid token", async () => {
      if (!lmsReady()) return;

      const res = await api("POST", "/pair", undefined, {
        pairingToken: "definitely-not-valid",
      });
      expect(res.status).toBe(401);
    });

    it("pairs successfully with valid pairing token", async () => {
      if (!lmsReady()) return;

      // Retry with fresh invite if pairing fails — previous test file may have
      // left a consumed token on disk that hasn't been fully flushed.
      let res = await api("POST", "/pair", undefined, {
        pairingToken: invite.pairingToken,
        deviceName: "e2e-pairing-test",
      });

      if (res.status !== 200) {
        invite = await generateTestInvite();
        res = await api("POST", "/pair", undefined, {
          pairingToken: invite.pairingToken,
          deviceName: "e2e-pairing-test",
        });
      }

      expect(res.status).toBe(200);
      expect(res.json?.deviceToken).toBeTruthy();
      expect(typeof res.json?.deviceToken).toBe("string");

      deviceToken = res.json!.deviceToken as string;
    });

    it("rejects replayed pairing token (one-time use)", async () => {
      if (!lmsReady()) return;

      const res = await api("POST", "/pair", undefined, {
        pairingToken: invite.pairingToken,
        deviceName: "e2e-replay-attempt",
      });

      expect(res.status).toBe(401);
    });

    // ── 4. Post-pairing: device token works ──

    it("authenticates /me with device token", async () => {
      if (!lmsReady() || !deviceToken) return;

      const res = await api("GET", "/me", deviceToken);
      expect(res.status).toBe(200);
      expect(res.json?.user).toBeTruthy();
    });

    it("lists workspaces with device token", async () => {
      if (!lmsReady() || !deviceToken) return;

      const res = await api("GET", "/workspaces", deviceToken);
      expect(res.status).toBe(200);
      expect(Array.isArray(res.json?.workspaces)).toBe(true);
    });

    it("creates a workspace with device token", async () => {
      if (!lmsReady() || !deviceToken) return;

      const res = await api("POST", "/workspaces", deviceToken, {
        name: "e2e-pairing-workspace",
      });

      expect(res.status).toBe(201);
      expect(res.json?.workspace).toBeTruthy();
      workspaceId = (res.json!.workspace as Record<string, unknown>).id as string;
      expect(workspaceId).toBeTruthy();
    });

    it("creates a session with device token", async () => {
      if (!lmsReady() || !deviceToken || !workspaceId) return;

      const res = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
        model: inject("e2eModel"),
      });

      expect(res.status).toBe(201);
      expect(res.json?.session).toBeTruthy();
      sessionId = (res.json!.session as Record<string, unknown>).id as string;
      expect(sessionId).toBeTruthy();
    });

    it("opens split session WebSocket with device token", async () => {
      if (!lmsReady() || !deviceToken || !workspaceId || !sessionId) return;

      const sessionStream = await openSessionStream(deviceToken, workspaceId, sessionId);

      expect(
        sessionStream.events.some(
          (e) => e.direction === "in" && e.type === "connected" && e.sessionId === sessionId,
        ),
      ).toBe(true);

      await closeStream(sessionStream);
    });

    it("rejects split streams with invalid device token", async () => {
      if (!lmsReady()) return;

      const status = await waitForUpgradeStatus(
        sessionStreamURL(workspaceId || "missing", sessionId || "missing"),
        `${deviceToken}_invalid`,
      );

      expect(status).toBe(401);
    });
  });

  // ── 5. Server info accessible post-pairing ──

  it("accesses /server/info with device token", async () => {
    if (!lmsReady()) return;

    // Pair a fresh device for this test
    const invite = await generateTestInvite();
    const pairRes = await api("POST", "/pair", undefined, {
      pairingToken: invite.pairingToken,
    });
    const token = pairRes.json?.deviceToken as string;

    const info = await api("GET", "/server/info", token);
    expect(info.status).toBe(200);
    expect(info.json?.version).toBeTruthy();
    expect(info.json?.stats).toBeTruthy();
    const capabilities = info.json?.capabilities as Record<string, { version?: number }>;
    expect(capabilities.sessionStream?.version).toBeGreaterThanOrEqual(1);
  });

  it("lists models with device token", async () => {
    if (!lmsReady()) return;

    const invite = await generateTestInvite();
    const pairRes = await api("POST", "/pair", undefined, {
      pairingToken: invite.pairingToken,
    });
    const token = pairRes.json?.deviceToken as string;

    const models = await api("GET", "/models", token);
    expect(models.status).toBe(200);
    expect(Array.isArray(models.json?.models)).toBe(true);
  });
});

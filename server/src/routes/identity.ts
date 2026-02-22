import type { IncomingMessage, ServerResponse } from "node:http";
import { hostname } from "node:os";

import { ensureIdentityMaterial, identityConfigForDataDir } from "../security.js";
import type { RegisterDeviceTokenRequest } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const PAIRING_MAX_FAILURES = 5;
const PAIRING_WINDOW_MS = 60_000;
const PAIRING_COOLDOWN_MS = 120_000;

export function createIdentityRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  const pairingFailuresBySource = new Map<string, number[]>();
  const pairingBlockedUntilBySource = new Map<string, number>();

  function pairingSourceKey(req: IncomingMessage): string {
    return req.socket.remoteAddress || "unknown";
  }

  function isPairingRateLimited(source: string, now: number): boolean {
    const blockedUntil = pairingBlockedUntilBySource.get(source) || 0;
    if (blockedUntil > now) {
      return true;
    }

    if (blockedUntil > 0 && blockedUntil <= now) {
      pairingBlockedUntilBySource.delete(source);
      pairingFailuresBySource.delete(source);
    }

    return false;
  }

  function recordPairingFailure(source: string, now: number): void {
    const windowStart = now - PAIRING_WINDOW_MS;
    const failures = (pairingFailuresBySource.get(source) || []).filter((ts) => ts >= windowStart);
    failures.push(now);
    pairingFailuresBySource.set(source, failures);

    if (failures.length >= PAIRING_MAX_FAILURES) {
      pairingBlockedUntilBySource.set(source, now + PAIRING_COOLDOWN_MS);
    }
  }

  function clearPairingFailures(source: string): void {
    pairingFailuresBySource.delete(source);
    pairingBlockedUntilBySource.delete(source);
  }

  async function handlePair(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const source = pairingSourceKey(req);
    const now = Date.now();
    if (isPairingRateLimited(source, now)) {
      helpers.error(res, 429, "Too many invalid pairing attempts. Try again later.");
      return;
    }

    const body = await helpers.parseBody<{ pairingToken?: string }>(req);
    const pairingToken = typeof body.pairingToken === "string" ? body.pairingToken.trim() : "";

    if (!pairingToken) {
      helpers.error(res, 400, "pairingToken required");
      return;
    }

    const deviceToken = ctx.storage.consumePairingToken(pairingToken);
    if (!deviceToken) {
      recordPairingFailure(source, now);
      helpers.error(res, 401, "Invalid or expired pairing token");
      return;
    }

    clearPairingFailures(source);
    helpers.json(res, { deviceToken });
  }

  function handleGetMe(res: ServerResponse): void {
    // Keep a stable single-user identifier for iOS decoding.
    helpers.json(res, {
      user: "owner",
      name: ctx.storage.getOwnerName(),
    });
  }

  function handleGetServerInfo(res: ServerResponse): void {
    const config = ctx.storage.getConfig();
    const workspaces = ctx.storage.listWorkspaces();
    const sessions = ctx.storage.listSessions();
    const activeSessions = sessions.filter((s) => s.status !== "stopped" && s.status !== "error");

    const uptimeSeconds = Math.floor((Date.now() - ctx.serverStartedAt) / 1000);

    let identity: { fingerprint: string; keyId: string; algorithm: "ed25519" } | null = null;
    try {
      const material = ensureIdentityMaterial(identityConfigForDataDir(ctx.storage.getDataDir()));
      identity = {
        fingerprint: material.fingerprint,
        keyId: material.keyId,
        algorithm: material.algorithm,
      };
    } catch {
      identity = null;
    }

    helpers.json(res, {
      name: hostname(),
      version: ctx.serverVersion,
      uptime: uptimeSeconds,
      os: process.platform,
      arch: process.arch,
      hostname: hostname(),
      nodeVersion: process.version,
      piVersion: ctx.piVersion,
      configVersion: config.configVersion ?? 1,
      identity,
      stats: {
        workspaceCount: workspaces.length,
        activeSessionCount: activeSessions.length,
        totalSessionCount: sessions.length,
        skillCount: ctx.skillRegistry.list().length,
        modelCount: ctx.getModelCatalog().length,
      },
    });
  }

  async function handleListModels(res: ServerResponse): Promise<void> {
    await ctx.refreshModelCatalog();
    helpers.json(res, { models: ctx.getModelCatalog() });
  }

  async function handleRegisterDeviceToken(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<RegisterDeviceTokenRequest>(req);
    if (!body.deviceToken) {
      helpers.error(res, 400, "deviceToken required");
      return;
    }

    const tokenType = body.tokenType || "apns";
    if (tokenType === "liveactivity") {
      ctx.storage.setLiveActivityToken(body.deviceToken);
      console.log(`[push] Live Activity token registered for ${ctx.storage.getOwnerName()}`);
    } else {
      ctx.storage.addPushDeviceToken(body.deviceToken);
      console.log(`[push] Device token registered for ${ctx.storage.getOwnerName()}`);
    }

    helpers.json(res, { ok: true });
  }

  async function handleDeleteDeviceToken(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<{ deviceToken: string }>(req);
    if (body.deviceToken) {
      ctx.storage.removePushDeviceToken(body.deviceToken);
      console.log(`[push] Device token removed for ${ctx.storage.getOwnerName()}`);
    }
    helpers.json(res, { ok: true });
  }

  return async ({ method, path, req, res }) => {
    if (path === "/pair" && method === "POST") {
      await handlePair(req, res);
      return true;
    }
    if (path === "/me" && method === "GET") {
      handleGetMe(res);
      return true;
    }
    if (path === "/server/info" && method === "GET") {
      handleGetServerInfo(res);
      return true;
    }
    if (path === "/models" && method === "GET") {
      await handleListModels(res);
      return true;
    }
    if (path === "/me/device-token" && method === "POST") {
      await handleRegisterDeviceToken(req, res);
      return true;
    }
    if (path === "/me/device-token" && method === "DELETE") {
      await handleDeleteDeviceToken(req, res);
      return true;
    }

    return false;
  };
}

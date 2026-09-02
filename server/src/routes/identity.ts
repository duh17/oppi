import type { IncomingMessage, ServerResponse } from "node:http";
import { hostname } from "node:os";

import { ensureIdentityMaterial, identityConfigForDataDir } from "../security.js";
import { createLogger } from "../logger.js";
import { isLocalRequest } from "../request-trust.js";
import { EXTENSION_NATIVE_UI_SERVER_CAPABILITIES } from "../extension-ui-contract.js";
import { isDictationStreamEnabled } from "../pi-extension-stt-host.js";
import type { RegisterDeviceTokenRequest } from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import {
  aggregateDailyDetail,
  aggregateStats,
  getActiveSessions,
  getMemoryStats,
  parseRange,
  parseTzOffset,
} from "./server-stats.js";

const PAIRING_MAX_FAILURES = 5;
const PAIRING_WINDOW_MS = 60_000;
const PAIRING_COOLDOWN_MS = 120_000;

const log = createLogger({ base: { component: "route_identity" } });

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

    const body = await helpers.parseBody<{
      pairingToken?: string;
      devicePublicKey?: unknown;
      deviceName?: string;
    }>(req);
    const pairingToken = typeof body.pairingToken === "string" ? body.pairingToken.trim() : "";
    if (!pairingToken) {
      helpers.error(res, 400, "pairingToken required");
      return;
    }

    // Pairing issues short-lived at_ credentials bound to a device P-256 key.
    // Leftover dt_ tokens are migration-only; pre-migration clients must update.
    if (body.devicePublicKey === undefined) {
      helpers.error(res, 400, "devicePublicKey required");
      return;
    }

    const pairing = ctx.storage.enrollViaPairing(pairingToken, {
      publicKey: body.devicePublicKey,
      name: body.deviceName,
    });
    if (!pairing) {
      recordPairingFailure(source, now);
      helpers.error(res, 401, "Invalid or expired pairing token");
      return;
    }

    clearPairingFailures(source);
    helpers.json(res, pairing);
  }

  function handleGetMe(res: ServerResponse): void {
    // Keep a stable single-user identifier for iOS decoding.
    helpers.json(res, {
      user: "owner",
      name: ctx.storage.getOwnerName(),
    });
  }

  async function handleGetServerInfo(res: ServerResponse): Promise<void> {
    const config = ctx.storage.getConfig();
    const workspaces = ctx.storage.listWorkspaces();
    const sessions = ctx.storage.listSessions();
    const activeIds = ctx.sessionRuntimes.getActiveSessionIds();
    const activeSessions = sessions.filter(
      (s) => s.status !== "stopped" && s.status !== "error" && activeIds.has(s.id),
    );
    const uptimeSeconds = Math.floor((Date.now() - ctx.serverStartedAt) / 1000);

    let identity: { fingerprint: string; keyId: string; algorithm: "ed25519" } | null;
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
      uploadProtocol: {
        version: 1,
        maxFileBytes: config.uploadStore?.maxFileBytes ?? 50 * 1024 * 1024,
        maxTurnBytes: config.uploadStore?.maxTurnBytes ?? 100 * 1024 * 1024,
      },
      images: {
        autoResize: config.images?.autoResize ?? false,
      },
      capabilities: {
        sessionStream: { version: 1 },
        controlSessions: { version: 1 },
        appEventStream: { version: 1 },
        dictationStream: isDictationStreamEnabled(config.asr) ? { version: 1 } : undefined,
        extensionNativeUI: {
          version: 1,
          capabilities: [...EXTENSION_NATIVE_UI_SERVER_CAPABILITIES],
        },
      },
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

  async function handleGetProviderQuotas(res: ServerResponse): Promise<void> {
    const getter = ctx.getProviderQuotasStatus;
    if (!getter) {
      helpers.json(res, {
        providers: [],
        fetchedAt: Date.now(),
      });
      return;
    }

    helpers.json(res, await getter());
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
      log.info("identity.push.live_activity_token.registered", {
        owner: ctx.storage.getOwnerName(),
      });
    } else {
      ctx.storage.addPushDeviceToken(body.deviceToken);
      log.info("identity.push.device_token.registered", {
        owner: ctx.storage.getOwnerName(),
      });
    }

    helpers.json(res, { ok: true });
  }

  function handleGetDailyDetail(date: string, url: URL, res: ServerResponse): void {
    const parsed = new Date(date + "T00:00:00Z");
    if (isNaN(parsed.getTime())) {
      helpers.json(res, { error: "Invalid date format. Use YYYY-MM-DD." }, 400);
      return;
    }

    const tzOffsetMin = parseTzOffset(url.searchParams.get("tz"));
    const sessions = ctx.storage.listSessions();
    const result = aggregateDailyDetail(sessions, date, tzOffsetMin);
    helpers.json(res, result);
  }

  function handleGetServerStats(url: URL, res: ServerResponse): void {
    const rangeDays = parseRange(url.searchParams.get("range"));
    const tzOffsetMin = parseTzOffset(url.searchParams.get("tz"));
    const sessions = ctx.storage.listSessions();
    const workspaces = ctx.storage.listWorkspaces();

    const memory = getMemoryStats();
    const activeSessions = getActiveSessions(sessions, ctx.sessionRuntimes.getActiveSessionIds());
    const { daily, modelBreakdown, workspaceBreakdown, totals } = aggregateStats({
      sessions,
      workspaces,
      rangeDays,
      tzOffsetMin,
    });

    helpers.json(res, {
      memory,
      activeSessions,
      daily,
      modelBreakdown,
      workspaceBreakdown,
      totals,
    });
  }

  // ─── Device-key auth routes ───

  async function handleAuthMigrate(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const authorization = req.headers.authorization;
    const legacyToken = authorization?.startsWith("Bearer ") ? authorization.slice(7) : "";
    if (!legacyToken) {
      helpers.error(res, 400, "legacy device token required");
      return;
    }

    const body = await helpers.parseBody<{ devicePublicKey?: unknown; deviceName?: string }>(req);
    if (!body.devicePublicKey) {
      helpers.error(res, 400, "devicePublicKey required");
      return;
    }

    const enrollment = ctx.storage.migrateLegacyDevice(legacyToken, {
      publicKey: body.devicePublicKey,
      name: body.deviceName,
    });
    if (!enrollment) {
      helpers.error(res, 401, "Invalid or unsupported legacy device token");
      return;
    }

    log.info("auth.device_migrated", { device: enrollment.deviceId });
    helpers.json(res, {
      deviceId: enrollment.deviceId,
      accessToken: enrollment.accessToken,
      expiresAt: enrollment.expiresAt,
      refreshChallenge: enrollment.refreshChallenge,
    });
  }

  async function handleAuthChallenge(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<{ deviceId?: string }>(req);
    const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
    if (!deviceId) {
      helpers.error(res, 400, "deviceId required");
      return;
    }

    const challenge = ctx.storage.issueChallenge(deviceId);
    if (!challenge) {
      helpers.error(res, 404, "Unknown or revoked device");
      return;
    }
    helpers.json(res, challenge);
  }

  async function handleAuthRefresh(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<{
      deviceId?: string;
      nonce?: string;
      signature?: unknown;
    }>(req);
    const deviceId = typeof body.deviceId === "string" ? body.deviceId.trim() : "";
    const nonce = typeof body.nonce === "string" ? body.nonce.trim() : "";
    if (!deviceId || !nonce || typeof body.signature !== "string" || body.signature.length === 0) {
      helpers.error(res, 400, "deviceId, nonce, and signature required");
      return;
    }

    const result = ctx.storage.refresh({ deviceId, nonce, signature: body.signature });
    if (!result.ok) {
      const status =
        result.code === "unknown_device"
          ? 404
          : result.code === "revoked"
            ? 403
            : result.code === "rate_limited"
              ? 429
              : 401;
      log.warn("auth.refresh_failed", { device: deviceId, code: result.code });
      helpers.error(res, status, result.code);
      return;
    }

    log.info("auth.refresh_succeeded", { device: deviceId });
    const nextChallenge = ctx.storage.issueChallenge(deviceId);
    helpers.json(res, {
      accessToken: result.accessToken,
      expiresAt: result.expiresAt,
      ...(nextChallenge ? { refreshChallenge: nextChallenge } : {}),
    });
  }

  function handleListDevices(req: IncomingMessage, res: ServerResponse): void {
    if (!isLocalRequest(req)) {
      helpers.error(res, 403, "Local admin only");
      return;
    }
    const devices = ctx.storage.listDevices().map((device) => ({
      id: device.id,
      name: device.name,
      scope: device.scope,
      createdAt: device.createdAt,
      lastUsedAt: device.lastUsedAt,
      revokedAt: device.revokedAt,
      keyEnrolled: device.publicKey !== undefined,
    }));
    helpers.json(res, { devices });
  }

  function handleRevokeDevice(req: IncomingMessage, res: ServerResponse, deviceId: string): void {
    if (!isLocalRequest(req)) {
      helpers.error(res, 403, "Local admin only");
      return;
    }
    if (!ctx.storage.revokeDevice(deviceId)) {
      helpers.error(res, 404, "Unknown or already-revoked device");
      return;
    }
    log.warn("auth.device_revoked", { device: deviceId });
    ctx.onDeviceRevoked?.(deviceId);
    helpers.json(res, { ok: true });
  }

  function handleAuthFinalize(req: IncomingMessage, res: ServerResponse, finalized: boolean): void {
    if (!isLocalRequest(req)) {
      helpers.error(res, 403, "Local admin only");
      return;
    }
    ctx.storage.setMigrationFinalized(finalized);
    ctx.onMigrationFinalized?.(finalized);
    if (finalized) {
      log.warn("auth.migration_finalized", {});
    } else {
      log.warn("auth.migration_compat_restored", {});
    }
    helpers.json(res, { ok: true, finalized });
  }

  function handleAuthRotate(req: IncomingMessage, res: ServerResponse): void {
    if (!isLocalRequest(req)) {
      helpers.error(res, 403, "Local admin only");
      return;
    }
    ctx.storage.rotateToken();
    // An emergency owner rotation must immediately sever every already-open
    // remote device socket; the cleared device/access-token state alone only
    // affects future upgrades.
    ctx.onOwnerTokenRotated?.();
    log.warn("auth.owner_rotated", {});
    helpers.json(res, { ok: true });
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/pair" && method === "POST") {
      await handlePair(req, res);
      return true;
    }
    if (path === "/auth/migrate" && method === "POST") {
      await handleAuthMigrate(req, res);
      return true;
    }
    if (path === "/auth/challenge" && method === "POST") {
      await handleAuthChallenge(req, res);
      return true;
    }
    if (path === "/auth/refresh" && method === "POST") {
      await handleAuthRefresh(req, res);
      return true;
    }
    if (path === "/auth/devices" && method === "GET") {
      handleListDevices(req, res);
      return true;
    }
    const deviceRevokeMatch = path.match(/^\/auth\/devices\/([^/]+)$/);
    if (deviceRevokeMatch && method === "DELETE") {
      handleRevokeDevice(req, res, decodeURIComponent(deviceRevokeMatch[1]));
      return true;
    }
    if (path === "/auth/finalize" && method === "POST") {
      handleAuthFinalize(req, res, true);
      return true;
    }
    if (path === "/auth/compat" && method === "POST") {
      handleAuthFinalize(req, res, false);
      return true;
    }
    if (path === "/auth/rotate" && method === "POST") {
      handleAuthRotate(req, res);
      return true;
    }
    if (path === "/me" && method === "GET") {
      handleGetMe(res);
      return true;
    }
    if (path === "/server/info" && method === "GET") {
      await handleGetServerInfo(res);
      return true;
    }
    if (path === "/server/provider-quotas" && method === "GET") {
      await handleGetProviderQuotas(res);
      return true;
    }
    // Match /server/stats/daily/YYYY-MM-DD (must come before /server/stats)
    const dailyDetailMatch = path.match(/^\/server\/stats\/daily\/(\d{4}-\d{2}-\d{2})$/);
    if (dailyDetailMatch && method === "GET") {
      handleGetDailyDetail(dailyDetailMatch[1], url, res);
      return true;
    }
    if (path === "/server/stats" && method === "GET") {
      handleGetServerStats(url, res);
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
    if (path === "/server/auto-title" && method === "GET") {
      const config = ctx.storage.getConfig();
      helpers.json(res, config.autoTitle ?? { enabled: false });
      return true;
    }
    if (path === "/server/auto-title" && method === "PUT") {
      const body = await helpers.parseBody<{ enabled?: boolean; model?: string | null }>(req);
      const current = ctx.storage.getConfig().autoTitle ?? { enabled: false };
      const updated = {
        enabled: typeof body.enabled === "boolean" ? body.enabled : current.enabled,
        model:
          typeof body.model === "string" && body.model.trim().length > 0
            ? body.model.trim()
            : body.model === null
              ? undefined
              : current.model,
      };
      ctx.storage.updateConfig({ autoTitle: updated });
      helpers.json(res, updated);
      return true;
    }
    return false;
  };
}

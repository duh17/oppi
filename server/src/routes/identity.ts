import type { IncomingMessage, ServerResponse } from "node:http";
import { hostname } from "node:os";

import { ensureIdentityMaterial, identityConfigForDataDir } from "../security.js";
import { createLogger } from "../logger.js";
import { handleIrohPairingRequest } from "../iroh-pairing.js";
import { EXTENSION_NATIVE_UI_SERVER_CAPABILITIES } from "../extension-ui-contract.js";
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

    const body = await helpers.parseBody<{ pairingToken?: string; clientNodeId?: string }>(req);
    const pairingToken = typeof body.pairingToken === "string" ? body.pairingToken.trim() : "";
    const clientNodeId =
      typeof body.clientNodeId === "string" && body.clientNodeId.trim().length > 0
        ? body.clientNodeId.trim()
        : undefined;

    if (!pairingToken) {
      helpers.error(res, 400, "pairingToken required");
      return;
    }

    const pairing = handleIrohPairingRequest(
      ctx.storage,
      { pairingToken, clientNodeId },
      { transport: "http" },
    );
    if (!pairing.ok) {
      if (pairing.status === 401) {
        recordPairingFailure(source, now);
      }
      helpers.error(res, pairing.status, pairing.error);
      return;
    }

    clearPairingFailures(source);
    helpers.json(res, {
      deviceToken: pairing.deviceToken,
      credentialTransports: pairing.credentialTransports,
    });
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
        dictationStream: config.asr?.sttEndpoint ? { version: 1 } : undefined,
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

  return async ({ method, path, url, req, res }) => {
    if (path === "/pair" && method === "POST") {
      await handlePair(req, res);
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

import { timingSafeEqual } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { hostname } from "node:os";

import { generateInvite } from "../invite.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "../security.js";
import { createLogger } from "../logger.js";
import { normalizeIp, trustConfigFromServerConfig } from "../proxy-config.js";
import { isLocalRequest, requestClientIp, resolveRequestProvenance } from "../request-trust.js";
import { deviceKeyThumbprint, type PairingGrant } from "../device-pairing.js";
import { normalizeDeviceName, parseDevicePublicKey } from "../storage/device-auth.js";
import { inviteHostForTlsMode, proveSameTailscaleUser } from "../tailscale-whois.js";
import { SourceRateLimiter } from "../source-rate-limit.js";
import { EXTENSION_NATIVE_UI_SERVER_CAPABILITIES } from "../extension-ui-contract.js";
import { isDictationStreamEnabled } from "../dictation-types.js";
import { MAX_WORKSPACE_FILE_EDIT_BYTES } from "../file-serving-policy.js";
import { isDeviceAccessPrincipal, type RequestPrincipal } from "../request-principal.js";
import { checkPushRegistration } from "../push/registration.js";
import type { PushRegistrationRequest, WorkspaceFileEditingCapability } from "../types.js";
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
const AUTH_BOOTSTRAP_MAX_BYTES = 16 * 1024;
const CHALLENGE_WINDOW_MS = 60_000;
const CHALLENGE_MAX_PER_WINDOW = 8;
/** Concurrent `tailscale` proofs; taken before spawn so 503/hangs cannot flood. */
const TAILSCALE_PROOF_MAX_CONCURRENT = 2;

const log = createLogger({ base: { component: "route_identity" } });

export function createIdentityRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  const pairingFailuresBySource = new Map<string, number[]>();
  const pairingBlockedUntilBySource = new Map<string, number>();
  const challengeLimiter = new SourceRateLimiter(CHALLENGE_WINDOW_MS, CHALLENGE_MAX_PER_WINDOW);
  let tailscaleProofInFlight = 0;
  function currentTrustConfig(): ReturnType<typeof trustConfigFromServerConfig> {
    const config = typeof ctx.storage.getConfig === "function" ? ctx.storage.getConfig() : {};
    return trustConfigFromServerConfig(config);
  }

  function pairingSourceKey(req: IncomingMessage): string {
    return resolveRequestProvenance(req, currentTrustConfig()).clientIdentity;
  }

  function prunePairingLimiters(now: number): void {
    const staleBefore = now - PAIRING_WINDOW_MS - PAIRING_COOLDOWN_MS;
    for (const [source, failures] of pairingFailuresBySource) {
      const last = failures.at(-1) ?? 0;
      const blockedUntil = pairingBlockedUntilBySource.get(source) ?? 0;
      if (blockedUntil > now) continue;
      if (last < staleBefore) {
        pairingFailuresBySource.delete(source);
        pairingBlockedUntilBySource.delete(source);
      }
    }
  }

  async function parseBootstrapBody<T>(
    req: IncomingMessage,
  ): Promise<{ ok: true; body: T } | { ok: false; status: number; error: string }> {
    try {
      const body = await helpers.parseBody<T>(req, { maxBytes: AUTH_BOOTSTRAP_MAX_BYTES });
      return { ok: true, body };
    } catch (error) {
      const message = error instanceof Error ? error.message : "Invalid JSON";
      if (message.includes("too large")) {
        return { ok: false, status: 413, error: "Request body too large" };
      }
      return { ok: false, status: 400, error: "Invalid JSON" };
    }
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
    prunePairingLimiters(now);
    if (isPairingRateLimited(source, now)) {
      helpers.error(res, 429, "Too many invalid pairing attempts. Try again later.");
      return;
    }

    const parsed = await parseBootstrapBody<{
      pairingToken?: string;
      devicePublicKey?: unknown;
      deviceName?: string;
      credential?: unknown;
    }>(req);
    if (!parsed.ok) {
      helpers.error(res, parsed.status, parsed.error);
      return;
    }
    const body = parsed.body;
    const pairingToken = typeof body.pairingToken === "string" ? body.pairingToken.trim() : "";
    // Without an invite, only a loaded auth.module approver can admit the device.
    if (!pairingToken && !ctx.pairing.customApproverAvailable) {
      helpers.error(res, 400, "pairingToken required");
      return;
    }

    // Pairing issues short-lived at_ credentials bound to a device P-256 key.
    // Old clients without device-key support must update and re-pair.
    if (body.devicePublicKey === undefined) {
      helpers.error(res, 400, "devicePublicKey required");
      return;
    }

    // Checked before any approver runs, so a malformed key never burns the invite.
    const publicKey = parseDevicePublicKey(body.devicePublicKey);
    if (!publicKey) {
      recordPairingFailure(source, now);
      if (pairingToken) helpers.error(res, 401, "Invalid or expired pairing token");
      else helpers.error(res, 400, "Invalid devicePublicKey");
      return;
    }
    const name = normalizeDeviceName(body.deviceName);
    const clientIp = requestClientIp(req, currentTrustConfig());
    let grant: PairingGrant;
    if (pairingToken) {
      const inviteGrant = ctx.pairing.approveInvite(pairingToken, clientIp);
      if (!inviteGrant) {
        recordPairingFailure(source, now);
        helpers.error(res, 401, "Invalid or expired pairing token");
        return;
      }
      grant = inviteGrant;
    } else {
      const decision = await ctx.pairing.approveCustom({
        deviceName: name,
        devicePublicKey: publicKey,
        keyThumbprint: deviceKeyThumbprint(publicKey),
        credential: body.credential,
        ...(clientIp ? { clientIp } : {}),
        headers: req.headers,
      });
      if (!decision.ok) {
        recordPairingFailure(source, now);
        log.warn("auth.custom_pairing_denied", { source });
        helpers.error(res, 403, decision.reason ?? "pairing_denied");
        return;
      }
      grant = decision.grant;
    }

    clearPairingFailures(source);
    const outcome = ctx.pairing.admit({ publicKey, name }, grant);
    switch (outcome.kind) {
      case "enrolled":
        helpers.json(res, outcome.result);
        return;
      case "approval_required":
        helpers.json(
          res,
          {
            status: "approval_required",
            approvalId: outcome.approvalId,
            pendingToken: outcome.pendingToken,
            expiresAt: outcome.expiresAt,
          },
          202,
        );
        return;
      case "busy":
        helpers.error(res, 429, "Too many pending pairing approvals");
        return;
    }
  }

  /** The device waiting for approval polls here; the first poll after approval enrolls it. */
  async function handlePairApprovalStatus(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const source = pairingSourceKey(req);
    const now = Date.now();
    prunePairingLimiters(now);
    if (isPairingRateLimited(source, now)) {
      helpers.error(res, 429, "Too many invalid pairing attempts. Try again later.");
      return;
    }
    const parsed = await parseBootstrapBody<{ approvalId?: unknown; pendingToken?: unknown }>(req);
    if (!parsed.ok) {
      helpers.error(res, parsed.status, parsed.error);
      return;
    }
    const { approvalId, pendingToken } = parsed.body;
    if (typeof approvalId !== "string" || !approvalId || typeof pendingToken !== "string") {
      helpers.error(res, 400, "approvalId and pendingToken required");
      return;
    }
    const status = ctx.pairing.status(approvalId, pendingToken);
    switch (status.kind) {
      case "pending":
        helpers.json(res, { status: "pending", expiresAt: status.expiresAt }, 202);
        return;
      case "enrolled":
        helpers.json(res, status.result);
        return;
      case "denied":
        helpers.error(res, 403, "pairing_denied");
        return;
      case "expired":
        helpers.error(res, 410, "pairing_expired");
        return;
      case "unknown":
        recordPairingFailure(source, now);
        helpers.error(res, 404, "unknown_approval");
        return;
    }
  }

  /** Approve or deny a waiting device. Device credentials only: the owner socket never approves. */
  async function handleSettlePairingApproval(
    req: IncomingMessage,
    res: ServerResponse,
    principal: RequestPrincipal | undefined,
    approvalId: string,
    action: "approve" | "deny",
  ): Promise<void> {
    if (!isDeviceAccessPrincipal(principal)) {
      helpers.error(res, 403, "Pairing approval requires a paired device credential");
      return;
    }
    if (action === "deny") {
      if (!ctx.pairing.deny(approvalId, principal.deviceId)) {
        helpers.error(res, 404, "unknown_approval");
        return;
      }
      helpers.json(res, { ok: true });
      return;
    }
    const body = await helpers.parseBody<{ signature?: unknown }>(req, {
      maxBytes: AUTH_BOOTSTRAP_MAX_BYTES,
    });
    switch (ctx.pairing.approve(approvalId, principal.deviceId, body.signature)) {
      case "approved":
        helpers.json(res, { ok: true });
        return;
      case "bad_signature":
        helpers.error(res, 401, "bad_signature");
        return;
      case "inactive_device":
        helpers.error(res, 403, "Unknown or revoked device");
        return;
      case "not_found":
        helpers.error(res, 404, "unknown_approval");
        return;
    }
  }

  async function handleTailscalePairInvite(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (isLocalRequest(req) || isOwnerBearer(req, ctx.storage.getToken?.())) {
      helpers.error(res, 404, "Not found");
      return;
    }

    const config = ctx.storage.getConfig();
    if (config.publicUrl || config.auth?.tailscalePairing === false) {
      helpers.error(res, 404, "Not found");
      return;
    }
    // Forwarding metadata means the socket peer may be a relay, not the caller.
    if (
      ["forwarded", "x-forwarded-for", "x-forwarded-proto", "x-real-ip", "via"].some(
        (header) => header in req.headers,
      )
    ) {
      helpers.error(res, 403, "Tailscale pairing is not available through a reverse proxy");
      return;
    }
    const provenance = resolveRequestProvenance(req, trustConfigFromServerConfig(config));
    const source = provenance.clientIdentity;
    const now = Date.now();
    prunePairingLimiters(now);
    if (isPairingRateLimited(source, now)) {
      helpers.error(res, 429, "Too many invalid pairing attempts. Try again later.");
      return;
    }

    // Socket-peer whois would mint for every caller behind a same-owner proxy.
    if (provenance.trustedPeer) {
      recordPairingFailure(source, now);
      helpers.error(res, 403, "Tailscale pairing is not available through a reverse proxy");
      return;
    }

    const peerIp = provenance.socketPeer ?? normalizeIp(req.socket?.remoteAddress);
    if (!peerIp) {
      recordPairingFailure(source, now);
      helpers.error(res, 403, "Different Tailscale user");
      return;
    }

    if (tailscaleProofInFlight >= TAILSCALE_PROOF_MAX_CONCURRENT) {
      helpers.error(res, 429, "Too many Tailscale identity checks");
      return;
    }
    tailscaleProofInFlight += 1;
    try {
      const proof = await proveSameTailscaleUser(peerIp);
      if (!proof.ok) {
        if (proof.status === 403 || proof.status === 503) {
          recordPairingFailure(source, now);
        }
        helpers.error(res, proof.status, proof.reason);
        return;
      }

      const tlsMode = config.tls?.mode;
      if (!tlsMode || tlsMode === "disabled") {
        recordPairingFailure(source, now);
        helpers.error(res, 503, "HTTPS pairing requires TLS");
        return;
      }

      const inviteHost = inviteHostForTlsMode(tlsMode, proof);
      if (!inviteHost) {
        recordPairingFailure(source, now);
        helpers.error(
          res,
          503,
          tlsMode === "tailscale"
            ? "Tailscale hostname is unavailable"
            : "Same-user Tailscale pairing requires tls.mode=tailscale",
        );
        return;
      }

      try {
        const invite = generateInvite(
          ctx.storage,
          (override) => override?.trim() || inviteHost,
          shortInviteHostLabel,
          {
            hostOverride: inviteHost,
            pairingTokenTtlMs: 90_000,
            pairingOrigin: { method: "tailscale", source: proof.login },
            ignorePublicUrl: true,
            skipRenewal: true,
          },
        );
        if (invite.scheme !== "https") {
          recordPairingFailure(source, now);
          helpers.error(res, 503, "HTTPS pairing requires TLS");
          return;
        }
        clearPairingFailures(source);
        helpers.json(res, invite);
      } catch (error: unknown) {
        const detail = error instanceof Error ? error.message : String(error);
        recordPairingFailure(source, now);
        helpers.error(res, 503, shortInviteFailureReason(detail));
      }
    } finally {
      if (tailscaleProofInFlight > 0) tailscaleProofInFlight -= 1;
    }
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

    const piCliVersion = typeof ctx.piCliVersion === "string" ? ctx.piCliVersion.trim() : "";
    const update = ctx.serverUpdate?.infoSnapshot();
    helpers.json(res, {
      name: hostname(),
      version: ctx.serverVersion,
      ...(update ? { update } : {}),
      uptime: uptimeSeconds,
      os: process.platform,
      arch: process.arch,
      hostname: hostname(),
      nodeVersion: process.version,
      piVersion: ctx.piVersion,
      ...(piCliVersion && piCliVersion !== "unknown" ? { piCliVersion } : {}),
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
        currentFiles: { version: 1 },
        workspaceFileEditing: {
          version: 1,
          maxBytes: MAX_WORKSPACE_FILE_EDIT_BYTES,
        } satisfies WorkspaceFileEditingCapability,
        appEventStream: { version: 1 },
        dictationStream: isDictationStreamEnabled(config.asr) ? { version: 1 } : undefined,
        // Create requests may ask for engine "durable" (experimental.serverDurable).
        durableSessions: ctx.sessions.durableSessionsAvailable() ? { version: 1 } : undefined,
        // Experimental: `attach` on a durable session's focused stream sends snapshot/update.
        conversationStream: ctx.sessions.conversationStreamAvailable() ? { version: 1 } : undefined,
        desktopLiveView: config.experimental?.desktopLiveView === true ? { version: 1 } : undefined,
        extensionNativeUI: {
          version: 1,
          capabilities: [...EXTENSION_NATIVE_UI_SERVER_CAPABILITIES],
        },
        // Relay mode: paired apps that opt in register with this relay, then PUT
        // /me/push-registration (protocol/push/spec.md, section 5).
        pushNotifications: pushRelayCapability(),
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

  function pushRelayCapability(): { version: 1; relay: string } | undefined {
    const primary = ctx.push?.sender.relays()?.[0];
    return primary ? { version: 1, relay: primary } : undefined;
  }

  /**
   * The calling paired device's push key and relay send token, signed by its device key.
   * Revoking the device removes the registration.
   */
  async function handlePutPushRegistration(
    req: IncomingMessage,
    res: ServerResponse,
    principal: RequestPrincipal | undefined,
  ): Promise<void> {
    if (!isDeviceAccessPrincipal(principal)) {
      helpers.error(res, 403, "Push registration requires a paired device credential");
      return;
    }
    const push = ctx.push;
    const primaryRelay = push?.sender.relays()?.[0];
    if (!push || !primaryRelay) {
      helpers.error(res, 409, "push_disabled");
      return;
    }
    const device = ctx.storage
      .listDevices()
      .find((item) => item.id === principal.deviceId && item.revokedAt === undefined);
    if (!device) {
      helpers.error(res, 403, "Unknown or revoked device");
      return;
    }
    const body =
      await helpers.parseBody<Partial<Record<keyof PushRegistrationRequest, unknown>>>(req);
    const check = checkPushRegistration({
      body,
      deviceId: device.id,
      devicePublicKey: device.publicKey,
      serverFingerprint: push.serverFingerprint,
      primaryRelay,
      now: Date.now(),
    });
    if (!check.ok) {
      log.warn("identity.push.registration_rejected", { status: check.status, error: check.error });
      helpers.error(res, check.status, check.error);
      return;
    }

    const replaced = ctx.storage.setPushRegistration({
      deviceId: device.id,
      keyId: check.keyId,
      publicKey: check.publicKey,
      sendToken: check.sendToken,
    });
    if (replaced === false) {
      helpers.error(res, 403, "Unknown or revoked device");
      return;
    }
    if (replaced) push.sender.releasePermission(replaced);
    log.info("identity.push.registered", { device: device.id });
    helpers.json(res, { serverPublicKey: push.serverPublicKey, keyId: check.keyId });
  }

  function handleDeletePushRegistration(
    res: ServerResponse,
    principal: RequestPrincipal | undefined,
  ): void {
    if (!isDeviceAccessPrincipal(principal)) {
      helpers.error(res, 403, "Push registration requires a paired device credential");
      return;
    }
    const removed = ctx.storage.removePushRegistration(principal.deviceId);
    if (removed) ctx.push?.sender.releasePermission(removed);
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

  async function handleAuthChallenge(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const source = pairingSourceKey(req);
    const now = Date.now();
    prunePairingLimiters(now);
    challengeLimiter.prune(now);
    const parsed = await parseBootstrapBody<{ deviceId?: string }>(req);
    if (!parsed.ok) {
      helpers.error(res, parsed.status, parsed.error);
      return;
    }
    const deviceId = typeof parsed.body.deviceId === "string" ? parsed.body.deviceId.trim() : "";
    if (!deviceId) {
      helpers.error(res, 400, "deviceId required");
      return;
    }
    // Per source only: a per-device key would let anyone who knows a device id fill it and
    // block that device's own refresh.
    if (challengeLimiter.tooMany(`ip:${source}`, now)) {
      helpers.error(res, 429, "Too many challenge requests");
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
    const parsed = await parseBootstrapBody<{
      deviceId?: string;
      nonce?: string;
      signature?: unknown;
    }>(req);
    if (!parsed.ok) {
      helpers.error(res, parsed.status, parsed.error);
      return;
    }
    const body = parsed.body;
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

    log.debug("auth.refresh_succeeded", { device: deviceId });
    const nextChallenge = ctx.storage.issueChallenge(deviceId);
    helpers.json(res, {
      accessToken: result.accessToken,
      expiresAt: result.expiresAt,
      ...(nextChallenge ? { refreshChallenge: nextChallenge } : {}),
    });
  }

  function handleListDevices(_req: IncomingMessage, res: ServerResponse): void {
    const devices = ctx.storage.listDevices().map((device) => ({
      id: device.id,
      name: device.name,
      scope: device.scope,
      createdAt: device.createdAt,
      lastUsedAt: device.lastUsedAt,
      revokedAt: device.revokedAt,
      keyEnrolled: device.publicKey !== undefined,
      ...(device.pairing
        ? {
            pairingMethod: device.pairing.method,
            ...(device.pairing.source ? { pairingSource: device.pairing.source } : {}),
            ...(device.pairing.approvedByDeviceId
              ? { approvedByDeviceId: device.pairing.approvedByDeviceId }
              : {}),
          }
        : {}),
    }));
    helpers.json(res, { devices });
  }

  function handleRevokeDevice(_req: IncomingMessage, res: ServerResponse, deviceId: string): void {
    const pushRegistration = ctx.push
      ? ctx.storage.getPushRegistrations().find((entry) => entry.deviceId === deviceId)
      : undefined;
    // Removes the device's push registration in the same write.
    if (!ctx.storage.revokeDevice(deviceId)) {
      helpers.error(res, 404, "Unknown or already-revoked device");
      return;
    }
    if (pushRegistration) ctx.push?.sender.releasePermission(pushRegistration);
    log.warn("auth.device_revoked", { device: deviceId });
    ctx.onDeviceRevoked?.(deviceId);
    helpers.json(res, { ok: true });
  }

  function handleAuthRotate(req: IncomingMessage, res: ServerResponse): void {
    if (!isLocalRequest(req)) {
      helpers.error(res, 403, "Local admin only");
      return;
    }
    const pushRegistrations = ctx.push ? ctx.storage.getPushRegistrations() : [];
    // Revokes every device and removes their push registrations.
    ctx.storage.rotateToken();
    for (const registration of pushRegistrations) ctx.push?.sender.releasePermission(registration);
    // An emergency owner rotation must immediately sever every already-open
    // remote device socket; the cleared device/access-token state alone only
    // affects future upgrades.
    ctx.onOwnerTokenRotated?.();
    log.warn("auth.owner_rotated", {});
    helpers.json(res, { ok: true });
  }

  return async ({ method, path, url, req, res, principal }) => {
    if (path === "/pair/tailscale" && method === "POST") {
      await handleTailscalePairInvite(req, res);
      return true;
    }
    if (path === "/pair" && method === "POST") {
      await handlePair(req, res);
      return true;
    }
    if (path === "/pair/approval-status" && method === "POST") {
      await handlePairApprovalStatus(req, res);
      return true;
    }
    if (path === "/auth/pairing-approvals" && method === "GET") {
      helpers.json(res, { approvals: ctx.pairing.list() });
      return true;
    }
    const approvalMatch = path.match(/^\/auth\/pairing-approvals\/([^/]+)\/(approve|deny)$/);
    if (approvalMatch && method === "POST") {
      await handleSettlePairingApproval(
        req,
        res,
        principal,
        decodeURIComponent(approvalMatch[1]),
        approvalMatch[2] as "approve" | "deny",
      );
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
    if (path === "/me/push-registration" && method === "PUT") {
      await handlePutPushRegistration(req, res, principal);
      return true;
    }
    if (path === "/me/push-registration" && method === "DELETE") {
      handleDeletePushRegistration(res, principal);
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

function shortInviteHostLabel(host: string): string {
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host) || host.includes(":")) return host;
  return host.split(".")[0] || host;
}

function shortInviteFailureReason(detail: string): string {
  const trimmed = detail.trim();
  if (/certificate|cert/i.test(trimmed)) return "Tailscale certificate is unavailable";
  if (/pairing host|ts\.net/i.test(trimmed)) return trimmed.slice(0, 160);
  if (trimmed) return trimmed.slice(0, 160);
  return "Could not issue a pairing invite";
}

function isOwnerBearer(req: IncomingMessage, ownerToken: string | undefined): boolean {
  if (!ownerToken) return false;
  const auth = req.headers?.authorization;
  if (typeof auth !== "string" || !auth.startsWith("Bearer ")) return false;
  const candidate = auth.slice(7);
  if (!candidate) return false;
  const expected = Buffer.from(ownerToken, "utf8");
  const actual = Buffer.from(candidate, "utf8");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

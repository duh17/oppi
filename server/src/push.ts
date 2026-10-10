/**
 * APNs push notification sender.
 *
 * Token-based auth (.p8 key) with automatic JWT refresh. Each token carries its APNs
 * environment, and the client keeps one persistent HTTP/2 connection per environment
 * host, so sandbox (Xcode) and production (TestFlight/App Store) tokens can be mixed.
 *
 * No-op when not configured — server works fine without push.
 */

import { connect as http2Connect, type ClientHttp2Session } from "node:http2";
import { createPrivateKey, createSign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import { createLogger } from "./logger.js";
import type { APNsEnvironment, ProgramStatusKind, PushDeviceToken } from "./types.js";

// ─── Config ───

export interface APNsConfig {
  /** Path to the .p8 key file from Apple Developer Portal */
  keyPath: string;
  /** Key ID from Apple Developer Portal */
  keyId: string;
  /** Team ID from Apple Developer Portal */
  teamId: string;
  /** App bundle ID (used as APNs topic) */
  bundleId: string;
}

/** Where one push goes: the token and the APNs host that issued it. */
export type PushTarget = Pick<PushDeviceToken, "token" | "environment">;

export interface PushClientOptions {
  metrics?: ServerMetricCollector;
  /** APNs says this token can never be delivered again; the owner drops it. */
  onTokenRejected?: (token: string, reason: string) => void;
}

// ─── Push Payloads ───

export interface SessionEventPushPayload {
  sessionId: string;
  sessionName?: string;
  event: "ended" | "error" | "blocked" | "done";
  reason: string;
  /** Blocked pushes only: why the session waits. */
  kind?: ProgramStatusKind;
}

function sessionEventPresentation(payload: SessionEventPushPayload): {
  title: string;
  category: string;
  urgent: boolean;
} {
  switch (payload.event) {
    case "ended":
      return { title: "Session Ended", category: "SESSION_DONE", urgent: false };
    case "done":
      return { title: "Session Done", category: "SESSION_DONE", urgent: false };
    case "error":
      return { title: "Session Error", category: "SESSION_ERROR", urgent: true };
    case "blocked":
      return {
        title:
          payload.kind === "permission"
            ? "Needs Approval"
            : payload.kind === "auth"
              ? "Sign-in Needed"
              : "Question",
        category: "SESSION_BLOCKED",
        urgent: true,
      };
  }
}

// ─── APNs Client ───

const APNS_HOSTS: Record<APNsEnvironment, string> = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
};

/**
 * Responses that retire a token: 410 (the app is gone from the device, or the token
 * expired), and 400 for a token that is malformed, from the other environment, or for
 * another topic. Other failures (auth, throttling, server errors) leave the token alone.
 */
function isRetiredToken(status: number, reason: string): boolean {
  if (status === 410) return true;
  return status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic");
}

// JWT is valid for 1 hour; refresh at 50 minutes to avoid edge cases.
const JWT_REFRESH_MS = 50 * 60 * 1000;

const log = createLogger({ base: { component: "push" } });

export function redactTokenForLog(token: string): string {
  return `<redacted:${token.length} chars>`;
}

export class APNsClient {
  readonly enabled = true;
  private config: APNsConfig;
  private privateKey: KeyObject;
  private metrics?: ServerMetricCollector;
  private onTokenRejected?: (token: string, reason: string) => void;

  private readonly openConnections = new Map<APNsEnvironment, ClientHttp2Session>();
  private readonly pendingConnections = new Map<APNsEnvironment, Promise<ClientHttp2Session>>();
  private jwt: string = "";
  private jwtExpiresAt = 0;

  constructor(config: APNsConfig, options: PushClientOptions = {}) {
    this.config = config;
    this.metrics = options.metrics;
    this.onTokenRejected = options.onTokenRejected;

    const keyPem = readFileSync(config.keyPath, "utf-8");
    this.privateKey = createPrivateKey(keyPem);
  }

  // ─── Public API ───

  /**
   * Send a session event push (ended, error, blocked, done).
   * Blocked and error alert immediately; ended and done are passive.
   */
  async sendSessionEventPush(
    target: PushTarget,
    payload: SessionEventPushPayload,
  ): Promise<boolean> {
    const presentation = sessionEventPresentation(payload);

    const apnsPayload = {
      aps: {
        alert: {
          title: presentation.title,
          subtitle: payload.sessionName || payload.sessionId,
          body: payload.reason,
        },
        category: presentation.category,
        "interruption-level": presentation.urgent ? "active" : "passive",
        sound: presentation.urgent ? "default" : undefined,
      },
      sessionId: payload.sessionId,
      event: payload.event,
      ...(payload.kind ? { kind: payload.kind } : {}),
    };

    return this.send(target, apnsPayload, {
      pushType: "alert",
      priority: presentation.urgent ? 10 : 5,
    });
  }

  /**
   * Send a Live Activity update push.
   */
  async sendLiveActivityUpdate(
    target: PushTarget,
    contentState: Record<string, unknown>,
    staleDate?: number,
    priority: 5 | 10 = 5,
  ): Promise<boolean> {
    const apnsPayload = {
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: "update",
        "content-state": contentState,
        "stale-date": staleDate ? Math.floor(staleDate / 1000) : undefined,
        "dismissal-date": undefined,
      },
    };

    return this.send(target, apnsPayload, {
      pushType: "liveactivity",
      priority,
      topic: `${this.config.bundleId}.push-type.liveactivity`,
    });
  }

  /**
   * End a Live Activity via push.
   */
  async endLiveActivity(
    target: PushTarget,
    contentState: Record<string, unknown>,
    dismissalDate?: number,
    priority: 5 | 10 = 10,
  ): Promise<boolean> {
    const apnsPayload = {
      aps: {
        timestamp: Math.floor(Date.now() / 1000),
        event: "end",
        "content-state": contentState,
        "dismissal-date": dismissalDate
          ? Math.floor(dismissalDate / 1000)
          : Math.floor(Date.now() / 1000) + 300, // dismiss after 5 min
      },
    };

    return this.send(target, apnsPayload, {
      pushType: "liveactivity",
      priority,
      topic: `${this.config.bundleId}.push-type.liveactivity`,
    });
  }

  /**
   * Close the HTTP/2 connections.
   */
  shutdown(): void {
    for (const connection of this.openConnections.values()) connection.close();
    this.openConnections.clear();
  }

  // ─── Private ───

  private async send(
    target: PushTarget,
    payload: Record<string, unknown>,
    opts: { pushType: string; priority: number; expiration?: number; topic?: string },
  ): Promise<boolean> {
    const sendStart = Date.now();
    const deviceToken = target.token;
    const conn = await this.getConnection(target.environment);
    const jwt = this.getJWT();
    const topic = opts.topic || this.config.bundleId;

    const headers: Record<string, string | number> = {
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": opts.pushType,
      "apns-priority": opts.priority,
    };

    if (opts.expiration !== undefined) {
      headers["apns-expiration"] = opts.expiration;
    }

    const body = JSON.stringify(payload);

    return new Promise((resolve) => {
      const req = conn.request(headers);

      let responseStatus = 0;
      let responseBody = "";

      req.on("response", (headers) => {
        responseStatus = headers[":status"] as number;
      });

      req.setEncoding("utf8");
      req.on("data", (chunk: string) => {
        responseBody += chunk;
      });

      req.on("end", () => {
        const pushType = opts.pushType;
        if (this.metrics) {
          this.metrics.record("server.push_send_ms", Date.now() - sendStart, {
            push_type: pushType,
          });
          this.metrics.record("server.push_result", 1, {
            push_type: pushType,
            success: responseStatus === 200 ? "true" : "false",
          });
        }
        if (responseStatus === 200) {
          resolve(true);
        } else {
          let reason = responseBody;
          try {
            const parsed = JSON.parse(responseBody);
            reason = parsed.reason || responseBody;
          } catch {}
          log.error("apns.push.failed", {
            status: responseStatus,
            reason,
            environment: target.environment,
            deviceToken: redactTokenForLog(deviceToken),
          });

          if (isRetiredToken(responseStatus, reason)) {
            log.warn("apns.device_token_retired", {
              status: responseStatus,
              reason,
              environment: target.environment,
              deviceToken: redactTokenForLog(deviceToken),
            });
            this.onTokenRejected?.(deviceToken, reason);
          }

          resolve(false);
        }
      });

      req.on("error", (err) => {
        log.error("apns.request.error", { error: err.message });
        if (this.metrics) {
          this.metrics.record("server.push_send_ms", Date.now() - sendStart, {
            push_type: opts.pushType,
          });
          this.metrics.record("server.push_result", 1, {
            push_type: opts.pushType,
            success: "false",
          });
        }
        resolve(false);
      });

      req.end(body);
    });
  }

  /** One shared connection per environment host; concurrent sends wait on the same connect. */
  private async getConnection(environment: APNsEnvironment): Promise<ClientHttp2Session> {
    const open = this.openConnections.get(environment);
    if (open && !open.closed && !open.destroyed) {
      return open;
    }
    return this.pendingConnections.get(environment) ?? this.connect(environment);
  }

  private connect(environment: APNsEnvironment): Promise<ClientHttp2Session> {
    const host = APNS_HOSTS[environment];
    const pending = new Promise<ClientHttp2Session>((resolve, reject) => {
      const conn = http2Connect(`https://${host}`);
      const forget = (): void => {
        if (this.openConnections.get(environment) === conn)
          this.openConnections.delete(environment);
      };

      conn.on("connect", () => {
        this.openConnections.set(environment, conn);
        resolve(conn);
      });

      conn.on("error", (err) => {
        log.error("apns.connection.error", { host, error: err.message });
        forget();
        reject(err);
      });

      conn.on("goaway", () => {
        log.warn("apns.connection_goaway", { host });
        forget();
      });

      conn.on("close", forget);
    });
    this.pendingConnections.set(environment, pending);
    // Settled either way (including a synchronous connect throw): the next send starts fresh.
    const settle = (): void => {
      if (this.pendingConnections.get(environment) === pending) {
        this.pendingConnections.delete(environment);
      }
    };
    pending.then(settle, settle);
    return pending;
  }

  private getJWT(): string {
    const now = Date.now();
    if (this.jwt && now < this.jwtExpiresAt) {
      return this.jwt;
    }

    const iat = Math.floor(now / 1000);
    const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: this.config.keyId })).toString(
      "base64url",
    );

    const claims = Buffer.from(JSON.stringify({ iss: this.config.teamId, iat })).toString(
      "base64url",
    );

    const signingInput = `${header}.${claims}`;

    const signer = createSign("SHA256");
    signer.update(signingInput);
    const signature = signer.sign({ key: this.privateKey, dsaEncoding: "ieee-p1363" }, "base64url");

    this.jwt = `${signingInput}.${signature}`;
    this.jwtExpiresAt = now + JWT_REFRESH_MS;

    return this.jwt;
  }
}

// ─── No-op Client ───

/**
 * Stub client used when APNs is not configured.
 * All sends are silent no-ops.
 */
export class NoopAPNsClient {
  readonly enabled = false;
  async sendSessionEventPush(
    _target: PushTarget,
    _payload: SessionEventPushPayload,
  ): Promise<boolean> {
    return false;
  }
  async sendLiveActivityUpdate(
    _target: PushTarget,
    _contentState: Record<string, unknown>,
    _staleDate?: number,
    _priority: 5 | 10 = 5,
  ): Promise<boolean> {
    return false;
  }
  async endLiveActivity(
    _target: PushTarget,
    _contentState: Record<string, unknown>,
    _dismissalDate?: number,
    _priority: 5 | 10 = 10,
  ): Promise<boolean> {
    return false;
  }
  shutdown(): void {}
}

// ─── Factory ───

export type PushClient = APNsClient | NoopAPNsClient;

export function createPushClient(config?: APNsConfig, options: PushClientOptions = {}): PushClient {
  if (!config) {
    log.info("apns.not_configured", {
      enabled: false,
      reason: "not_configured",
    });
    return new NoopAPNsClient();
  }

  try {
    const client = new APNsClient(config, options);
    log.info("apns.configured", {
      topic: config.bundleId,
      enabled: true,
    });
    return client;
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    log.error("apns.setup.failed", {
      error: message,
      pushDisabled: true,
    });
    return new NoopAPNsClient();
  }
}

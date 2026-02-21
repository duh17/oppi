/**
 * APNs push notification sender.
 *
 * Uses HTTP/2 persistent connection to Apple's Push Notification service.
 * Token-based auth (.p8 key), connection reuse, automatic JWT refresh.
 *
 * No-op when not configured — server works fine without push.
 */

import { connect as http2Connect, type ClientHttp2Session } from "node:http2";
import { createPrivateKey, createSign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";

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
  /** "production" or "sandbox" (default: "sandbox") */
  environment?: "production" | "sandbox";
}

// ─── Push Payloads ───

export interface PermissionPushPayload {
  permissionId: string;
  sessionId: string;
  sessionName?: string;
  tool: string;
  displaySummary: string;
  reason: string;
  timeoutAt: number;
  expires?: boolean;
}

export interface SessionEventPushPayload {
  sessionId: string;
  sessionName?: string;
  event: "ended" | "error";
  reason: string;
}

// ─── APNs Client ───

const APNS_HOSTS = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
} as const;

// JWT is valid for 1 hour; refresh at 50 minutes to avoid edge cases.
const JWT_REFRESH_MS = 50 * 60 * 1000;

export function redactTokenForLog(token: string): string {
  return `<redacted:${token.length} chars>`;
}

export class APNsClient {
  private config: APNsConfig;
  private privateKey: KeyObject;
  private host: string;

  private connection: ClientHttp2Session | null = null;
  private jwt: string = "";
  private jwtExpiresAt = 0;

  constructor(config: APNsConfig) {
    this.config = config;
    this.host = APNS_HOSTS[config.environment || "sandbox"];

    const keyPem = readFileSync(config.keyPath, "utf-8");
    this.privateKey = createPrivateKey(keyPem);
  }

  // ─── Public API ───

  /**
   * Send a permission request push notification.
   * Time-sensitive, with Allow/Deny actions.
   */
  async sendPermissionPush(deviceToken: string, payload: PermissionPushPayload): Promise<boolean> {
    const apnsPayload = {
      aps: {
        alert: {
          title: "Permission Request",
          subtitle: payload.sessionName || payload.sessionId,
          body: `${payload.tool}: ${payload.displaySummary}`,
        },
        category: "PERMISSION_REQUEST",
        "interruption-level": "time-sensitive",
        "relevance-score": 0.9,
        sound: "default",
      },
      permissionId: payload.permissionId,
      sessionId: payload.sessionId,
      tool: payload.tool,
      summary: payload.displaySummary,
      timeoutAt: payload.timeoutAt,
    };

    return this.send(deviceToken, apnsPayload, {
      pushType: "alert",
      priority: 10,
      expiration: payload.expires === false ? undefined : Math.floor(payload.timeoutAt / 1000),
    });
  }

  /**
   * Send a session event push (ended, error).
   * Not time-sensitive.
   */
  async sendSessionEventPush(
    deviceToken: string,
    payload: SessionEventPushPayload,
  ): Promise<boolean> {
    const title = payload.event === "ended" ? "Session Ended" : "Session Error";
    const category = payload.event === "ended" ? "SESSION_DONE" : "SESSION_ERROR";

    const apnsPayload = {
      aps: {
        alert: {
          title,
          subtitle: payload.sessionName || payload.sessionId,
          body: payload.reason,
        },
        category,
        "interruption-level": payload.event === "error" ? "active" : "passive",
        sound: payload.event === "error" ? "default" : undefined,
      },
      sessionId: payload.sessionId,
      event: payload.event,
    };

    return this.send(deviceToken, apnsPayload, {
      pushType: "alert",
      priority: payload.event === "error" ? 10 : 5,
    });
  }

  /**
   * Send a Live Activity update push.
   */
  async sendLiveActivityUpdate(
    pushToken: string,
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

    return this.send(pushToken, apnsPayload, {
      pushType: "liveactivity",
      priority,
      topic: `${this.config.bundleId}.push-type.liveactivity`,
    });
  }

  /**
   * End a Live Activity via push.
   */
  async endLiveActivity(
    pushToken: string,
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

    return this.send(pushToken, apnsPayload, {
      pushType: "liveactivity",
      priority,
      topic: `${this.config.bundleId}.push-type.liveactivity`,
    });
  }

  /**
   * Close the HTTP/2 connection.
   */
  shutdown(): void {
    if (this.connection) {
      this.connection.close();
      this.connection = null;
    }
  }

  // ─── Private ───

  private async send(
    deviceToken: string,
    payload: Record<string, unknown>,
    opts: { pushType: string; priority: number; expiration?: number; topic?: string },
  ): Promise<boolean> {
    const conn = await this.getConnection();
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
        if (responseStatus === 200) {
          resolve(true);
        } else {
          let reason = responseBody;
          try {
            const parsed = JSON.parse(responseBody);
            reason = parsed.reason || responseBody;
          } catch {}
          console.error(
            `[apns] Push failed (${responseStatus}): ${reason} [token: ${redactTokenForLog(deviceToken)}]`,
          );

          // Handle specific APNs errors
          if (responseStatus === 410 || reason === "Unregistered") {
            console.warn(
              `[apns] Device token expired/unregistered: ${redactTokenForLog(deviceToken)}`,
            );
            // Caller should remove this token
          }

          resolve(false);
        }
      });

      req.on("error", (err) => {
        console.error("[apns] Request error:", err.message);
        resolve(false);
      });

      req.end(body);
    });
  }

  private async getConnection(): Promise<ClientHttp2Session> {
    if (this.connection && !this.connection.closed && !this.connection.destroyed) {
      return this.connection;
    }

    return new Promise((resolve, reject) => {
      const conn = http2Connect(`https://${this.host}`);

      conn.on("connect", () => {
        this.connection = conn;
        resolve(conn);
      });

      conn.on("error", (err) => {
        console.error("[apns] Connection error:", err.message);
        this.connection = null;
        reject(err);
      });

      conn.on("goaway", () => {
        console.warn("[apns] Server sent GOAWAY, will reconnect on next push");
        this.connection = null;
      });

      conn.on("close", () => {
        this.connection = null;
      });
    });
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
  async sendPermissionPush(
    _deviceToken: string,
    _payload: PermissionPushPayload,
  ): Promise<boolean> {
    return false;
  }
  async sendSessionEventPush(
    _deviceToken: string,
    _payload: SessionEventPushPayload,
  ): Promise<boolean> {
    return false;
  }
  async sendLiveActivityUpdate(
    _pushToken: string,
    _contentState: Record<string, unknown>,
    _staleDate?: number,
    _priority: 5 | 10 = 5,
  ): Promise<boolean> {
    return false;
  }
  async endLiveActivity(
    _pushToken: string,
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

export function createPushClient(config?: APNsConfig): PushClient {
  if (!config) {
    console.log("📱 APNs not configured — push notifications disabled");
    return new NoopAPNsClient();
  }

  try {
    const client = new APNsClient(config);
    console.log(
      `📱 APNs configured (${config.environment || "sandbox"}) — push notifications enabled`,
    );
    return client;
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`📱 APNs setup failed: ${message} — push notifications disabled`);
    return new NoopAPNsClient();
  }
}

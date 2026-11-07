/**
 * Access lifetime of live device WebSockets, and its in-band renewal (`auth_renew`,
 * `capabilities.streamAuthRenewal`).
 *
 * A socket opened with an expiring device token closes `CLOCK_SKEW_MS` after that token
 * expires, unless it is renewed first. `SocketAccessDeadlines` owns those deadlines; each
 * stream mux only recognizes the `auth_renew` frame, ahead of its own message set, and sends
 * the answer back on the same socket.
 */
import type { WebSocket } from "ws";
import { createLogger } from "./logger.js";
import { isDeviceAccessPrincipal, type RequestPrincipal } from "./request-principal.js";
import { CLOCK_SKEW_MS, type AccessTokenValidation } from "./storage/device-auth.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";
import type {
  StreamAuthRenewMessage,
  StreamAuthRenewRejection,
  StreamAuthRenewResultMessage,
} from "./types.js";

const log = createLogger({ base: { component: "stream_auth_renewal" } });

/** The live streams that take `auth_renew`; also their `stream` telemetry tag. */
export type RenewableStream = "session" | "app_events" | "dictation";

export type RenewStreamAccess = (
  ws: WebSocket,
  token: string,
  stream: RenewableStream,
) => StreamAuthRenewResultMessage;

/** The answer when no renewal owner is wired in: nothing on this socket expires. */
export const NOT_RENEWABLE: StreamAuthRenewResultMessage = {
  type: "auth_renew_result",
  ok: false,
  reason: "not_renewable",
};

const AUTH_RENEW: StreamAuthRenewMessage["type"] = "auth_renew";

/**
 * The token an `auth_renew` frame carries, or `undefined` for any other frame. A missing or
 * non-string token comes back as `""`, which validation refuses as `unknown_token`.
 */
export function authRenewToken(record: Record<string, unknown>): string | undefined {
  if (record["type"] !== AUTH_RENEW) return undefined;
  const token = record["token"];
  return typeof token === "string" ? token : "";
}

export interface SocketAccessDeadlinesDeps {
  /** Each open socket's principal, shared with the server: revocation and presence read it. */
  principals: Map<WebSocket, RequestPrincipal>;
  validateAccessToken: (token: string) => AccessTokenValidation;
  /**
   * The socket's deadline passed: close it, or hold it open (a dictation take or a Live Voice
   * call finishing) and return how long until the next look.
   */
  expire: (ws: WebSocket) => number | undefined;
  /** A renewal moved the socket's deadline; the dictation mux checks new takes against it. */
  extended: (ws: WebSocket, expiresAt: number) => void;
  metrics: ServerTelemetry;
}

export class SocketAccessDeadlines {
  private readonly timers = new Map<WebSocket, ReturnType<typeof setTimeout>>();

  constructor(private readonly deps: SocketAccessDeadlinesDeps) {}

  /** Arm the deadline of a newly opened socket whose principal holds an expiring token. */
  track(ws: WebSocket): void {
    const principal = this.deps.principals.get(ws);
    if (isDeviceAccessPrincipal(principal) && principal.expiresAt) {
      this.scheduleDeadline(ws, principal.expiresAt);
    }
  }

  forget(ws: WebSocket): void {
    const timer = this.timers.get(ws);
    if (timer) clearTimeout(timer);
    this.timers.delete(ws);
  }

  clear(): void {
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
  }

  /**
   * `auth_renew`. A token valid at this moment, exactly as the upgrade checks it, and of the
   * socket's own device moves the socket's deadline to that token's: the socket then lasts as
   * long as a fresh connection with that token would, and never shorter than before. A refusal
   * changes nothing, so the socket still closes at its old deadline. A socket already past its
   * deadline (held open only to finish a dictation take or a Live Voice call) is not revived.
   * Revocation and owner-credential rotation still close it at once: they read `principals`,
   * which keeps the device.
   */
  renew(ws: WebSocket, token: string, stream: RenewableStream): StreamAuthRenewResultMessage {
    const principal = this.deps.principals.get(ws);
    const refuse = (
      reason: StreamAuthRenewRejection,
      deviceId?: string,
    ): StreamAuthRenewResultMessage => {
      this.deps.metrics.record("server.ws_auth_renew", {}, { stream, result: "rejected", reason });
      log.warn("ws.auth_renew_rejected", {
        stream,
        reason,
        ...(deviceId ? { device: deviceId } : {}),
      });
      return { type: "auth_renew_result", ok: false, reason };
    };
    if (!isDeviceAccessPrincipal(principal) || principal.expiresAt === undefined) {
      return refuse("not_renewable");
    }
    if (Date.now() - CLOCK_SKEW_MS > principal.expiresAt) {
      return refuse("past_deadline", principal.deviceId);
    }
    const access = this.deps.validateAccessToken(token);
    if (!access.ok) return refuse(access.code, principal.deviceId);
    if (access.deviceId !== principal.deviceId) return refuse("wrong_device", principal.deviceId);

    const expiresAt = Math.max(access.expiresAt, principal.expiresAt);
    if (expiresAt !== principal.expiresAt) {
      this.deps.principals.set(ws, { ...principal, expiresAt });
      this.scheduleDeadline(ws, expiresAt);
      this.deps.extended(ws, expiresAt);
    }
    this.deps.metrics.record("server.ws_auth_renew", {}, { stream, result: "renewed" });
    log.info("ws.auth_renewed", { stream, device: principal.deviceId, expiresAt });
    return { type: "auth_renew_result", ok: true, expiresAt };
  }

  private scheduleDeadline(ws: WebSocket, expiresAt: number): void {
    this.lookAfter(ws, Math.max(0, expiresAt + CLOCK_SKEW_MS - Date.now()));
  }

  private lookAfter(ws: WebSocket, delay: number): void {
    this.forget(ws);
    const timer = setTimeout(() => {
      this.timers.delete(ws);
      const recheck = this.deps.expire(ws);
      if (recheck !== undefined) this.lookAfter(ws, recheck);
    }, delay);
    this.timers.set(ws, timer);
  }
}

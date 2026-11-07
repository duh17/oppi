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
import type { AuthGateRequest, AuthGateResult } from "./auth-module.js";
import { safeErrorMessage } from "./log-utils.js";
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
) => Promise<StreamAuthRenewResultMessage>;

/** The answer when no renewal owner is wired in: nothing on this socket expires. */
const NOT_RENEWABLE: StreamAuthRenewResultMessage = {
  type: "auth_renew_result",
  ok: false,
  reason: "not_renewable",
};

/**
 * Renewals one socket may ask for in a minute. The app sends one per token lifetime and
 * retries a refusal every 10 s, far below this. Past it, frames are refused without a token
 * lookup or a gate call, and only the first refusal of the minute is logged.
 */
const RENEWALS_PER_MINUTE = 12;
const RENEWAL_WINDOW_MS = 60_000;

/** Larger than any `auth_renew` frame; a bigger text frame is not one and is never parsed. */
export const MAX_AUTH_RENEW_FRAME_BYTES = 1024;

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

/** Answer one `auth_renew` frame on its socket. A renewal that throws is logged, unanswered. */
export function answerAuthRenew(
  renew: RenewStreamAccess | undefined,
  ws: WebSocket,
  token: string,
  stream: RenewableStream,
  send: (message: StreamAuthRenewResultMessage) => void,
): void {
  if (!renew) {
    send(NOT_RENEWABLE);
    return;
  }
  renew(ws, token, stream).then(send, (error: unknown) => {
    log.error("ws.auth_renew_failed", { stream, error: safeErrorMessage(error) });
  });
}

type RenewablePrincipal = Extract<RequestPrincipal, { kind: "device" }> & { expiresAt: number };

export interface SocketAccessDeadlinesDeps {
  /** Each open socket's principal, shared with the server: revocation and presence read it. */
  principals: Map<WebSocket, RequestPrincipal>;
  validateAccessToken: (token: string) => AccessTokenValidation;
  /** The `auth.module` gate, re-run on renewal with the request that admitted the socket. */
  gate: (request: AuthGateRequest) => Promise<AuthGateResult>;
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
  /** The `auth.module` gate request each network socket was admitted with. */
  private readonly gateRequests = new Map<WebSocket, AuthGateRequest>();
  /**
   * Sockets whose deadline timer has fired. Such a socket is past its deadline even when the
   * clock disagrees by the few milliseconds a timer may fire early, so it is never revived.
   */
  private readonly lapsed = new Set<WebSocket>();
  private readonly attempts = new Map<WebSocket, { windowStart: number; count: number }>();

  constructor(private readonly deps: SocketAccessDeadlinesDeps) {}

  /**
   * Arm the deadline of a newly opened socket whose principal holds an expiring token.
   * `gateRequest` is what `auth.module` admitted a network socket with; the owner Unix socket
   * skips the gate and has none.
   */
  track(ws: WebSocket, gateRequest?: AuthGateRequest): void {
    const principal = this.deps.principals.get(ws);
    if (isDeviceAccessPrincipal(principal) && principal.expiresAt) {
      if (gateRequest) this.gateRequests.set(ws, gateRequest);
      this.scheduleDeadline(ws, principal.expiresAt);
    }
  }

  forget(ws: WebSocket): void {
    this.cancelTimer(ws);
    this.gateRequests.delete(ws);
    this.lapsed.delete(ws);
    this.attempts.delete(ws);
  }

  clear(): void {
    for (const timer of this.timers.values()) clearTimeout(timer);
    this.timers.clear();
    this.gateRequests.clear();
    this.lapsed.clear();
    this.attempts.clear();
  }

  /**
   * `auth_renew`. The socket is admitted again exactly as at upgrade: the `auth.module` gate
   * with its upgrade request, then the token, valid at this moment and of the socket's own
   * device. The socket's deadline then moves to that token's: it lasts as long as a fresh
   * connection with that token would, and never shorter than before. A refusal changes
   * nothing, so the socket still closes at its old deadline. A socket already past its
   * deadline (held open only to finish a dictation take or a Live Voice call) is not revived.
   * Revocation and owner-credential rotation still close it at once: they read `principals`,
   * which keeps the device.
   */
  async renew(
    ws: WebSocket,
    token: string,
    stream: RenewableStream,
  ): Promise<StreamAuthRenewResultMessage> {
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
    const before = this.renewablePrincipal(ws);
    if (!before) return refuse("not_renewable");
    const attempt = this.countAttempt(ws);
    if (attempt > RENEWALS_PER_MINUTE) {
      if (attempt === RENEWALS_PER_MINUTE + 1) return refuse("rate_limited", before.deviceId);
      return { type: "auth_renew_result", ok: false, reason: "rate_limited" };
    }
    if (this.pastDeadline(ws, before.expiresAt)) return refuse("past_deadline", before.deviceId);

    const gateRequest = this.gateRequests.get(ws);
    if (gateRequest && !(await this.deps.gate(gateRequest)).allow) {
      return refuse("gate_denied", before.deviceId);
    }

    // The gate may have taken a while: read the socket's state again before the token.
    const principal = this.renewablePrincipal(ws);
    if (!principal) return refuse("not_renewable", before.deviceId);
    if (this.pastDeadline(ws, principal.expiresAt)) {
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

  /** The socket's device principal while it holds an expiring token. */
  private renewablePrincipal(ws: WebSocket): RenewablePrincipal | undefined {
    const principal = this.deps.principals.get(ws);
    if (!isDeviceAccessPrincipal(principal) || principal.expiresAt === undefined) return undefined;
    return { ...principal, expiresAt: principal.expiresAt };
  }

  private pastDeadline(ws: WebSocket, expiresAt: number): boolean {
    return this.lapsed.has(ws) || Date.now() - CLOCK_SKEW_MS > expiresAt;
  }

  /** This renewal's number within the socket's current one-minute window. */
  private countAttempt(ws: WebSocket): number {
    const now = Date.now();
    const current = this.attempts.get(ws);
    if (!current || now - current.windowStart >= RENEWAL_WINDOW_MS) {
      this.attempts.set(ws, { windowStart: now, count: 1 });
      return 1;
    }
    current.count += 1;
    return current.count;
  }

  private scheduleDeadline(ws: WebSocket, expiresAt: number): void {
    this.lookAfter(ws, Math.max(0, expiresAt + CLOCK_SKEW_MS - Date.now()));
  }

  private lookAfter(ws: WebSocket, delay: number): void {
    this.cancelTimer(ws);
    const timer = setTimeout(() => {
      this.timers.delete(ws);
      this.lapsed.add(ws);
      const recheck = this.deps.expire(ws);
      if (recheck !== undefined) this.lookAfter(ws, recheck);
    }, delay);
    this.timers.set(ws, timer);
  }

  private cancelTimer(ws: WebSocket): void {
    const timer = this.timers.get(ws);
    if (timer) clearTimeout(timer);
    this.timers.delete(ws);
  }
}

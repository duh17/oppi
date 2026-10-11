/**
 * Phone WSS `/desktop/view/stream` relay. Owns grant check, pacing, and close.
 * Forwards companion media payloads unchanged.
 */

import type { Socket } from "node:net";
import type { WebSocket } from "ws";

import {
  DesktopCompanionViewStreamError,
  type DesktopCompanionViewStreamClient,
} from "./desktop-companion-view-stream-client.js";
import {
  DESKTOP_VIEW_HARD_BYTE_CAP,
  DESKTOP_VIEW_PING_RTT_WINDOW_MS,
  DesktopViewRateController,
} from "./desktop-view-rate-controller.js";
import {
  CompanionFrameReader,
  encodeCompanionJson,
  parseControlJson,
} from "./desktop-view-stream-codec.js";
import {
  DESKTOP_VIEW_COMPANION_FRAME_JSON,
  DESKTOP_VIEW_COMPANION_FRAME_MEDIA,
  DESKTOP_VIEW_ERROR,
  DESKTOP_VIEW_WIRE_VERSION,
  isDesktopViewFatalError,
  type DesktopViewCompanionControl,
  type DesktopViewErrorCode,
  type DesktopViewHello,
  type DesktopViewPhoneControl,
} from "./types/protocol.js";

const WS_CLOSE_POLICY = 4000;
const PING_INTERVAL_MS = 1_000;
const ENCODE_WATCHDOG_MS = 5_000;

export type DesktopViewStreamAccess = {
  deviceId: string;
};

type StreamDeps = {
  connectCompanion: DesktopCompanionViewStreamClient["connect"];
  now?: () => number;
  trackConnection?: (ws: WebSocket) => void;
  untrackConnection?: (ws: WebSocket) => void;
};

type ActiveRelay = {
  phone: WebSocket;
  companion?: Socket;
  grantId?: string;
  closed: boolean;
};

export class DesktopViewStreamMux {
  private active: ActiveRelay | undefined;

  constructor(private readonly deps: StreamDeps) {}

  handleWebSocket(ws: WebSocket, access: DesktopViewStreamAccess): void {
    this.deps.trackConnection?.(ws);
    if (this.active && !this.active.closed) {
      this.fail(ws, DESKTOP_VIEW_ERROR.alreadyStreaming, "Desktop view stream is already active");
      this.deps.untrackConnection?.(ws);
      return;
    }

    const relay: ActiveRelay = { phone: ws, closed: false };
    this.active = relay;
    const now = this.deps.now ?? Date.now;
    const controller = new DesktopViewRateController({ now });
    const abort = new AbortController();
    const pingIdleAtSend = new Map<number, boolean>();
    let encodeOutstanding = false;
    let sawHello = false;
    let waitTimer: ReturnType<typeof setTimeout> | undefined;
    let pingTimer: ReturnType<typeof setInterval> | undefined;
    let watchdog: ReturnType<typeof setTimeout> | undefined;

    const teardown = (code?: DesktopViewErrorCode | number, message?: string): void => {
      if (relay.closed) return;
      relay.closed = true;
      abort.abort();
      if (waitTimer) clearTimeout(waitTimer);
      if (pingTimer) clearInterval(pingTimer);
      if (watchdog) clearTimeout(watchdog);
      if (this.active === relay) this.active = undefined;
      relay.companion?.destroy();
      if (code !== undefined && message !== undefined) {
        this.sendJson(ws, {
          type: "error",
          code,
          message,
          fatal: isDesktopViewFatalError(code),
        });
        if (ws.readyState === ws.OPEN || ws.readyState === ws.CONNECTING) {
          ws.close(WS_CLOSE_POLICY, closeReason(code));
        }
      }
      this.deps.untrackConnection?.(ws);
    };

    ws.on("close", () => {
      teardown();
    });

    ws.on("message", (data, isBinary) => {
      if (relay.closed || isBinary) return;
      const payload = controlPayload(data);
      const parsed = parseControlJson(payload);
      if (!parsed || typeof parsed.type !== "string") return;
      if (parsed.type === "pong" && typeof parsed.t === "number") {
        const idleAtSend = pingIdleAtSend.get(parsed.t) === true;
        pingIdleAtSend.delete(parsed.t);
        controller.onRttSample(now() - parsed.t, now(), idleAtSend);
        maybeEncode();
        return;
      }
      if (
        parsed.type === "ack" &&
        typeof parsed.frameId === "number" &&
        typeof parsed.receivedAt === "number"
      ) {
        controller.onAck(parsed.frameId, now());
        maybeEncode();
      }
    });

    const maybeEncode = (): void => {
      if (relay.closed || !sawHello) return;
      if (waitTimer) {
        clearTimeout(waitTimer);
        waitTimer = undefined;
      }
      const decision = controller.shouldEncode(now(), !encodeOutstanding);
      if (decision.kind === "wait") {
        if (decision.afterMs !== undefined && decision.afterMs > 0) {
          waitTimer = setTimeout(maybeEncode, decision.afterMs);
        }
        return;
      }
      if (decision.kind === "close") {
        teardown(DESKTOP_VIEW_ERROR.backpressureCap, "Desktop view in-flight byte cap exceeded");
        return;
      }
      encodeOutstanding = true;
      if (watchdog) clearTimeout(watchdog);
      watchdog = setTimeout(() => {
        teardown(DESKTOP_VIEW_ERROR.companionUnavailable, "Desktop companion is unavailable");
      }, ENCODE_WATCHDOG_MS);
      const command: DesktopViewCompanionControl = {
        type: "encode",
        frameId: decision.command.frameId,
        bitrate: decision.command.bitrate,
        fps: decision.command.fps,
        scale: decision.command.scale,
        keyframe: decision.command.keyframe || undefined,
      };
      writeCompanion(relay.companion, encodeCompanionJson(command));
      maybeEncode();
    };

    void this.deps
      .connectCompanion({
        deviceId: access.deviceId,
        signal: abort.signal,
      })
      .then((stream) => {
        if (relay.closed) {
          stream.socket.destroy();
          return;
        }
        relay.companion = stream.socket;
        const reader = new CompanionFrameReader(DESKTOP_VIEW_HARD_BYTE_CAP);
        const onBytes = (chunk: Buffer): void => {
          if (relay.closed) return;
          let frames;
          try {
            frames = reader.push(chunk);
          } catch {
            teardown(DESKTOP_VIEW_ERROR.protocolFatal, "Desktop view companion framing is invalid");
            return;
          }
          for (const frame of frames) {
            if (frame.type === DESKTOP_VIEW_COMPANION_FRAME_MEDIA) {
              encodeOutstanding = false;
              if (watchdog) {
                clearTimeout(watchdog);
                watchdog = undefined;
              }
              if (ws.readyState !== ws.OPEN) continue;
              if (
                frame.payload.length > DESKTOP_VIEW_HARD_BYTE_CAP ||
                ws.bufferedAmount + frame.payload.length > DESKTOP_VIEW_HARD_BYTE_CAP
              ) {
                teardown(
                  DESKTOP_VIEW_ERROR.backpressureCap,
                  "Desktop view in-flight byte cap exceeded",
                );
                return;
              }
              ws.send(frame.payload, { binary: true, compress: false });
              const frameId = frame.payload.length >= 8 ? frame.payload.readUInt32BE(4) : 0;
              controller.onFrameSent(frameId, frame.payload.length, now());
              maybeEncode();
              continue;
            }
            if (frame.type !== DESKTOP_VIEW_COMPANION_FRAME_JSON) continue;
            const parsed = parseControlJson(frame.payload);
            if (!parsed || typeof parsed.type !== "string") continue;
            if (parsed.type === "hello") {
              const hello = parsed as unknown as DesktopViewHello;
              if (
                hello.version !== DESKTOP_VIEW_WIRE_VERSION ||
                !Array.isArray(hello.features) ||
                hello.features.length === 0
              ) {
                teardown(DESKTOP_VIEW_ERROR.protocolFatal, "Desktop view hello is invalid");
                return;
              }
              if (hello.deviceId !== access.deviceId) {
                teardown(
                  DESKTOP_VIEW_ERROR.grantNotBound,
                  "Desktop view session is not granted to this device",
                );
                return;
              }
              sawHello = true;
              relay.grantId = hello.grantId;
              const phoneHello: DesktopViewPhoneControl = {
                type: "hello",
                version: hello.version,
                features: hello.features,
                grantId: hello.grantId,
                deviceId: hello.deviceId,
                surface: hello.surface,
                expiresAt: hello.expiresAt,
              };
              this.sendJson(ws, phoneHello);
              const sendPing = (): void => {
                const t = now();
                const staleBefore = t - DESKTOP_VIEW_PING_RTT_WINDOW_MS;
                for (const sentAt of pingIdleAtSend.keys()) {
                  if (sentAt < staleBefore) pingIdleAtSend.delete(sentAt);
                }
                const snap = controller.snapshot();
                const pFrameBytes = Math.max(1, Math.ceil(snap.bitrate / 8 / snap.fps));
                const inFlight = controller.inFlightBytes();
                // Control bytes (hello) may sit in bufferedAmount with no media in
                // flight; those pings are still idle. A ping behind queued frames is not.
                pingIdleAtSend.set(
                  t,
                  inFlight <= pFrameBytes && (inFlight === 0 || ws.bufferedAmount === 0),
                );
                this.sendJson(ws, { type: "ping", t });
              };
              sendPing();
              pingTimer = setInterval(sendPing, PING_INTERVAL_MS);
              continue;
            }
            if (parsed.type === "error" && typeof parsed.code === "number") {
              teardown(
                parsed.code,
                typeof parsed.message === "string" ? parsed.message : "Desktop view error",
              );
            }
          }
        };
        if (stream.leftover.length > 0) onBytes(stream.leftover);
        stream.socket.on("data", (chunk: Buffer | string) => {
          onBytes(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        });
        stream.socket.on("close", () => {
          teardown(DESKTOP_VIEW_ERROR.companionUnavailable, "Desktop companion is unavailable");
        });
        stream.socket.on("error", () => {
          teardown(DESKTOP_VIEW_ERROR.companionUnavailable, "Desktop companion is unavailable");
        });
      })
      .catch((error: unknown) => {
        if (error instanceof DesktopCompanionViewStreamError) {
          teardown(error.code, error.message);
          return;
        }
        teardown(DESKTOP_VIEW_ERROR.companionUnavailable, "Desktop companion is unavailable");
      });
  }

  private fail(ws: WebSocket, code: number, message: string): void {
    this.sendJson(ws, {
      type: "error",
      code,
      message,
      fatal: isDesktopViewFatalError(code),
    });
    if (ws.readyState === ws.OPEN || ws.readyState === ws.CONNECTING) {
      ws.close(WS_CLOSE_POLICY, closeReason(code));
    }
  }

  private sendJson(ws: WebSocket, value: unknown): void {
    if (ws.readyState !== ws.OPEN && ws.readyState !== ws.CONNECTING) return;
    ws.send(JSON.stringify(value));
  }
}

function controlPayload(data: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(data)) return data;
  if (typeof data === "string") return Buffer.from(data, "utf8");
  if (Array.isArray(data)) return Buffer.concat(data);
  return Buffer.from(data);
}

function writeCompanion(socket: Socket | undefined, bytes: Buffer): void {
  if (!socket || socket.destroyed) return;
  socket.write(bytes);
}

function closeReason(code: number): string {
  switch (code) {
    case DESKTOP_VIEW_ERROR.protocolFatal:
      return "protocol_fatal";
    case DESKTOP_VIEW_ERROR.grantUnavailable:
      return "grant_unavailable";
    case DESKTOP_VIEW_ERROR.grantNotBound:
      return "grant_not_bound";
    case DESKTOP_VIEW_ERROR.grantRevoked:
      return "grant_revoked";
    case DESKTOP_VIEW_ERROR.grantExpired:
      return "grant_expired";
    case DESKTOP_VIEW_ERROR.surfaceGone:
      return "surface_gone";
    case DESKTOP_VIEW_ERROR.deviceRevoked:
      return "device_revoked";
    case DESKTOP_VIEW_ERROR.flagOff:
      return "flag_off";
    case DESKTOP_VIEW_ERROR.backpressureCap:
      return "backpressure_cap";
    case DESKTOP_VIEW_ERROR.alreadyStreaming:
      return "already_streaming";
    case DESKTOP_VIEW_ERROR.companionUnavailable:
      return "companion_unavailable";
    default:
      return "desktop_view";
  }
}

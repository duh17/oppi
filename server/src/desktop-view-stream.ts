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
import { DesktopViewRateController } from "./desktop-view-rate-controller.js";
import {
  CompanionFrameReader,
  encodeCompanionJson,
  parseControlJson,
} from "./desktop-view-stream-codec.js";
import {
  DESKTOP_VIEW_COMPANION_FRAME_JSON,
  DESKTOP_VIEW_COMPANION_FRAME_MEDIA,
  DESKTOP_VIEW_ERROR,
  DESKTOP_VIEW_FEATURE_H264_ANNEXB,
  DESKTOP_VIEW_WIRE_VERSION,
  isDesktopViewFatalError,
  type DesktopViewCompanionControl,
  type DesktopViewErrorCode,
  type DesktopViewHello,
  type DesktopViewPhoneControl,
} from "./types/protocol.js";

const WS_CLOSE_POLICY = 4000;

export type DesktopViewStreamAccess = {
  deviceId: string;
  deviceName?: string;
  expiresAt?: number;
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

  get activeCount(): number {
    return this.active && !this.active.closed ? 1 : 0;
  }

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
    let encodeOutstanding = false;
    let sawHello = false;
    let paceTimer: ReturnType<typeof setTimeout> | undefined;

    const closeBoth = (code: DesktopViewErrorCode | number, message: string): void => {
      if (relay.closed) return;
      relay.closed = true;
      abort.abort();
      if (paceTimer) clearTimeout(paceTimer);
      if (this.active === relay) this.active = undefined;
      try {
        relay.companion?.destroy();
      } catch {
        // Socket may already be closed.
      }
      this.sendJson(ws, {
        type: "error",
        code,
        message,
        fatal: isDesktopViewFatalError(code),
      });
      if (ws.readyState === ws.OPEN || ws.readyState === ws.CONNECTING) {
        ws.close(WS_CLOSE_POLICY, closeReason(code));
      }
      this.deps.untrackConnection?.(ws);
    };

    ws.on("close", () => {
      if (relay.closed) return;
      relay.closed = true;
      abort.abort();
      if (paceTimer) clearTimeout(paceTimer);
      if (this.active === relay) this.active = undefined;
      try {
        relay.companion?.destroy();
      } catch {
        // already closed
      }
      this.deps.untrackConnection?.(ws);
    });

    ws.on("message", (data, isBinary) => {
      if (relay.closed || isBinary) return;
      const payload =
        typeof data === "string" ? data : Buffer.from(data as Buffer).toString("utf8");
      const parsed = parseControlJson(Buffer.from(payload, "utf8"));
      if (!parsed || typeof parsed.type !== "string") return;
      if (parsed.type === "pong" && typeof parsed.t === "number") {
        controller.onRttSample(now() - parsed.t);
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
      if (relay.closed || encodeOutstanding || !sawHello) return;
      if (paceTimer) {
        clearTimeout(paceTimer);
        paceTimer = undefined;
      }
      const decision = controller.shouldEncode(now());
      if (decision.kind === "wait") {
        if (decision.afterMs !== undefined && decision.afterMs > 0) {
          paceTimer = setTimeout(maybeEncode, decision.afterMs);
        }
        return;
      }
      if (decision.kind === "close") {
        closeBoth(DESKTOP_VIEW_ERROR.backpressureCap, "Desktop view in-flight byte cap exceeded");
        return;
      }
      encodeOutstanding = true;
      const command: DesktopViewCompanionControl = {
        type: "encode",
        frameId: decision.command.frameId,
        bitrate: decision.command.bitrate,
        fps: decision.command.fps,
        scale: decision.command.scale,
        keyframe: decision.command.keyframe || undefined,
      };
      writeCompanion(relay.companion, encodeCompanionJson(command));
      paceTimer = setTimeout(maybeEncode, Math.max(1, 1000 / decision.command.fps));
    };

    void this.deps
      .connectCompanion({
        deviceId: access.deviceId,
        deviceName: access.deviceName,
        signal: abort.signal,
      })
      .then((stream) => {
        if (relay.closed) {
          stream.socket.destroy();
          return;
        }
        relay.companion = stream.socket;
        const reader = new CompanionFrameReader();
        const onBytes = (chunk: Buffer): void => {
          if (relay.closed) return;
          let frames;
          try {
            frames = reader.push(chunk);
          } catch {
            closeBoth(
              DESKTOP_VIEW_ERROR.protocolFatal,
              "Desktop view companion framing is invalid",
            );
            return;
          }
          for (const frame of frames) {
            if (frame.type === DESKTOP_VIEW_COMPANION_FRAME_MEDIA) {
              encodeOutstanding = false;
              if (ws.readyState !== ws.OPEN) continue;
              ws.send(frame.payload, { binary: true });
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
              if (hello.deviceId !== access.deviceId) {
                closeBoth(
                  DESKTOP_VIEW_ERROR.grantNotBound,
                  "Desktop view session is not granted to this device",
                );
                return;
              }
              sawHello = true;
              relay.grantId = hello.grantId;
              const phoneHello: DesktopViewPhoneControl = {
                type: "hello",
                version: DESKTOP_VIEW_WIRE_VERSION,
                features: hello.features?.length
                  ? hello.features
                  : [DESKTOP_VIEW_FEATURE_H264_ANNEXB],
                grantId: hello.grantId,
                deviceId: hello.deviceId,
                surface: hello.surface,
                width: hello.width,
                height: hello.height,
                expiresAt: hello.expiresAt,
              };
              this.sendJson(ws, phoneHello);
              this.sendJson(ws, { type: "ping", t: now() });
              continue;
            }
            if (parsed.type === "error" && typeof parsed.code === "number") {
              closeBoth(
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
          if (relay.closed) return;
          closeBoth(DESKTOP_VIEW_ERROR.surfaceGone, "Desktop view companion closed");
        });
        stream.socket.on("error", () => {
          if (relay.closed) return;
          closeBoth(DESKTOP_VIEW_ERROR.companionUnavailable, "Desktop companion is unavailable");
        });
      })
      .catch((error: unknown) => {
        if (relay.closed) return;
        if (error instanceof DesktopCompanionViewStreamError) {
          closeBoth(error.code, error.message);
          return;
        }
        closeBoth(DESKTOP_VIEW_ERROR.companionUnavailable, "Desktop companion is unavailable");
      });
  }

  closeAll(code = DESKTOP_VIEW_ERROR.flagOff, message = "Desktop live view is off"): void {
    const relay = this.active;
    if (!relay || relay.closed) return;
    relay.closed = true;
    this.active = undefined;
    try {
      relay.companion?.destroy();
    } catch {
      // already closed
    }
    this.sendJson(relay.phone, {
      type: "error",
      code,
      message,
      fatal: isDesktopViewFatalError(code),
    });
    if (relay.phone.readyState === relay.phone.OPEN) {
      relay.phone.close(WS_CLOSE_POLICY, closeReason(code));
    }
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

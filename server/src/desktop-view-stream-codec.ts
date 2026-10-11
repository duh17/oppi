/**
 * Desktop live-view wire codec.
 *
 * Phone WSS: JSON text control; binary media = 24-byte header + Annex-B H.264.
 * Companion unix stream after 101: length-prefixed frames wrapping JSON or the
 * same media bytes Node forwards unchanged to `ws.send`.
 */

import {
  DESKTOP_VIEW_COMPANION_FRAME_JSON,
  DESKTOP_VIEW_COMPANION_FRAME_MEDIA,
  DESKTOP_VIEW_MEDIA_HEADER_BYTES,
  DESKTOP_VIEW_WIRE_VERSION,
} from "./types/protocol.js";

export const DESKTOP_VIEW_MAX_FRAME_BYTES = 16 * 1024 * 1024;

export const DESKTOP_VIEW_FLAG_KEYFRAME = 1 << 0;

export type DesktopViewMediaHeader = {
  version: number;
  keyframe: boolean;
  frameId: number;
  capturedAtMs: number;
  width: number;
  height: number;
  payloadBytes: number;
};

export type CompanionFrame = {
  type: number;
  payload: Buffer;
};

export function encodeCompanionFrame(type: number, payload: Buffer): Buffer {
  const length = 1 + payload.length;
  const out = Buffer.allocUnsafe(4 + length);
  out.writeUInt32BE(length, 0);
  out[4] = type;
  payload.copy(out, 5);
  return out;
}

export function encodeCompanionJson(value: unknown): Buffer {
  return encodeCompanionFrame(
    DESKTOP_VIEW_COMPANION_FRAME_JSON,
    Buffer.from(JSON.stringify(value), "utf8"),
  );
}

export function encodeCompanionMedia(phoneWire: Buffer): Buffer {
  return encodeCompanionFrame(DESKTOP_VIEW_COMPANION_FRAME_MEDIA, phoneWire);
}

export class CompanionFrameReader {
  private buf: Buffer = Buffer.alloc(0);

  push(chunk: Buffer): CompanionFrame[] {
    this.buf = this.buf.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.buf, chunk]);
    const frames: CompanionFrame[] = [];
    while (this.buf.length >= 5) {
      const length = this.buf.readUInt32BE(0);
      if (!Number.isSafeInteger(length) || length < 1 || length > DESKTOP_VIEW_MAX_FRAME_BYTES) {
        throw new Error("Desktop view companion frame length is invalid");
      }
      if (this.buf.length < 4 + length) break;
      const type = this.buf[4] ?? 0;
      const payload = this.buf.subarray(5, 4 + length);
      frames.push({ type, payload });
      this.buf = this.buf.subarray(4 + length);
    }
    return frames;
  }
}

export function encodeMediaFrame(
  header: Omit<DesktopViewMediaHeader, "version" | "payloadBytes">,
  annexB: Buffer,
): Buffer {
  const out = Buffer.allocUnsafe(DESKTOP_VIEW_MEDIA_HEADER_BYTES + annexB.length);
  writeMediaHeader(out, {
    version: DESKTOP_VIEW_WIRE_VERSION,
    keyframe: header.keyframe,
    frameId: header.frameId,
    capturedAtMs: header.capturedAtMs,
    width: header.width,
    height: header.height,
    payloadBytes: annexB.length,
  });
  annexB.copy(out, DESKTOP_VIEW_MEDIA_HEADER_BYTES);
  return out;
}

export function parseMediaFrame(bytes: Buffer): {
  header: DesktopViewMediaHeader;
  payload: Buffer;
} {
  if (bytes.length < DESKTOP_VIEW_MEDIA_HEADER_BYTES) {
    throw new Error("Desktop view media frame is truncated");
  }
  const header = readMediaHeader(bytes);
  if (header.version !== DESKTOP_VIEW_WIRE_VERSION) {
    throw new Error("Desktop view media version is unsupported");
  }
  const end = DESKTOP_VIEW_MEDIA_HEADER_BYTES + header.payloadBytes;
  if (bytes.length < end) {
    throw new Error("Desktop view media payload is truncated");
  }
  return { header, payload: bytes.subarray(DESKTOP_VIEW_MEDIA_HEADER_BYTES, end) };
}

export function writeMediaHeader(out: Buffer, header: DesktopViewMediaHeader): void {
  out[0] = header.version;
  out[1] = header.keyframe ? DESKTOP_VIEW_FLAG_KEYFRAME : 0;
  out[2] = DESKTOP_VIEW_MEDIA_HEADER_BYTES;
  out[3] = 0;
  out.writeUInt32BE(header.frameId >>> 0, 4);
  writeUInt64BE(out, 8, header.capturedAtMs);
  out.writeUInt16BE(header.width, 16);
  out.writeUInt16BE(header.height, 18);
  out.writeUInt32BE(header.payloadBytes >>> 0, 20);
}

export function readMediaHeader(bytes: Buffer): DesktopViewMediaHeader {
  return {
    version: bytes[0] ?? 0,
    keyframe: ((bytes[1] ?? 0) & DESKTOP_VIEW_FLAG_KEYFRAME) !== 0,
    frameId: bytes.readUInt32BE(4),
    capturedAtMs: readUInt64BE(bytes, 8),
    width: bytes.readUInt16BE(16),
    height: bytes.readUInt16BE(18),
    payloadBytes: bytes.readUInt32BE(20),
  };
}

function writeUInt64BE(buf: Buffer, offset: number, value: number): void {
  const hi = Math.floor(value / 0x1_0000_0000);
  const lo = value >>> 0;
  buf.writeUInt32BE(hi, offset);
  buf.writeUInt32BE(lo, offset + 4);
}

function readUInt64BE(buf: Buffer, offset: number): number {
  const hi = buf.readUInt32BE(offset);
  const lo = buf.readUInt32BE(offset + 4);
  return hi * 0x1_0000_0000 + lo;
}

export function parseControlJson(payload: Buffer): Record<string, unknown> | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload.toString("utf8"));
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return undefined;
  }
  return parsed as Record<string, unknown>;
}

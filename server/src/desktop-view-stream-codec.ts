/**
 * Desktop live-view wire codec.
 *
 * Phone WSS: JSON text control; binary media = 24-byte header + AVCC H.264
 * (4-byte NAL lengths; SPS/PPS prepended as length-prefixed NALUs on IDR).
 * Companion unix stream after 101: length-prefixed frames wrapping JSON or the
 * same media bytes Node forwards unchanged to `ws.send`.
 */

import {
  DESKTOP_VIEW_COMPANION_FRAME_JSON,
  DESKTOP_VIEW_COMPANION_FRAME_MEDIA,
  DESKTOP_VIEW_MEDIA_HEADER_BYTES,
  DESKTOP_VIEW_WIRE_VERSION,
} from "./types/protocol.js";

/** Companion length-prefix max; matches the in-flight hard cap. */
export const DESKTOP_VIEW_MAX_FRAME_BYTES = 2 * 1024 * 1024;

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
  private chunks: Buffer[] = [];
  private total = 0;

  constructor(private readonly maxFrameBytes = DESKTOP_VIEW_MAX_FRAME_BYTES) {}

  push(chunk: Buffer): CompanionFrame[] {
    if (chunk.length === 0) return [];
    this.chunks.push(chunk);
    this.total += chunk.length;
    const frames: CompanionFrame[] = [];
    while (this.total >= 5) {
      const length = this.peekUInt32BE();
      if (!Number.isSafeInteger(length) || length < 1 || length > this.maxFrameBytes) {
        throw new Error("Desktop view companion frame length is invalid");
      }
      const frameSize = 4 + length;
      if (this.total < frameSize) break;
      const frame = this.take(frameSize);
      frames.push({ type: frame[4] ?? 0, payload: frame.subarray(5) });
    }
    return frames;
  }

  private peekUInt32BE(): number {
    const first = this.chunks[0];
    if (first && first.length >= 4) return first.readUInt32BE(0);
    const head = Buffer.allocUnsafe(4);
    let offset = 0;
    for (const chunk of this.chunks) {
      const n = Math.min(chunk.length, 4 - offset);
      chunk.copy(head, offset, 0, n);
      offset += n;
      if (offset === 4) break;
    }
    return head.readUInt32BE(0);
  }

  private take(n: number): Buffer {
    const first = this.chunks[0];
    if (first && first.length >= n) {
      const out = first.subarray(0, n);
      if (first.length === n) this.chunks.shift();
      else this.chunks[0] = first.subarray(n);
      this.total -= n;
      return out;
    }
    const parts: Buffer[] = [];
    let remaining = n;
    while (remaining > 0) {
      const chunk = this.chunks[0];
      if (!chunk) break;
      if (chunk.length <= remaining) {
        parts.push(chunk);
        remaining -= chunk.length;
        this.chunks.shift();
      } else {
        parts.push(chunk.subarray(0, remaining));
        this.chunks[0] = chunk.subarray(remaining);
        remaining = 0;
      }
    }
    this.total -= n;
    const only = parts[0];
    return parts.length === 1 && only ? only : Buffer.concat(parts);
  }
}

export function encodeMediaFrame(
  header: Omit<DesktopViewMediaHeader, "version" | "payloadBytes">,
  avcc: Buffer,
): Buffer {
  const out = Buffer.allocUnsafe(DESKTOP_VIEW_MEDIA_HEADER_BYTES + avcc.length);
  writeMediaHeader(out, {
    version: DESKTOP_VIEW_WIRE_VERSION,
    keyframe: header.keyframe,
    frameId: header.frameId,
    capturedAtMs: header.capturedAtMs,
    width: header.width,
    height: header.height,
    payloadBytes: avcc.length,
  });
  avcc.copy(out, DESKTOP_VIEW_MEDIA_HEADER_BYTES);
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

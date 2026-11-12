import { crc32, deflateSync } from "node:zlib";

import { DEFAULT_IMAGE_LIMITS } from "@earendil-works/pi-durable/tools";
import { describe, expect, it } from "vitest";

import { READ_IMAGE_MAX_EDGE, readImages } from "../src/coding-tools.js";

function chunk(type: string, data: Buffer): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}

/** An RGB PNG of noise, so no encoder can squeeze it below the byte limit by itself. */
function png(width: number, height: number): Buffer {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 2, 0, 0, 0], 8);
  const rows = Buffer.alloc((width * 3 + 1) * height);
  let seed = 7;
  for (let i = 0; i < rows.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    rows[i] = i % (width * 3 + 1) === 0 ? 0 : seed >> 16;
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(rows)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** Width and height from a PNG's IHDR or a JPEG's start-of-frame segment. */
function size(data: string): { width: number; height: number } {
  const bytes = Buffer.from(data, "base64");
  if (bytes[0] === 0x89) return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  for (let at = 2; at < bytes.length; at += 2 + bytes.readUInt16BE(at + 2)) {
    const marker = bytes[at + 1]!;
    if (marker >= 0xc0 && marker <= 0xc3)
      return { width: bytes.readUInt16BE(at + 7), height: bytes.readUInt16BE(at + 5) };
  }
  throw new Error("no image size");
}

describe("read images", () => {
  it("shrinks an image past the 2000 px default to the read edge instead of refusing it", async () => {
    const prepared = await readImages.prepare(png(3000, 1000), "image/png", DEFAULT_IMAGE_LIMITS);
    expect(prepared && size(prepared.data)).toEqual({ width: READ_IMAGE_MAX_EDGE, height: 523 });
    expect(prepared?.resized?.from).toEqual({ width: 3000, height: 1000 });
  });

  it("shrinks a tall image within the default limits by its long edge", async () => {
    const prepared = await readImages.prepare(png(900, 1920), "image/png", DEFAULT_IMAGE_LIMITS);
    expect(prepared && size(prepared.data)).toEqual({ width: 735, height: READ_IMAGE_MAX_EDGE });
  });

  it("reads a small image from a pooled Buffer and leaves the caller's bytes intact", async () => {
    const file = png(40, 10);
    // A view into a larger ArrayBuffer at an offset, like a small Buffer from Node's shared pool.
    const view = Buffer.alloc(file.length + 64).subarray(32, 32 + file.length);
    file.copy(view);
    const prepared = await readImages.prepare(view, "image/png", DEFAULT_IMAGE_LIMITS);
    expect(prepared && size(prepared.data)).toEqual({ width: 40, height: 10 });
    expect(view.equals(file)).toBe(true);
  });

  it("keeps a model limit tighter than the read edge", async () => {
    const limits = { ...DEFAULT_IMAGE_LIMITS, maxWidth: 800, maxHeight: 800 };
    const prepared = await readImages.prepare(png(1600, 400), "image/png", limits);
    expect(prepared && size(prepared.data)).toEqual({ width: 800, height: 200 });
  });
});

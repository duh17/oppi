import { crc32, deflateSync } from "node:zlib";

// Small made-up images for the icon-asset checks. The PNG is a complete RGBA
// image; the GIF and WebP carry real headers around a token payload, which is
// all the server reads.

function pngChunk(type: string, data: Buffer): Buffer {
  const header = Buffer.alloc(8);
  header.writeUInt32BE(data.length, 0);
  header.write(type, 4, 4, "latin1");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([header.subarray(4), data])), 0);
  return Buffer.concat([header, data, crc]);
}

export function pngFixture(options: { width?: number; height?: number } = {}): Buffer {
  const width = options.width ?? 4;
  const height = options.height ?? 4;
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.writeUInt8(8, 8); // bit depth
  ihdr.writeUInt8(6, 9); // RGBA
  const row = Buffer.alloc(1 + width * 4, 0x80);
  row[0] = 0; // filter: none
  const pixels = deflateSync(Buffer.concat(Array.from({ length: height }, () => row)));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", pixels),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

export function gifFixture(options: { width?: number; height?: number } = {}): Buffer {
  const screen = Buffer.alloc(7);
  screen.writeUInt16LE(options.width ?? 1, 0);
  screen.writeUInt16LE(options.height ?? 1, 2);
  return Buffer.concat([Buffer.from("GIF89a", "latin1"), screen, Buffer.from([0x3b])]);
}

/** A WebP whose first chunk is `chunk` with `data`. */
function webpWith(chunk: string, data: Buffer): Buffer {
  const header = Buffer.alloc(20);
  header.write("RIFF", 0, 4, "latin1");
  header.writeUInt32LE(12 + data.length, 4);
  header.write("WEBP", 8, 4, "latin1");
  header.write(chunk, 12, 4, "latin1");
  header.writeUInt32LE(data.length, 16);
  return Buffer.concat([header, data]);
}

export function webpFixture(
  kind: "VP8L" | "VP8X" | "VP8 " = "VP8L",
  options: { width?: number; height?: number } = {},
): Buffer {
  const width = options.width ?? 2;
  const height = options.height ?? 2;
  switch (kind) {
    case "VP8L": {
      const data = Buffer.alloc(9);
      data.writeUInt8(0x2f, 0);
      data.writeUInt32LE(((width - 1) & 0x3fff) | (((height - 1) & 0x3fff) << 14), 1);
      return webpWith("VP8L", data);
    }
    case "VP8X": {
      const data = Buffer.alloc(10);
      data.writeUInt8(0x02, 0); // animated
      data.writeUIntLE(width - 1, 4, 3);
      data.writeUIntLE(height - 1, 7, 3);
      return webpWith("VP8X", data);
    }
    case "VP8 ": {
      const data = Buffer.alloc(10);
      data.writeUIntBE(0x9d012a, 3, 3);
      data.writeUInt16LE(width, 6);
      data.writeUInt16LE(height, 8);
      return webpWith("VP8 ", data);
    }
  }
}

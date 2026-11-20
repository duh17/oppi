/**
 * The image icons a person imports (PNG and APNG, GIF, WebP). The format comes
 * from the bytes, never a file name or a declared type, and the pixel size from
 * fixed header positions. The server never decodes or draws these bytes: the
 * app decodes every image with ImageIO before it uploads one and again before
 * it draws one, so anything a decoder tolerates (trailing bytes, a missing
 * GIF trailer) is left to it.
 */

export type IconImageContentType = "image/png" | "image/gif" | "image/webp";

/** An imported icon is small: the app sends stills at about 128 px. */
export const ICON_IMAGE_MAX_BYTES = 1024 * 1024;
export const ICON_IMAGE_MAX_DIMENSION = 1_024;

export class IconImageFormatError extends Error {
  constructor(
    readonly code: "unsupported" | "corrupt",
    message: string,
  ) {
    super(message);
  }
}

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** The image format of `bytes`, or undefined when they are none of PNG, GIF, or WebP. */
export function detectIconImageFormat(bytes: Buffer): IconImageContentType | undefined {
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return "image/png";
  const head6 = bytes.toString("latin1", 0, 6);
  if (head6 === "GIF87a" || head6 === "GIF89a") return "image/gif";
  if (
    bytes.length >= 12 &&
    bytes.toString("latin1", 0, 4) === "RIFF" &&
    bytes.toString("latin1", 8, 12) === "WEBP"
  ) {
    return "image/webp";
  }
  return undefined;
}

/** The format of an imported icon, after checking its header's pixel size. */
export function sniffIconImage(bytes: Buffer): IconImageContentType {
  const contentType = detectIconImageFormat(bytes);
  if (!contentType) unsupported("Unsupported icon image; expected PNG, GIF, or WebP");
  const { width, height } = headerSize(contentType, bytes);
  if (width < 1 || height < 1) corrupt("Icon image has no pixels");
  if (width > ICON_IMAGE_MAX_DIMENSION || height > ICON_IMAGE_MAX_DIMENSION) {
    unsupported(`Icon image exceeds ${ICON_IMAGE_MAX_DIMENSION} pixels on a side`);
  }
  return contentType;
}

function headerSize(type: IconImageContentType, bytes: Buffer): { width: number; height: number } {
  switch (type) {
    case "image/png":
      // Signature, then the IHDR chunk: length, "IHDR", width, height.
      if (bytes.length < 24 || bytes.toString("latin1", 12, 16) !== "IHDR") {
        corrupt("PNG has no IHDR header");
      }
      return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
    case "image/gif":
      // The logical screen descriptor follows the six-byte signature.
      if (bytes.length < 10) corrupt("GIF header is truncated");
      return { width: bytes.readUInt16LE(6), height: bytes.readUInt16LE(8) };
    case "image/webp":
      return webpSize(bytes);
  }
}

/** The canvas size from the first chunk after the RIFF header. */
function webpSize(bytes: Buffer): { width: number; height: number } {
  const chunk = bytes.toString("latin1", 12, 16);
  const data = 20;
  switch (chunk) {
    case "VP8 ":
      // Frame tag (3 bytes), start code 9d 01 2a, then 14-bit sizes.
      if (bytes.length < data + 10 || bytes.readUIntBE(data + 3, 3) !== 0x9d012a) {
        corrupt("WebP VP8 header is invalid");
      }
      return {
        width: bytes.readUInt16LE(data + 6) & 0x3fff,
        height: bytes.readUInt16LE(data + 8) & 0x3fff,
      };
    case "VP8L": {
      if (bytes.length < data + 5 || bytes[data] !== 0x2f) corrupt("WebP VP8L header is invalid");
      const bits = bytes.readUInt32LE(data + 1);
      return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
    }
    case "VP8X":
      if (bytes.length < data + 10) corrupt("WebP VP8X header is truncated");
      return {
        width: bytes.readUIntLE(data + 4, 3) + 1,
        height: bytes.readUIntLE(data + 7, 3) + 1,
      };
    default:
      return unsupported("WebP has no VP8, VP8L, or VP8X header");
  }
}

function unsupported(message: string): never {
  throw new IconImageFormatError("unsupported", message);
}

function corrupt(message: string): never {
  throw new IconImageFormatError("corrupt", message);
}

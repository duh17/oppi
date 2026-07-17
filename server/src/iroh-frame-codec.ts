const DEFAULT_MAX_HEADER_BYTES = 64 * 1024;

export type IrohFrame = {
  header: Record<string, unknown>;
  body: Uint8Array;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function encodeIrohFrame(header: Record<string, unknown>, body?: Uint8Array): Uint8Array {
  if (!isRecord(header)) {
    throw new Error("Iroh frame header must be a JSON object");
  }

  const bodyBytes = body ? Buffer.from(body) : Buffer.alloc(0);
  const headerWithLength =
    bodyBytes.length > 0 && header.bodyLength === undefined
      ? { ...header, bodyLength: bodyBytes.length }
      : header;

  if (
    headerWithLength.bodyLength !== undefined &&
    (typeof headerWithLength.bodyLength !== "number" ||
      !Number.isSafeInteger(headerWithLength.bodyLength) ||
      headerWithLength.bodyLength < 0)
  ) {
    throw new Error("Iroh frame bodyLength must be a non-negative safe integer");
  }

  if (
    headerWithLength.bodyLength !== undefined &&
    headerWithLength.bodyLength !== bodyBytes.length
  ) {
    throw new Error("Iroh frame bodyLength does not match body bytes");
  }

  const headerBytes = Buffer.from(JSON.stringify(headerWithLength), "utf8");
  const frame = Buffer.alloc(4 + headerBytes.length + bodyBytes.length);
  frame.writeUInt32BE(headerBytes.length, 0);
  headerBytes.copy(frame, 4);
  bodyBytes.copy(frame, 4 + headerBytes.length);
  return frame;
}

export function decodeIrohFrame(
  bytes: Uint8Array,
  options: { maxHeaderBytes?: number; maxBodyBytes?: number } = {},
): IrohFrame {
  const frame = Buffer.from(bytes);
  if (frame.length < 4) {
    throw new Error("Iroh frame has a truncated header length");
  }

  const maxHeaderBytes = options.maxHeaderBytes ?? DEFAULT_MAX_HEADER_BYTES;
  const headerLength = frame.readUInt32BE(0);
  if (headerLength > maxHeaderBytes) {
    throw new Error(`Iroh frame header exceeds ${maxHeaderBytes} bytes`);
  }

  const headerEnd = 4 + headerLength;
  if (frame.length < headerEnd) {
    throw new Error("Iroh frame has a truncated JSON header");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(frame.subarray(4, headerEnd).toString("utf8")) as unknown;
  } catch {
    throw new Error("Iroh frame contains malformed JSON");
  }

  if (!isRecord(parsed)) {
    throw new Error("Iroh frame header must be a JSON object");
  }

  const bodyLengthValue = parsed.bodyLength;
  const bodyLength = bodyLengthValue === undefined ? 0 : bodyLengthValue;
  if (typeof bodyLength !== "number" || !Number.isSafeInteger(bodyLength) || bodyLength < 0) {
    throw new Error("Iroh frame bodyLength must be a non-negative safe integer");
  }

  if (options.maxBodyBytes !== undefined && bodyLength > options.maxBodyBytes) {
    throw new Error(`Iroh frame body exceeds ${options.maxBodyBytes} bytes`);
  }

  const bodyEnd = headerEnd + bodyLength;
  if (frame.length < bodyEnd) {
    throw new Error("Iroh frame has a truncated body");
  }
  if (frame.length > bodyEnd) {
    throw new Error("Iroh frame has trailing bytes after body");
  }

  return {
    header: parsed,
    body: frame.subarray(headerEnd, bodyEnd),
  };
}

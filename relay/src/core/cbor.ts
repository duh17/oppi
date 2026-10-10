/**
 * Minimal CBOR (RFC 8949) decoder for App Attest attestation and assertion objects:
 * unsigned and negative integers, byte and text strings, arrays, maps, and simple values.
 * Indefinite lengths, tags, and floats are rejected; App Attest objects use none of them.
 */

export type CborValue =
  | number
  | Uint8Array
  | string
  | CborValue[]
  | Map<CborValue, CborValue>
  | boolean
  | null;

const MAX_DEPTH = 8;
const MAX_ITEMS = 256;

class Reader {
  offset = 0;
  constructor(readonly bytes: Uint8Array) {}

  byte(): number {
    const value = this.bytes[this.offset];
    if (value === undefined) throw new Error("cbor: truncated");
    this.offset += 1;
    return value;
  }

  take(length: number): Uint8Array {
    if (length > this.bytes.length - this.offset) throw new Error("cbor: truncated");
    const slice = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return slice;
  }

  argument(info: number): number {
    if (info < 24) return info;
    if (info === 24) return this.byte();
    if (info === 25) return (this.byte() << 8) | this.byte();
    if (info === 26) {
      const bytes = this.take(4);
      return ((bytes[0]! << 24) >>> 0) + (bytes[1]! << 16) + (bytes[2]! << 8) + bytes[3]!;
    }
    throw new Error("cbor: unsupported length");
  }
}

function decodeItem(reader: Reader, depth: number): CborValue {
  if (depth > MAX_DEPTH) throw new Error("cbor: too deep");
  const initial = reader.byte();
  const major = initial >> 5;
  const info = initial & 0x1f;
  switch (major) {
    case 0:
      return reader.argument(info);
    case 1:
      return -1 - reader.argument(info);
    case 2:
      return reader.take(reader.argument(info)).slice();
    case 3:
      return new TextDecoder("utf-8", { fatal: true }).decode(reader.take(reader.argument(info)));
    case 4: {
      const count = reader.argument(info);
      if (count > MAX_ITEMS) throw new Error("cbor: array too long");
      const items: CborValue[] = [];
      for (let index = 0; index < count; index += 1) items.push(decodeItem(reader, depth + 1));
      return items;
    }
    case 5: {
      const count = reader.argument(info);
      if (count > MAX_ITEMS) throw new Error("cbor: map too long");
      const map = new Map<CborValue, CborValue>();
      for (let index = 0; index < count; index += 1) {
        const key = decodeItem(reader, depth + 1);
        map.set(key, decodeItem(reader, depth + 1));
      }
      return map;
    }
    case 7:
      if (info === 20) return false;
      if (info === 21) return true;
      if (info === 22) return null;
      throw new Error("cbor: unsupported simple value");
    default:
      throw new Error("cbor: unsupported major type");
  }
}

/** Decode exactly one item; trailing bytes are an error. */
export function decodeCbor(bytes: Uint8Array): CborValue {
  const reader = new Reader(bytes);
  const value = decodeItem(reader, 0);
  if (reader.offset !== bytes.length) throw new Error("cbor: trailing bytes");
  return value;
}

export function cborMapGet(value: CborValue, key: string): CborValue | undefined {
  return value instanceof Map ? value.get(key) : undefined;
}

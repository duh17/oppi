/**
 * Positional reads and bounded structure walking shared by the two audio header
 * passes: `audio-duration.ts` (length and format) and `audio-tags.ts` (tags).
 *
 * Input may be crafted, so every read goes through `BoundedReader`: it stays
 * inside the file, each read is at most `MAX_READ_BYTES`, one pass reads at most
 * its budget, and the deadline is checked before every read. Every walk has an
 * iteration cap and no buffer is sized from file data. Anything unrecognized or
 * malformed throws `Unknown`, which the pass that owns the section turns into a
 * missing field.
 */

/** Positional reads over one already-open file. */
export interface AudioByteSource {
  readonly size: number;
  /** Fills `buffer` from `position`; resolves to the bytes read. */
  read(buffer: Uint8Array, position: number): Promise<number>;
}

const MAX_READ_BYTES = 64 * 1024;
/** One pass over a file reads at most this much; the tag pass gets its own. */
const MAX_PASS_READ_BYTES = 512 * 1024;

class Unknown extends Error {}

/** Abandons the current section: the caller reports its fields as unknown. */
export function unknown(): never {
  throw new Unknown();
}

export class BoundedReader {
  private budgetLeft: number;

  constructor(
    private readonly source: AudioByteSource,
    private readonly deadline: AbortSignal,
    budgetBytes: number = MAX_PASS_READ_BYTES,
  ) {
    this.budgetLeft = budgetBytes;
  }

  get size(): number {
    return this.source.size;
  }

  /** Exactly `length` bytes at `position`, or unknown. */
  async read(position: number, length: number): Promise<Buffer> {
    this.deadline.throwIfAborted();
    if (
      !Number.isSafeInteger(position) ||
      position < 0 ||
      !Number.isSafeInteger(length) ||
      length < 0 ||
      length > MAX_READ_BYTES ||
      position + length > this.source.size
    ) {
      unknown();
    }
    this.budgetLeft -= length;
    if (this.budgetLeft < 0) unknown();
    const buffer = Buffer.alloc(length);
    let filled = 0;
    while (filled < length) {
      const n = await this.source.read(buffer.subarray(filled), position + filled);
      if (n <= 0) unknown();
      filled += n;
    }
    return buffer;
  }
}

// MARK: - MP4 / ISO BMFF boxes

export interface Box {
  type: string;
  /** Payload range, after the header. */
  start: number;
  end: number;
}

/** Boxes read while walking one movie; shared across every nested walk. */
export interface BoxBudget {
  left: number;
}

export function newBoxBudget(cap: number): BoxBudget {
  return { left: cap };
}

/** The boxes in [start, end), in order; a malformed header is unknown. */
export async function* childBoxes(
  reader: BoundedReader,
  start: number,
  end: number,
  boxes: BoxBudget,
): AsyncGenerator<Box> {
  let offset = start;
  while (offset + 8 <= end) {
    if (--boxes.left < 0) unknown();
    const header = await reader.read(offset, 8);
    const declared = header.readUInt32BE(0);
    let headerSize = 8;
    let boxEnd: number;
    if (declared === 1) {
      if (offset + 16 > end) unknown();
      boxEnd = offset + uint64BE(await reader.read(offset + 8, 8), 0);
      headerSize = 16;
    } else if (declared === 0) {
      boxEnd = end; // The box runs to the end of its parent (the file at top level).
    } else {
      boxEnd = offset + declared;
    }
    if (boxEnd - offset < headerSize || boxEnd > end) unknown();
    yield { type: header.toString("latin1", 4, 8), start: offset + headerSize, end: boxEnd };
    offset = boxEnd;
  }
}

/** The first `type` box among the boxes in [start, end), if any. */
export async function findBox(
  reader: BoundedReader,
  start: number,
  end: number,
  type: string,
  boxes: BoxBudget,
): Promise<Box | undefined> {
  for await (const box of childBoxes(reader, start, end, boxes)) {
    if (box.type === type) return box;
  }
  return undefined;
}

// MARK: - Numeric fields

/** A 4-byte syncsafe integer (four 7-bit bytes, high bit clear), or undefined. */
export function syncsafeUInt32(bytes: Buffer, at: number): number | undefined {
  const value = bytes.readUInt32BE(at);
  if ((value & 0x8080_8080) !== 0) return undefined;
  return (
    ((value >>> 3) & 0x0fe0_0000) |
    ((value >>> 2) & 0x001f_c000) |
    ((value >>> 1) & 0x0000_3f80) |
    (value & 0x7f)
  );
}

/** A 64-bit big-endian field as a safe integer, or unknown. */
export function uint64BE(bytes: Buffer, at: number): number {
  return safe(bytes.readUInt32BE(at) * 2 ** 32 + bytes.readUInt32BE(at + 4));
}

/** A 64-bit little-endian field as a safe integer, or unknown. */
export function uint64LE(bytes: Buffer, at: number): number {
  return safe(bytes.readUInt32LE(at + 4) * 2 ** 32 + bytes.readUInt32LE(at));
}

export function safe(value: number): number {
  return Number.isSafeInteger(value) ? value : unknown();
}

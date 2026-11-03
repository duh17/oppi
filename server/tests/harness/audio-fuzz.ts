/**
 * Seeded mutation fuzz for the audio header passes.
 *
 * Each base file is mutated a fixed number of times from a fixed seed, so a
 * failing case replays from its seed. Every case runs under the same guarantees:
 * reads stay inside the file, no single read is over 64 KiB, one pass reads at
 * most 512 KiB, no text value is over 4 KiB, nothing throws, the pass finishes
 * before the deadline, and whatever it reports stays inside the documented
 * ranges.
 */

import type { AudioByteSource } from "../../src/audio-bytes.js";
import type { MediaInfoFormat, MediaInfoTags } from "../../src/types/workspace-files.js";

/** An in-memory file that counts the bytes a pass reads. */
export function source(bytes: Buffer): AudioByteSource & { bytesRead: number } {
  return {
    size: bytes.length,
    bytesRead: 0,
    async read(buffer, position) {
      const n = bytes.copy(buffer, 0, position, position + buffer.length);
      this.bytesRead += n;
      return n;
    },
  };
}

export const READ_BUDGET_BYTES = 512 * 1024;
/** The reader's own ceiling for one read (`audio-bytes.ts`). */
const READ_MAX_BYTES = 64 * 1024;
/** The tag pass's ceiling for one text value (`audio-tags.ts`). */
const TEXT_VALUE_MAX_BYTES = 4 * 1024;
export const DEADLINE_MS = 5_000;

/** mulberry32: small and seeded, so a failing case replays from its seed. */
export function seeded(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b_79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 2 ** 32;
  };
}

/** Size, count, and timing fields worth overwriting, with their byte order. */
function sizeFields(bytes: Buffer): { at: number; littleEndian: boolean }[] {
  const fields: { at: number; littleEndian: boolean }[] = [];
  const each = (tag: string, offsets: number[], littleEndian: boolean) => {
    for (let at = bytes.indexOf(tag, 0, "latin1"); at !== -1;) {
      for (const offset of offsets) fields.push({ at: at + offset, littleEndian });
      at = bytes.indexOf(tag, at + 1, "latin1");
    }
  };
  for (const tag of ["RIFF", "RF64", "fmt ", "data", "ds64", "LIST", "INFO"]) {
    each(tag, [4], true);
  }
  each("ds64", [16, 20], true);
  for (const tag of ["ftyp", "moov", "trak", "mdia", "hdlr", "mdat", "free", "udta", "meta"]) {
    each(tag, [-4], false);
  }
  // Box size, then timescale and duration (v0 layout).
  for (const tag of ["mvhd", "mdhd"]) each(tag, [-4, 16, 20], false);
  for (const tag of ["Xing", "Info"]) each(tag, [4, 8], false);
  each("VBRI", [14], false);
  each("ID3", [6], false);
  // Block header, then STREAMINFO's sample rate and sample count.
  each("fLaC", [4, 18, 22], false);
  // Value length of the tag chunks the tag pass reads.
  for (const tag of ["ilst", "data", "esds", "stsd", "id3 "]) each(tag, [-4], false);
  return fields.filter(({ at }) => at >= 0 && at + 4 <= bytes.length);
}

const INTERESTING_U32 = [0, 1, 7, 8, 16, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff];

/** One to four byte flips, truncations, insertions, or size-field overwrites. */
export function mutate(base: Buffer, random: () => number): Buffer {
  const pick = (n: number) => Math.floor(random() * n);
  const fields = sizeFields(base);
  let bytes = Buffer.from(base);
  for (let steps = 1 + pick(4); steps > 0; steps--) {
    switch (pick(4)) {
      case 0:
        for (let flips = 1 + pick(8); flips > 0 && bytes.length > 0; flips--) {
          const at = pick(bytes.length);
          bytes.writeUInt8(bytes.readUInt8(at) ^ (1 + pick(255)), at);
        }
        break;
      case 1:
        bytes = bytes.subarray(0, pick(bytes.length + 1));
        break;
      case 2: {
        const at = pick(bytes.length + 1);
        const inserted = Buffer.from(Array.from({ length: 1 + pick(64) }, () => pick(256)));
        bytes = Buffer.concat([bytes.subarray(0, at), inserted, bytes.subarray(at)]);
        break;
      }
      default: {
        const field = fields[pick(fields.length)];
        if (!field || field.at + 4 > bytes.length) break;
        const values = [...INTERESTING_U32, bytes.length, bytes.length - field.at, pick(2 ** 32)];
        const value = (values[pick(values.length)] ?? 0) >>> 0;
        if (field.littleEndian) bytes.writeUInt32LE(value, field.at);
        else bytes.writeUInt32BE(value, field.at);
      }
    }
  }
  return bytes;
}

/**
 * Runs `parse` on one mutated file. The parse returns the first broken
 * guarantee it sees beyond the shared ones; this reports the shared ones itself.
 */
export async function boundedPassProblem<T>(
  bytes: Buffer,
  parse: (
    file: AudioByteSource & { bytesRead: number },
    deadline: AbortSignal,
  ) => Promise<{ result: T; problem?: string }>,
): Promise<string | undefined> {
  const file = source(bytes);
  const read = file.read.bind(file);
  let outside: string | undefined;
  let largestRead = 0;
  file.read = (buffer, position) => {
    if (position < 0 || position + buffer.length > bytes.length) {
      outside ??= `read ${buffer.length} bytes at ${position} of ${bytes.length}`;
    }
    largestRead = Math.max(largestRead, buffer.length);
    return read(buffer, position);
  };
  const started = performance.now();
  let problem: string | undefined;
  try {
    ({ problem } = await parse(file, AbortSignal.timeout(DEADLINE_MS)));
  } catch (error) {
    return `threw ${String(error)}`;
  }
  const elapsed = performance.now() - started;
  if (outside) return outside;
  if (largestRead > READ_MAX_BYTES) return `read ${largestRead} bytes in one read`;
  if (file.bytesRead > READ_BUDGET_BYTES) return `read ${file.bytesRead} bytes in total`;
  if (elapsed >= DEADLINE_MS) return `took ${elapsed.toFixed(0)} ms`;
  return problem;
}

/** Every format number inside its documented range, or the first that is not. */
export function formatProblem(format: MediaInfoFormat | undefined): string | undefined {
  if (format === undefined) return undefined;
  if (typeof format.codec !== "string" || format.codec.length === 0) {
    return `codec ${String(format.codec)}`;
  }
  const ranges = [
    ["sample rate", format.sampleRate, 8_000, 768_000],
    ["channels", format.channels, 1, 32],
    ["bitrate", format.bitrate, 1_000, 10_000_000],
  ] as const;
  for (const [field, value, min, max] of ranges) {
    if (value === undefined) continue;
    if (!Number.isInteger(value) || value < min || value > max) return `${field} ${value}`;
  }
  return undefined;
}

/** Every tag value inside the text rules, or the first that is not. */
export function tagsProblem(tags: MediaInfoTags | undefined): string | undefined {
  if (tags === undefined) return undefined;
  // The same class the tag pass strips (`audio-tags.ts`), with the control range
  // it removes on purpose.
  const unsafe =
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]/;
  for (const field of ["title", "artist", "album"] as const) {
    const value = tags[field];
    if (value === undefined) continue;
    if (typeof value !== "string" || value.length === 0) return `${field} ${String(value)}`;
    if (value !== value.trim()) return `${field} untrimmed`;
    if (unsafe.test(value)) return `${field} has a control, bidi, or separator character`;
    if (Buffer.byteLength(value, "utf8") > TEXT_VALUE_MAX_BYTES) {
      return `${field} over ${TEXT_VALUE_MAX_BYTES} bytes`;
    }
    // Count code points, so one emoji is one character.
    if (Array.from(value).length > 256) return `${field} over 256 characters`;
  }
  return undefined;
}

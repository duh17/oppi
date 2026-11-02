import { describe, expect, it } from "vitest";

import {
  type AudioByteSource,
  MAX_DURATION_SECONDS,
  readAudioDuration,
} from "../src/audio-duration.js";

/** An in-memory file that counts the bytes a parse reads. */
function source(bytes: Buffer): AudioByteSource & { bytesRead: number } {
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

function duration(bytes: Buffer, deadline = AbortSignal.timeout(5_000)) {
  return readAudioDuration(source(bytes), deadline);
}

function ascii(text: string): Buffer {
  return Buffer.from(text, "latin1");
}

function u32le(value: number): Buffer {
  const out = Buffer.alloc(4);
  out.writeUInt32LE(value);
  return out;
}

function u64le(value: number): Buffer {
  const out = Buffer.alloc(8);
  out.writeBigUInt64LE(BigInt(value));
  return out;
}

function u64be(value: number): Buffer {
  const out = Buffer.alloc(8);
  out.writeBigUInt64BE(BigInt(value));
  return out;
}

function u32be(value: number): Buffer {
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value);
  return out;
}

function riffChunk(id: string, body: Buffer, declaredSize = body.length): Buffer {
  const pad = body.length % 2 === 1 ? Buffer.alloc(1) : Buffer.alloc(0);
  return Buffer.concat([ascii(id), u32le(declaredSize), body, pad]);
}

/** 16-bit PCM `fmt ` body. */
function pcmFormat(sampleRate: number, channels: number): Buffer {
  const fmt = Buffer.alloc(16);
  fmt.writeUInt16LE(1, 0);
  fmt.writeUInt16LE(channels, 2);
  fmt.writeUInt32LE(sampleRate, 4);
  fmt.writeUInt32LE(sampleRate * channels * 2, 8);
  fmt.writeUInt16LE(channels * 2, 12);
  fmt.writeUInt16LE(16, 14);
  return fmt;
}

function wav(
  seconds: number,
  options: { sampleRate?: number; channels?: number; before?: Buffer[]; dataSize?: number } = {},
): Buffer {
  const { sampleRate = 8_000, channels = 1, before = [] } = options;
  const data = Buffer.alloc(Math.round(seconds * sampleRate) * channels * 2);
  const body = Buffer.concat([
    ascii("WAVE"),
    riffChunk("fmt ", pcmFormat(sampleRate, channels)),
    ...before,
    riffChunk("data", data, options.dataSize ?? data.length),
  ]);
  return Buffer.concat([ascii("RIFF"), u32le(body.length), body]);
}

function rf64(seconds: number, sampleRate = 16_000): Buffer {
  const data = Buffer.alloc(seconds * sampleRate * 2);
  const ds64 = Buffer.concat([u64le(0), u64le(data.length), u64le(seconds * sampleRate), u32le(0)]);
  return Buffer.concat([
    ascii("RF64"),
    u32le(0xffff_ffff),
    ascii("WAVE"),
    riffChunk("ds64", ds64),
    riffChunk("fmt ", pcmFormat(sampleRate, 1)),
    ascii("data"),
    u32le(0xffff_ffff),
    data,
  ]);
}

function rf64WithDataSize(dataSize: bigint): Buffer {
  const file = rf64(1);
  // RIFF header (12), ds64 chunk header (8), RIFF size (8), then the data size.
  file.writeBigUInt64LE(dataSize, 28);
  return file;
}

/** MPEG-1 Layer III, 128 kbps, 44.1 kHz, joint stereo: 417-byte frames of 1152 samples. */
const MPEG1_HEADER = [0xff, 0xfb, 0x90, 0x44];
/** MPEG-2 Layer III, 64 kbps, 22.05 kHz, mono: 208-byte frames of 576 samples. */
const MPEG2_MONO_HEADER = [0xff, 0xf3, 0x80, 0xc0];

function mp3Frame(header: number[], length: number, payload?: { at: number; bytes: Buffer }) {
  const frame = Buffer.alloc(length);
  frame.set(header, 0);
  if (payload) payload.bytes.copy(frame, payload.at);
  return frame;
}

function mp3(options: {
  frames: number;
  header?: number[];
  frameLength?: number;
  /** A leading Xing/Info/VBRI frame and the frame count it reports. */
  vbr?: { tag: "Xing" | "Info" | "VBRI"; frames: number };
  id3v2?: number;
  id3v1?: boolean;
}): Buffer {
  const header = options.header ?? MPEG1_HEADER;
  const frameLength = options.frameLength ?? 417;
  const sideInfo = header === MPEG2_MONO_HEADER ? 9 : 32;
  const parts: Buffer[] = [];
  if (options.id3v2 !== undefined) {
    const size = options.id3v2;
    const syncsafe = [(size >> 21) & 0x7f, (size >> 14) & 0x7f, (size >> 7) & 0x7f, size & 0x7f];
    parts.push(Buffer.from([...ascii("ID3"), 3, 0, 0, ...syncsafe]), Buffer.alloc(size));
  }
  if (options.vbr) {
    const { tag, frames } = options.vbr;
    const bytes =
      tag === "VBRI"
        ? Buffer.concat([ascii("VBRI"), Buffer.from([0, 1, 0, 0, 0, 75]), u32be(0), u32be(frames)])
        : // Flags: frame count and stream bytes present, as LAME writes them.
          Buffer.concat([ascii(tag), u32be(3), u32be(frames), u32be((frames + 1) * frameLength)]);
    parts.push(mp3Frame(header, frameLength, { at: tag === "VBRI" ? 36 : 4 + sideInfo, bytes }));
  }
  for (let i = 0; i < options.frames; i++) parts.push(mp3Frame(header, frameLength));
  if (options.id3v1) parts.push(Buffer.concat([ascii("TAG"), Buffer.alloc(125)]));
  return Buffer.concat(parts);
}

/** MPEG-1 Layer III at 48 kHz: frames of 3 bytes per kbps, 1152 samples. */
const MPEG1_48K_BITRATE_INDEX = { 96: 7, 128: 9, 160: 10, 192: 11, 224: 12 } as const;

/** Header-less MP3 whose frames take the given bitrates in turn. */
function mp3AtBitrates(bitrates: (keyof typeof MPEG1_48K_BITRATE_INDEX)[]): Buffer {
  return Buffer.concat(
    bitrates.map((kbps) =>
      mp3Frame([0xff, 0xfb, (MPEG1_48K_BITRATE_INDEX[kbps] << 4) | 0x04, 0x44], 3 * kbps),
    ),
  );
}

function id3Tags(count: number): Buffer {
  return Buffer.concat(
    Array.from({ length: count }, () => Buffer.from([...ascii("ID3"), 3, 0, 0, 0, 0, 0, 0])),
  );
}

function box(type: string, ...children: Buffer[]): Buffer {
  const body = Buffer.concat(children);
  return Buffer.concat([u32be(8 + body.length), ascii(type), body]);
}

/** A box whose size is in the 64-bit `largesize` field. */
function largeBox(type: string, body: Buffer): Buffer {
  const largesize = Buffer.alloc(8);
  largesize.writeBigUInt64BE(BigInt(16 + body.length));
  return Buffer.concat([u32be(1), ascii(type), largesize, body]);
}

/** An `mvhd`, or an `mdhd`, which shares its leading layout. */
function mvhd(
  version: 0 | 1,
  timescale: number,
  units: number,
  type: "mvhd" | "mdhd" = "mvhd",
): Buffer {
  if (version === 0) {
    return box(type, Buffer.alloc(12), u32be(timescale), u32be(units), Buffer.alloc(80));
  }
  const fields = Buffer.alloc(32);
  fields[0] = 1;
  fields.writeUInt32BE(timescale, 20);
  fields.writeBigUInt64BE(BigInt(units), 24);
  return box(type, fields, Buffer.alloc(80));
}

function mdhd(version: 0 | 1, timescale: number, units: number): Buffer {
  return mvhd(version, timescale, units, "mdhd");
}

function trak(handler: "soun" | "vide", mediaHeader: Buffer): Buffer {
  const hdlr = box("hdlr", Buffer.alloc(8), ascii(handler), Buffer.alloc(12));
  return box("trak", box("tkhd", Buffer.alloc(84)), box("mdia", mediaHeader, hdlr, box("minf")));
}

function movie(...moovChildren: Buffer[]): Buffer {
  return Buffer.concat([
    box("ftyp", ascii("M4A "), u32be(0)),
    box("moov", ...moovChildren),
    box("mdat", Buffer.alloc(64)),
  ]);
}

/** `mvhd` says 0; the first audio track (after a video track) says 3 s. */
const mdhdFallback = movie(
  mvhd(0, 1_000, 0),
  trak("vide", mdhd(0, 90_000, 90_000 * 10)),
  trak("soun", mdhd(0, 44_100, 44_100 * 3)),
);

function mp4(header: Buffer, before: Buffer[] = []): Buffer {
  return Buffer.concat([
    box("ftyp", ascii("M4A "), u32be(0), ascii("M4A isom")),
    ...before,
    box("moov", box("udta"), header, box("trak")),
    box("mdat", Buffer.alloc(64)),
  ]);
}

function flac(sampleRate: number, totalSamples: number): Buffer {
  const info = Buffer.alloc(34);
  info.writeUInt16BE(4096, 0);
  info.writeUInt16BE(4096, 2);
  // 20-bit sample rate, 3-bit channels-1, 5-bit bits-per-sample-1, 36-bit samples.
  info[10] = (sampleRate >> 12) & 0xff;
  info[11] = (sampleRate >> 4) & 0xff;
  info[12] = ((sampleRate & 0x0f) << 4) | (1 << 1) | 0;
  info[13] = (15 << 4) | Math.floor(totalSamples / 2 ** 32);
  info.writeUInt32BE(totalSamples % 2 ** 32, 14);
  return Buffer.concat([ascii("fLaC"), Buffer.from([0x80, 0, 0, 34]), info, Buffer.alloc(256)]);
}

// A WAV piped out of ffmpeg has no seekable header to patch, so its data size
// stays 0xFFFFFFFF; a recording cut short claims more data than it holds.
const streamedWav = wav(1);
streamedWav.writeUInt32LE(0xffff_ffff, 40);

const valid: [string, Buffer, number][] = [
  ["WAV", wav(4.5), 4.5],
  ["streamed WAV (data size 0xFFFFFFFF)", streamedWav, 1],
  ["WAV cut short mid-data", wav(2).subarray(0, 44 + 8_000), 0.5],
  [
    "WAV with odd-size chunks before data",
    wav(2, { sampleRate: 22_050, channels: 2, before: [riffChunk("junk", Buffer.alloc(3))] }),
    2,
  ],
  ["RF64", rf64(3), 3],
  ["MP3 with Xing", mp3({ frames: 100, vbr: { tag: "Xing", frames: 100 } }), (100 * 1152) / 44_100],
  [
    "MPEG-2 mono MP3 with Info",
    mp3({
      frames: 50,
      header: MPEG2_MONO_HEADER,
      frameLength: 208,
      vbr: { tag: "Info", frames: 50 },
    }),
    (50 * 576) / 22_050,
  ],
  ["MP3 with VBRI", mp3({ frames: 80, vbr: { tag: "VBRI", frames: 80 } }), (80 * 1152) / 44_100],
  // Constant bitrate: audio bytes (file less both tags) at 128 kbps.
  [
    "CBR MP3 with ID3v2 and ID3v1",
    mp3({ frames: 120, id3v2: 300, id3v1: true }),
    (120 * 417 * 8) / 128_000,
  ],
  ["MP4 mvhd v0", mp4(mvhd(0, 44_100, 44_100 * 7)), 7],
  [
    "MP4 mvhd v1 after a 64-bit largesize box",
    mp4(mvhd(1, 1_000, 61_250), [largeBox("free", Buffer.alloc(8))]),
    61.25,
  ],
  [
    "MP4 whose last box has size 0 (to the end of the file)",
    Buffer.concat([
      box("ftyp", ascii("qt  "), u32be(0)),
      box("mdat", Buffer.alloc(32)),
      Buffer.concat([u32be(0), ascii("moov"), mvhd(0, 600, 1_500)]),
    ]),
    2.5,
  ],
  ["FLAC", flac(44_100, 44_100 * 3.5), 3.5],
  ["MP4 with mvhd duration 0, from the first audio track's mdhd v0", mdhdFallback, 3],
  [
    "MP4 without mvhd, from the audio track's mdhd v1",
    movie(trak("soun", mdhd(1, 48_000, 48_000 * 4.5))),
    4.5,
  ],
  [
    "CBR MP3 after the most ID3v2 tags read",
    Buffer.concat([id3Tags(8), mp3({ frames: 40 })]),
    (40 * 417 * 8) / 128_000,
  ],
];

function withU32(bytes: Buffer, at: number, value: number, endian: "le" | "be"): Buffer {
  const out = Buffer.from(bytes);
  if (endian === "le") out.writeUInt32LE(value, at);
  else out.writeUInt32BE(value, at);
  return out;
}

/** Byte offset of the chunk or box size field preceding `type`. */
function sizeOf(bytes: Buffer, type: string, occurrence = 0): number {
  let at = -1;
  for (let i = 0; i <= occurrence; i++) at = bytes.indexOf(type, at + 1, "latin1");
  return type === "data" || type === "fmt " ? at + 4 : at - 4;
}

const wavFile = wav(1);
const mp4File = mp4(mvhd(0, 1_000, 5_000));
const nestingBomb = (() => {
  const depth = 20_000;
  const inner = mvhd(0, 1_000, 5_000);
  const headers = Array.from({ length: depth }, (_, level) =>
    Buffer.concat([u32be(8 * (depth - level) + inner.length), ascii("moov")]),
  );
  return Buffer.concat([box("ftyp", ascii("isom")), ...headers, inner]);
})();

const crafted: [string, Buffer][] = [
  ["an empty file", Buffer.alloc(0)],
  ["text", ascii("not a wave file")],
  ...valid.flatMap(([name, bytes]) =>
    [3, 11, 20].map((cut): [string, Buffer] => [
      `${name} cut to ${cut} bytes`,
      bytes.subarray(0, cut),
    ]),
  ),
  ["WAV data size 0", withU32(wavFile, sizeOf(wavFile, "data"), 0, "le")],
  ["WAV fmt size 0", withU32(wavFile, sizeOf(wavFile, "fmt "), 0, "le")],
  ["WAV fmt past the end", withU32(wavFile, sizeOf(wavFile, "fmt "), 0xffff_fff0, "le")],
  ["WAV byte rate 0", withU32(wavFile, sizeOf(wavFile, "fmt ") + 12, 0, "le")],
  [
    "WAV of 100,000 empty chunks",
    wav(1, { before: Array.from({ length: 100_000 }, () => riffChunk("junk", Buffer.alloc(0))) }),
  ],
  [
    "RF64 without ds64",
    Buffer.concat([ascii("RF64"), u32le(0), ascii("WAVE"), rf64(1).subarray(48)]),
  ],
  ["MP4 moov size ~0", withU32(mp4File, sizeOf(mp4File, "moov"), 0xffff_ffff, "be")],
  ["MP4 moov past the end", withU32(mp4File, sizeOf(mp4File, "moov"), mp4File.length, "be")],
  ["MP4 box size below its header", withU32(mp4File, sizeOf(mp4File, "moov"), 4, "be")],
  ["MP4 ftyp size 0 swallowing moov", withU32(mp4File, sizeOf(mp4File, "ftyp"), 0, "be")],
  ["MP4 largesize 0", Buffer.concat([u32be(1), ascii("ftyp"), Buffer.alloc(8), mp4File])],
  ["MP4 largesize ~0", Buffer.concat([u32be(1), ascii("ftyp"), Buffer.alloc(8, 0xff), mp4File])],
  [
    "MP4 largesize above 2^53",
    Buffer.concat([u32be(1), ascii("free"), u64be(2 ** 53 + 16), mp4File]),
  ],
  ["RF64 ds64 data size above 2^53", rf64WithDataSize(2n ** 53n + 2n)],
  ["MP4 timescale 0", withU32(mp4File, sizeOf(mp4File, "mvhd") + 20, 0, "be")],
  ["MP4 duration ~0 (unknown)", withU32(mp4File, sizeOf(mp4File, "mvhd") + 24, 0xffff_ffff, "be")],
  ["MP4 mvhd version 2", withU32(mp4File, sizeOf(mp4File, "mvhd") + 8, 0x0200_0000, "be")],
  ["MP4 nesting bomb of 20,000 moov boxes", nestingBomb],
  [
    "fragmented MP4 (mvex) whose mvhd says 0",
    Buffer.concat([
      movie(
        mvhd(0, 1_000, 0),
        trak("soun", mdhd(0, 44_100, 44_100 * 2)),
        box("mvex", box("trex", Buffer.alloc(24))),
      ),
      box("moof", box("mfhd", Buffer.alloc(8))),
    ]),
  ],
  [
    "MP4 whose mvhd says 0 with only a video track",
    movie(mvhd(0, 1_000, 0), trak("vide", mdhd(0, 90_000, 90_000 * 10))),
  ],
  [
    "MP4 whose audio track has no mdhd",
    movie(
      mvhd(0, 1_000, 0),
      box("trak", box("mdia", box("hdlr", Buffer.alloc(8), ascii("soun"), Buffer.alloc(12)))),
    ),
  ],
  [
    "MP4 of 5,000 boxes before moov",
    mp4(
      mvhd(0, 1_000, 5_000),
      Array.from({ length: 5_000 }, () => box("free")),
    ),
  ],
  ["FLAC sample rate 0", flac(0, 44_100)],
  ["FLAC total samples 0", flac(44_100, 0)],
  [
    "FLAC without STREAMINFO first",
    Buffer.concat([ascii("fLaC"), Buffer.from([0x84]), flac(44_100, 44_100).subarray(5)]),
  ],
  [
    "CBR MP3 behind more ID3v2 tags than are read",
    Buffer.concat([id3Tags(9), mp3({ frames: 40 })]),
  ],
  // Formats without a parser must not reach the MP3 frame search, even when
  // they carry MP3-like bytes.
  ...(
    [
      ["AIFF", "FORM"],
      ["CAF", "caff"],
      ["Ogg", "OggS"],
      ["Matroska", "\x1a\x45\xdf\xa3"],
    ] as const
  ).map(([format, magic]): [string, Buffer] => [
    `${format} file holding MP3 frames`,
    Buffer.concat([ascii(magic), Buffer.alloc(8), mp3({ frames: 40 })]),
  ]),
  ["ID3 size past the end", mp3({ frames: 10, id3v2: 300 }).subarray(0, 200)],
  [
    "ID3 size that is not syncsafe",
    Buffer.concat([ascii("ID3"), Buffer.from([3, 0, 0, 0, 0, 0x80, 0]), mp3({ frames: 10 })]),
  ],
  [
    "MP3 with no frame sync",
    Buffer.concat([mp3({ frames: 0, id3v2: 64 }), Buffer.alloc(100_000, 0x55)]),
  ],
  [
    "MP3 with a lone frame header among junk",
    Buffer.concat([Buffer.from(MPEG1_HEADER), Buffer.alloc(100_000, 0x55)]),
  ],
  ["MP3 sync patterns filling the search window", Buffer.alloc(200_000, 0xff)],
  [
    "MP3 frame headers that never chain into a next frame",
    Buffer.alloc(200_000, Buffer.from(MPEG1_HEADER)),
  ],
];

describe("readAudioDuration on malformed input", () => {
  it.each(crafted)(
    "reports %s as unknown quickly, within its read budget",
    async (_name, bytes) => {
      const file = source(bytes);
      const started = performance.now();
      expect(await readAudioDuration(file, AbortSignal.timeout(5_000))).toBeUndefined();
      expect(performance.now() - started).toBeLessThan(500);
      expect(file.bytesRead).toBeLessThanOrEqual(512 * 1024);
    },
  );

  it("stops at the deadline", async () => {
    expect(await duration(wav(1), AbortSignal.abort())).toBeUndefined();
  });

  it("stops when the deadline passes mid-parse", async () => {
    const deadline = new AbortController();
    const file = source(wav(1));
    const read = file.read.bind(file);
    file.read = async (buffer, position) => {
      const n = await read(buffer, position);
      deadline.abort();
      return n;
    };
    expect(await readAudioDuration(file, deadline.signal)).toBeUndefined();
    expect(file.bytesRead).toBe(12);
  });

  it.each([
    ["alternating", [128, 160, 192, 96, 224] as const],
    ["steady for four frames, then varying", [128, 128, 128, 128, 160, 192, 96] as const],
  ])("reports a VBR MP3 without Xing/Info/VBRI (%s bitrates) as unknown", async (_name, cycle) => {
    const bitrates = Array.from({ length: 300 }, (_, i) => cycle[i % cycle.length] ?? 128);
    expect(await duration(mp3AtBitrates(bitrates))).toBeUndefined();
  });

  it("reports a read error as unknown", async () => {
    const failing: AudioByteSource = {
      size: 1_000,
      read: () => Promise.reject(new Error("EIO")),
    };
    expect(await readAudioDuration(failing, AbortSignal.timeout(5_000))).toBeUndefined();
  });
});

describe("readAudioDuration", () => {
  it.each(valid)("reads the length of %s", async (_name, bytes, seconds) => {
    expect(await duration(bytes)).toBeCloseTo(seconds, 6);
  });
});

// MARK: - Seeded mutation fuzz

const FUZZ_SEED = 0x5eed_a0d1;
const FUZZ_CASES_PER_FORMAT = 2_000;
const DEADLINE_MS = 5_000;
const READ_BUDGET_BYTES = 512 * 1024;

/** mulberry32: small and seeded, so a failing case replays from its seed. */
function seeded(seed: number): () => number {
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
  for (const tag of ["RIFF", "RF64", "fmt ", "data", "ds64"]) each(tag, [4], true);
  each("ds64", [16, 20], true);
  for (const tag of ["ftyp", "moov", "trak", "mdia", "hdlr", "mdat", "free", "udta"]) {
    each(tag, [-4], false);
  }
  // Box size, then timescale and duration (v0 layout).
  for (const tag of ["mvhd", "mdhd"]) each(tag, [-4, 16, 20], false);
  for (const tag of ["Xing", "Info"]) each(tag, [4, 8], false);
  each("VBRI", [14], false);
  each("ID3", [6], false);
  // Block header, then STREAMINFO's sample rate and sample count.
  each("fLaC", [4, 18, 22], false);
  return fields.filter(({ at }) => at >= 0 && at + 4 <= bytes.length);
}

const INTERESTING_U32 = [0, 1, 7, 8, 16, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff];

/** One to four byte flips, truncations, insertions, or size-field overwrites. */
function mutate(base: Buffer, random: () => number): Buffer {
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

/** The first broken guarantee for one input, or undefined when all hold. */
async function boundedParseProblem(bytes: Buffer): Promise<string | undefined> {
  const file = source(bytes);
  const read = file.read.bind(file);
  let outside: string | undefined;
  file.read = (buffer, position) => {
    if (position < 0 || position + buffer.length > bytes.length) {
      outside ??= `read ${buffer.length} bytes at ${position} of ${bytes.length}`;
    }
    return read(buffer, position);
  };
  const started = performance.now();
  let seconds: number | undefined;
  try {
    seconds = await readAudioDuration(file, AbortSignal.timeout(DEADLINE_MS));
  } catch (error) {
    return `threw ${String(error)}`;
  }
  const elapsed = performance.now() - started;
  if (outside) return outside;
  if (file.bytesRead > READ_BUDGET_BYTES) return `read ${file.bytesRead} bytes in total`;
  if (
    seconds !== undefined &&
    !(Number.isFinite(seconds) && seconds >= 0 && seconds <= MAX_DURATION_SECONDS)
  ) {
    return `length ${seconds}`;
  }
  if (elapsed >= DEADLINE_MS) return `took ${elapsed.toFixed(0)} ms`;
  return undefined;
}

const fuzzBases: [string, Buffer][] = [
  ["WAV", wav(0.5)],
  ["RF64", rf64(1)],
  ["MP3 with Xing", mp3({ frames: 30, vbr: { tag: "Xing", frames: 30 } })],
  ["MP3 with VBRI", mp3({ frames: 30, vbr: { tag: "VBRI", frames: 30 } })],
  ["CBR MP3", mp3({ frames: 30, id3v2: 64, id3v1: true })],
  ["MP4 mvhd v0", mp4(mvhd(0, 44_100, 44_100 * 7))],
  ["MP4 mvhd v1", mp4(mvhd(1, 1_000, 61_250), [largeBox("free", Buffer.alloc(8))])],
  ["MP4 mdhd fallback", mdhdFallback],
  ["FLAC", flac(44_100, 44_100 * 3.5)],
];

describe("readAudioDuration under seeded mutation", () => {
  it.each(fuzzBases.map(([name, bytes], index) => [name, bytes, index] as const))(
    "keeps every guarantee for 2,000 mutated %s files",
    async (name, base, index) => {
      const caseSeeds = seeded(FUZZ_SEED + index);
      const failures: string[] = [];
      for (let n = 0; n < FUZZ_CASES_PER_FORMAT; n++) {
        const seed = Math.floor(caseSeeds() * 2 ** 32);
        const problem = await boundedParseProblem(mutate(base, seeded(seed)));
        // Replay one case with mutate(base, seeded(seed)).
        if (problem) failures.push(`${name} case ${n}, seed 0x${seed.toString(16)}: ${problem}`);
      }
      expect(failures.slice(0, 5), `fuzz seed 0x${FUZZ_SEED.toString(16)}`).toEqual([]);
    },
    30_000,
  );
});

import { describe, expect, it } from "vitest";

import { readAudioHeaders } from "../src/audio-duration.js";
import { source } from "./harness/audio-fuzz.js";

function ascii(text: string): Buffer {
  return Buffer.from(text, "latin1");
}

function u16le(value: number): Buffer {
  const out = Buffer.alloc(2);
  out.writeUInt16LE(value);
  return out;
}

function u32le(value: number): Buffer {
  const out = Buffer.alloc(4);
  out.writeUInt32LE(value);
  return out;
}

function u32be(value: number): Buffer {
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value);
  return out;
}

function riffChunk(id: string, body: Buffer): Buffer {
  const pad = body.length % 2 === 1 ? Buffer.alloc(1) : Buffer.alloc(0);
  return Buffer.concat([ascii(id), u32le(body.length), body, pad]);
}

/** A `fmt ` body; `tag` 0xFFFE adds the extensible sub-format around `subformat`. */
function fmtBody(options: {
  tag?: number;
  channels?: number;
  sampleRate?: number;
  bits?: number;
  byteRate?: number;
  subformat?: number;
}): Buffer {
  const { tag = 1, channels = 1, sampleRate = 8_000, bits = 16 } = options;
  const byteRate = options.byteRate ?? sampleRate * channels * Math.max(1, Math.ceil(bits / 8));
  const basic = Buffer.alloc(16);
  basic.writeUInt16LE(tag, 0);
  basic.writeUInt16LE(channels, 2);
  basic.writeUInt32LE(sampleRate, 4);
  basic.writeUInt32LE(byteRate, 8);
  basic.writeUInt16LE(channels * Math.ceil(bits / 8), 12);
  basic.writeUInt16LE(bits, 14);
  if (tag !== 0xfffe) return basic;
  const guid = Buffer.alloc(16);
  guid.writeUInt16LE(options.subformat ?? 1, 0);
  return Buffer.concat([basic, u16le(22), u16le(bits), u32le(0), guid]);
}

function wavFile(fmt: Buffer, dataBytes: number): Buffer {
  const body = Buffer.concat([
    ascii("WAVE"),
    riffChunk("fmt ", fmt),
    riffChunk("data", Buffer.alloc(dataBytes)),
  ]);
  return Buffer.concat([ascii("RIFF"), u32le(body.length), body]);
}

async function headers(bytes: Buffer) {
  return readAudioHeaders(source(bytes), AbortSignal.timeout(5_000));
}

// MARK: - WAV

describe("WAV format", () => {
  it("reports PCM sample rate, channels and bitrate from `fmt `", async () => {
    const info = await headers(wavFile(fmtBody({ sampleRate: 8_000, channels: 1 }), 16_000));
    expect(info.format).toEqual({ codec: "pcm", sampleRate: 8_000, channels: 1, bitrate: 128_000 });
    expect(info.durationSeconds).toBe(1);
  });

  it("reads 24-bit stereo at 48 kHz", async () => {
    const info = await headers(
      wavFile(fmtBody({ sampleRate: 48_000, channels: 2, bits: 24 }), 288_000),
    );
    expect(info.format).toEqual({
      codec: "pcm",
      sampleRate: 48_000,
      channels: 2,
      bitrate: 2_304_000,
    });
  });

  it("names float samples", async () => {
    const fmt = fmtBody({ tag: 3, sampleRate: 44_100, channels: 2, bits: 32 });
    expect((await headers(wavFile(fmt, 352_800))).format?.codec).toBe("pcm_float");
  });

  it("takes the real codec from an extensible sub-format", async () => {
    const pcm = fmtBody({ tag: 0xfffe, sampleRate: 44_100, channels: 2, bits: 16, subformat: 1 });
    expect((await headers(wavFile(pcm, 176_400))).format?.codec).toBe("pcm");
    const float = fmtBody({ tag: 0xfffe, sampleRate: 44_100, channels: 2, bits: 32, subformat: 3 });
    expect((await headers(wavFile(float, 352_800))).format?.codec).toBe("pcm_float");
  });

  it("names an MP3-in-WAV stream", async () => {
    const fmt = fmtBody({ tag: 0x55, sampleRate: 44_100, channels: 2, byteRate: 16_000, bits: 0 });
    expect((await headers(wavFile(fmt, 32_000))).format?.codec).toBe("mp3");
  });

  it("drops the format of a codec it cannot name, and keeps the length", async () => {
    // 6 is A-law: this server has no codec name for it.
    const fmt = fmtBody({ tag: 6, sampleRate: 8_000, channels: 1, bits: 8 });
    const info = await headers(wavFile(fmt, 8_000));
    expect(info.durationSeconds).toBe(1);
    expect(info.format).toBeUndefined();
  });

  it("drops format numbers outside the audio ranges", async () => {
    const info = await headers(
      wavFile(fmtBody({ sampleRate: 4_000, channels: 0, byteRate: 8_000 }), 8_000),
    );
    expect(info.durationSeconds).toBe(1);
    // The byte rate still states a bitrate; only the unusable numbers are gone.
    expect(info.format).toEqual({ codec: "pcm", bitrate: 64_000 });
  });

  it("drops a bitrate over 10 Mbit/s", async () => {
    const info = await headers(wavFile(fmtBody({ byteRate: 2_000_000 }), 2_000_000));
    expect(info.durationSeconds).toBe(1);
    expect(info.format?.bitrate).toBeUndefined();
  });
});

// MARK: - MP3

/** MPEG-1 Layer III, 128 kbps, 44.1 kHz, joint stereo: 417-byte frames of 1152 samples. */
const MPEG1_HEADER = [0xff, 0xfb, 0x90, 0x44];
/** MPEG-2 Layer III, 64 kbps, 22.05 kHz, mono: 208-byte frames of 576 samples. */
const MPEG2_MONO_HEADER = [0xff, 0xf3, 0x80, 0xc0];
/** MPEG-1 Layer II, 128 kbps, 48 kHz, stereo: 384-byte frames of 1152 samples. */
const MPEG1_LAYER2_HEADER = [0xff, 0xfd, 0x84, 0x00];

function mp3Frame(
  header: number[],
  length: number,
  payload?: { at: number; bytes: Buffer },
): Buffer {
  const frame = Buffer.alloc(length);
  frame.set(header, 0);
  if (payload) payload.bytes.copy(frame, payload.at);
  return frame;
}

function mp3(options: {
  frames: number;
  header?: number[];
  frameLength?: number;
  vbr?: { tag: "Xing" | "VBRI"; frames: number };
  id3v2?: number;
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
        : Buffer.concat([ascii(tag), u32be(3), u32be(frames), u32be((frames + 1) * frameLength)]);
    parts.push(mp3Frame(header, frameLength, { at: tag === "VBRI" ? 36 : 4 + sideInfo, bytes }));
  }
  for (let i = 0; i < options.frames; i++) parts.push(mp3Frame(header, frameLength));
  return Buffer.concat(parts);
}

describe("MP3 format", () => {
  it("reports the first frame's layer, rate, channels and header bitrate", async () => {
    const info = await headers(mp3({ frames: 20 }));
    expect(info.format).toEqual({
      codec: "mp3",
      sampleRate: 44_100,
      channels: 2,
      bitrate: 128_000,
    });
  });

  it("reports an MPEG-2 mono frame", async () => {
    const info = await headers(mp3({ frames: 20, header: MPEG2_MONO_HEADER, frameLength: 208 }));
    expect(info.format).toEqual({ codec: "mp3", sampleRate: 22_050, channels: 1, bitrate: 64_000 });
  });

  it("names MPEG Layer II a different codec", async () => {
    const info = await headers(mp3({ frames: 20, header: MPEG1_LAYER2_HEADER, frameLength: 384 }));
    expect(info.format).toEqual({
      codec: "mp2",
      sampleRate: 48_000,
      channels: 2,
      bitrate: 128_000,
    });
  });

  it("averages the audio bytes over the length of a VBR stream", async () => {
    const info = await headers(mp3({ frames: 100, vbr: { tag: "Xing", frames: 100 } }));
    expect(info.format?.codec).toBe("mp3");
    // 101 frames of 417 bytes over 100 * 1152 / 44100 s.
    expect(info.format?.bitrate).toBeGreaterThan(128_000);
    expect(info.format?.bitrate).toBeLessThan(130_000);
  });

  it("reads the first frame after an ID3v2 tag", async () => {
    const info = await headers(mp3({ frames: 20, id3v2: 300 }));
    expect(info.format?.codec).toBe("mp3");
    expect(info.durationSeconds).toBeCloseTo((20 * 417 * 8) / 128_000, 6);
  });
});

// MARK: - MP4

function box(type: string, ...children: Buffer[]): Buffer {
  const body = Buffer.concat(children);
  return Buffer.concat([u32be(8 + body.length), ascii(type), body]);
}

function mvhd(timescale: number, units: number): Buffer {
  return box("mvhd", Buffer.alloc(12), u32be(timescale), u32be(units), Buffer.alloc(80));
}

function mdhd(timescale: number, units: number): Buffer {
  return box("mdhd", Buffer.alloc(12), u32be(timescale), u32be(units), Buffer.alloc(80));
}

/** An ISO audio sample entry: the 28 fixed bytes, then the codec's own boxes. */
function audioEntry(
  type: string,
  channels: number,
  sampleRate: number,
  ...children: Buffer[]
): Buffer {
  const fields = Buffer.alloc(28);
  fields.writeUInt16BE(1, 6); // data reference index
  fields.writeUInt16BE(channels, 16);
  fields.writeUInt16BE(16, 18); // sample size
  fields.writeUInt32BE(sampleRate * 65_536, 24);
  return box(type, fields, ...children);
}

/** An `esds` full box: ES_Descriptor holding one DecoderConfigDescriptor. */
function esds(avgBitrate: number, objectType = 0x40): Buffer {
  const config = Buffer.alloc(13);
  config.writeUInt8(objectType, 0);
  config.writeUInt8(0x15, 1); // audio stream
  config.writeUInt32BE(avgBitrate, 5);
  config.writeUInt32BE(avgBitrate, 9);
  const decoderConfig = Buffer.concat([Buffer.from([0x04, config.length]), config]);
  const payload = Buffer.concat([Buffer.from([0, 1, 0]), decoderConfig]); // ES_ID, flags
  return box("esds", u32be(0), Buffer.from([0x03, payload.length]), payload);
}

function m4a(entry: Buffer, options: { duration?: number; mdatBytes?: number } = {}): Buffer {
  const { duration = 7, mdatBytes = 64 } = options;
  const hdlr = box("hdlr", Buffer.alloc(8), ascii("soun"), Buffer.alloc(12));
  const stsd = box("stsd", u32be(0), u32be(1), entry);
  const mdia = box(
    "mdia",
    mdhd(44_100, Math.round(44_100 * duration)),
    hdlr,
    box("minf", box("stbl", stsd)),
  );
  return Buffer.concat([
    box("ftyp", ascii("M4A "), u32be(0)),
    box("moov", mvhd(1_000, Math.round(1_000 * duration)), box("trak", mdia)),
    box("mdat", Buffer.alloc(mdatBytes)),
  ]);
}

describe("MP4 format", () => {
  it("reports AAC channels, rate and the esds average bitrate", async () => {
    const info = await headers(m4a(audioEntry("mp4a", 2, 44_100, esds(128_000))));
    expect(info.durationSeconds).toBe(7);
    expect(info.format).toEqual({
      codec: "aac",
      sampleRate: 44_100,
      channels: 2,
      bitrate: 128_000,
    });
  });

  it("falls back to the sample bytes over the length when esds states no bitrate", async () => {
    const info = await headers(m4a(audioEntry("mp4a", 2, 44_100), { mdatBytes: 100_000 }));
    expect(info.format).toEqual({
      codec: "aac",
      sampleRate: 44_100,
      channels: 2,
      bitrate: Math.round((100_000 * 8) / 7),
    });
  });

  it("falls back to the sample bytes when esds states a zero bitrate", async () => {
    const info = await headers(m4a(audioEntry("mp4a", 2, 44_100, esds(0)), { mdatBytes: 84_000 }));
    expect(info.format?.bitrate).toBe(Math.round((84_000 * 8) / 7));
  });

  it("names each codec a sample entry can declare", async () => {
    for (const [type, codec] of [
      ["alac", "alac"],
      ["fLaC", "flac"],
      ["Opus", "opus"],
      ["ac-3", "ac3"],
      ["ec-3", "eac3"],
    ] as const) {
      const info = await headers(m4a(audioEntry(type, 2, 48_000), { mdatBytes: 84_000 }));
      expect(info.format?.codec, type).toBe(codec);
      expect(info.format?.sampleRate).toBe(48_000);
    }
  });

  it("keeps the length when the sample entry names no codec this server reads", async () => {
    const info = await headers(m4a(audioEntry("sowt", 2, 44_100)));
    expect(info.durationSeconds).toBe(7);
    expect(info.format).toBeUndefined();
  });

  it("drops an esds bitrate below 1 kbit/s", async () => {
    const info = await headers(m4a(audioEntry("mp4a", 2, 44_100, esds(500))));
    expect(info.format).toEqual({ codec: "aac", sampleRate: 44_100, channels: 2 });
  });

  it("reports only the codec of a truncated audio sample entry", async () => {
    const info = await headers(m4a(box("mp4a", Buffer.alloc(8))));
    expect(info.durationSeconds).toBe(7);
    expect(info.format).toEqual({ codec: "aac" });
  });
});

// MARK: - FLAC

function flac(sampleRate: number, totalSamples: number, size: number): Buffer {
  const info = Buffer.alloc(34);
  info.writeUInt16BE(4_096, 0);
  info.writeUInt16BE(4_096, 2);
  // 20-bit sample rate, 3-bit channels-1, 5-bit bits-per-sample-1, 36-bit samples.
  info[10] = (sampleRate >> 12) & 0xff;
  info[11] = (sampleRate >> 4) & 0xff;
  info[12] = ((sampleRate & 0x0f) << 4) | (1 << 1);
  info[13] = (15 << 4) | Math.floor(totalSamples / 2 ** 32);
  info.writeUInt32BE(totalSamples % 2 ** 32, 14);
  const streamInfo = Buffer.concat([Buffer.from([0, 0, 0, 34]), info]);
  const padding = Math.max(0, size - (4 + streamInfo.length + 4));
  const paddingHeader = Buffer.from([
    0x81,
    (padding >> 16) & 0xff,
    (padding >> 8) & 0xff,
    padding & 0xff,
  ]);
  return Buffer.concat([ascii("fLaC"), streamInfo, paddingHeader, Buffer.alloc(padding)]);
}

describe("FLAC format", () => {
  it("reports STREAMINFO's rate and channels and the stream's average bitrate", async () => {
    const bytes = flac(44_100, 44_100 * 3, 120_000);
    const info = await headers(bytes);
    expect(info.durationSeconds).toBe(3);
    expect(info.format).toEqual({
      codec: "flac",
      sampleRate: 44_100,
      channels: 2,
      bitrate: Math.round((bytes.length * 8) / 3),
    });
  });
});

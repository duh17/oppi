/**
 * Audio length and format from container headers: WAV/RF64 chunks, MP3
 * Xing/Info/VBRI frames (or a constant-bitrate estimate), MP4 `mvhd` (or the
 * audio track's `mdhd`) with the first audio `stsd`/`esds`, FLAC STREAMINFO.
 *
 * Input may be crafted, so every read goes through `BoundedReader`: it stays
 * inside the file, each read is at most 64 KiB, one parse reads at most 512 KiB,
 * the deadline is checked before every read, and every walk has an iteration cap
 * and no buffer is sized from file data. Anything unrecognized or malformed is
 * "unknown" (`undefined`), never a throw.
 *
 * Tags are a second pass with their own budget (`audio-tags.ts`), and format
 * extraction never costs the length: a container that walks to its length but
 * not to its format still reports the length.
 */

import {
  BoundedReader,
  type AudioByteSource,
  type Box,
  type BoxBudget,
  childBoxes,
  findBox,
  newBoxBudget,
  uint64BE,
  uint64LE,
  unknown,
} from "./audio-bytes.js";
import { detectContainer } from "./audio-container.js";
import type { MediaInfoFormat } from "./types/workspace-files.js";

const MAX_WAV_CHUNKS = 1_024;
const MAX_MP4_BOXES = 1_024;
/** Bytes of the `fmt ` body that carry the codec, channels, rate and byte rate. */
const WAV_FMT_BYTES = 40;
/**
 * About 115 days. A crafted MP4 or FLAC header (timescale or sample rate 1,
 * huge duration) parses to billions of seconds; that is not audio, and a client
 * clock that converts it to an integer would trap.
 */
export const MAX_DURATION_SECONDS = 10_000_000;
/** Bytes searched for the first MP3 frame after any ID3v2 tags. */
const MP3_SYNC_WINDOW_BYTES = 64 * 1024;
/** Frames that must share one bitrate before an MP3 counts as constant-bitrate. */
const CBR_CHECK_FRAMES = 16;
/** An `esds` body larger than this is not a real decoder configuration. */
const ESDS_MAX_BYTES = 512;

/** Format numbers outside these ranges are not audio; the field is omitted. */
const SAMPLE_RATE_RANGE = [8_000, 768_000] as const;
const CHANNEL_RANGE = [1, 32] as const;
const BITRATE_RANGE = [1_000, 10_000_000] as const;

export interface AudioHeaders {
  durationSeconds?: number;
  format?: MediaInfoFormat;
}

/**
 * Seconds of audio and the format the headers describe. Either may be missing:
 * an unknown container, a malformed walk, a length over `MAX_DURATION_SECONDS`,
 * or format numbers outside their ranges drop only that field.
 */
export async function readAudioHeaders(
  source: AudioByteSource,
  deadline: AbortSignal,
): Promise<AudioHeaders> {
  let parsed: AudioHeaders;
  try {
    parsed = await parse(new BoundedReader(source, deadline));
  } catch {
    return {};
  }
  const headers: AudioHeaders = {};
  const { durationSeconds } = parsed;
  // Zero-length audio has nothing to label; a length past the cap is not audio.
  if (
    durationSeconds !== undefined &&
    Number.isFinite(durationSeconds) &&
    durationSeconds > 0 &&
    durationSeconds <= MAX_DURATION_SECONDS
  ) {
    headers.durationSeconds = durationSeconds;
  }
  const format = formatWithinRange(parsed.format);
  if (format) headers.format = format;
  return headers;
}

async function parse(reader: BoundedReader): Promise<AudioHeaders> {
  const container = await detectContainer(reader);
  switch (container.kind) {
    case "wav":
      return wavHeaders(reader, container.rf64);
    case "flac":
      return flacHeaders(reader, container.start);
    case "mp4":
      return mp4Headers(reader);
    case "mp3":
      return mp3Headers(reader, container.audioStart);
  }
}

// MARK: - WAV / RF64

async function wavHeaders(reader: BoundedReader, rf64: boolean): Promise<AudioHeaders> {
  let fmt: Buffer | undefined;
  let fmtSize = 0;
  let dataSize: number | undefined;
  /** RF64 keeps the real data size in `ds64`; the `data` header holds 0xFFFFFFFF. */
  let ds64DataSize: number | undefined;
  let offset = 12;
  for (let i = 0; i < MAX_WAV_CHUNKS && offset + 8 <= reader.size; i++) {
    const header = await reader.read(offset, 8);
    const id = header.toString("latin1", 0, 4);
    let size = header.readUInt32LE(4);
    const body = offset + 8;
    if (id === "ds64" && rf64) {
      if (size < 24) unknown();
      const ds64 = await reader.read(body, 24);
      ds64DataSize = uint64LE(ds64, 8);
    } else if (id === "fmt ") {
      if (size < 16) unknown();
      fmtSize = size;
      fmt = await reader.read(body, Math.min(size, WAV_FMT_BYTES));
    } else if (id === "data") {
      if (rf64 && size === 0xffff_ffff) {
        if (ds64DataSize === undefined) unknown();
        size = ds64DataSize;
      }
      // A WAV piped out of an encoder keeps a 0xFFFFFFFF placeholder, and a
      // recording cut short claims more than it holds: the audio is what is there.
      size = Math.min(size, reader.size - body);
      dataSize = size;
    }
    if (size > reader.size - body) unknown();
    if (fmt !== undefined && dataSize !== undefined) break;
    // Chunks are word-aligned: an odd-size chunk carries one pad byte.
    offset = body + size + (size & 1);
  }
  if (fmt === undefined) unknown();
  const byteRate = fmt.readUInt32LE(8);
  if (byteRate === 0) unknown();
  const codec = wavCodec(fmt, fmtSize);
  // A codec this reader cannot name costs the format, not the length.
  const format: MediaInfoFormat | undefined =
    codec === undefined
      ? undefined
      : {
          codec,
          sampleRate: fmt.readUInt32LE(4),
          channels: fmt.readUInt16LE(2),
          bitrate: byteRate * 8,
        };
  // A header with `fmt ` but no `data` states a format and no length.
  return dataSize === undefined ? { format } : { durationSeconds: dataSize / byteRate, format };
}

/** WAV format tags worth naming; anything else reports no format. */
const WAV_CODECS: Record<number, string | undefined> = {
  1: "pcm",
  3: "pcm_float",
  0x55: "mp3",
};

function wavCodec(fmt: Buffer, fmtSize: number): string | undefined {
  let tag = fmt.readUInt16LE(0);
  // WAVE_FORMAT_EXTENSIBLE states the real format in its sub-format GUID.
  if (tag === 0xfffe && fmtSize >= 26 && fmt.length >= 26) tag = fmt.readUInt16LE(24);
  return WAV_CODECS[tag];
}

// MARK: - FLAC

async function flacHeaders(reader: BoundedReader, start: number): Promise<AudioHeaders> {
  // STREAMINFO is always the first metadata block after the marker.
  const block = await reader.read(start + 4, 4 + 34);
  if ((block.readUInt8(0) & 0x7f) !== 0 || block.readUIntBE(1, 3) < 34) unknown();
  const info = block.subarray(4);
  // 20-bit sample rate, 3-bit channels, 5-bit sample size, 36-bit sample count.
  const sampleRate = info.readUIntBE(10, 3) >>> 4;
  const channels = ((info.readUInt8(12) >>> 1) & 0x07) + 1;
  const totalSamples = (info.readUInt8(13) & 0x0f) * 2 ** 32 + info.readUInt32BE(14);
  if (sampleRate === 0) unknown();
  const durationSeconds = totalSamples / sampleRate;
  const format: MediaInfoFormat = {
    codec: "flac",
    sampleRate,
    channels,
    // Average over the whole stream, tags included: STREAMINFO states no bitrate.
    bitrate: durationSeconds > 0 ? ((reader.size - start) * 8) / durationSeconds : undefined,
  };
  return { durationSeconds, format };
}

// MARK: - MP4 / M4A / MOV

interface Mp4Movie {
  /** The first audio track's `mdia`, when the movie has one. */
  audioMedia?: Box;
  /** `mvhd` duration, or 0 when it is absent or zero. */
  movieDuration: number;
  /** A fragmented movie's samples live outside `moov`; its `mdhd` is partial. */
  fragmented: boolean;
  /** Payload bytes of every top-level `mdat`, for a bitrate the `esds` omits. */
  mdatBytes: number;
}

/**
 * `mvhd`'s duration, or when it is 0 or missing, the first audio track's
 * `mdhd` (`moov` → `trak` → `mdia` → `hdlr` `soun` → `mdhd`). The audio track is
 * walked anyway for `stsd`, so the format comes from the same traversal. Only
 * these paths are walked, so depth is fixed, and every box header read counts
 * against one `MAX_MP4_BOXES` cap; the top-level `mdat` count that feeds the
 * bitrate fallback walks with a budget of its own.
 */
async function mp4Headers(reader: BoundedReader): Promise<AudioHeaders> {
  const boxes = newBoxBudget(MAX_MP4_BOXES);
  const movie = await readMovie(reader, boxes);
  let durationSeconds: number | undefined;
  if (movie.movieDuration > 0) {
    durationSeconds = movie.movieDuration;
  } else if (!movie.fragmented && movie.audioMedia) {
    const mdhd = await findBox(reader, movie.audioMedia.start, movie.audioMedia.end, "mdhd", boxes);
    durationSeconds = mdhd ? await headerDuration(reader, mdhd) : undefined;
  }
  // A malformed audio track costs the format, not the length the movie states.
  const format = await mp4Format(reader, movie, durationSeconds, boxes).catch(() => undefined);
  return { durationSeconds, format };
}

async function readMovie(reader: BoundedReader, boxes: BoxBudget): Promise<Mp4Movie> {
  // `findBox` returns at `moov`, so a header broken after the movie cannot cost
  // a length the movie already stated (a truncated download, a corrupt size, or
  // many fragments).
  const movie = (await findBox(reader, 0, reader.size, "moov", boxes)) ?? unknown();
  const mvhd = await findBox(reader, movie.start, movie.end, "mvhd", boxes);
  const movieDuration = mvhd ? await headerDuration(reader, mvhd) : 0;

  let audioMedia: Box | undefined;
  let fragmented = false;
  for await (const child of childBoxes(reader, movie.start, movie.end, boxes)) {
    if (child.type === "mvex") fragmented = true;
    if (child.type !== "trak" || audioMedia) continue;
    const mdia = await findBox(reader, child.start, child.end, "mdia", boxes);
    if (!mdia) continue;
    const hdlr = await findBox(reader, mdia.start, mdia.end, "hdlr", boxes);
    // version/flags, pre_defined, then the handler type.
    if (!hdlr || hdlr.end - hdlr.start < 12) continue;
    const handler = (await reader.read(hdlr.start + 8, 4)).toString("latin1");
    if (handler === "soun") audioMedia = mdia;
  }
  return { audioMedia, movieDuration, fragmented, mdatBytes: await sumTopLevelMdat(reader) };
}

/**
 * Payload bytes of every top-level `mdat`, which only feed the bitrate the
 * `esds` omits. Best-effort with its own box budget: a walk that fails stops the
 * sum where it failed, so a broken box costs sample bytes, never a length or
 * format the movie already answered.
 */
async function sumTopLevelMdat(reader: BoundedReader): Promise<number> {
  const boxes = newBoxBudget(MAX_MP4_BOXES);
  let bytes = 0;
  try {
    for await (const box of childBoxes(reader, 0, reader.size, boxes)) {
      if (box.type === "mdat") bytes += box.end - box.start;
    }
  } catch {
    return bytes;
  }
  return bytes;
}

/** Seconds from an `mvhd` or `mdhd`, which share their leading layout. */
async function headerDuration(reader: BoundedReader, box: Box): Promise<number> {
  const fullBox = await reader.read(box.start, Math.min(4, box.end - box.start));
  const version = fullBox[0];
  if (version === 0) {
    // version/flags, creation, modification, timescale, duration: all 32-bit.
    if (box.end - box.start < 20) unknown();
    const fields = await reader.read(box.start + 12, 8);
    const duration = fields.readUInt32BE(4);
    if (duration === 0xffff_ffff) unknown();
    return duration / nonZero(fields.readUInt32BE(0));
  }
  if (version === 1) {
    // version/flags, 64-bit creation and modification, 32-bit timescale, 64-bit duration.
    if (box.end - box.start < 32) unknown();
    const fields = await reader.read(box.start + 20, 12);
    // An all-ones duration (unknown) is not a safe integer, so uint64BE rejects it.
    return uint64BE(fields, 4) / nonZero(fields.readUInt32BE(0));
  }
  return unknown();
}

/** Codecs an audio `stsd` sample entry can name. */
const MP4_CODECS: Record<string, string | undefined> = {
  mp4a: "aac",
  alac: "alac",
  fLaC: "flac",
  Opus: "opus",
  "ac-3": "ac3",
  "ec-3": "eac3",
};

/**
 * The first audio sample entry's codec, channels and rate (`mdia` → `minf` →
 * `stbl` → `stsd`). Bitrate comes from the `esds` decoder configuration, else
 * from the `mdat` bytes over the movie's length.
 */
async function mp4Format(
  reader: BoundedReader,
  movie: Mp4Movie,
  durationSeconds: number | undefined,
  boxes: BoxBudget,
): Promise<MediaInfoFormat | undefined> {
  const media = movie.audioMedia;
  if (!media) return undefined;
  const minf = await findBox(reader, media.start, media.end, "minf", boxes);
  if (!minf) return undefined;
  const stbl = await findBox(reader, minf.start, minf.end, "stbl", boxes);
  if (!stbl) return undefined;
  const stsd = await findBox(reader, stbl.start, stbl.end, "stsd", boxes);
  // `stsd` is a full box: version/flags, then the entry count, then the entries.
  if (!stsd || stsd.end - stsd.start < 8) return undefined;
  const entry = await firstBox(reader, stsd.start + 8, stsd.end, boxes);
  if (!entry) return undefined;
  const codec = MP4_CODECS[entry.type];
  if (codec === undefined) return undefined;
  // ISO audio sample entry: reserved, data reference, version/revision/vendor,
  // channels, sample size, compression, packet size, 16.16 sample rate.
  if (entry.end - entry.start < 28) return { codec };
  const fields = await reader.read(entry.start, 28);
  const stated = await esdsAverageBitrate(reader, entry, boxes).catch(() => undefined);
  const format: MediaInfoFormat = {
    codec,
    channels: fields.readUInt16BE(16),
    sampleRate: fields.readUInt32BE(24) >>> 16,
  };
  // An encoder that writes 0 states no bitrate; the sample bytes over the length do.
  const bitrate =
    stated !== undefined && stated > 0 ? stated : mdatBitrate(movie.mdatBytes, durationSeconds);
  if (bitrate !== undefined) format.bitrate = bitrate;
  return format;
}

async function firstBox(
  reader: BoundedReader,
  start: number,
  end: number,
  boxes: BoxBudget,
): Promise<Box | undefined> {
  for await (const box of childBoxes(reader, start, end, boxes)) return box;
  return undefined;
}

/** Average bitrate the `esds` decoder configuration states, if any. */
async function esdsAverageBitrate(
  reader: BoundedReader,
  entry: Box,
  boxes: BoxBudget,
): Promise<number | undefined> {
  // Sample entry children follow the 28 fixed bytes in the ISO layout.
  const esds = await findBox(reader, entry.start + 28, entry.end, "esds", boxes);
  if (!esds) return undefined;
  const length = Math.min(esds.end - esds.start, ESDS_MAX_BYTES);
  if (length < 8) return undefined;
  const bytes = await reader.read(esds.start, length);
  // Past the full-box version/flags is the ES_Descriptor.
  const decoderConfig = findDecoderConfig(bytes, 4);
  // OTI(1), streamType(1), bufferSizeDB(3), maxBitrate(4), avgBitrate(4).
  if (!decoderConfig || decoderConfig.length < 13) return undefined;
  return decoderConfig.readUInt32BE(9);
}

/**
 * The `DecoderConfigDescriptor` payload inside an `ES_Descriptor`, or undefined.
 * MPEG-4 descriptors are tag + 7-bit-grouped length + payload; the optional ES
 * flags (dependency, URL, OCR) shift the decoder configuration that follows.
 */
function findDecoderConfig(bytes: Buffer, at: number): Buffer | undefined {
  const es = readDescriptor(bytes, at);
  if (!es) return undefined;
  if (es.tag === 0x04) return bytes.subarray(es.start, es.end);
  if (es.tag !== 0x03 || es.end - es.start < 3) return undefined;
  let childAt = es.start + 3;
  const flags = bytes[childAt - 1] ?? 0;
  if ((flags & 0x80) !== 0) childAt += 2;
  if ((flags & 0x40) !== 0) childAt += 1 + (bytes[childAt] ?? 0);
  if ((flags & 0x20) !== 0) childAt += 2;
  const config = readDescriptor(bytes, childAt);
  return config?.tag === 0x04 ? bytes.subarray(config.start, config.end) : undefined;
}

function readDescriptor(
  bytes: Buffer,
  at: number,
): { tag: number; start: number; end: number } | undefined {
  if (at + 2 > bytes.length) return undefined;
  const tag = bytes.readUInt8(at);
  let size = 0;
  let offset = at + 1;
  for (let group = 0; ; group++) {
    if (offset >= bytes.length || group === 4) return undefined;
    const byte = bytes.readUInt8(offset++);
    size = size * 128 + (byte & 0x7f);
    if ((byte & 0x80) === 0) break;
  }
  if (offset + size > bytes.length) return undefined;
  return { tag, start: offset, end: offset + size };
}

/** Bits per second over the sample bytes, when both are known. */
function mdatBitrate(mdatBytes: number, durationSeconds: number | undefined): number | undefined {
  if (durationSeconds === undefined || !(durationSeconds > 0) || mdatBytes === 0) return undefined;
  return (mdatBytes * 8) / durationSeconds;
}

// MARK: - MP3

/** MPEG layer as a codec name: a Layer III stream is an MP3. */
const MP3_CODECS: Record<number, string | undefined> = { 1: "mp1", 2: "mp2", 3: "mp3" };

interface Mp3Frame {
  mpeg1: boolean;
  layer: 1 | 2 | 3;
  bitrateKbps: number;
  sampleRate: number;
  mono: boolean;
  samplesPerFrame: number;
  length: number;
}

const BITRATES_KBPS: Record<string, readonly number[]> = {
  "1-1": [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  "1-2": [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  "1-3": [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  "2-1": [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  "2-2": [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  "2-3": [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
};
/** Indexed by the header's version bits: MPEG 2.5, reserved, MPEG 2, MPEG 1. */
const SAMPLE_RATES: readonly (readonly number[] | undefined)[] = [
  [11_025, 12_000, 8_000],
  undefined,
  [22_050, 24_000, 16_000],
  [44_100, 48_000, 32_000],
];

/** The frame header at `at`, or undefined when those bytes are not one. */
function parseFrameHeader(bytes: Buffer, at: number): Mp3Frame | undefined {
  if (at + 4 > bytes.length) return undefined;
  const header = bytes.readUInt32BE(at);
  if (header >>> 21 !== 0x7ff) return undefined;
  const versionBits = (header >>> 19) & 3;
  const layerBits = (header >>> 17) & 3;
  const bitrateIndex = (header >>> 12) & 0xf;
  const sampleRateIndex = (header >>> 10) & 3;
  const rates = SAMPLE_RATES[versionBits];
  // Free-format (0) and bad (15) bitrates have no computable frame length.
  if (!rates || layerBits === 0 || bitrateIndex === 0 || bitrateIndex === 15) return undefined;
  const mpeg1 = versionBits === 3;
  const layer = (4 - layerBits) as 1 | 2 | 3;
  const bitrateKbps = BITRATES_KBPS[`${mpeg1 ? 1 : 2}-${layer}`]?.[bitrateIndex];
  const sampleRate = rates[sampleRateIndex]; // Index 3 is reserved: undefined.
  if (bitrateKbps === undefined || sampleRate === undefined) return undefined;
  const padding = (header >>> 9) & 1;
  const samplesPerFrame = layer === 1 ? 384 : layer === 3 && !mpeg1 ? 576 : 1152;
  const length =
    layer === 1
      ? (Math.floor((12_000 * bitrateKbps) / sampleRate) + padding) * 4
      : Math.floor(((samplesPerFrame / 8) * 1000 * bitrateKbps) / sampleRate) + padding;
  return {
    mpeg1,
    layer,
    bitrateKbps,
    sampleRate,
    mono: ((header >>> 6) & 3) === 3,
    samplesPerFrame,
    length,
  };
}

async function mp3Headers(reader: BoundedReader, audioStart: number): Promise<AudioHeaders> {
  const window = await reader.read(
    audioStart,
    Math.min(MP3_SYNC_WINDOW_BYTES, reader.size - audioStart),
  );
  const audioEnd = reader.size - (await id3v1Size(reader, audioStart));
  /** Bytes from the search window when it holds them, else one bounded read. */
  const bytesAt = (position: number, length: number): Promise<Buffer> | Buffer => {
    const from = position - audioStart;
    return from + length <= window.length
      ? window.subarray(from, from + length)
      : reader.read(position, length);
  };
  for (let at = window.indexOf(0xff); at !== -1; at = window.indexOf(0xff, at + 1)) {
    const frame = parseFrameHeader(window, at);
    if (!frame) continue;
    const frameStart = audioStart + at;
    if (frameStart >= audioEnd) break;
    const audioBytes = audioEnd - frameStart;
    const frameBytes = await bytesAt(frameStart, Math.min(frame.length, audioBytes));
    // The first frame states the format whether or not the length is knowable.
    const format: MediaInfoFormat = {
      codec: MP3_CODECS[frame.layer] ?? unknown(),
      sampleRate: frame.sampleRate,
      channels: frame.mono ? 1 : 2,
    };
    const frames = vbrFrameCount(frameBytes, frame);
    if (frames !== undefined) {
      const durationSeconds = (frames * frame.samplesPerFrame) / frame.sampleRate;
      // A VBR stream states no bitrate: average the audio bytes over its length.
      if (durationSeconds > 0) format.bitrate = (audioBytes * 8) / durationSeconds;
      return { durationSeconds, format };
    }
    const stream = classifyStream(window, at, frame, audioEnd - audioStart);
    if (stream === "noise") continue;
    // VBR without a Xing/Info/VBRI frame states no length; only a full scan has one.
    // A header-less VBR file that opens with `CBR_CHECK_FRAMES` or more frames at
    // one bitrate (leading silence) still gets this estimate. music-metadata
    // judged constant bitrate from its first four frames, so this is no regression.
    if (stream === "variable") unknown();
    // No Xing/Info/VBRI frame: a constant-bitrate estimate from the audio bytes.
    format.bitrate = frame.bitrateKbps * 1000;
    return { durationSeconds: (audioBytes * 8) / (frame.bitrateKbps * 1000), format };
  }
  return unknown();
}

/** Frame count from a Xing/Info or VBRI header inside the first frame. */
function vbrFrameCount(frameBytes: Buffer, frame: Mp3Frame): number | undefined {
  if (frame.layer === 3) {
    const sideInfo = frame.mpeg1 ? (frame.mono ? 17 : 32) : frame.mono ? 9 : 17;
    const xing = 4 + sideInfo;
    const tag = frameBytes.toString("latin1", xing, xing + 4);
    if ((tag === "Xing" || tag === "Info") && xing + 12 <= frameBytes.length) {
      const hasFrames = (frameBytes.readUInt32BE(xing + 4) & 1) !== 0;
      const frames = hasFrames ? frameBytes.readUInt32BE(xing + 8) : 0;
      if (frames > 0) return frames;
    }
  }
  // VBRI sits 32 bytes after the frame header regardless of channel mode.
  if (frameBytes.toString("latin1", 36, 40) === "VBRI" && 54 <= frameBytes.length) {
    const frames = frameBytes.readUInt32BE(50);
    if (frames > 0) return frames;
  }
  return undefined;
}

/**
 * Walks the frames chained after `at` inside the search window. A lone 0xFFE
 * pattern in arbitrary bytes looks like a frame header ("noise": the next frame
 * does not start where this one ends with the same version, layer and sample
 * rate), and a VBR stream without a Xing/Info/VBRI frame changes bitrate
 * ("variable"), so only "constant" supports a bitrate estimate.
 */
function classifyStream(
  window: Buffer,
  at: number,
  frame: Mp3Frame,
  audioLength: number,
): "constant" | "variable" | "noise" {
  const end = Math.min(window.length, audioLength);
  let position = at + frame.length;
  for (let chained = 1; chained < CBR_CHECK_FRAMES; chained++) {
    if (position + 4 > end) {
      // The audio ends on a frame boundary, or the window ends with enough
      // frames already agreeing.
      if (end === audioLength) return position <= end ? "constant" : "noise";
      return chained >= 2 ? "constant" : "noise";
    }
    const next = parseFrameHeader(window, position);
    if (
      next === undefined ||
      next.mpeg1 !== frame.mpeg1 ||
      next.layer !== frame.layer ||
      next.sampleRate !== frame.sampleRate
    ) {
      return "noise";
    }
    if (next.bitrateKbps !== frame.bitrateKbps) return "variable";
    position += next.length;
  }
  return "constant";
}

/** 128 when an ID3v1 `TAG` trails the audio, else 0. */
async function id3v1Size(reader: BoundedReader, audioStart: number): Promise<number> {
  if (reader.size - audioStart < 128) return 0;
  const tag = await reader.read(reader.size - 128, 3);
  return tag.toString("latin1") === "TAG" ? 128 : 0;
}

// MARK: - Helpers

/** A finite number in [min, max], rounded when asked, else undefined. */
function inRange(
  value: number | undefined,
  min: number,
  max: number,
  round: boolean,
): number | undefined {
  if (value === undefined || !Number.isFinite(value)) return undefined;
  const bounded = round ? Math.round(value) : value;
  return bounded >= min && bounded <= max ? bounded : undefined;
}

/** The codec with every number that is in range and no field that is not. */
function formatWithinRange(format: MediaInfoFormat | undefined): MediaInfoFormat | undefined {
  if (!format || typeof format.codec !== "string" || format.codec.length === 0) return undefined;
  const sanitized: MediaInfoFormat = { codec: format.codec };
  const sampleRate = inRange(format.sampleRate, ...SAMPLE_RATE_RANGE, true);
  const channels = inRange(format.channels, ...CHANNEL_RANGE, true);
  const bitrate = inRange(format.bitrate, ...BITRATE_RANGE, true);
  if (sampleRate !== undefined) sanitized.sampleRate = sampleRate;
  if (channels !== undefined) sanitized.channels = channels;
  if (bitrate !== undefined) sanitized.bitrate = bitrate;
  return sanitized;
}

function nonZero(value: number): number {
  return value === 0 ? unknown() : value;
}

/**
 * Audio length from container headers: WAV/RF64 chunks, MP3 Xing/Info/VBRI
 * frames (or a constant-bitrate estimate), MP4 `mvhd` (or the audio track's
 * `mdhd`), FLAC STREAMINFO.
 *
 * Input may be crafted, so every read goes through `BoundedReader`: it stays
 * inside the file, each read is at most `MAX_READ_BYTES`, one parse reads at
 * most `MAX_TOTAL_READ_BYTES`, and the deadline is checked before every read.
 * Every walk has an iteration cap and no buffer is sized from file data.
 * Anything unrecognized or malformed is "unknown" (`undefined`), never a throw.
 */

/** Positional reads over one already-open file. */
export interface AudioByteSource {
  readonly size: number;
  /** Fills `buffer` from `position`; resolves to the bytes read. */
  read(buffer: Uint8Array, position: number): Promise<number>;
}

const MAX_READ_BYTES = 64 * 1024;
/** Far above any real header walk; MP3 sync search is the largest reader. */
const MAX_TOTAL_READ_BYTES = 512 * 1024;
const MAX_WAV_CHUNKS = 1_024;
const MAX_MP4_BOXES = 1_024;
const MAX_ID3_TAGS = 8;
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

class Unknown extends Error {}

function unknown(): never {
  throw new Unknown();
}

class BoundedReader {
  private budgetLeft = MAX_TOTAL_READ_BYTES;

  constructor(
    private readonly source: AudioByteSource,
    private readonly deadline: AbortSignal,
  ) {}

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

/**
 * Seconds of audio the headers describe, or undefined when the format is not
 * one of WAV, RF64, MP3, MP4/M4A/MOV, FLAC, or the headers are malformed.
 * Zero-length audio is reported as unknown: there is nothing to label, and so
 * is a length over `MAX_DURATION_SECONDS`.
 */
export async function readAudioDuration(
  source: AudioByteSource,
  deadline: AbortSignal,
): Promise<number | undefined> {
  try {
    const duration = await parse(new BoundedReader(source, deadline));
    return Number.isFinite(duration) && duration > 0 && duration <= MAX_DURATION_SECONDS
      ? duration
      : undefined;
  } catch {
    return undefined;
  }
}

async function parse(reader: BoundedReader): Promise<number> {
  const head = await reader.read(0, Math.min(12, reader.size));
  const magic = head.toString("latin1", 0, 4);
  if ((magic === "RIFF" || magic === "RF64") && head.toString("latin1", 8, 12) === "WAVE") {
    return wavDuration(reader, magic === "RF64");
  }
  if (magic === "fLaC") return flacDuration(reader, 0);
  if (head.length >= 8 && MP4_FIRST_BOXES.has(head.toString("latin1", 4, 8))) {
    return mp4Duration(reader);
  }
  if (UNPARSED_MAGICS.has(magic)) unknown();
  const audioStart = await skipId3v2(reader);
  if (audioStart + 4 <= reader.size) {
    const marker = await reader.read(audioStart, 4);
    if (marker.toString("latin1") === "fLaC") return flacDuration(reader, audioStart);
  }
  return mp3Duration(reader, audioStart);
}

/**
 * AIFF, CAF, Ogg and Matroska/WebM have no parser here; stop before the MP3
 * frame search, which could otherwise mistake their payload for frames.
 */
const UNPARSED_MAGICS = new Set(["FORM", "caff", "OggS", "\x1a\x45\xdf\xa3"]);

// MARK: - WAV / RF64

async function wavDuration(reader: BoundedReader, rf64: boolean): Promise<number> {
  let byteRate: number | undefined;
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
      const fmt = await reader.read(body, 16);
      byteRate = fmt.readUInt32LE(8);
      if (byteRate === 0) unknown();
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
    if (byteRate !== undefined && dataSize !== undefined) return dataSize / byteRate;
    // Chunks are word-aligned: an odd-size chunk carries one pad byte.
    offset = body + size + (size & 1);
  }
  return unknown();
}

// MARK: - FLAC

async function flacDuration(reader: BoundedReader, start: number): Promise<number> {
  // STREAMINFO is always the first metadata block after the marker.
  const block = await reader.read(start + 4, 4 + 34);
  if ((block.readUInt8(0) & 0x7f) !== 0 || block.readUIntBE(1, 3) < 34) unknown();
  const info = block.subarray(4);
  // 20-bit sample rate, 3-bit channels, 5-bit sample size, 36-bit sample count.
  const sampleRate = info.readUIntBE(10, 3) >>> 4;
  const totalSamples = (info.readUInt8(13) & 0x0f) * 2 ** 32 + info.readUInt32BE(14);
  if (sampleRate === 0) unknown();
  return totalSamples / sampleRate;
}

// MARK: - MP4 / M4A / MOV

/** Box types a QuickTime or ISO BMFF file plausibly starts with. */
const MP4_FIRST_BOXES = new Set(["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"]);

interface Box {
  type: string;
  /** Payload range, after the header. */
  start: number;
  end: number;
}

/**
 * `mvhd`'s duration, or when it is 0 or missing, the first audio track's
 * `mdhd` (`moov` → `trak` → `mdia` → `hdlr` `soun` → `mdhd`). Only these
 * paths are walked, so depth is four by construction, and every box header
 * read counts against one `MAX_MP4_BOXES` cap.
 */
async function mp4Duration(reader: BoundedReader): Promise<number> {
  const boxes = { left: MAX_MP4_BOXES };
  const moov = (await findBox(reader, 0, reader.size, "moov", boxes)) ?? unknown();
  const mvhd = await findBox(reader, moov.start, moov.end, "mvhd", boxes);
  const movieDuration = mvhd ? await headerDuration(reader, mvhd) : 0;
  if (movieDuration > 0) return movieDuration;

  let audioMedia: Box | undefined;
  for await (const child of childBoxes(reader, moov.start, moov.end, boxes)) {
    // Fragmented MP4 keeps its samples in `moof` boxes that `mvex` announces;
    // a track header covers only the samples in `moov`, so it is not the length.
    if (child.type === "mvex") unknown();
    if (child.type !== "trak" || audioMedia) continue;
    const mdia = await findBox(reader, child.start, child.end, "mdia", boxes);
    if (!mdia) continue;
    const hdlr = await findBox(reader, mdia.start, mdia.end, "hdlr", boxes);
    // version/flags, pre_defined, then the handler type.
    if (!hdlr || hdlr.end - hdlr.start < 12) continue;
    const handler = (await reader.read(hdlr.start + 8, 4)).toString("latin1");
    if (handler === "soun") audioMedia = mdia;
  }
  if (!audioMedia) return unknown();
  const mdhd = await findBox(reader, audioMedia.start, audioMedia.end, "mdhd", boxes);
  return headerDuration(reader, mdhd ?? unknown());
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

/** The first `type` box among the boxes in [start, end), if any. */
async function findBox(
  reader: BoundedReader,
  start: number,
  end: number,
  type: string,
  boxes: { left: number },
): Promise<Box | undefined> {
  for await (const box of childBoxes(reader, start, end, boxes)) {
    if (box.type === type) return box;
  }
  return undefined;
}

/** The boxes in [start, end), in order; a malformed header is unknown. */
async function* childBoxes(
  reader: BoundedReader,
  start: number,
  end: number,
  boxes: { left: number },
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

// MARK: - MP3

/**
 * Offset just past any leading ID3v2 tags (0 without one). More tags than
 * `MAX_ID3_TAGS` is unknown, not a frame search through the next tag.
 */
async function skipId3v2(reader: BoundedReader): Promise<number> {
  let offset = 0;
  for (let tags = 0; offset + 10 <= reader.size; tags++) {
    const header = await reader.read(offset, 10);
    if (header.toString("latin1", 0, 3) !== "ID3") break;
    if (tags === MAX_ID3_TAGS) unknown();
    // Syncsafe: four 7-bit bytes, high bit clear.
    const syncsafe = header.readUInt32BE(6);
    if ((syncsafe & 0x8080_8080) !== 0) unknown();
    const tagSize =
      ((syncsafe >>> 3) & 0x0fe0_0000) |
      ((syncsafe >>> 2) & 0x001f_c000) |
      ((syncsafe >>> 1) & 0x0000_3f80) |
      (syncsafe & 0x7f);
    const hasFooter = (header.readUInt8(5) & 0x10) !== 0;
    offset += 10 + tagSize + (hasFooter ? 10 : 0);
    if (offset > reader.size) unknown();
  }
  return offset;
}

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

async function mp3Duration(reader: BoundedReader, audioStart: number): Promise<number> {
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
    const frameBytes = await bytesAt(frameStart, Math.min(frame.length, audioEnd - frameStart));
    const frames = vbrFrameCount(frameBytes, frame);
    if (frames !== undefined) return (frames * frame.samplesPerFrame) / frame.sampleRate;
    const stream = classifyStream(window, at, frame, audioEnd - audioStart);
    if (stream === "noise") continue;
    // VBR without a Xing/Info/VBRI frame states no length; only a full scan has one.
    // A header-less VBR file that opens with `CBR_CHECK_FRAMES` or more frames at
    // one bitrate (leading silence) still gets this estimate. music-metadata
    // judged constant bitrate from its first four frames, so this is no regression.
    if (stream === "variable") unknown();
    // No Xing/Info/VBRI frame: a constant-bitrate estimate from the audio bytes.
    return ((audioEnd - frameStart) * 8) / (frame.bitrateKbps * 1000);
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

function nonZero(value: number): number {
  return value === 0 ? unknown() : value;
}

/** A 64-bit field as a safe integer, or unknown. */
function uint64BE(bytes: Buffer, at: number): number {
  return safe(bytes.readUInt32BE(at) * 2 ** 32 + bytes.readUInt32BE(at + 4));
}

function uint64LE(bytes: Buffer, at: number): number {
  return safe(bytes.readUInt32LE(at + 4) * 2 ** 32 + bytes.readUInt32LE(at));
}

function safe(value: number): number {
  return Number.isSafeInteger(value) ? value : unknown();
}

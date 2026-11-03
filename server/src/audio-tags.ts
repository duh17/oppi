/**
 * Audio tags (title, artist, album) from container headers: ID3v2.2–2.4 with
 * ID3v1 fallback for MP3, `moov/udta/meta/ilst` for MP4/M4A/M4B,
 * `VORBIS_COMMENT` for FLAC, and RIFF `LIST`/`INFO` plus an `id3 `/`ID3 ` chunk
 * for WAV/RF64.
 *
 * This is a second pass over the file with its own 512 KiB read budget, so a
 * malformed tag section costs the tags and never the length (and vice versa).
 * The shape rules hold for every text: at most 4 KiB is read per value, decoded
 * strictly, stripped of control, bidi, and separator characters, trimmed, and at
 * most 256 characters or the field is omitted.
 */

import {
  type AudioByteSource,
  BoundedReader,
  childBoxes,
  findBox,
  newBoxBudget,
  syncsafeUInt32,
} from "./audio-bytes.js";
import { detectContainer } from "./audio-container.js";
import type { MediaInfoTags } from "./types/workspace-files.js";

// Keep in step with `MAX_ID3_TAGS` in `audio-container.ts`: detection skips the
// same leading tags, so both passes find the same audio start.
const MAX_ID3_TAGS = 8;
const MAX_ID3_FRAMES = 512;
const MAX_ID3V1_BYTES = 128;
const MAX_TEXT_BYTES = 4 * 1024;
const MAX_TEXT_CHARS = 256;
const MAX_MP4_BOXES = 1_024;
const MAX_FLAC_BLOCKS = 64;
const MAX_VORBIS_COMMENTS = 512;
const MAX_WAV_CHUNKS = 1_024;
const MAX_INFO_SUBCHUNKS = 256;

/**
 * Title, artist and album the headers state, or undefined when the container is
 * unsupported, the tag section is malformed, or it names none of them.
 */
export async function readAudioTags(
  source: AudioByteSource,
  deadline: AbortSignal,
): Promise<MediaInfoTags | undefined> {
  let tags: MediaInfoTags;
  try {
    tags = await parse(new BoundedReader(source, deadline));
  } catch {
    return undefined;
  }
  return hasFields(tags) ? tags : undefined;
}

async function parse(reader: BoundedReader): Promise<MediaInfoTags> {
  const container = await detectContainer(reader);
  switch (container.kind) {
    case "wav":
      return wavTags(reader);
    case "flac":
      return flacTags(reader, container.start);
    case "mp4":
      return mp4Tags(reader);
    case "mp3":
      return mp3Tags(reader);
  }
}

// MARK: - Text

const UTF8 = new TextDecoder("utf-8", { fatal: true });
const UTF16LE = new TextDecoder("utf-16le", { fatal: true });
const UTF16BE = new TextDecoder("utf-16be", { fatal: true });
const LATIN1 = new TextDecoder("latin1");

/**
 * C0/C1 controls, bidi marks and overrides, and the line and paragraph
 * separators: they reorder, hide, or break what a single-line card shows. The
 * control range is the point, not an accident.
 */
const UNSAFE_TEXT =
  // eslint-disable-next-line no-control-regex
  /[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g;

/** Decoded text under the tag rules, or undefined when it is unusable. */
function sanitizeText(text: string | undefined): string | undefined {
  if (text === undefined) return undefined;
  const cleaned = text.replace(UNSAFE_TEXT, "").trim();
  if (cleaned.length === 0) return undefined;
  // Count code points, so one emoji is one character.
  return Array.from(cleaned).length <= MAX_TEXT_CHARS ? cleaned : undefined;
}

function decodeStrict(decoder: TextDecoder, bytes: Buffer): string | undefined {
  try {
    return decoder.decode(bytes);
  } catch {
    return undefined;
  }
}

/** Text up to the first NUL, in whichever terminator width the encoding uses. */
function terminate(bytes: Buffer, wide: boolean): Buffer {
  if (!wide) {
    const end = bytes.indexOf(0);
    return end === -1 ? bytes : bytes.subarray(0, end);
  }
  for (let at = 0; at + 1 < bytes.length; at += 2) {
    if (bytes[at] === 0 && bytes[at + 1] === 0) return bytes.subarray(0, at);
  }
  return bytes;
}

/** RIFF `INFO` states no encoding: strict UTF-8, else Latin-1 (never fails). */
function decodeInfoText(bytes: Buffer): string | undefined {
  const value = terminate(bytes, false);
  return decodeStrict(UTF8, value) ?? decodeStrict(LATIN1, value);
}

// MARK: - MP3: ID3v2 and ID3v1

/** Frame ids that carry the three fields, per tag version. */
function id3FrameIds(major: number): Record<"title" | "artist" | "album", string> | undefined {
  if (major === 2) return { title: "TT2", artist: "TP1", album: "TAL" };
  if (major === 3 || major === 4) return { title: "TIT2", artist: "TPE1", album: "TALB" };
  return undefined;
}

async function mp3Tags(reader: BoundedReader): Promise<MediaInfoTags> {
  let tags: MediaInfoTags = {};
  let offset = 0;
  for (let tagsRead = 0; tagsRead < MAX_ID3_TAGS && offset + 10 <= reader.size; tagsRead++) {
    const header = await reader.read(offset, 10);
    if (header.toString("latin1", 0, 3) !== "ID3") break;
    const size = syncsafeUInt32(header, 6);
    if (size === undefined) break;
    const footer = (header.readUInt8(5) & 0x10) !== 0;
    const end = offset + 10 + size + (footer ? 10 : 0);
    if (end > reader.size) break;
    tags = merge(tags, await id3v2Tag(reader, offset, end));
    offset = end;
  }
  // A v1 trailer fills what a missing or broken v2 tag leaves unknown.
  return merge(tags, await id3v1Tags(reader));
}

/**
 * Text frames from one ID3v2 tag that starts at `start` and ends by `limit`.
 * A tag-level unsynchronisation scheme or an extended header shifts every frame
 * it contains, so that tag states no tags rather than a guess.
 */
async function id3v2Tag(
  reader: BoundedReader,
  start: number,
  limit: number,
): Promise<MediaInfoTags> {
  if (start + 10 > limit) return {};
  const header = await reader.read(start, 10);
  if (header.toString("latin1", 0, 3) !== "ID3") return {};
  const major = header.readUInt8(3);
  const flags = header.readUInt8(5);
  const size = syncsafeUInt32(header, 6);
  const ids = id3FrameIds(major);
  if (size === undefined || ids === undefined) return {};
  const body = start + 10;
  const end = body + size;
  if ((flags & 0xc0) !== 0 || end > limit) return {};

  const headerSize = major === 2 ? 6 : 10;
  const tags: MediaInfoTags = {};
  let offset = body;
  for (let frames = 0; offset + headerSize <= end; frames++) {
    if (frames === MAX_ID3_FRAMES) break;
    const frame = await reader.read(offset, headerSize);
    const id = frame.toString("latin1", 0, headerSize === 6 ? 3 : 4);
    if (!/^[A-Z0-9]+$/.test(id)) break; // Padding or garbage ends the frame walk.
    let frameSize: number;
    if (major === 2) {
      frameSize = frame.readUIntBE(3, 3);
    } else if (major === 4) {
      // v2.4 frame sizes are syncsafe; v2.3 sizes are plain 32-bit.
      const syncsafeSize = syncsafeUInt32(frame, 4);
      if (syncsafeSize === undefined) break;
      frameSize = syncsafeSize;
    } else {
      frameSize = frame.readUInt32BE(4);
    }
    // Any format flag (compression, encryption, unsynchronisation, grouping or a
    // data length indicator) adds bytes or a transform this reader does not apply.
    const formatFlags = headerSize === 6 ? 0 : frame.readUInt8(9);
    const dataStart = offset + headerSize;
    const dataEnd = dataStart + frameSize;
    if (dataEnd > end) break;
    if (formatFlags === 0) {
      const field = fieldForFrame(ids, id);
      // The encoding byte is separate from the value the 4 KiB cap covers.
      if (field !== undefined && frameSize > 0 && frameSize <= MAX_TEXT_BYTES + 1) {
        const text = await reader.read(dataStart, frameSize);
        assign(tags, field, sanitizeText(decodeId3Text(text)));
      }
    }
    offset = dataEnd;
  }
  return tags;
}

function fieldForFrame(
  ids: Record<"title" | "artist" | "album", string>,
  id: string,
): keyof MediaInfoTags | undefined {
  if (id === ids.title) return "title";
  if (id === ids.artist) return "artist";
  if (id === ids.album) return "album";
  return undefined;
}

/** A text frame's value: one encoding byte, then the encoded text. */
function decodeId3Text(frame: Buffer): string | undefined {
  const bytes = frame.subarray(1);
  switch (frame.readUInt8(0)) {
    case 0:
      return decodeStrict(LATIN1, terminate(bytes, false));
    case 1: {
      const bom = bytes.length >= 2 ? bytes.readUInt16BE(0) : 0;
      if (bom === 0xfeff) return decodeStrict(UTF16BE, terminate(bytes.subarray(2), true));
      if (bom === 0xfffe) return decodeStrict(UTF16LE, terminate(bytes.subarray(2), true));
      return decodeStrict(UTF16LE, terminate(bytes, true));
    }
    case 2:
      return decodeStrict(UTF16BE, terminate(bytes, true));
    case 3:
      return decodeStrict(UTF8, terminate(bytes, false));
    default:
      return undefined;
  }
}

/** ID3v1's 30-character fields at the end of the file. */
async function id3v1Tags(reader: BoundedReader): Promise<MediaInfoTags> {
  if (reader.size < MAX_ID3V1_BYTES) return {};
  const tag = await reader.read(reader.size - MAX_ID3V1_BYTES, MAX_ID3V1_BYTES);
  if (tag.toString("latin1", 0, 3) !== "TAG") return {};
  const field = (from: number): string | undefined =>
    sanitizeText(decodeStrict(LATIN1, tag.subarray(from, from + 30)));
  return { title: field(3), artist: field(33), album: field(63) };
}

// MARK: - MP4 / M4A / M4B

/** iTunes item boxes, as Latin-1 strings (`©` is one byte, 0xA9). */
const ILST_FIELDS: Record<string, keyof MediaInfoTags | undefined> = {
  "\u00a9nam": "title",
  "\u00a9ART": "artist",
  "\u00a9alb": "album",
  // Album artist names the artist when the track artist does not.
  aART: "artist",
};

async function mp4Tags(reader: BoundedReader): Promise<MediaInfoTags> {
  const boxes = newBoxBudget(MAX_MP4_BOXES);
  const moov = await findBox(reader, 0, reader.size, "moov", boxes);
  if (!moov) return {};
  const udta = await findBox(reader, moov.start, moov.end, "udta", boxes);
  if (!udta) return {};
  const meta = await findBox(reader, udta.start, udta.end, "meta", boxes);
  // `meta` is a full box: version/flags, then its child boxes.
  if (!meta || meta.end - meta.start < 4) return {};
  const ilst = await findBox(reader, meta.start + 4, meta.end, "ilst", boxes);
  if (!ilst) return {};

  const tags: MediaInfoTags = {};
  for await (const item of childBoxes(reader, ilst.start, ilst.end, boxes)) {
    const field = ILST_FIELDS[item.type];
    if (field === undefined || tags[field] !== undefined) continue;
    const data = await findBox(reader, item.start, item.end, "data", boxes);
    // A `data` box is version/flags (the type is the low byte), a locale, then the value.
    if (!data || data.end - data.start < 8) continue;
    const header = await reader.read(data.start, 8);
    if ((header.readUInt32BE(0) & 0xff) !== 1) continue; // Type 1 is UTF-8 text.
    const length = data.end - data.start - 8;
    if (length <= 0 || length > MAX_TEXT_BYTES) continue;
    const value = await reader.read(data.start + 8, length);
    assign(tags, field, sanitizeText(decodeStrict(UTF8, terminate(value, false))));
  }
  return tags;
}

// MARK: - FLAC

async function flacTags(reader: BoundedReader, start: number): Promise<MediaInfoTags> {
  let offset = start + 4;
  for (let blocks = 0; blocks < MAX_FLAC_BLOCKS; blocks++) {
    if (offset + 4 > reader.size) break;
    const header = await reader.read(offset, 4);
    const last = (header.readUInt8(0) & 0x80) !== 0;
    const type = header.readUInt8(0) & 0x7f;
    const size = header.readUIntBE(1, 3);
    const body = offset + 4;
    if (body + size > reader.size) break;
    if (type === 4) return vorbisComment(reader, body, body + size);
    if (last) break;
    offset = body + size;
  }
  return {};
}

/**
 * `VORBIS_COMMENT` fields: a vendor string (skipped by its length, never read),
 * a comment count, then `KEY=VALUE` UTF-8 comments. Keys are case-insensitive.
 */
async function vorbisComment(
  reader: BoundedReader,
  start: number,
  end: number,
): Promise<MediaInfoTags> {
  if (start + 4 > end) return {};
  const vendorLength = (await reader.read(start, 4)).readUInt32LE(0);
  let offset = start + 4 + vendorLength;
  if (offset + 4 > end) return {};
  const count = (await reader.read(offset, 4)).readUInt32LE(0);
  offset += 4;
  const tags: MediaInfoTags = {};
  for (let i = 0; i < Math.min(count, MAX_VORBIS_COMMENTS); i++) {
    if (offset + 4 > end) break;
    const length = (await reader.read(offset, 4)).readUInt32LE(0);
    offset += 4;
    if (offset + length > end) break;
    if (length > 0 && length <= MAX_TEXT_BYTES) {
      assignVorbisComment(tags, await reader.read(offset, length));
    }
    offset += length;
  }
  return tags;
}

const VORBIS_FIELDS: Record<string, keyof MediaInfoTags | undefined> = {
  TITLE: "title",
  ARTIST: "artist",
  ALBUM: "album",
};

function assignVorbisComment(tags: MediaInfoTags, comment: Buffer): void {
  const text = decodeStrict(UTF8, comment);
  if (text === undefined) return;
  const separator = text.indexOf("=");
  if (separator <= 0) return;
  const field = VORBIS_FIELDS[text.slice(0, separator).toUpperCase()];
  assign(tags, field, sanitizeText(text.slice(separator + 1)));
}

// MARK: - WAV / RF64

const INFO_FIELDS: Record<string, keyof MediaInfoTags | undefined> = {
  INAM: "title",
  IART: "artist",
  IPRD: "album",
};

/**
 * RIFF chunks from the header to the end of the file. Metadata may follow the
 * audio, so the walk steps over `data` by its declared size instead of stopping.
 */
async function wavTags(reader: BoundedReader): Promise<MediaInfoTags> {
  let info: MediaInfoTags = {};
  let id3: MediaInfoTags = {};
  let offset = 12;
  for (let i = 0; i < MAX_WAV_CHUNKS && offset + 8 <= reader.size; i++) {
    const header = await reader.read(offset, 8);
    const id = header.toString("latin1", 0, 4);
    const size = header.readUInt32LE(4);
    const body = offset + 8;
    if (body + size > reader.size) break;
    if (id === "LIST") info = merge(info, await riffInfoTags(reader, body, body + size));
    else if (id === "id3 " || id === "ID3 ") {
      id3 = merge(id3, await id3v2Tag(reader, body, body + size));
    }
    // Chunks are word-aligned: an odd-size chunk carries one pad byte.
    offset = body + size + (size & 1);
  }
  // `LIST`/`INFO` owns the WAV tag names; an `id3 ` chunk fills what it lacks.
  return merge(info, id3);
}

async function riffInfoTags(
  reader: BoundedReader,
  start: number,
  end: number,
): Promise<MediaInfoTags> {
  if (start + 4 > end) return {};
  if ((await reader.read(start, 4)).toString("latin1") !== "INFO") return {};
  const tags: MediaInfoTags = {};
  let offset = start + 4;
  for (let i = 0; i < MAX_INFO_SUBCHUNKS && offset + 8 <= end; i++) {
    const header = await reader.read(offset, 8);
    const id = header.toString("latin1", 0, 4);
    const size = header.readUInt32LE(4);
    offset += 8;
    if (offset + size > end) break;
    const field = INFO_FIELDS[id];
    if (field !== undefined && tags[field] === undefined && size > 0 && size <= MAX_TEXT_BYTES) {
      assign(tags, field, sanitizeText(decodeInfoText(await reader.read(offset, size))));
    }
    offset += size + (size & 1);
  }
  return tags;
}

// MARK: - Field merging

function assign(
  tags: MediaInfoTags,
  field: keyof MediaInfoTags | undefined,
  value: string | undefined,
): void {
  if (field === undefined || value === undefined) return;
  if (tags[field] === undefined) tags[field] = value;
}

/** `base` wins; `extra` fills only what it leaves unknown. */
function merge(base: MediaInfoTags, extra: MediaInfoTags): MediaInfoTags {
  return {
    title: base.title ?? extra.title,
    artist: base.artist ?? extra.artist,
    album: base.album ?? extra.album,
  };
}

function hasFields(tags: MediaInfoTags): boolean {
  return tags.title !== undefined || tags.artist !== undefined || tags.album !== undefined;
}

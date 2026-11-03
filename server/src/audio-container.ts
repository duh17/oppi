/**
 * Which container's headers a file starts with.
 *
 * The length pass and the tag pass read different structures but must agree on
 * what the file is, so both start here. Detection is bounded like any other
 * walk: it reads the first bytes and the leading ID3v2 tag headers only.
 */

import { type BoundedReader, syncsafeUInt32, unknown } from "./audio-bytes.js";

export type AudioContainer =
  | { kind: "wav"; rf64: boolean }
  | { kind: "flac"; start: number }
  | { kind: "mp4" }
  | { kind: "mp3"; audioStart: number };

/** Box types a QuickTime or ISO BMFF file plausibly starts with. */
const MP4_FIRST_BOXES = new Set(["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"]);

/**
 * AIFF, CAF, Ogg and Matroska/WebM have no parser here; stop before the MP3
 * frame search, which could otherwise mistake their payload for frames.
 */
const UNPARSED_MAGICS = new Set(["FORM", "caff", "OggS", "\x1a\x45\xdf\xa3"]);

/**
 * Tags read before the audio in one file; more is unknown, not a frame search.
 * Keep in step with `MAX_ID3_TAGS` in `audio-tags.ts`, which reads the same ones.
 */
const MAX_ID3_TAGS = 8;

export async function detectContainer(reader: BoundedReader): Promise<AudioContainer> {
  const head = await reader.read(0, Math.min(12, reader.size));
  const magic = head.toString("latin1", 0, 4);
  if ((magic === "RIFF" || magic === "RF64") && head.toString("latin1", 8, 12) === "WAVE") {
    return { kind: "wav", rf64: magic === "RF64" };
  }
  if (magic === "fLaC") return { kind: "flac", start: 0 };
  if (head.length >= 8 && MP4_FIRST_BOXES.has(head.toString("latin1", 4, 8)))
    return { kind: "mp4" };
  if (UNPARSED_MAGICS.has(magic)) unknown();
  const audioStart = await skipId3v2(reader);
  if (audioStart + 4 <= reader.size) {
    const marker = await reader.read(audioStart, 4);
    // A FLAC stream with an ID3v2 tag in front of its marker (some taggers do this).
    if (marker.toString("latin1") === "fLaC") return { kind: "flac", start: audioStart };
  }
  return { kind: "mp3", audioStart };
}

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
    const tagSize = syncsafeUInt32(header, 6) ?? unknown();
    const hasFooter = (header.readUInt8(5) & 0x10) !== 0;
    offset += 10 + tagSize + (hasFooter ? 10 : 0);
    if (offset > reader.size) unknown();
  }
  return offset;
}

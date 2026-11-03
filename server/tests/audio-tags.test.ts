import { describe, expect, it } from "vitest";

import { readAudioTags } from "../src/audio-tags.js";
import { boundedPassProblem, mutate, seeded, source, tagsProblem } from "./harness/audio-fuzz.js";

function ascii(text: string): Buffer {
  return Buffer.from(text, "latin1");
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

/** Four 7-bit bytes, the way ID3 states a tag or v2.4 frame size. */
function syncsafe(value: number): Buffer {
  return Buffer.from([
    (value >> 21) & 0x7f,
    (value >> 14) & 0x7f,
    (value >> 7) & 0x7f,
    value & 0x7f,
  ]);
}

async function tags(bytes: Buffer) {
  return readAudioTags(source(bytes), AbortSignal.timeout(5_000));
}

/** MPEG-1 Layer III, 128 kbps, 44.1 kHz: 417-byte frames of 1152 samples. */
const MP3_FRAME = Buffer.concat([Buffer.from([0xff, 0xfb, 0x90, 0x44]), Buffer.alloc(413)]);

function mp3Audio(frames = 4): Buffer {
  return Buffer.concat(Array.from({ length: frames }, () => MP3_FRAME));
}

// MARK: - ID3

function encodedText(text: string, encoding: 0 | 1 | 2 | 3): Buffer {
  switch (encoding) {
    case 0:
      return Buffer.concat([Buffer.from([0]), Buffer.from(text, "latin1")]);
    case 1:
      // UTF-16 with a little-endian BOM, as taggers write it.
      return Buffer.concat([Buffer.from([1, 0xff, 0xfe]), Buffer.from(text, "utf16le")]);
    case 2:
      return Buffer.concat([Buffer.from([2]), Buffer.from(text, "utf16le").swap16()]);
    default:
      return Buffer.concat([Buffer.from([3]), Buffer.from(text, "utf8")]);
  }
}

interface FrameSpec {
  id: string;
  body: Buffer;
  /** The v2.3/v2.4 format flags byte. */
  flags?: number;
}

function id3Frame(version: 2 | 3 | 4, frame: FrameSpec): Buffer {
  const headerSize = version === 2 ? 6 : 10;
  const header = Buffer.alloc(headerSize);
  header.write(frame.id, 0, "latin1");
  if (version === 2) header.writeUIntBE(frame.body.length, 3, 3);
  else if (version === 4) syncsafe(frame.body.length).copy(header, 4);
  else header.writeUInt32BE(frame.body.length, 4);
  if (headerSize === 10) header.writeUInt8(frame.flags ?? 0, 9);
  return Buffer.concat([header, frame.body]);
}

/** One ID3v2 tag; `flags` is the whole tag header's flags byte. */
function id3v2(version: 2 | 3 | 4, frames: FrameSpec[], options: { flags?: number } = {}): Buffer {
  const body = Buffer.concat(frames.map((frame) => id3Frame(version, frame)));
  const header = Buffer.concat([
    ascii("ID3"),
    Buffer.from([version, 0, options.flags ?? 0]),
    syncsafe(body.length),
  ]);
  return Buffer.concat([header, body]);
}

const TITLE: FrameSpec = { id: "TIT2", body: encodedText("Episode 12", 3) };
const ARTIST: FrameSpec = { id: "TPE1", body: encodedText("Alex Rivera", 3) };
const ALBUM: FrameSpec = { id: "TALB", body: encodedText("Field Notes", 3) };

function id3v1(fields: { title?: string; artist?: string; album?: string }): Buffer {
  const field = (value: string | undefined) => {
    const out = Buffer.alloc(30);
    out.write(value ?? "", 0, "latin1");
    return out;
  };
  return Buffer.concat([
    ascii("TAG"),
    field(fields.title),
    field(fields.artist),
    field(fields.album),
    Buffer.alloc(35),
  ]);
}

describe("ID3 tags", () => {
  it("reads ID3v2.3 text frames", async () => {
    expect(await tags(Buffer.concat([id3v2(3, [TITLE, ARTIST, ALBUM]), mp3Audio()]))).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("reads ID3v2.4 frames and its syncsafe frame sizes", async () => {
    expect(await tags(Buffer.concat([id3v2(4, [TITLE, ARTIST, ALBUM]), mp3Audio()]))).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("reads ID3v2.2's three-character frame ids", async () => {
    const tag = id3v2(2, [
      { id: "TT2", body: encodedText("Episode 12", 3) },
      { id: "TP1", body: encodedText("Alex Rivera", 3) },
      { id: "TAL", body: encodedText("Field Notes", 3) },
    ]);
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("decodes Latin-1, UTF-16 with a BOM, and UTF-16BE without one", async () => {
    const tag = id3v2(3, [
      { id: "TIT2", body: encodedText("Episode 12", 0) },
      { id: "TPE1", body: encodedText("Alex Rivera", 1) },
      { id: "TALB", body: encodedText("Field Notes", 2) },
    ]);
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("falls back to ID3v1 when there is no ID3v2 tag", async () => {
    const bytes = Buffer.concat([
      mp3Audio(),
      id3v1({ title: "Episode 12", artist: "Alex Rivera", album: "Field Notes" }),
    ]);
    expect(await tags(bytes)).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("fills each field ID3v2 leaves unknown from ID3v1", async () => {
    const bytes = Buffer.concat([
      id3v2(3, [TITLE]),
      mp3Audio(),
      id3v1({ title: "Ignored", artist: "Alex Rivera", album: "Field Notes" }),
    ]);
    expect(await tags(bytes)).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("strips control, bidi and separator characters and trims", async () => {
    const tag = id3v2(3, [
      { id: "TIT2", body: encodedText("  Ep\u0001isode\u202e12\u200f  ", 3) },
      { id: "TPE1", body: encodedText("\u007fAlex Rivera\u009f", 3) },
      { id: "TALB", body: encodedText("Field\u2028Notes\u2029 \u061c", 3) },
    ]);
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toEqual({
      title: "Episode12",
      artist: "Alex Rivera",
      album: "FieldNotes",
    });
  });

  it("omits a field over 256 characters and keeps the others", async () => {
    const long = "x".repeat(257);
    const tag = id3v2(3, [
      { id: "TIT2", body: encodedText(long, 3) },
      { id: "TPE1", body: encodedText("Alex Rivera", 3) },
    ]);
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toEqual({ artist: "Alex Rivera" });
  });

  it("keeps a 256-character field", async () => {
    const edge = "y".repeat(256);
    const tag = id3v2(3, [{ id: "TIT2", body: encodedText(edge, 3) }]);
    expect((await tags(Buffer.concat([tag, mp3Audio()])))?.title).toBe(edge);
  });

  it("omits a field whose bytes are not the encoding it declares", async () => {
    const tag = id3v2(3, [
      { id: "TIT2", body: Buffer.concat([Buffer.from([3]), Buffer.from([0xff, 0xfe, 0xc0])]) },
      { id: "TPE1", body: encodedText("Alex Rivera", 3) },
    ]);
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toEqual({ artist: "Alex Rivera" });
  });

  it.each([
    ["v2.3 compression", 3, 0x80],
    ["v2.3 encryption", 3, 0x40],
    ["v2.3 grouping", 3, 0x20],
    ["v2.4 unsynchronisation", 4, 0x02],
    ["v2.4 data length indicator", 4, 0x01],
  ] as const)("skips a frame with %s and reads the rest", async (_name, version, flags) => {
    const tag = id3v2(version, [{ ...TITLE, flags }, ARTIST]);
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toEqual({ artist: "Alex Rivera" });
  });

  it("skips a tag with a tag-level unsynchronisation scheme", async () => {
    const tag = id3v2(3, [TITLE, ARTIST], { flags: 0x80 });
    expect(await tags(Buffer.concat([tag, mp3Audio()]))).toBeUndefined();
  });

  it("skips a tag with an extended header and reads the tag after it", async () => {
    const extended = id3v2(3, [TITLE], { flags: 0x40 });
    const bytes = Buffer.concat([extended, id3v2(3, [ARTIST]), mp3Audio()]);
    expect(await tags(bytes)).toEqual({ artist: "Alex Rivera" });
  });

  it("reports no tags for a lone tag with an extended header", async () => {
    expect(
      await tags(Buffer.concat([id3v2(3, [TITLE], { flags: 0x40 }), mp3Audio()])),
    ).toBeUndefined();
  });

  it("does not read a text value over 4 KiB", async () => {
    const file = source(
      Buffer.concat([
        id3v2(3, [{ id: "TIT2", body: encodedText("x".repeat(8_000), 3) }, ARTIST]),
        mp3Audio(),
      ]),
    );
    const read = await readAudioTags(file, AbortSignal.timeout(5_000));
    expect(read).toEqual({ artist: "Alex Rivera" });
    // Frame headers only: the 8 KiB value is skipped by its declared size.
    expect(file.bytesRead).toBeLessThan(400);
  });

  it("stops at 512 frames and keeps what it found", async () => {
    const padding: FrameSpec[] = Array.from({ length: 600 }, () => ({
      id: "TXXX",
      body: encodedText("pad", 3),
    }));
    const bytes = Buffer.concat([id3v2(3, [TITLE, ...padding, ARTIST]), mp3Audio()]);
    expect(await tags(bytes)).toEqual({ title: "Episode 12" });
  });

  it("reports no tags when the pass exhausts its own budget", async () => {
    const heavy: FrameSpec[] = Array.from({ length: 600 }, () => ({
      id: "TIT2",
      body: encodedText("z".repeat(3_900), 3),
    }));
    const file = source(Buffer.concat([id3v2(3, heavy), mp3Audio()]));
    expect(await readAudioTags(file, AbortSignal.timeout(5_000))).toBeUndefined();
    expect(file.bytesRead).toBeLessThanOrEqual(512 * 1024);
  });

  it("reports no tags when the file states none", async () => {
    expect(await tags(mp3Audio())).toBeUndefined();
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

/** A `data` box: version/flags (the low byte is the type), locale, then the value. */
function dataBox(value: Buffer, type = 1): Buffer {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(type, 0);
  return box("data", head, value);
}

function ilst(...items: Buffer[]): Buffer {
  return box("ilst", ...items);
}

function m4aWithIlst(ilstBox: Buffer): Buffer {
  return Buffer.concat([
    box("ftyp", ascii("M4A "), u32be(0)),
    box("moov", mvhd(1_000, 7_000), box("udta", box("meta", u32be(0), ilstBox))),
    box("mdat", Buffer.alloc(64)),
  ]);
}

const NAM = "\u00a9nam";
const ART = "\u00a9ART";
const ALB = "\u00a9alb";

describe("MP4 tags", () => {
  it("reads the ilst title, artist and album", async () => {
    const bytes = m4aWithIlst(
      ilst(
        box(NAM, dataBox(Buffer.from("Episode 12", "utf8"))),
        box(ART, dataBox(Buffer.from("Alex Rivera", "utf8"))),
        box(ALB, dataBox(Buffer.from("Field Notes", "utf8"))),
      ),
    );
    expect(await tags(bytes)).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("falls back to the album artist", async () => {
    const bytes = m4aWithIlst(ilst(box("aART", dataBox(Buffer.from("Alex Rivera", "utf8")))));
    expect(await tags(bytes)).toEqual({ artist: "Alex Rivera" });
  });

  it("reads only UTF-8 data boxes", async () => {
    const bytes = m4aWithIlst(
      ilst(
        box(NAM, dataBox(Buffer.from("E\u0000p\u0000i\u0000", "latin1"), 2)),
        box(ART, dataBox(Buffer.from("Alex Rivera", "utf8"))),
      ),
    );
    expect(await tags(bytes)).toEqual({ artist: "Alex Rivera" });
  });

  it("does not read a value over 4 KiB", async () => {
    const bytes = m4aWithIlst(
      ilst(
        box(NAM, dataBox(Buffer.from("x".repeat(8_000), "utf8"))),
        box(ART, dataBox(Buffer.from("Alex Rivera", "utf8"))),
      ),
    );
    expect(await tags(bytes)).toEqual({ artist: "Alex Rivera" });
  });

  it("reports no tags when the ilst walk exceeds the box cap", async () => {
    const items = Array.from({ length: 1_100 }, (_, i) =>
      box(NAM, dataBox(Buffer.from(`Episode ${i}`, "utf8"))),
    );
    expect(await tags(m4aWithIlst(ilst(...items)))).toBeUndefined();
  });

  it("reports no tags for a movie without udta", async () => {
    const bytes = Buffer.concat([
      box("ftyp", ascii("M4A "), u32be(0)),
      box("moov", mvhd(1_000, 7_000)),
      box("mdat", Buffer.alloc(64)),
    ]);
    expect(await tags(bytes)).toBeUndefined();
  });
});

// MARK: - FLAC

function flacWithBlocks(blocks: { type: number; body: Buffer }[]): Buffer {
  const info = Buffer.alloc(34);
  info.writeUInt16BE(4_096, 0);
  info.writeUInt16BE(4_096, 2);
  info[10] = (44_100 >> 12) & 0xff;
  info[11] = (44_100 >> 4) & 0xff;
  info[12] = ((44_100 & 0x0f) << 4) | (1 << 1) | 0;
  info[13] = 15 << 4;
  const parts = [ascii("fLaC"), Buffer.from([0, 0, 0, 34]), info];
  blocks.forEach((block, index) => {
    const last = index === blocks.length - 1 ? 0x80 : 0;
    parts.push(
      Buffer.from([last | block.type]),
      Buffer.from([
        (block.body.length >> 16) & 0xff,
        (block.body.length >> 8) & 0xff,
        block.body.length & 0xff,
      ]),
      block.body,
    );
  });
  return Buffer.concat(parts);
}

function vorbisComment(comments: string[], vendor = "Oppi"): Buffer {
  const vendorBytes = Buffer.from(vendor, "utf8");
  const parts = [u32le(vendorBytes.length), vendorBytes, u32le(comments.length)];
  for (const comment of comments) {
    const bytes = Buffer.from(comment, "utf8");
    parts.push(u32le(bytes.length), bytes);
  }
  return Buffer.concat(parts);
}

describe("FLAC tags", () => {
  it("reads VORBIS_COMMENT with case-insensitive keys", async () => {
    const bytes = flacWithBlocks([
      {
        type: 4,
        body: vorbisComment(["Title=Episode 12", "ARTIST=Alex Rivera", "album=Field Notes"]),
      },
    ]);
    expect(await tags(bytes)).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("skips a vendor string without reading it", async () => {
    const file = source(
      flacWithBlocks([{ type: 4, body: vorbisComment(["TITLE=Episode 12"], "v".repeat(100_000)) }]),
    );
    expect(await readAudioTags(file, AbortSignal.timeout(5_000))).toEqual({ title: "Episode 12" });
    expect(file.bytesRead).toBeLessThan(1_000);
  });

  it("does not read a comment over 4 KiB", async () => {
    const bytes = flacWithBlocks([
      { type: 4, body: vorbisComment([`TITLE=${"x".repeat(8_000)}`, "ARTIST=Alex Rivera"]) },
    ]);
    expect(await tags(bytes)).toEqual({ artist: "Alex Rivera" });
  });

  it("omits a comment that is not UTF-8", async () => {
    const raw = Buffer.from([0xff, 0xfe, 0xc0, 0x41]);
    const bytes = flacWithBlocks([
      { type: 4, body: Buffer.concat([u32le(0), u32le(1), u32le(raw.length), raw]) },
    ]);
    expect(await tags(bytes)).toBeUndefined();
  });

  it("reports no tags when the block walk exceeds 64 blocks", async () => {
    const padding = Array.from({ length: 70 }, () => ({ type: 1, body: Buffer.alloc(4) }));
    const bytes = flacWithBlocks([...padding, { type: 4, body: vorbisComment(["TITLE=Late"]) }]);
    expect(await tags(bytes)).toBeUndefined();
  });

  it("reports no tags for a FLAC with no VORBIS_COMMENT", async () => {
    expect(await tags(flacWithBlocks([{ type: 1, body: Buffer.alloc(8) }]))).toBeUndefined();
  });
});

// MARK: - WAV

function riffChunk(id: string, body: Buffer): Buffer {
  const pad = body.length % 2 === 1 ? Buffer.alloc(1) : Buffer.alloc(0);
  return Buffer.concat([ascii(id), u32le(body.length), body, pad]);
}

function fmtBody(sampleRate = 8_000, channels = 1): Buffer {
  const fmt = Buffer.alloc(16);
  fmt.writeUInt16LE(1, 0);
  fmt.writeUInt16LE(channels, 2);
  fmt.writeUInt32LE(sampleRate, 4);
  fmt.writeUInt32LE(sampleRate * channels * 2, 8);
  fmt.writeUInt16LE(channels * 2, 12);
  fmt.writeUInt16LE(16, 14);
  return fmt;
}

function listInfo(fields: { id: string; value: string }[]): Buffer {
  return riffChunk(
    "LIST",
    Buffer.concat([
      ascii("INFO"),
      ...fields.map((field) => riffChunk(field.id, Buffer.from(field.value, "utf8"))),
    ]),
  );
}

function wavWithChunks(chunks: Buffer[]): Buffer {
  const body = Buffer.concat([ascii("WAVE"), riffChunk("fmt ", fmtBody()), ...chunks]);
  return Buffer.concat([ascii("RIFF"), u32le(body.length), body]);
}

const dataChunk = riffChunk("data", Buffer.alloc(800));

describe("WAV tags", () => {
  it("reads LIST/INFO before the audio", async () => {
    const bytes = wavWithChunks([
      listInfo([
        { id: "INAM", value: "Episode 12" },
        { id: "IART", value: "Alex Rivera" },
        { id: "IPRD", value: "Field Notes" },
      ]),
      dataChunk,
    ]);
    expect(await tags(bytes)).toEqual({
      title: "Episode 12",
      artist: "Alex Rivera",
      album: "Field Notes",
    });
  });

  it("keeps walking past the audio to a LIST after it", async () => {
    const bytes = wavWithChunks([dataChunk, listInfo([{ id: "INAM", value: "Episode 12" }])]);
    expect(await tags(bytes)).toEqual({ title: "Episode 12" });
  });

  it("fills what LIST lacks from an `id3 ` chunk, whichever comes first", async () => {
    const id3 = riffChunk("id3 ", id3v2(3, [TITLE, ARTIST]));
    const bytes = wavWithChunks([id3, listInfo([{ id: "INAM", value: "List Title" }]), dataChunk]);
    // LIST/INFO owns the name `INFO` states; the ID3 chunk fills the rest.
    expect(await tags(bytes)).toEqual({ title: "List Title", artist: "Alex Rivera" });
  });

  it("reads an `ID3 ` chunk too", async () => {
    const bytes = wavWithChunks([riffChunk("ID3 ", id3v2(3, [TITLE])), dataChunk]);
    expect(await tags(bytes)).toEqual({ title: "Episode 12" });
  });

  it("does not read an INFO value over 4 KiB", async () => {
    const bytes = wavWithChunks([
      listInfo([
        { id: "INAM", value: "x".repeat(8_000) },
        { id: "IART", value: "Alex Rivera" },
      ]),
      dataChunk,
    ]);
    expect(await tags(bytes)).toEqual({ artist: "Alex Rivera" });
  });

  it("reads Latin-1 INFO values that are not UTF-8", async () => {
    const bytes = wavWithChunks([
      riffChunk(
        "LIST",
        Buffer.concat([ascii("INFO"), riffChunk("INAM", Buffer.from([0xe9, 0x74, 0xe9]))]),
      ),
      dataChunk,
    ]);
    expect(await tags(bytes)).toEqual({ title: "\u00e9t\u00e9" });
  });

  it("reports no tags for a WAV whose `id3 ` chunk is garbage", async () => {
    const bytes = wavWithChunks([riffChunk("id3 ", Buffer.alloc(64, 0xff)), dataChunk]);
    expect(await tags(bytes)).toBeUndefined();
  });
});

// MARK: - Unsupported containers

describe("formats without a tag parser", () => {
  it.each([
    ["AIFF", "FORM"],
    ["CAF", "caff"],
    ["Ogg", "OggS"],
  ])("reports no tags for a %s file", async (_name, magic) => {
    const bytes = Buffer.concat([ascii(magic), Buffer.alloc(64), id3v2(3, [TITLE])]);
    expect(await tags(bytes)).toBeUndefined();
  });
});

// MARK: - Seeded mutation fuzz

const FUZZ_SEED = 0x5eed_7a95;
const FUZZ_CASES_PER_FORMAT = 2_000;

const fuzzBases: [string, Buffer][] = [
  ["ID3v2.3 with text frames", Buffer.concat([id3v2(3, [TITLE, ARTIST, ALBUM]), mp3Audio()])],
  ["ID3v2.4 with text frames", Buffer.concat([id3v2(4, [TITLE, ARTIST, ALBUM]), mp3Audio()])],
  [
    "MP4 with ilst",
    m4aWithIlst(
      ilst(
        box(NAM, dataBox(Buffer.from("Episode 12", "utf8"))),
        box(ART, dataBox(Buffer.from("Alex Rivera", "utf8"))),
      ),
    ),
  ],
  [
    "FLAC with VORBIS_COMMENT",
    flacWithBlocks([{ type: 4, body: vorbisComment(["TITLE=Episode 12", "ALBUM=Field Notes"]) }]),
  ],
  [
    "WAV with LIST and an id3 chunk",
    wavWithChunks([
      listInfo([{ id: "INAM", value: "Episode 12" }]),
      riffChunk("id3 ", id3v2(3, [ARTIST])),
      dataChunk,
    ]),
  ],
];

describe("readAudioTags under seeded mutation", () => {
  it.each(fuzzBases.map(([name, bytes], index) => [name, bytes, index] as const))(
    "keeps every guarantee for 2,000 mutated %s files",
    async (name, base, index) => {
      const caseSeeds = seeded(FUZZ_SEED + index);
      const failures: string[] = [];
      for (let n = 0; n < FUZZ_CASES_PER_FORMAT; n++) {
        const seed = Math.floor(caseSeeds() * 2 ** 32);
        const problem = await boundedPassProblem(
          mutate(base, seeded(seed)),
          async (file, deadline) => {
            const read = await readAudioTags(file, deadline);
            return { result: read, problem: tagsProblem(read) };
          },
        );
        // Replay one case with mutate(base, seeded(seed)).
        if (problem) failures.push(`${name} case ${n}, seed 0x${seed.toString(16)}: ${problem}`);
      }
      expect(failures.slice(0, 5), `fuzz seed 0x${FUZZ_SEED.toString(16)}`).toEqual([]);
    },
    30_000,
  );
});

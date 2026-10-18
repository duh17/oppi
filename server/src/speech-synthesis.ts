/**
 * Read-aloud synthesis for chat messages (`POST /speech`).
 *
 * `tts.provider` picks the backend:
 *   http — OpenAI-compatible `POST {endpoint}/v1/audio/speech` returning WAV
 *          (Yuwp, a local OpenAI-compatible server, and similar).
 *   xai  — Grok `POST {endpoint}/v1/tts` with raw PCM output.
 *          Docs: https://docs.x.ai/developers/model-capabilities/audio/text-to-speech
 *
 * A message is read as short passages synthesized in order, so playback starts
 * after the first passage instead of after the whole message. Every provider's
 * audio is normalized to 16-bit little-endian PCM at the provider's own rate.
 */

import { resolveSttBearerToken, type SttGetAuth } from "./create-stt-provider.js";
import type { ServerConfig } from "./types.js";

export type TtsConfig = NonNullable<ServerConfig["tts"]>;
export type TtsProviderId = NonNullable<TtsConfig["provider"]>;

export const DEFAULT_XAI_TTS_ENDPOINT = "https://api.x.ai";
/** xAI's unary limit; also a sane bound for one read-aloud request. */
export const SPEECH_MAX_TEXT_CHARS = 60_000;
const XAI_PCM_SAMPLE_RATE = 24_000;
/** The first passage is short so audio starts quickly; later ones carry more prosody. */
const FIRST_PASSAGE_CHARS = 120;
const PASSAGE_CHARS = 900;

export interface PcmAudio {
  sampleRate: number;
  channels: number;
  /** 16-bit little-endian interleaved samples. */
  pcm: Buffer;
}

export class SpeechError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = "SpeechError";
  }
}

export function resolveTtsProvider(tts: TtsConfig | undefined): TtsProviderId | undefined {
  if (tts?.provider === "http" || tts?.provider === "xai") return tts.provider;
  const endpoint = tts?.endpoint?.trim();
  if (!endpoint) return undefined;
  try {
    if (new URL(endpoint).hostname.toLowerCase() === "api.x.ai") return "xai";
  } catch {
    return "http";
  }
  return "http";
}

/** True when the server can read messages aloud (advertised as `capabilities.speech`). */
export function isSpeechEnabled(tts: TtsConfig | undefined): boolean {
  const provider = resolveTtsProvider(tts);
  if (provider === "xai") return true;
  return provider === "http" && (tts?.endpoint?.trim().length ?? 0) > 0;
}

// ─── Text ───

/**
 * Turn assistant Markdown into text worth hearing: code blocks, images, URLs,
 * and HTML are dropped; links and wiki links keep their labels; Markdown
 * markers are removed. Paragraph breaks survive so passages split naturally.
 */
export function speakableText(markdown: string): string {
  // Linear by construction: whitespace runs collapse first and separators are
  // dropped by a character test, so no two neighbouring quantifiers below can
  // split the same run; inner spans are bounded so a long line of unclosed
  // `[`, `<`, or backticks cannot rescan the line from every opener.
  return withoutCodeAndMath(markdown)
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .filter((line) => line.length > 0 && !isRuleOrTableSeparator(line))
    .join("\n")
    .replace(/<[^<>\n]{1,200}>/g, "")
    .replace(/!\[\[[^[\]\n]{0,300}\]\]/g, "")
    .replace(/!\[[^[\]\n]{0,300}\]\([^()\n]{0,2048}\)/g, "")
    .replace(/\[\[([^[\]|\n]{0,300})\|([^[\]\n]{0,300})\]\]/g, "$2")
    .replace(/\[\[([^[\]\n]{0,300})\]\]/g, (_match, target: string) => {
      const name = target.split("#")[0]?.split("/").pop() ?? "";
      return name.replace(/\.[A-Za-z0-9]+$/, "");
    })
    .replace(/\[([^[\]\n]{0,300})\]\([^()\n]{0,2048}\)/g, "$1")
    .replace(/\bhttps?:\/\/[^\s<>'")\]]+/gi, "")
    .replace(/`([^`\n]{0,500})`/g, "$1")
    .replace(/^#{1,6} /gm, "")
    .replace(/^> ?/gm, "")
    .replace(/^([-*+]|\d+[.)]) (\[[ xX]\] )?/gm, "")
    .replace(/^\|(.*)\|$/gm, (_match, cells: string) =>
      cells
        .split("|")
        .map((cell) => cell.trim())
        .filter(Boolean)
        .join(", "),
    )
    .replace(/(\*\*|__|~~|\*)/g, "")
    .replace(/ {2,}/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .trim();
}

/**
 * Horizontal rules (`---`, `* * *`) and table separators (`|---|:--:|`,
 * `|:-|-:|`, `--- | ---`).
 */
function isRuleOrTableSeparator(line: string): boolean {
  if (/^([-*_])( ?\1){2,}$/.test(line)) return true;
  return (
    line.includes("-") && (line.includes("|") || line.includes("---")) && /^[|: -]+$/.test(line)
  );
}

/**
 * Lines without fenced code or display math, matching what the chat renders:
 * a fence (``` or ~~~) closes on a line of the same character at least as
 * long, and an unclosed fence runs to the end. Display math is a whole
 * `$$...$$` line, or a `$$` line through the next `$$` line; an unclosed
 * `$$` stays text, and `$$` inside prose or code spans is ordinary text.
 * One pass over the text.
 */
function withoutCodeAndMath(markdown: string): string[] {
  const kept: string[] = [];
  let fence: string | undefined;
  // Lines after an opening `$$` line, restored if no closing line follows.
  let math: string[] | undefined;
  for (const line of markdown.split(/\r\n?|\n/)) {
    const trimmed = line.trim();
    if (fence) {
      if (trimmed.length >= fence.length && trimmed === fence.charAt(0).repeat(trimmed.length)) {
        fence = undefined;
      }
      continue;
    }
    if (math) {
      if (trimmed === "$$") math = undefined;
      else math.push(line);
      continue;
    }
    const opener = /^(`{3,}|~{3,})/.exec(trimmed)?.[1];
    if (opener) {
      fence = opener;
    } else if (trimmed === "$$") {
      math = [];
    } else if (!(trimmed.length > 4 && trimmed.startsWith("$$") && trimmed.endsWith("$$"))) {
      kept.push(line);
    }
  }
  for (const line of math ?? []) kept.push(line);
  return kept;
}

/** Split speakable text into passages: a short first one, then growing up to paragraph size. */
export function speechPassages(text: string): string[] {
  // Each line is a unit (paragraph, list item, heading). One without closing
  // punctuation gets a period so the voice pauses instead of running items together.
  const sentences = text
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => (/[.!?:;,\u3002\uff01\uff1f]$/.test(line) ? line : `${line}.`))
    .flatMap((line) => line.split(/(?<=[.!?\u3002\uff01\uff1f])\s+/))
    .filter(Boolean);
  const passages: string[] = [];
  let current = "";
  for (const sentence of sentences) {
    // Passages double in size: each one is synthesized while the previous one
    // plays, so it must not take longer to make than the audio already queued.
    const limit = Math.min(PASSAGE_CHARS, FIRST_PASSAGE_CHARS * 2 ** passages.length);
    if (current && current.length + 1 + sentence.length > limit) {
      passages.push(current);
      current = "";
    }
    current = current ? `${current} ${sentence}` : sentence;
  }
  if (current) passages.push(current);
  return passages;
}

// ─── Audio ───

/**
 * Decode a complete WAV file to 16-bit PCM. Accepts integer PCM (16/24/32-bit)
 * and IEEE float (32/64-bit), including WAVE_FORMAT_EXTENSIBLE and extra
 * chunks such as JUNK. A streamed header's unknown data size reads to the end.
 */
export function decodeWavToPcm16(wav: Buffer): PcmAudio {
  if (
    wav.length < 12 ||
    wav.toString("ascii", 0, 4) !== "RIFF" ||
    wav.toString("ascii", 8, 12) !== "WAVE"
  ) {
    throw new SpeechError(502, "TTS backend did not return WAV audio");
  }
  let format: { tag: number; channels: number; sampleRate: number; bits: number } | undefined;
  let offset = 12;
  while (offset + 8 <= wav.length) {
    const id = wav.toString("ascii", offset, offset + 4);
    const declared = wav.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "fmt ") {
      let tag = wav.readUInt16LE(body);
      if (tag === 0xfffe && declared >= 26) tag = wav.readUInt16LE(body + 24);
      format = {
        tag,
        channels: wav.readUInt16LE(body + 2),
        sampleRate: wav.readUInt32LE(body + 4),
        bits: wav.readUInt16LE(body + 14),
      };
    } else if (id === "data") {
      if (!format) throw new SpeechError(502, "TTS WAV has no format chunk");
      const available = wav.length - body;
      const size =
        declared === 0 || declared === 0xffffffff ? available : Math.min(declared, available);
      return {
        sampleRate: format.sampleRate,
        channels: format.channels,
        pcm: toPcm16(wav.subarray(body, body + size), format.tag, format.bits),
      };
    }
    offset = body + declared + (declared % 2);
  }
  throw new SpeechError(502, "TTS WAV has no audio data");
}

function toPcm16(data: Buffer, tag: number, bits: number): Buffer {
  if (tag === 1 && bits === 16)
    return Buffer.from(data.subarray(0, data.length - (data.length % 2)));
  const bytes = bits / 8;
  if (
    !(tag === 1 && (bits === 24 || bits === 32)) &&
    !(tag === 3 && (bits === 32 || bits === 64))
  ) {
    throw new SpeechError(502, `Unsupported TTS WAV encoding (format ${tag}, ${bits}-bit)`);
  }
  const count = Math.floor(data.length / bytes);
  const out = Buffer.alloc(count * 2);
  for (let i = 0; i < count; i++) {
    const at = i * bytes;
    let sample: number;
    if (tag === 3) {
      const value = bits === 32 ? data.readFloatLE(at) : data.readDoubleLE(at);
      sample = Math.round(Math.max(-1, Math.min(1, value)) * 32767);
    } else {
      sample = bits === 24 ? data.readIntLE(at, 3) >> 8 : data.readInt32LE(at) >> 16;
    }
    out.writeInt16LE(sample, i * 2);
  }
  return out;
}

// ─── Providers ───

export interface SpeechDeps {
  fetchFn?: typeof globalThis.fetch;
  getAuth?: SttGetAuth;
  /** Test seam for credentials; production resolves Pi/Oppi provider auth. */
  resolveApiKey?: (providerId: "xai") => Promise<string | undefined>;
}

type Synthesize = (text: string, signal: AbortSignal) => Promise<PcmAudio>;

function createSynthesizer(tts: TtsConfig | undefined, deps: SpeechDeps): Synthesize {
  const provider = resolveTtsProvider(tts);
  if (!tts || !provider || !isSpeechEnabled(tts)) {
    throw new SpeechError(404, "Read aloud is not configured on this server");
  }
  const fetchFn = deps.fetchFn ?? globalThis.fetch;

  if (provider === "xai") {
    const endpoint = (tts.endpoint?.trim() || DEFAULT_XAI_TTS_ENDPOINT).replace(/\/+$/, "");
    return async (text, signal) => {
      const apiKey = (
        deps.resolveApiKey
          ? await deps.resolveApiKey("xai")
          : await resolveSttBearerToken("xai", { getAuth: deps.getAuth })
      )?.trim();
      if (!apiKey) throw new SpeechError(503, "No xAI credentials for read aloud");
      const response = await fetchFn(`${endpoint}/v1/tts`, {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          text,
          ...(tts.voice ? { voice_id: tts.voice } : {}),
          language: tts.language || "auto",
          output_format: { codec: "pcm", sample_rate: XAI_PCM_SAMPLE_RATE },
        }),
        signal,
      });
      const body = await readOk(response, "xAI TTS");
      return {
        sampleRate: XAI_PCM_SAMPLE_RATE,
        channels: 1,
        pcm: body.subarray(0, body.length - (body.length % 2)),
      };
    };
  }

  const endpoint = (tts.endpoint ?? "").trim().replace(/\/+$/, "");
  return async (text, signal) => {
    const response = await fetchFn(`${endpoint}/v1/audio/speech`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...(tts.model ? { model: tts.model } : {}),
        input: text,
        ...(tts.voice ? { voice: tts.voice } : {}),
        response_format: "wav",
      }),
      signal,
    });
    return decodeWavToPcm16(await readOk(response, "TTS backend"));
  };
}

async function readOk(response: Response, label: string): Promise<Buffer> {
  const body = Buffer.from(await response.arrayBuffer());
  if (!response.ok) {
    const detail = body.toString("utf8", 0, Math.min(body.length, 300)).trim();
    throw new SpeechError(
      502,
      `${label} returned ${response.status}${detail ? `: ${detail}` : ""}`,
    );
  }
  return body;
}

export interface SpeechStream {
  sampleRate: number;
  channels: number;
  /** The first passage's audio, already synthesized. */
  first: Buffer;
  /** Remaining passages' audio, synthesized one at a time as the caller pulls. */
  rest: AsyncIterable<Buffer>;
}

/**
 * Start reading `markdown` aloud. Resolves once the first passage is
 * synthesized, so the caller can send headers with the real audio format;
 * later passages must match that format.
 */
export async function startSpeech(
  tts: TtsConfig | undefined,
  markdown: string,
  signal: AbortSignal,
  deps: SpeechDeps = {},
): Promise<SpeechStream> {
  // Cap what is spoken, not the raw reply: skipped code blocks do not count.
  const spoken = speakableText(markdown);
  if (spoken.length > SPEECH_MAX_TEXT_CHARS) {
    throw new SpeechError(413, `Text to read is longer than ${SPEECH_MAX_TEXT_CHARS} characters`);
  }
  const [firstPassage, ...laterPassages] = speechPassages(spoken);
  if (!firstPassage) throw new SpeechError(400, "Nothing to read aloud");
  const synthesize = createSynthesizer(tts, deps);
  const first = await synthesize(firstPassage, signal);
  if (
    first.channels < 1 ||
    first.channels > 2 ||
    first.sampleRate < 8_000 ||
    first.sampleRate > 48_000
  ) {
    throw new SpeechError(
      502,
      `Unsupported TTS audio format (${first.sampleRate} Hz, ${first.channels} ch)`,
    );
  }

  async function* rest(): AsyncGenerator<Buffer> {
    for (const passage of laterPassages) {
      const audio = await synthesize(passage, signal);
      if (audio.sampleRate !== first.sampleRate || audio.channels !== first.channels) {
        throw new SpeechError(502, "TTS backend changed audio format mid-message");
      }
      yield audio.pcm;
    }
  }

  return { sampleRate: first.sampleRate, channels: first.channels, first: first.pcm, rest: rest() };
}

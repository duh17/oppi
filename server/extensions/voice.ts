import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { Text } from "@mariozechner/pi-tui";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import type {
  TTSAudioStreamEvent,
  TTSToolVoiceDetails,
  TTSProviderInfo,
  TTSVoiceReplyDelivery,
} from "../src/tts-provider.js";
import {
  createTTSAudioStreamEmitter,
  createTTSToolVoiceDetails,
  createTTSVoicePresentationDetails,
} from "../src/tts-provider.js";
import type { Storage } from "../src/storage.js";

const DEFAULT_TTS_URL = "http://127.0.0.1:7937";
const DEFAULT_LANGUAGE = "English";
const DEFAULT_VOICE_ID = process.env.PI_DEFAULT_VOICE_ID ?? "elena";
const DEFAULT_TEMPERATURE = 0.8;
const DEFAULT_STREAMING_INTERVAL = 0.2;
const MAX_TEXT_CHARS = 5_000;
const MAX_EMBED_AUDIO_BYTES = 12 * 1024 * 1024;
const SERVER_START_TIMEOUT_MS = 30_000;

function sanitizeSpokenVoiceText(text: string): string {
  // Voice is for listening, especially while driving. Raw URLs and full street
  // addresses are hard to understand and waste attention, so keep them out of
  // speech. Put navigation links in regular message text/metadata instead.
  return text
    .replace(/\bhttps?:\/\/[^\s<>'")\]]+/gi, "")
    .replace(/\bwww\.[^\s<>'")\]]+/gi, "")
    .replace(/\b(?:Google|Apple)(?: Maps?| navigation)?\s*(?:link)?\s*:\s*/gi, "")
    .replace(
      /\b\d{2,6}\s+(?:(?:N|S|E|W|NE|NW|SE|SW|North|South|East|West|Northeast|Northwest|Southeast|Southwest)\.?\s+)?(?:[A-Z][\w'.-]*\s+){0,5}(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Boulevard|Blvd|Way|Lane|Ln|Court|Ct|Highway|Hwy)\b/gi,
      "the street address",
    )
    .replace(/[ \t]+\./g, ".")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

const VOICE_DESIGN_REPOS = [
  "models--Qwen--Qwen3-TTS-12Hz-1.7B-VoiceDesign",
  "models--Qwen--Qwen3-TTS-12Hz-0.6B-VoiceDesign",
  "models--Qwen--Qwen3-TTS-12Hz-1.7B-CustomVoice",
  "models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice",
];

type VoiceDeliveryMode = TTSVoiceReplyDelivery;

const YUWP_PROVIDER = {
  id: "yuwp",
  displayName: "Yuwp",
  capabilities: {
    streaming: true,
    listVoices: true,
    designVoice: true,
    providerNativeFormats: ["audio/wav", "audio/pcm; codecs=s16le"],
  },
} satisfies TTSProviderInfo;

type VoiceRecord = {
  id: string;
  object?: string;
  name: string;
  kind: string;
  prompt?: string;
  voice?: string;
  language?: string;
  preview_filename?: string;
  tags?: string[];
  created_at?: string;
  updated_at?: string;
  defaults?: Record<string, unknown>;
};

type VoicePreferencesRecord = {
  defaultVoiceId?: string;
  updatedAt?: string;
};

type SessionVoiceReplyMode = "manual" | "autoplay" | "default";

type AudioDetails = TTSToolVoiceDetails["audio"] & {
  mimeType: "audio/wav";
  path: string;
  fileName: string;
  sizeBytes: number;
};

type VoiceToolDetails = {
  serverUrl: string;
  voice?: VoiceRecord;
  voices?: VoiceRecord[];
  audio?: AudioDetails;
  played?: boolean;
  message?: string;
  delivery?: VoiceDeliveryMode;
  presentation?: TTSToolVoiceDetails["presentation"];
  provider?: TTSToolVoiceDetails["provider"];
  preferences?: VoicePreferencesRecord;
};

type VoiceSpeakToolDetails = TTSToolVoiceDetails & {
  serverUrl: string;
  audio: AudioDetails;
  played?: boolean;
  preferences?: VoicePreferencesRecord;
};

type SpeechResult = {
  metrics: Record<string, unknown>;
};

type SpeechRequest = {
  model: string;
  voice: string;
  input: string;
  response_format: "wav";
  stream?: boolean;
  language?: string;
  temperature?: number;
  streaming_interval?: number;
};

type YuwpStreamEvent = {
  event?: string;
  sample_rate?: number;
  channels?: number;
  audio?: string;
  chunk?: number;
  seconds?: number;
  audio_duration_seconds?: number;
  error?: string;
};

function hasError(value: unknown): value is { error: unknown } {
  return Boolean(value && typeof value === "object" && "error" in value);
}

let serverProcess: ReturnType<typeof spawn> | undefined;
let speechQueue: Promise<unknown> = Promise.resolve();

export function createVoiceFactory(storage?: Storage): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "voice_create",
      label: "Create Voice",
      description:
        "Create or update a local Yuwp TTS voice from a VoiceDesign prompt, optionally generate a short preview, and return audio details for TUI/Oppi timeline playback.",
      promptSnippet: "Create a reusable local voice for Yuwp TTS",
      promptGuidelines: [
        "Use voice_create when the user asks to design, tweak, save, or preview a reusable speaking voice.",
        "Prefer stable, short lowercase voice IDs like warm-technical-teammate or calm-asian-woman.",
        "Avoid celebrity, private-person, or deceptive impersonation voices. Describe qualities, accent, cadence, warmth, and delivery instead.",
        "Use preview playback when the user wants to hear the voice immediately.",
        "For voice_create, choose preview text that sounds like real conversation and can serve as a stable long-term anchor.",
        "For voice_create, optimize reusable voices for consistency, natural pacing, and medium-energy conversational delivery instead of flashy demo energy.",
      ],
      parameters: Type.Object({
        id: Type.Optional(
          Type.String({
            description: "Stable voice ID. Lowercase letters, numbers, dash, or underscore.",
          }),
        ),
        name: Type.String({ description: "Human readable voice name." }),
        prompt: Type.String({
          description:
            "VoiceDesign prompt describing tone, age range, accent, pace, warmth, and delivery.",
        }),
        language: Type.Optional(
          Type.String({ description: "Default language. Default: English." }),
        ),
        tags: Type.Optional(
          Type.Array(Type.String(), { description: "Optional tags for organization." }),
        ),
        temperature: Type.Optional(
          Type.Number({ description: "Default sampling temperature. Default: 0.8." }),
        ),
        previewText: Type.Optional(
          Type.String({ description: "Preview text. Default is a short neutral preview." }),
        ),
        playPreview: Type.Optional(
          Type.Boolean({
            description: "Play the preview locally with afplay on macOS. Default: true.",
          }),
        ),
        overwrite: Type.Optional(
          Type.Boolean({
            description: "PATCH existing voice if ID already exists. Default: true.",
          }),
        ),
        embedAudio: Type.Optional(
          Type.Boolean({
            description:
              "Embed small preview WAV as base64 in tool details for Oppi timeline playback. Default: true.",
          }),
        ),
        setDefault: Type.Optional(
          Type.Boolean({
            description: "Persist this voice as the default for future voice_speak calls.",
          }),
        ),
      }),
      async execute(_toolCallId, params, _signal, onUpdate) {
        return enqueue(async () => {
          onUpdate?.({
            content: [{ type: "text", text: "Creating local Yuwp voice..." }],
            details: { status: "creating" },
          });
          const serverUrl = await ensureYuwpTTSServer();
          const body = {
            id: params.id,
            name: params.name,
            kind: "design",
            prompt: params.prompt,
            language: params.language ?? DEFAULT_LANGUAGE,
            tags: params.tags ?? [],
            defaults: {
              temperature: params.temperature ?? DEFAULT_TEMPERATURE,
              streaming_interval: DEFAULT_STREAMING_INTERVAL,
            },
          };

          let voice = await requestJSON<VoiceRecord>(serverUrl, "/v1/voices", "POST", body, [201]);
          if (hasError(voice) && params.overwrite !== false && params.id) {
            voice = await requestJSON<VoiceRecord>(
              serverUrl,
              `/v1/voices/${encodeURIComponent(params.id)}`,
              "PATCH",
              body,
              [200],
            );
          }
          if (hasError(voice)) throw new Error(String(voice.error));

          let audio: AudioDetails | undefined;
          let played = false;
          const shouldPreview = params.playPreview !== false || Boolean(params.previewText);
          if (shouldPreview) {
            onUpdate?.({
              content: [{ type: "text", text: `Generating preview for ${voice.id}...` }],
              details: { status: "preview" },
            });
            const previewBytes = await requestBytes(
              serverUrl,
              `/v1/voices/${encodeURIComponent(voice.id)}/preview`,
              "POST",
              {
                input: params.previewText ?? "Hello. This is a short preview of this Yuwp voice.",
                temperature: params.temperature ?? DEFAULT_TEMPERATURE,
              },
            );
            const outPath = audioOutputPath(`voice-preview-${voice.id}`);
            writeFileSync(outPath, previewBytes);
            audio = audioDetails(outPath, previewBytes, params.embedAudio !== false, {
              preview: true,
            });
            if (params.playPreview !== false) {
              await afplay(outPath);
              played = true;
            }
          }

          if (params.setDefault) {
            saveVoicePreferences(storage, { defaultVoiceId: voice.id });
          }

          const details: VoiceToolDetails = {
            serverUrl,
            voice,
            audio,
            played,
            preferences: readVoicePreferences(storage),
          };
          return {
            content: [
              {
                type: "text" as const,
                text: `Created voice ${voice.id}: ${voice.name}${params.setDefault ? "\nSaved as default voice." : ""}${audio ? `\nPreview: ${audio.path}` : ""}`,
              },
            ],
            details,
          };
        });
      },
      renderResult(result, _options, theme) {
        const details = result.details as VoiceToolDetails | undefined;
        if (!details?.voice)
          return new Text(result.content[0]?.type === "text" ? result.content[0].text : "", 0, 0);
        const lines = [
          theme.fg("success", `✓ Voice ${details.voice.id}`),
          theme.fg("muted", details.voice.name),
        ];
        if (details.voice.prompt) lines.push(theme.fg("dim", `Prompt: ${details.voice.prompt}`));
        if (details.preferences?.defaultVoiceId === details.voice.id) {
          lines.push(theme.fg("success", "Saved as default voice"));
        }
        if (details.audio) lines.push(theme.fg("dim", `Audio: ${details.audio.path}`));
        if (details.played) lines.push(theme.fg("success", "Played preview locally"));
        return new Text(lines.join("\n"), 0, 0);
      },
    });

    pi.registerTool({
      name: "voice_speak",
      label: "Speak Voice",
      description:
        "Speak text using a saved local voice ID or raw VoiceDesign prompt. Streams from Yuwp TTS, saves a WAV, optionally plays locally, and returns audio details for Oppi timeline playback.",
      promptSnippet: "Speak using a saved local Yuwp voice",
      promptGuidelines: [
        "Use voice_speak when the user asks to hear a saved voice or wants the agent to speak with a named voice.",
        `If the user asks you to speak without naming a voice, default to the saved default voice or ${DEFAULT_VOICE_ID} if none is saved.`,
        "When the user asks for a voice reply without specifying playback behavior, omit delivery so Oppi can use the current app or session default.",
        "If the user explicitly wants immediate playback, live interaction, or direct speech, set delivery to directSpeak.",
        "If the user asks to change how this session handles voice replies going forward, use voice_reply_mode instead of repeating delivery hints manually.",
        "If the user is choosing an ongoing voice reply style and the preference is genuinely unclear, use ask instead of guessing.",
        "Use voice_speak for direct spoken replies, not written mini-essays read aloud.",
        "When already speaking in a voice during the session, keep using that same voice unless the user asks to switch.",
        "For voice_speak, write for the ear: shorter sentences, simpler joins, fewer stacked clauses, and fewer abstractions.",
        "For voice_speak, prefer one concrete point at a time and avoid listy consultant phrasing unless the user explicitly wants a list.",
        "Keep attention announcements brief. For long-form/audiobook text, chunk the text into paragraphs in the app layer rather than one huge request.",
        "Never speak raw website URLs, Google Maps links, Apple Maps links, or long street addresses. Describe places by human landmarks, highway exits, relative location, and next action instead; put clickable links in non-spoken metadata or separate UI text.",
        "Avoid canned contrast formulas, hypey transitions, and over-explaining in voice_speak output; spoken replies should sound like a person talking in the moment.",
        "Prefer saved voice IDs in the voice field. Raw VoiceDesign prompts are allowed for quick one-offs.",
      ],
      parameters: Type.Object({
        text: Type.String({ description: "Text to speak. Keep short for interactive use." }),
        voice: Type.Optional(
          Type.String({
            description: `Saved voice ID, or raw VoiceDesign/custom voice string. Defaults to ${DEFAULT_VOICE_ID}.`,
          }),
        ),
        language: Type.Optional(Type.String({ description: "Language hint. Default: English." })),
        temperature: Type.Optional(
          Type.Number({ description: "Sampling temperature. Default comes from voice or 0.8." }),
        ),
        stream: Type.Optional(Type.Boolean({ description: "Use HTTP streaming. Default: true." })),
        play: Type.Optional(
          Type.Boolean({ description: "Play locally with afplay on macOS. Default: true." }),
        ),
        out: Type.Optional(Type.String({ description: "Optional output WAV path." })),
        embedAudio: Type.Optional(
          Type.Boolean({
            description:
              "Embed small WAV as base64 in tool details for Oppi timeline playback. Default: true.",
          }),
        ),
        delivery: Type.Optional(
          Type.Union([Type.Literal("voiceMessage"), Type.Literal("directSpeak")], {
            description:
              "Oppi delivery hint. voiceMessage renders a playable voice card without autoplay by default. directSpeak requests immediate client playback when allowed.",
          }),
        ),
      }),
      async execute(_toolCallId, params, _signal, onUpdate, ctx) {
        return enqueue(async () => {
          if (params.text.length > MAX_TEXT_CHARS)
            throw new Error(
              `Text too long for interactive voice_speak (${params.text.length} > ${MAX_TEXT_CHARS})`,
            );
          const voice = resolveVoiceId(params.voice, storage);
          const delivery = normalizeVoiceDelivery(params.delivery);
          const spokenText = sanitizeSpokenVoiceText(params.text);
          if (!spokenText)
            throw new Error(
              "voice_speak text has no speakable content after removing URLs/addresses",
            );
          onUpdate?.({
            content: [{ type: "text", text: spokenText }],
            details: createTTSVoicePresentationDetails({
              message: spokenText,
              delivery,
              provider: {
                ...YUWP_PROVIDER,
                model: "yuwp-tts",
                voiceId: voice,
                sourceMimeType: "audio/wav",
              },
              extra: { status: "speaking" },
            }),
          });
          const serverUrl = await ensureYuwpTTSServer();
          const outPath = params.out
            ? path.resolve(params.out)
            : audioOutputPath(`voice-speak-${safeSlug(voice)}`);
          const stream = params.stream !== false;
          const speechRequest: SpeechRequest = {
            model: "yuwp-tts",
            voice,
            input: spokenText,
            response_format: "wav",
            stream,
            language: params.language ?? DEFAULT_LANGUAGE,
            temperature: params.temperature,
            streaming_interval: DEFAULT_STREAMING_INTERVAL,
          };
          const audioStream = createTTSAudioStreamEmitter({
            ui: ctx?.ui,
            toolCallId: _toolCallId,
            delivery,
          });
          const result = stream
            ? await streamSpeechToWav(serverUrl, speechRequest, outPath, audioStream)
            : await fullSpeechToWav(serverUrl, speechRequest, outPath);
          const streamedDirectSpeakToOppi =
            params.play !== false && stream && !!audioStream && delivery === "directSpeak";
          let played = false;
          if (params.play !== false && !audioStream) {
            await afplay(outPath);
            played = true;
          }
          const bytes = readFileSync(outPath);
          const shouldEmbed = params.embedAudio !== false && !streamedDirectSpeakToOppi;
          const audio = audioDetails(outPath, bytes, shouldEmbed, result.metrics);
          if (streamedDirectSpeakToOppi) {
            played = true;
          }
          const details: VoiceSpeakToolDetails = createTTSToolVoiceDetails({
            message: spokenText,
            delivery,
            provider: {
              ...YUWP_PROVIDER,
              model: speechRequest.model,
              voiceId: voice,
              sourceMimeType: audio.mimeType,
            },
            audio,
            extra: {
              serverUrl,
              played,
              preferences: readVoicePreferences(storage),
            },
          });
          return {
            content: [{ type: "text" as const, text: spokenText }],
            details,
          };
        });
      },
      renderResult(result, _options, theme) {
        const details = result.details as VoiceSpeakToolDetails | undefined;
        if (!details?.audio)
          return new Text(result.content[0]?.type === "text" ? result.content[0].text : "", 0, 0);
        const duration = details.audio.durationSeconds
          ? ` · ${details.audio.durationSeconds.toFixed(2)}s`
          : "";
        const lines = [
          theme.fg("success", `✓ Voice message${duration}`),
          theme.fg("muted", `“${details.message ?? ""}”`),
        ];
        if (details.played) lines.push(theme.fg("success", "Played"));
        return new Text(lines.join("\n"), 0, 0);
      },
    });

    pi.registerTool({
      name: "voice_reply_mode",
      label: "Session Voice Reply Mode",
      description:
        "Set or clear the current Oppi session's default voice reply behavior so future voice replies autoplay or stay tap-to-play for this session.",
      promptSnippet: "Set the current session's default voice reply behavior",
      promptGuidelines: [
        "Use voice_reply_mode when the user asks the agent to keep speaking out loud or to stop autoplaying for the rest of this session.",
        "Use mode='autoplay' to make future voice replies speak out loud by default in this session.",
        "Use mode='manual' to make future voice replies stay tap-to-play by default in this session.",
        "Use mode='default' to clear the session override and fall back to the global app setting.",
      ],
      parameters: Type.Object({
        mode: Type.Union(
          [Type.Literal("manual"), Type.Literal("autoplay"), Type.Literal("default")],
          {
            description:
              "Session-scoped default for Oppi voice replies. manual keeps replies tap-to-play by default, autoplay speaks them out loud by default, default clears the session override.",
          },
        ),
      }),
      async execute(_toolCallId, params) {
        const mode = params.mode as SessionVoiceReplyMode;
        const message =
          mode === "autoplay"
            ? "This session will autoplay voice replies by default."
            : mode === "manual"
              ? "This session will keep voice replies tap-to-play by default."
              : "This session will follow the global voice reply setting again.";
        return {
          content: [{ type: "text" as const, text: message }],
          details: {
            kind: "voice_reply_mode",
            scope: "session",
            mode,
            message,
          },
        };
      },
    });

    pi.registerTool({
      name: "voice_preferences",
      label: "Voice Preferences",
      description:
        "Inspect or update saved voice preferences such as the default voice used by voice_speak.",
      promptSnippet: "Inspect or update saved voice preferences",
      promptGuidelines: [
        "Use voice_preferences when the user wants to set, change, or inspect the saved default voice.",
        "Default voices should point to an existing saved voice ID whenever possible.",
      ],
      parameters: Type.Object({
        defaultVoiceId: Type.Optional(
          Type.String({
            description: "Persist this saved voice ID as the default for future voice_speak calls.",
          }),
        ),
      }),
      async execute(_toolCallId, params) {
        const serverUrl = await ensureYuwpTTSServer();
        if (params.defaultVoiceId) {
          const voiceId = params.defaultVoiceId.trim();
          if (!voiceId) {
            throw new Error("defaultVoiceId cannot be empty");
          }
          await assertSavedVoiceExists(serverUrl, voiceId);
          saveVoicePreferences(storage, { defaultVoiceId: voiceId });
        }
        const preferences = readVoicePreferences(storage);
        const activeDefault = preferences.defaultVoiceId ?? DEFAULT_VOICE_ID;
        return {
          content: [
            {
              type: "text" as const,
              text: `Default voice: ${activeDefault}${preferences.defaultVoiceId ? "" : " (fallback)"}`,
            },
          ],
          details: {
            serverUrl,
            preferences,
          } satisfies VoiceToolDetails,
        };
      },
    });

    pi.registerTool({
      name: "voice_list",
      label: "List Voices",
      description: "List saved local Yuwp voices available for voice_speak.",
      parameters: Type.Object({}),
      async execute() {
        const serverUrl = await ensureYuwpTTSServer();
        const response = await requestJSON<{ data: VoiceRecord[] }>(serverUrl, "/v1/voices", "GET");
        const voices = response.data ?? [];
        const preferences = readVoicePreferences(storage);
        const defaultVoiceId = preferences.defaultVoiceId ?? DEFAULT_VOICE_ID;
        return {
          content: [
            {
              type: "text" as const,
              text: voices.length
                ? voices
                    .map((v) => `${v.id}: ${v.name}${v.id === defaultVoiceId ? " (default)" : ""}`)
                    .join("\n")
                : "No saved voices.",
            },
          ],
          details: { serverUrl, voices, preferences } satisfies VoiceToolDetails,
        };
      },
    });

    pi.registerCommand("voice", {
      description:
        "Create/list/speak local Yuwp voices. Usage: /voice list | /voice default [voice-id] | /voice speak <voice-id> <text>",
      handler: async (args, ctx) => {
        const trimmed = args.trim();
        if (!trimmed || trimmed === "help") {
          ctx.ui.notify(
            "Usage: /voice list | /voice default [voice-id] | /voice speak <voice-id> <text>",
            "info",
          );
          return;
        }
        const [cmd, ...rest] = trimmed.split(/\s+/);
        if (cmd === "list") {
          const serverUrl = await ensureYuwpTTSServer();
          const response = await requestJSON<{ data: VoiceRecord[] }>(
            serverUrl,
            "/v1/voices",
            "GET",
          );
          const defaultVoiceId = readVoicePreferences(storage).defaultVoiceId ?? DEFAULT_VOICE_ID;
          ctx.ui.notify(
            (response.data ?? [])
              .map((v) => `${v.id}: ${v.name}${v.id === defaultVoiceId ? " (default)" : ""}`)
              .join("\n") || "No saved voices",
            "info",
          );
          return;
        }
        if (cmd === "default") {
          const requestedVoiceId = rest.join(" ").trim();
          if (!requestedVoiceId) {
            const defaultVoiceId = readVoicePreferences(storage).defaultVoiceId ?? DEFAULT_VOICE_ID;
            ctx.ui.notify(`Default voice: ${defaultVoiceId}`, "info");
            return;
          }
          const serverUrl = await ensureYuwpTTSServer();
          await assertSavedVoiceExists(serverUrl, requestedVoiceId);
          saveVoicePreferences(storage, { defaultVoiceId: requestedVoiceId });
          ctx.ui.notify(`Saved default voice: ${requestedVoiceId}`, "info");
          return;
        }
        if (cmd === "speak") {
          const voiceArg = rest.shift();
          const text = rest.join(" ");
          const voice = resolveVoiceId(voiceArg, storage);
          if (!text) {
            ctx.ui.notify("Usage: /voice speak <voice-id> <text>", "warning");
            return;
          }
          const serverUrl = await ensureYuwpTTSServer();
          const outPath = audioOutputPath(`voice-command-${safeSlug(voice)}`);
          await streamSpeechToWav(
            serverUrl,
            { model: "yuwp-tts", voice, input: text, response_format: "wav", stream: true },
            outPath,
          );
          await afplay(outPath);
          ctx.ui.notify(`Spoke with ${voice}: ${outPath}`, "info");
          return;
        }
        ctx.ui.notify("Unknown /voice command", "warning");
      },
    });
  };
}

async function enqueue<T>(fn: () => Promise<T>): Promise<T> {
  const run = speechQueue.then(fn, fn);
  speechQueue = run.catch(() => undefined);
  return run;
}

async function ensureYuwpTTSServer(): Promise<string> {
  const serverUrl = process.env.PI_VOICE_TTS_URL ?? process.env.YUWP_TTS_URL ?? DEFAULT_TTS_URL;
  assertLocalURL(serverUrl);
  if (await serverReady(serverUrl)) return serverUrl;
  await startServer(serverUrl);
  const start = Date.now();
  while (Date.now() - start < SERVER_START_TIMEOUT_MS) {
    if (await serverReady(serverUrl)) return serverUrl;
    await sleep(250);
  }
  throw new Error(`Yuwp TTS server did not become ready at ${serverUrl}`);
}

function resolveVoiceId(voice: string | undefined, storage?: Storage): string {
  const trimmed = typeof voice === "string" ? voice.trim() : "";
  return trimmed || resolveConfiguredDefaultVoiceId(storage);
}

export function normalizeVoiceDelivery(value: unknown): VoiceDeliveryMode | undefined {
  return value === "voiceMessage" || value === "directSpeak" ? value : undefined;
}

export function readVoicePreferences(storage?: Storage): VoicePreferencesRecord {
  const defaultVoiceId = storage?.getConfig().extensions?.voice?.defaultVoiceId?.trim();
  return defaultVoiceId ? { defaultVoiceId } : {};
}

export function saveVoicePreferences(
  storage: Storage | undefined,
  update: VoicePreferencesRecord,
): VoicePreferencesRecord {
  const next: VoicePreferencesRecord = {
    ...readVoicePreferences(storage),
    ...update,
    updatedAt: new Date().toISOString(),
  };

  if (storage) {
    const current = storage.getConfig();
    storage.updateConfig({
      extensions: {
        ...(current.extensions ?? {}),
        voice: next.defaultVoiceId ? { defaultVoiceId: next.defaultVoiceId } : undefined,
      },
    });
  }

  return next;
}

export function resolveConfiguredDefaultVoiceId(storage?: Storage): string {
  return readVoicePreferences(storage).defaultVoiceId?.trim() || DEFAULT_VOICE_ID;
}

async function assertSavedVoiceExists(serverUrl: string, voiceId: string): Promise<void> {
  const response = await requestJSON<{ data: VoiceRecord[] }>(serverUrl, "/v1/voices", "GET");
  const voices = response.data ?? [];
  if (!voices.some((voice) => voice.id === voiceId)) {
    throw new Error(`Saved voice not found: ${voiceId}`);
  }
}

function assertLocalURL(raw: string): void {
  if (process.env.PI_VOICE_ALLOW_REMOTE === "1") return;
  const url = new URL(raw);
  if (!["127.0.0.1", "localhost", "::1"].includes(url.hostname)) {
    throw new Error(`Refusing non-local Yuwp TTS URL without PI_VOICE_ALLOW_REMOTE=1: ${raw}`);
  }
}

async function serverReady(serverUrl: string): Promise<boolean> {
  try {
    const response = await fetch(new URL("/v1/info", serverUrl), {
      signal: AbortSignal.timeout(1_000),
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function startServer(serverUrl: string): Promise<void> {
  if (serverProcess) return;
  const binary = process.env.PI_VOICE_TTS_BIN ?? findYuwpTTSBinary();
  const model = process.env.PI_VOICE_MODEL ?? process.env.PI_SPEECH_MODEL ?? findModelPath();
  if (!binary)
    throw new Error("Could not find yuwp-tts binary. Build Yuwp TTS or set PI_VOICE_TTS_BIN.");
  if (!model)
    throw new Error("Could not find Qwen3-TTS model. Set PI_VOICE_MODEL to a local snapshot path.");
  const url = new URL(serverUrl);
  const port = url.port || "7937";
  const host = url.hostname === "localhost" ? "127.0.0.1" : url.hostname;
  const logs = path.join(os.tmpdir(), "pi-voice-yuwp-tts.log");
  serverProcess = spawn(
    binary,
    [
      "serve",
      "--transport",
      "http",
      "--host",
      host,
      "--port",
      port,
      "--model",
      model,
      "--language",
      DEFAULT_LANGUAGE,
      "--temperature",
      String(DEFAULT_TEMPERATURE),
      "--streaming-interval",
      String(DEFAULT_STREAMING_INTERVAL),
    ],
    {
      detached: true,
      stdio: ["ignore", "ignore", "ignore"],
    },
  );
  serverProcess.unref();
  writeFileSync(
    logs,
    `Started ${binary} at ${new Date().toISOString()}\nmodel=${model}\nurl=${serverUrl}\n`,
    { flag: "a" },
  );
}

function findYuwpTTSBinary(): string | undefined {
  const home = os.homedir();
  const candidates = [
    path.join(home, "workspace/yuwp/.build/arm64-apple-macosx/release/yuwp-tts"),
    path.join(home, "workspace/yuwp/.build/debug/yuwp-tts"),
    path.join(
      home,
      "workspace/yuwp-autoresearch/tts-correctness-streaming-20260424/.build/arm64-apple-macosx/release/yuwp-tts",
    ),
    path.join(
      home,
      "workspace/yuwp-autoresearch/tts-correctness-streaming-20260424/.build/debug/yuwp-tts",
    ),
  ];
  return candidates.find((candidate) => existsSync(candidate));
}

function findModelPath(): string | undefined {
  const hub = path.join(os.homedir(), ".cache/huggingface/hub");
  for (const repo of VOICE_DESIGN_REPOS) {
    const snapshots = path.join(hub, repo, "snapshots");
    if (!existsSync(snapshots)) continue;
    const entries = readDirSafe(snapshots)
      .map((name) => path.join(snapshots, name))
      .filter((entry) => existsSync(path.join(entry, "config.json")))
      .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
    if (entries[0]) return entries[0];
  }
  return undefined;
}

function readDirSafe(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

async function requestJSON<T>(
  serverUrl: string,
  route: string,
  method: string,
  body?: unknown,
  okStatuses = [200],
): Promise<T> {
  const response = await fetch(new URL(route, serverUrl), {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json: unknown = {};
  try {
    json = text ? (JSON.parse(text) as unknown) : {};
  } catch {
    json = { error: text };
  }
  if (!okStatuses.includes(response.status)) {
    return json as T;
  }
  return json as T;
}

async function requestBytes(
  serverUrl: string,
  route: string,
  method: string,
  body: unknown,
): Promise<Buffer> {
  const response = await fetch(new URL(route, serverUrl), {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(await response.text());
  return Buffer.from(await response.arrayBuffer());
}

async function fullSpeechToWav(
  serverUrl: string,
  body: SpeechRequest,
  outPath: string,
): Promise<SpeechResult> {
  const bytes = await requestBytes(serverUrl, "/v1/audio/speech", "POST", body);
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, bytes);
  return { metrics: { stream: false } };
}

async function streamSpeechToWav(
  serverUrl: string,
  body: SpeechRequest,
  outPath: string,
  onAudioStream?: (event: Omit<TTSAudioStreamEvent, "id" | "delivery">) => void,
): Promise<SpeechResult> {
  const response = await fetch(new URL("/v1/audio/speech/stream", serverUrl), {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/x-ndjson" },
    body: JSON.stringify(body),
  });
  if (!response.ok || !response.body) throw new Error(await response.text());
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  let sampleRate = 24000;
  let channels = 1;
  const chunks: Buffer[] = [];
  let done: Record<string, unknown> = {};
  while (true) {
    const { done: complete, value } = await reader.read();
    if (complete) break;
    pending += decoder.decode(value, { stream: true });
    let newline: number;
    while ((newline = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, newline).trim();
      pending = pending.slice(newline + 1);
      if (!line) continue;
      const event = JSON.parse(line) as YuwpStreamEvent;
      if (event.event === "metadata") {
        sampleRate = event.sample_rate ?? sampleRate;
        channels = event.channels ?? channels;
        onAudioStream?.({
          kind: "audio-stream",
          event: "metadata",
          mimeType: "audio/pcm; codecs=s16le",
          sampleRate,
          channels,
        });
      } else if (event.event === "audio") {
        if (!event.audio) continue;
        chunks.push(Buffer.from(event.audio, "base64"));
        onAudioStream?.({
          kind: "audio-stream",
          event: "chunk",
          mimeType: "audio/pcm; codecs=s16le",
          sampleRate,
          channels,
          chunkIndex: event.chunk,
          audioBase64: event.audio,
          durationSeconds: event.seconds,
        });
      } else if (event.event === "done") {
        done = event;
        onAudioStream?.({
          kind: "audio-stream",
          event: "done",
          mimeType: "audio/pcm; codecs=s16le",
          sampleRate,
          channels,
          durationSeconds: event.audio_duration_seconds,
          metrics: event,
        });
      } else if (event.event === "error") {
        onAudioStream?.({
          kind: "audio-stream",
          event: "error",
          mimeType: "audio/pcm; codecs=s16le",
          sampleRate,
          channels,
          text: event.error ?? "TTS stream error",
        });
        throw new Error(event.error ?? "TTS stream error");
      }
    }
  }
  const pcm = Buffer.concat(chunks);
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, wavFromPCM16(pcm, sampleRate, channels));
  return { metrics: { stream: true, ...done } };
}

function wavFromPCM16(pcm: Buffer, sampleRate: number, channels: number): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * channels * 2, 28);
  header.writeUInt16LE(channels * 2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

function audioDetails(
  outPath: string,
  bytes: Buffer,
  embed: boolean,
  metrics?: Record<string, unknown>,
): AudioDetails {
  const detail: AudioDetails = {
    kind: "audio",
    mimeType: "audio/wav",
    path: outPath,
    fileName: path.basename(outPath),
    sizeBytes: bytes.length,
    durationSeconds:
      typeof metrics?.audio_duration_seconds === "number"
        ? metrics.audio_duration_seconds
        : undefined,
    stream: Boolean(metrics?.stream),
    metrics,
  };
  if (embed && bytes.length <= MAX_EMBED_AUDIO_BYTES) detail.base64 = bytes.toString("base64");
  return detail;
}

function audioOutputPath(prefix: string): string {
  const dir = path.join(os.homedir(), "Library/Application Support/Yuwp/Audio/pi-voice");
  mkdirSync(dir, { recursive: true });
  return path.join(dir, `${prefix}-${Date.now()}.wav`);
}

async function afplay(file: string): Promise<void> {
  if (process.platform !== "darwin") return;
  await new Promise<void>((resolve, reject) => {
    const child = spawn("afplay", [file], { stdio: "ignore" });
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`afplay exited ${code}`)),
    );
    child.on("error", reject);
  });
}

function safeSlug(raw: string): string {
  return (
    raw
      .toLowerCase()
      .replace(/[^a-z0-9_-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 64) || "voice"
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

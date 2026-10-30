import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";

import { VoiceCallController } from "../src/continuous-voice-call.js";
import {
  TranscriptionVoiceMediaAdapter,
  VoiceCallMediaCoordinator,
} from "../src/continuous-voice-media.js";
import {
  OPENROUTER_LIVE_VOICE_STT_MODEL,
  OPENROUTER_LIVE_VOICE_TTS_MODEL,
  OPENROUTER_LIVE_VOICE_TTS_VOICE,
  OpenRouterLiveTranscription,
  OpenRouterLiveVoiceTts,
} from "../src/openrouter-live-voice.js";
import { SttSessionCreateError } from "../src/stt-provider.js";
import { waitForCondition } from "./harness/async.js";
import { DeterministicVoiceCallFrontend } from "./helpers/deterministic-voice-call-frontend.js";

const SILENCE_MS = 300;
const API_KEY = "sk-or-test";

interface Recorded {
  path: string;
  authorization: string | undefined;
  /** Transcription requests carry `input_audio`; speech requests the rest. */
  body: {
    model?: string;
    input_audio?: { data: string; format: string };
    [key: string]: unknown;
  };
}

type Reply = (req: Recorded, res: ServerResponse) => void | Promise<void>;

const servers = new Set<Server>();
afterEach(async () => {
  for (const server of servers) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
  servers.clear();
});

/** Plays OpenRouter's `/api/v1/audio/*` on 127.0.0.1 and records every request. */
async function fakeOpenRouter(routes: { transcribe?: Reply; speech?: Reply }) {
  const requests: Recorded[] = [];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      const recorded: Recorded = {
        path: req.url ?? "",
        authorization: req.headers.authorization,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
      };
      requests.push(recorded);
      const route =
        recorded.path === "/api/v1/audio/transcriptions"
          ? routes.transcribe
          : recorded.path === "/api/v1/audio/speech"
            ? routes.speech
            : undefined;
      if (!route) {
        res.writeHead(404).end();
        return;
      }
      void route(recorded, res);
    });
  });
  servers.add(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  return { baseUrl: `http://127.0.0.1:${port}/api/v1`, requests };
}

/** `ms` of 16 kHz mono PCM: a loud tone (speech to the detector) or digital silence. */
function pcm(ms: number, amplitude = 0): Buffer {
  const samples = (16_000 * ms) / 1_000;
  const out = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) {
    out.writeInt16LE(Math.round(amplitude * Math.sin((2 * Math.PI * 220 * i) / 16_000)), i * 2);
  }
  return out;
}
const speech = (ms: number) => pcm(ms, 8_000);
const silence = (ms: number) => pcm(ms);

/** Feeds audio the way the phone does: small frames whose sizes do not line up with 20 ms. */
function feed(target: { feedAudio(pcm: Buffer): void }, audio: Buffer): void {
  for (let offset = 0; offset < audio.length; offset += 1_234) {
    target.feedAudio(audio.subarray(offset, offset + 1_234));
  }
}

function wav(body: Recorded["body"]): Buffer {
  return Buffer.from(body.input_audio?.data ?? "", "base64");
}

function wavPcm(body: Recorded["body"]): Buffer {
  return wav(body).subarray(44);
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(body));
}

/** A whole call: phone frontend, controller, coordinator, and the OpenRouter adapter. */
async function call(baseUrl: string, apiKey: string | undefined = API_KEY) {
  const dispatched: string[] = [];
  const calls = new VoiceCallController({
    nextCallId: () => "call-1",
    leaseDurationMs: 30_000,
    dispatchDelegation: (_sessionId, delegation) => dispatched.push(delegation.request),
  });
  const resolveApiKey = async () => apiKey;
  const coordinator = new VoiceCallMediaCoordinator({
    calls,
    createAdapter: ({ callId }) =>
      new TranscriptionVoiceMediaAdapter(
        new OpenRouterLiveTranscription({ baseUrl, resolveApiKey, silenceDurationMs: SILENCE_MS }),
        { tts: new OpenRouterLiveVoiceTts({ baseUrl, resolveApiKey }), callId },
      ),
  });
  const frontend = new DeterministicVoiceCallFrontend({
    connectionId: "connection-1",
    authenticatedDeviceId: "paired-iphone",
  });
  const started = calls.startCall(
    { controlSessionId: "voice-1", clientCallId: "client-1" },
    frontend.connection,
  );
  const attach = () =>
    coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
  return {
    attach,
    dispatched,
    frontend,
    coordinator,
    callId: started.state.callId,
    say: (audio: Buffer) =>
      feed({ feedAudio: (b) => coordinator.feedAudio("connection-1", b) }, audio),
  };
}

describe("OpenRouter Live Voice", () => {
  it("sends each paused utterance to OpenRouter and the agent, and speaks the reply", async () => {
    const replyPcm = Buffer.from(Array.from({ length: 4_801 }, (_, i) => i % 256));
    const api = await fakeOpenRouter({
      transcribe: (_req, res) => json(res, 200, { text: " Run the tests. ", usage: {} }),
      speech: (_req, res) => {
        res.writeHead(200, { "Content-Type": "audio/pcm" });
        // Odd-sized chunks split samples; playback must still get whole samples, in order.
        res.write(replyPcm.subarray(0, 1_001));
        setTimeout(() => res.end(replyPcm.subarray(1_001)), 10);
      },
    });
    const c = await call(api.baseUrl);
    await c.attach();

    c.say(Buffer.concat([silence(500), speech(1_000), silence(SILENCE_MS + 100)]));
    await waitForCondition(() => c.dispatched.length === 1, { description: "turn dispatched" });

    expect(c.dispatched).toEqual(["Run the tests."]);
    const [stt] = api.requests;
    expect(stt.path).toBe("/api/v1/audio/transcriptions");
    expect(stt.authorization).toBe(`Bearer ${API_KEY}`);
    expect(stt.body.model).toBe(OPENROUTER_LIVE_VOICE_STT_MODEL);
    expect(stt.body.input_audio?.format).toBe("wav");
    expect(wav(stt.body).subarray(0, 4).toString("ascii")).toBe("RIFF");
    expect(wav(stt.body).readUInt32LE(24)).toBe(16_000);
    // The speech plus pre-roll and a short tail, not the closing pause or the silence before.
    const uploadedMs = wavPcm(stt.body).length / 32;
    expect(uploadedMs).toBeGreaterThanOrEqual(1_000);
    expect(uploadedMs).toBeLessThan(1_000 + 400 + SILENCE_MS);

    await c.coordinator.speak(c.callId, "All 12 tests pass.");
    const tts = api.requests[1];
    expect(tts.path).toBe("/api/v1/audio/speech");
    expect(tts.authorization).toBe(`Bearer ${API_KEY}`);
    expect(tts.body).toEqual({
      model: OPENROUTER_LIVE_VOICE_TTS_MODEL,
      voice: OPENROUTER_LIVE_VOICE_TTS_VOICE,
      input: "All 12 tests pass.",
      response_format: "pcm",
    });
    expect(c.frontend.audio.every((chunk) => chunk.length % 2 === 0)).toBe(true);
    expect(Buffer.concat(c.frontend.audio)).toEqual(replyPcm.subarray(0, 4_800));
  });

  it("ignores clicks and quiet noise, and keeps one turn through a pause shorter than the cut", async () => {
    const api = await fakeOpenRouter({
      transcribe: (_req, res) => json(res, 200, { text: "one turn" }),
    });
    const c = await call(api.baseUrl);
    await c.attach();

    c.say(Buffer.concat([speech(100), silence(500), pcm(500, 40), silence(500)]));
    c.say(Buffer.concat([speech(600), silence(SILENCE_MS - 100), speech(600)]));
    c.say(silence(SILENCE_MS + 100));
    await waitForCondition(() => c.dispatched.length === 1, { description: "turn dispatched" });

    expect(api.requests).toHaveLength(1);
    expect(wavPcm(api.requests[0].body).length / 32).toBeGreaterThanOrEqual(1_400);
    expect(c.dispatched).toEqual(["one turn"]);
  });

  it("hands turns over in the order spoken when an earlier transcription is slower", async () => {
    let request = 0;
    const api = await fakeOpenRouter({
      transcribe: (_req, res) => {
        request += 1;
        const text = request === 1 ? "first" : "second";
        setTimeout(() => json(res, 200, { text }), request === 1 ? 150 : 0);
      },
    });
    const c = await call(api.baseUrl);
    await c.attach();

    c.say(Buffer.concat([speech(400), silence(SILENCE_MS + 50)]));
    c.say(Buffer.concat([speech(400), silence(SILENCE_MS + 50)]));
    await waitForCondition(() => c.dispatched.length === 2, { description: "both turns" });

    expect(c.dispatched).toEqual(["first", "second"]);
  });

  it("keeps the call going past a failed transcription and sends nothing for it", async () => {
    let request = 0;
    const api = await fakeOpenRouter({
      transcribe: (_req, res) => {
        request += 1;
        if (request === 1)
          json(res, 502, { error: { code: 502, message: "Provider returned error" } });
        else json(res, 200, { text: "try again" });
      },
    });
    const c = await call(api.baseUrl);
    await c.attach();

    c.say(Buffer.concat([speech(400), silence(SILENCE_MS + 50)]));
    await waitForCondition(() => api.requests.length === 1, { description: "first upload" });
    c.say(Buffer.concat([speech(400), silence(SILENCE_MS + 50)]));
    await waitForCondition(() => c.dispatched.length === 1, { description: "second turn" });

    expect(c.dispatched).toEqual(["try again"]);
  });

  it("sends what the caller was still saying when the call ends", async () => {
    const api = await fakeOpenRouter({
      transcribe: (_req, res) => setTimeout(() => json(res, 200, { text: "last words" }), 50),
    });
    const c = await call(api.baseUrl);
    await c.attach();

    c.say(speech(600));
    await c.coordinator.detach("connection-1");

    expect(api.requests).toHaveLength(1);
    expect(c.dispatched).toEqual(["last words"]);
  });

  it("cuts an utterance whose audio stops mid-speech (mute, hold)", async () => {
    const api = await fakeOpenRouter({
      transcribe: (_req, res) => json(res, 200, { text: "before mute" }),
    });
    const c = await call(api.baseUrl);
    await c.attach();

    c.say(speech(600));
    await waitForCondition(() => c.dispatched.length === 1, {
      timeoutMs: SILENCE_MS * 5,
      description: "stalled turn",
    });

    expect(c.dispatched).toEqual(["before mute"]);
  });

  it("refuses to start without an OpenRouter credential", async () => {
    const transcription = new OpenRouterLiveTranscription({
      baseUrl: "http://127.0.0.1:1/api/v1",
      resolveApiKey: async () => undefined,
      silenceDurationMs: SILENCE_MS,
    });
    const events = { speechStarted() {}, partial() {}, turn() {}, closed() {} };

    await expect(transcription.start(events)).rejects.toMatchObject({
      constructor: SttSessionCreateError,
      category: "auth",
    });
  });

  it("reports OpenRouter's reason when speech fails", async () => {
    const api = await fakeOpenRouter({
      speech: (_req, res) =>
        json(res, 402, { error: { code: 402, message: "Insufficient credits" } }),
    });
    const tts = new OpenRouterLiveVoiceTts({
      baseUrl: api.baseUrl,
      resolveApiKey: async () => API_KEY,
    });

    const chunks = tts.speak("hello", new AbortController().signal)[Symbol.asyncIterator]();
    await expect(chunks.next()).rejects.toThrow("HTTP 402: Insufficient credits");
  });
});

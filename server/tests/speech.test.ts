import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSpeechRoutes } from "../src/routes/speech.js";
import type { RouteContext } from "../src/routes/types.js";
import {
  decodeWavToPcm16,
  speakableText,
  speechPassages,
  type SpeechBackendObserver,
  type TtsConfig,
} from "../src/speech-synthesis.js";

const servers: Server[] = [];

afterEach(async () => {
  await Promise.all(
    servers
      .splice(0)
      .map((server) => new Promise<void>((resolve) => server.close(() => resolve()))),
  );
});

async function listen(
  handler: (req: IncomingMessage, res: ServerResponse) => void,
): Promise<string> {
  const server = createServer(handler);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
}

/** Float32 mono WAV with a JUNK chunk before fmt, the way Yuwp writes it. */
function float32Wav(samples: number[], sampleRate = 44_100): Buffer {
  const junk = Buffer.alloc(8 + 28);
  junk.write("JUNK", 0);
  junk.writeUInt32LE(28, 4);
  const fmt = Buffer.alloc(8 + 16);
  fmt.write("fmt ", 0);
  fmt.writeUInt32LE(16, 4);
  fmt.writeUInt16LE(3, 8);
  fmt.writeUInt16LE(1, 10);
  fmt.writeUInt32LE(sampleRate, 12);
  fmt.writeUInt32LE(sampleRate * 4, 16);
  fmt.writeUInt16LE(4, 20);
  fmt.writeUInt16LE(32, 22);
  const data = Buffer.alloc(8 + samples.length * 4);
  data.write("data", 0);
  data.writeUInt32LE(samples.length * 4, 4);
  samples.forEach((sample, index) => data.writeFloatLE(sample, 8 + index * 4));
  const header = Buffer.alloc(12);
  header.write("RIFF", 0);
  header.writeUInt32LE(4 + junk.length + fmt.length + data.length, 4);
  header.write("WAVE", 8);
  return Buffer.concat([header, junk, fmt, data]);
}

function pcm16(values: number[]): Buffer {
  const out = Buffer.alloc(values.length * 2);
  values.forEach((value, index) => out.writeInt16LE(value, index * 2));
  return out;
}

async function speechServer(
  tts: TtsConfig | undefined,
  xaiKey?: string,
  observer?: SpeechBackendObserver,
): Promise<string> {
  const ctx = {
    storage: { getConfig: () => ({ tts }) },
    getProviderAuth: async () => (xaiKey ? { auth: { apiKey: xaiKey } } : undefined),
    voiceBackendHealth: observer,
  } as unknown as RouteContext;
  const route = createSpeechRoutes(ctx, createRouteHelpers());
  return listen((req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    void route({ method: req.method ?? "GET", path: url.pathname, url, req, res }).then(
      (handled) => {
        if (!handled) {
          res.writeHead(404);
          res.end();
        }
      },
    );
  });
}

describe("read-aloud text", () => {
  it("speaks prose, link labels, and list items, but not code, images, or URLs", () => {
    const markdown = [
      "## Result",
      "",
      "See [the docs](https://example.com/docs) and [[server/src/speech-synthesis.ts|the module]].",
      "",
      "```ts",
      "const secret = 1;",
      "```",
      "",
      "![chart](chart.png)",
      "- **First** item",
      "- Second `item`",
      "",
      "Raw link: https://example.com/x",
    ].join("\n");

    const text = speakableText(markdown);
    expect(text).not.toMatch(/secret|chart|https?:|\*\*|`|#/);
    expect(speechPassages(text).join(" ")).toBe(
      "Result. See the docs and the module. First item. Second item. Raw link:",
    );
  });

  it("skips display math and code without swallowing the prose between them", () => {
    const markdown = [
      "Before.",
      "$$a+b$$",
      "Middle.",
      "$$",
      "x^2",
      "$$",
      "Then.",
      "````md",
      "```",
      "inner",
      "````",
      "After.",
      "```",
      "unclosed code runs to the end",
    ].join("\n");
    expect(speakableText(markdown)).toBe("Before.\nMiddle.\nThen.\nAfter.");
  });

  it("reads `$$` that the chat shows as text, like shell PIDs and unclosed math", () => {
    expect(speakableText("Use `echo $$` to print the PID.\nThen restart the server.")).toBe(
      "Use echo $$ to print the PID.\nThen restart the server.",
    );
    expect(speakableText("Price tiers: $, $$, $$$.\nDone.")).toBe(
      "Price tiers: $, $$, $$$.\nDone.",
    );
    expect(speakableText("Intro.\n$$\nNever closed.")).toBe("Intro.\nNever closed.");
  });

  it("does not read table separators, including one-dash cells", () => {
    expect(speakableText("| a | b |\n|:-|--:|\n| 1 | 2 |\n\nx | y\n--- | ---")).toBe(
      "a, b\n1, 2\nx | y",
    );
  });

  it("starts with a short passage and never splits a sentence", () => {
    const sentence = "This sentence is about forty characters.";
    const passages = speechPassages(Array.from({ length: 60 }, () => sentence).join(" "));

    expect(passages.length).toBeGreaterThan(2);
    expect(passages[0]!.length).toBeLessThanOrEqual(120);
    expect(passages[1]!.length).toBeGreaterThan(120);
    for (const passage of passages) {
      expect(passage.startsWith("This")).toBe(true);
      expect(passage.endsWith("characters.")).toBe(true);
    }
  });
});

describe("WAV decoding", () => {
  it("converts float WAV with extra chunks to 16-bit PCM and clamps overs", () => {
    const audio = decodeWavToPcm16(float32Wav([0, 0.5, -1, 2]));
    expect(audio).toMatchObject({ sampleRate: 44_100, channels: 1 });
    expect(audio.pcm).toEqual(pcm16([0, 16384, -32767, 32767]));
  });
});

describe("POST /speech", () => {
  it("streams every passage from an OpenAI-compatible backend in order", async () => {
    const requests: Record<string, unknown>[] = [];
    const backend = await listen(async (req, res) => {
      const body = await readJson(req);
      requests.push({ path: req.url, ...body });
      res.writeHead(200, { "Content-Type": "audio/wav" });
      res.end(float32Wav([requests.length / 10]));
    });
    const server = await speechServer({ endpoint: backend, model: "drama3", voice: "elena" });
    const text = [
      "First paragraph is short.",
      "",
      `${"A longer second passage keeps going. ".repeat(10)}`,
    ].join("\n");

    const response = await fetch(`${server}/speech`, {
      method: "POST",
      body: JSON.stringify({ text }),
    });
    const body = Buffer.from(await response.arrayBuffer());

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("audio/pcm; codecs=s16le");
    expect(response.headers.get("x-oppi-sample-rate")).toBe("44100");
    expect(response.headers.get("x-oppi-channels")).toBe("1");
    expect(requests.length).toBeGreaterThan(1);
    expect(requests[0]).toMatchObject({
      path: "/v1/audio/speech",
      model: "drama3",
      voice: "elena",
      response_format: "wav",
      input: expect.stringContaining("First paragraph is short."),
    });
    expect(body).toEqual(
      Buffer.concat(
        requests.map((_, index) => decodeWavToPcm16(float32Wav([(index + 1) / 10])).pcm),
      ),
    );
  });

  it("plays Yuwp audio as it streams, before the passage finishes synthesizing", async () => {
    const requests: Record<string, unknown>[] = [];
    let finishSynthesis!: () => void;
    const synthesisFinished = new Promise<void>((resolve) => (finishSynthesis = resolve));
    const line = (event: Record<string, unknown>): string => `${JSON.stringify(event)}\n`;
    const backend = await listen(async (req, res) => {
      requests.push(await readJson(req));
      res.writeHead(200, { "Content-Type": "application/x-ndjson" });
      res.write(
        line({
          event: "metadata",
          format: "pcm_s16le",
          sample_rate: 24_000,
          channels: 1,
          encoding: "base64",
        }),
      );
      res.write(line({ event: "audio", audio: pcm16([1, 2]).toString("base64") }));
      await synthesisFinished;
      res.write(line({ event: "audio", audio: pcm16([3]).toString("base64") }));
      res.end(line({ event: "done" }));
    });
    const server = await speechServer({ provider: "yuwp", endpoint: backend, voice: "elena" });

    const response = await fetch(`${server}/speech`, {
      method: "POST",
      body: JSON.stringify({ text: "Hello there." }),
    });
    const reader = response.body!.getReader();
    const opening = await reader.read();
    finishSynthesis();
    const chunks = [Buffer.from(opening.value!)];
    for (let next = await reader.read(); !next.done; next = await reader.read()) {
      chunks.push(Buffer.from(next.value));
    }

    expect(response.status).toBe(200);
    expect(response.headers.get("x-oppi-sample-rate")).toBe("24000");
    expect(Buffer.from(opening.value!)).toEqual(pcm16([1, 2]));
    expect(Buffer.concat(chunks)).toEqual(pcm16([1, 2, 3]));
    expect(requests).toEqual([{ input: "Hello there.", voice: "elena", stream: true }]);
  });

  it("cuts a failed Yuwp stream short and keeps the spoken text out of health", async () => {
    let failSynthesis!: () => void;
    const synthesisFailed = new Promise<void>((resolve) => (failSynthesis = resolve));
    const backend = await listen(async (req, res) => {
      await readJson(req);
      res.writeHead(200, { "Content-Type": "application/x-ndjson" });
      res.write(
        `${JSON.stringify({ event: "metadata", format: "pcm_s16le", sample_rate: 24_000, channels: 1, encoding: "base64" })}\n`,
      );
      res.write(`${JSON.stringify({ event: "audio", audio: pcm16([1]).toString("base64") })}\n`);
      await synthesisFailed;
      res.end(`${JSON.stringify({ event: "error", error: "could not voice: Hello there." })}\n`);
    });
    const failures: string[] = [];
    const server = await speechServer({ provider: "yuwp", endpoint: backend }, undefined, {
      requestSucceeded: () => failures.push("succeeded"),
      requestFailed: (_endpoint, message) => failures.push(message),
      connectFailed: () => failures.push("unreachable"),
    });

    const response = await fetch(`${server}/speech`, {
      method: "POST",
      body: JSON.stringify({ text: "Hello there." }),
    });

    const reader = response.body!.getReader();
    const opening = await reader.read();
    failSynthesis();

    expect(response.status).toBe(200);
    expect(Buffer.from(opening.value!)).toEqual(pcm16([1]));
    await expect(
      (async () => {
        while (!(await reader.read()).done);
      })(),
    ).rejects.toThrow();
    // Health is shown on About This Server; the backend's error can echo what was read.
    expect(failures).toEqual(["TTS backend could not synthesize"]);
  });

  it("reads with Grok voice using provider credentials", async () => {
    let seen: { auth?: string; body?: Record<string, unknown> } = {};
    const xai = await listen(async (req, res) => {
      seen = { auth: req.headers.authorization, body: await readJson(req) };
      res.writeHead(200, { "Content-Type": "audio/pcm" });
      res.end(pcm16([1, -2, 3]));
    });
    const server = await speechServer({ provider: "xai", endpoint: xai, voice: "eve" }, "xai-key");

    const response = await fetch(`${server}/speech`, {
      method: "POST",
      body: JSON.stringify({ text: "Hello there." }),
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("x-oppi-sample-rate")).toBe("24000");
    expect(Buffer.from(await response.arrayBuffer())).toEqual(pcm16([1, -2, 3]));
    expect(seen.auth).toBe("Bearer xai-key");
    expect(seen.body).toEqual({
      text: "Hello there.",
      voice_id: "eve",
      language: "auto",
      output_format: { codec: "pcm", sample_rate: 24000 },
    });
  });

  it("reads a reply whose code blocks alone exceed the length cap", async () => {
    const spoken: string[] = [];
    const xai = await listen(async (req, res) => {
      spoken.push(String((await readJson(req)).text));
      res.writeHead(200, { "Content-Type": "audio/pcm" });
      res.end(pcm16([7]));
    });
    const server = await speechServer({ provider: "xai", endpoint: xai }, "xai-key");
    const text = `Here is the patch.\n\n\`\`\`diff\n${"+ line\n".repeat(12_000)}\`\`\``;

    const response = await fetch(`${server}/speech`, {
      method: "POST",
      body: JSON.stringify({ text }),
    });

    expect(text.length).toBeGreaterThan(60_000);
    expect(response.status).toBe(200);
    await response.arrayBuffer();
    expect(spoken).toEqual(["Here is the patch."]);
  });

  it("explains why it cannot read instead of returning audio", async () => {
    const failing = await listen((_req, res) => {
      res.writeHead(500);
      res.end("model not loaded");
    });
    const cases: Array<[TtsConfig | undefined, unknown, number, string]> = [
      [undefined, { text: "Hi." }, 404, "not configured"],
      [{ endpoint: failing }, { text: "Hi." }, 502, "model not loaded"],
      [{ endpoint: failing }, { text: "```\ncode only\n```" }, 400, "Nothing to read"],
      [{ endpoint: failing }, { nope: true }, 400, "Expected text"],
    ];
    for (const [tts, body, status, message] of cases) {
      const server = await speechServer(tts);
      const response = await fetch(`${server}/speech`, {
        method: "POST",
        body: JSON.stringify(body),
      });
      expect(response.status, message).toBe(status);
      expect(((await response.json()) as { error: string }).error).toContain(message);
    }
  });
});

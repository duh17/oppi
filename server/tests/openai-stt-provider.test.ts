import { describe, expect, it, vi } from "vitest";
import { SttSessionCreateError } from "../src/stt-provider.js";
import { OpenAiSttProvider } from "../src/openai-stt-provider.js";

const SENTINEL = "ReviewSyntheticVocabulary";

interface FetchCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  form?: FormData;
}

function headerMap(headers: HeadersInit | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!headers) return out;
  if (headers instanceof Headers) {
    headers.forEach((value, key) => {
      out[key.toLowerCase()] = value;
    });
    return out;
  }
  if (Array.isArray(headers)) {
    for (const [key, value] of headers) out[key.toLowerCase()] = value;
    return out;
  }
  for (const [key, value] of Object.entries(headers)) {
    out[key.toLowerCase()] = value;
  }
  return out;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function makeProvider(
  fetchFn: typeof globalThis.fetch,
  resolveApiKey: () => string | undefined | Promise<string | undefined> = () => "sk-test",
  opts?: { endpoint?: string; model?: string },
): OpenAiSttProvider {
  return new OpenAiSttProvider(
    {
      endpoint: opts?.endpoint ?? "https://api.openai.com",
      model: opts?.model ?? "gpt-4o-mini-transcribe",
      resolveApiKey,
    },
    fetchFn,
  );
}

describe("OpenAiSttProvider", () => {
  it("does not call the network on start or feed, and never emits live partials", async () => {
    const calls: FetchCall[] = [];
    const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
      const url =
        typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      calls.push({
        url,
        method: init?.method ?? "GET",
        headers: headerMap(init?.headers),
        form: init?.body instanceof FormData ? init.body : undefined,
      });
      return jsonResponse({ text: "should not run yet" });
    }) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn);
    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));

    const started = await provider.start();
    expect(started.contextApplied).toBe(false);
    expect(calls).toHaveLength(0);

    provider.feedAudio(Buffer.from([1, 0, 2, 0]));
    provider.feedAudio(Buffer.from([3, 0, 4, 0]));
    expect(calls).toHaveLength(0);
    expect(tokens).toEqual([]);

    await provider.dispose();
  });

  it("POSTs /v1/audio/transcriptions once on stop with bearer auth and a WAV body", async () => {
    const calls: FetchCall[] = [];
    const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
      const url =
        typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      calls.push({
        url,
        method: init?.method ?? "GET",
        headers: headerMap(init?.headers),
        form: init?.body instanceof FormData ? init.body : undefined,
      });
      return jsonResponse({ text: "hello from openai" });
    }) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn);
    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start();
    provider.feedAudio(Buffer.from([1, 0, 2, 0, 3, 0, 4, 0]));

    const result = await provider.stop();
    expect(result.text).toBe("hello from openai");
    expect(tokens).toEqual([]);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.method).toBe("POST");
    expect(calls[0]?.url).toBe("https://api.openai.com/v1/audio/transcriptions");
    expect(calls[0]?.headers.authorization).toBe("Bearer sk-test");
    expect(calls[0]?.url).not.toContain("/transcriptions/stream");

    const form = calls[0]?.form;
    expect(form).toBeDefined();
    expect(form?.get("model")).toBe("gpt-4o-mini-transcribe");
    expect(form?.get("stream")).toBeNull();
    const file = form?.get("file");
    expect(file).toBeInstanceOf(Blob);
    const bytes = Buffer.from(await (file as Blob).arrayBuffer());
    expect(bytes.subarray(0, 4).toString("ascii")).toBe("RIFF");
    expect(bytes.subarray(8, 12).toString("ascii")).toBe("WAVE");
    expect(bytes.readUInt16LE(22)).toBe(1);
    expect(bytes.readUInt32LE(24)).toBe(16000);
    expect(bytes.readUInt16LE(34)).toBe(16);
    expect(bytes.subarray(44)).toEqual(Buffer.from([1, 0, 2, 0, 3, 0, 4, 0]));
  });

  it("maps vocabulary to the documented prompt field and reports contextApplied", async () => {
    const calls: FetchCall[] = [];
    const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(input),
        method: init?.method ?? "GET",
        headers: headerMap(init?.headers),
        form: init?.body instanceof FormData ? init.body : undefined,
      });
      return jsonResponse({ text: "ok" });
    }) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn);
    const started = await provider.start({ contextualStrings: ["Yuwp", "Oppi"] });
    expect(started.contextApplied).toBe(true);
    provider.feedAudio(Buffer.from([1, 0]));
    await provider.stop();

    const form = calls[0]?.form;
    expect(form?.get("prompt")).toBe("Yuwp, Oppi");
    expect(form?.get("keywords")).toBeNull();
    expect(form?.has("stream_config")).toBe(false);
  });

  it("does not POST when stop has no audio", async () => {
    const fetchFn = vi.fn(async () => jsonResponse({ text: "nope" }));
    const provider = makeProvider(fetchFn as unknown as typeof globalThis.fetch);
    await provider.start();
    const result = await provider.stop();
    expect(result.text).toBe("");
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it("uses an async Pi auth resolver as the bearer token", async () => {
    const calls: FetchCall[] = [];
    const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(input),
        method: init?.method ?? "GET",
        headers: headerMap(init?.headers),
        form: init?.body instanceof FormData ? init.body : undefined,
      });
      return jsonResponse({ text: "ok" });
    }) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn, async () => "sk-from-pi-auth");
    await provider.start();
    provider.feedAudio(Buffer.from([1, 0]));
    await provider.stop();
    expect(calls[0]?.headers.authorization).toBe("Bearer sk-from-pi-auth");
  });

  it("throws auth on start when the OpenAI key is missing", async () => {
    const fetchFn = vi.fn(async () => jsonResponse({ text: "nope" }));
    const provider = makeProvider(fetchFn as unknown as typeof globalThis.fetch, () => undefined);
    await expect(provider.start()).rejects.toBeInstanceOf(SttSessionCreateError);
    await expect(provider.start()).rejects.toMatchObject({ category: "auth" });
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it("keeps upstream 401 bodies out of thrown errors", async () => {
    const fetchFn = (async () =>
      new Response(JSON.stringify({ error: { message: `invalid ${SENTINEL}` } }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      })) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn);
    await provider.start();
    provider.feedAudio(Buffer.from([1, 0]));
    await expect(provider.stop()).rejects.toThrow(/HTTP 401/);
    try {
      await provider.start();
      provider.feedAudio(Buffer.from([1, 0]));
      await provider.stop();
    } catch (err) {
      expect(err instanceof Error ? err.message : String(err)).not.toContain(SENTINEL);
    }
  });

  it("strips a trailing /v1 from a custom endpoint", async () => {
    const calls: FetchCall[] = [];
    const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
      calls.push({
        url: String(input),
        method: init?.method ?? "GET",
        headers: headerMap(init?.headers),
      });
      return jsonResponse({ text: "ok" });
    }) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn, () => "sk-test", {
      endpoint: "https://proxy.example.com/v1",
    });
    await provider.start();
    provider.feedAudio(Buffer.from([1, 0]));
    await provider.stop();
    expect(calls[0]?.url).toBe("https://proxy.example.com/v1/audio/transcriptions");
  });
});

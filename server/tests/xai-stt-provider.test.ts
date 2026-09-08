import { describe, expect, it } from "vitest";
import { SttSessionCreateError } from "../src/stt-provider.js";
import { XaiSttProvider, type SttWebSocket } from "../src/xai-stt-provider.js";

const SENTINEL = "ReviewSyntheticVocabulary";

class FakeSttSocket implements SttWebSocket {
  readonly url: string;
  readonly headers: Record<string, string>;
  readyState = 0;
  sent: Array<Buffer | string> = [];
  private readonly handlers = new Map<string, Array<(...args: unknown[]) => void>>();

  constructor(url: string, headers: Record<string, string>) {
    this.url = url;
    this.headers = headers;
  }

  on(event: "open" | "message" | "error" | "close", listener: (...args: unknown[]) => void): void {
    const list = this.handlers.get(event) ?? [];
    list.push(listener);
    this.handlers.set(event, list);
  }

  send(data: Buffer | string): void {
    this.sent.push(data);
  }

  close(): void {
    this.readyState = 3;
    this.emit("close");
  }

  open(): void {
    this.readyState = 1;
    this.emit("open");
  }

  emit(event: string, ...args: unknown[]): void {
    for (const listener of this.handlers.get(event) ?? []) listener(...args);
  }

  emitJson(body: unknown): void {
    this.emit("message", JSON.stringify(body));
  }
}

function makeProvider(
  sockets: FakeSttSocket[],
  resolveApiKey: () => string | undefined | Promise<string | undefined> = () => "xai-test",
  endpoint = "https://api.x.ai",
): XaiSttProvider {
  return new XaiSttProvider({
    endpoint,
    resolveApiKey,
    createWebSocket: (url, headers) => {
      const socket = new FakeSttSocket(url, headers);
      sockets.push(socket);
      queueMicrotask(() => {
        socket.open();
        socket.emitJson({ type: "transcript.created" });
      });
      return socket;
    },
  });
}

async function flush(): Promise<void> {
  for (let i = 0; i < 12; i++) await Promise.resolve();
}

describe("XaiSttProvider", () => {
  it("connects the official streaming STT WebSocket with bearer auth", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets);
    const started = await provider.start();
    expect(started.contextApplied).toBe(false);
    expect(sockets).toHaveLength(1);
    const socket = sockets[0];
    expect(socket?.headers.Authorization).toBe("Bearer xai-test");
    expect(socket?.url.startsWith("wss://api.x.ai/v1/stt?")).toBe(true);
    const url = new URL(socket?.url ?? "");
    expect(url.searchParams.get("sample_rate")).toBe("16000");
    expect(url.searchParams.get("encoding")).toBe("pcm");
    expect(url.searchParams.get("interim_results")).toBe("true");
    expect(socket?.url).not.toContain("/audio/transcriptions");
    await provider.dispose();
  });

  it("forwards live partials from transcript.partial and returns transcript.done on stop", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets);
    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start();
    await flush();

    const pcm = Buffer.from([1, 0, 2, 0]);
    provider.feedAudio(pcm);
    expect(sockets[0]?.sent.some((chunk) => Buffer.isBuffer(chunk) && chunk.equals(pcm))).toBe(
      true,
    );

    sockets[0]?.emitJson({
      type: "transcript.partial",
      text: "hello",
      is_final: false,
      speech_final: false,
    });
    sockets[0]?.emitJson({
      type: "transcript.partial",
      text: "hello world",
      is_final: true,
      speech_final: false,
    });
    expect(tokens).toEqual(["hello", "hello world"]);

    const stopPromise = provider.stop();
    await flush();
    const doneFrame = sockets[0]?.sent.find(
      (chunk) => typeof chunk === "string" && chunk.includes("audio.done"),
    );
    expect(doneFrame).toBe('{"type":"audio.done"}');
    sockets[0]?.emitJson({ type: "transcript.done", text: "hello world final", duration: 1.2 });
    await expect(stopPromise).resolves.toEqual({ text: "hello world final" });
  });

  it("maps vocabulary to documented keyterm query params and reports contextApplied", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets);
    const started = await provider.start({
      contextualStrings: ["Understand The Universe", "Oppi"],
    });
    expect(started.contextApplied).toBe(true);
    const url = new URL(sockets[0]?.url ?? "");
    expect(url.searchParams.getAll("keyterm")).toEqual(["Understand The Universe", "Oppi"]);
    await provider.dispose();
  });

  it("omits keyterms longer than the documented 50-character limit", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets);
    const tooLong = "x".repeat(51);
    const started = await provider.start({ contextualStrings: [tooLong, "Oppi"] });
    expect(started.contextApplied).toBe(true);
    const url = new URL(sockets[0]?.url ?? "");
    expect(url.searchParams.getAll("keyterm")).toEqual(["Oppi"]);
    await provider.dispose();
  });

  it("returns the last partial if the socket closes before stop", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets);
    await provider.start();
    await flush();
    sockets[0]?.emitJson({
      type: "transcript.partial",
      text: "hello",
      is_final: false,
      speech_final: false,
    });
    sockets[0]?.close();
    await expect(provider.stop()).resolves.toEqual({ text: "hello" });
  });

  it("uses an async Pi auth resolver as the bearer token", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets, async () => "xai-oauth-access");
    await provider.start();
    expect(sockets[0]?.headers.Authorization).toBe("Bearer xai-oauth-access");
    await provider.dispose();
  });

  it("throws auth on start when the xAI key is missing", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = makeProvider(sockets, () => undefined);
    await expect(provider.start()).rejects.toBeInstanceOf(SttSessionCreateError);
    await expect(provider.start()).rejects.toMatchObject({ category: "auth" });
    expect(sockets).toHaveLength(0);
  });

  it("keeps upstream WS error payloads out of thrown errors", async () => {
    const sockets: FakeSttSocket[] = [];
    const provider = new XaiSttProvider({
      endpoint: "https://api.x.ai",
      resolveApiKey: () => "xai-test",
      createWebSocket: (url, headers) => {
        const socket = new FakeSttSocket(url, headers);
        sockets.push(socket);
        queueMicrotask(() => {
          socket.open();
          socket.emitJson({ type: "error", message: `bad ${SENTINEL}` });
        });
        return socket;
      },
    });
    await expect(provider.start()).rejects.toBeInstanceOf(SttSessionCreateError);
    try {
      await provider.start();
    } catch (err) {
      expect(err instanceof Error ? err.message : String(err)).not.toContain(SENTINEL);
    }
  });
});

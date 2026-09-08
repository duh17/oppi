import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DictationManager } from "../src/dictation-manager.js";
import type { DictationServerMessage } from "../src/dictation-types.js";
import { SttSessionCreateError, StreamingSttProvider } from "../src/stt-provider.js";

const BASE = "http://localhost:9999";
const STREAM_URL = `${BASE}/v1/audio/transcriptions/stream`;

interface FetchCall {
  url: string;
  method: string;
  bodyLength?: number;
  jsonBody?: unknown;
}

type ResponseFactory = () => Response | Promise<Response>;

function jsonResponse(body: unknown, status = 200): ResponseFactory {
  return () =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function errorResponse(status: number): ResponseFactory {
  return () => new Response("", { status });
}

function createMockFetch(
  handlers: Array<{ match: (url: string, method: string) => boolean; response: ResponseFactory }>,
): { fetchFn: typeof globalThis.fetch; calls: FetchCall[] } {
  const calls: FetchCall[] = [];

  const fetchFn = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = init?.method ?? "GET";
    const rawBody = init?.body;
    const bodyLength =
      rawBody instanceof Uint8Array || rawBody instanceof ArrayBuffer
        ? rawBody.byteLength
        : undefined;
    let jsonBody: unknown;
    if (typeof rawBody === "string") {
      try {
        jsonBody = JSON.parse(rawBody) as unknown;
      } catch {
        jsonBody = undefined;
      }
    }
    calls.push({ url, method, bodyLength, jsonBody });

    for (const h of handlers) {
      if (h.match(url, method)) return h.response();
    }
    throw new Error(`Unexpected fetch request: ${method} ${url}`);
  };

  return { fetchFn: fetchFn as typeof globalThis.fetch, calls };
}

const isCreate = (url: string, method: string): boolean => method === "POST" && url === STREAM_URL;
const isFeed = (url: string, method: string): boolean =>
  method === "POST" && url.startsWith(STREAM_URL + "/");
const isDelete = (url: string, method: string): boolean =>
  method === "DELETE" && url.startsWith(STREAM_URL + "/");

async function flush(): Promise<void> {
  for (let i = 0; i < 10; i++) {
    vi.advanceTimersByTime(0);
    await Promise.resolve();
  }
}

function makeProvider(
  fetchFn: typeof globalThis.fetch,
  feedIntervalMs = 100,
): StreamingSttProvider {
  return new StreamingSttProvider({ endpoint: BASE, model: "test-model" }, fetchFn, feedIntervalMs);
}

function createBodies(calls: FetchCall[]): unknown[] {
  return calls.filter((c) => isCreate(c.url, c.method)).map((c) => c.jsonBody);
}

describe("StreamingSttProvider", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("does not create a session until start()", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush();
    expect(calls).toHaveLength(0);

    await provider.start();
    expect(calls.filter((c) => isCreate(c.url, c.method))).toHaveLength(1);
    await provider.dispose();
  });

  it("start -> feedAudio -> stop: correct API sequence", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      { match: isFeed, response: jsonResponse({ text: "hello world" }) },
      { match: isDelete, response: jsonResponse({ text: "hello world final" }) },
    ]);

    const provider = makeProvider(fetchFn);
    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start();

    expect(calls.filter((c) => isCreate(c.url, c.method))).toHaveLength(1);

    provider.feedAudio(Buffer.from([1, 2, 3, 4]));
    vi.advanceTimersByTime(100);
    await flush();

    expect(calls.filter((c) => isFeed(c.url, c.method)).length).toBeGreaterThanOrEqual(1);
    expect(tokens).toEqual(["hello world"]);

    const result = await provider.stop();
    expect(result.text).toBe("hello world final");
    expect(calls.some((c) => isDelete(c.url, c.method) && c.url === `${STREAM_URL}/s1`)).toBe(true);
  });

  it("emits a segment commit even when the visible text does not change", async () => {
    let feedCount = 0;
    const { fetchFn } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      {
        match: isFeed,
        response: () => {
          feedCount += 1;
          if (feedCount === 1) {
            return jsonResponse({
              text: "hello world",
              committed_text: "",
              active_text: "hello world",
            })();
          }
          return jsonResponse({
            text: "hello world",
            committed_text: "hello world",
            active_text: "",
            batch_corrected: true,
          })();
        },
      },
      { match: isDelete, response: jsonResponse({ text: "hello world" }) },
    ]);

    const provider = makeProvider(fetchFn);
    const updates: Array<{ text: string; snap: boolean }> = [];
    provider.onToken((update) => updates.push({ text: update.text, snap: update.snap === true }));
    await provider.start();

    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();

    provider.feedAudio(Buffer.from([3, 4]));
    vi.advanceTimersByTime(100);
    await flush();

    expect(updates).toEqual([
      { text: "hello world", snap: false },
      { text: "hello world", snap: true },
    ]);

    await provider.stop();
  });

  it("start() called twice: first session is DELETE'd", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      { match: isFeed, response: jsonResponse({ text: "hi" }) },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await provider.start();
    await provider.start();
    await flush();

    expect(calls.some((c) => isDelete(c.url, c.method) && c.url === `${STREAM_URL}/s1`)).toBe(true);
    await provider.stop();
  });

  it("stop without start does not throw", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    const result = await provider.stop();
    expect(result.text).toBe("");
    expect(calls).toHaveLength(0);
  });

  it("handles 404 on feed by recreating session with the same take context", async () => {
    let sessionCounter = 0;
    let feedStatus = 200;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      {
        match: isFeed,
        response: () => {
          if (feedStatus === 404) return errorResponse(404)();
          return jsonResponse({ text: "recovered" })();
        },
      },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start({ contextualStrings: ["Yuwp"] });

    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens).toEqual(["recovered"]);

    feedStatus = 404;
    provider.feedAudio(Buffer.from([3, 4]));
    vi.advanceTimersByTime(100);
    await flush();

    feedStatus = 200;
    provider.feedAudio(Buffer.from([5, 6]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens[tokens.length - 1]).toBe("recovered");

    const creates = createBodies(calls);
    expect(creates.length).toBeGreaterThanOrEqual(2);
    for (const body of creates) {
      expect(body).toEqual({
        model: "test-model",
        stream_config: { contextual_strings: ["Yuwp"] },
      });
    }

    await provider.stop();
  });

  it("dispose deletes the active session", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await provider.start();
    await provider.dispose();

    expect(calls.some((c) => isDelete(c.url, c.method) && c.url === `${STREAM_URL}/s1`)).toBe(true);
  });

  it("dispose with no active session does not fetch", async () => {
    const { fetchFn, calls } = createMockFetch([]);
    const provider = makeProvider(fetchFn);
    await provider.dispose();
    expect(calls).toHaveLength(0);
  });

  it("start throws when backend is down", async () => {
    const { fetchFn } = createMockFetch([{ match: isCreate, response: errorResponse(500) }]);
    const provider = makeProvider(fetchFn);
    await expect(provider.start()).rejects.toThrow();
    await provider.dispose();
  });

  it("start throws when fetch fails entirely", async () => {
    const { fetchFn } = createMockFetch([
      {
        match: isCreate,
        response: () => {
          throw new Error("fetch failed");
        },
      },
    ]);
    const provider = makeProvider(fetchFn);
    await expect(provider.start()).rejects.toThrow(SttSessionCreateError);
    await expect(provider.start()).rejects.toThrow(/network/);
  });

  it("feed timer concatenates multiple queued chunks into one request", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      { match: isFeed, response: jsonResponse({ text: "concat" }) },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await provider.start();
    const feedBaseline = calls.filter((c) => isFeed(c.url, c.method)).length;

    provider.feedAudio(Buffer.from([1, 2]));
    provider.feedAudio(Buffer.from([3, 4]));
    provider.feedAudio(Buffer.from([5, 6]));
    expect(calls.filter((c) => isFeed(c.url, c.method)).length).toBe(feedBaseline);

    vi.advanceTimersByTime(100);
    await Promise.resolve();
    expect(calls.filter((c) => isFeed(c.url, c.method)).length).toBe(feedBaseline + 1);

    await provider.stop();
  });

  it("stop waits for in-flight feed and drains queued audio before deleting the session", async () => {
    let releaseFirstFeed: (() => void) | null = null;
    let nonEmptyFeedCount = 0;
    const callOrder: string[] = [];

    const fetchFn = (async (
      input: string | URL | Request,
      init?: RequestInit,
    ): Promise<Response> => {
      const url =
        typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const method = init?.method ?? "GET";

      if (method === "POST" && url === STREAM_URL) {
        callOrder.push("create");
        return new Response(JSON.stringify({ session_id: "s1" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }

      if (method === "POST" && url === `${STREAM_URL}/s1`) {
        nonEmptyFeedCount += 1;
        callOrder.push(`feed-${nonEmptyFeedCount}`);
        if (nonEmptyFeedCount === 1) {
          await new Promise<void>((resolve) => {
            releaseFirstFeed = resolve;
          });
        }
        return new Response(JSON.stringify({ text: `chunk ${nonEmptyFeedCount}` }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }

      if (method === "DELETE" && url === `${STREAM_URL}/s1`) {
        callOrder.push("delete");
        return new Response(JSON.stringify({ text: "done" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }

      return new Response("Not found", { status: 404 });
    }) as typeof globalThis.fetch;

    const provider = makeProvider(fetchFn);
    await provider.start();

    provider.feedAudio(Buffer.from([1]));
    vi.advanceTimersByTime(100);
    await Promise.resolve();
    expect(callOrder).toContain("feed-1");

    provider.feedAudio(Buffer.from([2]));
    const stopPromise = provider.stop();
    await Promise.resolve();

    expect(callOrder).not.toContain("delete");
    releaseFirstFeed?.();

    await stopPromise;
    expect(callOrder.slice(0, 4)).toEqual(["create", "feed-1", "feed-2", "delete"]);
  });

  it("handles 404 on feed when session recreation also fails", async () => {
    let sessionCounter = 0;
    let createShouldFail = false;
    const { fetchFn, calls } = createMockFetch([
      {
        match: isCreate,
        response: () => {
          if (createShouldFail) return errorResponse(500)();
          return jsonResponse({ session_id: `s${++sessionCounter}` })();
        },
      },
      { match: isFeed, response: errorResponse(404) },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await provider.start();
    createShouldFail = true;
    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(calls.filter((c) => isCreate(c.url, c.method)).length).toBeGreaterThanOrEqual(1);
    await provider.dispose();
  });

  it("handles fetch throwing during flushAudio", async () => {
    let feedShouldThrow = false;
    const { fetchFn } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      {
        match: isFeed,
        response: () => {
          if (feedShouldThrow) throw new Error("network timeout");
          return jsonResponse({ text: "ok" })();
        },
      },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start();

    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens).toEqual(["ok"]);

    feedShouldThrow = true;
    provider.feedAudio(Buffer.from([3, 4]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens).toEqual(["ok"]);

    await provider.stop();
  });

  it("dispose handles network errors gracefully", async () => {
    const { fetchFn } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      {
        match: isDelete,
        response: () => {
          throw new Error("ECONNREFUSED");
        },
      },
    ]);

    const provider = makeProvider(fetchFn);
    await provider.start();
    await expect(provider.dispose()).resolves.toBeUndefined();
  });

  describe("per-take contextual strings", () => {
    it("omits stream_config when the take has no hints", async () => {
      const { fetchFn, calls } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isDelete, response: jsonResponse({ text: "" }) },
      ]);
      const provider = makeProvider(fetchFn);
      const result = await provider.start();
      expect(result.contextApplied).toBe(false);
      expect(createBodies(calls)).toEqual([{ model: "test-model" }]);
      await provider.stop();
    });

    it("sends stream_config.contextual_strings and reports context_applied", async () => {
      const { fetchFn, calls } = createMockFetch([
        {
          match: isCreate,
          response: jsonResponse({ session_id: "s1", context_applied: true }),
        },
        { match: isDelete, response: jsonResponse({ text: "" }) },
      ]);
      const provider = makeProvider(fetchFn);
      const result = await provider.start({ contextualStrings: ["Foo Bar", "Yuwp"] });
      expect(result.contextApplied).toBe(true);
      expect(createBodies(calls)).toEqual([
        {
          model: "test-model",
          stream_config: { contextual_strings: ["Foo Bar", "Yuwp"] },
        },
      ]);
      await provider.stop();
    });

    it("does not treat a missing context_applied acknowledgement as applied", async () => {
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isDelete, response: jsonResponse({ text: "" }) },
      ]);
      const provider = makeProvider(fetchFn);
      const result = await provider.start({ contextualStrings: ["Yuwp"] });
      expect(result.contextApplied).toBe(false);
      await provider.stop();
    });

    it("does not treat context_applied false as applied", async () => {
      const { fetchFn } = createMockFetch([
        {
          match: isCreate,
          response: jsonResponse({ session_id: "s1", context_applied: false }),
        },
        { match: isDelete, response: jsonResponse({ text: "" }) },
      ]);
      const provider = makeProvider(fetchFn);
      const result = await provider.start({ contextualStrings: ["Yuwp"] });
      expect(result.contextApplied).toBe(false);
      await provider.stop();
    });

    it("isolates take A then B then empty create bodies", async () => {
      const { fetchFn, calls } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1", context_applied: true }) },
        { match: isDelete, response: jsonResponse({ text: "" }) },
      ]);
      const provider = makeProvider(fetchFn);

      await provider.start({ contextualStrings: ["Alpha"] });
      await provider.stop();
      await provider.start({ contextualStrings: ["Beta Token"] });
      await provider.stop();
      await provider.start();
      await provider.stop();

      expect(createBodies(calls)).toEqual([
        { model: "test-model", stream_config: { contextual_strings: ["Alpha"] } },
        { model: "test-model", stream_config: { contextual_strings: ["Beta Token"] } },
        { model: "test-model" },
      ]);
    });

    it("never sends system_prompt", async () => {
      const { fetchFn, calls } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1", context_applied: true }) },
        { match: isDelete, response: jsonResponse({ text: "" }) },
      ]);
      const provider = makeProvider(fetchFn);
      await provider.start({ contextualStrings: ["Yuwp"] });
      const body = createBodies(calls)[0] as Record<string, unknown>;
      expect(body.stream_config).toEqual({ contextual_strings: ["Yuwp"] });
      expect(JSON.stringify(body)).not.toContain("system_prompt");
      await provider.stop();
    });
  });

  describe("create failures never echo upstream bodies", () => {
    const SENTINEL = "ReviewSyntheticVocabulary";

    function collectStderr(): { lines: string[]; restore: () => void } {
      const lines: string[] = [];
      const spy = vi.spyOn(process.stderr, "write").mockImplementation((chunk) => {
        lines.push(String(chunk));
        return true;
      });
      return {
        lines,
        restore() {
          spy.mockRestore();
        },
      };
    }

    function expectNoSentinel(haystack: string): void {
      expect(haystack).not.toContain(SENTINEL);
    }

    it("keeps 422 bodies out of thrown errors, logs, and dictation_error frames", async () => {
      const { fetchFn } = createMockFetch([
        {
          match: isCreate,
          response: () =>
            new Response(JSON.stringify({ error: `unknown phrase ${SENTINEL}` }), {
              status: 422,
              headers: { "Content-Type": "application/json" },
            }),
        },
      ]);
      const stderr = collectStderr();
      const provider = makeProvider(fetchFn);
      const sent: DictationServerMessage[] = [];
      const manager = new DictationManager(provider);

      await expect(provider.start({ contextualStrings: [SENTINEL] })).rejects.toBeInstanceOf(
        SttSessionCreateError,
      );
      try {
        await provider.start({ contextualStrings: [SENTINEL] });
      } catch (err) {
        expectNoSentinel(err instanceof Error ? err.message : String(err));
      }

      manager.handleControlMessage(
        { type: "dictation_start", contextualStrings: [SENTINEL] },
        (msg) => sent.push(msg),
      );
      for (let i = 0; i < 20; i++) await Promise.resolve();

      expectNoSentinel(JSON.stringify(sent));
      expectNoSentinel(stderr.lines.join(""));
      const errors = sent.filter((m) => m.type === "dictation_error");
      expect(errors.length).toBeGreaterThan(0);
      expect(errors[0]?.error).toMatch(/HTTP 422/);
      stderr.restore();
    });

    it("keeps malformed JSON excerpts out of thrown errors", async () => {
      const { fetchFn } = createMockFetch([
        {
          match: isCreate,
          response: () =>
            new Response(`{"session_id":"s1","leak":"${SENTINEL}"`, {
              status: 200,
              headers: { "Content-Type": "application/json" },
            }),
        },
      ]);
      const stderr = collectStderr();
      const provider = makeProvider(fetchFn);
      await expect(provider.start({ contextualStrings: [SENTINEL] })).rejects.toBeInstanceOf(
        SttSessionCreateError,
      );
      try {
        await provider.start({ contextualStrings: [SENTINEL] });
      } catch (err) {
        expectNoSentinel(err instanceof Error ? err.message : String(err));
        expect(err instanceof SttSessionCreateError && err.category === "invalid_response").toBe(
          true,
        );
      }
      expectNoSentinel(stderr.lines.join(""));
      stderr.restore();
    });

    it("rejects numeric session_id and non-boolean context_applied without echoing hints", async () => {
      const { fetchFn } = createMockFetch([
        {
          match: isCreate,
          response: jsonResponse({
            session_id: 17,
            context_applied: true,
            leak: SENTINEL,
          }),
        },
      ]);
      const stderr = collectStderr();
      const provider = makeProvider(fetchFn);
      await expect(provider.start({ contextualStrings: [SENTINEL] })).rejects.toMatchObject({
        category: "invalid_response",
      });
      try {
        await provider.start({ contextualStrings: [SENTINEL] });
      } catch (err) {
        expectNoSentinel(err instanceof Error ? err.message : String(err));
      }
      expectNoSentinel(stderr.lines.join(""));
      stderr.restore();
    });

    it("rejects non-boolean context_applied on an otherwise valid session_id", async () => {
      const { fetchFn } = createMockFetch([
        {
          match: isCreate,
          response: jsonResponse({
            session_id: "s1",
            context_applied: "true",
            leak: SENTINEL,
          }),
        },
      ]);
      const provider = makeProvider(fetchFn);
      await expect(provider.start({ contextualStrings: [SENTINEL] })).rejects.toMatchObject({
        category: "invalid_response",
      });
    });
  });
});

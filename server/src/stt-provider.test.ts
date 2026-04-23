import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { StreamingSttProvider } from "./stt-provider.js";

// ─── Mock helpers ───

const BASE = "http://localhost:9999";
const STREAM_URL = `${BASE}/v1/audio/transcriptions/stream`;

interface FetchCall {
  url: string;
  method: string;
}

/** Response factory — returns a fresh Response each invocation. */
type ResponseFactory = () => Response;

function jsonResponse(body: unknown, status = 200): ResponseFactory {
  return () =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function errorResponse(status: number): ResponseFactory {
  return () => new Response("", { status });
}

/**
 * Create a mock fetch that routes by method + URL pattern.
 * Handlers are checked in order; first match wins.
 * Falls back to 404 if nothing matches.
 */
function createMockFetch(
  handlers: Array<{ match: (url: string, method: string) => boolean; response: ResponseFactory }>,
): { fetchFn: typeof globalThis.fetch; calls: FetchCall[] } {
  const calls: FetchCall[] = [];

  const fetchFn = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = init?.method ?? "GET";
    calls.push({ url, method });

    for (const h of handlers) {
      if (h.match(url, method)) return h.response();
    }
    return new Response("Not found", { status: 404 });
  };

  return { fetchFn: fetchFn as typeof globalThis.fetch, calls };
}

// Matchers
const isCreate = (url: string, method: string): boolean => method === "POST" && url === STREAM_URL;
const isFeed = (url: string, method: string): boolean =>
  method === "POST" && url.startsWith(STREAM_URL + "/");
const isDelete = (url: string, method: string): boolean =>
  method === "DELETE" && url.startsWith(STREAM_URL + "/");

/** Drain async microtasks (constructor warmUpSession, createSession, etc.). */
async function flush(): Promise<void> {
  for (let i = 0; i < 10; i++) {
    vi.advanceTimersByTime(0);
    await Promise.resolve();
  }
}

/** Shorthand for creating a provider with defaults. */
function makeProvider(
  fetchFn: typeof globalThis.fetch,
  feedIntervalMs = 100,
): StreamingSttProvider {
  return new StreamingSttProvider({ endpoint: BASE, model: "test-model" }, fetchFn, feedIntervalMs);
}

// ─── Tests ───

describe("StreamingSttProvider", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  // 1. Happy path
  it("start -> feedAudio -> stop: correct API sequence", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      { match: isFeed, response: jsonResponse({ text: "hello world" }) },
      { match: isDelete, response: jsonResponse({ text: "hello world final" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // constructor warmUpSession

    expect(calls.filter((c) => c.method === "POST" && c.url === STREAM_URL)).toHaveLength(1);

    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start();

    // Warm session was consumed — verify call was made (may include a verify POST)
    const postCalls = calls.filter((c) => c.method === "POST" && c.url === STREAM_URL);
    expect(postCalls.length).toBeGreaterThanOrEqual(1);

    provider.feedAudio(Buffer.from([1, 2, 3, 4]));

    // Advance timer to trigger flushAudio
    vi.advanceTimersByTime(100);
    await flush();

    // Feed should have fired
    const feedCalls = calls.filter((c) => isFeed(c.url, c.method));
    expect(feedCalls.length).toBeGreaterThanOrEqual(1);
    expect(tokens).toEqual(["hello world"]);

    // Stop
    const result = await provider.stop();
    expect(result.text).toBe("hello world final");

    // DELETE was sent
    const deleteCalls = calls.filter((c) => isDelete(c.url, c.method));
    expect(deleteCalls.some((c) => c.url === `${STREAM_URL}/s1`)).toBe(true);
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
            // Warm-session verify probe sent by start().
            return jsonResponse({ text: "" })();
          }
          if (feedCount === 2) {
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
    await flush();

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

  // 2. Warm session reuse — no extra createSession on start
  it("start reuses warm session without creating a new one", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "warm-1" }) },
      { match: isFeed, response: jsonResponse({ text: "" }) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush();

    const createsBefore = calls.filter((c) => isCreate(c.url, c.method)).length;
    await provider.start();
    await flush();

    // No new session creation — warm was reused (verify POST goes to session URL, not create)
    const createsAfter = calls.filter((c) => isCreate(c.url, c.method)).length;
    expect(createsAfter).toBe(createsBefore);

    await provider.stop();
  });

  // 3. Double start cleans up first session
  it("start() called twice: first session is DELETE'd", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      { match: isFeed, response: jsonResponse({ text: "hi" }) },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // warm = s1

    await provider.start(); // active = s1 (from warm)
    await flush();

    await provider.start(); // should DELETE s1, then use fresh session
    await flush();

    // s1 should have been DELETE'd
    const deleteCalls = calls.filter((c) => isDelete(c.url, c.method));
    expect(deleteCalls.some((c) => c.url === `${STREAM_URL}/s1`)).toBe(true);

    await provider.stop();
  });

  // 4. stop() without start() — no-op
  it("stop without start does not throw", async () => {
    const { fetchFn } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "warm-1" }) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush();

    // stop() before any start() — should return "" and not throw
    const result = await provider.stop();
    expect(result.text).toBe("");
  });

  // 5. warmUpSession replaces existing warm — old one DELETE'd
  it("warmUpSession cleans up previous warm session", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `w${++sessionCounter}` })() },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // warm = w1

    // stop() triggers another warmUpSession, which should DELETE w1 first
    // Need to give it a session to stop — use start+stop cycle
    // Actually, stop() without start() also calls warmUpSession().
    const result = await provider.stop();
    expect(result.text).toBe("");
    await flush(); // let warmUpSession complete → warm = w2

    // w1 should have been DELETE'd during the second warmUpSession
    const deleteCalls = calls.filter((c) => isDelete(c.url, c.method));
    expect(deleteCalls.some((c) => c.url === `${STREAM_URL}/w1`)).toBe(true);

    // New warm session w2 was created
    const creates = calls.filter((c) => isCreate(c.url, c.method));
    expect(creates.length).toBeGreaterThanOrEqual(2);

    await provider.dispose();
  });

  // 6. MLX server returns 404 on feed — session recreated
  it("handles 404 on feed by recreating session", async () => {
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
    await flush(); // warm = s1

    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start(); // active = s1

    // Queue audio and flush — should succeed
    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens).toEqual(["recovered"]);

    // Now make feed return 404
    feedStatus = 404;
    provider.feedAudio(Buffer.from([3, 4]));
    vi.advanceTimersByTime(100);
    await flush(); // let 404 handling + createSession complete

    // Session should have been recreated (s2 from createSession, warm was consumed as s1)
    feedStatus = 200;
    provider.feedAudio(Buffer.from([5, 6]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens[tokens.length - 1]).toBe("recovered");

    // Verify we created more than the initial warm session
    const creates = calls.filter((c) => isCreate(c.url, c.method));
    expect(creates.length).toBeGreaterThanOrEqual(2);

    await provider.stop();
  });

  // 7. dispose() cleans up both active and warm sessions
  it("dispose deletes active and warm sessions", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      { match: isFeed, response: jsonResponse({ text: "hi" }) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // warm = s1

    await provider.start(); // active = s1 (from warm)
    await flush();

    const stopResult = await provider.stop(); // DELETEs s1, warms up s2
    await flush();
    expect(stopResult.text).toBe("");

    // Now start again — active = s2 (from warm)
    await provider.start();
    await flush();

    // Current state: active = s2, warm = null.
    await provider.dispose();

    const deleteCalls = calls.filter((c) => isDelete(c.url, c.method));
    // s1 was deleted during stop(), s2 during dispose()
    expect(deleteCalls.some((c) => c.url === `${STREAM_URL}/s2`)).toBe(true);
  });

  it("dispose deletes warm session when no active session exists", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "warm-1" }) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // warm = warm-1

    // No start() called — only warm exists
    await provider.dispose();

    const deleteCalls = calls.filter((c) => isDelete(c.url, c.method));
    expect(deleteCalls).toHaveLength(1);
    expect(deleteCalls[0].url).toBe(`${STREAM_URL}/warm-1`);
  });

  // 8. start() throws when backend is unreachable
  it("start throws when backend is down (no warm session, createSession fails)", async () => {
    const { fetchFn } = createMockFetch([
      { match: isCreate, response: errorResponse(500) },
      { match: isDelete, response: jsonResponse({ text: "" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // warm-up fails (500)

    // start() should throw since no warm and createSession returns 500
    await expect(provider.start()).rejects.toThrow();

    await provider.dispose();
  });

  // 8b. start() throws when fetch itself fails (network down)
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
    await flush(); // warm-up fails

    await expect(provider.start()).rejects.toThrow("fetch failed");
  });

  // 8c. start() detects stale warm session and recreates
  it("start recreates session when warm session is stale (404 on verify)", async () => {
    let sessionCounter = 0;
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: () => jsonResponse({ session_id: `s${++sessionCounter}` })() },
      {
        match: isFeed,
        response: () => {
          // First feed (verify) returns 404, subsequent feeds succeed
          const feedCalls = calls.filter((c) => isFeed(c.url, c.method));
          if (feedCalls.length <= 1) return errorResponse(404)();
          return jsonResponse({ text: "ok" })();
        },
      },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush(); // warm = s1

    // start() should detect s1 is stale, delete it, and create s2
    await provider.start();
    await flush();

    // Should have created a fresh session after stale warm
    const creates = calls.filter((c) => isCreate(c.url, c.method));
    expect(creates.length).toBeGreaterThanOrEqual(2);

    await provider.stop();
  });

  // 9. Feed timer concatenates queued audio chunks
  it("feed timer concatenates multiple queued chunks into one request", async () => {
    const { fetchFn, calls } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      { match: isFeed, response: jsonResponse({ text: "concat" }) },
      { match: isDelete, response: jsonResponse({ text: "done" }) },
    ]);

    const provider = makeProvider(fetchFn);
    await flush();

    await provider.start();

    // start() may have sent a verify POST — record baseline
    const feedBaseline = calls.filter((c) => isFeed(c.url, c.method)).length;

    // Feed multiple chunks before timer fires
    provider.feedAudio(Buffer.from([1, 2]));
    provider.feedAudio(Buffer.from([3, 4]));
    provider.feedAudio(Buffer.from([5, 6]));

    // Timer hasn't fired yet — no new feeds beyond baseline
    expect(calls.filter((c) => isFeed(c.url, c.method)).length).toBe(feedBaseline);

    // Advance past one interval
    vi.advanceTimersByTime(100);
    await Promise.resolve();

    // All three chunks sent as one request
    const feedCalls = calls.filter((c) => isFeed(c.url, c.method));
    expect(feedCalls.length).toBe(feedBaseline + 1);

    await provider.stop();
  });

  // Edge: 404 on feed + createSession also fails → logs warning, no throw
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
    await flush(); // warm = s1

    await provider.start(); // active = s1

    // Now make createSession fail so the 404 recovery path hits the inner catch
    createShouldFail = true;

    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();

    // Should not throw — the error is logged and swallowed
    // Session should be null after the failed recreation
    const creates = calls.filter((c) => isCreate(c.url, c.method));
    expect(creates.length).toBeGreaterThanOrEqual(1);

    await provider.dispose();
  });

  // Edge: fetch itself throws during feed → outer catch handles it
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
    await flush();

    const tokens: string[] = [];
    provider.onToken((update) => tokens.push(update.text));
    await provider.start();

    // First feed succeeds
    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();
    expect(tokens).toEqual(["ok"]);

    // Now make fetch throw on the next feed
    feedShouldThrow = true;
    provider.feedAudio(Buffer.from([3, 4]));
    vi.advanceTimersByTime(100);
    await flush();

    // Should not throw — error is caught and logged
    // No new tokens emitted from the failed feed
    expect(tokens).toEqual(["ok"]);

    await provider.stop();
  });

  // Edge: dispose is safe when fetch throws (network down)
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
    await flush();

    // Should not throw even when DELETE fails
    await expect(provider.dispose()).resolves.toBeUndefined();
  });

  // ─── Hallucination filter (isPromptLeak) ───

  describe("hallucination filter (system prompt leak suppression)", () => {
    const SYSTEM_PROMPT = "Domain terms and proper nouns: Oppi, StreamingSttProvider, PCM audio";

    /** Create a provider with the system prompt set. */
    function makeProviderWithPrompt(fetchFn: typeof globalThis.fetch): StreamingSttProvider {
      return new StreamingSttProvider(
        { endpoint: BASE, model: "test-model", systemPrompt: SYSTEM_PROMPT },
        fetchFn,
        100,
      );
    }

    it("suppresses transcript that starts with the system prompt prefix", async () => {
      const leaked = SYSTEM_PROMPT; // exact match of entire prompt
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isFeed, response: jsonResponse({ text: leaked }) },
        { match: isDelete, response: jsonResponse({ text: "final" }) },
      ]);

      const provider = makeProviderWithPrompt(fetchFn);
      await flush();

      const tokens: string[] = [];
      provider.onToken((update) => tokens.push(update.text));
      await provider.start();

      provider.feedAudio(Buffer.from([1, 2, 3]));
      vi.advanceTimersByTime(100);
      await flush();

      // Leaked text should have been suppressed — no tokens emitted
      expect(tokens).toEqual([]);

      await provider.stop();
    });

    it("suppresses transcript with prompt prefix followed by trailing content", async () => {
      // First 30 chars match, plus extra garbage the model appended
      const leaked = SYSTEM_PROMPT.slice(0, 30) + " ...some hallucinated continuation";
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isFeed, response: jsonResponse({ text: leaked }) },
        { match: isDelete, response: jsonResponse({ text: "final" }) },
      ]);

      const provider = makeProviderWithPrompt(fetchFn);
      await flush();

      const tokens: string[] = [];
      provider.onToken((update) => tokens.push(update.text));
      await provider.start();

      provider.feedAudio(Buffer.from([1, 2]));
      vi.advanceTimersByTime(100);
      await flush();

      expect(tokens).toEqual([]);

      await provider.stop();
    });

    it("passes through normal transcript unchanged", async () => {
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isFeed, response: jsonResponse({ text: "The quick brown fox" }) },
        { match: isDelete, response: jsonResponse({ text: "done" }) },
      ]);

      const provider = makeProviderWithPrompt(fetchFn);
      await flush();

      const tokens: string[] = [];
      provider.onToken((update) => tokens.push(update.text));
      await provider.start();

      provider.feedAudio(Buffer.from([1, 2]));
      vi.advanceTimersByTime(100);
      await flush();

      expect(tokens).toEqual(["The quick brown fox"]);

      await provider.stop();
    });

    it("does not suppress partial/similar-but-not-matching text (no false positives)", async () => {
      // Starts with "Domain" but diverges before hitting the 30-char prefix
      const similar = "Domain terms are interesting things to study";
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isFeed, response: jsonResponse({ text: similar }) },
        { match: isDelete, response: jsonResponse({ text: "done" }) },
      ]);

      const provider = makeProviderWithPrompt(fetchFn);
      await flush();

      const tokens: string[] = [];
      provider.onToken((update) => tokens.push(update.text));
      await provider.start();

      provider.feedAudio(Buffer.from([1, 2]));
      vi.advanceTimersByTime(100);
      await flush();

      // Should NOT be suppressed — only the first few words match, not the 30-char prefix
      expect(tokens).toEqual([similar]);

      await provider.stop();
    });

    it("does not suppress when no system prompt is configured", async () => {
      const textLookingLikePrompt = SYSTEM_PROMPT;
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isFeed, response: jsonResponse({ text: textLookingLikePrompt }) },
        { match: isDelete, response: jsonResponse({ text: "done" }) },
      ]);

      // No systemPrompt — use the default makeProvider
      const provider = makeProvider(fetchFn);
      await flush();

      const tokens: string[] = [];
      provider.onToken((update) => tokens.push(update.text));
      await provider.start();

      provider.feedAudio(Buffer.from([1, 2]));
      vi.advanceTimersByTime(100);
      await flush();

      // Without a system prompt, the filter is disabled — text passes through
      expect(tokens).toEqual([textLookingLikePrompt]);

      await provider.stop();
    });

    it("handles empty transcript (not emitted regardless of filter)", async () => {
      const { fetchFn } = createMockFetch([
        { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
        { match: isFeed, response: jsonResponse({ text: "" }) },
        { match: isDelete, response: jsonResponse({ text: "done" }) },
      ]);

      const provider = makeProviderWithPrompt(fetchFn);
      await flush();

      const tokens: string[] = [];
      provider.onToken((update) => tokens.push(update.text));
      await provider.start();

      provider.feedAudio(Buffer.from([1, 2]));
      vi.advanceTimersByTime(100);
      await flush();

      // Empty text is already filtered by the `text &&` guard before isPromptLeak
      expect(tokens).toEqual([]);

      await provider.stop();
    });
  });

  // Edge: stop returns last known text when DELETE fails
  it("stop returns last text when DELETE fails", async () => {
    const { fetchFn } = createMockFetch([
      { match: isCreate, response: jsonResponse({ session_id: "s1" }) },
      { match: isFeed, response: jsonResponse({ text: "partial" }) },
      {
        match: isDelete,
        response: () => {
          throw new Error("timeout");
        },
      },
    ]);

    const provider = makeProvider(fetchFn);
    await flush();

    provider.onToken(() => {});
    await provider.start();
    provider.feedAudio(Buffer.from([1, 2]));
    vi.advanceTimersByTime(100);
    await flush();

    const result = await provider.stop();
    expect(result.text).toBe("partial");
  });
});

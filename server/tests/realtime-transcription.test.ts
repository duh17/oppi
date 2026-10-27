import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { afterEach, describe, expect, it, vi } from "vitest";

// These tests read the call's telemetry from stderr. The pre-commit hook runs with
// OPPI_LOG_LEVEL=error and loggers bind their level at import, so set it before imports.
vi.hoisted(() => {
  process.env.OPPI_LOG_LEVEL = "info";
});
import { WebSocketServer, type WebSocket } from "ws";

import {
  RealtimeTranscriptionClient,
  realtimeTranscriptionUrl,
  vocabularyPrompt,
  type LiveTranscriptionEvents,
} from "../src/realtime-transcription.js";
import { SttSessionCreateError } from "../src/stt-provider.js";

/** A realtime transcription server the test plays by hand: it records what the client sends. */
class FakeRealtimeServer {
  readonly received: Array<Record<string, unknown>> = [];
  pings = 0;
  requestUrl = "";
  private readonly wss: WebSocketServer;
  private socket?: WebSocket;

  private constructor(
    private readonly http: Server,
    private readonly autoReady: boolean,
    private readonly autoCommitEmpty: boolean,
  ) {
    this.wss = new WebSocketServer({ server: http });
    this.wss.on("connection", (socket, request) => {
      this.socket = socket;
      this.requestUrl = request.url ?? "";
      socket.on("ping", () => void (this.pings += 1));
      socket.on("message", (data) => {
        const event = JSON.parse(String(data)) as Record<string, unknown>;
        this.received.push(event);
        if (event.type === "session.update" && this.autoReady)
          this.send({ type: "session.updated" });
        // Nothing open to cut, as when the VAD already committed everything.
        if (event.type === "input_audio_buffer.commit" && this.autoCommitEmpty) {
          this.send({
            type: "error",
            error: { type: "invalid_request_error", code: "input_audio_buffer_commit_empty" },
          });
        }
      });
    });
  }

  static async listen(
    options: { autoReady?: boolean; autoCommitEmpty?: boolean } = {},
  ): Promise<FakeRealtimeServer> {
    const http = createServer();
    await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
    return new FakeRealtimeServer(http, options.autoReady ?? true, options.autoCommitEmpty ?? true);
  }

  get url(): string {
    return `ws://127.0.0.1:${(this.http.address() as AddressInfo).port}/v1/realtime?intent=transcription`;
  }

  send(event: Record<string, unknown>): void {
    this.socket?.send(JSON.stringify(event));
  }

  /** Resolves once the client has sent an event of `type` (counting ones already sent). */
  async waitFor(type: string, count = 1): Promise<Record<string, unknown>> {
    for (let i = 0; i < 500; i++) {
      const matching = this.received.filter((event) => event.type === type);
      if (matching.length >= count) return matching[count - 1] as Record<string, unknown>;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    throw new Error(`client never sent ${type}`);
  }

  /** Stop reading from the client, as a server that is stuck would. */
  stallReads(): void {
    (this.socket as unknown as { _socket: { pause(): void } })._socket.pause();
  }

  closeSocket(code: number): void {
    this.socket?.close(code, "going away");
  }

  /** A text frame that is not valid UTF-8: the client's socket errors out. */
  breakSocket(): void {
    (this.socket as unknown as { _socket: { write(data: Buffer): void } })._socket.write(
      Buffer.from([0x81, 0x02, 0xff, 0xfe]),
    );
  }

  async close(): Promise<void> {
    for (const client of this.wss.clients) client.terminate();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
    await new Promise<void>((resolve) => this.http.close(() => resolve()));
  }
}

interface Recorded {
  speechStarted: number;
  partials: string[];
  turns: Array<{ text: string; reason: string }>;
  closed: Array<{ reason: string; code?: number }>;
}

function recorder(): { events: LiveTranscriptionEvents; seen: Recorded } {
  const seen: Recorded = { speechStarted: 0, partials: [], turns: [], closed: [] };
  return {
    seen,
    events: {
      speechStarted: () => void (seen.speechStarted += 1),
      partial: (text) => void seen.partials.push(text),
      turn: ({ text, reason }) => void seen.turns.push({ text, reason }),
      closed: (reason, detail) => void seen.closed.push({ reason, code: detail.code }),
    },
  };
}

const servers: FakeRealtimeServer[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => server.close()));
});

async function connect(
  options: {
    autoReady?: boolean;
    autoCommitEmpty?: boolean;
    silenceDurationMs?: number;
    pingIntervalMs?: number;
    vocabulary?: string[];
  } = {},
) {
  const server = await FakeRealtimeServer.listen(options);
  servers.push(server);
  const client = new RealtimeTranscriptionClient({
    url: server.url,
    silenceDurationMs: options.silenceDurationMs ?? 700,
    startTimeoutMs: 500,
    drainTimeoutMs: 500,
    pingIntervalMs: options.pingIntervalMs,
    vocabulary: options.vocabulary,
  });
  const { events, seen } = recorder();
  return { server, client, events, seen };
}

/** Wait for the recorded state to satisfy `check` (the socket delivers asynchronously). */
async function until(check: () => boolean): Promise<void> {
  for (let i = 0; i < 500; i++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("condition not reached");
}

describe("realtime transcription client", () => {
  it("opens a transcription session with server VAD and waits for session.updated before sending audio", async () => {
    const { server, client, events } = await connect({ autoReady: false, silenceDurationMs: 700 });
    const started = client.start(events);
    // Audio fed before the server accepted the session is held, not dropped.
    client.feedAudio(Buffer.from([1, 0, 2, 0]));
    await server.waitFor("session.update");
    expect(server.requestUrl).toBe("/v1/realtime?intent=transcription");
    expect(server.received).toEqual([
      {
        type: "session.update",
        session: {
          type: "transcription",
          audio: {
            input: {
              format: { type: "audio/pcm", rate: 16_000 },
              turn_detection: { type: "server_vad", silence_duration_ms: 700 },
            },
          },
        },
      },
    ]);

    server.send({ type: "session.updated" });
    await started;
    client.feedAudio(Buffer.from([3, 0]));
    await server.waitFor("input_audio_buffer.append", 2);

    expect(server.received.slice(1)).toEqual([
      { type: "input_audio_buffer.append", audio: Buffer.from([1, 0, 2, 0]).toString("base64") },
      { type: "input_audio_buffer.append", audio: Buffer.from([3, 0]).toString("base64") },
    ]);
    await client.stop();
  });

  it("sends dictionary phrases as Yuwp's vocabulary prompt, cut to the prompt limit in order", async () => {
    const { server, client, events } = await connect({
      autoReady: false,
      vocabulary: ["Oppi", "kypu", "Yuwp"],
    });
    const started = client.start(events);
    await server.waitFor("session.update");
    expect(server.received[0]).toMatchObject({
      session: {
        audio: { input: { transcription: { prompt: "Vocabulary: Oppi, kypu, Yuwp" } } },
      },
    });
    server.send({ type: "session.updated" });
    await started;
    await client.stop();

    // A full dictionary (100 phrases, 8192 bytes) plus the prefix and separators is past Yuwp's
    // 8192-byte prompt limit, which would fail the call's start: trailing phrases are left out.
    const full = Array.from({ length: 100 }, (_, i) => `${i}`.padStart(81, "x"));
    const prompt = vocabularyPrompt(full) ?? "";
    expect(Buffer.byteLength(prompt, "utf8")).toBeLessThanOrEqual(8192);
    expect(prompt).toBe(`Vocabulary: ${full.slice(0, 98).join(", ")}`);
    expect(vocabularyPrompt([])).toBeUndefined();
  });

  it("hands turns over in commit order even when the transcripts finish out of order", async () => {
    const { server, client, events, seen } = await connect();
    await client.start(events);

    server.send({ type: "input_audio_buffer.speech_started", item_id: "item-1" });
    server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
    server.send({ type: "input_audio_buffer.speech_started", item_id: "item-2" });
    server.send({ type: "input_audio_buffer.committed", item_id: "item-2" });
    // The second item's transcript lands first: it waits for the first.
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-2",
      transcript: "Then run the tests.",
    });
    await until(() => seen.partials.includes("Then run the tests."));
    expect(seen.turns).toEqual([]);

    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "Update the docs.",
    });
    await until(() => seen.turns.length === 2);

    expect(seen.turns).toEqual([
      { text: "Update the docs.", reason: "server_vad" },
      { text: "Then run the tests.", reason: "server_vad" },
    ]);
    expect(seen.speechStarted).toBe(2);
    expect(seen.partials.at(-1)).toBe("");
    await client.stop();
  });

  it("builds the live caption from deltas and ends the turn with the completed transcript", async () => {
    const { server, client, events, seen } = await connect();
    await client.start(events);

    server.send({
      type: "conversation.item.input_audio_transcription.delta",
      item_id: "item-1",
      delta: "Update your",
    });
    server.send({
      type: "conversation.item.input_audio_transcription.delta",
      item_id: "item-1",
      delta: " own code",
    });
    await until(() => seen.partials.length === 2);
    // Deltas are a caption only: the item is not over until the server commits and completes it.
    expect(seen.partials).toEqual(["Update your", "Update your own code"]);
    expect(seen.turns).toEqual([]);

    server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "Update your own code, and, uh, come back.",
    });
    await until(() => seen.turns.length === 1);

    // The completed transcript replaces what streamed.
    expect(seen.turns).toEqual([
      { text: "Update your own code, and, uh, come back.", reason: "server_vad" },
    ]);
    expect(seen.partials.at(-1)).toBe("");
    await client.stop();
  });

  it("treats a failed item as an empty turn that does not hold up the next one", async () => {
    const { server, client, events, seen } = await connect();
    await client.start(events);

    server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
    server.send({ type: "input_audio_buffer.committed", item_id: "item-2" });
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-2",
      transcript: "Second item.",
    });
    server.send({
      type: "conversation.item.input_audio_transcription.failed",
      item_id: "item-1",
      error: { type: "server_error", code: "transcription_failed" },
    });
    await until(() => seen.turns.length === 2);

    expect(seen.turns).toEqual([
      { text: "", reason: "server_vad" },
      { text: "Second item.", reason: "server_vad" },
    ]);
    await client.stop();
  });

  it.each([
    [
      "the server closes the socket",
      (server: FakeRealtimeServer) => server.closeSocket(1011),
      "socket_closed",
      1011,
    ],
    [
      "the socket breaks",
      (server: FakeRealtimeServer) => server.breakSocket(),
      "socket_error",
      undefined,
    ],
  ] as const)(
    "reports the end of listening once, with a logged reason, when %s",
    async (_what, end, reason, code) => {
      const lines: Record<string, unknown>[] = [];
      const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
        const line = JSON.parse(String(chunk)) as Record<string, unknown>;
        if (line.event === "realtime_transcription.closed") lines.push(line);
        return true;
      }) as typeof process.stderr.write);
      try {
        const { server, client, events, seen } = await connect();
        await client.start(events);
        server.send({
          type: "conversation.item.input_audio_transcription.delta",
          item_id: "item-1",
          delta: "half a sent",
        });
        await until(() => seen.partials.length === 1);

        end(server);
        await until(() => seen.closed.length > 0);

        expect(seen.closed).toHaveLength(1);
        expect(seen.closed[0]?.reason).toBe(reason);
        if (code !== undefined) expect(seen.closed[0]?.code).toBe(code);
        expect(lines).toEqual([expect.objectContaining({ reason, inFlightItems: 1 })]);
        // Audio after the end goes nowhere, and End has nothing left to wait for.
        client.feedAudio(Buffer.from([1, 0]));
        await client.stop();
        expect(seen.closed).toHaveLength(1);
        expect(seen.turns).toEqual([]);
      } finally {
        stderr.mockRestore();
      }
    },
  );

  it("cuts what the caller was still saying at End and hands it over before closing", async () => {
    const { server, client, events, seen } = await connect({ autoCommitEmpty: false });
    await client.start(events);
    // One item already ended on the VAD and is still being transcribed.
    server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
    server.send({
      type: "conversation.item.input_audio_transcription.delta",
      item_id: "item-1",
      delta: "Check",
    });
    await until(() => seen.partials.length === 1);

    const stopping = client.stop();
    await server.waitFor("input_audio_buffer.commit");
    server.send({ type: "input_audio_buffer.committed", item_id: "item-2" });
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-2",
      transcript: "And list the sessions.",
    });
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "Check the build.",
    });
    await stopping;

    expect(seen.turns).toEqual([
      { text: "Check the build.", reason: "server_vad" },
      { text: "And list the sessions.", reason: "call_stop" },
    ]);
    expect(seen.closed).toEqual([]);
  });

  it("ends at once when there was nothing left to cut", async () => {
    const { client, events, seen } = await connect();
    await client.start(events);

    await client.stop();

    expect(seen.turns).toEqual([]);
  });

  it("fails the start with the user-facing copy when the server refuses the session or lacks the endpoint", async () => {
    const { server, client, events } = await connect({ autoReady: false });
    const started = client.start(events);
    await server.waitFor("session.update");
    server.send({
      type: "error",
      error: { type: "invalid_request_error", code: "turn_detection_unavailable" },
    });
    await expect(started).rejects.toMatchObject({
      name: "SttSessionCreateError",
      category: "invalid_response",
    });

    // A Yuwp from before /v1/realtime answers the upgrade with plain HTTP.
    const old = createServer((_request, response) => {
      response.statusCode = 404;
      response.end("not found");
    });
    await new Promise<void>((resolve) => old.listen(0, "127.0.0.1", resolve));
    try {
      const oldClient = new RealtimeTranscriptionClient({
        url: `ws://127.0.0.1:${(old.address() as AddressInfo).port}/v1/realtime?intent=transcription`,
        silenceDurationMs: 700,
      });
      const failure = await oldClient.start(recorder().events).catch((error: unknown) => error);
      expect(failure).toBeInstanceOf(SttSessionCreateError);
      expect(failure).toMatchObject({ category: "http_error", status: 404 });
    } finally {
      await new Promise<void>((resolve) => old.close(() => resolve()));
    }
  });

  it("cuts an open item once when the phone stops sending audio, and not while audio keeps flowing", async () => {
    const { server, client, events, seen } = await connect({
      autoCommitEmpty: false,
      silenceDurationMs: 300,
    });
    await client.start(events);
    const commits = () =>
      server.received.filter((event) => event.type === "input_audio_buffer.commit");

    // Audio keeps arriving well inside the pause: the VAD alone decides, nothing is cut.
    server.send({ type: "input_audio_buffer.speech_started", item_id: "item-1" });
    for (let i = 0; i < 40; i++) {
      client.feedAudio(Buffer.from([1, 0]));
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    expect(commits()).toEqual([]);

    // The phone mutes mid-speech: no frames, so the server's VAD can never see the pause.
    await server.waitFor("input_audio_buffer.commit");
    await new Promise((resolve) => setTimeout(resolve, 400));
    expect(commits()).toHaveLength(1);

    server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "Update your own code and come back.",
    });
    await until(() => seen.turns.length === 1);
    expect(seen.turns).toEqual([
      { text: "Update your own code and come back.", reason: "audio_stalled" },
    ]);

    // End's commit finds nothing open; the server answers it like it would.
    const stopping = client.stop();
    await server.waitFor("input_audio_buffer.commit", 2);
    server.send({
      type: "error",
      error: { type: "invalid_request_error", code: "input_audio_buffer_commit_empty" },
    });
    await stopping;
  });

  it("keeps End waiting for its own commit's answer when a stalled-audio commit is still unanswered", async () => {
    const { server, client, events, seen } = await connect({
      autoCommitEmpty: false,
      silenceDurationMs: 60,
    });
    await client.start(events);
    server.send({ type: "input_audio_buffer.speech_started", item_id: "item-1" });
    await server.waitFor("input_audio_buffer.commit");

    let stopped = false;
    const stopping = client.stop().then(() => void (stopped = true));
    await server.waitFor("input_audio_buffer.commit", 2);

    // The server answers in order: the stalled-audio commit cut item-1 and it is transcribed.
    server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
    server.send({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "First words.",
    });
    await until(() => seen.turns.length === 1);
    await new Promise((resolve) => setTimeout(resolve, 50));
    // That was the stall commit's answer, not End's: End is still waiting.
    expect(stopped).toBe(false);

    server.send({
      type: "error",
      error: { type: "invalid_request_error", code: "input_audio_buffer_commit_empty" },
    });
    await stopping;
    expect(seen.turns).toEqual([{ text: "First words.", reason: "audio_stalled" }]);
  });

  it("takes commit_empty after a stalled-audio cut as the item having already ended", async () => {
    const lines: Record<string, unknown>[] = [];
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
      const line = JSON.parse(String(chunk)) as Record<string, unknown>;
      if (line.event === "realtime_transcription.event_error") lines.push(line);
      return true;
    }) as typeof process.stderr.write);
    try {
      const { server, client, events, seen } = await connect({
        autoCommitEmpty: false,
        silenceDurationMs: 60,
      });
      await client.start(events);
      server.send({ type: "input_audio_buffer.speech_started", item_id: "item-1" });
      await server.waitFor("input_audio_buffer.commit");
      // The VAD had committed the item just before our commit reached it: Yuwp sends its
      // committed first, then commit_empty for ours.
      server.send({ type: "input_audio_buffer.committed", item_id: "item-1" });
      server.send({
        type: "error",
        error: { type: "invalid_request_error", code: "input_audio_buffer_commit_empty" },
      });
      server.send({
        type: "conversation.item.input_audio_transcription.completed",
        item_id: "item-1",
        transcript: "Done.",
      });
      await until(() => seen.turns.length === 1);

      expect(seen.turns).toHaveLength(1);
      expect(seen.turns[0]?.text).toBe("Done.");
      expect(lines).toEqual([]);
      // End finds nothing pending from the earlier exchange: it waits for its own answer only.
      const stopping = client.stop();
      await server.waitFor("input_audio_buffer.commit", 2);
      server.send({
        type: "error",
        error: { type: "invalid_request_error", code: "input_audio_buffer_commit_empty" },
      });
      await stopping;
    } finally {
      stderr.mockRestore();
    }
  });

  it("pings the server on an interval so an idle socket is not closed", async () => {
    const { server, client, events } = await connect({ pingIntervalMs: 30 });
    await client.start(events);
    await until(() => server.pings >= 2);
    await client.stop();
    const after = server.pings;
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(server.pings).toBe(after);
  });

  it("drops audio instead of buffering without bound when the server stops reading, and says so once", async () => {
    const lines: Record<string, unknown>[] = [];
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
      const line = JSON.parse(String(chunk)) as Record<string, unknown>;
      if (/^realtime_transcription\.audio_(backpressure|dropped)/.test(String(line.event)))
        lines.push(line);
      return true;
    }) as typeof process.stderr.write);
    try {
      const { server, client, events } = await connect();
      await client.start(events);
      server.stallReads();
      // 1 s of PCM per frame; far more than the kernel's socket buffers can swallow.
      const second = Buffer.alloc(32_000);
      for (let i = 0; i < 600; i++) client.feedAudio(second);

      expect(lines).toEqual([
        expect.objectContaining({
          event: "realtime_transcription.audio_backpressure",
          bufferedBytes: expect.any(Number),
        }),
      ]);

      // The episode is still open when the call ends: the close says how many frames it cost.
      await client.stop();
      expect(lines.at(-1)).toMatchObject({
        event: "realtime_transcription.audio_dropped_at_close",
        droppedFrames: expect.any(Number),
      });
      expect(lines).toHaveLength(2);
    } finally {
      stderr.mockRestore();
    }
  });

  it("derives the realtime socket URL from the configured ASR endpoint", () => {
    expect(realtimeTranscriptionUrl("http://127.0.0.1:7936")).toBe(
      "ws://127.0.0.1:7936/v1/realtime?intent=transcription",
    );
    expect(realtimeTranscriptionUrl(" https://asr.example.com/yuwp/v1/ ")).toBe(
      "wss://asr.example.com/yuwp/v1/realtime?intent=transcription",
    );
  });
});

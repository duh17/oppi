import { createBashToolDefinition } from "@earendil-works/pi-coding-agent";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { appendFileSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import {
  TERMINAL_CHUNK_MAX_BYTES,
  TERMINAL_END_DRAIN_MAX_BYTES,
  TERMINAL_TICK_MAX_BYTES,
} from "../src/terminal-output-stream.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import type { ServerMessage } from "../src/types.js";

type ToolOutput = Extract<ServerMessage, { type: "tool_output" }>;
type ToolEnd = Extract<ServerMessage, { type: "tool_end" }>;

const cleanup: string[] = [];
afterEach(() => {
  for (const path of cleanup.splice(0)) rmSync(path, { recursive: true, force: true });
});

function makeCtx(): TranslationContext {
  return {
    sessionId: "s",
    mobileRenderers: new MobileRendererRegistry(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    toolArgs: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
}

const event = (value: Record<string, unknown>) => value as unknown as AgentSessionEvent;

/** The receiving side of the contract: strict contiguity inside an epoch, reset on a new epoch. */
class StreamReceiver {
  epoch = 0;
  cursor = 0;
  resets = 0;
  readonly text: string[] = [];
  readonly sizes: number[] = [];

  accept(message: ServerMessage): void {
    if (message.type !== "tool_output" || !message.outputStream) return;
    const { epoch, offset, bytes } = message.outputStream;
    expect(message.mode).toBeUndefined();
    expect(message.truncated).toBeUndefined();
    expect(message.totalBytes).toBeUndefined();
    if (epoch > this.epoch) {
      if (this.epoch > 0) this.resets += 1;
      this.epoch = epoch;
      this.cursor = 0;
      this.text.length = 0;
      this.sizes.length = 0;
    }
    expect(epoch).toBe(this.epoch);
    expect(offset).toBe(this.cursor);
    expect(bytes).toBeLessThanOrEqual(TERMINAL_CHUNK_MAX_BYTES);
    this.cursor += bytes;
    this.text.push(message.output);
    this.sizes.push(bytes);
  }

  get output(): string {
    return this.text.join("");
  }
}

function toolOutputs(messages: ServerMessage[]): ToolOutput[] {
  return messages.filter((m): m is ToolOutput => m.type === "tool_output");
}

function toolEnd(messages: ServerMessage[]): ToolEnd {
  const end = messages.find((m): m is ToolEnd => m.type === "tool_end");
  if (!end) throw new Error("missing tool_end");
  return end;
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Drive Pi's real bash tool (real OutputAccumulator, 100 ms update throttle, temp-file
 * handling) with scripted process output and translate each Pi event as the server does.
 */
async function runRealBash(plan: Array<Buffer | number>, ctx = makeCtx()) {
  const receiver = new StreamReceiver();
  const tickBytes: number[] = [];
  const markersSeen: Array<{ offset: number; cursor: number }> = [];
  let fullOutputPath: string | undefined;
  const tool = createBashToolDefinition(tmpdir(), {
    operations: {
      exec: async (_command, _cwd, { onData }) => {
        for (const step of plan) {
          if (typeof step === "number") await sleep(step);
          else onData(step);
        }
        return { exitCode: 0 };
      },
    },
  });
  const project = (value: Record<string, unknown>): ServerMessage[] =>
    translatePiEvent(event({ toolCallId: "tc", toolName: "bash", ...value }), ctx);
  project({ type: "tool_execution_start", args: { command: "x" } });
  const result = await tool.execute(
    "tc",
    { command: "x" },
    undefined,
    (partialResult) => {
      const path = (partialResult.details as { fullOutputPath?: string } | undefined)
        ?.fullOutputPath;
      if (path) fullOutputPath = path;
      const messages = project({ type: "tool_execution_update", partialResult });
      let sent = 0;
      for (const message of toolOutputs(messages)) {
        receiver.accept(message);
        sent += message.outputStream?.bytes ?? 0;
      }
      tickBytes.push(sent);
      const [marker] = ctx.toolOutputSnapshots.terminal.attachMarkers();
      if (marker) markersSeen.push({ offset: marker.offset, cursor: receiver.cursor });
    },
    undefined as never,
  );
  if (fullOutputPath) cleanup.push(fullOutputPath);
  const end = project({ type: "tool_execution_end", result, isError: false });
  for (const message of end) receiver.accept(message);
  return { receiver, end, ctx, tickBytes, markersSeen, fullOutputPath };
}

const line = (i: number) =>
  Buffer.from(`\u001b[3${i % 8}mrow-${i}\u001b[0m ${"x".repeat(40)} 🙂 ✓\r\n`, "utf8");
const lines = (from: number, count: number) =>
  Buffer.concat(Array.from({ length: count }, (_, i) => line(from + i)));

describe("terminal output stream (real Pi bash)", () => {
  it("streams small output as contiguous raw bytes without stripping and tracks the cursor", async () => {
    const raw = Buffer.from(
      "\u001b[1mbuild\u001b[0m\r10%\r50%\r100%\n\u001b[2K\u001b[1Adone\n",
      "utf8",
    );
    const { receiver, end, ctx, markersSeen } = await runRealBash([
      raw.subarray(0, 12),
      130,
      raw.subarray(12),
      130,
    ]);

    expect(receiver.epoch).toBe(1);
    expect(Buffer.from(receiver.output, "utf8").equals(raw)).toBe(true);
    expect(receiver.cursor).toBe(raw.length);
    expect(toolEnd(end).outputStream).toEqual({ epoch: 1, totalBytes: raw.length });
    // Mid-run, the attach cursor was exactly where the receiver stood.
    expect(markersSeen.length).toBeGreaterThan(0);
    for (const seen of markersSeen) expect(seen.offset).toBe(seen.cursor);
    // Finished streams get no attach marker; the raw log stays servable until turn_end.
    expect(ctx.toolOutputSnapshots.terminal.attachMarkers()).toEqual([]);
    expect(ctx.toolOutputSnapshots.fullOutput("tc")).toBe(raw.toString("utf8"));
  });

  it("keeps one epoch and continues offsets across Pi's switch to its temp file", async () => {
    // Phase 1 text (clean UTF-8) is a byte prefix of the file Pi starts writing at 50 KB.
    const split = Buffer.from("🙂", "utf8");
    const plan = [
      lines(0, 300),
      130,
      lines(300, 700),
      130,
      lines(1000, 400),
      130,
      // A codepoint split across two process writes inside the file phase.
      lines(1400, 5),
      split.subarray(0, 2),
      130,
      split.subarray(2),
      lines(1405, 5),
      130,
    ];
    const raw = Buffer.concat(plan.filter((step): step is Buffer => typeof step !== "number"));
    const { receiver, end, tickBytes, fullOutputPath } = await runRealBash(plan);

    expect(fullOutputPath).toBeDefined();
    const fileBytes = statSync(fullOutputPath!).size;
    expect(fileBytes).toBe(raw.length);
    expect(receiver.output).toBe(raw.toString("utf8"));
    expect(receiver.epoch).toBe(1);
    expect(receiver.resets).toBe(0);
    expect(receiver.cursor).toBe(fileBytes);
    expect(receiver.output).not.toContain("\uFFFD");
    expect(toolEnd(end).outputStream).toEqual({ epoch: 1, totalBytes: fileBytes });
    for (const bytes of tickBytes) expect(bytes).toBeLessThanOrEqual(TERMINAL_TICK_MAX_BYTES);
  });

  it("restarts at a new epoch when phase-1 bytes are not a prefix of the Pi file", async () => {
    // Pi decodes 0xFF to U+FFFD (3 bytes sent) while its file keeps the raw byte.
    const head = Buffer.concat([Buffer.from([0x66, 0xff, 0x67, 0x0a]), lines(0, 80)]);
    const tail = lines(80, 700);
    const raw = Buffer.concat([head, tail]);
    const { receiver, end, fullOutputPath } = await runRealBash([
      head,
      130,
      tail,
      130,
      lines(0, 1),
      130,
    ]);
    const full = Buffer.concat([raw, lines(0, 1)]);

    expect(fullOutputPath).toBeDefined();
    expect(receiver.resets).toBe(1);
    expect(receiver.epoch).toBe(2);
    expect(receiver.cursor).toBe(full.length);
    expect(receiver.output).toBe(full.toString("utf8"));
    expect(toolEnd(end).outputStream).toEqual({ epoch: 2, totalBytes: full.length });
  });

  it("splits a burst at 64 KiB codepoint-aligned chunks, 256 KiB per tick, and drains at end", async () => {
    const burst = lines(0, 8000); // ~600 KB in one process write
    const { receiver, end, tickBytes } = await runRealBash([burst, 130, lines(8000, 3), 130]);
    const full = Buffer.concat([burst, lines(8000, 3)]);

    expect(burst.length).toBeGreaterThan(TERMINAL_TICK_MAX_BYTES * 2);
    for (const bytes of tickBytes) expect(bytes).toBeLessThanOrEqual(TERMINAL_TICK_MAX_BYTES);
    expect(Math.max(...receiver.sizes)).toBeLessThanOrEqual(TERMINAL_CHUNK_MAX_BYTES);
    expect(receiver.output).not.toContain("\uFFFD");
    expect(receiver.epoch).toBe(1);
    expect(receiver.cursor).toBe(full.length);
    expect(receiver.output).toBe(full.toString("utf8"));
    expect(toolEnd(end).outputStream?.totalBytes).toBe(full.length);
  });
});

describe("terminal output stream (translator)", () => {
  const start = (ctx: TranslationContext, toolName = "bash", toolCallId = "tc") =>
    translatePiEvent(event({ type: "tool_execution_start", toolCallId, toolName, args: {} }), ctx);
  const update = (
    ctx: TranslationContext,
    text: string | undefined,
    details?: unknown,
    toolName = "bash",
  ) =>
    translatePiEvent(
      event({
        type: "tool_execution_update",
        toolCallId: "tc",
        toolName,
        partialResult: { content: text === undefined ? [] : [{ type: "text", text }], details },
      }),
      ctx,
    );
  const end = (ctx: TranslationContext, text: string | undefined, details?: unknown) =>
    translatePiEvent(
      event({
        type: "tool_execution_end",
        toolCallId: "tc",
        toolName: "bash",
        result: { content: text === undefined ? [] : [{ type: "text", text }], details },
        isError: false,
      }),
      ctx,
    );

  it("emits contiguous byte offsets from cumulative text and counts bytes, not UTF-16 units", () => {
    const ctx = makeCtx();
    start(ctx);
    expect(update(ctx, "caf\u00e9 \u{1F642}")).toEqual([
      {
        type: "tool_output",
        output: "caf\u00e9 \u{1F642}",
        toolCallId: "tc",
        outputStream: { epoch: 1, offset: 0, bytes: 10 },
      },
    ]);
    expect(update(ctx, "caf\u00e9 \u{1F642}\u001b[31mred")[0]).toMatchObject({
      output: "\u001b[31mred",
      outputStream: { epoch: 1, offset: 10, bytes: 8 },
    });
    expect(update(ctx, "caf\u00e9 \u{1F642}\u001b[31mred")).toEqual([]);
  });

  it("never sends half of a surrogate pair", () => {
    const ctx = makeCtx();
    start(ctx);
    const pair = "\u{1F642}";
    const first = update(ctx, `a${pair[0]}`);
    expect(first[0]).toMatchObject({ output: "a", outputStream: { offset: 0, bytes: 1 } });
    expect(update(ctx, `a${pair}`)[0]).toMatchObject({
      output: pair,
      outputStream: { offset: 1, bytes: 4 },
    });
  });

  it("bumps the epoch when Pi replaces rather than extends its text and no file exists", () => {
    const ctx = makeCtx();
    start(ctx);
    update(ctx, "Generating...");
    const replaced = update(ctx, "Downloading");
    expect(replaced).toEqual([
      expect.objectContaining({
        output: "Downloading",
        outputStream: { epoch: 2, offset: 0, bytes: 11 },
      }),
    ]);
    expect(replaced[0]).not.toHaveProperty("mode");
    // The sidecar snapshot is the current epoch's log.
    expect(ctx.toolOutputSnapshots.fullOutput("tc")).toBe("Downloading");
    const done = end(ctx, "Downloading, done");
    expect(toolOutputs(done)[0]).toMatchObject({
      output: ", done",
      outputStream: { epoch: 2, offset: 11, bytes: 6 },
    });
    expect(toolEnd(done).outputStream).toEqual({ epoch: 2, totalBytes: 17 });
  });

  it("delivers a result that only exists at tool end, including Pi's placeholder text", () => {
    const ctx = makeCtx();
    start(ctx);
    const done = end(ctx, "(no output)");
    expect(toolOutputs(done)[0]).toMatchObject({
      output: "(no output)",
      outputStream: { epoch: 1, offset: 0, bytes: 11 },
    });
    expect(toolEnd(done).outputStream).toEqual({ epoch: 1, totalBytes: 11 });
  });

  it("reports an empty log for a terminal call that produced nothing", () => {
    const ctx = makeCtx();
    start(ctx);
    expect(update(ctx, undefined)).toEqual([]);
    const done = end(ctx, undefined);
    expect(toolOutputs(done)).toEqual([]);
    expect(toolEnd(done).outputStream).toEqual({ epoch: 1, totalBytes: 0 });
  });

  it("does not throttle or tail-replace large terminal output", () => {
    const ctx = makeCtx();
    start(ctx);
    const first = "x".repeat(9000);
    const second = `${first}more`;
    expect(update(ctx, first)).toHaveLength(1);
    // Same millisecond: the removed 150 ms throttle would have skipped this.
    expect(update(ctx, second)).toEqual([
      expect.objectContaining({
        output: "more",
        outputStream: { epoch: 1, offset: 9000, bytes: 4 },
      }),
    ]);
    const done = end(ctx, `${second}!`);
    // No full-text resend, no replace.
    expect(toolOutputs(done)).toEqual([
      expect.objectContaining({ output: "!", outputStream: { epoch: 1, offset: 9004, bytes: 1 } }),
    ]);
    expect(toolEnd(done).outputStream).toEqual({ epoch: 1, totalBytes: 9005 });
  });

  it("leaves non-terminal kinds on the cumulative delta/replace path with ANSI stripped", () => {
    const ctx = makeCtx();
    translatePiEvent(
      event({ type: "tool_execution_start", toolCallId: "tc", toolName: "read", args: {} }),
      ctx,
    );
    const first = update(ctx, "a\u001b[31mb\u001b[2K", undefined, "read");
    expect(first).toEqual([{ type: "tool_output", output: "a\u001b[31mb", toolCallId: "tc" }]);
    const replaced = update(ctx, "zzz", undefined, "read");
    expect(replaced[0]).toMatchObject({ output: "zzz", mode: "replace" });
    expect(replaced[0]).not.toHaveProperty("outputStream");
    expect(ctx.toolOutputSnapshots.terminal.size).toBe(0);
    const done = translatePiEvent(
      event({
        type: "tool_execution_end",
        toolCallId: "tc",
        toolName: "read",
        result: { content: [{ type: "text", text: "zzz" }] },
      }),
      ctx,
    );
    expect(toolEnd(done)).not.toHaveProperty("outputStream");
  });

  it("registers streams by output presentation, not tool name, and tags nested calls", () => {
    const ctx = makeCtx();
    ctx.mobileRenderers.register("run_thing", {
      outputPresentation: { kind: "terminal" },
      renderCall: () => [],
      renderResult: () => [],
    });
    translatePiEvent(
      event({
        type: "tool_execution_start",
        toolCallId: "child",
        parentToolCallId: "parent",
        toolName: "run_thing",
        args: {},
      }),
      ctx,
    );
    expect(ctx.toolOutputSnapshots.terminal.attachMarkers()).toEqual([
      { toolCallId: "child", parentToolCallId: "parent", epoch: 1, offset: 0 },
    ]);
    const out = translatePiEvent(
      event({
        type: "tool_execution_update",
        toolCallId: "child",
        parentToolCallId: "parent",
        toolName: "run_thing",
        partialResult: { content: [{ type: "text", text: "hi" }] },
      }),
      ctx,
    );
    expect(toolOutputs(out)[0]).toMatchObject({
      parentToolCallId: "parent",
      outputStream: { epoch: 1, offset: 0, bytes: 2 },
    });
  });
});

describe("terminal output stream (Pi temp file phase)", () => {
  function fileFixture() {
    const dir = mkdtempSync(join(tmpdir(), "oppi-terminal-stream-"));
    cleanup.push(dir);
    return join(dir, "pi-bash.log");
  }
  const upd = (ctx: TranslationContext, text: string | undefined, path: string) =>
    translatePiEvent(
      event({
        type: "tool_execution_update",
        toolCallId: "tc",
        toolName: "bash",
        partialResult: {
          content: text === undefined ? [] : [{ type: "text", text }],
          details: { truncation: { truncated: true }, fullOutputPath: path },
        },
      }),
      ctx,
    );
  const fin = (ctx: TranslationContext, path: string) =>
    translatePiEvent(
      event({
        type: "tool_execution_end",
        toolCallId: "tc",
        toolName: "bash",
        // Pi's final text carries a truncation footer that is not part of the byte log.
        result: {
          content: [{ type: "text", text: "tail\n\n[Showing lines 1-2. Full output: x]" }],
          details: { truncation: { truncated: true }, fullOutputPath: path },
        },
        isError: false,
      }),
      ctx,
    );
  const begin = (ctx: TranslationContext) =>
    translatePiEvent(
      event({ type: "tool_execution_start", toolCallId: "tc", toolName: "bash", args: {} }),
      ctx,
    );

  it("waits while Pi's write stream lags the update that named the file", () => {
    const ctx = makeCtx();
    const path = fileFixture();
    begin(ctx);
    const sent = toolOutputs(
      translatePiEvent(
        event({
          type: "tool_execution_update",
          toolCallId: "tc",
          toolName: "bash",
          partialResult: { content: [{ type: "text", text: "abcdef" }], details: {} },
        }),
        ctx,
      ),
    );
    expect(sent[0]?.outputStream).toEqual({ epoch: 1, offset: 0, bytes: 6 });
    writeFileSync(path, "abc"); // file shorter than what was already sent
    expect(toolOutputs(upd(ctx, "ignored tail", path)).filter((m) => m.outputStream)).toEqual([]);
    expect(ctx.toolOutputSnapshots.terminal.attachMarkers()[0]).toMatchObject({
      epoch: 1,
      offset: 6,
    });
    writeFileSync(path, "abcdefghij");
    expect(toolOutputs(upd(ctx, "ignored tail", path))[0]).toMatchObject({
      output: "ghij",
      outputStream: { epoch: 1, offset: 6, bytes: 4 },
    });
    expect(ctx.toolOutputSnapshots.terminal.retainedText("tc")).toBeNull();
  });

  it("starts a new epoch from file byte 0 when the file disagrees with what was sent", () => {
    const ctx = makeCtx();
    const path = fileFixture();
    begin(ctx);
    translatePiEvent(
      event({
        type: "tool_execution_update",
        toolCallId: "tc",
        toolName: "bash",
        partialResult: { content: [{ type: "text", text: "abc" }], details: {} },
      }),
      ctx,
    );
    writeFileSync(path, "xyzdef");
    expect(toolOutputs(upd(ctx, "tail", path))[0]).toMatchObject({
      output: "xyzdef",
      outputStream: { epoch: 2, offset: 0, bytes: 6 },
    });
  });

  it("uses file bytes, never partialResult text, once the file is known", () => {
    const ctx = makeCtx();
    const path = fileFixture();
    begin(ctx);
    writeFileSync(path, "line1\nline2\n");
    const first = toolOutputs(upd(ctx, "TOTALLY DIFFERENT TAIL", path));
    expect(first[0]).toMatchObject({
      output: "line1\nline2\n",
      outputStream: { epoch: 1, offset: 0, bytes: 12 },
    });
    appendFileSync(path, "line3\n");
    expect(toolOutputs(upd(ctx, "ANOTHER TAIL", path))[0]).toMatchObject({
      output: "line3\n",
      outputStream: { epoch: 1, offset: 12, bytes: 6 },
    });
  });

  it("drains at tool end, reports the file size, and ignores the result footer", () => {
    const ctx = makeCtx();
    const path = fileFixture();
    begin(ctx);
    writeFileSync(path, "one\n");
    upd(ctx, "one\n", path);
    appendFileSync(path, "two\nthree\n");
    const done = fin(ctx, path);
    expect(toolOutputs(done)).toEqual([
      expect.objectContaining({
        output: "two\nthree\n",
        outputStream: { epoch: 1, offset: 4, bytes: 10 },
      }),
    ]);
    expect(toolEnd(done).outputStream).toEqual({ epoch: 1, totalBytes: 14 });
    expect(ctx.toolOutputSnapshots.fullOutput("tc")).toBeNull();
    expect(ctx.toolOutputSnapshots.terminal.attachMarkers()).toEqual([]);
  });

  it("caps a tick at 256 KiB and the end drain, leaving the rest to sidecar gap fill", () => {
    const ctx = makeCtx();
    const path = fileFixture();
    begin(ctx);
    const row = "0123456789abcdef\n".repeat(1024); // 17408 bytes
    writeFileSync(path, row.repeat(40)); // 696320 bytes
    const tick = toolOutputs(upd(ctx, undefined, path));
    const tickBytes = tick.reduce((sum, m) => sum + (m.outputStream?.bytes ?? 0), 0);
    expect(tickBytes).toBeLessThanOrEqual(TERMINAL_TICK_MAX_BYTES);
    expect(tickBytes).toBeGreaterThan(TERMINAL_TICK_MAX_BYTES - TERMINAL_CHUNK_MAX_BYTES);
    expect(tick.length).toBeGreaterThan(3);

    appendFileSync(path, Buffer.alloc(TERMINAL_END_DRAIN_MAX_BYTES + 100_000, 0x61));
    const size = statSync(path).size;
    const done = fin(ctx, path);
    const drained = toolOutputs(done).reduce((sum, m) => sum + (m.outputStream?.bytes ?? 0), 0);
    expect(drained).toBeLessThanOrEqual(TERMINAL_END_DRAIN_MAX_BYTES);
    expect(toolEnd(done).outputStream?.totalBytes).toBe(size);
    expect(tickBytes + drained).toBeLessThan(size);
  });

  it("aligns chunk boundaries to UTF-8 codepoints at the 64 KiB cut", () => {
    const ctx = makeCtx();
    const path = fileFixture();
    begin(ctx);
    // Offset by one byte so a 3-byte codepoint straddles every 64 KiB cut.
    const body = `a${"\u2713".repeat(60_000)}`;
    writeFileSync(path, body);
    const receiver = new StreamReceiver();
    const sent: ServerMessage[] = [];
    sent.push(...upd(ctx, undefined, path), ...fin(ctx, path));
    for (const message of sent) receiver.accept(message);
    expect(receiver.output).toBe(body);
    expect(receiver.cursor).toBe(Buffer.byteLength(body));
    expect(receiver.sizes.every((n) => n <= TERMINAL_CHUNK_MAX_BYTES)).toBe(true);
  });
});

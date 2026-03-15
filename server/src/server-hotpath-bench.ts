/**
 * Comprehensive server hot-path benchmark.
 *
 * Measures all critical-path functions that sit between a pi agent event
 * and the user seeing pixels on iOS. Every microsecond saved here directly
 * reduces TTFT and streaming latency.
 *
 * Hot paths measured:
 *   1. translatePiEvent (session-protocol.ts) — event → ServerMessage translation
 *   2. MobileRendererRegistry.renderCall/renderResult (mobile-renderer.ts)
 *   3. sanitizeToolResultDetails (visual-schema.ts) — dynamic UI sanitization
 *   4. EventRing.push + EventRing.since (event-ring.ts) — durable sequencing + catch-up
 *   5. SessionBroadcaster.broadcast (session-broadcast.ts) — fan-out
 *   6. stripAnsiEscapes (ansi.ts) — tool output cleaning
 *
 * Each path is exercised with realistic payloads at realistic volume.
 */

import { translatePiEvent, type TranslationContext } from "./session-protocol.js";
import { MobileRendererRegistry } from "./mobile-renderer.js";
import { sanitizeToolResultDetails } from "./visual-schema.js";
import { EventRing } from "./event-ring.js";
import { SessionBroadcaster, type BroadcastSessionState } from "./session-broadcast.js";
import { stripAnsiEscapes } from "./ansi.js";
import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";
import type { ServerMessage, Session } from "./types.js";

// ─── Config ───

const WARMUP_ITERATIONS = 500;
const BENCH_ITERATIONS = 5_000;

// ─── Realistic Test Data ───

function makeCtx(renderers?: MobileRendererRegistry): TranslationContext {
  return {
    sessionId: "bench-session-001",
    partialResults: new Map(),
    streamedAssistantText: "",
    hasStreamedThinking: false,
    mobileRenderers: renderers,
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingArgPreviews: new Set(),
  };
}

function makeSession(): Session {
  return {
    id: "bench-session-001",
    status: "busy",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 5,
    tokens: { input: 1200, output: 800 },
    cost: 0.05,
  } as Session;
}

// Realistic pi agent events that exercise different code paths
const TEXT_DELTA_EVENT: AgentSessionEvent = {
  type: "message_update",
  assistantMessageEvent: {
    type: "text_delta",
    delta: "Here is a code snippet that implements the binary search algorithm:\n\n```typescript\n",
  },
} as AgentSessionEvent;

const THINKING_DELTA_EVENT: AgentSessionEvent = {
  type: "message_update",
  assistantMessageEvent: {
    type: "thinking_delta",
    delta: "The user wants to optimize the event pipeline. Let me analyze the critical path from translatePiEvent through to broadcast...",
  },
} as AgentSessionEvent;

const TOOL_EXECUTION_START_EVENT: AgentSessionEvent = {
  type: "tool_execution_start",
  toolCallId: "tc_bench_001",
  toolName: "bash",
  args: {
    command: 'grep -rn "performance" server/src --include="*.ts" | head -20',
  },
} as AgentSessionEvent;

// Simulated bash output with ANSI escapes (realistic terminal output)
const ANSI_RICH_OUTPUT =
  "\x1b[1;32mserver/src/types.ts\x1b[0m:\x1b[33m42\x1b[0m: * Performance metrics for chat pipeline\n" +
  "\x1b[1;32mserver/src/session-protocol.ts\x1b[0m:\x1b[33m128\x1b[0m: // Hot path — called for every agent event\n" +
  "\x1b[1;32mserver/src/mobile-renderer.ts\x1b[0m:\x1b[33m55\x1b[0m: /** Pre-renders styled summary segments */\n" +
  "\x1b[36m~\x1b[0m\n".repeat(20);

const TOOL_UPDATE_EVENT: AgentSessionEvent = {
  type: "tool_execution_update",
  toolCallId: "tc_bench_001",
  partialResult: {
    content: [{ type: "text", text: ANSI_RICH_OUTPUT }],
  },
} as AgentSessionEvent;

const TOOL_END_EVENT: AgentSessionEvent = {
  type: "tool_execution_end",
  toolCallId: "tc_bench_001",
  toolName: "bash",
  result: {
    content: [{ type: "text", text: ANSI_RICH_OUTPUT }],
    details: {
      exitCode: 0,
      truncation: { truncated: false, outputLines: 23, totalLines: 23 },
    },
  },
} as AgentSessionEvent;

const AGENT_START_EVENT: AgentSessionEvent = {
  type: "agent_start",
} as AgentSessionEvent;

const AGENT_END_EVENT: AgentSessionEvent = {
  type: "agent_end",
} as AgentSessionEvent;

// Streaming tool call (write with content)
const TOOLCALL_DELTA_EVENT: AgentSessionEvent = {
  type: "message_update",
  assistantMessageEvent: {
    type: "toolcall_delta",
    contentIndex: 0,
  },
  message: {
    role: "assistant",
    content: [
      {
        type: "toolCall",
        id: "tc_write_001",
        name: "write",
        arguments: {
          path: "server/src/new-file.ts",
          content: 'export function optimized(): string {\n  return "fast";\n}\n',
        },
      },
    ],
  },
} as unknown as AgentSessionEvent;

// Read tool execution
const READ_TOOL_START: AgentSessionEvent = {
  type: "tool_execution_start",
  toolCallId: "tc_read_001",
  toolName: "read",
  args: {
    path: "server/src/session-protocol.ts",
    offset: 1,
    limit: 50,
  },
} as AgentSessionEvent;

// Edit tool execution
const EDIT_TOOL_START: AgentSessionEvent = {
  type: "tool_execution_start",
  toolCallId: "tc_edit_001",
  toolName: "edit",
  args: {
    path: "server/src/event-ring.ts",
    oldText: "const capacity = 500;",
    newText: "const capacity = 1000;",
  },
} as AgentSessionEvent;

// Chart payload for visual-schema
const CHART_DETAILS = {
  ui: [
    {
      kind: "chart",
      version: 1,
      title: "Benchmark Results",
      spec: {
        title: "Event Pipeline Throughput",
        dataset: {
          rows: Array.from({ length: 200 }, (_, i) => ({
            run: i + 1,
            throughput: 50000 + Math.random() * 10000,
            latency_us: 15 + Math.random() * 5,
            status: i % 3 === 0 ? "keep" : "discard",
          })),
        },
        marks: [
          { type: "line", x: "run", y: "throughput", label: "throughput" },
          { type: "point", x: "run", y: "throughput", series: "status" },
          { type: "rule", yValue: 55000, label: "baseline" },
        ],
        axes: {
          x: { label: "Run" },
          y: { label: "events/sec" },
        },
        renderHints: {
          xAxis: { type: "numeric" },
          yAxis: { zeroBaseline: "never" },
          legend: { mode: "hide" },
        },
        colorScale: { keep: "#22C55E", discard: "#EF4444" },
        annotations: [
          { x: 50, y: 58000, text: "Optimization A", anchor: "top" },
          { x: 120, y: 62000, text: "Optimization B" },
        ],
      },
    },
  ],
  expandedText: "200 runs, best throughput: 62,000 events/sec",
  presentationFormat: "markdown",
};

// Larger ANSI content for stripAnsiEscapes benchmark
const LARGE_ANSI_CONTENT = Array.from(
  { length: 100 },
  (_, i) =>
    `\x1b[1;${31 + (i % 6)}m${"/path/to/file".repeat(3)}\x1b[0m:\x1b[33m${i}\x1b[0m: ${"x".repeat(80)}\n`,
).join("");

// ─── Benchmark Runner ───

interface BenchResult {
  name: string;
  totalUs: number;
  iterationsPerSecond: number;
  avgUs: number;
  p50Us: number;
  p99Us: number;
  minUs: number;
  maxUs: number;
}

function runBench(name: string, iterations: number, fn: () => void): BenchResult {
  // Warmup
  for (let i = 0; i < WARMUP_ITERATIONS; i++) fn();

  // Collect per-iteration timings
  const timings: number[] = new Array(iterations);
  const t0 = process.hrtime.bigint();

  for (let i = 0; i < iterations; i++) {
    const start = process.hrtime.bigint();
    fn();
    timings[i] = Number(process.hrtime.bigint() - start) / 1000; // ns → us
  }

  const totalNs = Number(process.hrtime.bigint() - t0);
  const totalUs = totalNs / 1000;

  // Sort for percentiles
  timings.sort((a, b) => a - b);

  return {
    name,
    totalUs,
    iterationsPerSecond: Math.round((iterations / totalNs) * 1e9),
    avgUs: totalUs / iterations,
    p50Us: timings[Math.floor(iterations * 0.5)],
    p99Us: timings[Math.floor(iterations * 0.99)],
    minUs: timings[0],
    maxUs: timings[iterations - 1],
  };
}

// ─── Benchmark Suites ───

function benchTranslatePiEvent(renderers: MobileRendererRegistry): BenchResult[] {
  const results: BenchResult[] = [];

  // 1. text_delta (highest frequency — every token)
  // Uses shared context like production: context is created once per session,
  // reused for every event within a turn.
  const textDeltaCtx = makeCtx(renderers);
  results.push(
    runBench("translate:text_delta", BENCH_ITERATIONS, () => {
      textDeltaCtx.streamedAssistantText = "";
      translatePiEvent(TEXT_DELTA_EVENT, textDeltaCtx);
    }),
  );

  // 2. thinking_delta
  const thinkingCtx = makeCtx(renderers);
  results.push(
    runBench("translate:thinking_delta", BENCH_ITERATIONS, () => {
      thinkingCtx.hasStreamedThinking = false;
      translatePiEvent(THINKING_DELTA_EVENT, thinkingCtx);
    }),
  );

  // 3. tool_execution_start (bash)
  const toolStartCtx = makeCtx(renderers);
  results.push(
    runBench("translate:tool_start:bash", BENCH_ITERATIONS, () => {
      toolStartCtx.toolNames.clear();
      toolStartCtx.streamingArgPreviews.clear();
      translatePiEvent(TOOL_EXECUTION_START_EVENT, toolStartCtx);
    }),
  );

  // 4. tool_execution_update with ANSI content
  const toolUpdateCtx = makeCtx(renderers);
  results.push(
    runBench("translate:tool_update:ansi", BENCH_ITERATIONS, () => {
      toolUpdateCtx.toolNames.set("tc_bench_001", "bash");
      toolUpdateCtx.partialResults.delete("tc_bench_001");
      translatePiEvent(TOOL_UPDATE_EVENT, toolUpdateCtx);
    }),
  );

  // 5. tool_execution_end with details
  const toolEndCtx = makeCtx(renderers);
  results.push(
    runBench("translate:tool_end:bash", BENCH_ITERATIONS, () => {
      toolEndCtx.toolNames.set("tc_bench_001", "bash");
      toolEndCtx.partialResults.set("tc_bench_001", ANSI_RICH_OUTPUT.slice(0, 100));
      toolEndCtx.shellPreviewLastSent.delete("tc_bench_001");
      translatePiEvent(TOOL_END_EVENT, toolEndCtx);
    }),
  );

  // 6. toolcall_delta (write streaming)
  const toolcallCtx = makeCtx(renderers);
  results.push(
    runBench("translate:toolcall_delta:write", BENCH_ITERATIONS, () => {
      translatePiEvent(TOOLCALL_DELTA_EVENT, toolcallCtx);
    }),
  );

  // 7. tool_execution_start (read — with path shortening)
  const readCtx = makeCtx(renderers);
  results.push(
    runBench("translate:tool_start:read", BENCH_ITERATIONS, () => {
      readCtx.toolNames.clear();
      readCtx.streamingArgPreviews.clear();
      translatePiEvent(READ_TOOL_START, readCtx);
    }),
  );

  // 8. tool_execution_start (edit)
  const editCtx = makeCtx(renderers);
  results.push(
    runBench("translate:tool_start:edit", BENCH_ITERATIONS, () => {
      editCtx.toolNames.clear();
      editCtx.streamingArgPreviews.clear();
      translatePiEvent(EDIT_TOOL_START, editCtx);
    }),
  );

  // 9. Full turn sequence (realistic mix)
  results.push(
    runBench("translate:full_turn", BENCH_ITERATIONS, () => {
      const ctx = makeCtx(renderers);
      translatePiEvent(AGENT_START_EVENT, ctx);
      translatePiEvent(TEXT_DELTA_EVENT, ctx);
      translatePiEvent(TEXT_DELTA_EVENT, ctx);
      translatePiEvent(TEXT_DELTA_EVENT, ctx);
      translatePiEvent(THINKING_DELTA_EVENT, ctx);
      translatePiEvent(TOOL_EXECUTION_START_EVENT, ctx);
      translatePiEvent(TOOL_UPDATE_EVENT, ctx);
      translatePiEvent(TOOL_UPDATE_EVENT, ctx);
      translatePiEvent(TOOL_END_EVENT, ctx);
      translatePiEvent(AGENT_END_EVENT, ctx);
    }),
  );

  return results;
}

function benchMobileRenderer(): BenchResult[] {
  const registry = new MobileRendererRegistry();
  const results: BenchResult[] = [];

  // renderCall for each built-in tool
  const toolArgs: [string, Record<string, unknown>][] = [
    ["bash", { command: 'grep -rn "foo" server/src --include="*.ts"' }],
    ["read", { path: "/Users/alice/workspace/project/src/main.ts", offset: 10, limit: 50 }],
    ["edit", { path: "/Users/alice/workspace/project/src/main.ts", oldText: "old", newText: "new" }],
    ["write", { path: "/Users/alice/workspace/project/src/new.ts", content: "export const x = 1;" }],
    ["grep", { pattern: "TODO", path: ".", glob: "*.ts" }],
    ["find", { pattern: "*.swift", path: "/Users/alice/workspace/ios" }],
    ["ls", { path: "/Users/alice/workspace/project/src" }],
    ["todo", { action: "list", title: "Fix the benchmark" }],
    ["plot", { spec: { marks: [{ type: "line" }], dataset: { rows: [{ x: 1, y: 2 }] } } }],
  ];

  for (const [tool, args] of toolArgs) {
    results.push(
      runBench(`renderer:call:${tool}`, BENCH_ITERATIONS, () => {
        registry.renderCall(tool, args);
      }),
    );
  }

  // renderResult for bash with exit code
  results.push(
    runBench("renderer:result:bash", BENCH_ITERATIONS, () => {
      registry.renderResult("bash", { exitCode: 0 }, false);
    }),
  );

  // renderResult for read with truncation
  results.push(
    runBench("renderer:result:read_trunc", BENCH_ITERATIONS, () => {
      registry.renderResult(
        "read",
        { truncation: { truncated: true, outputLines: 200, totalLines: 500 } },
        false,
      );
    }),
  );

  return results;
}

function benchVisualSchema(): BenchResult[] {
  const results: BenchResult[] = [];

  // 1. Chart with 200 rows (typical autoresearch)
  results.push(
    runBench("sanitize:chart_200rows", BENCH_ITERATIONS, () => {
      sanitizeToolResultDetails(CHART_DETAILS);
    }),
  );

  // 2. Simple details (no UI)
  results.push(
    runBench("sanitize:simple_details", BENCH_ITERATIONS, () => {
      sanitizeToolResultDetails({ exitCode: 0, truncation: { truncated: false } });
    }),
  );

  // 3. Null/undefined details
  results.push(
    runBench("sanitize:null", BENCH_ITERATIONS, () => {
      sanitizeToolResultDetails(null);
    }),
  );

  // 4. Large chart (1000 rows)
  const largeChart = {
    ui: [
      {
        kind: "chart",
        version: 1,
        title: "Large Dataset",
        spec: {
          dataset: {
            rows: Array.from({ length: 1000 }, (_, i) => ({
              x: i,
              y: Math.random() * 100,
              z: `label_${i}`,
            })),
          },
          marks: [
            { type: "line", x: "x", y: "y" },
            { type: "point", x: "x", y: "y" },
          ],
        },
      },
    ],
  };
  results.push(
    runBench("sanitize:chart_1000rows", BENCH_ITERATIONS / 5, () => {
      sanitizeToolResultDetails(largeChart);
    }),
  );

  return results;
}

function benchEventRing(): BenchResult[] {
  const results: BenchResult[] = [];

  // 1. Push events (includes ring construction — setup cost)
  results.push(
    runBench("ring:push_500", BENCH_ITERATIONS, () => {
      const ring = new EventRing(500);
      for (let i = 1; i <= 500; i++) {
        ring.push({
          seq: i,
          event: { type: "text_delta", delta: "token " } as ServerMessage,
          timestamp: Date.now(),
        });
      }
    }),
  );

  // 1b. Single push into full ring (realistic hot-path cost per event)
  let pushSeq = 501;
  const pushRing = new EventRing(500);
  for (let i = 1; i <= 500; i++) {
    pushRing.push({
      seq: i,
      event: { type: "text_delta", delta: "token " } as ServerMessage,
      timestamp: Date.now(),
    });
  }
  results.push(
    runBench("ring:push_single", BENCH_ITERATIONS, () => {
      pushRing.push({
        seq: pushSeq++,
        event: { type: "text_delta", delta: "token " } as ServerMessage,
        timestamp: Date.now(),
      });
    }),
  );

  // 2. Catch-up query (full ring, recent miss)
  const fullRing = new EventRing(500);
  for (let i = 1; i <= 500; i++) {
    fullRing.push({
      seq: i,
      event: { type: "text_delta", delta: `token ${i}` } as ServerMessage,
      timestamp: Date.now(),
    });
  }

  results.push(
    runBench("ring:since_recent", BENCH_ITERATIONS, () => {
      fullRing.since(490); // 10 events to catch up
    }),
  );

  results.push(
    runBench("ring:since_old", BENCH_ITERATIONS, () => {
      fullRing.since(100); // 400 events to catch up
    }),
  );

  results.push(
    runBench("ring:canServe", BENCH_ITERATIONS, () => {
      fullRing.canServe(50);
      fullRing.canServe(490);
      fullRing.canServe(0);
    }),
  );

  return results;
}

function benchBroadcaster(): BenchResult[] {
  const results: BenchResult[] = [];

  // Shared setup — in production, broadcaster + state already exist
  const ephSessions = new Map<string, BroadcastSessionState>();
  const ephBroadcaster = new SessionBroadcaster(
    {
      getActiveSession: (key) => ephSessions.get(key),
      emitSessionEvent: () => {},
      saveSession: () => {},
    },
    1000,
  );
  const ephSession = makeSession();
  const ephState: BroadcastSessionState = {
    session: ephSession,
    subscribers: new Set(),
    seq: 0,
    eventRing: new EventRing(500),
  };
  ephState.subscribers.add(() => {});
  ephState.subscribers.add(() => {});
  ephState.subscribers.add(() => {});
  ephSessions.set(ephSession.id, ephState);

  // Ephemeral broadcast (text_delta — highest frequency)
  results.push(
    runBench("broadcast:ephemeral", BENCH_ITERATIONS, () => {
      ephBroadcaster.broadcast(ephSession.id, { type: "text_delta", delta: "hello " } as ServerMessage);
    }),
  );

  // Durable broadcast (tool_start — needs sequencing + ring push)
  const durSessions = new Map<string, BroadcastSessionState>();
  const durBroadcaster = new SessionBroadcaster(
    {
      getActiveSession: (key) => durSessions.get(key),
      emitSessionEvent: () => {},
      saveSession: () => {},
    },
    1000,
  );
  const durSession = makeSession();
  durSession.id = "dur-bench-session";
  const durState: BroadcastSessionState = {
    session: durSession,
    subscribers: new Set(),
    seq: 0,
    eventRing: new EventRing(500),
  };
  durState.subscribers.add(() => {});
  durState.subscribers.add(() => {});
  durSessions.set(durSession.id, durState);

  results.push(
    runBench("broadcast:durable", BENCH_ITERATIONS, () => {
      durBroadcaster.broadcast(durSession.id, {
        type: "tool_start",
        tool: "bash",
        args: { command: "ls" },
        toolCallId: "tc_001",
      } as ServerMessage);
    }),
  );

  return results;
}

function benchAnsiStrip(): BenchResult[] {
  const results: BenchResult[] = [];

  // Small content with ANSI
  results.push(
    runBench("ansi:small", BENCH_ITERATIONS, () => {
      stripAnsiEscapes(ANSI_RICH_OUTPUT);
    }),
  );

  // Large content with many ANSI sequences
  results.push(
    runBench("ansi:large_100lines", BENCH_ITERATIONS, () => {
      stripAnsiEscapes(LARGE_ANSI_CONTENT);
    }),
  );

  // No ANSI (should be fast — no work to do)
  const plainText = "No ANSI escapes here, just plain text.\n".repeat(50);
  results.push(
    runBench("ansi:plain_50lines", BENCH_ITERATIONS, () => {
      stripAnsiEscapes(plainText);
    }),
  );

  return results;
}

// ─── Main ───

function main() {
  const renderers = new MobileRendererRegistry();

  const allResults: BenchResult[] = [];

  // Run all benchmark suites
  console.error("Running translate benchmarks...");
  allResults.push(...benchTranslatePiEvent(renderers));

  console.error("Running mobile renderer benchmarks...");
  allResults.push(...benchMobileRenderer());

  console.error("Running visual schema benchmarks...");
  allResults.push(...benchVisualSchema());

  console.error("Running event ring benchmarks...");
  allResults.push(...benchEventRing());

  console.error("Running broadcaster benchmarks...");
  allResults.push(...benchBroadcaster());

  console.error("Running ANSI strip benchmarks...");
  allResults.push(...benchAnsiStrip());

  // Output METRIC lines for autoresearch
  let totalUs = 0;
  const categoryTotals = new Map<string, number>();

  for (const r of allResults) {
    const category = r.name.split(":")[0];
    categoryTotals.set(category, (categoryTotals.get(category) ?? 0) + r.avgUs);
    totalUs += r.avgUs;
  }

  // Primary metric: sum of all avg latencies (lower is better)
  console.log(`METRIC total_avg_us=${totalUs.toFixed(2)}`);

  // Category subtotals
  for (const [cat, total] of categoryTotals) {
    console.log(`METRIC ${cat}_us=${total.toFixed(2)}`);
  }

  // Individual metrics
  for (const r of allResults) {
    console.log(`METRIC ${r.name.replace(/:/g, "_")}_avg_us=${r.avgUs.toFixed(2)}`);
    console.log(`METRIC ${r.name.replace(/:/g, "_")}_p99_us=${r.p99Us.toFixed(2)}`);
  }

  // Human-readable table
  console.error("\n─── Results ───");
  console.error(
    `${"Benchmark".padEnd(40)} ${"avg".padStart(10)} ${"p50".padStart(10)} ${"p99".padStart(10)} ${"ops/s".padStart(12)}`,
  );
  console.error("─".repeat(85));
  for (const r of allResults) {
    console.error(
      `${r.name.padEnd(40)} ${r.avgUs.toFixed(2).padStart(9)}μs ${r.p50Us.toFixed(2).padStart(9)}μs ${r.p99Us.toFixed(2).padStart(9)}μs ${r.iterationsPerSecond.toLocaleString().padStart(12)}`,
    );
  }
  console.error("─".repeat(85));
  console.error(
    `${"TOTAL (sum of averages)".padEnd(40)} ${totalUs.toFixed(2).padStart(9)}μs`,
  );

  // Category breakdown
  console.error("\n─── Category Breakdown ───");
  const sorted = [...categoryTotals.entries()].sort((a, b) => b[1] - a[1]);
  for (const [cat, total] of sorted) {
    const pct = ((total / totalUs) * 100).toFixed(1);
    console.error(`  ${cat.padEnd(20)} ${total.toFixed(2).padStart(10)}μs  (${pct}%)`);
  }
}

main();

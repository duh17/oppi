#!/usr/bin/env npx tsx
/**
 * Lightweight load + reliability harness for oppi-server.
 *
 * Measures:
 * 1) HTTP /health throughput + latency
 * 2) WebSocket connect latency + get_state RTT under reconnect churn
 *
 * WebSocket benchmark is optional and requires auth/session context.
 *
 * Usage:
 *   npx tsx scripts/manual/load-ws.ts
 *   npx tsx scripts/manual/load-ws.ts --host 127.0.0.1 --port 7749
 *   npx tsx scripts/manual/load-ws.ts --token <token> --workspace <workspaceId> --session <sessionId>
 *
 * Environment variables (equivalent):
 *   LOAD_HOST, LOAD_PORT
 *   LOAD_HTTP_WORKERS, LOAD_HTTP_DURATION_MS
 *   LOAD_TOKEN, LOAD_WORKSPACE_ID, LOAD_SESSION_ID
 *   LOAD_WS_CLIENTS, LOAD_WS_CONNECTIONS_PER_CLIENT, LOAD_WS_REQUESTS_PER_CONNECTION
 *   LOAD_WS_DROP_RATE, LOAD_WS_TIMEOUT_MS
 */

import { performance } from "node:perf_hooks";
import WebSocket from "ws";

interface BenchConfig {
  host: string;
  port: number;

  httpWorkers: number;
  httpDurationMs: number;

  token?: string;
  workspaceId?: string;
  sessionId?: string;

  wsClients: number;
  wsConnectionsPerClient: number;
  wsRequestsPerConnection: number;
  wsDropRate: number;
  wsTimeoutMs: number;
}

interface Summary {
  count: number;
  minMs: number;
  maxMs: number;
  avgMs: number;
  p50Ms: number;
  p95Ms: number;
  p99Ms: number;
}

interface HttpWorkerResult {
  ok: number;
  fail: number;
  latencies: number[];
}

interface WsWorkerResult {
  connectOk: number;
  connectFail: number;
  connectLatencies: number[];

  requestTotal: number;
  requestOk: number;
  requestFail: number;
  requestTimeout: number;
  stateLatencies: number[];

  dropAttempts: number;
  dropDisconnects: number;
  dropWonRace: number;
}

function getArg(name: string): string | undefined {
  const key = `--${name}`;
  const idx = process.argv.indexOf(key);
  if (idx < 0 || idx + 1 >= process.argv.length) {
    return undefined;
  }
  return process.argv[idx + 1];
}

function argOrEnv(name: string, envKey: string, fallback?: string): string | undefined {
  const arg = getArg(name);
  if (arg !== undefined) {
    return arg;
  }
  const env = process.env[envKey];
  if (env !== undefined) {
    return env;
  }
  return fallback;
}

function parseNumber(name: string, envKey: string, fallback: number): number {
  const raw = argOrEnv(name, envKey, String(fallback));
  const value = Number.parseFloat(raw ?? "");
  return Number.isFinite(value) ? value : fallback;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) {
    return 0;
  }

  const index = (sorted.length - 1) * p;
  const lo = Math.floor(index);
  const hi = Math.ceil(index);
  if (lo === hi) {
    return sorted[lo];
  }

  const weight = index - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * weight;
}

function summarize(samples: number[]): Summary | undefined {
  if (samples.length === 0) {
    return undefined;
  }

  const sorted = [...samples].sort((a, b) => a - b);
  let total = 0;
  for (const n of sorted) {
    total += n;
  }

  return {
    count: sorted.length,
    minMs: sorted[0],
    maxMs: sorted[sorted.length - 1],
    avgMs: total / sorted.length,
    p50Ms: percentile(sorted, 0.50),
    p95Ms: percentile(sorted, 0.95),
    p99Ms: percentile(sorted, 0.99),
  };
}

function printSummary(label: string, summary: Summary | undefined): void {
  if (!summary) {
    console.log(`${label}: n/a`);
    return;
  }

  console.log(
    `${label}: n=${summary.count}, avg=${summary.avgMs.toFixed(2)}ms, `
      + `p50=${summary.p50Ms.toFixed(2)}ms, p95=${summary.p95Ms.toFixed(2)}ms, `
      + `p99=${summary.p99Ms.toFixed(2)}ms, max=${summary.maxMs.toFixed(2)}ms`,
  );
}

function typeFromRaw(raw: WebSocket.RawData): string | undefined {
  const text = typeof raw === "string"
    ? raw
    : Buffer.isBuffer(raw)
      ? raw.toString("utf-8")
      : Array.isArray(raw)
        ? Buffer.concat(raw).toString("utf-8")
        : raw.toString();

  try {
    const parsed = JSON.parse(text) as { type?: unknown };
    if (typeof parsed.type === "string") {
      return parsed.type;
    }
  } catch {
    // ignore malformed messages
  }

  return undefined;
}

function closeWsQuietly(ws: WebSocket): Promise<void> {
  return new Promise((resolve) => {
    if (ws.readyState === WebSocket.CLOSED) {
      resolve();
      return;
    }

    const timer = setTimeout(() => resolve(), 500);
    ws.once("close", () => {
      clearTimeout(timer);
      resolve();
    });

    try {
      ws.close();
    } catch {
      clearTimeout(timer);
      resolve();
    }
  });
}

async function runHttpWorker(baseUrl: string, durationMs: number): Promise<HttpWorkerResult> {
  const deadline = performance.now() + durationMs;
  const latencies: number[] = [];
  let ok = 0;
  let fail = 0;

  while (performance.now() < deadline) {
    const started = performance.now();
    try {
      const res = await fetch(`${baseUrl}/health`);
      const elapsed = performance.now() - started;
      latencies.push(elapsed);

      if (res.ok) {
        ok += 1;
      } else {
        fail += 1;
      }
    } catch {
      const elapsed = performance.now() - started;
      latencies.push(elapsed);
      fail += 1;
    }
  }

  return { ok, fail, latencies };
}

async function runHttpBenchmark(config: BenchConfig): Promise<void> {
  const baseUrl = `http://${config.host}:${config.port}`;
  console.log("\n━━ HTTP /health benchmark ━━");
  console.log(`target=${baseUrl}`);
  console.log(`workers=${config.httpWorkers}, duration=${config.httpDurationMs}ms`);

  const started = performance.now();
  const workers = Array.from(
    { length: config.httpWorkers },
    () => runHttpWorker(baseUrl, config.httpDurationMs),
  );

  const results = await Promise.all(workers);
  const elapsedMs = performance.now() - started;

  let ok = 0;
  let fail = 0;
  const latencies: number[] = [];
  for (const r of results) {
    ok += r.ok;
    fail += r.fail;
    latencies.push(...r.latencies);
  }

  const reqTotal = ok + fail;
  const reqPerSec = reqTotal / (elapsedMs / 1000);

  console.log(`requests=${reqTotal}, ok=${ok}, fail=${fail}, rps=${reqPerSec.toFixed(1)}`);
  printSummary("latency", summarize(latencies));
}

function connectWs(
  wsUrl: string,
  token: string,
  timeoutMs: number,
): Promise<{ ws: WebSocket; connectMs: number }> {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const ws = new WebSocket(wsUrl, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    let settled = false;

    const timeout = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        ws.terminate();
      } catch {
        // ignore
      }
      reject(new Error("connect-timeout"));
    }, timeoutMs);

    const cleanup = (): void => {
      clearTimeout(timeout);
      ws.off("message", onMessage);
      ws.off("error", onError);
      ws.off("close", onClose);
    };

    const onMessage = (raw: WebSocket.RawData): void => {
      if (settled) {
        return;
      }
      const type = typeFromRaw(raw);
      if (type === "connected" || type === "state") {
        settled = true;
        cleanup();
        resolve({ ws, connectMs: performance.now() - started });
      } else if (type === "error") {
        settled = true;
        cleanup();
        reject(new Error("server-error-on-connect"));
      }
    };

    const onError = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error("socket-error"));
    };

    const onClose = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error("closed-before-ready"));
    };

    ws.on("message", onMessage);
    ws.once("error", onError);
    ws.once("close", onClose);
  });
}

function requestStateRoundTrip(
  ws: WebSocket,
  timeoutMs: number,
  dropMidFlight: boolean,
): Promise<number> {
  return new Promise((resolve, reject) => {
    if (ws.readyState !== WebSocket.OPEN) {
      reject(new Error("not-open"));
      return;
    }

    let settled = false;
    const started = performance.now();

    const timeout = setTimeout(() => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error("request-timeout"));
    }, timeoutMs);

    const cleanup = (): void => {
      clearTimeout(timeout);
      ws.off("message", onMessage);
      ws.off("close", onClose);
      ws.off("error", onError);
    };

    const onMessage = (raw: WebSocket.RawData): void => {
      if (settled) {
        return;
      }
      const type = typeFromRaw(raw);
      if (type === "state") {
        settled = true;
        cleanup();
        resolve(performance.now() - started);
      }
    };

    const onClose = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error("closed"));
    };

    const onError = (): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error("socket-error"));
    };

    ws.on("message", onMessage);
    ws.once("close", onClose);
    ws.once("error", onError);

    ws.send(JSON.stringify({ type: "get_state" }), (err) => {
      if (settled) {
        return;
      }
      if (err) {
        settled = true;
        cleanup();
        reject(new Error("send-failed"));
      }
    });

    if (dropMidFlight) {
      setTimeout(() => {
        if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
          try {
            ws.terminate();
          } catch {
            // ignore
          }
        }
      }, 1);
    }
  });
}

async function runWsWorker(workerId: number, config: BenchConfig): Promise<WsWorkerResult> {
  const token = config.token;
  const workspaceId = config.workspaceId;
  const sessionId = config.sessionId;
  if (!token || !workspaceId || !sessionId) {
    throw new Error("ws worker missing token/workspaceId/sessionId");
  }

  const wsUrl = `ws://${config.host}:${config.port}/workspaces/${workspaceId}/sessions/${sessionId}/stream`;

  const result: WsWorkerResult = {
    connectOk: 0,
    connectFail: 0,
    connectLatencies: [],

    requestTotal: 0,
    requestOk: 0,
    requestFail: 0,
    requestTimeout: 0,
    stateLatencies: [],

    dropAttempts: 0,
    dropDisconnects: 0,
    dropWonRace: 0,
  };

  for (let conn = 0; conn < config.wsConnectionsPerClient; conn += 1) {
    let ws: WebSocket | null = null;

    try {
      const opened = await connectWs(wsUrl, token, config.wsTimeoutMs);
      ws = opened.ws;
      result.connectOk += 1;
      result.connectLatencies.push(opened.connectMs);
    } catch {
      result.connectFail += 1;
      continue;
    }

    for (let req = 0; req < config.wsRequestsPerConnection; req += 1) {
      result.requestTotal += 1;

      const dropMidFlight = Math.random() < config.wsDropRate;
      if (dropMidFlight) {
        result.dropAttempts += 1;
      }

      try {
        const latency = await requestStateRoundTrip(ws, config.wsTimeoutMs, dropMidFlight);
        result.requestOk += 1;
        result.stateLatencies.push(latency);

        if (dropMidFlight) {
          // Response arrived before forced terminate won the race.
          result.dropWonRace += 1;
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);

        if (message.includes("timeout")) {
          result.requestTimeout += 1;
        } else {
          result.requestFail += 1;
        }

        if (dropMidFlight) {
          result.dropDisconnects += 1;
        }

        if (ws.readyState !== WebSocket.OPEN) {
          break;
        }
      }
    }

    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CLOSING) {
      await closeWsQuietly(ws);
    }
  }

  if (result.connectFail > 0) {
    console.log(`worker#${workerId}: connectFail=${result.connectFail}`);
  }

  return result;
}

async function runWsBenchmark(config: BenchConfig): Promise<void> {
  if (!config.token || !config.workspaceId || !config.sessionId) {
    console.log("\n━━ WS benchmark skipped ━━");
    console.log(
      "Set --token/--workspace/--session (or LOAD_TOKEN/LOAD_WORKSPACE_ID/LOAD_SESSION_ID) to run WS churn benchmark.",
    );
    return;
  }

  console.log("\n━━ WebSocket get_state benchmark (with forced drops) ━━");
  console.log(`workspace=${config.workspaceId}, session=${config.sessionId}`);
  console.log(
    `clients=${config.wsClients}, connections/client=${config.wsConnectionsPerClient}, `
      + `requests/connection=${config.wsRequestsPerConnection}, dropRate=${config.wsDropRate}`,
  );

  const started = performance.now();

  const workers = Array.from(
    { length: config.wsClients },
    (_, i) => runWsWorker(i + 1, config),
  );

  const results = await Promise.all(workers);
  const elapsedMs = performance.now() - started;

  let connectOk = 0;
  let connectFail = 0;
  let requestTotal = 0;
  let requestOk = 0;
  let requestFail = 0;
  let requestTimeout = 0;
  let dropAttempts = 0;
  let dropDisconnects = 0;
  let dropWonRace = 0;

  const connectLatencies: number[] = [];
  const stateLatencies: number[] = [];

  for (const r of results) {
    connectOk += r.connectOk;
    connectFail += r.connectFail;
    requestTotal += r.requestTotal;
    requestOk += r.requestOk;
    requestFail += r.requestFail;
    requestTimeout += r.requestTimeout;
    dropAttempts += r.dropAttempts;
    dropDisconnects += r.dropDisconnects;
    dropWonRace += r.dropWonRace;

    connectLatencies.push(...r.connectLatencies);
    stateLatencies.push(...r.stateLatencies);
  }

  const reqPerSec = requestOk / (elapsedMs / 1000);

  console.log(
    `connect: ok=${connectOk}, fail=${connectFail}, successRate=${(
      connectOk / Math.max(1, connectOk + connectFail)
    * 100).toFixed(1)}%`,
  );
  console.log(
    `state requests: total=${requestTotal}, ok=${requestOk}, fail=${requestFail}, timeout=${requestTimeout}, `
      + `throughput=${reqPerSec.toFixed(1)} req/s`,
  );
  console.log(
    `forced drops: attempts=${dropAttempts}, disconnects=${dropDisconnects}, responsesWonRace=${dropWonRace}`,
  );

  printSummary("connect latency", summarize(connectLatencies));
  printSummary("get_state RTT", summarize(stateLatencies));
}

function printUsage(): void {
  console.log(`
Usage:
  npx tsx scripts/manual/load-ws.ts [options]

Options:
  --host <host>                          (default: 127.0.0.1)
  --port <port>                          (default: 7749)

  --http-workers <n>                     (default: 16)
  --http-duration-ms <ms>                (default: 5000)

  --token <bearer-token>                 (optional, enables WS benchmark)
  --workspace <workspace-id>             (optional, enables WS benchmark)
  --session <session-id>                 (optional, enables WS benchmark)

  --ws-clients <n>                       (default: 8)
  --ws-connections-per-client <n>        (default: 8)
  --ws-requests-per-connection <n>       (default: 20)
  --ws-drop-rate <0..1>                  (default: 0.10)
  --ws-timeout-ms <ms>                   (default: 4000)

Examples:
  npx tsx scripts/manual/load-ws.ts --host 127.0.0.1 --port 7749
  npx tsx scripts/manual/load-ws.ts --token <token> --workspace <workspaceId> --session <sessionId>
`);
}

async function main(): Promise<void> {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    printUsage();
    return;
  }

  const config: BenchConfig = {
    host: argOrEnv("host", "LOAD_HOST", "127.0.0.1") ?? "127.0.0.1",
    port: parseNumber("port", "LOAD_PORT", 7749),

    httpWorkers: parseNumber("http-workers", "LOAD_HTTP_WORKERS", 16),
    httpDurationMs: parseNumber("http-duration-ms", "LOAD_HTTP_DURATION_MS", 5000),

    token: argOrEnv("token", "LOAD_TOKEN"),
    workspaceId: argOrEnv("workspace", "LOAD_WORKSPACE_ID"),
    sessionId: argOrEnv("session", "LOAD_SESSION_ID"),

    wsClients: parseNumber("ws-clients", "LOAD_WS_CLIENTS", 8),
    wsConnectionsPerClient: parseNumber("ws-connections-per-client", "LOAD_WS_CONNECTIONS_PER_CLIENT", 8),
    wsRequestsPerConnection: parseNumber("ws-requests-per-connection", "LOAD_WS_REQUESTS_PER_CONNECTION", 20),
    wsDropRate: parseNumber("ws-drop-rate", "LOAD_WS_DROP_RATE", 0.10),
    wsTimeoutMs: parseNumber("ws-timeout-ms", "LOAD_WS_TIMEOUT_MS", 4000),
  };

  console.log("╔══════════════════════════════════════════════╗");
  console.log("║ oppi-server load harness (HTTP + WS churn)    ║");
  console.log("╚══════════════════════════════════════════════╝");

  await runHttpBenchmark(config);
  await runWsBenchmark(config);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`\nFatal: ${message}`);
  process.exit(1);
});

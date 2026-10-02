#!/usr/bin/env bun
/** Credential-approved, throwaway-server Haiku smoke. Never targets an owner runtime. */
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  closeSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import { createServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import type { ServerMessage } from "../src/types.js";

const serverDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const artifactDir = mkdtempSync(join(tmpdir(), "oppi-durable-ui-haiku-"));
chmodSync(artifactDir, 0o700);
const dataDir = join(artifactDir, "data");
const piDir = join(dataDir, "pi-agent");
const cwd = join(dataDir, "workspace");
mkdirSync(piDir, { recursive: true, mode: 0o700 });
mkdirSync(cwd, { recursive: true, mode: 0o700 });
const sharedPi = process.env.DURABLE_SMOKE_PI_DIR ?? join(homedir(), ".pi", "agent");
// Copy rather than symlink: an OAuth refresh can write ONLY the private test copy.
// Run through secret_run; neither credentials nor bearer tokens enter the receipt.
for (const name of ["auth.json", "models.json"]) {
  const source = join(sharedPi, name);
  if (!existsSync(source)) {
    if (name === "auth.json") throw new Error("Pi shared auth.json is required");
    continue;
  }
  copyFileSync(source, join(piDir, name));
  chmodSync(join(piDir, name), 0o600);
}
writeFileSync(
  join(piDir, "settings.json"),
  JSON.stringify({
    defaultProvider: "anthropic",
    defaultModel: "claude-haiku-4-5",
    defaultThinkingLevel: "off",
    compaction: { enabled: false },
    packages: [],
    extensions: [],
  }),
  { mode: 0o600 },
);
const socket = createServer();
socket.listen(0, "127.0.0.1");
await once(socket, "listening");
const address = socket.address();
assert(address && typeof address === "object");
const port = address.port;
await new Promise<void>((resolve) => socket.close(() => resolve()));
const token = `sk_${crypto.randomUUID().replaceAll("-", "")}`;
writeFileSync(
  join(dataDir, "config.json"),
  JSON.stringify({
    host: "127.0.0.1",
    port,
    token,
    tls: { mode: "disabled" },
    experimental: { serverDurable: true },
  }),
  { mode: 0o600 },
);
const base = `http://127.0.0.1:${port}`;
const receipt: string[] = [];
function record(line: string) {
  receipt.push(line);
  console.log(line);
  writeFileSync(join(artifactDir, "receipt.txt"), `${receipt.join("\n")}\n`);
}
let child: ChildProcess | undefined;
const connections: WebSocket[] = [];
async function stop(signal: "SIGKILL" | "SIGTERM") {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = once(child, "exit");
  child.kill(signal);
  const timer = setTimeout(() => child?.kill("SIGKILL"), 15000);
  try {
    await exited;
  } finally {
    clearTimeout(timer);
    child = undefined;
  }
}
async function launch(label: string) {
  const fd = openSync(join(artifactDir, `server-${label}.log`), "w", 0o600);
  child = spawn(process.execPath, [join(serverDir, "dist", "src", "cli.js"), "serve"], {
    cwd: serverDir,
    env: {
      ...process.env,
      OPPI_DATA_DIR: dataDir,
      PI_CODING_AGENT_DIR: piDir,
      PI_AGENT_SYNC_MODE: "skip",
      OPPI_LOG_LEVEL: "info",
    },
    stdio: ["ignore", fd, fd],
  });
  closeSync(fd);
  child.on("error", (error) => record(`server child error: ${error.message}`));
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null)
      throw new Error(`Throwaway server exited; inspect server-${label}.log`);
    try {
      if ((await fetch(`${base}/health`, { signal: AbortSignal.timeout(1000) })).ok) {
        record(
          `doctor ${label}: owned child healthy pid=${child.pid} model=anthropic/claude-haiku-4-5`,
        );
        return;
      }
    } catch {
      /* Bounded HTTP startup check, not process/job polling. */
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Throwaway server health timeout; inspect server-${label}.log`);
}
async function post(path: string, body: unknown): Promise<any> {
  const response = await fetch(`${base}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(45000),
  });
  if (!response.ok) throw new Error(`POST ${path}: HTTP ${response.status}`);
  return response.json();
}
async function connect(path: string) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  connections.push(ws);
  const messages: ServerMessage[] = [];
  const waiters = new Set<{
    predicate: (m: ServerMessage) => boolean;
    resolve: (m: ServerMessage) => void;
  }>();
  ws.on("message", (raw) => {
    const message = JSON.parse(raw.toString()) as ServerMessage;
    messages.push(message);
    for (const waiter of waiters)
      if (waiter.predicate(message)) {
        waiters.delete(waiter);
        waiter.resolve(message);
      }
  });
  await Promise.race([
    once(ws, "open"),
    new Promise((_, reject) => {
      const t = setTimeout(() => reject(new Error("WS open timeout")), 15000);
      t.unref();
    }),
  ]);
  const next = (predicate: (m: ServerMessage) => boolean): Promise<ServerMessage> => {
    const existing = messages.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        waiters.delete(waiter);
        reject(new Error(`WS event timeout; observed ${messages.map((m) => m.type).join(",")}`));
      }, 90000);
      const waiter = {
        predicate,
        resolve: (m: ServerMessage) => {
          clearTimeout(timer);
          resolve(m);
        },
      };
      waiters.add(waiter);
    });
  };
  await next((m) => m.type === "stream_connected");
  return { ws, next, messages };
}
try {
  record(`artifacts=${artifactDir}`);
  await launch("before-kill");
  const { workspace } = await post("/workspaces", { name: "Durable UI smoke", hostMount: cwd });
  const { session } = await post(`/workspaces/${workspace.id}/sessions`, {
    name: "Haiku crash ask",
    model: "anthropic/claude-haiku-4-5",
    thinking: "off",
    tools: ["ask"],
    autoStop: false,
  });
  const streamPath = `/workspaces/${workspace.id}/sessions/${session.id}/stream`;
  const first = await connect(streamPath);
  first.ws.send(
    JSON.stringify({
      type: "prompt",
      message:
        "Call ask exactly once now. Ask one question with id color, question Favorite color?, and two options red/Red and blue/Blue. After the answer, respond with exactly COLOR=<the chosen value>. Do not guess or use any other tool.",
      clientTurnId: "durable-ui-smoke-turn",
    }),
  );
  const pending = (await first.next(
    (m) => m.type === "extension_ui_request" && m.method === "ask",
  )) as Extract<ServerMessage, { type: "extension_ui_request" }>;
  assert.equal(pending.questions?.length, 1);
  assert.equal(pending.questions![0]!.id, "color");
  record(`Haiku pending ask id=${pending.id} questions=1`);
  await stop("SIGKILL");
  first.ws.terminate();
  record("SIGKILL owned server while ask pending");
  await launch("after-kill");
  const second = await connect(streamPath);
  const restored = (await second.next(
    (m) => m.type === "extension_ui_request" && m.method === "ask",
  )) as Extract<ServerMessage, { type: "extension_ui_request" }>;
  assert.equal(restored.id, pending.id);
  assert.deepEqual(restored.questions, pending.questions);
  record(`reconnect restored same pending ask id=${restored.id}`);
  second.ws.send(
    JSON.stringify({
      type: "extension_ui_response",
      id: restored.id,
      value: JSON.stringify({ color: "red" }),
    }),
  );
  await second.next((m) => m.type === "extension_ui_settled" && m.id === restored.id);
  await second.next(
    (m) => m.type === "message_end" && m.role === "assistant" && m.content.includes("COLOR=red"),
  );
  await second.next((m) => m.type === "agent_end");
  second.ws.send(JSON.stringify({ type: "get_messages", requestId: "smoke-history" }));
  const historyResponse = (await second.next(
    (m) => m.type === "command_result" && m.requestId === "smoke-history",
  )) as Extract<ServerMessage, { type: "command_result" }>;
  assert.equal(historyResponse.success, true);
  const history = historyResponse.data as Array<{
    role: string;
    toolName?: string;
    isError?: boolean;
    details?: { answers?: unknown };
    content?: unknown;
  }>;
  const results = history.filter((m) => m.role === "toolResult" && m.toolName === "ask");
  assert.equal(results.length, 1);
  assert.equal(results[0]!.isError, false);
  assert.deepEqual(results[0]!.details?.answers, { color: "red" });
  assert.equal(history.filter((m) => m.role === "user").length, 1);
  assert.equal(
    second.messages.filter((m) => m.type === "tool_end" && m.tool === "ask" && !m.isError).length,
    1,
  );
  record("PASS answer over WS: tool_results=1 user_turns=1 successful_tool_end=1 final=COLOR=red");
  writeFileSync(
    join(artifactDir, "ws-after-restart.json"),
    JSON.stringify(second.messages, null, 2),
  );
} catch (error) {
  record(`FAIL ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
} finally {
  for (const ws of connections) ws.terminate();
  await stop("SIGTERM");
  record("owned throwaway processes stopped; run artifacts retained");
}

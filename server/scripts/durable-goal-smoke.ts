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
import { request } from "node:http";
import { createConnection, createServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { localApiSocketPath } from "../src/local-api-socket.js";
import type { ServerMessage } from "../src/types.js";

const serverDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const artifactDir = mkdtempSync(join(tmpdir(), "oppi-durable-goal-haiku-"));
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
// Owner sk_ bearers are local-only; both REST and live upgrades use this socket.
const apiSocketPath = localApiSocketPath(dataDir);
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
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath: apiSocketPath,
        path,
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        signal: AbortSignal.timeout(45000),
        agent: false,
      },
      (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => (text += chunk));
        res.on("error", reject);
        res.on("end", () => {
          const status = res.statusCode ?? 0;
          if (status < 200 || status >= 300) {
            reject(new Error(`POST ${path}: HTTP ${status}`));
            return;
          }
          try {
            resolve(JSON.parse(text));
          } catch (error) {
            reject(error);
          }
        });
      },
    );
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}
async function connect(path: string) {
  const ws = new WebSocket(`ws://localhost${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    createConnection: () => createConnection(apiSocketPath),
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
  const { workspace } = await post("/workspaces", { name: "Durable goal smoke", hostMount: cwd });
  const { session } = await post(`/workspaces/${workspace.id}/sessions`, {
    name: "Haiku goal restart",
    model: "anthropic/claude-haiku-4-5",
    thinking: "off",
    tools: ["get_goal", "create_goal", "update_goal", "ask"],
    autoStop: false,
  });
  const streamPath = `/workspaces/${workspace.id}/sessions/${session.id}/stream`;
  const first = await connect(streamPath);
  first.ws.send(
    JSON.stringify({
      type: "prompt",
      message:
        "I explicitly request an autonomous goal for this crash-recovery test. Call create_goal with objective='Verify goal state survives server restart', summary='Before crash evidence', max_continuations=1, and one pending task with id='restart', title='Verify restart'. Then end this initial run with INITIAL_DONE; do not call ask in this run. On the automatic continuation, call get_goal, then ask exactly one question: id='restart', question='Proceed with restart verification?', options yes/Yes and no/No. Do not pause or block the goal while waiting for ask. Once answered yes, call get_goal again, then update_goal with status='complete', task_updates=[{id:'restart',status:'completed'}], summary='Restart verified with preserved goal'. End with GOAL_RECOVERED.",
      clientTurnId: "durable-goal-smoke-turn",
    }),
  );
  const pending = (await first.next(
    (m) => m.type === "extension_ui_request" && m.method === "ask",
  )) as Extract<ServerMessage, { type: "extension_ui_request" }>;
  assert.equal(pending.questions?.length, 1);
  assert.equal(pending.questions![0]!.id, "restart");
  await first.next(
    (m) => m.type === "message_end" && m.role === "assistant" && m.content.includes("INITIAL_DONE"),
  );
  const widget = (await first.next(
    (m) =>
      m.type === "extension_ui_notification" &&
      m.method === "setWidget" &&
      m.widgetKey === "goal" &&
      JSON.stringify(m.nativeSurface).includes("1/1 continuations"),
  )) as Extract<ServerMessage, { type: "extension_ui_notification" }>;
  assert(JSON.stringify(widget.nativeSurface).includes("Before crash evidence"));
  record(`goal active: one continuation, pending ask id=${pending.id}; original run settled`);
  await stop("SIGKILL");
  first.ws.terminate();
  record("SIGKILL owned server mid-goal while first continuation awaits ask");
  await launch("after-kill");
  const second = await connect(streamPath);
  const restored = (await second.next(
    (m) => m.type === "extension_ui_request" && m.method === "ask",
  )) as Extract<ServerMessage, { type: "extension_ui_request" }>;
  assert.equal(restored.id, pending.id);
  assert.deepEqual(restored.questions, pending.questions);
  const restoredWidget = (await second.next(
    (m) =>
      m.type === "extension_ui_notification" &&
      m.method === "setWidget" &&
      m.widgetKey === "goal" &&
      JSON.stringify(m.nativeSurface).includes("1/1 continuations"),
  )) as Extract<ServerMessage, { type: "extension_ui_notification" }>;
  assert.deepEqual(restoredWidget.nativeSurface, widget.nativeSurface);
  record(`reconnect restored goal widget and same pending ask id=${restored.id}`);
  second.ws.send(
    JSON.stringify({
      type: "extension_ui_response",
      id: restored.id,
      value: JSON.stringify({ restart: "yes" }),
    }),
  );
  await second.next((m) => m.type === "extension_ui_settled" && m.id === restored.id);
  await second.next(
    (m) =>
      m.type === "message_end" && m.role === "assistant" && m.content.includes("GOAL_RECOVERED"),
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
  assert.deepEqual(results[0]!.details?.answers, { restart: "yes" });
  const userText = (content: unknown): string =>
    typeof content === "string"
      ? content
      : Array.isArray(content)
        ? content.map((block: { text?: string }) => block.text ?? "").join("")
        : "";
  const notes = history.filter(
    (m) => m.role === "user" && userText(m.content).startsWith("[Goal runner]"),
  );
  assert(
    notes.some((m) =>
      userText(m.content).includes("continue: Run settled; no pending messages or compaction"),
    ),
    "continuation decision must be visible in the phone transcript",
  );
  assert.equal(
    history.filter((m) => m.role === "user" && !userText(m.content).startsWith("[Goal runner]"))
      .length,
    2,
  );
  const creates = history.filter((m) => m.role === "toolResult" && m.toolName === "create_goal");
  assert.equal(creates.length, 1);
  const reads = history.filter((m) => m.role === "toolResult" && m.toolName === "get_goal");
  assert(reads.length >= 2, "get_goal must run before and after restart");
  const goals = reads.map(
    (m) =>
      (
        m.details as {
          goal?: {
            id: string;
            status: string;
            continuationCount: number;
            tasks: Array<{ id: string; status: string }>;
          };
        }
      ).goal,
  );
  assert(
    goals.every(
      (g) =>
        g?.id === goals[0]?.id &&
        g?.status === "active" &&
        g?.continuationCount === 1 &&
        g.tasks.some((task) => task.id === "restart" && task.status === "pending"),
    ),
    "same active goal/checklist/count must survive restart",
  );
  const completion = history.filter((m) => m.role === "toolResult" && m.toolName === "update_goal");
  assert.equal(completion.length, 1);
  assert.equal(
    (completion[0]!.details as { goal: { status: string; continuationCount: number } }).goal.status,
    "complete",
  );
  assert.equal(
    (completion[0]!.details as { goal: { continuationCount: number } }).goal.continuationCount,
    1,
  );
  assert.equal(
    second.messages.filter((m) => m.type === "tool_end" && m.tool === "ask" && !m.isError).length,
    1,
  );
  record(
    "PASS create=1 continuation=1 user_turns=2 ask_results=1; state/checklist preserved; final=GOAL_RECOVERED",
  );
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

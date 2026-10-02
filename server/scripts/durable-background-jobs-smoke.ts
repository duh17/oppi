#!/usr/bin/env bun
/** Opt-in credential-approved crash smoke. Only an owned throwaway server is killed. */
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
  readFileSync,
  watch,
} from "node:fs";
import { request } from "node:http";
import { createConnection, createServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { DatabaseSync } from "node:sqlite";
import { localApiSocketPath } from "../src/local-api-socket.js";
import type { ServerMessage } from "../src/types.js";

const serverDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const artifactDir = mkdtempSync(join(tmpdir(), "oppi-durable-background-haiku-"));
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
let jobPid: number | undefined;
async function waitForStartedJob(): Promise<void> {
  const marker = join(cwd, "smoke-job.log");
  await new Promise<void>((resolve, reject) => {
    const watcher = watch(cwd, () => check());
    const timer = setTimeout(() => {
      watcher.close();
      reject(new Error("Job exec marker timeout"));
    }, 45000);
    function check() {
      if (!existsSync(marker)) return;
      const match = /^START (\d+)\n$/u.exec(readFileSync(marker, "utf8"));
      if (!match) return;
      jobPid = Number(match[1]);
      clearTimeout(timer);
      watcher.close();
      resolve();
    }
    check();
  });
}
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
  const { workspace } = await post("/workspaces", {
    name: "Durable background smoke",
    hostMount: cwd,
  });
  const { session } = await post(`/workspaces/${workspace.id}/sessions`, {
    name: "Haiku crash background job",
    model: "anthropic/claude-haiku-4-5",
    thinking: "off",
    tools: ["background_job"],
    autoStop: false,
  });
  const streamPath = `/workspaces/${workspace.id}/sessions/${session.id}/stream`;
  const first = await connect(streamPath);
  first.ws.send(
    JSON.stringify({
      type: "prompt",
      message:
        "Call background_job start exactly once with command: printf 'START %s\\n' \"$$\" >> smoke-job.log; sleep 120; printf 'DONE\\n' >> smoke-job.log . Use timeout 180. Then end your reply with STARTED. Do not poll. If you later receive an interrupted background job result, reply with exactly INTERRUPTED; do not start another job.",
      clientTurnId: "durable-background-smoke-turn",
    }),
  );
  await first.next((m) => m.type === "tool_end" && m.tool === "background_job" && !m.isError);
  await waitForStartedJob();
  await first.next((m) => m.type === "agent_end");
  record(
    "Haiku started background job; shell marker confirms execution and agent_end confirms idle",
  );
  await stop("SIGKILL");
  first.ws.terminate();
  record("SIGKILL owned server mid-job (the original shell may outlive process death)");
  await launch("after-kill");
  const second = await connect(streamPath);
  // get_messages reads committed history even if restart finished the model turn
  // before the socket attached. A bounded retry is service-state QA, not an agent poll.
  const deadline = Date.now() + 90000;
  let completed = false;
  while (Date.now() < deadline) {
    const requestId = `restart-history:${crypto.randomUUID()}`;
    second.ws.send(JSON.stringify({ type: "get_messages", requestId }));
    const result = (await second.next(
      (m) => m.type === "command_result" && m.requestId === requestId,
    )) as Extract<ServerMessage, { type: "command_result" }>;
    assert.equal(result.success, true);
    const messages = result.data as Array<{ role: string; content?: unknown }>;
    if (
      messages.some(
        (message) =>
          message.role === "assistant" && JSON.stringify(message.content).includes("INTERRUPTED"),
      )
    ) {
      completed = true;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.equal(completed, true, "Haiku must answer the interrupted result after restart");
  second.ws.send(JSON.stringify({ type: "get_messages", requestId: "smoke-history" }));
  const historyResponse = (await second.next(
    (m) => m.type === "command_result" && m.requestId === "smoke-history",
  )) as Extract<ServerMessage, { type: "command_result" }>;
  assert.equal(historyResponse.success, true);
  const history = historyResponse.data as Array<{
    role: string;
    toolName?: string;
    content?: unknown;
  }>;
  const reports = history.filter(
    (m) => m.role === "user" && JSON.stringify(m.content).includes("interrupted by a host restart"),
  );
  assert.equal(reports.length, 1);
  assert.equal(
    history.filter((m) => m.role === "toolResult" && m.toolName === "background_job").length,
    1,
  );
  assert.equal(readFileSync(join(cwd, "smoke-job.log"), "utf8").split("START ").length - 1, 1);
  const db = new DatabaseSync(join(dataDir, "durable", "harness.sqlite"), { readOnly: true });
  try {
    const receipts = db
      .prepare(
        "SELECT request_id, status FROM submissions WHERE request_id LIKE 'background-job:%'",
      )
      .all();
    assert.deepEqual(
      receipts.map((row) => ({ ...row })),
      [{ request_id: "background-job:bash-1", status: "done" }],
    );
    writeFileSync(join(artifactDir, "job-receipts.json"), JSON.stringify(receipts, null, 2));
  } finally {
    db.close();
  }
  record(
    "PASS restart: exec_starts=1 interrupted_inputs=1 job_receipts=1 status=done final=INTERRUPTED",
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
  // SIGKILL cannot invoke NodeExecutionEnv cleanup. Kill ONLY the process group
  // this smoke recorded, never a user's runtime or a discovered ambient process.
  if (jobPid && jobPid > 1) {
    try {
      process.kill(-jobPid, "SIGKILL");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
    }
  }
  record("owned throwaway processes stopped; run artifacts retained");
}

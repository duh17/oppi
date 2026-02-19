#!/usr/bin/env node

import { mkdtempSync, openSync, closeSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import WebSocket from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const serverDir = join(__dirname, "..");

const LOCAL_MODEL_ID = process.env.LMS_MODEL_ID || "glm-4.7-flash-mlx";
const SERVER_MODEL_ID = process.env.SERVER_MODEL_ID || `lmstudio/${LOCAL_MODEL_ID}`;

const PORT = Number(process.env.E2E_PORT || 17869);
const ADMIN_TOKEN = process.env.E2E_ADMIN_TOKEN || "sk_e2e_lmstudio_contract_admin";

const BOOT_TIMEOUT_MS = Number(process.env.BOOT_TIMEOUT_MS || 60_000);
const RUN_TIMEOUT_MS = Number(process.env.RUN_TIMEOUT_MS || 120_000);
const NO_PROGRESS_TIMEOUT_MS = Number(process.env.NO_PROGRESS_TIMEOUT_MS || 45_000);
const BUILD_TIMEOUT_MS = Number(process.env.BUILD_TIMEOUT_MS || 300_000);
const WS_FAILURE_TIMEOUT_MS = Number(process.env.WS_FAILURE_TIMEOUT_MS || 10_000);
const STREAM_STEP_TIMEOUT_MS = Number(process.env.STREAM_STEP_TIMEOUT_MS || 30_000);
const STREAM_RING_PROMPT_TIMEOUT_MS = Number(
  process.env.STREAM_RING_PROMPT_TIMEOUT_MS || Math.max(STREAM_STEP_TIMEOUT_MS, 90_000),
);
const SESSION_EVENT_RING_CAPACITY = Number(process.env.SESSION_EVENT_RING_CAPACITY || 24);
const STREAM_RING_MISS_PROMPTS = Number(process.env.STREAM_RING_MISS_PROMPTS || 14);
const REQUIRE_LMS_MODEL = process.env.REQUIRE_LMS_MODEL === "1";

const KEEP_ARTIFACTS = process.env.KEEP_E2E_ARTIFACTS === "1";

const TOOL_MARKER = "CONTRACT_TOOL_OK";
const PROMPT_REQUEST_ID = "req-contract-prompt";

function log(msg) {
  console.log(`[contract] ${msg}`);
}

function warn(msg) {
  console.warn(`[contract] WARN: ${msg}`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseJsonSafe(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function spawnWithTimeout(command, args, {
  cwd,
  env,
  timeoutMs,
  captureOutput = false,
  stdio = "inherit",
} = {}) {
  return new Promise((resolve, reject) => {
    let timedOut = false;
    const child = spawn(command, args, {
      cwd,
      env,
      stdio: captureOutput ? ["ignore", "pipe", "pipe"] : stdio,
    });

    let stdout = "";
    let stderr = "";

    if (captureOutput) {
      child.stdout?.on("data", (chunk) => {
        stdout += chunk.toString();
      });
      child.stderr?.on("data", (chunk) => {
        stderr += chunk.toString();
      });
    }

    const timer = timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          child.kill("SIGTERM");
          setTimeout(() => child.kill("SIGKILL"), 1500).unref();
        }, timeoutMs)
      : null;

    child.on("error", (err) => {
      if (timer) clearTimeout(timer);
      reject(err);
    });

    child.on("exit", (code, signal) => {
      if (timer) clearTimeout(timer);

      if (timedOut) {
        reject(new Error(`${command} ${args.join(" ")} timed out after ${timeoutMs}ms`));
        return;
      }

      if (code !== 0) {
        const detail = captureOutput
          ? `\nstdout:\n${stdout}\nstderr:\n${stderr}`
          : ` (signal=${signal ?? "none"})`;
        reject(new Error(`${command} ${args.join(" ")} failed with code ${code}${detail}`));
        return;
      }

      resolve({ stdout, stderr });
    });
  });
}

async function ensureModelLoaded() {
  log(`checking LM Studio model: ${LOCAL_MODEL_ID}`);

  let ps;
  try {
    ps = await spawnWithTimeout("lms", ["ps"], {
      captureOutput: true,
      timeoutMs: 20_000,
      stdio: "pipe",
    });
  } catch (error) {
    if (REQUIRE_LMS_MODEL) {
      throw error;
    }

    warn(
      `unable to query LM Studio models (${error.message}); skipping contract lane. `
      + `Set REQUIRE_LMS_MODEL=1 to fail instead.`,
    );
    return false;
  }

  if (ps.stdout.includes(LOCAL_MODEL_ID)) {
    log(`model already loaded: ${LOCAL_MODEL_ID}`);
    return true;
  }

  if (REQUIRE_LMS_MODEL) {
    throw new Error(`LM Studio model ${LOCAL_MODEL_ID} is not loaded (lms ps)`);
  }

  warn(
    `LM Studio model ${LOCAL_MODEL_ID} is not loaded; skipping contract lane. `
    + `Load it first with: lms load ${LOCAL_MODEL_ID}`,
  );
  return false;
}

async function waitForHealth(baseUrl) {
  const started = Date.now();
  while (Date.now() - started < BOOT_TIMEOUT_MS) {
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) return;
    } catch {
      // keep retrying
    }
    await sleep(500);
  }
  throw new Error(`server /health did not become ready within ${BOOT_TIMEOUT_MS}ms`);
}

async function apiRequest(baseUrl, method, path, token, body) {
  const headers = { "Content-Type": "application/json" };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  return {
    status: res.status,
    json: parseJsonSafe(text),
    text,
  };
}

async function stopServer(serverProc) {
  if (!serverProc || serverProc.killed) return;

  serverProc.kill("SIGTERM");

  const exited = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 4_000);
    serverProc.once("exit", () => {
      clearTimeout(timer);
      resolve(true);
    });
  });

  if (!exited) {
    serverProc.kill("SIGKILL");
  }
}

async function expectWsUpgradeFailure({ wsUrl, token, expectedStatus, label }) {
  return new Promise((resolve, reject) => {
    let settled = false;

    const finish = (err = null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        ws.terminate();
      } catch {
        // ignore terminate errors
      }
      if (err) {
        reject(err);
      } else {
        resolve();
      }
    };

    const headers = {};
    if (typeof token === "string" && token.length > 0) {
      headers.Authorization = `Bearer ${token}`;
    }

    const ws = new WebSocket(wsUrl, Object.keys(headers).length > 0 ? { headers } : undefined);

    const timer = setTimeout(() => {
      finish(new Error(`${label}: timeout waiting for expected WS failure (${expectedStatus})`));
    }, WS_FAILURE_TIMEOUT_MS);

    ws.on("unexpected-response", (_req, res) => {
      const status = res.statusCode || 0;
      res.resume();
      if (status !== expectedStatus) {
        finish(new Error(`${label}: expected WS status ${expectedStatus}, got ${status}`));
        return;
      }
      finish();
    });

    ws.on("open", () => {
      finish(new Error(`${label}: websocket unexpectedly opened`));
    });

    ws.on("error", (err) => {
      if (settled) return;
      const message = err?.message || String(err);
      const match = message.match(/Unexpected server response:\s*(\d+)/i);
      if (match) {
        const status = Number(match[1]);
        if (status === expectedStatus) {
          finish();
          return;
        }
        finish(new Error(`${label}: expected WS status ${expectedStatus}, got ${status}`));
        return;
      }
      finish(new Error(`${label}: websocket error before expected failure: ${message}`));
    });
  });
}

function findFirst(events, predicate) {
  for (const event of events) {
    if (predicate(event)) return event;
  }
  return undefined;
}

function findLast(events, predicate) {
  for (let i = events.length - 1; i >= 0; i--) {
    if (predicate(events[i])) return events[i];
  }
  return undefined;
}

function requireEventOrder(before, after, label) {
  if (!before || !after) {
    throw new Error(`missing events for order check: ${label}`);
  }
  if (before.seq >= after.seq) {
    throw new Error(`invalid event order: ${label} (${before.seq} !< ${after.seq})`);
  }
}

function validateContractResult(result) {
  const events = result.events;
  const connected = findFirst(events, (e) => e.direction === "in" && e.type === "connected");
  const promptSend = findFirst(
    events,
    (e) => e.direction === "out" && e.type === "prompt" && e.requestId === PROMPT_REQUEST_ID,
  );
  const promptRpc = findFirst(
    events,
    (e) =>
      e.direction === "in" &&
      e.type === "rpc_result" &&
      e.requestId === PROMPT_REQUEST_ID &&
      e.success === true,
  );

  const agentStart = findFirst(events, (e) => e.direction === "in" && e.type === "agent_start");
  const agentEnd = findLast(events, (e) => e.direction === "in" && e.type === "agent_end");

  const bashStart = findFirst(
    events,
    (e) => e.direction === "in" && e.type === "tool_start" && String(e.tool || "").includes("bash"),
  );
  const bashEnd = findFirst(
    events,
    (e) => e.direction === "in" && e.type === "tool_end" && String(e.tool || "").includes("bash"),
  );

  if (!connected) throw new Error("missing connected event");
  if (!promptSend) throw new Error("missing outbound prompt event");
  if (!promptRpc) throw new Error("missing successful prompt rpc_result event");
  if (!agentStart) throw new Error("missing agent_start event");
  if (!agentEnd) throw new Error("missing agent_end event");
  if (!bashStart) throw new Error("missing bash tool_start event");
  if (!bashEnd) throw new Error("missing bash tool_end event");

  requireEventOrder(connected, promptSend, "connected -> prompt send");
  requireEventOrder(promptSend, promptRpc, "prompt send -> prompt rpc_result");
  requireEventOrder(agentStart, bashStart, "agent_start -> bash tool_start");
  requireEventOrder(bashStart, bashEnd, "bash tool_start -> bash tool_end");
  requireEventOrder(bashEnd, agentEnd, "bash tool_end -> agent_end");

  if (result.permissionRequestIds.length === 0) {
    throw new Error("expected at least one permission_request event");
  }

  const responseSet = new Set(result.permissionResponseIds);
  for (const id of result.permissionRequestIds) {
    if (!responseSet.has(id)) {
      throw new Error(`missing permission_response for permission_request id=${id}`);
    }
  }
}

function createContractError(message, state) {
  const err = new Error(message);
  if (state !== undefined) {
    err.contractState = state;
  }
  return err;
}

function assertStrictlyIncreasing(values, label) {
  for (let i = 1; i < values.length; i++) {
    if (values[i] <= values[i - 1]) {
      throw new Error(`${label} not strictly increasing at index ${i}: ${values[i - 1]} -> ${values[i]}`);
    }
  }
}

function serializeStreamEvent(direction, msg, localSeq, startedAt) {
  const event = {
    localSeq,
    atMs: Date.now() - startedAt,
    direction,
    type: typeof msg?.type === "string" ? msg.type : "unknown",
  };

  if (typeof msg?.sessionId === "string") event.sessionId = msg.sessionId;
  if (typeof msg?.requestId === "string") event.requestId = msg.requestId;
  if (typeof msg?.command === "string") event.command = msg.command;
  if (typeof msg?.id === "string") event.id = msg.id;
  if (typeof msg?.tool === "string") event.tool = msg.tool;
  if (typeof msg?.clientTurnId === "string") event.clientTurnId = msg.clientTurnId;
  if (typeof msg?.stage === "string") event.stage = msg.stage;
  if (typeof msg?.duplicate === "boolean") event.duplicate = msg.duplicate;
  if (typeof msg?.source === "string") event.source = msg.source;
  if (typeof msg?.reason === "string") event.reason = msg.reason;
  if (typeof msg?.error === "string") event.error = msg.error;
  if (typeof msg?.success === "boolean") event.success = msg.success;
  if ("data" in (msg || {})) event.data = msg.data;
  if (msg?.type === "state" && typeof msg?.session?.status === "string") {
    event.sessionStatus = msg.session.status;
  }
  if (typeof msg?.seq === "number") event.sessionSeq = msg.seq;
  if (typeof msg?.streamSeq === "number") event.streamSeq = msg.streamSeq;
  if (typeof msg?.content === "string") event.content = msg.content;

  return event;
}

async function waitForWsEvent(connection, predicate, {
  startIndex = 0,
  timeoutMs = STREAM_STEP_TIMEOUT_MS,
  label = "ws event",
} = {}) {
  let cursor = Math.max(0, startIndex);
  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    while (cursor < connection.events.length) {
      const event = connection.events[cursor];
      if (predicate(event)) {
        return { event, index: cursor };
      }
      cursor += 1;
    }

    if (connection.closed) {
      throw createContractError(
        `${connection.label}: closed while waiting for ${label} (code=${connection.closeCode ?? "unknown"})`,
        {
          label: connection.label,
          closeCode: connection.closeCode,
          closeReason: connection.closeReason,
          eventTail: connection.events.slice(-40),
        },
      );
    }

    await sleep(25);
  }

  throw createContractError(`${connection.label}: timeout waiting for ${label} (${timeoutMs}ms)`, {
    label: connection.label,
    eventTail: connection.events.slice(-40),
  });
}

async function openUserStreamConnection({ streamWsUrl, deviceToken, label }) {
  const ws = new WebSocket(streamWsUrl, {
    headers: { Authorization: `Bearer ${deviceToken}` },
  });

  const startedAt = Date.now();
  let localSeq = 0;

  const connection = {
    label,
    ws,
    startedAt,
    events: [],
    closed: false,
    closeCode: null,
    closeReason: "",
    send(payload) {
      const event = serializeStreamEvent("out", payload, ++localSeq, startedAt);
      connection.events.push(event);
      ws.send(JSON.stringify(payload));
    },
  };

  ws.on("message", (raw) => {
    const msg = parseJsonSafe(raw.toString());
    const event = serializeStreamEvent("in", msg ?? { type: "invalid_json" }, ++localSeq, startedAt);
    connection.events.push(event);
  });

  ws.on("close", (code, reason) => {
    connection.closed = true;
    connection.closeCode = code;
    connection.closeReason = reason?.toString() || "";
  });

  ws.on("error", (err) => {
    const event = serializeStreamEvent("in", { type: "ws_error", error: err.message }, ++localSeq, startedAt);
    connection.events.push(event);
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(createContractError(`${label}: timeout waiting for websocket open`));
    }, STREAM_STEP_TIMEOUT_MS);

    const cleanup = () => {
      clearTimeout(timer);
      ws.off("open", onOpen);
      ws.off("error", onError);
      ws.off("close", onClose);
    };

    const onOpen = () => {
      cleanup();
      resolve();
    };

    const onError = (err) => {
      cleanup();
      reject(createContractError(`${label}: websocket open error: ${err.message}`));
    };

    const onClose = (code) => {
      cleanup();
      reject(createContractError(`${label}: websocket closed before open (code=${code})`));
    };

    ws.on("open", onOpen);
    ws.on("error", onError);
    ws.on("close", onClose);
  });

  await waitForWsEvent(
    connection,
    (event) => event.direction === "in" && event.type === "stream_connected",
    { label: "stream_connected" },
  );

  return connection;
}

async function closeUserStreamConnection(connection) {
  if (connection.closed) return;

  await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(), 2_500);
    connection.ws.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
    connection.ws.close();
  });
}

function startPermissionAutoApprover(connection, sessionId) {
  let cursor = 0;
  const approvedIds = new Set();

  const tick = () => {
    while (cursor < connection.events.length) {
      const event = connection.events[cursor];
      cursor += 1;

      if (
        event.direction !== "in"
        || event.type !== "permission_request"
        || event.sessionId !== sessionId
        || typeof event.id !== "string"
      ) {
        continue;
      }

      if (approvedIds.has(event.id)) {
        continue;
      }

      approvedIds.add(event.id);

      connection.send({
        type: "permission_response",
        sessionId,
        id: event.id,
        action: "allow",
        scope: "once",
        requestId: `req-auto-perm-${event.id}`,
      });
    }
  };

  const timer = setInterval(tick, 25);

  return {
    stop() {
      clearInterval(timer);
      tick();
    },
    getApprovedCount() {
      return approvedIds.size;
    },
  };
}

async function subscribeUserStreamSession(connection, { sessionId, sinceSeq, requestId, level = "full" }) {
  const startIndex = connection.events.length;

  connection.send({
    type: "subscribe",
    sessionId,
    level,
    sinceSeq,
    requestId,
  });

  const { event: rpcEvent, index: rpcIndex } = await waitForWsEvent(
    connection,
    (event) =>
      event.direction === "in"
      && event.type === "rpc_result"
      && event.command === "subscribe"
      && event.requestId === requestId
      && event.sessionId === sessionId,
    {
      startIndex,
      label: `subscribe rpc_result (${requestId})`,
    },
  );

  if (rpcEvent.success !== true) {
    throw createContractError(`subscribe rpc_result failed: ${rpcEvent.error || "unknown"}`, {
      label: connection.label,
      requestId,
      rpcEvent,
      eventTail: connection.events.slice(Math.max(0, rpcIndex - 30), rpcIndex + 1),
    });
  }

  const windowEvents = connection.events.slice(startIndex, rpcIndex + 1);
  const catchupEvents = windowEvents.filter(
    (event) =>
      event.direction === "in"
      && event.sessionId === sessionId
      && Number.isInteger(event.sessionSeq)
      && event.sessionSeq > sinceSeq,
  );

  return {
    rpcEvent,
    rpcData: rpcEvent.data,
    windowEvents,
    catchupEvents,
  };
}

async function sendUserStreamPrompt(connection, { sessionId, requestId, message }) {
  const startIndex = connection.events.length;

  connection.send({
    type: "prompt",
    sessionId,
    message,
    requestId,
  });

  const { event: promptRpc } = await waitForWsEvent(
    connection,
    (event) =>
      event.direction === "in"
      && event.type === "rpc_result"
      && event.requestId === requestId
      && event.command === "prompt"
      && event.sessionId === sessionId,
    {
      startIndex,
      label: `prompt rpc_result (${requestId})`,
    },
  );

  if (promptRpc.success !== true) {
    throw createContractError(`prompt rpc_result failed: ${promptRpc.error || "unknown"}`, {
      label: connection.label,
      requestId,
      eventTail: connection.events.slice(-40),
    });
  }

  await waitForWsEvent(
    connection,
    (event) =>
      event.direction === "in"
      && event.type === "agent_end"
      && event.sessionId === sessionId,
    {
      startIndex,
      label: `agent_end after prompt (${requestId})`,
    },
  );
}

async function sendUserStreamCommandAndWaitRpc(
  connection,
  { sessionId, type, requestId, extra = {} },
) {
  const startIndex = connection.events.length;

  connection.send({
    type,
    sessionId,
    requestId,
    ...extra,
  });

  const { event: rpcEvent } = await waitForWsEvent(
    connection,
    (event) =>
      event.direction === "in"
      && event.type === "rpc_result"
      && event.requestId === requestId
      && event.command === type
      && event.sessionId === sessionId,
    {
      startIndex,
      label: `${type} rpc_result (${requestId})`,
    },
  );

  return rpcEvent;
}

function getSessionSeqEvents(events, sessionId, minExclusive = 0) {
  return events.filter(
    (event) =>
      event.direction === "in"
      && event.sessionId === sessionId
      && Number.isInteger(event.sessionSeq)
      && event.sessionSeq > minExclusive,
  );
}

async function runUserStreamReconnectContract({ streamWsUrl, sessionWsUrl, deviceToken, sessionId }) {
  const stream1 = await openUserStreamConnection({
    streamWsUrl,
    deviceToken,
    label: "stream-conn-1",
  });

  let baselineSeq = 0;

  try {
    const subscribe1 = await subscribeUserStreamSession(stream1, {
      sessionId,
      level: "full",
      sinceSeq: 0,
      requestId: "req-stream-subscribe-1",
    });

    if (subscribe1.rpcData?.catchUpComplete !== true) {
      throw createContractError("initial stream subscribe catchUpComplete was false", {
        phase: "stream-1-subscribe",
        rpcData: subscribe1.rpcData,
        eventTail: stream1.events.slice(-40),
      });
    }

    await sendUserStreamPrompt(stream1, {
      sessionId,
      requestId: "req-stream-prompt-1",
      message: "Reply with exactly STREAM_BASELINE_OK. Do not use tools.",
    });

    const baselineEvents = getSessionSeqEvents(stream1.events, sessionId);
    const lastBaseline = baselineEvents[baselineEvents.length - 1];
    baselineSeq = lastBaseline?.sessionSeq ?? 0;

    if (!Number.isInteger(baselineSeq) || baselineSeq <= 0) {
      throw createContractError("failed to capture baseline session seq from /stream connection", {
        phase: "stream-1-baseline",
        eventTail: stream1.events.slice(-40),
      });
    }
  } finally {
    await closeUserStreamConnection(stream1);
  }

  const gapRun = await runWebSocketContract({
    wsUrl: sessionWsUrl,
    deviceToken,
    expectedSessionId: sessionId,
  });
  validateContractResult(gapRun);

  const stream2 = await openUserStreamConnection({
    streamWsUrl,
    deviceToken,
    label: "stream-conn-2",
  });

  let catchupSeqs = [];
  let catchupTypes = [];

  try {
    const subscribe2 = await subscribeUserStreamSession(stream2, {
      sessionId,
      level: "full",
      sinceSeq: baselineSeq,
      requestId: "req-stream-subscribe-2",
    });

    if (subscribe2.rpcData?.catchUpComplete !== true) {
      throw createContractError("reconnect subscribe catchUpComplete was false", {
        phase: "stream-2-subscribe",
        baselineSeq,
        rpcData: subscribe2.rpcData,
        eventTail: stream2.events.slice(-40),
      });
    }

    if (!Array.isArray(subscribe2.catchupEvents) || subscribe2.catchupEvents.length === 0) {
      throw createContractError("reconnect subscribe returned no catch-up events", {
        phase: "stream-2-catchup",
        baselineSeq,
        rpcData: subscribe2.rpcData,
        eventTail: stream2.events.slice(-50),
      });
    }

    catchupSeqs = subscribe2.catchupEvents.map((event) => event.sessionSeq);
    catchupTypes = subscribe2.catchupEvents.map((event) => event.type);

    assertStrictlyIncreasing(catchupSeqs, "catch-up seqs (stream-2)");

    const uniqueSeqs = new Set(catchupSeqs);
    if (uniqueSeqs.size !== catchupSeqs.length) {
      throw createContractError("duplicate seq values in reconnect catch-up events", {
        phase: "stream-2-catchup-duplicates",
        catchupSeqs,
      });
    }

    if (catchupSeqs[0] <= baselineSeq) {
      throw createContractError(
        `reconnect catch-up did not advance beyond baseline (first=${catchupSeqs[0]} baseline=${baselineSeq})`,
      );
    }

    if (!catchupTypes.includes("agent_start") || !catchupTypes.includes("agent_end")) {
      throw createContractError("reconnect catch-up missing agent_start/agent_end", {
        phase: "stream-2-catchup-types",
        catchupTypes,
      });
    }
  } finally {
    await closeUserStreamConnection(stream2);
  }

  const stream3 = await openUserStreamConnection({
    streamWsUrl,
    deviceToken,
    label: "stream-conn-3",
  });

  let replaySeqs = [];
  let replayTypes = [];

  try {
    const subscribe3 = await subscribeUserStreamSession(stream3, {
      sessionId,
      level: "full",
      sinceSeq: baselineSeq,
      requestId: "req-stream-subscribe-3",
    });

    if (subscribe3.rpcData?.catchUpComplete !== true) {
      throw createContractError("replay subscribe catchUpComplete was false", {
        phase: "stream-3-subscribe",
        baselineSeq,
        rpcData: subscribe3.rpcData,
      });
    }

    replaySeqs = subscribe3.catchupEvents.map((event) => event.sessionSeq);
    replayTypes = subscribe3.catchupEvents.map((event) => event.type);

    assertStrictlyIncreasing(replaySeqs, "catch-up seqs (stream-3)");

    if (JSON.stringify(replaySeqs) !== JSON.stringify(catchupSeqs)) {
      throw createContractError("replay catch-up seqs differ from previous reconnect", {
        phase: "stream-3-seq-compare",
        catchupSeqs,
        replaySeqs,
      });
    }

    if (JSON.stringify(replayTypes) !== JSON.stringify(catchupTypes)) {
      throw createContractError("replay catch-up event types differ from previous reconnect", {
        phase: "stream-3-type-compare",
        catchupTypes,
        replayTypes,
      });
    }
  } finally {
    await closeUserStreamConnection(stream3);
  }

  return {
    baselineSeq,
    catchupSeqs,
    replaySeqs,
    catchupTypes,
    stream1Events: stream1.events,
    stream2Events: stream2.events,
    stream3Events: stream3.events,
    gapRun,
  };
}

async function runUserStreamRingMissContract({
  streamWsUrl,
  deviceToken,
  sessionId,
  overflowPromptCount,
}) {
  const streamMiss1 = await openUserStreamConnection({
    streamWsUrl,
    deviceToken,
    label: "stream-miss-conn-1",
  });

  const prompts = Number.isInteger(overflowPromptCount) && overflowPromptCount > 0
    ? overflowPromptCount
    : 1;

  let baselineSeq = 0;
  let latestSeq = 0;

  try {
    await subscribeUserStreamSession(streamMiss1, {
      sessionId,
      level: "full",
      sinceSeq: 0,
      requestId: "req-stream-miss-subscribe-1",
    });

    await sendUserStreamPrompt(streamMiss1, {
      sessionId,
      requestId: "req-stream-miss-baseline",
      message: "Reply with exactly STREAM_RING_BASELINE_OK. Do not use tools.",
    });

    const baselineEvents = getSessionSeqEvents(streamMiss1.events, sessionId);
    baselineSeq = baselineEvents[baselineEvents.length - 1]?.sessionSeq ?? 0;
    if (!Number.isInteger(baselineSeq) || baselineSeq <= 0) {
      throw createContractError("failed to capture baseline seq for ring miss scenario", {
        phase: "stream-miss-baseline",
        eventTail: streamMiss1.events.slice(-40),
      });
    }

    for (let i = 0; i < prompts; i += 1) {
      await sendUserStreamPrompt(streamMiss1, {
        sessionId,
        requestId: `req-stream-miss-overflow-${i + 1}`,
        message: `Reply with exactly STREAM_RING_OVERFLOW_${i + 1}. Do not use tools.`,
      });
    }

    const latestEvents = getSessionSeqEvents(streamMiss1.events, sessionId);
    latestSeq = latestEvents[latestEvents.length - 1]?.sessionSeq ?? 0;

    if (!Number.isInteger(latestSeq) || latestSeq <= baselineSeq) {
      throw createContractError(
        `ring miss overflow failed to advance seq (baseline=${baselineSeq}, latest=${latestSeq})`,
        {
          phase: "stream-miss-overflow",
          baselineSeq,
          latestSeq,
          prompts,
          eventTail: streamMiss1.events.slice(-60),
        },
      );
    }
  } finally {
    await closeUserStreamConnection(streamMiss1);
  }

  const streamMiss2 = await openUserStreamConnection({
    streamWsUrl,
    deviceToken,
    label: "stream-miss-conn-2",
  });

  let missCatchUpComplete = null;
  let missCatchupCount = 0;
  let messagesCount;

  try {
    const subscribe2 = await subscribeUserStreamSession(streamMiss2, {
      sessionId,
      level: "full",
      sinceSeq: baselineSeq,
      requestId: "req-stream-miss-subscribe-2",
    });

    missCatchUpComplete = subscribe2.rpcData?.catchUpComplete;
    missCatchupCount = subscribe2.catchupEvents.length;

    if (missCatchUpComplete !== false) {
      throw createContractError("expected reconnect subscribe to report catchUpComplete=false", {
        phase: "stream-miss-subscribe-2",
        baselineSeq,
        latestSeq,
        prompts,
        rpcData: subscribe2.rpcData,
        catchupEvents: subscribe2.catchupEvents,
        eventTail: streamMiss2.events.slice(-60),
      });
    }

    if (missCatchupCount !== 0) {
      throw createContractError("expected no catch-up events when catchUpComplete=false", {
        phase: "stream-miss-catchup-empty",
        missCatchupCount,
        catchupEvents: subscribe2.catchupEvents,
      });
    }

    const hasStateSnapshot = subscribe2.windowEvents.some(
      (event) => event.direction === "in" && event.type === "state" && event.sessionId === sessionId,
    );
    if (!hasStateSnapshot) {
      throw createContractError("expected state snapshot on subscribe when catchUpComplete=false", {
        phase: "stream-miss-state-snapshot",
        eventTail: streamMiss2.events.slice(-40),
      });
    }

    const messagesRpc = await sendUserStreamCommandAndWaitRpc(streamMiss2, {
      sessionId,
      type: "get_messages",
      requestId: "req-stream-miss-get-messages",
    });

    if (messagesRpc.success !== true) {
      throw createContractError(`get_messages fallback failed: ${messagesRpc.error || "unknown"}`, {
        phase: "stream-miss-get-messages",
        messagesRpc,
      });
    }

    messagesCount = Array.isArray(messagesRpc.data)
      ? messagesRpc.data.length
      : Array.isArray(messagesRpc.data?.messages)
        ? messagesRpc.data.messages.length
        : undefined;
  } finally {
    await closeUserStreamConnection(streamMiss2);
  }

  return {
    baselineSeq,
    latestSeq,
    prompts,
    missCatchUpComplete,
    missCatchupCount,
    messagesCount,
    streamMiss1Events: streamMiss1.events,
    streamMiss2Events: streamMiss2.events,
  };
}

async function runUserStreamTurnAndStopContract({ streamWsUrl, deviceToken, sessionId }) {
  const stream = await openUserStreamConnection({
    streamWsUrl,
    deviceToken,
    label: "stream-turn-stop-conn",
  });

  const approver = startPermissionAutoApprover(stream, sessionId);

  const clientTurnId = `turn-dedupe-${Date.now().toString(36)}`;
  const dedupeMessage = "Reply with exactly TURN_DEDUPE_OK. Do not use tools.";

  try {
    await subscribeUserStreamSession(stream, {
      sessionId,
      level: "full",
      sinceSeq: 0,
      requestId: "req-turn-stop-subscribe",
    });

    const dedupeStartIndex = stream.events.length;

    stream.send({
      type: "prompt",
      sessionId,
      message: dedupeMessage,
      requestId: "req-turn-dedupe-1",
      clientTurnId,
    });

    const { event: firstPromptRpc } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "rpc_result"
        && event.command === "prompt"
        && event.requestId === "req-turn-dedupe-1"
        && event.sessionId === sessionId,
      { label: "first dedupe prompt rpc_result" },
    );

    if (firstPromptRpc.success !== true) {
      throw createContractError(`first dedupe prompt failed: ${firstPromptRpc.error || "unknown"}`);
    }

    await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "turn_ack"
        && event.clientTurnId === clientTurnId
        && event.stage === "accepted"
        && event.requestId === "req-turn-dedupe-1"
        && event.sessionId === sessionId,
      { startIndex: dedupeStartIndex, label: "turn_ack accepted for first prompt" },
    );

    await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "turn_ack"
        && event.clientTurnId === clientTurnId
        && event.stage === "dispatched"
        && event.requestId === "req-turn-dedupe-1"
        && event.sessionId === sessionId,
      { startIndex: dedupeStartIndex, label: "turn_ack dispatched for first prompt" },
    );

    stream.send({
      type: "prompt",
      sessionId,
      message: dedupeMessage,
      requestId: "req-turn-dedupe-2",
      clientTurnId,
    });

    const { event: duplicatePromptRpc } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "rpc_result"
        && event.command === "prompt"
        && event.requestId === "req-turn-dedupe-2"
        && event.sessionId === sessionId,
      { startIndex: dedupeStartIndex, label: "duplicate dedupe prompt rpc_result" },
    );

    if (duplicatePromptRpc.success !== true) {
      throw createContractError(`duplicate dedupe prompt failed: ${duplicatePromptRpc.error || "unknown"}`);
    }

    const { event: duplicateAck } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "turn_ack"
        && event.clientTurnId === clientTurnId
        && event.requestId === "req-turn-dedupe-2"
        && event.duplicate === true
        && event.sessionId === sessionId,
      { startIndex: dedupeStartIndex, label: "duplicate turn_ack" },
    );

    stream.send({
      type: "prompt",
      sessionId,
      message: "Reply with exactly TURN_CONFLICT_FAIL.",
      requestId: "req-turn-conflict-1",
      clientTurnId,
    });

    const { event: conflictRpc } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "rpc_result"
        && event.command === "prompt"
        && event.requestId === "req-turn-conflict-1"
        && event.sessionId === sessionId,
      { startIndex: dedupeStartIndex, label: "clientTurnId conflict rpc_result" },
    );

    if (conflictRpc.success !== false || !String(conflictRpc.error || "").includes("clientTurnId conflict")) {
      throw createContractError("expected clientTurnId conflict rpc_result failure", {
        conflictRpc,
      });
    }

    await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "agent_end"
        && event.sessionId === sessionId,
      {
        startIndex: dedupeStartIndex,
        label: "agent_end after dedupe prompt",
      },
    );

    const dedupeWindow = stream.events.slice(dedupeStartIndex);
    const dedupeAgentStarts = dedupeWindow.filter(
      (event) => event.direction === "in" && event.type === "agent_start" && event.sessionId === sessionId,
    ).length;

    if (dedupeAgentStarts !== 1) {
      throw createContractError(`expected exactly one agent_start for dedupe window, got ${dedupeAgentStarts}`);
    }

    const startedAck = dedupeWindow.find(
      (event) =>
        event.direction === "in"
        && event.type === "turn_ack"
        && event.clientTurnId === clientTurnId
        && event.stage === "started"
        && event.sessionId === sessionId,
    );
    if (!startedAck) {
      throw createContractError("missing turn_ack started for dedupe turn");
    }

    const stopStartIndex = stream.events.length;

    stream.send({
      type: "prompt",
      sessionId,
      message:
        "Use exactly one bash tool call: sleep 15 && echo STOP_CONTRACT_DONE. After the tool finishes, reply with one short line: STOP_CONTRACT_DONE",
      requestId: "req-stop-long-prompt",
      clientTurnId: `turn-stop-${Date.now().toString(36)}`,
    });

    const { event: stopPromptRpc } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "rpc_result"
        && event.command === "prompt"
        && event.requestId === "req-stop-long-prompt"
        && event.sessionId === sessionId,
      {
        startIndex: stopStartIndex,
        label: "stop prompt rpc_result",
      },
    );

    if (stopPromptRpc.success !== true) {
      throw createContractError(`stop prompt rpc_result failed: ${stopPromptRpc.error || "unknown"}`);
    }

    const { index: toolStartIndex } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "tool_start"
        && event.sessionId === sessionId
        && String(event.tool || "").includes("bash"),
      {
        startIndex: stopStartIndex,
        label: "long bash tool_start before stop",
      },
    );

    stream.send({
      type: "stop",
      sessionId,
      requestId: "req-stop-1",
    });

    const { event: stopRpc1 } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "rpc_result"
        && event.command === "stop"
        && event.requestId === "req-stop-1"
        && event.sessionId === sessionId,
      {
        startIndex: toolStartIndex,
        label: "first stop rpc_result",
      },
    );

    if (stopRpc1.success !== true) {
      throw createContractError(`first stop rpc_result failed: ${stopRpc1.error || "unknown"}`);
    }

    stream.send({
      type: "stop",
      sessionId,
      requestId: "req-stop-2",
    });

    const { event: stopRpc2 } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "rpc_result"
        && event.command === "stop"
        && event.requestId === "req-stop-2"
        && event.sessionId === sessionId,
      {
        startIndex: toolStartIndex,
        label: "second stop rpc_result",
      },
    );

    if (stopRpc2.success !== true) {
      throw createContractError(`second stop rpc_result failed: ${stopRpc2.error || "unknown"}`);
    }

    const { event: stopRequested, index: stopRequestedIndex } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.type === "stop_requested"
        && event.sessionId === sessionId
        && event.source === "user",
      {
        startIndex: toolStartIndex,
        label: "user stop_requested",
      },
    );

    const { event: stopTerminal, index: stopTerminalIndex } = await waitForWsEvent(
      stream,
      (event) =>
        event.direction === "in"
        && event.sessionId === sessionId
        && (event.type === "stop_confirmed" || event.type === "stop_failed"),
      {
        startIndex: stopRequestedIndex,
        timeoutMs: Math.max(STREAM_STEP_TIMEOUT_MS, 25_000),
        label: "stop terminal event",
      },
    );

    const stopWindow = stream.events.slice(stopStartIndex, stopTerminalIndex + 1);
    const userStopRequestedCount = stopWindow.filter(
      (event) =>
        event.direction === "in"
        && event.type === "stop_requested"
        && event.sessionId === sessionId
        && event.source === "user",
    ).length;

    if (userStopRequestedCount !== 1) {
      throw createContractError(
        `expected exactly one user stop_requested event, got ${userStopRequestedCount}`,
      );
    }

    if (stopTerminal.type === "stop_failed") {
      await waitForWsEvent(
        stream,
        (event) =>
          event.direction === "in"
          && event.type === "state"
          && event.sessionId === sessionId
          && typeof event.sessionStatus === "string"
          && event.sessionStatus !== "stopping",
        {
          startIndex: stopTerminalIndex,
          label: "state recovery after stop_failed",
        },
      );
    }

    return {
      clientTurnId,
      dedupeAgentStarts,
      duplicateAckStage: duplicateAck.stage,
      stopRequestedSource: stopRequested.source,
      stopTerminalType: stopTerminal.type,
      userStopRequestedCount,
      permissionAutoApprovedCount: approver.getApprovedCount(),
      streamTurnStopEvents: stream.events,
    };
  } finally {
    approver.stop();
    await closeUserStreamConnection(stream);
  }
}

async function runWebSocketContract({ wsUrl, deviceToken, expectedSessionId }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl, {
      headers: { Authorization: `Bearer ${deviceToken}` },
    });

    const startedAt = Date.now();
    let seq = 0;

    const state = {
      connected: false,
      connectedSessionId: "",
      promptRpcOk: false,
      promptAssistantText: "",
      agentStarted: false,
      agentEnded: false,
      permissionRequestIds: [],
      permissionResponseIds: [],
      toolStarts: [],
      toolOutputs: [],
      toolEnds: [],
      events: [],
      errors: [],
    };

    let finished = false;
    let noProgressTimer = null;

    const recordEvent = (direction, msg) => {
      const event = {
        seq: ++seq,
        atMs: Date.now() - startedAt,
        direction,
        type: typeof msg?.type === "string" ? msg.type : "unknown",
      };

      if (typeof msg?.requestId === "string") event.requestId = msg.requestId;
      if (typeof msg?.command === "string") event.command = msg.command;
      if (typeof msg?.id === "string") event.id = msg.id;
      if (typeof msg?.tool === "string") event.tool = msg.tool;
      if (typeof msg?.toolCallId === "string") event.toolCallId = msg.toolCallId;
      if (typeof msg?.success === "boolean") event.success = msg.success;
      if (typeof msg?.error === "string") event.error = msg.error;
      if (typeof msg?.output === "string") event.output = msg.output;

      state.events.push(event);
    };

    const sendClientMessage = (payload) => {
      recordEvent("out", payload);
      ws.send(JSON.stringify(payload));
    };

    const makeError = (message) => {
      const err = new Error(message);
      err.contractState = {
        ...state,
        durationMs: Date.now() - startedAt,
        eventTail: state.events.slice(-30),
      };
      return err;
    };

    const done = (err = null) => {
      if (finished) return;
      finished = true;

      clearTimeout(globalTimer);
      if (noProgressTimer) clearTimeout(noProgressTimer);

      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        ws.close();
      }

      if (err) {
        reject(err);
      } else {
        resolve({
          ...state,
          durationMs: Date.now() - startedAt,
        });
      }
    };

    const resetNoProgressTimer = () => {
      if (noProgressTimer) clearTimeout(noProgressTimer);
      noProgressTimer = setTimeout(() => {
        state.errors.push(`no-progress timeout after ${NO_PROGRESS_TIMEOUT_MS}ms`);
        try {
          sendClientMessage({ type: "stop", requestId: "req-contract-timeout-stop" });
          sendClientMessage({ type: "stop_session", requestId: "req-contract-timeout-stop-session" });
        } catch {
          // ignore timeout escalation send failures
        }
        done(makeError(`websocket no-progress timeout (${NO_PROGRESS_TIMEOUT_MS}ms)`));
      }, NO_PROGRESS_TIMEOUT_MS);
    };

    const globalTimer = setTimeout(() => {
      state.errors.push(`global timeout after ${RUN_TIMEOUT_MS}ms`);
      try {
        sendClientMessage({ type: "stop", requestId: "req-contract-global-stop" });
        sendClientMessage({ type: "stop_session", requestId: "req-contract-global-stop-session" });
      } catch {
        // ignore timeout escalation send failures
      }
      done(makeError(`websocket global timeout (${RUN_TIMEOUT_MS}ms)`));
    }, RUN_TIMEOUT_MS);

    const assertCompletion = () => {
      if (!state.connected) return;
      if (!state.promptRpcOk) return;
      if (!state.agentStarted || !state.agentEnded) return;
      if (state.promptAssistantText.trim().length === 0) return;

      const bashStarts = state.toolStarts.filter((evt) => String(evt.tool || "").includes("bash"));
      const bashEnds = state.toolEnds.filter((evt) => String(evt.tool || "").includes("bash"));

      if (bashStarts.length === 0 || bashEnds.length === 0) return;

      const start = bashStarts[0];
      const end = bashEnds[0];

      if (start.toolCallId && end.toolCallId && start.toolCallId !== end.toolCallId) {
        done(makeError(`toolCallId mismatch start=${start.toolCallId} end=${end.toolCallId}`));
        return;
      }

      const targetToolCallId = start.toolCallId || end.toolCallId;
      const relevantOutputs = targetToolCallId
        ? state.toolOutputs.filter((evt) => evt.toolCallId === targetToolCallId)
        : state.toolOutputs;

      const sawMarker = relevantOutputs.some((evt) => String(evt.output || "").includes(TOOL_MARKER));
      if (!sawMarker) return;

      done();
    };

    ws.on("open", () => {
      log("websocket opened");
      resetNoProgressTimer();
    });

    ws.on("message", (raw) => {
      resetNoProgressTimer();

      const msg = parseJsonSafe(raw.toString());
      if (!msg || typeof msg !== "object") {
        state.errors.push("received non-JSON websocket payload");
        return;
      }

      recordEvent("in", msg);

      const type = msg.type;

      if (type === "connected") {
        state.connected = true;
        state.connectedSessionId = msg.session?.id || "";

        if (state.connectedSessionId !== expectedSessionId) {
          done(
            makeError(
              `connected session mismatch expected=${expectedSessionId} got=${state.connectedSessionId}`,
            ),
          );
          return;
        }

        sendClientMessage({
          type: "prompt",
          message:
            "Use exactly one bash tool call with this exact command: git push origin main --dry-run; echo CONTRACT_TOOL_OK. After the tool finishes, reply with one short line: PROMPT_CONTRACT_OK",
          requestId: PROMPT_REQUEST_ID,
        });

        return;
      }

      if (type === "rpc_result" && msg.requestId === PROMPT_REQUEST_ID) {
        if (msg.success !== true) {
          done(makeError(`prompt rpc_result not successful: ${msg.error || "unknown"}`));
          return;
        }
        state.promptRpcOk = true;
      }

      if (type === "agent_start") {
        state.agentStarted = true;
      }

      if (type === "text_delta") {
        state.promptAssistantText += msg.delta || "";
      }

      if (type === "message_end") {
        if (msg.role === "assistant" && typeof msg.content === "string") {
          state.promptAssistantText += msg.content;
        }
      }

      if (type === "agent_end") {
        state.agentEnded = true;
      }

      if (type === "permission_request") {
        if (typeof msg.id === "string" && msg.id.length > 0) {
          state.permissionRequestIds.push(msg.id);
          sendClientMessage({
            type: "permission_response",
            id: msg.id,
            action: "allow",
            scope: "once",
            requestId: `req-contract-permission-${msg.id}`,
          });
          state.permissionResponseIds.push(msg.id);
        }
      }

      if (type === "tool_start") {
        state.toolStarts.push({
          tool: msg.tool,
          toolCallId: msg.toolCallId,
        });
      }

      if (type === "tool_output") {
        state.toolOutputs.push({
          output: msg.output,
          toolCallId: msg.toolCallId,
        });
      }

      if (type === "tool_end") {
        state.toolEnds.push({
          tool: msg.tool,
          toolCallId: msg.toolCallId,
        });
      }

      if (type === "error") {
        state.errors.push(msg.error || "unknown websocket error event");
      }

      assertCompletion();
    });

    ws.on("close", (code) => {
      if (!finished) {
        done(makeError(`websocket closed before completion (code=${code})`));
      }
    });

    ws.on("error", (err) => {
      if (!finished) {
        done(makeError(`websocket error: ${err.message}`));
      }
    });
  });
}

async function main() {
  let artifactsDir = "";
  let serverProc;

  try {
    const modelReady = await ensureModelLoaded();
    if (!modelReady) {
      log("skipped (LM Studio model prerequisite not met)");
      return;
    }

    log(`building server (timeout ${BUILD_TIMEOUT_MS}ms)`);
    await spawnWithTimeout("npm", ["run", "build"], {
      cwd: serverDir,
      timeoutMs: BUILD_TIMEOUT_MS,
      stdio: "inherit",
    });

    artifactsDir = mkdtempSync(join(tmpdir(), "oppi-lmstudio-contract-"));
    const baseUrl = `http://127.0.0.1:${PORT}`;

    log(`artifacts dir: ${artifactsDir}`);

    const { Storage } = await import(new URL("../dist/storage.js", import.meta.url));
    const storage = new Storage(artifactsDir);

    storage.updateConfig({
      host: "127.0.0.1",
      port: PORT,
      token: ADMIN_TOKEN,
      defaultModel: SERVER_MODEL_ID,
    });

    const pairingToken = storage.issuePairingToken(5 * 60 * 1000);
    log("issued pairing token");

    const serverLogPath = join(artifactsDir, "server.log");
    const serverLogFd = openSync(serverLogPath, "w");

    serverProc = spawn("node", ["dist/cli.js", "serve"], {
      cwd: serverDir,
      env: {
        ...process.env,
        OPPI_DATA_DIR: artifactsDir,
        OPPI_SESSION_EVENT_RING_CAPACITY: String(SESSION_EVENT_RING_CAPACITY),
      },
      stdio: ["ignore", serverLogFd, serverLogFd],
    });

    closeSync(serverLogFd);

    await waitForHealth(baseUrl);
    log("server healthy");

    const unauth = await apiRequest(baseUrl, "GET", "/me", "", undefined);
    if (unauth.status !== 401) {
      throw new Error(`expected unauthenticated /me to return 401, got ${unauth.status}`);
    }

    const pairRes = await apiRequest(baseUrl, "POST", "/pair", "", {
      pairingToken,
      deviceName: "lmstudio-contract",
    });

    if (pairRes.status !== 200 || !pairRes.json?.deviceToken) {
      throw new Error(`pair failed status=${pairRes.status} body=${pairRes.text}`);
    }

    const replayPairRes = await apiRequest(baseUrl, "POST", "/pair", "", {
      pairingToken,
      deviceName: "lmstudio-contract-replay",
    });
    if (replayPairRes.status !== 401) {
      throw new Error(`expected replayed pairing token to fail with 401, got ${replayPairRes.status}`);
    }

    const deviceToken = pairRes.json.deviceToken;
    log(`paired device token: ${deviceToken.slice(0, 12)}...`);

    const meRes = await apiRequest(baseUrl, "GET", "/me", deviceToken, undefined);
    if (meRes.status !== 200) {
      throw new Error(`device token auth failed status=${meRes.status}`);
    }

    const wsRes = await apiRequest(baseUrl, "POST", "/workspaces", deviceToken, {
      name: "lmstudio-contract-ws",
      skills: [],
      runtime: "host",
      defaultModel: SERVER_MODEL_ID,
    });

    if (wsRes.status !== 201 || !wsRes.json?.workspace?.id) {
      throw new Error(`workspace create failed status=${wsRes.status} body=${wsRes.text}`);
    }

    const workspaceId = wsRes.json.workspace.id;
    log(`workspace created: ${workspaceId}`);

    const sessionRes = await apiRequest(
      baseUrl,
      "POST",
      `/workspaces/${workspaceId}/sessions`,
      deviceToken,
      { model: SERVER_MODEL_ID },
    );

    if (sessionRes.status !== 201 || !sessionRes.json?.session?.id) {
      throw new Error(`session create failed status=${sessionRes.status} body=${sessionRes.text}`);
    }

    const session = sessionRes.json.session;
    const sessionId = session.id;

    if (session.model !== SERVER_MODEL_ID) {
      throw new Error(`session model mismatch expected=${SERVER_MODEL_ID} got=${session.model}`);
    }

    log(`session created: ${sessionId}`);

    const mismatchWsRes = await apiRequest(baseUrl, "POST", "/workspaces", deviceToken, {
      name: "lmstudio-contract-mismatch",
      skills: [],
      runtime: "host",
      defaultModel: SERVER_MODEL_ID,
    });

    if (mismatchWsRes.status !== 201 || !mismatchWsRes.json?.workspace?.id) {
      throw new Error(
        `mismatch workspace create failed status=${mismatchWsRes.status} body=${mismatchWsRes.text}`,
      );
    }

    const mismatchWorkspaceId = mismatchWsRes.json.workspace.id;

    const wsUrl = `ws://127.0.0.1:${PORT}/workspaces/${workspaceId}/sessions/${sessionId}/stream`;
    const mismatchWsUrl = `ws://127.0.0.1:${PORT}/workspaces/${mismatchWorkspaceId}/sessions/${sessionId}/stream`;

    await expectWsUpgradeFailure({
      wsUrl,
      token: "",
      expectedStatus: 401,
      label: "ws upgrade missing auth",
    });

    await expectWsUpgradeFailure({
      wsUrl,
      token: `${deviceToken}_invalid`,
      expectedStatus: 401,
      label: "ws upgrade bad token",
    });

    await expectWsUpgradeFailure({
      wsUrl: mismatchWsUrl,
      token: deviceToken,
      expectedStatus: 404,
      label: "ws upgrade workspace/session mismatch",
    });

    log("negative auth/path handshake checks passed");

    const sessionContract = await runWebSocketContract({
      wsUrl,
      deviceToken,
      expectedSessionId: sessionId,
    });

    validateContractResult(sessionContract);

    const streamWsUrl = `ws://127.0.0.1:${PORT}/stream`;
    const reconnectContract = await runUserStreamReconnectContract({
      streamWsUrl,
      sessionWsUrl: wsUrl,
      deviceToken,
      sessionId,
    });

    const ringMissContract = await runUserStreamRingMissContract({
      streamWsUrl,
      deviceToken,
      sessionId,
      overflowPromptCount: STREAM_RING_MISS_PROMPTS,
    });

    const turnStopContract = await runUserStreamTurnAndStopContract({
      streamWsUrl,
      deviceToken,
      sessionId,
    });

    const summaryPath = join(artifactsDir, "contract-summary.json");
    const transcriptPath = join(artifactsDir, "ws-transcript-primary.json");
    const gapTranscriptPath = join(artifactsDir, "ws-transcript-gap.json");
    const streamTranscript1Path = join(artifactsDir, "stream-transcript-1.json");
    const streamTranscript2Path = join(artifactsDir, "stream-transcript-2.json");
    const streamTranscript3Path = join(artifactsDir, "stream-transcript-3.json");
    const streamMissTranscript1Path = join(artifactsDir, "stream-miss-transcript-1.json");
    const streamMissTranscript2Path = join(artifactsDir, "stream-miss-transcript-2.json");
    const streamTurnStopTranscriptPath = join(artifactsDir, "stream-turn-stop-transcript.json");

    writeFileSync(transcriptPath, JSON.stringify(sessionContract.events, null, 2));
    writeFileSync(gapTranscriptPath, JSON.stringify(reconnectContract.gapRun.events, null, 2));
    writeFileSync(streamTranscript1Path, JSON.stringify(reconnectContract.stream1Events, null, 2));
    writeFileSync(streamTranscript2Path, JSON.stringify(reconnectContract.stream2Events, null, 2));
    writeFileSync(streamTranscript3Path, JSON.stringify(reconnectContract.stream3Events, null, 2));
    writeFileSync(streamMissTranscript1Path, JSON.stringify(ringMissContract.streamMiss1Events, null, 2));
    writeFileSync(streamMissTranscript2Path, JSON.stringify(ringMissContract.streamMiss2Events, null, 2));
    writeFileSync(streamTurnStopTranscriptPath, JSON.stringify(turnStopContract.streamTurnStopEvents, null, 2));

    const bashStarts = sessionContract.toolStarts.filter((evt) => String(evt.tool || "").includes("bash")).length;
    const bashEnds = sessionContract.toolEnds.filter((evt) => String(evt.tool || "").includes("bash")).length;
    const gapBashStarts = reconnectContract.gapRun.toolStarts.filter(
      (evt) => String(evt.tool || "").includes("bash"),
    ).length;
    const gapBashEnds = reconnectContract.gapRun.toolEnds.filter(
      (evt) => String(evt.tool || "").includes("bash"),
    ).length;

    writeFileSync(
      summaryPath,
      JSON.stringify(
        {
          model: SERVER_MODEL_ID,
          primarySessionContract: {
            durationMs: sessionContract.durationMs,
            permissionRequests: sessionContract.permissionRequestIds.length,
            permissionResponses: sessionContract.permissionResponseIds.length,
            assistantChars: sessionContract.promptAssistantText.trim().length,
            toolStarts: sessionContract.toolStarts.length,
            toolOutputs: sessionContract.toolOutputs.length,
            toolEnds: sessionContract.toolEnds.length,
          },
          reconnectCatchUpContract: {
            baselineSeq: reconnectContract.baselineSeq,
            catchupSeqs: reconnectContract.catchupSeqs,
            replaySeqs: reconnectContract.replaySeqs,
            catchupTypes: reconnectContract.catchupTypes,
            gapRunDurationMs: reconnectContract.gapRun.durationMs,
            gapPermissionRequests: reconnectContract.gapRun.permissionRequestIds.length,
            gapPermissionResponses: reconnectContract.gapRun.permissionResponseIds.length,
          },
          ringMissContract: {
            eventRingCapacity: SESSION_EVENT_RING_CAPACITY,
            overflowPrompts: ringMissContract.prompts,
            baselineSeq: ringMissContract.baselineSeq,
            latestSeq: ringMissContract.latestSeq,
            catchUpComplete: ringMissContract.missCatchUpComplete,
            catchUpEventCount: ringMissContract.missCatchupCount,
            fallbackMessagesCount: ringMissContract.messagesCount,
          },
          turnIdempotencyAndStopContract: {
            clientTurnId: turnStopContract.clientTurnId,
            dedupeAgentStarts: turnStopContract.dedupeAgentStarts,
            duplicateAckStage: turnStopContract.duplicateAckStage,
            stopRequestedSource: turnStopContract.stopRequestedSource,
            stopTerminalType: turnStopContract.stopTerminalType,
            userStopRequestedCount: turnStopContract.userStopRequestedCount,
            permissionAutoApprovedCount: turnStopContract.permissionAutoApprovedCount,
          },
        },
        null,
        2,
      ),
    );

    log("contract assertions passed");
    log(`primary duration: ${sessionContract.durationMs}ms`);
    log(`primary assistant chars: ${sessionContract.promptAssistantText.trim().length}`);
    log(`primary permission requests/responses: ${sessionContract.permissionRequestIds.length}/${sessionContract.permissionResponseIds.length}`);
    log(`primary bash tool events: start=${bashStarts}, output=${sessionContract.toolOutputs.length}, end=${bashEnds}`);
    log(`reconnect baseline seq: ${reconnectContract.baselineSeq}`);
    log(`reconnect catch-up seqs: ${reconnectContract.catchupSeqs.join(",")}`);
    log(`replay catch-up seqs: ${reconnectContract.replaySeqs.join(",")}`);
    log(`gap bash tool events: start=${gapBashStarts}, output=${reconnectContract.gapRun.toolOutputs.length}, end=${gapBashEnds}`);
    log(`ring miss config: capacity=${SESSION_EVENT_RING_CAPACITY}, prompts=${ringMissContract.prompts}`);
    log(`ring miss seqs: baseline=${ringMissContract.baselineSeq}, latest=${ringMissContract.latestSeq}`);
    log(`ring miss catchUpComplete=${ringMissContract.missCatchUpComplete}, catchupEvents=${ringMissContract.missCatchupCount}`);
    log(`ring miss fallback get_messages count=${ringMissContract.messagesCount ?? "n/a"}`);
    log(`turn dedupe agent_starts=${turnStopContract.dedupeAgentStarts}, duplicate_ack_stage=${turnStopContract.duplicateAckStage}`);
    log(`stop contract terminal=${turnStopContract.stopTerminalType}, user_stop_requested_count=${turnStopContract.userStopRequestedCount}`);
    log(`stop contract permission_auto_approved=${turnStopContract.permissionAutoApprovedCount}`);
    log(`artifacts: ${artifactsDir}`);

    await stopServer(serverProc);

    if (!KEEP_ARTIFACTS) {
      rmSync(artifactsDir, { recursive: true, force: true });
    }

    process.exit(0);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[contract] FAIL: ${message}`);

    if (artifactsDir && err && typeof err === "object" && err.contractState) {
      try {
        writeFileSync(
          join(artifactsDir, "contract-failure-state.json"),
          JSON.stringify(err.contractState, null, 2),
        );
      } catch {
        // ignore artifact write failures
      }
    }

    if (serverProc) {
      await stopServer(serverProc);
    }

    if (artifactsDir) {
      console.error(`[contract] artifacts kept at: ${artifactsDir}`);
      if (!KEEP_ARTIFACTS) {
        console.error("[contract] set KEEP_E2E_ARTIFACTS=1 to preserve artifacts on success as well");
      }
    }

    process.exit(1);
  }
}

main();

#!/usr/bin/env bun
/** Owned throwaway server; faux replaces only the external model provider. No owner credentials. */
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { request } from "node:http";
import { createConnection } from "node:net";
import WebSocket from "ws";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxProvider, fauxAssistantMessage } from "@earendil-works/pi-ai/providers/faux";

const dir = mkdtempSync(join(tmpdir(), "oppi-durable-trace-smoke-"));
chmodSync(dir, 0o700);
const agentDir = join(dir, "pi-agent");
mkdirSync(agentDir);
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_AGENT_SYNC_MODE = "skip";
writeFileSync(
  join(agentDir, "settings.json"),
  JSON.stringify({
    defaultProvider: "faux",
    defaultModel: "faux-1",
    compaction: { enabled: false },
    packages: [],
    extensions: [],
  }),
);
const originalCreate = ModelRuntime.create;
ModelRuntime.create = async (options) => {
  const models = await originalCreate.call(ModelRuntime, { ...options, refreshOnCreate: false });
  const faux = fauxProvider();
  faux.setResponses([
    fauxAssistantMessage("answer one"),
    fauxAssistantMessage("answer two"),
    fauxAssistantMessage("answer three"),
  ]);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  return models;
};
// Compiled production server, isolated storage and the ordinary local HTTP/WS listeners.
const { Storage } = await import("../dist/src/storage.js");
const { Server } = await import("../dist/src/server.js");
const { localApiSocketPath } = await import("../dist/src/local-api-socket.js");
const storage = new Storage(join(dir, "data"));
storage.updateConfig({
  host: "127.0.0.1",
  port: 0,
  tls: { mode: "disabled" },
  experimental: { serverDurable: true },
});
// Direct construction does not run CLI pairing bootstrap.
storage.ensurePaired();
const server = new Server(storage);
const socketPath = localApiSocketPath(storage.getDataDir());
const evidence: string[] = [];
function record(line: string) {
  evidence.push(line);
  console.log(line);
  writeFileSync(join(dir, "receipt.txt"), evidence.join("\n") + "\n");
}
async function api(path: string, body?: unknown): Promise<any> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        socketPath,
        path,
        method: body === undefined ? "GET" : "POST",
        headers: {
          Authorization: `Bearer ${storage.getToken()}`,
          "Content-Type": "application/json",
        },
        signal: AbortSignal.timeout(15_000),
        agent: false,
      },
      (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => (text += chunk));
        res.on("error", reject);
        res.on("end", () => {
          try {
            assert(
              (res.statusCode ?? 0) >= 200 && (res.statusCode ?? 0) < 300,
              `${path}: HTTP ${res.statusCode}`,
            );
            resolve(JSON.parse(text));
          } catch (error) {
            reject(error);
          }
        });
      },
    );
    req.on("error", reject);
    req.end(body === undefined ? undefined : JSON.stringify(body));
  });
}
let ws: WebSocket | undefined;
try {
  await server.start();
  assert.deepEqual(await api("/health"), { ok: true, protocol: 2 });
  record(
    `doctor: owned compiled server healthy; artifacts=${dir}; provider=faux (no real-model/device claim)`,
  );
  const { workspace } = await api("/workspaces", { name: "Durable trace smoke", hostMount: dir });
  const { session } = await api(`/workspaces/${workspace.id}/sessions`, {
    name: "History proof",
    model: "faux/faux-1",
    thinking: "off",
    autoStop: false,
  });
  const path = `/workspaces/${workspace.id}/sessions/${session.id}`;
  ws = new WebSocket(`ws://localhost${path}/stream`, {
    headers: { Authorization: `Bearer ${storage.getToken()}` },
    createConnection: () => createConnection(socketPath),
  });
  const messages: any[] = [];
  let notify = () => {};
  ws.on("message", (data) => {
    messages.push(JSON.parse(data.toString()));
    notify();
  });
  async function next(type: string, from = 0): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () =>
          reject(
            new Error(`WS ${type} timeout; observed ${messages.slice(from).map((m) => m.type)}`),
          ),
        15_000,
      );
      notify = () => {
        if (messages.slice(from).some((m) => m.type === type)) {
          clearTimeout(timer);
          resolve();
        }
      };
      notify();
    });
  }
  await next("stream_connected");
  for (const [index, prompt] of ["turn one", "turn two", "turn three"].entries()) {
    const from = messages.length;
    ws.send(
      JSON.stringify({ type: "prompt", message: prompt, clientTurnId: `trace-smoke-${index}` }),
    );
    await next("agent_end", from);
  }
  assert.equal((await api(`${path}/trace-page`)).trace.length, 6);
  record("live: trace-page returned all 6 events from 3 turns");
  await api(`/sessions/${session.id}/stop`, {});
  const full = await api(`/sessions/${session.id}/trace?view=full`);
  const page = await api(`${path}/trace-page`);
  const outline = await api(`${path}/trace-outline`);
  assert.equal(full.trace.length, 6);
  assert.deepEqual(
    full.trace.filter((event: any) => event.type === "user").map((event: any) => event.text),
    ["turn one", "turn two", "turn three"],
  );
  assert.deepEqual(page.trace, full.trace);
  assert.deepEqual(
    outline.outline.entries.map((entry: any) => entry.id),
    full.trace.map((event: any) => event.id),
  );
  for (const [name, value] of Object.entries({ full, page, outline }))
    writeFileSync(join(dir, `${name}.json`), JSON.stringify(value, null, 2));
  record(
    `stopped: session=${session.id}; full=6 page=6 outline=6; page events byte-equal to full; outline IDs equal`,
  );
} finally {
  ws?.terminate();
  await server.stop();
  ModelRuntime.create = originalCreate;
  record("owned server stopped; all receipts and response artifacts retained");
}

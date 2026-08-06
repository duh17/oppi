import { createServer as createHttpServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { generateInvite } from "../dist/src/invite.js";
import {
  irohInviteTransportFromState,
  readIrohInviteState,
} from "../dist/src/iroh-invite-state.js";
import { Server } from "../dist/src/server.js";
import { Storage } from "../dist/src/storage.js";

const dataDir = process.env.OPPI_DATA_DIR ?? "/data/oppi";
const piAgentDir = process.env.PI_CODING_AGENT_DIR ?? "/data/pi-agent";
const exchangeDir = "/exchange";
const workspaceDir = "/workspace";
const httpPort = 17760;
const sttPort = 19090;

mkdirSync(dataDir, { recursive: true, mode: 0o700 });
mkdirSync(piAgentDir, { recursive: true, mode: 0o700 });
mkdirSync(exchangeDir, { recursive: true });
mkdirSync(workspaceDir, { recursive: true });
writeFileSync(join(workspaceDir, "fixture.txt"), "0123456789abcdefghijklmnopqrstuvwxyz\n");
writeFileSync(
  join(piAgentDir, "models.json"),
  JSON.stringify({
    providers: {
      stub: {
        baseUrl: "http://127.0.0.1:19091/v1",
        apiKey: "stub",
        api: "openai-completions",
        models: [
          {
            id: "deterministic",
            name: "Deterministic Iroh E2E Stub",
            contextWindow: 8192,
            maxTokens: 1024,
            input: ["text"],
            reasoning: false,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          },
        ],
      },
    },
  }),
);

let nextSttSession = 1;
const sttServer = createHttpServer((req, res) => {
  const path = req.url ?? "/";
  if (req.method === "POST" && path === "/v1/audio/transcriptions/stream") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ session_id: `stub-${nextSttSession++}` }));
    return;
  }
  if (req.method === "POST" && path.startsWith("/v1/audio/transcriptions/stream/")) {
    req.resume();
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ text: "stub transcript", committed_text: "stub transcript" }));
    return;
  }
  if (req.method === "DELETE" && path.startsWith("/v1/audio/transcriptions/stream/")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ text: "stub transcript", committed_text: "stub transcript" }));
    return;
  }
  res.writeHead(404).end();
});
await new Promise<void>((resolve, reject) => {
  sttServer.once("error", reject);
  sttServer.listen(sttPort, "127.0.0.1", resolve);
});

const storage = new Storage(dataDir);
storage.updateConfig({
  host: "127.0.0.1",
  port: httpPort,
  tls: { mode: "disabled" },
  asr: { sttEndpoint: `http://127.0.0.1:${sttPort}` },
});

const server = new Server(storage);
await server.start();
const iroh = irohInviteTransportFromState(readIrohInviteState(dataDir));
if (!iroh) throw new Error("Iroh invite state missing after server readiness");
const irohPairingInvite = generateInvite(
  storage,
  () => "127.0.0.1",
  () => "iroh-isolated-server",
  {
    inviteVersion: 4,
    preference: "irohOnly",
    transports: { iroh },
    pairingTokenTtlMs: 10 * 60_000,
  },
);
const exchangePath = join(exchangeDir, "invite.json");
const temporaryPath = `${exchangePath}.tmp`;
writeFileSync(
  temporaryPath,
  JSON.stringify({
    irohPairingToken: irohPairingInvite.pairingToken,
    iroh,
    expectedHttpPort: httpPort,
    workspaceDir,
  }),
);
renameSync(temporaryPath, exchangePath);
console.log(JSON.stringify({ event: "iroh_isolated.ready", nodeId: iroh.nodeId }));

const clientNodePath = join(exchangeDir, "client-node.json");
const clientNodeDeadline = Date.now() + 90_000;
while (!existsSync(clientNodePath)) {
  if (Date.now() >= clientNodeDeadline)
    throw new Error("Timed out waiting for Iroh client node ID");
  await new Promise((resolve) => setTimeout(resolve, 100));
}
const clientNode = JSON.parse(readFileSync(clientNodePath, "utf8")) as { clientNodeId?: unknown };
if (typeof clientNode.clientNodeId !== "string" || clientNode.clientNodeId.length === 0) {
  throw new Error("Iroh client node exchange is invalid");
}
const invite = generateInvite(
  storage,
  () => "127.0.0.1",
  () => "iroh-isolated-server",
  {
    inviteVersion: 4,
    preference: "irohPreferred",
    transports: { iroh },
    pairingTokenTtlMs: 10 * 60_000,
  },
);
const pairingResponse = await fetch(`http://127.0.0.1:${httpPort}/pair`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    pairingToken: invite.pairingToken,
    clientNodeId: clientNode.clientNodeId,
  }),
});
if (!pairingResponse.ok) {
  throw new Error(`HTTP pairing failed with status ${pairingResponse.status}`);
}
const credential = (await pairingResponse.json()) as {
  deviceToken?: unknown;
  credentialTransports?: unknown;
};
if (
  typeof credential.deviceToken !== "string" ||
  !Array.isArray(credential.credentialTransports) ||
  credential.credentialTransports.length !== 2 ||
  !credential.credentialTransports.includes("http") ||
  !credential.credentialTransports.includes("iroh")
) {
  throw new Error("HTTP pairing did not issue the expected dual-transport credential");
}
const credentialPath = join(exchangeDir, "credential.json");
const credentialTemporaryPath = `${credentialPath}.tmp`;
writeFileSync(credentialTemporaryPath, JSON.stringify(credential));
renameSync(credentialTemporaryPath, credentialPath);
console.log(JSON.stringify({ event: "iroh_isolated.http_paired" }));

let stopping = false;
async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  await server.stop();
  await new Promise<void>((resolve) => sttServer.close(() => resolve()));
}
process.on("SIGTERM", () => void stop().finally(() => process.exit(0)));
process.on("SIGINT", () => void stop().finally(() => process.exit(0)));
await new Promise<void>(() => {});

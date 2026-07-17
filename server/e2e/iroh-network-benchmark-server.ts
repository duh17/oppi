import { execFileSync } from "node:child_process";
import { lookup } from "node:dns/promises";
import { mkdirSync, renameSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { EndpointTicket } from "@number0/iroh";

import { generateInvite } from "../dist/src/invite.js";
import {
  irohInviteTransportFromState,
  readIrohInviteState,
} from "../dist/src/iroh-invite-state.js";
import { Server } from "../dist/src/server.js";
import { Storage } from "../dist/src/storage.js";

const lane = process.env.BENCH_SERVER_LANE;
if (lane !== "direct" && lane !== "relay") {
  throw new Error("BENCH_SERVER_LANE must be direct or relay");
}

const dataDir = process.env.OPPI_DATA_DIR ?? "/data/oppi";
const piAgentDir = process.env.PI_CODING_AGENT_DIR ?? "/data/pi-agent";
const exchangeDir = "/exchange";
const workspaceDir = "/workspace";
const httpPort = 17760;

mkdirSync(dataDir, { recursive: true, mode: 0o700 });
mkdirSync(piAgentDir, { recursive: true, mode: 0o700 });
mkdirSync(exchangeDir, { recursive: true });
mkdirSync(workspaceDir, { recursive: true });

for (const sizeMiB of [1, 10, 50]) {
  const path = join(workspaceDir, `benchmark-${sizeMiB}m.mp4`);
  writeFileSync(path, "");
  truncateSync(path, sizeMiB * 1024 * 1024);
}

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
            name: "Deterministic Iroh Benchmark Stub",
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

const storage = new Storage(dataDir);
storage.ensurePaired();
storage.updateConfig({
  host: lane === "direct" ? "0.0.0.0" : "127.0.0.1",
  port: httpPort,
  tls: {
    mode: "disabled",
    ...(lane === "direct" ? { allowInsecureNetworkHttp: true } : {}),
  },
  uploadStore: {
    mode: "local",
    path: join(dataDir, "uploads"),
    maxFileBytes: 50 * 1024 * 1024,
    maxTurnBytes: 100 * 1024 * 1024,
    unusedTtlMs: 24 * 60 * 60 * 1000,
  },
});

const server = new Server(storage);
await server.start();
const iroh = irohInviteTransportFromState(readIrohInviteState(dataDir));
if (!iroh?.ticket) throw new Error("Iroh ticket missing after benchmark server readiness");
if (lane === "relay") {
  const relayUrl = EndpointTicket.fromString(iroh.ticket).endpointAddr().relayUrl();
  if (!relayUrl) throw new Error("Iroh relay URL missing after benchmark server readiness");
  const relayAddresses = await lookup(new URL(relayUrl).hostname, { all: true });
  const ipv4Addresses = relayAddresses.filter((item) => item.family === 4);
  if (ipv4Addresses.length === 0) throw new Error("Iroh relay hostname has no IPv4 address");
  for (const address of ipv4Addresses) {
    execFileSync("iptables", ["-A", "OUTPUT", "-p", "udp", "-d", address.address, "-j", "ACCEPT"]);
    execFileSync("iptables", ["-A", "INPUT", "-p", "udp", "-s", address.address, "-j", "ACCEPT"]);
  }
  execFileSync("iptables", ["-A", "OUTPUT", "-p", "udp", "--dport", "53", "-j", "ACCEPT"]);
  execFileSync("iptables", ["-A", "INPUT", "-p", "udp", "--sport", "53", "-j", "ACCEPT"]);
  execFileSync("iptables", ["-A", "OUTPUT", "-p", "udp", "-j", "REJECT"]);
  execFileSync("iptables", ["-A", "INPUT", "-p", "udp", "-j", "DROP"]);
}
const invite = generateInvite(
  storage,
  () => (lane === "direct" ? "iroh-benchmark-direct-server" : null),
  () => "iroh-benchmark-server",
  {
    inviteVersion: 4,
    preference: lane === "direct" ? "irohPreferred" : "irohOnly",
    transports: { iroh },
    pairingTokenTtlMs: 30 * 60_000,
  },
);

const exchangePath = join(exchangeDir, "invite.json");
const temporaryPath = `${exchangePath}.tmp`;
writeFileSync(
  temporaryPath,
  JSON.stringify({
    lane,
    pairingToken: invite.pairingToken,
    expectedHttpPort: httpPort,
    workspaceDir,
    iroh,
  }),
  { mode: 0o600 },
);
renameSync(temporaryPath, exchangePath);
process.stdout.write(`${JSON.stringify({ event: "iroh_benchmark.ready", lane })}\n`);

let stopping = false;
async function stop(): Promise<void> {
  if (stopping) return;
  stopping = true;
  await server.stop();
}
process.on("SIGTERM", () => void stop().finally(() => process.exit(0)));
process.on("SIGINT", () => void stop().finally(() => process.exit(0)));
await new Promise<void>(() => {});

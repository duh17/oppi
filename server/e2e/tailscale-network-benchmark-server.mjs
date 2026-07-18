import { mkdirSync, renameSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { Server } from "../dist/src/server.js";
import { Storage } from "../dist/src/storage.js";

const dataDir = process.env.OPPI_DATA_DIR;
const piAgentDir = process.env.PI_CODING_AGENT_DIR;
const workspaceDir = process.env.BENCH_WORKSPACE_DIR;
const readyPath = process.env.BENCH_READY_PATH;
const bindHost = process.env.BENCH_BIND_HOST;

if (!dataDir || !piAgentDir || !workspaceDir || !readyPath || !bindHost) {
  throw new Error("Missing Tailscale benchmark server environment");
}

mkdirSync(dataDir, { recursive: true, mode: 0o700 });
mkdirSync(piAgentDir, { recursive: true, mode: 0o700 });
mkdirSync(workspaceDir, { recursive: true, mode: 0o700 });

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
            name: "Deterministic Tailscale Benchmark Stub",
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
  { mode: 0o600 },
);

const storage = new Storage(dataDir);
const token = storage.ensurePaired();
storage.updateConfig({
  host: bindHost,
  port: 0,
  tls: { mode: "self-signed" },
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
const temporaryReadyPath = `${readyPath}.tmp`;
writeFileSync(
  temporaryReadyPath,
  JSON.stringify({
    port: server.port,
    token,
    workspaceDir,
    serverVersion: Server.VERSION,
    scheme: server.scheme,
  }),
  { mode: 0o600 },
);
renameSync(temporaryReadyPath, readyPath);
process.stdout.write(`${JSON.stringify({ event: "tailscale_benchmark.ready" })}\n`);

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await server.stop();
}
process.on("SIGTERM", () => void stop().finally(() => process.exit(0)));
process.on("SIGINT", () => void stop().finally(() => process.exit(0)));
await new Promise(() => {});

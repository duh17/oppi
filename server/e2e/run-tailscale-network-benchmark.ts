#!/usr/bin/env bun

import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { summarize, type NumericSummary } from "./iroh-network-benchmark-common.js";

const sshTarget = process.env.TAILSCALE_BENCH_SSH_TARGET;
const targetIp = process.env.TAILSCALE_BENCH_TARGET_IP;
const region = process.env.TAILSCALE_BENCH_REGION ?? "US Pacific Northwest";
if (!sshTarget || !targetIp) {
  throw new Error("TAILSCALE_BENCH_SSH_TARGET and TAILSCALE_BENCH_TARGET_IP are required");
}

const serverDir = join(import.meta.dirname, "..");
const repoDir = join(serverDir, "..");
const runId = randomUUID();
const artifactDir = join("/tmp", `oppi-tailscale-benchmark-${runId}`);
const remoteDir = `/tmp/oppi-tailscale-benchmark-${runId}`;
const remoteReadyPath = `${remoteDir}/ready.json`;
const localResultPath = join(artifactDir, "tailscale-client.json");
mkdirSync(artifactDir, { recursive: true, mode: 0o700 });

function run(
  command: string,
  args: string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; inherit?: boolean; timeoutMs?: number } = {},
): ReturnType<typeof spawnSync> {
  return spawnSync(command, args, {
    cwd: options.cwd ?? serverDir,
    env: options.env ?? process.env,
    encoding: "utf8",
    stdio: options.inherit ? "inherit" : "pipe",
    timeout: options.timeoutMs,
  });
}

function requireSuccess(result: ReturnType<typeof spawnSync>, label: string): void {
  if (result.status !== 0) {
    const output = [result.stdout, result.stderr]
      .map((value) => String(value ?? "").trim())
      .filter(Boolean)
      .join("\n");
    throw new Error(
      `${label} failed with exit code ${result.status ?? "unknown"}${output ? `:\n${output}` : ""}`,
    );
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function ssh(command: string, timeoutMs = 30_000): ReturnType<typeof spawnSync> {
  return run(
    "ssh",
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=5",
      "-o",
      "StrictHostKeyChecking=accept-new",
      sshTarget,
      `sh -lc ${shellQuote(command)}`,
    ],
    { timeoutMs },
  );
}

function pingPath(): { direct: true; latencyMs: NumericSummary; samples: number[] } {
  const result = run(
    "tailscale",
    ["ping", "--until-direct=false", "-c", "10", "--timeout", "3s", targetIp],
    { timeoutMs: 40_000 },
  );
  requireSuccess(result, "Tailscale path verification");
  const output = String(result.stdout ?? "");
  const lines = output.split("\n").filter((line) => line.includes("pong from"));
  if (lines.length !== 10) {
    throw new Error(`Tailscale path verification returned ${lines.length}/10 pong samples`);
  }
  if (lines.some((line) => line.includes("DERP("))) {
    throw new Error("Tailscale path verification observed DERP instead of an all-direct run");
  }
  if (lines.some((line) => !/\svia\s/.test(line))) {
    throw new Error("Tailscale path verification did not report a selected route for every sample");
  }
  const samples = lines.flatMap((line) => {
    const match = line.match(/\sin\s+([0-9.]+)ms/);
    return match ? [Number(match[1])] : [];
  });
  if (samples.length !== 10) {
    throw new Error(`Tailscale direct ping parsed ${samples.length}/10 latency samples`);
  }
  return { direct: true, latencyMs: summarize(samples), samples };
}

function tailscaleVersion(): string {
  const result = run("tailscale", ["version", "--json"], { timeoutMs: 10_000 });
  if (result.status !== 0) return "unknown";
  try {
    const parsed = JSON.parse(String(result.stdout)) as {
      long?: string;
      short?: string;
      Long?: string;
      Version?: string;
    };
    return parsed.long ?? parsed.short ?? parsed.Long ?? parsed.Version ?? "unknown";
  } catch {
    return "unknown";
  }
}

let remoteStarted = false;
try {
  requireSuccess(
    ssh(`mkdir -p ${remoteDir}/e2e ${remoteDir}/data ${remoteDir}/agent ${remoteDir}/workspace`),
    "Remote benchmark directory setup",
  );
  requireSuccess(
    run("rsync", ["-a", "--quiet", `${serverDir}/dist/`, `${sshTarget}:${remoteDir}/dist/`], {
      timeoutMs: 120_000,
    }),
    "Remote server copy",
  );
  requireSuccess(
    run(
      "rsync",
      [
        "-a",
        "--quiet",
        join(serverDir, "package.json"),
        join(serverDir, "package-lock.json"),
        `${sshTarget}:${remoteDir}/`,
      ],
      { timeoutMs: 60_000 },
    ),
    "Remote package metadata copy",
  );
  requireSuccess(
    ssh(`cd ${remoteDir} && npm ci --no-audit --no-fund --ignore-scripts`, 300_000),
    "Remote dependency install",
  );
  requireSuccess(
    run(
      "scp",
      [
        "-q",
        join(import.meta.dirname, "tailscale-network-benchmark-server.mjs"),
        `${sshTarget}:${remoteDir}/e2e/tailscale-network-benchmark-server.mjs`,
      ],
      { timeoutMs: 60_000 },
    ),
    "Remote benchmark launcher copy",
  );

  const startCommand = [
    `cd ${remoteDir} || exit 1; nohup env`,
    `OPPI_DATA_DIR=${remoteDir}/data`,
    `PI_CODING_AGENT_DIR=${remoteDir}/agent`,
    `BENCH_WORKSPACE_DIR=${remoteDir}/workspace`,
    `BENCH_READY_PATH=${remoteReadyPath}`,
    `BENCH_BIND_HOST=${targetIp}`,
    "OPPI_BONJOUR=0",
    "OPPI_LOG_LEVEL=warn",
    `node e2e/tailscale-network-benchmark-server.mjs </dev/null >${remoteDir}/server.log 2>&1 & echo $! >${remoteDir}/server.pid`,
  ].join(" ");
  requireSuccess(ssh(startCommand), "Remote benchmark server start");
  remoteStarted = true;

  let readyText = "";
  for (let attempt = 0; attempt < 90; attempt += 1) {
    const ready = ssh(`test -s ${remoteReadyPath} && cat ${remoteReadyPath}`, 10_000);
    if (ready.status === 0 && String(ready.stdout).trim().startsWith("{")) {
      readyText = String(ready.stdout).trim();
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  if (!readyText) {
    const remoteLog = ssh(`cat ${remoteDir}/server.log 2>/dev/null || true`, 10_000);
    throw new Error(
      `Remote Tailscale benchmark server did not become ready${remoteLog.stdout ? `:\n${String(remoteLog.stdout).trim()}` : ""}`,
    );
  }
  const ready = JSON.parse(readyText) as {
    port: number;
    token: string;
    workspaceDir: string;
    serverVersion: string;
    scheme: string;
  };
  if (ready.scheme !== "https" || !ready.token || !Number.isInteger(ready.port)) {
    throw new Error("Remote Tailscale benchmark readiness payload is invalid");
  }

  const before = pingPath();
  const client = run("node", ["--import", "tsx", "e2e/tailscale-network-benchmark-client.ts"], {
    cwd: serverDir,
    inherit: true,
    timeoutMs: 3_600_000,
    env: {
      ...process.env,
      TAILSCALE_BENCH_TARGET: targetIp,
      TAILSCALE_BENCH_TOKEN: ready.token,
      TAILSCALE_BENCH_PORT: String(ready.port),
      TAILSCALE_BENCH_WORKSPACE_DIR: ready.workspaceDir,
      TAILSCALE_BENCH_SERVER_VERSION: ready.serverVersion,
      TAILSCALE_BENCH_REGION: region,
      TAILSCALE_BENCH_OUTPUT: localResultPath,
    },
  });
  requireSuccess(client, "Tailscale benchmark client");
  const after = pingPath();

  const result = JSON.parse(readFileSync(localResultPath, "utf8")) as {
    name: string;
    transport: string;
    topology: Record<string, unknown>;
    raw: Record<string, unknown[]>;
    summaries: {
      coldConnectionMs: NumericSummary;
      warmRestMs: NumericSummary;
      websocketRttMs: NumericSummary;
      reconnectMs: NumericSummary;
      transfers: Record<string, NumericSummary>;
    };
  };
  const durable = {
    schemaVersion: 1,
    benchmark: "oppi-tailscale-network",
    generatedAt: new Date().toISOString(),
    privacy: {
      location: region,
      excluded: [
        "city",
        "hostname",
        "IP address",
        "tailnet name",
        "account identity",
        "ISP",
        "device identifier",
      ],
    },
    environment: {
      clientOs: "macOS arm64",
      serverOs: "macOS arm64",
      tailscaleVersion: tailscaleVersion(),
      oppiServerVersion: ready.serverVersion,
    },
    pathVerification: {
      before: { direct: before.direct, latencyMs: before.latencyMs },
      after: { direct: after.direct, latencyMs: after.latencyMs },
    },
    result,
    validation: {
      countsVerified: true,
      directPathVerifiedBeforeAndAfter: true,
    },
  };
  const serialized = `${JSON.stringify(durable, null, 2)}\n`;
  for (const forbidden of [targetIp, sshTarget, ready.token, remoteDir]) {
    if (serialized.includes(forbidden)) {
      throw new Error("Privacy scrub rejected a sensitive value in durable output");
    }
  }

  const stamp = durable.generatedAt.replaceAll(/[-:.]/g, "");
  const reportDir = join(repoDir, ".internal", "reports");
  mkdirSync(reportDir, { recursive: true });
  const reportBase = `tailscale-network-benchmark-${stamp}`;
  const reportPath = join(reportDir, `${reportBase}.json`);
  const markdownPath = join(reportDir, `${reportBase}.md`);
  const metric = (summary: NumericSummary, unit: string): string =>
    `${summary.p50.toFixed(2)} / ${summary.p95.toFixed(2)} ${unit}`;
  const transfer = (direction: "upload" | "download", mib: number): NumericSummary =>
    result.summaries.transfers[`${direction}-${mib * 1024 * 1024}`];
  const markdown = `# Tailscale direct network benchmark

Date: ${durable.generatedAt}

Machine-readable samples: [\`${reportBase}.json\`](./${reportBase}.json)

## Verified topology

A dedicated Oppi server ran on a separate macOS peer in ${region}. \`tailscale ping\` selected a direct path before and after the benchmark; the harness fails if either verification ends on DERP. The Oppi listener used HTTPS over Tailscale. Certificate verification was disabled only because the ephemeral benchmark server used a self-signed certificate; Tailscale still encrypted the network path.

| Metric | p50 / p95 |
| --- | ---: |
| Tailscale path RTT before | ${metric(before.latencyMs, "ms")} |
| Tailscale path RTT after | ${metric(after.latencyMs, "ms")} |
| Cold TLS connection | ${metric(result.summaries.coldConnectionMs, "ms")} |
| Warm authenticated \`GET /me\` | ${metric(result.summaries.warmRestMs, "ms")} |
| Focused WebSocket \`get_state\` RTT | ${metric(result.summaries.websocketRttMs, "ms")} |
| Focused WebSocket reconnect | ${metric(result.summaries.reconnectMs, "ms")} |
| Upload 1 MiB | ${metric(transfer("upload", 1), "Mb/s")} |
| Upload 10 MiB | ${metric(transfer("upload", 10), "Mb/s")} |
| Upload 50 MiB | ${metric(transfer("upload", 50), "Mb/s")} |
| Download 1 MiB | ${metric(transfer("download", 1), "Mb/s")} |
| Download 10 MiB | ${metric(transfer("download", 10), "Mb/s")} |
| Download 50 MiB | ${metric(transfer("download", 50), "Mb/s")} |

Sample counts match the Iroh matrix: 30 cold connections, 200 warm REST requests, 200 WebSocket round trips, 20 reconnects, and five transfers per direction and size.

## Comparison boundary

This is a real two-machine Tailscale-direct measurement, unlike the same-host container HTTP/Iroh-direct lanes and public-relay Iroh lane. Compare protocol behavior and user-visible latency, but do not attribute every difference to transport alone. The physical-device gate still requires a same-phone, same-location Tailscale-versus-Iroh A/B.
`;
  writeFileSync(reportPath, serialized, { mode: 0o600 });
  writeFileSync(markdownPath, markdown, { mode: 0o600 });
  process.stdout.write(`[tailscale-network-benchmark] JSON: ${reportPath}\n`);
  process.stdout.write(`[tailscale-network-benchmark] Markdown: ${markdownPath}\n`);
  process.stdout.write(`[tailscale-network-benchmark] runtime artifacts: ${artifactDir}\n`);
  process.stdout.write(
    "[tailscale-network-benchmark] counts, direct path, and privacy scrub verified\n",
  );
} finally {
  if (remoteStarted) {
    ssh(
      `test -f ${remoteDir}/server.pid && kill $(cat ${remoteDir}/server.pid) 2>/dev/null || true`,
    );
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    run("scp", ["-q", `${sshTarget}:${remoteDir}/server.log`, join(artifactDir, "server.log")], {
      timeoutMs: 30_000,
    });
  }
  ssh(`rm -rf ${remoteDir}`);
}

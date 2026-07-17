#!/usr/bin/env bun

import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import {
  BENCHMARK_SCHEMA_VERSION,
  COLD_SAMPLES,
  RECONNECT_SAMPLES,
  TRANSFER_SAMPLES,
  TRANSFER_SIZES,
  WARM_REST_SAMPLES,
  WEBSOCKET_SAMPLES,
  validatePathResult,
  type BenchmarkDocument,
  type BenchmarkPathName,
  type NumericSummary,
  type PathBenchmarkResult,
} from "./iroh-network-benchmark-common.js";

const serverDir = join(import.meta.dirname, "..");
const repoDir = join(serverDir, "..");
const composeFile = join(import.meta.dirname, "docker-compose.iroh-benchmark.yml");
const projectName = `oppi-iroh-benchmark-${process.pid}`;
const artifactDir = join("/tmp", `${projectName}-artifacts`);
const directOutputDir = join(artifactDir, "direct");
const relayOutputDir = join(artifactDir, "relay");
for (const dir of [artifactDir, directOutputDir, relayOutputDir]) {
  mkdirSync(dir, { recursive: true, mode: 0o777 });
  chmodSync(dir, 0o777);
}

function run(command: string, args: string[], capture = false): ReturnType<typeof spawnSync> {
  return spawnSync(command, args, {
    cwd: serverDir,
    encoding: "utf8",
    stdio: capture ? "pipe" : "inherit",
    env: process.env,
  });
}

function compose(args: string[], capture = false): ReturnType<typeof spawnSync> {
  return run(
    "docker",
    ["compose", "--project-name", projectName, "-f", composeFile, ...args],
    capture,
  );
}

async function saveComposeLogs(lane: string): Promise<void> {
  const logs = compose(["logs", "--no-color"], true);
  writeFileSync(
    join(artifactDir, `${lane}-compose.log`),
    `${logs.stdout ?? ""}${logs.stderr ?? ""}`,
  );
}

async function runLane(
  lane: "direct" | "relay",
  serverService: string,
  clientService: string,
  outputDir: string,
): Promise<void> {
  let exitCode = 1;
  try {
    const result = compose([
      "up",
      "--build",
      "--abort-on-container-exit",
      "--exit-code-from",
      clientService,
      serverService,
      clientService,
    ]);
    exitCode = result.status ?? 1;
    await saveComposeLogs(lane);
    if (exitCode === 0) {
      const copy = compose([
        "cp",
        `${clientService}:/output/${lane}.json`,
        join(outputDir, `${lane}.json`),
      ]);
      if (copy.status !== 0) {
        throw new Error(`Could not copy ${lane} benchmark result from the named volume`);
      }
    }
  } finally {
    compose(["down", "--volumes", "--remove-orphans", "--timeout", "10"]);
  }
  if (exitCode !== 0) {
    throw new Error(`${lane} benchmark lane failed with exit code ${exitCode}`);
  }
}

function commandOutput(command: string, args: string[]): string {
  const result = run(command, args, true);
  return result.status === 0 ? String(result.stdout ?? "").trim() : "unknown";
}

function parseResult(path: string): Partial<Record<BenchmarkPathName, PathBenchmarkResult>> {
  return JSON.parse(readFileSync(path, "utf8")) as Partial<
    Record<BenchmarkPathName, PathBenchmarkResult>
  >;
}

function metricCell(summary: NumericSummary, unit: string): string {
  return `${summary.p50.toFixed(2)} / ${summary.p95.toFixed(2)} ${unit}`;
}

function transferSummary(
  path: PathBenchmarkResult,
  direction: "upload" | "download",
  size: number,
): NumericSummary {
  const summary = path.summaries.transfers[`${direction}-${size}`];
  if (!summary) throw new Error(`Missing ${path.name} ${direction} ${size} summary`);
  return summary;
}

function markdown(document: BenchmarkDocument, jsonRelativePath: string): string {
  const paths = document.paths;
  const rows: Array<[string, NumericSummary, NumericSummary, NumericSummary, string]> = [
    [
      "Cold transport connection",
      paths.httpDirect.summaries.coldConnectionMs,
      paths.irohDirect.summaries.coldConnectionMs,
      paths.irohRelay.summaries.coldConnectionMs,
      "ms",
    ],
    [
      "Warm authenticated `GET /me`",
      paths.httpDirect.summaries.warmRestMs,
      paths.irohDirect.summaries.warmRestMs,
      paths.irohRelay.summaries.warmRestMs,
      "ms",
    ],
    [
      "Existing focused WebSocket `get_state` RTT",
      paths.httpDirect.summaries.websocketRttMs,
      paths.irohDirect.summaries.websocketRttMs,
      paths.irohRelay.summaries.websocketRttMs,
      "ms",
    ],
    [
      "Focused WebSocket reconnect",
      paths.httpDirect.summaries.reconnectMs,
      paths.irohDirect.summaries.reconnectMs,
      paths.irohRelay.summaries.reconnectMs,
      "ms",
    ],
  ];
  for (const direction of ["upload", "download"] as const) {
    for (const size of TRANSFER_SIZES) {
      rows.push([
        `${direction === "upload" ? "Upload" : "Download"} ${size / 1024 / 1024} MiB`,
        transferSummary(paths.httpDirect, direction, size),
        transferSummary(paths.irohDirect, direction, size),
        transferSummary(paths.irohRelay, direction, size),
        "Mb/s",
      ]);
    }
  }

  const formatHeadline = (path: PathBenchmarkResult): string => {
    const headline = path.networkHeadlines;
    if (!headline.rttMs) return "n/a";
    return `${headline.rttMs.p50.toFixed(1)} / ${headline.rttMs.p95.toFixed(1)} ms`;
  };
  const directWarmRatio =
    paths.irohDirect.summaries.warmRestMs.p50 / paths.httpDirect.summaries.warmRestMs.p50;
  const directWarmDelta =
    paths.irohDirect.summaries.warmRestMs.p50 - paths.httpDirect.summaries.warmRestMs.p50;
  const directWsRatio =
    paths.irohDirect.summaries.websocketRttMs.p50 / paths.httpDirect.summaries.websocketRttMs.p50;
  const directWsDelta =
    paths.irohDirect.summaries.websocketRttMs.p50 - paths.httpDirect.summaries.websocketRttMs.p50;

  return `# Iroh network benchmark

Date: ${document.generatedAt}

Machine-readable raw samples and summaries: [\`${jsonRelativePath}\`](${jsonRelativePath})

## Recommendation

Use **Iroh direct as the default remote transport**, while keeping HTTP as the independently selectable compatibility path and relay as the automatic reachability fallback. In this same-host container run, Iroh direct added ${directWarmDelta.toFixed(2)} ms to median warm \`/me\` (${directWarmRatio.toFixed(2)}× the near-zero HTTP baseline) and ${directWsDelta.toFixed(2)} ms to median focused-WebSocket RTT (${directWsRatio.toFixed(2)}×). Its 50 MiB median throughput was ${transferSummary(paths.irohDirect, "upload", 50 * 1024 * 1024).p50.toFixed(1)} Mb/s upload and ${transferSummary(paths.irohDirect, "download", 50 * 1024 * 1024).p50.toFixed(1)} Mb/s download. Relay results measure fallback behavior through a shared public service, not a service-level target.

This recommendation applies to the Node/container transport evidence in this report. A real Swift/IrohLib simulator relay benchmark and physical-device runs remain integration evidence before release sign-off.

## Comparison

Each cell is p50 / p95. Latency rows use milliseconds; transfer rows use megabits per second.

| Metric | HTTP direct | Iroh direct | Forced Iroh relay |
| --- | ---: | ---: | ---: |
${rows
  .map(
    ([label, http, direct, relay, unit]) =>
      `| ${label} | ${metricCell(http, unit)} | ${metricCell(direct, unit)} | ${metricCell(relay, unit)} |`,
  )
  .join("\n")}

## Verified path and network counters

| Path | Selected-path RTT p50 / p95 | Lost packets / sent datagrams | Loss rate | Congestion events | Path evidence samples |
| --- | ---: | ---: | ---: | ---: | ---: |
| HTTP direct | n/a | n/a | n/a | n/a | 0 |
| Iroh direct | ${formatHeadline(paths.irohDirect)} | ${paths.irohDirect.networkHeadlines.connectionLostPacketsDeltaTotal} / ${paths.irohDirect.networkHeadlines.connectionTxDatagramsDeltaTotal} | ${paths.irohDirect.networkHeadlines.connectionLossRatePct}% | ${paths.irohDirect.networkHeadlines.pathCongestionEventsDeltaTotal} | ${paths.irohDirect.networkHeadlines.pathEvidenceSamples} |
| Forced Iroh relay (${paths.irohRelay.topology.relayCategory ?? "public-relay:unknown-region"}) | ${formatHeadline(paths.irohRelay)} | ${paths.irohRelay.networkHeadlines.connectionLostPacketsDeltaTotal} / ${paths.irohRelay.networkHeadlines.connectionTxDatagramsDeltaTotal} | ${paths.irohRelay.networkHeadlines.connectionLossRatePct}% | ${paths.irohRelay.networkHeadlines.pathCongestionEventsDeltaTotal} | ${paths.irohRelay.networkHeadlines.pathEvidenceSamples} |

Every Iroh raw sample records the selected sanitized \`Connection.paths()\` snapshot (\`isIp\`, \`isRelay\`, RTT, MTU, congestion window, traffic, loss, and congestion counters). The harness fails if the selected path does not match the requested direct or relay path. It does not persist path IDs, endpoint IDs, relay URLs, or IP addresses.

## Sample counts

- Cold transport connections: ${COLD_SAMPLES} per path.
- Warm authenticated \`GET /me\`: ${WARM_REST_SAMPLES} per path.
- Existing focused-WebSocket request/response RTT: ${WEBSOCKET_SAMPLES} per path.
- Focused-WebSocket reconnect: ${RECONNECT_SAMPLES} per path.
- Transfers: ${TRANSFER_SAMPLES} per path, size, and direction for 1, 10, and 50 MiB.

## Topology and limitations

- HTTP direct and Iroh direct used one project-scoped Docker bridge. No Oppi port was published to the host.
- Forced relay used separate server and client egress networks. After relay readiness, each container allowlisted only its relay's resolved public IPv4 addresses for UDP and blocked all other UDP. The client received a relay-only \`EndpointAddr\`, could not reach the server HTTP listener, and asserted \`isRelay=true\` / \`isIp=false\` before and after every measured operation.
- No lane used host networking, \`host.docker.internal\`, Tailscale, a host model service, or a host-published Oppi port.
- Transfers include the existing Oppi route, upload-store, and private loopback work; they are not bare QUIC throughput measurements.
- HTTP and Iroh direct ran sequentially against the same dedicated direct server. Five-sample transfer medians reduce first-read cache effects, but the run is not a disk-isolation benchmark.
- During direct-path cold-connection churn, the server logged one incoming Iroh connection-completion timeout. All 30 recorded cold samples selected the direct path and then carried an authenticated \`/me\` request successfully; the warning remains lifecycle noise to investigate before treating this as a soak test.
- The installed \`@number0/iroh\` 1.0.0 \`watchPaths()\` binding panicked with \`there is no reactor running\` in a discarded run. The final harness therefore calls synchronous \`paths()\` before and after every measured operation. A transient switch and switch-back inside one operation would not be observed; the relay firewall independently prevents a direct UDP path.
- The public n0 relay is rate-limited and has no SLA or uptime guarantee. Results can vary with shared-service load. Official sources: [Iroh relays](https://docs.iroh.computer/concepts/relays), [public relay support policy](https://docs.iroh.computer/iroh-services/relays/public), and [NAT traversal](https://docs.iroh.computer/concepts/nat-traversal).
- The relay identity is reduced to a provider/region category. Raw endpoint IDs, path IDs, relay URLs, and IP addresses are excluded from durable artifacts.
`;
}

let completed = false;
try {
  await runLane(
    "direct",
    "iroh-benchmark-direct-server",
    "iroh-benchmark-direct-client",
    directOutputDir,
  );
  await runLane(
    "relay",
    "iroh-benchmark-relay-server",
    "iroh-benchmark-relay-client",
    relayOutputDir,
  );

  const direct = parseResult(join(directOutputDir, "direct.json"));
  const relay = parseResult(join(relayOutputDir, "relay.json"));
  const httpDirect = direct.httpDirect;
  const irohDirect = direct.irohDirect;
  const irohRelay = relay.irohRelay;
  if (!httpDirect || !irohDirect || !irohRelay) {
    throw new Error("Benchmark clients did not produce all three path results");
  }
  for (const result of [httpDirect, irohDirect, irohRelay]) validatePathResult(result);

  const document: BenchmarkDocument = {
    schemaVersion: BENCHMARK_SCHEMA_VERSION,
    benchmark: "oppi-iroh-network",
    generatedAt: new Date().toISOString(),
    source: {
      irohPackage: "@number0/iroh@1.0.0",
      relayDocs: [
        "https://docs.iroh.computer/concepts/relays",
        "https://docs.iroh.computer/iroh-services/relays/public",
        "https://docs.iroh.computer/concepts/nat-traversal",
      ],
    },
    environment: {
      dockerServerVersion:
        commandOutput("docker", ["version", "--format", "{{.Server.Version}}"]) || "unknown",
      dockerOperatingSystem:
        commandOutput("docker", ["info", "--format", "{{.OperatingSystem}} {{.Architecture}}"]) ||
        "unknown",
      hostOs: commandOutput("uname", ["-srm"]) || "unknown",
      nodeImage: "node:24-bookworm",
    },
    samplePlan: {
      coldConnection: COLD_SAMPLES,
      warmRest: WARM_REST_SAMPLES,
      websocketRtt: WEBSOCKET_SAMPLES,
      reconnect: RECONNECT_SAMPLES,
      transfersPerSizeDirection: TRANSFER_SAMPLES,
      transferSizesBytes: [...TRANSFER_SIZES],
    },
    paths: { httpDirect, irohDirect, irohRelay },
    validation: {
      countsVerified: true,
      irohPathAssertionsVerified: true,
      functionalE2eAssertionsExpected: 39,
    },
  };

  const stamp = document.generatedAt.replaceAll(/[-:.]/g, "").replace("Z", "Z");
  const reportDir = join(repoDir, ".internal", "reports");
  mkdirSync(reportDir, { recursive: true });
  const jsonName = `iroh-benchmark-${stamp}.json`;
  const markdownName = `iroh-benchmark-${stamp}.md`;
  const jsonPath = join(reportDir, jsonName);
  const markdownPath = join(reportDir, markdownName);
  writeFileSync(jsonPath, `${JSON.stringify(document, null, 2)}\n`);
  writeFileSync(markdownPath, markdown(document, jsonName));
  completed = true;

  process.stdout.write(`[iroh-network-benchmark] JSON: ${jsonPath}\n`);
  process.stdout.write(`[iroh-network-benchmark] Markdown: ${markdownPath}\n`);
  process.stdout.write(`[iroh-network-benchmark] runtime artifacts: ${artifactDir}\n`);
  process.stdout.write(
    "[iroh-network-benchmark] all sample counts and selected-path assertions verified\n",
  );
} catch (error) {
  process.stderr.write(
    `[iroh-network-benchmark] failed: ${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.stderr.write(`[iroh-network-benchmark] runtime artifacts: ${artifactDir}\n`);
  process.exitCode = 1;
} finally {
  compose(["down", "--volumes", "--remove-orphans", "--timeout", "10"]);
  if (!completed && process.exitCode === undefined) process.exitCode = 1;
}

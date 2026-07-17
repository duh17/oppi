import type { Connection, ConnectionStats, PathSnapshot, PathStatsRecord } from "@number0/iroh";

export const BENCHMARK_SCHEMA_VERSION = 1;
export const COLD_SAMPLES = 30;
export const WARM_REST_SAMPLES = 200;
export const WEBSOCKET_SAMPLES = 200;
export const RECONNECT_SAMPLES = 20;
export const TRANSFER_SAMPLES = 5;
export const TRANSFER_SIZES = [1, 10, 50].map((mib) => mib * 1024 * 1024);

export type BenchmarkPathName = "httpDirect" | "irohDirect" | "irohRelay";
export type ExpectedIrohPath = "direct" | "relay";

export type NumericSummary = {
  count: number;
  min: number;
  max: number;
  mean: number;
  p50: number;
  p95: number;
};

export type SanitizedPathSnapshot = {
  isIp: boolean;
  isRelay: boolean;
  addressCategory: string;
  rttMs: number;
  stats: PathStatsRecord;
};

export type PathCounterDelta = {
  udpTxDatagrams: number;
  udpTxBytes: number;
  udpRxDatagrams: number;
  udpRxBytes: number;
  lostPackets: number;
  lostBytes: number;
};

export type PathStatsDelta = PathCounterDelta & {
  cwnd: number;
  congestionEvents: number;
  currentMtu: number;
  rttMs: number;
};

export type PathEvidence = {
  expected: ExpectedIrohPath;
  before?: SanitizedPathSnapshot;
  after: SanitizedPathSnapshot;
  selectedPathChanged: boolean;
  selectedPathChangeEvents: number;
  connectionDelta?: PathCounterDelta;
  pathDelta?: PathStatsDelta;
};

export type TimedSample = {
  sample: number;
  durationMs: number;
  path?: PathEvidence;
};

export type TransferSample = TimedSample & {
  direction: "upload" | "download";
  sizeBytes: number;
  throughputMbps: number;
};

export type MetricSummaries = {
  coldConnectionMs: NumericSummary;
  warmRestMs: NumericSummary;
  websocketRttMs: NumericSummary;
  reconnectMs: NumericSummary;
  transfers: Record<string, NumericSummary>;
};

export type NetworkHeadlines = {
  pathEvidenceSamples: number;
  rttMs?: NumericSummary;
  connectionLostPacketsDeltaTotal?: number;
  connectionLostBytesDeltaTotal?: number;
  connectionTxDatagramsDeltaTotal?: number;
  connectionLossRatePct?: number;
  pathCongestionEventsDeltaTotal?: number;
};

export type PathBenchmarkResult = {
  name: BenchmarkPathName;
  transport: "http" | "iroh";
  requestedIrohPath?: ExpectedIrohPath;
  topology: {
    description: string;
    directHttpReachable: boolean;
    hostNetwork: false;
    hostDockerInternal: false;
    tailscale: false;
    hostModelService: false;
    relayCategory?: string;
  };
  raw: {
    coldConnection: TimedSample[];
    warmRest: TimedSample[];
    websocketRtt: TimedSample[];
    reconnect: TimedSample[];
    transfers: TransferSample[];
  };
  summaries: MetricSummaries;
  networkHeadlines: NetworkHeadlines;
};

export type BenchmarkDocument = {
  schemaVersion: number;
  benchmark: "oppi-iroh-network";
  generatedAt: string;
  source: {
    irohPackage: "@number0/iroh@1.0.0";
    relayDocs: string[];
  };
  environment: {
    dockerServerVersion: string;
    dockerOperatingSystem: string;
    hostOs: string;
    nodeImage: "node:24-bookworm";
  };
  samplePlan: {
    coldConnection: number;
    warmRest: number;
    websocketRtt: number;
    reconnect: number;
    transfersPerSizeDirection: number;
    transferSizesBytes: number[];
  };
  paths: Record<BenchmarkPathName, PathBenchmarkResult>;
  validation: {
    countsVerified: true;
    irohPathAssertionsVerified: true;
    functionalE2eAssertionsExpected: 39;
  };
};

type InternalSelectedPath = {
  id: string;
  snapshot: SanitizedPathSnapshot;
};

function round(value: number, digits = 6): number {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

export function summarize(values: number[]): NumericSummary {
  if (values.length === 0) throw new Error("Cannot summarize an empty sample set");
  const sorted = [...values].sort((left, right) => left - right);
  const percentile = (p: number): number => sorted[Math.ceil(p * sorted.length) - 1] ?? sorted[0];
  return {
    count: values.length,
    min: round(sorted[0]),
    max: round(sorted[sorted.length - 1]),
    mean: round(values.reduce((total, value) => total + value, 0) / values.length),
    p50: round(percentile(0.5)),
    p95: round(percentile(0.95)),
  };
}

function transferKey(direction: "upload" | "download", sizeBytes: number): string {
  return `${direction}-${sizeBytes}`;
}

export function summarizePathResult(
  result: Omit<PathBenchmarkResult, "summaries" | "networkHeadlines">,
): PathBenchmarkResult {
  const transfers: Record<string, NumericSummary> = {};
  for (const direction of ["upload", "download"] as const) {
    for (const sizeBytes of TRANSFER_SIZES) {
      const matching = result.raw.transfers.filter(
        (sample) => sample.direction === direction && sample.sizeBytes === sizeBytes,
      );
      transfers[transferKey(direction, sizeBytes)] = summarize(
        matching.map((sample) => sample.throughputMbps),
      );
    }
  }

  const allSamples = [
    ...result.raw.coldConnection,
    ...result.raw.warmRest,
    ...result.raw.websocketRtt,
    ...result.raw.reconnect,
    ...result.raw.transfers,
  ];
  const evidence = allSamples.flatMap((sample) => (sample.path ? [sample.path] : []));
  const connectionDeltas = evidence.flatMap((item) =>
    item.connectionDelta ? [item.connectionDelta] : [],
  );
  const pathDeltas = evidence.flatMap((item) => (item.pathDelta ? [item.pathDelta] : []));
  const lostPackets = connectionDeltas.reduce((total, item) => total + item.lostPackets, 0);
  const txDatagrams = connectionDeltas.reduce((total, item) => total + item.udpTxDatagrams, 0);

  return {
    ...result,
    summaries: {
      coldConnectionMs: summarize(result.raw.coldConnection.map((sample) => sample.durationMs)),
      warmRestMs: summarize(result.raw.warmRest.map((sample) => sample.durationMs)),
      websocketRttMs: summarize(result.raw.websocketRtt.map((sample) => sample.durationMs)),
      reconnectMs: summarize(result.raw.reconnect.map((sample) => sample.durationMs)),
      transfers,
    },
    networkHeadlines: {
      pathEvidenceSamples: evidence.length,
      ...(evidence.length > 0
        ? {
            rttMs: summarize(evidence.map((item) => item.after.rttMs)),
            connectionLostPacketsDeltaTotal: lostPackets,
            connectionLostBytesDeltaTotal: connectionDeltas.reduce(
              (total, item) => total + item.lostBytes,
              0,
            ),
            connectionTxDatagramsDeltaTotal: txDatagrams,
            connectionLossRatePct:
              txDatagrams + lostPackets === 0
                ? 0
                : round((lostPackets / (txDatagrams + lostPackets)) * 100),
            pathCongestionEventsDeltaTotal: pathDeltas.reduce(
              (total, item) => total + item.congestionEvents,
              0,
            ),
          }
        : {}),
    },
  };
}

function sanitizeRelayAddress(remoteAddr: string): string {
  try {
    const url = new URL(remoteAddr);
    const hostname = url.hostname.toLowerCase();
    const firstLabel = hostname.split(".")[0] ?? "";
    const region = firstLabel.match(/^[a-z]+\d+/)?.[0] ?? "unknown-region";
    const provider = hostname.includes("n0") || hostname.includes("iroh") ? "n0-public" : "public";
    return `${provider}:${region}`;
  } catch {
    return "public-relay:unknown-region";
  }
}

function sanitizeIpAddress(remoteAddr: string): string {
  const host = remoteAddr.startsWith("[")
    ? remoteAddr.slice(1, remoteAddr.indexOf("]"))
    : remoteAddr.slice(0, remoteAddr.lastIndexOf(":"));
  if (host === "127.0.0.1" || host === "::1") return "ip:loopback";
  if (
    host.startsWith("10.") ||
    host.startsWith("192.168.") ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
    host.startsWith("fc") ||
    host.startsWith("fd")
  ) {
    return "ip:private";
  }
  return "ip:public";
}

function sanitizeSnapshot(path: PathSnapshot): SanitizedPathSnapshot {
  return {
    isIp: path.isIp,
    isRelay: path.isRelay,
    addressCategory: path.isRelay
      ? sanitizeRelayAddress(path.remoteAddr)
      : path.isIp
        ? sanitizeIpAddress(path.remoteAddr)
        : "custom:unknown",
    rttMs: path.rttMs,
    stats: { ...path.stats },
  };
}

function selectedPath(connection: Connection, expected: ExpectedIrohPath): InternalSelectedPath {
  const selected = connection.paths().filter((path) => path.isSelected);
  if (selected.length !== 1) {
    throw new Error(`Expected exactly one selected Iroh path, found ${selected.length}`);
  }
  const path = selected[0];
  const matches = expected === "direct" ? path.isIp && !path.isRelay : path.isRelay && !path.isIp;
  if (!matches) {
    throw new Error(
      `Requested Iroh ${expected} path is not selected (isIp=${path.isIp}, isRelay=${path.isRelay})`,
    );
  }
  return { id: path.id, snapshot: sanitizeSnapshot(path) };
}

export async function waitForSelectedPath(
  connection: Connection,
  expected: ExpectedIrohPath,
  timeoutMs = 30_000,
): Promise<InternalSelectedPath> {
  const deadline = Date.now() + timeoutMs;
  let lastError: Error | undefined;
  while (Date.now() < deadline) {
    try {
      return selectedPath(connection, expected);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw new Error(
    `Iroh ${expected} path was not selected within ${timeoutMs}ms: ${lastError?.message ?? "no path"}`,
  );
}

function deltaConnection(before: ConnectionStats, after: ConnectionStats): PathCounterDelta {
  return {
    udpTxDatagrams: Math.max(0, after.udpTxDatagrams - before.udpTxDatagrams),
    udpTxBytes: Math.max(0, after.udpTxBytes - before.udpTxBytes),
    udpRxDatagrams: Math.max(0, after.udpRxDatagrams - before.udpRxDatagrams),
    udpRxBytes: Math.max(0, after.udpRxBytes - before.udpRxBytes),
    lostPackets: Math.max(0, after.lostPackets - before.lostPackets),
    lostBytes: Math.max(0, after.lostBytes - before.lostBytes),
  };
}

function deltaPath(before: PathStatsRecord, after: PathStatsRecord): PathStatsDelta {
  return {
    ...deltaConnection(before, after),
    cwnd: after.cwnd,
    congestionEvents: Math.max(0, after.congestionEvents - before.congestionEvents),
    currentMtu: after.currentMtu,
    rttMs: after.rttMs,
  };
}

export class IrohPathRecorder {
  private constructor(
    private readonly connection: Connection,
    private readonly expected: ExpectedIrohPath,
  ) {}

  static async start(
    connection: Connection,
    expected: ExpectedIrohPath,
  ): Promise<IrohPathRecorder> {
    await waitForSelectedPath(connection, expected);
    return new IrohPathRecorder(connection, expected);
  }

  begin(): { selected: InternalSelectedPath; connection: ConnectionStats } {
    return {
      selected: selectedPath(this.connection, this.expected),
      connection: this.connection.stats(),
    };
  }

  end(before: ReturnType<IrohPathRecorder["begin"]>): PathEvidence {
    const after = selectedPath(this.connection, this.expected);
    const samePath = before.selected.id === after.id;
    return {
      expected: this.expected,
      before: before.selected.snapshot,
      after: after.snapshot,
      selectedPathChanged: !samePath,
      selectedPathChangeEvents: samePath ? 0 : 1,
      connectionDelta: deltaConnection(before.connection, this.connection.stats()),
      ...(samePath
        ? { pathDelta: deltaPath(before.selected.snapshot.stats, after.snapshot.stats) }
        : {}),
    };
  }

  current(): PathEvidence {
    const selected = selectedPath(this.connection, this.expected);
    return {
      expected: this.expected,
      after: selected.snapshot,
      selectedPathChanged: false,
      selectedPathChangeEvents: 0,
    };
  }

  stop(): void {
    selectedPath(this.connection, this.expected);
  }
}

export function validatePathResult(result: PathBenchmarkResult): void {
  const expectCount = (actual: number, expected: number, label: string): void => {
    if (actual !== expected)
      throw new Error(`${result.name} ${label}: expected ${expected}, got ${actual}`);
  };
  expectCount(result.raw.coldConnection.length, COLD_SAMPLES, "cold samples");
  expectCount(result.raw.warmRest.length, WARM_REST_SAMPLES, "warm REST samples");
  expectCount(result.raw.websocketRtt.length, WEBSOCKET_SAMPLES, "WebSocket samples");
  expectCount(result.raw.reconnect.length, RECONNECT_SAMPLES, "reconnect samples");
  expectCount(
    result.raw.transfers.length,
    TRANSFER_SIZES.length * 2 * TRANSFER_SAMPLES,
    "transfer samples",
  );

  for (const direction of ["upload", "download"] as const) {
    for (const sizeBytes of TRANSFER_SIZES) {
      expectCount(
        result.raw.transfers.filter(
          (sample) => sample.direction === direction && sample.sizeBytes === sizeBytes,
        ).length,
        TRANSFER_SAMPLES,
        `${direction} ${sizeBytes} samples`,
      );
    }
  }

  if (result.transport === "iroh") {
    const expected = result.requestedIrohPath;
    if (!expected) throw new Error(`${result.name} is missing requestedIrohPath`);
    const samples = [
      ...result.raw.coldConnection,
      ...result.raw.warmRest,
      ...result.raw.websocketRtt,
      ...result.raw.reconnect,
      ...result.raw.transfers,
    ];
    for (const sample of samples) {
      if (!sample.path)
        throw new Error(`${result.name} sample ${sample.sample} lacks path evidence`);
      if (sample.path.expected !== expected)
        throw new Error(`${result.name} path expectation drift`);
      const selected = sample.path.after;
      const matches =
        expected === "direct"
          ? selected.isIp && !selected.isRelay
          : selected.isRelay && !selected.isIp;
      if (!matches) throw new Error(`${result.name} contains a mislabeled Iroh sample`);
    }
  }
}

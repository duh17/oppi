import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  HostResourceProbe,
  parseMeminfoUsedBytes,
  parseVmStatUsedBytes,
} from "../src/host-resource-probe.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createServerMetricsRoutes } from "../src/routes/server-metrics.js";
import type { RouteContext, ServerMetricsControl } from "../src/routes/types.js";
import {
  readServerMetricsHistory,
  type ServerResourceRecord,
} from "../src/server-metrics-history.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
// 2026-10-16T00:00:00Z
const DAY0 = Date.UTC(2026, 9, 16);
const MB = 1024 * 1024;

function record(
  ts: number,
  values: { cpu: number; rss?: number; hostCpu?: number },
): ServerResourceRecord {
  return {
    ts,
    cpu: { user: values.cpu, system: 0, total: values.cpu },
    memory: { heapUsed: 10, heapTotal: 20, rss: values.rss ?? 100, external: 1 },
    sessions: { busy: 0, ready: 1, starting: 0, total: 1, peak: 1 },
    wsConnections: 2,
    eventLoop: { p50: 1, p95: 2, p99: 3, max: 4 },
    ...(values.hostCpu === undefined
      ? {}
      : { host: { scope: "host" as const, cpu: values.hostCpu, memUsed: 1000 } }),
  };
}

function writeRaw(dir: string, date: string, lines: string[]): void {
  writeFileSync(join(dir, `server-metrics-${date}.jsonl`), lines.join("\n") + "\n");
}

describe("server metrics history", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-metrics-history-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("buckets samples into avg/max with null gaps and the window's edges", async () => {
    const now = DAY0 + 10 * HOUR + 30 * 1000;
    writeRaw(
      dir,
      "2026-10-16",
      [
        record(now - 2 * HOUR, { cpu: 99 }), // before the 1h window
        record(now - 50 * MINUTE, { cpu: 10, hostCpu: 40 }),
        record(now - 50 * MINUTE + 20_000, { cpu: 30, hostCpu: 60 }),
        record(now - 5 * 1000, { cpu: 5 }), // pre-host sample in the current bucket
      ].map((r) => JSON.stringify(r)),
    );

    const history = await readServerMetricsHistory(dir, "1h", now);

    expect(history.bucketMs).toBe(MINUTE);
    expect(history.ts).toHaveLength(60);
    expect(history.ts.at(-1)).toBe(DAY0 + 10 * HOUR);
    const i = history.ts.indexOf(DAY0 + 9 * HOUR + 10 * MINUTE);
    expect(history.series.cpu.avg[i]).toBe(20);
    expect(history.series.cpu.max[i]).toBe(30);
    // Host series average only the samples that carried host readings.
    expect(history.series.hostCpu.avg[i]).toBe(50);
    expect(history.series.cpu.avg[i + 1]).toBeNull();
    expect(history.series.cpu.avg.at(-1)).toBe(5);
    expect(history.series.hostCpu.avg.at(-1)).toBeNull();
    expect(history.series.cpu.max).not.toContain(99);
  });

  it("reads every UTC day file a long range touches, skipping torn lines", async () => {
    const now = DAY0 + 3 * HOUR;
    writeRaw(dir, "2026-09-17", [JSON.stringify(record(DAY0 - 29 * DAY + 5 * MINUTE, { cpu: 8 }))]);
    writeRaw(dir, "2026-10-15", [
      JSON.stringify(record(DAY0 - DAY + HOUR, { cpu: 10 })),
      JSON.stringify(record(DAY0 - DAY + HOUR + 30_000, { cpu: 50 })),
      '{"ts":12', // crash mid-append
    ]);
    writeRaw(dir, "2026-10-16", [JSON.stringify(record(DAY0 + 2 * HOUR, { cpu: 7 }))]);

    const history = await readServerMetricsHistory(dir, "30d", now);

    expect(history.bucketMs).toBe(2 * HOUR);
    expect(history.ts).toHaveLength(360);
    expect(history.series.cpu.avg[history.ts.indexOf(DAY0 - DAY)]).toBe(30);
    expect(history.series.cpu.max[history.ts.indexOf(DAY0 - DAY)]).toBe(50);
    expect(history.series.cpu.avg[history.ts.indexOf(DAY0 - 29 * DAY)]).toBe(8);
    expect(history.series.cpu.avg.at(-1)).toBe(7);
  });
});

describe("GET/PUT /server/metrics", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-metrics-route-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  function routeWith(control: ServerMetricsControl) {
    const ctx = { serverMetrics: control, serverStartedAt: 1_000 } as unknown as RouteContext;
    const route = createServerMetricsRoutes(ctx, createRouteHelpers());
    return async (method: string, path: string, body?: unknown) => {
      const res = makeResponse();
      const handled = await route({
        method,
        path: path.split("?")[0],
        url: new URL(`http://localhost${path}`),
        req: makeRequest(body),
        res: res as never,
      });
      expect(handled).toBe(true);
      return { status: res.statusCode, json: JSON.parse(res.body) as Record<string, unknown> };
    };
  }

  it("serves history while enabled, nothing while off, and toggles the switch", async () => {
    let enabled = true;
    const latest = record(Date.now(), { cpu: 12, hostCpu: 30 });
    writeRaw(dir, new Date().toISOString().slice(0, 10), [JSON.stringify(latest)]);
    const call = routeWith({
      telemetryDir: dir,
      intervalMs: 30_000,
      isEnabled: () => enabled,
      setEnabled: (value) => {
        enabled = value;
      },
      latestSample: () => latest,
    });

    const on = await call("GET", "/server/metrics?range=1h");
    expect(on.status).toBe(200);
    expect(on.json).toMatchObject({ enabled: true, intervalMs: 30_000, serverStartedAt: 1_000 });
    expect(on.json.latest).toEqual(latest);
    const history = on.json.history as { series: { cpu: { avg: number[] } } };
    expect(history.series.cpu.avg.at(-1)).toBe(12);

    // A year of samples is not kept; the longest range is 30 days.
    expect((await call("GET", "/server/metrics?range=1y")).status).toBe(400);
    expect((await call("PUT", "/server/metrics/settings", { enabled: "no" })).status).toBe(400);

    expect((await call("PUT", "/server/metrics/settings", { enabled: false })).json).toEqual({
      enabled: false,
    });
    expect((await call("GET", "/server/metrics/settings")).json).toEqual({ enabled: false });
    const off = await call("GET", "/server/metrics?range=1h");
    expect(off.json).toMatchObject({ enabled: false, latest: null, history: null });
  });
});

describe("host resource probe", () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "oppi-host-probe-"));
    mkdirSync(join(root, "proc/self"), { recursive: true });
    writeFileSync(
      join(root, "proc/meminfo"),
      "MemTotal:       16000000 kB\nMemFree:  100 kB\nMemAvailable:    4000000 kB\n",
    );
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  function writeCgroupV2(files: Record<string, string>): void {
    writeFileSync(join(root, "proc/self/cgroup"), "0::/\n");
    mkdirSync(join(root, "sys/fs/cgroup"), { recursive: true });
    for (const [name, text] of Object.entries(files)) {
      writeFileSync(join(root, "sys/fs/cgroup", name), text);
    }
  }

  it("reports a Docker container's cgroup usage against its limits, not the host's", async () => {
    writeFileSync(join(root, ".dockerenv"), "");
    writeCgroupV2({
      "memory.current": String(900 * MB),
      "memory.stat": `anon 500\ninactive_file ${100 * MB}\nactive_file 5\n`,
      "memory.max": String(2048 * MB),
      "cpu.max": "200000 100000\n",
      "cpu.stat": "usage_usec 1000000\nuser_usec 1\n",
    });
    let clock = 10_000;
    const probe = new HostResourceProbe({
      diskPath: root,
      fsRoot: root,
      platform: "linux",
      env: {},
      now: () => clock,
    });

    const first = await probe.sample();
    expect(first).toMatchObject({
      scope: "container",
      cpuCores: 2,
      cpuLimited: true,
      memUsed: 800,
      memTotal: 2048,
      memLimited: true,
    });
    expect(first.load1).toBeUndefined();
    expect(first.diskTotal).toBeGreaterThan(0);

    // 10 s on a 2-core limit is 20 s of CPU; 5 s used is 25%.
    clock += 10_000;
    writeFileSync(join(root, "sys/fs/cgroup/cpu.stat"), "usage_usec 6000000\n");
    expect((await probe.sample()).cpu).toBe(25);
  });

  it("uses machine memory as the ceiling when a container has no memory limit", async () => {
    writeFileSync(join(root, ".dockerenv"), "");
    writeCgroupV2({
      "memory.current": String(1000 * MB),
      "memory.stat": "inactive_file 0\n",
      "memory.max": "max\n",
      "cpu.max": "max 100000\n",
      "cpu.stat": "usage_usec 0\n",
    });
    const probe = new HostResourceProbe({
      diskPath: root,
      fsRoot: root,
      platform: "linux",
      env: {},
    });

    const sample = await probe.sample();
    expect(sample.scope).toBe("container");
    expect(sample.memTotal).toBeCloseTo(16000000 / 1024, 1);
    expect(sample.memUsed).toBe(1000);
    // The machine's capacity is not the container's limit, so it is not labeled one.
    expect(sample.memLimited).toBeUndefined();
    expect(sample.cpuLimited).toBeUndefined();
  });

  it("reads cgroup v1 controllers in older container runtimes", async () => {
    writeFileSync(join(root, ".dockerenv"), "");
    writeFileSync(join(root, "proc/self/cgroup"), "4:memory:/\n3:cpu,cpuacct:/\n");
    mkdirSync(join(root, "sys/fs/cgroup/memory"), { recursive: true });
    mkdirSync(join(root, "sys/fs/cgroup/cpu,cpuacct"), { recursive: true });
    writeFileSync(join(root, "sys/fs/cgroup/memory/memory.usage_in_bytes"), String(600 * MB));
    writeFileSync(
      join(root, "sys/fs/cgroup/memory/memory.stat"),
      `total_inactive_file ${100 * MB}\n`,
    );
    writeFileSync(join(root, "sys/fs/cgroup/memory/memory.limit_in_bytes"), "9223372036854771712");
    writeFileSync(join(root, "sys/fs/cgroup/cpu,cpuacct/cpuacct.usage"), "0");
    writeFileSync(join(root, "sys/fs/cgroup/cpu,cpuacct/cpu.cfs_quota_us"), "50000");
    writeFileSync(join(root, "sys/fs/cgroup/cpu,cpuacct/cpu.cfs_period_us"), "100000");
    const probe = new HostResourceProbe({
      diskPath: root,
      fsRoot: root,
      platform: "linux",
      env: {},
    });

    expect(await probe.sample()).toMatchObject({
      scope: "container",
      cpuCores: 0.5,
      cpuLimited: true,
      memUsed: 500,
    });
  });

  it("reads cgroup v1 usage and quota when cpu and cpuacct are mounted apart", async () => {
    writeFileSync(join(root, ".dockerenv"), "");
    writeFileSync(join(root, "proc/self/cgroup"), "5:memory:/\n4:cpuacct:/\n3:cpu:/\n");
    for (const dir of ["memory", "cpu", "cpuacct"]) {
      mkdirSync(join(root, "sys/fs/cgroup", dir), { recursive: true });
    }
    writeFileSync(join(root, "sys/fs/cgroup/memory/memory.usage_in_bytes"), String(300 * MB));
    writeFileSync(join(root, "sys/fs/cgroup/memory/memory.stat"), "total_inactive_file 0\n");
    writeFileSync(join(root, "sys/fs/cgroup/memory/memory.limit_in_bytes"), String(1024 * MB));
    writeFileSync(join(root, "sys/fs/cgroup/cpuacct/cpuacct.usage"), "0");
    writeFileSync(join(root, "sys/fs/cgroup/cpu/cpu.cfs_quota_us"), "300000");
    writeFileSync(join(root, "sys/fs/cgroup/cpu/cpu.cfs_period_us"), "100000");
    const probe = new HostResourceProbe({
      diskPath: root,
      fsRoot: root,
      platform: "linux",
      env: {},
    });

    expect(await probe.sample()).toMatchObject({
      scope: "container",
      cpuCores: 3,
      cpuLimited: true,
      memTotal: 1024,
      memLimited: true,
    });
  });

  it("leaves a container's CPU and memory out when its cgroup is unreadable", async () => {
    writeFileSync(join(root, ".dockerenv"), "");
    const probe = new HostResourceProbe({
      diskPath: root,
      fsRoot: root,
      platform: "linux",
      env: {},
    });

    const sample = await probe.sample();
    expect(sample.scope).toBe("container");
    expect(sample.memUsed).toBeUndefined();
    expect(sample.cpuCores).toBeUndefined();
  });

  it("reports a plain Linux host from /proc/meminfo with load average", async () => {
    const probe = new HostResourceProbe({
      diskPath: root,
      fsRoot: root,
      platform: "linux",
      env: {},
    });

    const sample = await probe.sample();
    expect(sample).toMatchObject({
      scope: "host",
      memUsed: 12000000 / 1024,
      memTotal: 16000000 / 1024,
    });
    expect(typeof sample.load1).toBe("number");
  });
});

describe("host memory parsing", () => {
  it("reads Activity Monitor's Memory Used from vm_stat", () => {
    const output = [
      "Mach Virtual Memory Statistics: (page size of 16384 bytes)",
      "Pages free:                                  3492898.",
      "Pages wired down:                            8217591.",
      "Pages purgeable:                               49111.",
      "Anonymous pages:                             5273308.",
      "Pages occupied by compressor:                3457473.",
    ].join("\n");
    expect(parseVmStatUsedBytes(output)).toBe((5273308 - 49111 + 8217591 + 3457473) * 16384);
    expect(parseVmStatUsedBytes("Pages free: 1.")).toBeUndefined();
  });

  it("reads used memory from /proc/meminfo as total minus available", () => {
    const output = "MemTotal:       16000000 kB\nMemFree:  100 kB\nMemAvailable:    4000000 kB\n";
    expect(parseMeminfoUsedBytes(output)).toEqual({
      used: 12000000 * 1024,
      total: 16000000 * 1024,
    });
  });
});

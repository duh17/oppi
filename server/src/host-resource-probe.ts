/**
 * Host readings for the server resource sampler: CPU, memory, and disk for the
 * machine Oppi runs on, or for its container when it runs in one.
 *
 * Each platform reports its own notion of "used" so the page agrees with the
 * tool people already trust there:
 * - macOS: `vm_stat`, Activity Monitor's Memory Used (app + wired + compressed).
 *   Node's `os.freemem()` counts only free pages and reads ~90% used.
 * - Linux: `/proc/meminfo` MemTotal − MemAvailable, like `free`.
 * - Linux container (Docker, Podman, Kubernetes): the container's cgroup, like
 *   `docker stats`: memory is usage minus inactive file cache against the
 *   memory limit, CPU is usage against the CPU limit. Machine-wide numbers
 *   would describe the host, not what the container may use. Load average is
 *   the host's, so it is left out.
 * - Other: `os.totalmem()` − `os.freemem()` and `os.cpus()` times.
 * Disk is `statfs` on the Oppi data directory, which inside a container is the
 * mounted volume. A reading that fails is left out of the sample, never
 * estimated or replaced with the host's.
 */

import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { readFile, statfs } from "node:fs/promises";
import { availableParallelism, cpus, freemem, loadavg, totalmem } from "node:os";
import { join } from "node:path";

import { createLogger } from "./logger.js";
import { round2 } from "./metric-utils.js";
import type { HostRecord } from "./server-metrics-history.js";

const log = createLogger({ base: { component: "host_resource_probe" } });

const BYTES_PER_MB = 1024 * 1024;
const VM_STAT_TIMEOUT_MS = 5_000;
/** cgroup v1 reports "no limit" as a page-rounded INT64_MAX. */
const CGROUP_V1_UNLIMITED = 2 ** 62;

/** Memory used per Activity Monitor: app + wired + compressed pages. */
export function parseVmStatUsedBytes(output: string): number | undefined {
  const pageSize = Number(/page size of (\d+) bytes/.exec(output)?.[1]);
  if (!Number.isFinite(pageSize) || pageSize <= 0) return undefined;
  const pages = (label: string): number | undefined => {
    const match = new RegExp(`^${label}:\\s+(\\d+)\\.`, "m").exec(output);
    return match ? Number(match[1]) : undefined;
  };
  const anonymous = pages("Anonymous pages");
  const purgeable = pages("Pages purgeable");
  const wired = pages("Pages wired down");
  const compressed = pages("Pages occupied by compressor");
  if (
    anonymous === undefined ||
    purgeable === undefined ||
    wired === undefined ||
    compressed === undefined
  ) {
    return undefined;
  }
  return (anonymous - purgeable + wired + compressed) * pageSize;
}

/** MemTotal − MemAvailable, in bytes. */
export function parseMeminfoUsedBytes(output: string): { used: number; total: number } | undefined {
  const kb = (label: string): number | undefined => {
    const match = new RegExp(`^${label}:\\s+(\\d+) kB`, "m").exec(output);
    return match ? Number(match[1]) * 1024 : undefined;
  };
  const total = kb("MemTotal");
  const available = kb("MemAvailable");
  if (total === undefined || available === undefined) return undefined;
  return { used: total - available, total };
}

function statValue(stat: string, key: string): number | undefined {
  const match = new RegExp(`^${key} (\\d+)$`, "m").exec(stat);
  return match ? Number(match[1]) : undefined;
}

function runVmStat(): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("vm_stat", { timeout: VM_STAT_TIMEOUT_MS }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });
}

interface Reading {
  used: number;
  total: number;
  /** The total is a container's own cap, not the machine's capacity. */
  limited?: boolean;
}

/** CPU time consumed so far, microseconds, and the CPUs it may use. */
interface CpuUsage {
  usageUs: number;
  cores: number;
  /** `cores` is a container's CPU quota, not the CPUs it may run on. */
  limited?: boolean;
}

/** Where this process's cgroup files live, and which cgroup version. */
interface Cgroup {
  version: 1 | 2;
  /** v2: the unified directory. v1: the memory controller directory. */
  memoryDir: string;
  /** v2: the unified directory. v1: the directory holding `cpuacct.usage`. */
  usageDir: string;
  /** v2: the unified directory. v1: the `cpu` controller, when mounted (holds the quota). */
  quotaDir?: string;
}

export interface HostProbeOptions {
  /** Directory whose volume the disk reading describes (the Oppi data dir). */
  diskPath: string;
  /** Filesystem root for `/proc`, `/sys/fs/cgroup`, and container markers. Tests only. */
  fsRoot?: string;
  platform?: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
  now?: () => number;
}

function isContainer(fsRoot: string, env: NodeJS.ProcessEnv): boolean {
  return (
    existsSync(join(fsRoot, ".dockerenv")) ||
    existsSync(join(fsRoot, "run/.containerenv")) ||
    Boolean(env.container) ||
    Boolean(env.KUBERNETES_SERVICE_HOST)
  );
}

/**
 * The cgroup directories for this process. A container usually has its own
 * cgroup namespace, so `/proc/self/cgroup` says `/` and the files sit at the
 * mount root; without one the listed path is appended.
 */
function findCgroup(fsRoot: string): Cgroup | undefined {
  let membership: string;
  try {
    membership = readFileSync(join(fsRoot, "proc/self/cgroup"), "utf8");
  } catch {
    return undefined;
  }
  const mount = join(fsRoot, "sys/fs/cgroup");
  const pick = (base: string, path: string, probe: string): string | undefined =>
    [join(base, path), base].find((dir) => existsSync(join(dir, probe)));

  const unified = /^0::(.*)$/m.exec(membership)?.[1];
  if (unified !== undefined) {
    const dir = pick(mount, unified, "memory.current");
    if (dir) return { version: 2, memoryDir: dir, usageDir: dir, quotaDir: dir };
  }
  // v1 lists each hierarchy with its controllers: `4:memory:/x`, `3:cpu,cpuacct:/x`,
  // or `cpu` and `cpuacct` on separate lines when they are mounted apart.
  const v1Path = (controller: string): string | undefined =>
    new RegExp(`^\\d+:(?:[^:]*,)?${controller}(?:,[^:]*)?:(.*)$`, "m").exec(membership)?.[1];
  const firstDir = (names: string[], path: string, probe: string): string | undefined =>
    names.map((name) => pick(join(mount, name), path, probe)).find(Boolean);
  const memoryPath = v1Path("memory");
  const usagePath = v1Path("cpuacct");
  if (memoryPath !== undefined && usagePath !== undefined) {
    const memoryDir = pick(join(mount, "memory"), memoryPath, "memory.usage_in_bytes");
    const usageDir = firstDir(
      ["cpu,cpuacct", "cpuacct,cpu", "cpuacct"],
      usagePath,
      "cpuacct.usage",
    );
    const quotaPath = v1Path("cpu");
    const quotaDir =
      quotaPath === undefined
        ? undefined
        : firstDir(["cpu,cpuacct", "cpuacct,cpu", "cpu"], quotaPath, "cpu.cfs_quota_us");
    if (memoryDir && usageDir) return { version: 1, memoryDir, usageDir, quotaDir };
  }
  return undefined;
}

export class HostResourceProbe {
  private readonly diskPath: string;
  private readonly fsRoot: string;
  private readonly platform: NodeJS.Platform;
  private readonly now: () => number;
  private readonly cgroup: Cgroup | undefined;
  readonly scope: HostRecord["scope"];
  private last: { usageUs: number; at: number } | undefined;
  /** Bumped by reset(); a CPU read from before it must not become the baseline. */
  private generation = 0;
  private readonly warned = new Set<string>();

  constructor(options: HostProbeOptions) {
    this.diskPath = options.diskPath;
    this.fsRoot = options.fsRoot ?? "/";
    this.platform = options.platform ?? process.platform;
    this.now = options.now ?? Date.now;
    const containerized =
      this.platform === "linux" && isContainer(this.fsRoot, options.env ?? process.env);
    this.cgroup = containerized ? findCgroup(this.fsRoot) : undefined;
    if (containerized && !this.cgroup) {
      log.warn("host_resource_probe.cgroup_unreadable", { fsRoot: this.fsRoot });
    }
    // A container whose cgroup cannot be read still reports as a container:
    // its CPU and memory are left out rather than shown as the host's.
    this.scope = containerized ? "container" : "host";
  }

  /**
   * Restart CPU deltas from now, so the first sample after a (re)start has a
   * CPU reading and never averages the time sampling was off.
   */
  reset(): void {
    this.last = undefined;
    const generation = ++this.generation;
    void this.readCpu().then((cpu) => {
      if (cpu && generation === this.generation && !this.last) {
        this.last = { usageUs: cpu.usageUs, at: this.now() };
      }
    });
  }

  async sample(): Promise<HostRecord> {
    const generation = this.generation;
    const [memory, disk, cpu] = await Promise.all([
      this.readMemory(),
      this.readDisk(),
      this.readCpu(),
    ]);
    const record: HostRecord = { scope: this.scope };
    // A read that straddled reset() belongs to the stopped run; keep the new baseline.
    if (cpu && generation === this.generation) {
      record.cpuCores = round2(cpu.cores);
      if (cpu.limited) record.cpuLimited = true;
      const at = this.now();
      const previous = this.last;
      this.last = { usageUs: cpu.usageUs, at };
      const elapsedUs = previous ? (at - previous.at) * 1000 : 0;
      if (previous && elapsedUs > 0 && cpu.usageUs >= previous.usageUs) {
        const share = (cpu.usageUs - previous.usageUs) / (elapsedUs * cpu.cores);
        record.cpu = round2(Math.min(Math.max(share, 0), 1) * 100);
      }
    }
    if (this.scope === "host" && this.platform !== "win32") {
      record.load1 = round2(loadavg()[0] ?? 0);
    }
    if (memory) {
      record.memUsed = round2(memory.used / BYTES_PER_MB);
      record.memTotal = round2(memory.total / BYTES_PER_MB);
      if (memory.limited) record.memLimited = true;
    }
    if (disk) {
      record.diskUsed = round2(disk.used / BYTES_PER_MB);
      record.diskTotal = round2(disk.total / BYTES_PER_MB);
    }
    return record;
  }

  private async readCpu(): Promise<CpuUsage | undefined> {
    if (this.scope === "host") {
      // os.cpus() times are milliseconds; busy is everything but idle.
      let busyMs = 0;
      const all = cpus();
      for (const { times } of all) busyMs += times.user + times.nice + times.sys + times.irq;
      return { usageUs: busyMs * 1000, cores: all.length };
    }
    const cgroup = this.cgroup;
    if (!cgroup) return undefined;
    try {
      let usageUs: number;
      if (cgroup.version === 2) {
        const usec = statValue(await this.read(cgroup.usageDir, "cpu.stat"), "usage_usec");
        if (usec === undefined) throw new Error("cpu.stat has no usage_usec");
        usageUs = usec;
      } else {
        usageUs = Number((await this.read(cgroup.usageDir, "cpuacct.usage")).trim()) / 1000;
        if (!Number.isFinite(usageUs)) throw new Error("unreadable cpuacct.usage");
      }
      const quota = await this.readQuotaCores(cgroup);
      return quota === undefined
        ? { usageUs, cores: availableParallelism() }
        : { usageUs, cores: quota, limited: true };
    } catch (err) {
      this.warnOnce("cpu", err);
      return undefined;
    }
  }

  /** The container's CPU quota in cores; undefined when it has none or it cannot be read. */
  private async readQuotaCores(cgroup: Cgroup): Promise<number | undefined> {
    if (!cgroup.quotaDir) return undefined;
    try {
      let quota: number;
      let period: number;
      if (cgroup.version === 2) {
        const [q, p] = (await this.read(cgroup.quotaDir, "cpu.max")).trim().split(/\s+/);
        if (q === "max") return undefined;
        quota = Number(q);
        period = Number(p);
      } else {
        quota = Number((await this.read(cgroup.quotaDir, "cpu.cfs_quota_us")).trim());
        period = Number((await this.read(cgroup.quotaDir, "cpu.cfs_period_us")).trim());
      }
      return quota > 0 && period > 0 ? quota / period : undefined;
    } catch (err) {
      // Usage alone still answers: against every CPU, as with no quota.
      this.warnOnce("cpu_quota", err);
      return undefined;
    }
  }

  private async readMemory(): Promise<Reading | undefined> {
    try {
      if (this.scope === "container") {
        if (!this.cgroup) return undefined;
        return await this.readCgroupMemory(this.cgroup);
      }
      switch (this.platform) {
        case "darwin": {
          const used = parseVmStatUsedBytes(await runVmStat());
          if (used === undefined) throw new Error("unrecognized vm_stat output");
          return { used, total: totalmem() };
        }
        case "linux": {
          const parsed = parseMeminfoUsedBytes(await this.read(this.fsRoot, "proc/meminfo"));
          if (!parsed) throw new Error("unrecognized /proc/meminfo");
          return parsed;
        }
        default:
          return { used: totalmem() - freemem(), total: totalmem() };
      }
    } catch (err) {
      this.warnOnce("memory", err);
      return undefined;
    }
  }

  private async readCgroupMemory(cgroup: Cgroup): Promise<Reading> {
    const v2 = cgroup.version === 2;
    const usage = Number(
      (await this.read(cgroup.memoryDir, v2 ? "memory.current" : "memory.usage_in_bytes")).trim(),
    );
    const stat = await this.read(cgroup.memoryDir, "memory.stat");
    const inactiveFile = statValue(stat, v2 ? "inactive_file" : "total_inactive_file") ?? 0;
    const rawLimit = (
      await this.read(cgroup.memoryDir, v2 ? "memory.max" : "memory.limit_in_bytes")
    ).trim();
    const limit = Number(rawLimit);
    const unlimited = rawLimit === "max" || !(limit > 0) || limit >= CGROUP_V1_UNLIMITED;
    if (!Number.isFinite(usage)) throw new Error("unreadable cgroup memory usage");
    const used = Math.max(usage - inactiveFile, 0);
    if (!unlimited) return { used, total: limit, limited: true };
    // No memory limit: the container may use the whole machine.
    const meminfo = parseMeminfoUsedBytes(await this.read(this.fsRoot, "proc/meminfo"));
    return { used, total: meminfo?.total ?? totalmem() };
  }

  private async readDisk(): Promise<Reading | undefined> {
    try {
      const stats = await statfs(this.diskPath);
      const total = stats.blocks * stats.bsize;
      // Used is what the user cannot write: total minus space available to them.
      return { used: total - stats.bavail * stats.bsize, total };
    } catch (err) {
      this.warnOnce("disk", err);
      return undefined;
    }
  }

  private read(dir: string, file: string): Promise<string> {
    return readFile(join(dir, file), "utf8");
  }

  private warnOnce(part: string, err: unknown): void {
    if (this.warned.has(part)) return;
    this.warned.add(part);
    log.warn("host_resource_probe.read_failed", {
      part,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

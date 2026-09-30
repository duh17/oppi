import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { McpError } from "./mcp-config.js";

/** Resolve the package's declared CLI, not dist/cli.js (the unbundled shim). */
function piCliPath(): string {
  const root = dirname(
    dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))),
  );
  const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as {
    bin: { pi: string };
  };
  return join(root, pkg.bin.pi);
}
/** Snapshot before signalling: Pi's detached stdio groups reparent when the CLI dies.
 * This does not depend on the CLI processing a signal or running JS exit hooks. */
function descendantGroups(pid: number): Set<number> {
  const rows = execFileSync("ps", ["-A", "-o", "pid=,ppid=,pgid="], {
    encoding: "utf8",
    timeout: 1000,
    maxBuffer: 4 * 1024 * 1024,
  })
    .trim()
    .split("\n")
    .map((line) => line.trim().split(/\s+/).map(Number));
  const descendants = new Set([pid]);
  const groups = new Set<number>();
  for (const parent of descendants) {
    for (const [child, ppid, pgid] of rows) {
      if (ppid === parent && child > 0 && pgid > 0) {
        descendants.add(child);
        groups.add(pgid);
      }
    }
  }
  return groups;
}
export interface McpCliProcess {
  child: ChildProcess;
  done: Promise<{ code: number; stdout: string }>;
  stop(): void;
}
export class McpCli {
  readonly globalCwd: string;
  private readonly phonePath: string;
  constructor(readonly agentDir: string) {
    // A neutral cwd prevents global operations from resolving a project's shadowing entry.
    this.globalCwd = mkdtempSync(join(tmpdir(), "oppi-mcp-"));
    const bin = join(this.globalCwd, "bin");
    mkdirSync(bin);
    for (const command of ["open", "xdg-open"])
      writeFileSync(join(bin, command), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    this.phonePath = `${bin}:${process.env.PATH ?? ""}`;
  }
  start(
    args: string[],
    cwd: string,
    options: { phone?: boolean; onLine?: (line: string) => void; timeoutMs?: number } = {},
  ): McpCliProcess {
    const child = spawn(process.execPath, [piCliPath(), "mcp", ...args], {
      cwd,
      detached: process.platform !== "win32",
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PI_CODING_AGENT_DIR: this.agentDir,
        NO_COLOR: "1",
        ...(options.phone ? { PATH: this.phonePath } : {}),
      },
    });
    let exited = false;
    let stopping: Promise<void> | undefined;
    const stop = (): void => {
      if (!child.pid || exited || stopping) return;
      const pid = child.pid;
      let groups = new Set<number>();
      if (process.platform !== "win32") {
        try {
          groups = descendantGroups(pid);
        } catch {
          // Even if process-table access fails, still terminate the CLI's own group.
        }
        groups.add(pid);
      }
      const signal = (kind: NodeJS.Signals): void => {
        for (const group of groups) {
          try {
            process.kill(-group, kind);
          } catch {
            /* already stopped */
          }
        }
        if (process.platform === "win32" && !exited) {
          try {
            child.kill(kind);
          } catch {
            /* already stopped */
          }
        }
      };
      signal("SIGTERM");
      stopping = new Promise((resolve) => {
        // CLI close must not cancel escalation for its now-orphaned stdio groups.
        setTimeout(() => {
          signal("SIGKILL");
          resolve();
        }, 1500);
      });
    };
    const done = new Promise<{ code: number; stdout: string }>((resolve, reject) => {
      let stdout = "";
      let pending = "";
      let bytes = 0;
      let failure: Error | undefined;
      const timer = setTimeout(() => {
        failure = new McpError(504, "Pi MCP command timed out");
        stop();
      }, options.timeoutMs ?? 90_000);
      timer.unref();
      const consume = (chunk: Buffer, output: boolean): void => {
        bytes += chunk.length;
        if (bytes > 4 * 1024 * 1024) {
          failure = new McpError(502, "Pi MCP output exceeded the limit");
          stop();
          return;
        }
        const text = chunk.toString("utf8");
        if (output) stdout += text;
        if (!output || !options.onLine) return;
        pending += text;
        let end: number;
        while ((end = pending.indexOf("\n")) >= 0) {
          const line = pending.slice(0, end).trim();
          pending = pending.slice(end + 1);
          // No child output is logged: authorization URLs and config secrets stay private.
          options.onLine(line);
        }
      };
      child.stdout?.on("data", (chunk: Buffer) => consume(chunk, true));
      child.stderr?.on("data", (chunk: Buffer) => consume(chunk, false));
      child.once("error", () => {
        failure = new McpError(502, "Could not start Pi MCP command");
      });
      child.once("close", (code) => {
        exited = true;
        clearTimeout(timer);
        if (pending) options.onLine?.(pending.trim());
        // Management (including login cancel/expiry) stays owned until escalation ends.
        void (stopping ?? Promise.resolve()).then(() => {
          if (failure) reject(failure);
          else resolve({ code: code ?? 1, stdout });
        });
      });
    });
    return { child, done, stop };
  }
  async run(
    args: string[],
    cwd: string,
    options: { timeoutMs?: number } = {},
  ): Promise<{ code: number; stdout: string }> {
    return this.start(args, cwd, options).done;
  }
}

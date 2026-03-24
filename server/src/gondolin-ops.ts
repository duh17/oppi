/**
 * Gondolin-backed tool operations for sandboxed workspace execution.
 *
 * Maps pi SDK tool operations (bash, read, write, edit) into a Gondolin
 * micro-VM. Host paths are translated to /workspace inside the guest,
 * and all file I/O and command execution runs in QEMU isolation.
 *
 * Adapted from https://github.com/earendil-works/gondolin/blob/main/host/examples/pi-gondolin.ts
 */

import { relative, resolve, posix } from "node:path";
import type {
  BashOperations,
  ReadOperations,
  WriteOperations,
  EditOperations,
} from "@mariozechner/pi-coding-agent";

/**
 * Minimal VM interface consumed by the operations layer.
 *
 * Matches the subset of `VM` from `@earendil-works/gondolin` that we
 * actually call. Typed locally so the module compiles without the
 * gondolin package installed (it is a runtime-only dependency).
 */
export interface GondolinVm {
  exec(
    args: string[] | string,
    options?: {
      cwd?: string;
      env?: Record<string, string>;
      signal?: AbortSignal;
      stdout?: "pipe" | "buffer";
      stderr?: "pipe" | "buffer";
    },
  ): GondolinProcess;
}

/**
 * Matches ExecProcess from Gondolin — a PromiseLike that resolves to ExecResult.
 * Call output() for streaming chunks, or await directly for buffered result.
 */
export interface GondolinProcess extends PromiseLike<GondolinExecResult> {
  output(): AsyncIterable<{ stream: "stdout" | "stderr"; data: Buffer }>;
}

export interface GondolinExecResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stdoutBuffer: Buffer;
  readonly ok: boolean;
}

/** Guest mount point for the host workspace directory. */
export const GUEST_WORKSPACE = "/workspace";

/**
 * Map a host-absolute path into the guest /workspace tree.
 *
 * Pi tools always pass absolute host paths. We compute the relative offset
 * from the workspace root and re-anchor it under GUEST_WORKSPACE.
 *
 * Paths that escape the workspace (e.g. /etc/passwd) are resolved as-is
 * inside the guest — the VM filesystem boundary provides the real guard.
 */
export function toGuestPath(localCwd: string, localPath: string): string {
  const resolved = resolve(localPath);
  const rel = relative(localCwd, resolved);

  // Path escapes workspace — pass through to guest as absolute
  if (rel.startsWith("..") || resolve(localCwd, rel) !== resolved) {
    return resolved;
  }

  return posix.join(GUEST_WORKSPACE, rel.split(/[\\/]/).join("/"));
}

/** Wrap a value in single quotes, escaping embedded single quotes. */
function shellQuote(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

// ─── Bash ───

export function createGondolinBashOps(vm: GondolinVm, localCwd: string): BashOperations {
  return {
    async exec(
      command: string,
      cwd: string,
      options: { onData: (data: Buffer) => void; signal?: AbortSignal; timeout?: number; env?: NodeJS.ProcessEnv },
    ) {
      const guestCwd = toGuestPath(localCwd, cwd);
      const env = options.env
        ? Object.fromEntries(
            Object.entries(options.env).filter((e): e is [string, string] => typeof e[1] === "string"),
          )
        : undefined;

      const proc = vm.exec(["/bin/bash", "-lc", command], {
        cwd: guestCwd,
        signal: options.signal,
        env,
        stdout: "pipe",
        stderr: "pipe",
      });

      for await (const chunk of proc.output()) {
        options.onData(chunk.data);
      }

      const result = await proc;
      return { exitCode: result.exitCode };
    },
  };
}

// ─── Read ───

export function createGondolinReadOps(vm: GondolinVm, localCwd: string): ReadOperations {
  return {
    async readFile(absolutePath: string) {
      const guestPath = toGuestPath(localCwd, absolutePath);
      const result = await vm.exec(["/bin/cat", guestPath]);
      if (!result.ok) {
        throw new Error(`Failed to read ${guestPath}: ${result.stdout || "file not found"}`);
      }
      return result.stdoutBuffer;
    },

    async access(absolutePath: string) {
      const guestPath = toGuestPath(localCwd, absolutePath);
      // Use ls rather than test -r or stat — FUSE-mounted VFS may not support them reliably.
      const result = await vm.exec(["/bin/ls", "-d", guestPath]);
      if (!result.ok) {
        throw new Error(`ENOENT: no such file or directory, access '${guestPath}'`);
      }
    },

    async detectImageMimeType(absolutePath: string) {
      const guestPath = toGuestPath(localCwd, absolutePath);
      const result = await vm.exec(["/usr/bin/file", "--mime-type", "-b", guestPath]);
      if (!result.ok) return null;

      const mime = result.stdout.trim();
      return mime.startsWith("image/") ? mime : null;
    },
  };
}

// ─── Write ───

export function createGondolinWriteOps(vm: GondolinVm, localCwd: string): WriteOperations {
  return {
    async writeFile(absolutePath: string, content: string) {
      const guestPath = toGuestPath(localCwd, absolutePath);
      const dir = posix.dirname(guestPath);
      // Base64-encode content to avoid shell quoting issues with arbitrary file content.
      const b64 = Buffer.from(content, "utf-8").toString("base64");

      const cmd = `mkdir -p ${shellQuote(dir)} && echo ${shellQuote(b64)} | base64 -d > ${shellQuote(guestPath)}`;
      const result = await vm.exec(["/bin/bash", "-c", cmd]);
      if (!result.ok) {
        throw new Error(`Failed to write ${guestPath}: ${result.stdout || "write failed"}`);
      }
    },

    async mkdir(dir: string) {
      const guestDir = toGuestPath(localCwd, dir);
      const result = await vm.exec(["/bin/mkdir", "-p", guestDir]);
      if (!result.ok) {
        throw new Error(`Failed to mkdir ${guestDir}: ${result.stdout || "mkdir failed"}`);
      }
    },
  };
}

// ─── Edit ───

/**
 * Edit operations composed from read + write against the VM.
 * The pi SDK edit tool reads the file, applies the diff in-process,
 * then writes the result back — so we only need readFile, writeFile, access.
 */
export function createGondolinEditOps(vm: GondolinVm, localCwd: string): EditOperations {
  const readOps = createGondolinReadOps(vm, localCwd);
  const writeOps = createGondolinWriteOps(vm, localCwd);

  return {
    readFile: readOps.readFile,
    writeFile: writeOps.writeFile,
    access: readOps.access,
  };
}

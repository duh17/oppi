/**
 * Gondolin-backed tool operations for sandboxed workspace execution.
 *
 * Maps pi SDK tool operations (bash, read, write, edit) into a Gondolin
 * micro-VM. Host paths are translated to /workspace inside the guest,
 * and all file I/O and command execution runs in QEMU isolation.
 *
 * Adapted from https://github.com/earendil-works/gondolin/blob/main/host/examples/pi-gondolin.ts
 */

import { existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join, relative, resolve, posix } from "node:path";
import type {
  BashOperations,
  ReadOperations,
  WriteOperations,
  EditOperations,
  LsOperations,
} from "@earendil-works/pi-coding-agent";

/**
 * Minimal VM interface consumed by the operations layer.
 *
 * Matches the subset of `VM` from `@earendil-works/gondolin` that we
 * actually call. Typed locally so the module compiles without the
 * gondolin package installed (it is a runtime-only dependency).
 */
export interface GondolinVm {
  fs: GondolinFs;
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
  /** Shell path detected during VM startup. Defaults to /bin/bash when absent. */
  shellPath?: string;
}

export interface GondolinFs {
  access(path: string): Promise<void>;
  mkdir(path: string, options?: { recursive?: boolean }): Promise<void>;
  readFile(path: string, options?: { encoding?: null }): Promise<Buffer>;
  writeFile(
    path: string,
    content: string | Buffer,
    options?: { encoding?: BufferEncoding },
  ): Promise<void>;
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
 * Paths that escape the workspace are rejected for file-tool operations. Bash
 * commands still execute inside the VM and can inspect the guest filesystem,
 * but pi file tools should stay within the configured workspace mount so the
 * model never confuses guest absolute paths with host paths.
 */
export function toGuestPath(
  localCwd: string,
  localPath: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): string {
  const resolved = resolve(localPath);
  const rel = relative(localCwd, resolved);

  if (rel.startsWith("..") || resolve(localCwd, rel) !== resolved) {
    throw new Error(`Path is outside the sandbox workspace: ${localPath}`);
  }

  return posix.join(guestWorkspace, rel.split(/[\\/]/).join("/"));
}

/**
 * Map a sandbox tool path back onto the host workspace mount.
 *
 * Sandbox sessions advertise guest cwd `/workspace/<slug>`. Host-backed
 * ls/find/grep still run on the Mac, so they must not stat that guest path.
 * The workspace mount is the same tree the guest already sees.
 */
export function toHostPath(absolutePath: string, hostCwd: string, guestCwd: string): string {
  const resolved = resolve(absolutePath);
  const guestRoot = resolve(guestCwd);
  const hostRoot = resolve(hostCwd);
  const guestPrefix = guestRoot.endsWith("/") ? guestRoot : `${guestRoot}/`;

  if (resolved === guestRoot) return hostRoot;
  if (resolved.startsWith(guestPrefix)) {
    return join(hostRoot, resolved.slice(guestPrefix.length));
  }

  throw new Error(`Path is outside the sandbox workspace: ${absolutePath}`);
}

// ─── Bash ───

const PI_SESSION_METADATA_ENV_KEYS = [
  "PI_PROVIDER",
  "PI_MODEL",
  "PI_REASONING_LEVEL",
  "PI_SESSION_ID",
] as const;

function selectPiSessionMetadataEnv(
  env: NodeJS.ProcessEnv | undefined,
): Record<string, string> | undefined {
  const selected: Record<string, string> = {};

  for (const key of PI_SESSION_METADATA_ENV_KEYS) {
    const value = env?.[key];
    if (value) {
      selected[key] = value;
    }
  }

  return Object.keys(selected).length > 0 ? selected : undefined;
}

export function createGondolinBashOps(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): BashOperations {
  return {
    async exec(
      command: string,
      cwd: string,
      options: {
        onData: (data: Buffer) => void;
        signal?: AbortSignal;
        timeout?: number;
        env?: NodeJS.ProcessEnv;
      },
    ) {
      const guestCwd = toGuestPath(localCwd, cwd, guestWorkspace);
      // Pi's bash tool passes the host shell environment by default. Forward
      // only non-secret session metadata without host paths: provider
      // credentials and host identity stay on the trusted host side.
      // Workspace-level sandbox env is injected at VM creation time instead.
      const env = selectPiSessionMetadataEnv(options.env);
      const shellPath = vm.shellPath || "/bin/bash";

      const proc = vm.exec([shellPath, "-lc", command], {
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

export function createGondolinReadOps(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): ReadOperations {
  return {
    async readFile(absolutePath: string) {
      const guestPath = toGuestPath(localCwd, absolutePath, guestWorkspace);
      try {
        return await vm.fs.readFile(guestPath);
      } catch (err) {
        const message = err instanceof Error ? err.message : "file not found";
        throw new Error(`Failed to read ${guestPath}: ${message}`, { cause: err });
      }
    },

    async access(absolutePath: string) {
      const guestPath = toGuestPath(localCwd, absolutePath, guestWorkspace);
      try {
        await vm.fs.access(guestPath);
      } catch {
        throw new Error(`ENOENT: no such file or directory, access '${guestPath}'`);
      }
    },

    async detectImageMimeType(absolutePath: string) {
      const guestPath = toGuestPath(localCwd, absolutePath, guestWorkspace);
      switch (posix.extname(guestPath).toLowerCase()) {
        case ".png":
          return "image/png";
        case ".jpg":
        case ".jpeg":
          return "image/jpeg";
        case ".gif":
          return "image/gif";
        case ".webp":
          return "image/webp";
        default:
          return null;
      }
    },
  };
}

// ─── Write ───

export function createGondolinWriteOps(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): WriteOperations {
  return {
    async writeFile(absolutePath: string, content: string) {
      const guestPath = toGuestPath(localCwd, absolutePath, guestWorkspace);
      const dir = posix.dirname(guestPath);
      try {
        await vm.fs.mkdir(dir, { recursive: true });
        await vm.fs.writeFile(guestPath, content, { encoding: "utf8" });
      } catch (err) {
        const message = err instanceof Error ? err.message : "write failed";
        throw new Error(`Failed to write ${guestPath}: ${message}`, { cause: err });
      }
    },

    async mkdir(dir: string) {
      const guestDir = toGuestPath(localCwd, dir, guestWorkspace);
      try {
        await vm.fs.mkdir(guestDir, { recursive: true });
      } catch (err) {
        const message = err instanceof Error ? err.message : "mkdir failed";
        throw new Error(`Failed to mkdir ${guestDir}: ${message}`, { cause: err });
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
export function createGondolinEditOps(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): EditOperations {
  const readOps = createGondolinReadOps(vm, localCwd, guestWorkspace);
  const writeOps = createGondolinWriteOps(vm, localCwd, guestWorkspace);

  return {
    readFile: readOps.readFile,
    writeFile: writeOps.writeFile,
    access: readOps.access,
  };
}

// ─── Ls ───

/**
 * Host-mount ls after remapping guest `/workspace/<slug>` paths.
 * Realpath must stay under the host mount. Shadowed secret names are hidden.
 */
export function createSandboxLsOps(
  hostCwd: string,
  guestCwd: string,
  options: { shouldShadow?: (posixPath: string) => boolean } = {},
): LsOperations {
  const shouldShadow = options.shouldShadow ?? (() => false);

  const contained = (absolutePath: string): string => {
    const mapped = toHostPath(absolutePath, hostCwd, guestCwd);
    const realRoot = realpathSync(hostCwd);
    const realTarget = existsSync(mapped) ? realpathSync(mapped) : mapped;
    const rootPrefix = realRoot.endsWith("/") ? realRoot : `${realRoot}/`;
    if (realTarget !== realRoot && !realTarget.startsWith(rootPrefix)) {
      throw new Error(`Path is outside the sandbox workspace: ${absolutePath}`);
    }
    const rel = relative(realRoot, existsSync(mapped) ? realTarget : mapped);
    const posixPath = posix.join("/", rel.split(/[\\/]/).join("/").replace(/^\.$/, ""));
    if (shouldShadow(posixPath === "/" ? "/" : posixPath)) {
      throw new Error(`ENOENT: no such file or directory, access '${absolutePath}'`);
    }
    return existsSync(mapped) ? realTarget : mapped;
  };

  return {
    exists(absolutePath: string) {
      try {
        return existsSync(contained(absolutePath));
      } catch {
        return false;
      }
    },
    stat(absolutePath: string) {
      return statSync(contained(absolutePath));
    },
    readdir(absolutePath: string) {
      const dir = contained(absolutePath);
      return readdirSync(dir).filter((name) => {
        const rel = relative(realpathSync(hostCwd), join(dir, name));
        const posixPath = posix.join("/", rel.split(/[\\/]/).join("/"));
        return !shouldShadow(posixPath);
      });
    },
  };
}

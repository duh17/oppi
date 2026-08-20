/**
 * Gondolin-backed tool operations for sandboxed workspace execution.
 *
 * Maps pi SDK tool operations (bash, read, write, edit, ls, find, grep)
 * into a Gondolin micro-VM. Host paths are translated to /workspace inside
 * the guest, and all file I/O and command execution runs in QEMU isolation.
 * Guest grep/find never spawn host rg/fd.
 *
 * Adapted from https://github.com/earendil-works/gondolin/blob/main/host/examples/pi-gondolin.ts
 */

import { isAbsolute, join, relative, resolve, posix } from "node:path";
import { Type } from "typebox";
import type {
  BashOperations,
  ReadOperations,
  WriteOperations,
  EditOperations,
  LsOperations,
  FindOperations,
  ToolDefinition,
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
  /** Guest directory listing. Sandbox ls requires this instead of host remount. */
  listDir?(dirPath: string, options?: { cwd?: string; signal?: AbortSignal }): Promise<string[]>;
  /** Guest stat. Sandbox ls requires this instead of host remount. */
  stat?(
    filePath: string,
    options?: { cwd?: string; signal?: AbortSignal },
  ): Promise<{ isDirectory: () => boolean; isFile?: () => boolean }>;
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
 * Sandbox sessions advertise guest cwd `/workspace/<slug>`. File tools now
 * stay on the guest VFS; this helper remains for callers that still need
 * the host mount equivalent of a guest path.
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

function guestPosixRelative(guestPath: string, guestWorkspace: string): string {
  const rel = posix.relative(guestWorkspace, guestPath);
  if (rel.startsWith("..")) {
    throw new Error(`Path is outside the sandbox workspace: ${guestPath}`);
  }
  return posix.join("/", rel === "" ? "" : rel);
}

/**
 * Guest ls through vm.fs.listDir/stat. Paths must stay inside the workspace
 * mount. Shadowed secret names are hidden. Host remount is not used.
 */
export function createSandboxLsOps(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
  options: { shouldShadow?: (posixPath: string) => boolean } = {},
): LsOperations {
  const shouldShadow = options.shouldShadow ?? (() => false);
  const listDir = vm.fs.listDir?.bind(vm.fs);
  const statFs = vm.fs.stat?.bind(vm.fs);

  const contained = (absolutePath: string): string => {
    const guestPath = toGuestPath(localCwd, absolutePath, guestWorkspace);
    const posixPath = guestPosixRelative(guestPath, guestWorkspace);
    if (shouldShadow(posixPath === "/" ? "/" : posixPath)) {
      throw new Error(`ENOENT: no such file or directory, access '${absolutePath}'`);
    }
    return guestPath;
  };

  return {
    async exists(absolutePath: string) {
      try {
        await vm.fs.access(contained(absolutePath));
        return true;
      } catch {
        return false;
      }
    },
    async stat(absolutePath: string) {
      if (!statFs) throw new Error("Sandbox ls requires vm.fs.stat");
      return statFs(contained(absolutePath));
    },
    async readdir(absolutePath: string) {
      if (!listDir) throw new Error("Sandbox ls requires vm.fs.listDir");
      const guestPath = contained(absolutePath);
      const posixPath = guestPosixRelative(guestPath, guestWorkspace);
      const entries = await listDir(guestPath);
      return entries.filter((name) => {
        const child = posix.join(posixPath === "/" ? "" : posixPath, name);
        const normalized = child.startsWith("/") ? child : `/${child}`;
        return !shouldShadow(normalized);
      });
    },
  };
}

// ─── Find ───

function findMatchArgs(pattern: string): string[] {
  if (pattern.includes("/")) {
    let pathPat = pattern.replaceAll("**", "*");
    if (!pathPat.startsWith("/") && !pathPat.startsWith("*")) {
      pathPat = `*/${pathPat}`;
    }
    return ["-path", pathPat];
  }
  return ["-name", pattern];
}

function findPruneNames(ignore: string[]): string[] {
  const names: string[] = [];
  for (const glob of ignore) {
    const trimmed = glob.replace(/\*\//g, "").replace(/\*\*/g, "").replaceAll("/", "");
    if (trimmed && !trimmed.includes("*") && !names.includes(trimmed)) names.push(trimmed);
  }
  return names.length > 0 ? names : ["node_modules", ".git"];
}

async function awaitGuestExec(
  vm: GondolinVm,
  args: string[],
  options?: { cwd?: string; signal?: AbortSignal },
): Promise<GondolinExecResult> {
  return vm.exec(args, {
    cwd: options?.cwd,
    signal: options?.signal,
    stdout: "buffer",
    stderr: "buffer",
  });
}

/**
 * Guest find through Alpine `find` via vm.exec. Do not use host fd.
 * Pi's createFindToolDefinition calls glob() instead of spawning fd when
 * this operations object is supplied.
 */
export function createGondolinFindOps(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): FindOperations {
  return {
    async exists(absolutePath: string) {
      try {
        const guestPath = toGuestPath(localCwd, absolutePath, guestWorkspace);
        await vm.fs.access(guestPath);
        return true;
      } catch {
        return false;
      }
    },
    async glob(pattern, cwd, options) {
      const guestPath = toGuestPath(localCwd, cwd, guestWorkspace);
      const prune = findPruneNames(options.ignore);
      // Gondolin array exec is execve-style and does not search PATH.
      const args = ["/usr/bin/find", guestPath];
      if (prune.length > 0) {
        args.push("(");
        for (const [index, name] of prune.entries()) {
          if (index > 0) args.push("-o");
          args.push("-name", name);
        }
        args.push(")", "-prune", "-o");
      }
      args.push("-type", "f", ...findMatchArgs(pattern), "-print");
      const result = await awaitGuestExec(vm, args, { cwd: guestWorkspace });
      if (!result.ok && !result.stdout.trim()) {
        throw new Error(result.stdout.trim() || `find exited with code ${result.exitCode}`);
      }
      const lines = result.stdout
        .split("\n")
        .map((line) => line.replace(/\r$/, "").trim())
        .filter(Boolean);
      return lines.slice(0, Math.max(1, options.limit));
    },
  };
}

// ─── Grep ───

const sandboxGrepSchema = Type.Object({
  pattern: Type.String({ description: "Search pattern (regex or literal string)" }),
  path: Type.Optional(
    Type.String({ description: "Directory or file to search (default: current directory)" }),
  ),
  glob: Type.Optional(
    Type.String({ description: "Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'" }),
  ),
  ignoreCase: Type.Optional(
    Type.Boolean({ description: "Case-insensitive search (default: false)" }),
  ),
  literal: Type.Optional(
    Type.Boolean({
      description: "Treat pattern as literal string instead of regex (default: false)",
    }),
  ),
  context: Type.Optional(
    Type.Number({
      description: "Number of lines to show before and after each match (default: 0)",
    }),
  ),
  limit: Type.Optional(
    Type.Number({ description: "Maximum number of matches to return (default: 100)" }),
  ),
});

function isHostHomeTildePath(input: string): boolean {
  return input === "~" || input.startsWith("~/") || input.startsWith("~\\");
}

/**
 * Resolve a sandbox grep/find path against the guest cwd. `~` is never expanded
 * to the host home directory. `..` cannot leave the workspace mount.
 */
export function resolveSandboxToolPath(
  input: string | undefined,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): string {
  const raw = (input ?? ".").trim() || ".";
  if (isHostHomeTildePath(raw)) {
    throw new Error(`Path is outside the sandbox workspace: ${raw}`);
  }
  const resolved = isAbsolute(raw) ? resolve(raw) : resolve(localCwd, raw);
  return toGuestPath(localCwd, resolved, guestWorkspace);
}

async function detectGuestRg(
  vm: GondolinVm,
  guestWorkspace: string,
  signal?: AbortSignal,
): Promise<string | undefined> {
  const result = await awaitGuestExec(vm, ["/bin/sh", "-c", "command -v rg"], {
    cwd: guestWorkspace,
    signal,
  });
  const rgPath = result.stdout.trim().split(/\s+/)[0];
  // Gondolin array exec does not search PATH, so only use an absolute rg.
  if (result.ok && rgPath.startsWith("/")) return rgPath;
  return undefined;
}

/**
 * Guest grep ToolDefinition. Prefer guest `rg` when `command -v rg` succeeds,
 * otherwise guest `grep`. Never call createGrepToolDefinition (host rg).
 */
export function createSandboxGrepToolDefinition(
  vm: GondolinVm,
  localCwd: string,
  guestWorkspace: string = GUEST_WORKSPACE,
): ToolDefinition<typeof sandboxGrepSchema> {
  return {
    name: "grep",
    label: "grep",
    description:
      "Search file contents inside the sandbox workspace. Paths outside the workspace mount are rejected. Prefers guest rg when present, otherwise guest grep.",
    promptSnippet: "Search file contents in the sandbox workspace",
    parameters: sandboxGrepSchema,
    async execute(_toolCallId, params, signal) {
      const pattern = String(params.pattern ?? "");
      const guestPath = resolveSandboxToolPath(
        typeof params.path === "string" ? params.path : undefined,
        localCwd,
        guestWorkspace,
      );
      const ignoreCase = params.ignoreCase === true;
      const literal = params.literal === true;
      const glob = typeof params.glob === "string" ? params.glob : undefined;
      const context = typeof params.context === "number" && params.context > 0 ? params.context : 0;
      const limit = typeof params.limit === "number" && params.limit > 0 ? params.limit : 100;

      const rgPath = await detectGuestRg(vm, guestWorkspace, signal);
      // Gondolin array exec is execve-style and does not search PATH.
      const args = rgPath
        ? [rgPath, "--line-number", "--color=never", "--hidden"]
        : ["/bin/grep", "-n", "-H", "-R"];
      if (ignoreCase) args.push(rgPath ? "--ignore-case" : "-i");
      if (literal) args.push(rgPath ? "--fixed-strings" : "-F");
      if (glob) {
        if (rgPath) args.push("--glob", glob);
        else args.push(`--include=${glob}`);
      }
      if (context > 0) args.push(rgPath ? "--context" : "-C", String(context));
      args.push("--", pattern, guestPath);

      const result = await awaitGuestExec(vm, args, { cwd: guestWorkspace, signal });
      if (!result.ok && result.exitCode !== 1) {
        throw new Error(result.stdout.trim() || `Search exited with code ${result.exitCode}`);
      }
      const lines = result.stdout
        .split("\n")
        .map((line) => line.replace(/\r$/, ""))
        .filter((line) => line.length > 0)
        .slice(0, limit);
      if (lines.length === 0) {
        return { content: [{ type: "text", text: "No matches found" }], details: undefined };
      }
      return { content: [{ type: "text", text: lines.join("\n") }], details: undefined };
    },
  };
}

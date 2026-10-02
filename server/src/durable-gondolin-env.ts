import { randomUUID } from "node:crypto";
import { posix } from "node:path";
import { StringDecoder } from "node:string_decoder";
import type { Context } from "@earendil-works/chord";
import {
  ExecutionError,
  FileError,
  err,
  ok,
  toError,
  type ExecutionEnv,
  type Result,
  type FileInfo,
  type ShellExecOptions,
  type ShellExecResult,
  type TextLineReader,
  type TextLine,
} from "@earendil-works/pi-durable/env";
import {
  resolveSandboxToolPath,
  type GondolinVm,
  type GondolinExecResult,
} from "./gondolin-ops.js";

// The trusted wrapper emits identity before allowing user code to run. The
// host ACK is on this exec's stdin, not a same-user, guest-writable pid file.
const EXEC_HANDSHAKE = [
  'shell="$1"; command="$2"',
  "IFS= read -r stat < /proc/$$/stat || exit 125",
  // eslint-disable-next-line no-template-curly-in-string -- Guest shell parameter expansion.
  "fields=${stat##*) }; set -- $fields; shift 19",
  'printf "%s %s\\n" "$$" "$1"',
  "IFS= read -r ack || exit 125",
  '[ "$ack" = go ] || exit 125',
  'exec "$shell" -lc "$command"',
].join("\n");

const KILL_GROUP = [
  'p="$1"; start="$2"',
  // Repeat the host validation at the signaling boundary. Leading zeros,
  // signs and p <= 1 must never reach kill's negative-pid syntax.
  'case "$p" in ""|0*|*[!0-9]*) exit 1;; esac',
  '[ "$p" -gt 1 ] && [ "$p" -le 2147483647 ] 2>/dev/null || exit 1',
  'case "$start" in ""|0*|*[!0-9]*) exit 1;; esac',
  // Shell kill reports ESRCH in the C locale; no other failure is success.
  "export LC_ALL=C",
  'gone() { case "$1" in *"No such process"*) exit 0;; *) printf "%s\\n" "$1" >&2; exit 1;; esac; }',
  'if ! IFS= read -r stat < "/proc/$p/stat"; then',
  // A gone leader can leave children in the captured group. A recycled
  // leader would have /proc/<pid>/stat and take the lifetime-check branch.
  '  if failure=$(kill -0 -"$p" 2>&1); then',
  '    failure=$(kill -KILL -"$p" 2>&1) && exit 0',
  "  fi",
  '  gone "$failure"',
  "fi",
  // eslint-disable-next-line no-template-curly-in-string -- Guest shell parameter expansion.
  "fields=${stat##*) }; set -- $fields",
  // The leader must still identify the original group, not a recycled pid.
  '[ "$3" = "$p" ] || exit 1',
  'shift 19; [ "$1" = "$start" ] || exit 1',
  'failure=$(kill -KILL -"$p" 2>&1) && exit 0',
  'gone "$failure"',
].join("\n");

function fileError(error: unknown, path?: string): FileError {
  if (error instanceof FileError) return error;
  const cause = toError(error);
  const message = cause.message.toLowerCase();
  const code = message.includes("abort")
    ? "aborted"
    : /enoent|no such file/.test(message)
      ? "not_found"
      : /eacces|eperm|permission denied|outside the sandbox/.test(message)
        ? "permission_denied"
        : /enotdir|not a directory/.test(message)
          ? "not_directory"
          : /eisdir|is a directory/.test(message)
            ? "is_directory"
            : "unknown";
  return new FileError(code, cause.message, path, cause);
}

/** One conversation's capabilities over the manager-owned, shared workspace VM. */
export class GondolinExecutionEnv implements ExecutionEnv {
  readonly id: string;
  cwd: string;
  private readonly inflight = new Set<{ abort: AbortController; done: Promise<unknown> }>();
  private cancellationFailure?: ExecutionError;

  constructor(
    readonly vm: GondolinVm,
    readonly workspaceId: string,
    readonly workspaceRoot: string,
  ) {
    // Shared file namespace also shares Durable's per-file mutation queues.
    this.id = `gondolin:${workspaceId}:${vm.id ?? workspaceRoot}`;
    this.cwd = workspaceRoot;
  }

  private path(path: string): string {
    const resolved = path.startsWith("~") ? path : posix.resolve(this.cwd, path);
    return resolveSandboxToolPath(resolved, this.workspaceRoot, this.workspaceRoot);
  }

  /** SDK search operations use this facade so Stop also kills guest find/grep. */
  cancellableVm(context: Context): GondolinVm {
    return {
      fs: this.vm.fs,
      shellPath: this.vm.shellPath,
      exec: (args, options) => {
        const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;
        const command = typeof args === "string" ? args : `exec ${args.map(quote).join(" ")}`;
        let output = "";
        const done = this.exec(
          command,
          {
            cwd: options?.cwd,
            env: options?.env,
            onOutput: (text) => {
              output += text;
            },
          },
          context,
        ).then((result) => {
          if (!result.ok) throw result.error;
          return {
            exitCode: result.value.exitCode,
            ok: result.value.exitCode === 0,
            stdout: output,
            stdoutBuffer: Buffer.from(output),
          };
        });
        void done.catch(() => undefined);
        return Object.assign(done, {
          async *output() {
            const result = await done;
            yield { stream: "stdout" as const, data: result.stdoutBuffer };
          },
          write() {
            throw new Error("Durable search processes do not support stdin");
          },
          end() {
            throw new Error("Durable search processes do not support stdin");
          },
        });
      },
    };
  }

  private async file<T>(
    path: string,
    context: Context,
    operation: (path: string) => Promise<T>,
  ): Promise<Result<T, FileError>> {
    try {
      if (context.abortSignal?.aborted) throw new FileError("aborted", "aborted", path);
      return ok(await operation(this.path(path)));
    } catch (error) {
      return err(fileError(error, path));
    }
  }

  absolutePath(path: string, context: Context): Promise<Result<string, FileError>> {
    return this.file(path, context, async (resolved) => resolved);
  }
  joinPath(parts: string[], context: Context): Promise<Result<string, FileError>> {
    return this.absolutePath(posix.join(...parts), context);
  }
  readBinaryFile(path: string, context: Context): Promise<Result<Uint8Array, FileError>> {
    return this.file(path, context, (resolved) =>
      this.vm.fs.readFile(resolved, { signal: context.abortSignal }),
    );
  }
  async readTextFile(path: string, context: Context): Promise<Result<string, FileError>> {
    const result = await this.readBinaryFile(path, context);
    return result.ok ? ok(Buffer.from(result.value).toString("utf8")) : result;
  }
  async openTextLineReader(
    path: string,
    context: Context,
  ): Promise<Result<TextLineReader, FileError>> {
    const result = await this.readTextFile(path, context);
    if (!result.ok) return result;
    const parts = result.value.split("\n");
    const lines: TextLine[] = parts.slice(0, -1).map((text) => ({ text, terminated: true }));
    const last = parts.at(-1);
    if (last) lines.push({ text: last, terminated: false });
    let index = 0;
    let closed = false;
    return ok({
      readLine: async (ctx) =>
        ctx.abortSignal?.aborted
          ? err(new FileError("aborted", "aborted", path))
          : closed
            ? err(new FileError("invalid", "Text line reader is closed", path))
            : ok(lines[index++]),
      close: async () => {
        closed = true;
      },
    });
  }
  async readTextLines(
    path: string,
    options: { maxLines?: number } | undefined,
    context: Context,
  ): Promise<Result<string[], FileError>> {
    const reader = await this.openTextLineReader(path, context);
    if (!reader.ok) return reader;
    const lines: string[] = [];
    try {
      while (options?.maxLines === undefined || lines.length < options.maxLines) {
        const line = await reader.value.readLine(context);
        if (!line.ok) return line;
        if (line.value === undefined) break;
        lines.push(line.value.text);
      }
      return ok(lines);
    } finally {
      await reader.value.close(context);
    }
  }
  writeFile(
    path: string,
    content: string | Uint8Array,
    context: Context,
  ): Promise<Result<void, FileError>> {
    return this.file(path, context, async (resolved) => {
      await this.vm.fs.mkdir(posix.dirname(resolved), {
        recursive: true,
        signal: context.abortSignal,
      });
      if (context.abortSignal?.aborted) throw new FileError("aborted", "aborted", path);
      await this.vm.fs.writeFile(
        resolved,
        typeof content === "string" ? content : Buffer.from(content),
        { signal: context.abortSignal },
      );
    });
  }
  async appendFile(
    path: string,
    content: string | Uint8Array,
    context: Context,
  ): Promise<Result<void, FileError>> {
    const existing = await this.readBinaryFile(path, context);
    if (!existing.ok && existing.error.code !== "not_found") return existing;
    return this.writeFile(
      path,
      Buffer.concat([
        existing.ok ? Buffer.from(existing.value) : Buffer.alloc(0),
        Buffer.from(content),
      ]),
      context,
    );
  }
  async truncateFile(
    path: string,
    size: number,
    context: Context,
  ): Promise<Result<void, FileError>> {
    if (!Number.isSafeInteger(size) || size < 0)
      return err(new FileError("invalid", "Invalid file size", path));
    const existing = await this.readBinaryFile(path, context);
    if (!existing.ok) return existing;
    const bytes = Buffer.alloc(size);
    bytes.set(existing.value.subarray(0, size));
    return this.writeFile(path, bytes, context);
  }
  flushFile(path: string, context: Context): Promise<Result<void, FileError>> {
    // VmFs has no fsync: completed writeFile is its persistence boundary.
    return this.file(path, context, (resolved) =>
      this.vm.fs.access(resolved, { signal: context.abortSignal }),
    );
  }
  renameFile(
    source: string,
    destination: string,
    context: Context,
  ): Promise<Result<void, FileError>> {
    return this.file(source, context, async (resolved) => {
      if (!this.vm.fs.rename) throw new FileError("not_supported", "VM filesystem has no rename");
      await this.vm.fs.rename(resolved, this.path(destination), { signal: context.abortSignal });
    });
  }
  fileInfo(path: string, context: Context): Promise<Result<FileInfo, FileError>> {
    return this.file(path, context, async (resolved) => {
      if (!this.vm.fs.stat) throw new FileError("not_supported", "VM filesystem has no stat");
      const stat = await this.vm.fs.stat(resolved, { signal: context.abortSignal });
      const kind = stat.isSymbolicLink?.()
        ? "symlink"
        : stat.isDirectory()
          ? "directory"
          : stat.isFile?.()
            ? "file"
            : undefined;
      if (!kind) throw new FileError("invalid", "Unsupported file type", resolved);
      return {
        name: posix.basename(resolved),
        path: resolved,
        kind,
        size: stat.size ?? 0,
        mtimeMs: stat.mtimeMs ?? 0,
      };
    });
  }
  listDir(path: string, context: Context): Promise<Result<FileInfo[], FileError>> {
    return this.file(path, context, async (resolved) => {
      if (!this.vm.fs.listDir) throw new FileError("not_supported", "VM filesystem has no listDir");
      const names = await this.vm.fs.listDir(resolved, { signal: context.abortSignal });
      const files: FileInfo[] = [];
      for (const name of names) {
        const info = await this.fileInfo(posix.join(resolved, name), context);
        if (!info.ok) throw info.error;
        files.push(info.value);
      }
      return files;
    });
  }
  canonicalPath(path: string, context: Context): Promise<Result<string, FileError>> {
    return this.file(path, context, async (resolved) => {
      // VmFs has no realpath API. Resolve in the guest, then check confinement
      // before access: a symlink outside the VFS mount can look missing to VmFs.
      const result = await this.vm.exec(
        [
          "/bin/sh",
          "-c",
          'p=$(readlink -f -- "$1") || exit 1; printf "%s\\0" "$p"',
          "oppi-realpath",
          resolved,
        ],
        { signal: context.abortSignal, stdout: "buffer", stderr: "buffer" },
      );
      if (!result.ok) {
        // Preserve typed missing errors for Durable's canonical-parent create key.
        await this.vm.fs.access(resolved, { signal: context.abortSignal });
        throw new FileError("unknown", "Guest realpath failed", resolved);
      }
      const canonical = result.stdoutBuffer.toString("utf8");
      if (
        !canonical.endsWith("\0") ||
        !canonical.startsWith("/") ||
        canonical.slice(0, -1).includes("\0")
      )
        throw new FileError("invalid", "Invalid guest realpath", resolved);
      const confined = this.path(canonical.slice(0, -1));
      await this.vm.fs.access(resolved, { signal: context.abortSignal });
      return confined;
    });
  }
  async exists(path: string, context: Context): Promise<Result<boolean, FileError>> {
    const info = await this.fileInfo(path, context);
    return info.ok ? ok(true) : info.error.code === "not_found" ? ok(false) : info;
  }
  createDir(
    path: string,
    options: { recursive?: boolean } | undefined,
    context: Context,
  ): Promise<Result<void, FileError>> {
    return this.file(path, context, (resolved) =>
      this.vm.fs.mkdir(resolved, {
        recursive: options?.recursive ?? true,
        signal: context.abortSignal,
      }),
    );
  }
  remove(
    path: string,
    options: { recursive?: boolean; force?: boolean } | undefined,
    context: Context,
  ): Promise<Result<void, FileError>> {
    return this.file(path, context, async (resolved) => {
      if (!this.vm.fs.deleteFile)
        throw new FileError("not_supported", "VM filesystem has no deleteFile");
      await this.vm.fs.deleteFile(resolved, { ...options, signal: context.abortSignal });
    });
  }
  async createTempDir(
    prefix: string | undefined,
    context: Context,
  ): Promise<Result<string, FileError>> {
    const path = posix.join(
      this.workspaceRoot,
      `.oppi-${posix.basename(prefix ?? "tmp-")}${randomUUID()}`,
    );
    const created = await this.createDir(path, { recursive: true }, context);
    return created.ok ? ok(path) : created;
  }
  async createTempFile(
    options: { prefix?: string; suffix?: string } | undefined,
    context: Context,
  ): Promise<Result<string, FileError>> {
    const path = posix.join(
      this.workspaceRoot,
      `.oppi-${posix.basename(options?.prefix ?? "tmp-")}${randomUUID()}${posix.basename(options?.suffix ?? "")}`,
    );
    const written = await this.writeFile(path, "", context);
    return written.ok ? ok(path) : written;
  }

  exec(
    command: string,
    options: ShellExecOptions | undefined,
    context: Context,
  ): Promise<Result<ShellExecResult, ExecutionError>> {
    const abort = new AbortController();
    const done = this.run(command, options, context, abort);
    const entry = { abort, done };
    this.inflight.add(entry);
    void done.finally(() => this.inflight.delete(entry)).catch(() => undefined);
    return done;
  }

  private async run(
    command: string,
    options: ShellExecOptions | undefined,
    context: Context,
    controller: AbortController,
  ): Promise<Result<ShellExecResult, ExecutionError>> {
    if (context.abortSignal?.aborted) return err(new ExecutionError("aborted", "aborted"));
    const timeout = options?.timeout;
    if (
      timeout !== undefined &&
      (!Number.isFinite(timeout) || timeout <= 0 || timeout * 1000 > 2147483647)
    )
      return err(new ExecutionError("timeout", "Invalid timeout"));
    const signal = AbortSignal.any([
      controller.signal,
      ...(context.abortSignal ? [context.abortSignal] : []),
    ]);
    let identity: { pgid: string; starttime: string } | undefined;
    let handshake = Buffer.alloc(0);
    let kill: Promise<GondolinExecResult> | undefined;
    const killGroup = (): void => {
      // Do NOT send the cancelled signal to this second exec. Gondolin abort
      // only rejects a host promise; it never signals the guest process.
      // Abort before identity is captured withholds the ACK. When the header
      // arrives below we kill the trusted wrapper without ever launching code.
      const target = identity;
      if (!target) return;
      kill ??= Promise.resolve().then(() =>
        this.vm.exec(["/bin/sh", "-c", KILL_GROUP, "oppi-kill", target.pgid, target.starttime], {
          stdout: "buffer",
          stderr: "buffer",
        }),
      );
      void kill.catch(() => undefined);
    };
    signal.addEventListener("abort", killGroup, { once: true });
    let timedOut = false;
    const timer =
      timeout === undefined
        ? undefined
        : setTimeout(() => {
            timedOut = true;
            controller.abort();
          }, timeout * 1000);
    let spillPath: string | undefined;
    const prefix: Buffer[] = [];
    let bytes = 0;
    let newlines = 0;
    let lastByte: number | undefined;
    const decoder = new StringDecoder("utf8");
    try {
      const cwd = this.path(options?.cwd ?? this.cwd);
      // setsid is required. Capture both identity fields on the exec stream
      // before ACK: the workload cannot replace them after it starts.
      const proc = this.vm.exec(
        [
          "/usr/bin/setsid",
          "/bin/sh",
          "-c",
          EXEC_HANDSHAKE,
          "oppi-exec",
          this.vm.shellPath ?? "/bin/sh",
          command,
        ],
        {
          cwd,
          env: options?.env,
          stdin: true,
          stdout: "pipe",
          stderr: "pipe",
          // Never forward process.env, even when inheritEnv is true.
        },
      );
      const resultPromise = Promise.resolve(proc);
      void resultPromise.catch(() => undefined);
      if (signal.aborted) killGroup();
      for await (const output of proc.output()) {
        let chunk = output;
        if (!identity && chunk.stream === "stdout") {
          handshake = Buffer.concat([handshake, chunk.data]);
          const newline = handshake.indexOf(10);
          if (newline < 0 && handshake.length <= 128) continue;
          const header = handshake.subarray(0, newline).toString("utf8");
          const match = /^([1-9][0-9]*) ([1-9][0-9]*)$/.exec(header);
          if (
            newline < 0 ||
            newline > 128 ||
            !match ||
            !Number.isSafeInteger(Number(match[1])) ||
            Number(match[1]) <= 1 ||
            Number(match[1]) > 2147483647
          ) {
            proc.end();
            throw new ExecutionError("unknown", "Invalid guest process identity handshake");
          }
          identity = { pgid: match[1], starttime: match[2] };
          if (signal.aborted) killGroup();
          else proc.write("go\n");
          proc.end();
          chunk = { ...chunk, data: handshake.subarray(newline + 1) };
          handshake = Buffer.alloc(0);
          if (!chunk.data.length) continue;
        }
        if (signal.aborted) continue;
        try {
          options?.onOutput?.(decoder.write(chunk.data), context);
        } catch (error) {
          throw new ExecutionError("callback_error", toError(error).message, toError(error));
        }
        if (options?.spill) {
          bytes += chunk.data.length;
          for (const byte of chunk.data) if (byte === 10) newlines++;
          lastByte = chunk.data.at(-1) ?? lastByte;
          const over =
            bytes > options.spill.afterBytes ||
            newlines + (lastByte === 10 ? 0 : 1) > options.spill.afterLines;
          if (!spillPath && over) {
            const temp = await this.createTempFile({ prefix: "output-", suffix: ".log" }, context);
            if (!temp.ok) throw temp.error;
            spillPath = temp.value;
            const written = await this.writeFile(spillPath, Buffer.concat(prefix), context);
            if (!written.ok) throw written.error;
            prefix.length = 0;
          }
          if (spillPath) {
            const appended = await this.appendFile(spillPath, chunk.data, context);
            if (!appended.ok) throw appended.error;
          } else prefix.push(chunk.data);
        }
      }
      const result = await resultPromise;
      if (!identity)
        throw new ExecutionError("unknown", "Guest process identity handshake missing");
      if (signal.aborted)
        throw new ExecutionError(
          timedOut ? "timeout" : "aborted",
          timedOut ? "Command timed out" : "aborted",
        );
      options?.onOutput?.(decoder.end(), context);
      return ok({ exitCode: result.exitCode, ...(spillPath ? { spillPath } : {}) });
    } catch (error) {
      // A callback/fs failure must also kill its still-running guest command.
      controller.abort();
      const failure =
        signal.aborted && (context.abortSignal?.aborted || timedOut)
          ? new ExecutionError(
              timedOut ? "timeout" : "aborted",
              timedOut ? "Command timed out" : "aborted",
            )
          : error instanceof ExecutionError
            ? error
            : new ExecutionError("unknown", toError(error).message, toError(error));
      if (spillPath) failure.spillPath = spillPath;
      return err(failure);
    } finally {
      if (timer) clearTimeout(timer);
      signal.removeEventListener("abort", killGroup);
      await this.finishCall(kill);
    }
  }

  private async finishCall(kill: Promise<GondolinExecResult> | undefined): Promise<void> {
    if (kill) {
      try {
        if (!(await kill).ok) throw new Error("Guest kill command failed");
      } catch (error) {
        // Durable can settle an aborted tool even after its invocation rejects.
        // Retain failure so Oppi's independent Stop boundary cannot confirm it.
        this.cancellationFailure = new ExecutionError(
          "unknown",
          "Failed to kill durable sandbox guest work",
          toError(error),
        );
        throw this.cancellationFailure;
      }
    }
  }

  async cleanup(_context: Context): Promise<void> {
    const calls = [...this.inflight];
    for (const call of calls) call.abort.abort();
    await Promise.all(calls.map((call) => call.done));
    if (this.cancellationFailure) throw this.cancellationFailure;
    // Never close a shared VM here. GondolinManager owns its lifetime.
  }
}

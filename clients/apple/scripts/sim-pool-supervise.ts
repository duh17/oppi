import {
  spawn,
  spawnSync,
  type ChildProcess,
  type StdioOptions,
} from "node:child_process";
import { once } from "node:events";

export type Supervised = {
  pid: number;
  pgid: number;
  child: ChildProcess;
  exit: Promise<WaitResult>;
  streamsClosed: Promise<void>;
  stdout: string;
  stderr: string;
  retired: boolean;
  terminal?: CompletionResult;
  completion?: Promise<CompletionResult>;
  stopRequested?: boolean;
  interruptWait?: () => void;
};

export type SpawnOwnedResult =
  | { ok: true; owned: Supervised }
  | { ok: false; reason: string; stop?: StopResult };

export type WaitResult = {
  code: number | null;
  signal: NodeJS.Signals | null;
};

export type StopResult = {
  quiescent: boolean;
  note?: string;
};

export type CompletionResult = {
  wait: WaitResult;
  stop: StopResult;
  stdout: string;
  stderr: string;
  timedOut?: boolean;
};

export type CompleteOptions = {
  timeoutMs?: number;
  streamCloseMs?: number;
  firstSignal?: NodeJS.Signals;
  termMs?: number;
  killMs?: number;
  stopFirst?: boolean;
};

export type GroupQuery =
  | { ok: true; pids: number[] }
  | { ok: false; reason: string };

function pgrepBin(): string {
  return process.env.OPPI_SIM_POOL_PGREP ?? "/usr/bin/pgrep";
}

export function queryProcessGroup(pgid: number): GroupQuery {
  const result = spawnSync(pgrepBin(), ["-g", String(pgid)], { encoding: "utf8" });
  if (result.error) {
    return { ok: false, reason: `pgrep spawn failed: ${result.error.message}` };
  }
  if (result.status === 1) {
    return { ok: true, pids: [] };
  }
  if (result.status !== 0) {
    return { ok: false, reason: `pgrep status ${result.status ?? "null"}` };
  }
  const pids = result.stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => Number(line))
    .filter((pid) => Number.isInteger(pid) && pid > 0);
  return { ok: true, pids };
}

/** @deprecated use queryProcessGroup; errors throw instead of pretending the group is empty */
export function processGroupPids(pgid: number): number[] {
  const query = queryProcessGroup(pgid);
  if (!query.ok) {
    throw new Error(query.reason);
  }
  return query.pids;
}

function signalGroup(owned: Supervised, signal: NodeJS.Signals): void {
  if (owned.retired) {
    return;
  }
  try {
    process.kill(-owned.pgid, signal);
  } catch {
    // Group may already be empty.
  }
}

function waitMs(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitWithTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

async function waitStreamsClosed(owned: Supervised, timeoutMs: number): Promise<{ closed: boolean }> {
  try {
    await waitWithTimeout(owned.streamsClosed, timeoutMs, `streams still open pid=${owned.pid}`);
    return { closed: true };
  } catch {
    return { closed: false };
  }
}

export function waitExitStatus(result: WaitResult): number {
  if (typeof result.code === "number") {
    return result.code;
  }
  switch (result.signal) {
    case "SIGINT":
      return 130;
    case "SIGTERM":
      return 143;
    case "SIGKILL":
      return 137;
    default:
      return 1;
  }
}

function alreadyExited(child: ChildProcess): boolean {
  return child.exitCode != null || child.signalCode != null;
}

function currentWait(child: ChildProcess): WaitResult {
  return { code: child.exitCode, signal: child.signalCode };
}

function attachOwned(child: ChildProcess): Supervised {
  const owned: Supervised = {
    pid: child.pid ?? 0,
    pgid: child.pid ?? 0,
    child,
    exit: alreadyExited(child)
      ? Promise.resolve(currentWait(child))
      : new Promise((resolve) => {
          child.once("exit", (code, signal) => resolve({ code, signal }));
        }),
    streamsClosed: Promise.resolve(),
    stdout: "",
    stderr: "",
    retired: false,
  };
  const closers: Promise<void>[] = [];
  if (child.stdout) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      owned.stdout += chunk;
    });
    closers.push(once(child.stdout, "close").then(() => undefined));
  }
  if (child.stderr) {
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      owned.stderr += chunk;
    });
    closers.push(once(child.stderr, "close").then(() => undefined));
  }
  owned.streamsClosed = closers.length === 0 ? Promise.resolve() : Promise.all(closers).then(() => undefined);
  return owned;
}

const GATE_SCRIPT = `read go || exit 1
[ "$go" = "go" ] || exit 1
exec "$0" "$@"`;

function gatedStdio(stdio?: StdioOptions): StdioOptions {
  if (stdio == null) {
    return ["pipe", "pipe", "pipe"];
  }
  if (typeof stdio === "string") {
    if (stdio === "ignore" || stdio === "inherit" || stdio === "pipe") {
      return ["pipe", stdio, stdio];
    }
    return ["pipe", "pipe", "pipe"];
  }
  if (Array.isArray(stdio)) {
    return ["pipe", stdio[1] ?? "pipe", stdio[2] ?? "pipe"];
  }
  return ["pipe", "pipe", "pipe"];
}

export type GatedSpawn = {
  owned: Supervised;
  authorize: () => void;
  abort: () => Promise<StopResult>;
};

export type SpawnGatedResult =
  | { ok: true; gated: GatedSpawn }
  | { ok: false; reason: string; stop?: StopResult };

export function spawnGateWaiting(
  command: string,
  args: string[],
  options: {
    cwd?: string;
    env?: NodeJS.ProcessEnv;
    stdio?: StdioOptions;
  } = {},
): Promise<SpawnGatedResult> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: SpawnGatedResult) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(result);
    };
    let child: ChildProcess;
    try {
      child = spawn("/bin/sh", ["-c", GATE_SCRIPT, command, ...args], {
        cwd: options.cwd,
        env: options.env,
        stdio: gatedStdio(options.stdio),
        detached: true,
      });
    } catch (error) {
      finish({ ok: false, reason: `spawn ${command} failed: ${error}` });
      return;
    }
    const owned = attachOwned(child);
    child.once("error", (error) => {
      finish({ ok: false, reason: `spawn ${command} failed: ${error}` });
    });
    child.once("spawn", () => {
      if (child.pid == null) {
        finish({ ok: false, reason: `spawn ${command}: no pid` });
        return;
      }
      owned.pid = child.pid;
      owned.pgid = child.pid;
      let authorized = false;
      finish({
        ok: true,
        gated: {
          owned,
          authorize: () => {
            if (authorized || owned.retired) {
              return;
            }
            authorized = true;
            try {
              child.stdin?.write("go\n");
            } catch {
              // stdin may already be closed
            }
            try {
              child.stdin?.end();
            } catch {
              // already ended
            }
          },
          abort: async () => {
            try {
              child.stdin?.end();
            } catch {
              // already ended
            }
            return stopOwned(owned, { firstSignal: "SIGKILL" });
          },
        },
      });
    });
  });
}

export function spawnOwned(
  command: string,
  args: string[],
  options: {
    cwd?: string;
    env?: NodeJS.ProcessEnv;
    stdio?: StdioOptions;
    onSpawned?: (owned: Supervised) => void;
  } = {},
): Promise<SpawnOwnedResult> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: SpawnOwnedResult) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(result);
    };
    let child: ChildProcess;
    try {
      child = spawn(command, args, {
        cwd: options.cwd,
        env: options.env,
        stdio: options.stdio ?? ["ignore", "pipe", "pipe"],
        detached: true,
      });
    } catch (error) {
      finish({ ok: false, reason: `spawn ${command} failed: ${error}` });
      return;
    }
    const owned = attachOwned(child);
    child.once("error", (error) => {
      finish({ ok: false, reason: `spawn ${command} failed: ${error}` });
    });
    child.once("spawn", () => {
      if (child.pid == null) {
        finish({ ok: false, reason: `spawn ${command}: no pid` });
        return;
      }
      owned.pid = child.pid;
      owned.pgid = child.pid;
      try {
        options.onSpawned?.(owned);
      } catch {
        // Child is already running; publication still tracks it.
      }
      finish({ ok: true, owned });
    });
  });
}

export function waitExit(owned: Supervised, timeoutMs?: number): Promise<WaitResult> {
  if (timeoutMs == null) {
    return owned.exit;
  }
  return waitWithTimeout(
    owned.exit,
    timeoutMs,
    `waitExit timed out after ${timeoutMs}ms pid=${owned.pid}`,
  );
}

export function waitOwned(
  owned: Supervised,
  options: { timeoutMs?: number } = {},
): Promise<WaitResult> {
  const timeoutMs = options.timeoutMs ?? 3_600_000;
  return Promise.all([
    waitExit(owned, timeoutMs),
    waitWithTimeout(
      owned.streamsClosed,
      timeoutMs,
      `waitOwned timed out after ${timeoutMs}ms pid=${owned.pid}`,
    ),
  ]).then(([wait]) => wait);
}

export function combineStop(stop: StopResult, streamsClosed: boolean, extra?: string): StopResult {
  if (stop.quiescent && !extra) {
    return stop;
  }
  const notes = [stop.note, streamsClosed ? undefined : "stdout/stderr did not close", extra].filter(
    (note): note is string => Boolean(note),
  );
  return {
    quiescent: false,
    note: notes.length > 0 ? notes.join("; ") : undefined,
  };
}

function unprovenStop(owned: Supervised, note?: string): StopResult {
  return {
    quiescent: false,
    note: note ?? `process group ${owned.pgid} retired without a completion result`,
  };
}

export async function stopOwned(
  owned: Supervised,
  options: {
    firstSignal?: NodeJS.Signals;
    termMs?: number;
    killMs?: number;
  } = {},
): Promise<StopResult> {
  if (owned.terminal) {
    return owned.terminal.stop;
  }
  if (owned.retired) {
    return unprovenStop(owned);
  }
  const firstSignal = options.firstSignal ?? "SIGTERM";
  const termMs = options.termMs ?? 2000;
  const killMs = options.killMs ?? 1000;
  const initial = queryProcessGroup(owned.pgid);
  if (!initial.ok) {
    signalGroup(owned, firstSignal);
    signalGroup(owned, "SIGKILL");
    return { quiescent: false, note: initial.reason };
  }
  if (initial.pids.length === 0) {
    return { quiescent: true };
  }
  signalGroup(owned, firstSignal);
  const termDeadline = Date.now() + termMs;
  while (Date.now() < termDeadline) {
    const query = queryProcessGroup(owned.pgid);
    if (!query.ok) {
      signalGroup(owned, "SIGKILL");
      return { quiescent: false, note: query.reason };
    }
    if (query.pids.length === 0) {
      return { quiescent: true };
    }
    await waitMs(40);
  }
  signalGroup(owned, "SIGKILL");
  const killDeadline = Date.now() + killMs;
  while (Date.now() < killDeadline) {
    const query = queryProcessGroup(owned.pgid);
    if (!query.ok) {
      return { quiescent: false, note: query.reason };
    }
    if (query.pids.length === 0) {
      return { quiescent: true };
    }
    await waitMs(40);
  }
  const remaining = queryProcessGroup(owned.pgid);
  if (!remaining.ok) {
    return { quiescent: false, note: remaining.reason };
  }
  if (remaining.pids.length === 0) {
    return { quiescent: true };
  }
  return {
    quiescent: false,
    note: `process group ${owned.pgid} still has pids ${remaining.pids.join(",")}`,
  };
}

async function runCompleteOwned(
  owned: Supervised,
  options: CompleteOptions,
): Promise<CompletionResult> {
  const timeoutMs = options.timeoutMs ?? 3_600_000;
  const streamCloseMs = options.streamCloseMs ?? 2000;
  const snapshot = (): Pick<CompletionResult, "stdout" | "stderr" | "wait"> => ({
    wait: currentWait(owned.child),
    stdout: owned.stdout,
    stderr: owned.stderr,
  });
  let interrupted = false;
  let resolveInterrupt = (): void => {};
  const interruptWait = (): void => {
    interrupted = true;
    resolveInterrupt();
  };
  const interruptPromise = new Promise<void>((resolve) => {
    resolveInterrupt = resolve;
    owned.interruptWait = interruptWait;
  });
  if (owned.stopRequested) {
    interruptWait();
  }

  const finishAfterStop = async (timedOut: boolean): Promise<CompletionResult> => {
    const stop = await stopOwned(owned, options);
    let waitTimedOut = timedOut;
    try {
      await waitExit(owned, streamCloseMs);
    } catch {
      waitTimedOut = true;
    }
    const streams = await waitStreamsClosed(owned, streamCloseMs);
    return {
      ...snapshot(),
      stop: combineStop(stop, streams.closed),
      timedOut: waitTimedOut,
    };
  };

  if (options.stopFirst || owned.stopRequested) {
    return finishAfterStop(false);
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeoutPromise = new Promise<"timeout">((resolve) => {
    timer = setTimeout(() => resolve("timeout"), timeoutMs);
  });
  try {
    const winner = await Promise.race([
      owned.exit.then(() => "exit" as const),
      interruptPromise.then(() => "interrupt" as const),
      timeoutPromise,
    ]);
    if (winner === "exit") {
      const stop = await stopOwned(owned, options);
      const streams = await waitStreamsClosed(owned, streamCloseMs);
      return {
        wait: currentWait(owned.child),
        stop: combineStop(stop, streams.closed),
        stdout: owned.stdout,
        stderr: owned.stderr,
      };
    }
    return finishAfterStop(winner === "timeout" && !interrupted);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

export async function completeOwned(
  owned: Supervised,
  options: CompleteOptions = {},
): Promise<CompletionResult> {
  if (owned.terminal) {
    return owned.terminal;
  }
  if (owned.completion) {
    if (options.stopFirst) {
      owned.stopRequested = true;
      owned.interruptWait?.();
    }
    return owned.completion;
  }
  if (owned.retired) {
    const failed: CompletionResult = {
      wait: currentWait(owned.child),
      stdout: owned.stdout,
      stderr: owned.stderr,
      stop: unprovenStop(owned),
    };
    owned.terminal = failed;
    return failed;
  }
  owned.completion = runCompleteOwned(owned, options).then((result) => {
    owned.terminal = result;
    owned.retired = true;
    return result;
  });
  return owned.completion;
}

export class CommandSession {
  private readonly children: Supervised[] = [];
  onBeforeSpawn?: () => void;
  onSpawned?: (owned: Supervised) => void;
  private cancelSignal: "INT" | "TERM" | null = null;
  private handlersInstalled = false;
  private sessionRetired = false;
  private stopPromise: Promise<StopResult> | null = null;
  private joinedStop: StopResult = { quiescent: true };
  private readonly onSigInt = (): void => {
    this.cancel("INT");
  };
  private readonly onSigTerm = (): void => {
    this.cancel("TERM");
  };

  get canceled(): boolean {
    return this.cancelSignal != null;
  }

  installHandlers(): void {
    if (this.handlersInstalled) {
      return;
    }
    this.handlersInstalled = true;
    process.on("SIGINT", this.onSigInt);
    process.on("SIGTERM", this.onSigTerm);
  }

  removeHandlers(): void {
    if (!this.handlersInstalled) {
      return;
    }
    process.off("SIGINT", this.onSigInt);
    process.off("SIGTERM", this.onSigTerm);
    this.handlersInstalled = false;
  }

  cancel(signal: "INT" | "TERM" = "TERM"): void {
    if (this.cancelSignal) {
      return;
    }
    this.cancelSignal = signal;
    void this.stopAll({ firstSignal: "SIGTERM" });
  }

  async waitWhileIdle(ms: number): Promise<void> {
    const deadline = Date.now() + ms;
    while (!this.canceled && Date.now() < deadline) {
      await waitMs(Math.min(50, Math.max(0, deadline - Date.now())));
    }
  }

  async spawn(
    command: string,
    args: string[],
    options: {
      cwd?: string;
      env?: NodeJS.ProcessEnv;
      stdio?: StdioOptions;
    } = {},
  ): Promise<SpawnOwnedResult> {
    if (this.cancelSignal || this.sessionRetired) {
      return { ok: false, reason: `canceled before spawn ${command}` };
    }
    try {
      this.onBeforeSpawn?.();
    } catch (error) {
      return { ok: false, reason: `publication failed before spawn ${command}: ${error}` };
    }
    const spawned = await spawnGateWaiting(command, args, options);
    if (!spawned.ok) {
      return spawned;
    }
    this.children.push(spawned.gated.owned);
    try {
      this.onSpawned?.(spawned.gated.owned);
    } catch (error) {
      const stop = await spawned.gated.abort();
      this.rememberStop(stop);
      this.retire(spawned.gated.owned);
      return {
        ok: false,
        reason: `publication failed ${command}: ${error}`,
        stop,
      };
    }
    if (this.cancelSignal || this.sessionRetired) {
      const stop = await spawned.gated.abort();
      this.rememberStop(stop);
      this.retire(spawned.gated.owned);
      return {
        ok: false,
        reason: `canceled before spawn publication ${command}`,
        stop,
      };
    }
    spawned.gated.authorize();
    return { ok: true, owned: spawned.gated.owned };
  }

  retire(owned: Supervised): void {
    owned.retired = true;
    const index = this.children.indexOf(owned);
    if (index >= 0) {
      this.children.splice(index, 1);
    }
  }

  async complete(owned: Supervised, options: CompleteOptions = {}): Promise<CompletionResult> {
    const completed = await completeOwned(owned, options);
    this.rememberStop(completed.stop);
    this.retire(owned);
    return completed;
  }

  async run(
    command: string,
    args: string[],
    options: {
      cwd?: string;
      env?: NodeJS.ProcessEnv;
      stdio?: StdioOptions;
    } & CompleteOptions = {},
  ): Promise<CompletionResult & { code: number }> {
    const spawned = await this.spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: options.stdio,
    });
    if (!spawned.ok) {
      const stop = spawned.stop ?? { quiescent: true, note: spawned.reason };
      this.rememberStop(stop);
      return {
        wait: { code: 127, signal: null },
        stop,
        stdout: "",
        stderr: spawned.reason,
        code: 127,
      };
    }
    const completed = await this.complete(spawned.owned, options);
    return { ...completed, code: waitExitStatus(completed.wait) };
  }

  async stopAll(options: { firstSignal?: NodeJS.Signals } = {}): Promise<StopResult> {
    if (this.stopPromise) {
      return this.stopPromise;
    }
    const running = this.runStopAll(options);
    this.stopPromise = running;
    try {
      return await running;
    } finally {
      if (this.stopPromise === running) {
        this.stopPromise = null;
      }
    }
  }

  async dispose(): Promise<StopResult> {
    this.sessionRetired = true;
    this.removeHandlers();
    return this.stopAll();
  }

  cancelExitCode(): number {
    return this.cancelSignal === "INT" ? 130 : 143;
  }

  private rememberStop(stop: StopResult): void {
    if (stop.quiescent) {
      return;
    }
    const notes = [this.joinedStop.note, stop.note].filter((note): note is string => Boolean(note));
    this.joinedStop = {
      quiescent: false,
      note: notes.length > 0 ? notes.join("; ") : undefined,
    };
  }

  private async runStopAll(options: { firstSignal?: NodeJS.Signals }): Promise<StopResult> {
    for (const child of [...this.children].reverse()) {
      const completed = await completeOwned(child, {
        stopFirst: true,
        firstSignal: options.firstSignal ?? "SIGTERM",
      });
      this.rememberStop(completed.stop);
    }
    this.children.splice(0, this.children.length);
    return this.joinedStop;
  }
}

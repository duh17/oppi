/**
 * Pi process spawning — host and container modes.
 *
 * Factory functions that create pi child processes with the correct
 * args, env vars, and extension configuration. Extracted from
 * SessionManager to isolate the complex arg-building logic.
 */

import { execSync, spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { Session, Workspace } from "./types.js";
import { HOST_ENV, HOST_PATH } from "./host-env.js";
import type { GateServer } from "./gate.js";
import type { SandboxManager } from "./sandbox.js";
import type { AuthProxy } from "./auth-proxy.js";
import { resolveWorkspaceExtensions } from "./extension-loader.js";
import { PolicyEngine, type PathAccess } from "./policy.js";

/** Compact HH:MM:SS.mmm timestamp for log lines. */
function ts(): string {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

// ─── Extension Paths ───

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Pi-remote TCP permission gate extension (oppi-server/extensions/permission-gate/). */
export const OPPI_GATE_EXTENSION = join(__dirname, "..", "extensions", "permission-gate");

/** Host memory extension (user's pi config). */
export const HOST_MEMORY_EXTENSION = join(homedir(), ".pi", "agent", "extensions", "memory.ts");

/** Host todo extension (user's pi config). */
export const HOST_TODOS_EXTENSION = join(homedir(), ".pi", "agent", "extensions", "todos.ts");

// ─── Dependencies ───

/** Dependencies injected by SessionManager into spawn functions. */
export interface SpawnDeps {
  gate: GateServer;
  sandbox: SandboxManager;
  authProxy: AuthProxy | null;
  piExecutable: string;
  /** Callback for each RPC line from pi stdout. */
  onRpcLine: (key: string, line: string) => void;
  /** Callback when pi process exits or errors. */
  onSessionEnd: (key: string, reason: string) => void;
}

// ─── Pi Executable Resolution ───

/**
 * Resolve the pi executable path for host runtime sessions.
 *
 * tmux/systemd launches may have a minimal PATH that does not include npm
 * global bins. Prefer an explicit env override, then common install paths.
 */
export function resolvePiExecutable(): string {
  const envPath = process.env.OPPI_PI_BIN;
  if (envPath && existsSync(envPath)) {
    return envPath;
  }

  try {
    const discovered = execSync("which pi", {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, PATH: HOST_PATH },
    }).trim();
    if (discovered.length > 0) {
      return discovered;
    }
  } catch {
    // Fall through to known locations
  }

  for (const candidate of ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"]) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  // Final fallback; spawn will surface ENOENT with actionable logs.
  return "pi";
}

// ─── Host Mode ───

/**
 * Spawn pi directly on the host — no container, no sandbox.
 *
 * Pi runs as the current user with full access to the host filesystem.
 * The permission gate is the only security layer.
 */
export async function spawnPiHost(
  session: Session,
  workspace: Workspace | undefined,
  deps: SpawnDeps,
): Promise<ChildProcess> {
  const key = session.id;

  // Create gate TCP socket (extension connects via localhost)
  const gatePort = await deps.gate.createSessionSocket(
    session.id,
    workspace?.id || "",
  );

  // Configure per-session policy based on workspace settings.
  // Host sessions default to "host" (developer trust mode) unless workspace overrides.
  const presetName = workspace?.policyPreset || "host";
  const cwd = workspace?.hostMount ? workspace.hostMount.replace(/^~/, homedir()) : homedir();

  const allowedPaths: PathAccess[] = [
    // Workspace directory — full read/write
    { path: cwd, access: "readwrite" },
    // Pi agent config — read-only (for recall, memory, skills)
    { path: join(homedir(), ".pi"), access: "read" },
  ];

  // Add workspace-configured extra paths
  if (workspace?.allowedPaths) {
    for (const entry of workspace.allowedPaths) {
      const resolved = entry.path.replace(/^~/, homedir());
      allowedPaths.push({ path: resolved, access: entry.access });
    }
  }

  const allowedExecutables = workspace?.allowedExecutables;
  const policy = new PolicyEngine(presetName, { allowedPaths, allowedExecutables });
  deps.gate.setSessionPolicy(session.id, policy);
  console.log(
    `${ts()} [session:${session.id}] policy: preset=${presetName}, paths=${allowedPaths.map((p) => `${p.path}(${p.access})`).join(", ")}, execs=${allowedExecutables?.join(",") || "default"}`,
  );

  // Build pi args.
  //
  // Host-mode uses --no-extensions to suppress auto-discovery of the user's
  // local extensions (which may include a different permission-gate impl).
  // We always load the oppi-server TCP permission gate extension explicitly,
  // then load workspace extensions resolved from workspace.extensions list.
  const piArgs = ["--mode", "rpc", "--no-extensions"];

  // 1. Always load the oppi-server TCP permission gate extension
  if (existsSync(OPPI_GATE_EXTENSION)) {
    piArgs.push("--extension", OPPI_GATE_EXTENSION);
  } else {
    console.warn(
      `${ts()} [session:${session.id}] oppi-server gate extension not found at ${OPPI_GATE_EXTENSION}`,
    );
  }

  // 2. Workspace extensions
  const extensionSelection = resolveWorkspaceExtensions(workspace?.extensions);

  for (const warning of extensionSelection.warnings) {
    console.warn(`${ts()} [session:${session.id}] extension: ${warning}`);
  }

  for (const extension of extensionSelection.extensions) {
    piArgs.push("--extension", extension.path);
  }

  if (session.model) {
    const slash = session.model.indexOf("/");
    if (slash > 0) {
      piArgs.push("--provider", session.model.slice(0, slash));
      piArgs.push("--model", session.model.slice(slash + 1));
    } else {
      piArgs.push("--model", session.model);
    }
  }

  // Resume existing session if JSONL file exists.
  // This preserves conversation history across server restarts.
  if (session.piSessionFile && existsSync(session.piSessionFile)) {
    piArgs.push("--session", session.piSessionFile);
    console.log(`${ts()} [session:${session.id}] resuming from ${session.piSessionFile}`);
  } else if (session.piSessionFiles?.length) {
    // Fall back to the most recent session file
    const lastFile = session.piSessionFiles[session.piSessionFiles.length - 1];
    if (existsSync(lastFile)) {
      piArgs.push("--session", lastFile);
      console.log(`${ts()} [session:${session.id}] resuming from ${lastFile} (fallback)`);
    }
  }

  // Resolve system prompt if workspace provides one
  if (workspace?.systemPrompt) {
    const promptDir = join(homedir(), ".config", "oppi", "prompts");
    mkdirSync(promptDir, { recursive: true });
    const promptPath = join(promptDir, `${session.id}.md`);
    writeFileSync(promptPath, workspace.systemPrompt);
    piArgs.push("--append-system-prompt", promptPath);
  }

  // Working directory — already resolved above for policy config
  if (!existsSync(cwd)) {
    throw new Error(`Host workspace path not found: ${cwd}`);
  }

  console.log(
    `${ts()} [session:${session.id}] spawning pi (host mode) in ${cwd} via ${deps.piExecutable}`,
  );
  console.log(`${ts()} [session:${session.id}] pi args: ${piArgs.join(" ")}`);

  const proc = spawn(deps.piExecutable, piArgs, {
    cwd,
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...HOST_ENV,
      OPPI_SESSION: session.id,
      OPPI_GATE_HOST: "127.0.0.1",
      OPPI_GATE_PORT: String(gatePort),
    },
  });

  return setupProcHandlers(key, session, proc, deps);
}

// ─── Container Mode ───

/**
 * Spawn pi inside a container via SandboxManager.
 */
export async function spawnPiContainer(
  session: Session,
  workspaceId: string,
  userName: string | undefined,
  workspace: Workspace | undefined,
  deps: SpawnDeps,
): Promise<ChildProcess> {
  const key = session.id;

  // Register session with auth proxy (proxy validates session tokens on API requests)
  deps.authProxy?.registerSession(session.id);

  // Create gate TCP socket (extension connects from container to host-gateway)
  const gatePort = await deps.gate.createSessionSocket(session.id, workspaceId);

  // Configure per-session policy for container (permissive — container IS the boundary)
  const presetName = workspace?.policyPreset || "container";
  const containerPolicy = new PolicyEngine(presetName);
  deps.gate.setSessionPolicy(session.id, containerPolicy);
  console.log(`${ts()} [session:${session.id}] policy: preset=${presetName} (container mode)`);

  // Pass through API keys for OpenRouter and other providers
  const extraEnv: Record<string, string> = {};
  if (process.env.OPENROUTER_API_KEY) {
    extraEnv.OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY;
  }

  // Spawn pi in container
  const proc = deps.sandbox.spawnPi({
    sessionId: session.id,
    workspaceId,
    userName,
    model: session.model,
    workspace,
    gatePort,
    env: Object.keys(extraEnv).length > 0 ? extraEnv : undefined,
  });

  return setupProcHandlers(key, session, proc, deps);
}

// ─── Process Handler Setup ───

/**
 * Wire up RPC line handling, stderr logging, exit/error handlers,
 * and wait for pi to be ready. Shared by host and container modes.
 */
export async function setupProcHandlers(
  key: string,
  session: Session,
  proc: ChildProcess,
  deps: SpawnDeps,
): Promise<ChildProcess> {
  if (!proc.stdout) {
    throw new Error(`pi process for ${key} has no stdout — was it spawned with stdio: "pipe"?`);
  }

  // Single readline consumer for stdout — handles all RPC events
  const rl = createInterface({ input: proc.stdout });
  let readyResolve: (() => void) | null = null;
  let readyReject: ((err: Error) => void) | null = null;

  const settleReady = (err?: Error): void => {
    if (err) {
      const reject = readyReject;
      readyResolve = null;
      readyReject = null;
      reject?.(err);
      return;
    }

    const resolve = readyResolve;
    readyResolve = null;
    readyReject = null;
    resolve?.();
  };

  rl.on("line", (line) => {
    // If waiting for ready, any valid JSON means pi is up
    if (readyResolve || readyReject) {
      try {
        const data = JSON.parse(line);
        if (data.type) {
          settleReady();
        }
      } catch {
        // non-JSON line from pi, ignore
      }
    }
    // Always route to handler (no messages lost)
    deps.onRpcLine(key, line);
  });

  // stderr → log
  proc.stderr?.on("data", (data: Buffer) => {
    console.error(`${ts()} [pi:${session.id}] ${data.toString().trim()}`);
  });

  // Prevent EPIPE on stdin from crashing the server when the process exits
  // between a writable check and the actual write completing.
  proc.stdin?.on("error", (err) => {
    if ((err as NodeJS.ErrnoException).code === "EPIPE") return; // expected on process exit
    console.error(`${ts()} [pi:${session.id}] stdin error:`, err);
  });

  // Process exit
  proc.on("exit", (code) => {
    if (readyReject) {
      settleReady(new Error(`pi exited before ready: ${session.id} (${code ?? "null"})`));
    }
    console.log(`${ts()} [pi:${session.id}] exited (${code})`);
    deps.onSessionEnd(key, code === 0 ? "completed" : "error");
  });

  proc.on("error", (err) => {
    if (readyReject) {
      settleReady(new Error(`pi spawn error before ready: ${session.id} (${err.message})`));
    }
    console.error(`${ts()} [pi:${session.id}] spawn error:`, err);
    deps.onSessionEnd(key, "error");
  });

  // Wait for pi to be ready (probe with get_state)
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      settleReady(new Error(`Timeout waiting for pi: ${session.id}`));
    }, 30_000);

    readyResolve = () => {
      clearTimeout(timer);
      resolve();
    };
    readyReject = (err) => {
      clearTimeout(timer);
      reject(err);
    };

    // Probe readiness — safe against EPIPE if process exits before timer fires
    setTimeout(() => {
      try {
        if (!proc.killed && proc.stdin?.writable) {
          proc.stdin.write(JSON.stringify({ type: "get_state" }) + "\n");
        }
      } catch {
        // Process exited between check and write — harmless.
      }
    }, 500);
  });

  return proc;
}

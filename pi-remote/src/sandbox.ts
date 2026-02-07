/**
 * Sandbox runtime — manages Apple container lifecycle for pi sessions.
 *
 * Self-contained: builds its own image, manages container lifecycle,
 * handles mounts and environment. No external scripts.
 *
 * Container layout:
 *   /work              ← user workspace (bind mount)
 *   /home/pi/.pi       ← pi agent state (bind mount from sandbox dir)
 *   /uv-cache          ← shared uv cache (bind mount)
 *
 * Host layout per user (mounted as /home/pi/.pi/):
 *   <sandboxBaseDir>/<userId>/
 *   ├── agent/              # Pi config (auth, models, extensions)
 *   │   ├── auth.json
 *   │   ├── models.json
 *   │   └── extensions/
 *   │       └── permission-gate/
 *   └── workspace/          # User's working directory
 */

import { spawn, execSync, type ChildProcess } from "node:child_process";
import {
  existsSync, mkdirSync, cpSync, readFileSync, writeFileSync,
  rmSync, realpathSync, chmodSync, statSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

// ─── Constants ───

const IMAGE_NAME = "pi-remote:local";
const SESSION_CONTAINER_PREFIX = "pi-remote-";
const CONTAINER_PI_HOME = "/home/pi/.pi";
const CONTAINER_WORK = "/work";
const CONTAINER_UV_CACHE = "/uv-cache";
const HOST_GATEWAY = "192.168.64.1"; // Apple container → host

// Paths relative to this file
const __dirname = dirname(fileURLToPath(import.meta.url));
const SANDBOX_DIR = join(__dirname, "..", "sandbox");
const EXTENSION_SRC = join(__dirname, "..", "extensions", "permission-gate");

// ─── Types ───

export interface SandboxConfig {
  /** Base dir for all sandbox data. Default: ~/.pi-remote/sandboxes */
  sandboxBaseDir: string;
  /** Shared uv cache. Default: ~/.pi-remote/uv-cache */
  uvCacheDir: string;
  /** Container image name. Default: pi-remote:local */
  image: string;
  /** CPUs per container */
  cpus: number;
  /** Memory per container (MB) */
  memoryMb: number;
}

export interface SpawnOptions {
  sessionId: string;
  userId: string;
  model?: string;
  /** Gate TCP port on host (extension connects to host-gateway:port) */
  gatePort?: number;
  /** Extra env vars to pass to the container */
  env?: Record<string, string>;
}

const DEFAULTS: SandboxConfig = {
  sandboxBaseDir: join(homedir(), ".pi-remote", "sandboxes"),
  uvCacheDir: join(homedir(), ".pi-remote", "uv-cache"),
  image: IMAGE_NAME,
  cpus: 4,
  memoryMb: 2048,
};

// ─── SandboxManager ───

export class SandboxManager {
  readonly config: SandboxConfig;
  private running: Map<string, { containerId: string; process: ChildProcess }> = new Map();

  constructor(config?: Partial<SandboxConfig>) {
    this.config = { ...DEFAULTS, ...config };
  }

  /** Expose base dir for trace file reading. */
  getBaseDir(): string {
    return this.config.sandboxBaseDir;
  }

  // ─── Image Management ───

  imageExists(): boolean {
    try {
      const out = execSync("container image list", { encoding: "utf-8" });
      // Image list format: "pi-remote              local              digest..."
      const name = this.config.image.split(":")[0];
      const tag = this.config.image.split(":")[1] || "latest";
      // Check for name and tag on the same line
      return out.split("\n").some(line => {
        const parts = line.trim().split(/\s+/);
        return parts[0] === name && parts[1] === tag;
      });
    } catch {
      return false;
    }
  }

  async buildImage(): Promise<void> {
    const containerfile = join(SANDBOX_DIR, "Containerfile");
    if (!existsSync(containerfile)) {
      throw new Error(`Containerfile not found: ${containerfile}`);
    }

    console.log(`[sandbox] Building image ${this.config.image}...`);

    return new Promise((resolve, reject) => {
      const proc = spawn("container", [
        "build", "-t", this.config.image, "-f", containerfile, SANDBOX_DIR,
      ], { stdio: "inherit" });

      proc.on("exit", (code) => {
        if (code === 0) {
          console.log(`[sandbox] ✓ Image ${this.config.image} built`);
          resolve();
        } else {
          reject(new Error(`Image build failed (exit ${code})`));
        }
      });
      proc.on("error", reject);
    });
  }

  async ensureImage(): Promise<void> {
    if (!this.imageExists()) {
      await this.buildImage();
    }
  }

  // ─── User Sandbox Setup ───

  /**
   * Initialize sandbox directories and sync host config. Idempotent.
   *
   * Host layout (mirrors pi's expected ~/.pi/ structure):
   *   <sandboxBaseDir>/<userId>/<sessionId>/
   *   ├── agent/              # auth.json, models.json, extensions/
   *   └── workspace/          # User's working directory
   *
   * Each session gets its own pi home dir so JSONL files, workspace,
   * and agent state are isolated between sessions.
   */
  initSession(userId: string, sessionId: string): { piDir: string; workDir: string } {
    const piDir = join(this.config.sandboxBaseDir, userId, sessionId);
    const agentDir = join(piDir, "agent");
    const workDir = join(piDir, "workspace");

    for (const dir of [agentDir, workDir]) {
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
      }
    }

    // Ensure uv cache dir exists
    if (!existsSync(this.config.uvCacheDir)) {
      mkdirSync(this.config.uvCacheDir, { recursive: true });
    }

    // Sync auth.json from host pi (if newer)
    this.syncFile(
      join(homedir(), ".pi", "agent", "auth.json"),
      join(agentDir, "auth.json"),
      { mode: 0o600 },
    );

    // Sync models.json with localhost → host-gateway transform
    this.syncModels(
      join(homedir(), ".pi", "agent", "models.json"),
      join(agentDir, "models.json"),
    );

    // Sync settings.json from host pi (if present) — carries defaultModel, defaultProvider, etc.
    this.syncFile(
      join(homedir(), ".pi", "agent", "settings.json"),
      join(agentDir, "settings.json"),
    );

    // Install permission-gate extension to agent/extensions/ (pi auto-discovers from ~/.pi/agent/extensions/)
    if (existsSync(EXTENSION_SRC)) {
      const dest = join(agentDir, "extensions", "permission-gate");
      // Always re-copy to pick up changes
      if (existsSync(dest)) rmSync(dest, { recursive: true });
      mkdirSync(dirname(dest), { recursive: true });
      cpSync(EXTENSION_SRC, dest, { recursive: true });
    }

    return { piDir, workDir };
  }

  // ─── Container Lifecycle ───

  /**
   * Spawn pi inside an Apple container. Returns the ChildProcess
   * with stdin/stdout/stderr piped for RPC communication.
   */
  spawnPi(opts: SpawnOptions): ChildProcess {
    const { sessionId, userId, model, gatePort, env: extraEnv } = opts;
    const { piDir, workDir } = this.initSession(userId, sessionId);

    // Build pi args
    const piArgs = ["--mode", "rpc"];
    if (model) {
      const slash = model.indexOf("/");
      if (slash > 0) {
        piArgs.push("--provider", model.slice(0, slash));
        piArgs.push("--model", model.slice(slash + 1));
      } else {
        piArgs.push("--model", model);
      }
    }

    const containerId = `pi-remote-${sessionId}`;

    // Build container run args
    const args = [
      "run", "--rm", "-i",
      "--name", containerId,
      "-c", String(this.config.cpus),
      "-m", `${this.config.memoryMb}M`,

      // Mounts — resolve symlinks (container CLI doesn't follow them)
      "-v", `${realpath(workDir)}:${CONTAINER_WORK}`,
      "-v", `${realpath(piDir)}:${CONTAINER_PI_HOME}`,
      "-v", `${realpath(this.config.uvCacheDir)}:${CONTAINER_UV_CACHE}`,

      "-w", CONTAINER_WORK,

      // Environment
      "-e", `SEARXNG_URL=http://${HOST_GATEWAY}:8888`,
      "-e", `LMSTUDIO_URL=http://${HOST_GATEWAY}:1234`,
      "-e", `UV_CACHE_DIR=${CONTAINER_UV_CACHE}`,
      "-e", "PI_SANDBOX=1",
      "-e", `PI_REMOTE_SESSION=${sessionId}`,
      "-e", `PI_REMOTE_USER=${userId}`,
    ];

    if (gatePort) {
      args.push("-e", `PI_REMOTE_GATE_HOST=${HOST_GATEWAY}`);
      args.push("-e", `PI_REMOTE_GATE_PORT=${gatePort}`);
    }

    // Extra env vars
    if (extraEnv) {
      for (const [k, v] of Object.entries(extraEnv)) {
        args.push("-e", `${k}=${v}`);
      }
    }

    // Image + pi entrypoint args
    args.push(this.config.image, ...piArgs);

    const proc = spawn("container", args, {
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.running.set(sessionId, { containerId, process: proc });
    proc.on("exit", () => this.running.delete(sessionId));

    return proc;
  }

  /**
   * Stop a container gracefully, then force-kill.
   */
  async stopContainer(sessionId: string): Promise<void> {
    const entry = this.running.get(sessionId);
    if (!entry) {
      return;
    }

    this.stopContainerById(entry.containerId);
    this.running.delete(sessionId);
  }

  async stopAll(): Promise<void> {
    await Promise.all(
      Array.from(this.running.keys()).map(id => this.stopContainer(id)),
    );
  }

  /**
   * Best-effort cleanup for stale session containers left by crashes.
   *
   * Note: this targets only containers we create (`pi-remote-<sessionId>`).
   */
  async cleanupOrphanedContainers(): Promise<void> {
    const tracked = new Set(Array.from(this.running.values()).map((entry) => entry.containerId));
    const candidates = this.listRunningSessionContainerIds();
    const orphaned = candidates.filter((containerId) => !tracked.has(containerId));

    if (orphaned.length === 0) {
      return;
    }

    console.log(`[sandbox] Cleaning up ${orphaned.length} orphan container(s)`);

    for (const containerId of orphaned) {
      this.stopContainerById(containerId);
      console.log(`[sandbox] Stopped orphan ${containerId}`);
    }
  }

  isRunning(sessionId: string): boolean {
    return this.running.has(sessionId);
  }

  private listRunningSessionContainerIds(): string[] {
    try {
      const output = execSync("container list", { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] });
      const ids: string[] = [];
      const lines = output.split("\n");

      for (const line of lines.slice(1)) {
        const trimmed = line.trim();
        if (!trimmed) {
          continue;
        }

        const containerId = trimmed.split(/\s+/)[0];
        if (containerId.startsWith(SESSION_CONTAINER_PREFIX)) {
          ids.push(containerId);
        }
      }

      return ids;
    } catch {
      return [];
    }
  }

  private stopContainerById(containerId: string): void {
    try {
      execSync(`container stop ${containerId}`, { timeout: 5000, stdio: "ignore" });
      return;
    } catch {}

    try {
      execSync(`container kill ${containerId}`, { stdio: "ignore" });
    } catch {}
  }

  // ─── Convenience Getters ───

  getWorkDir(userId: string, sessionId: string): string {
    const workDir = join(this.config.sandboxBaseDir, userId, sessionId, "workspace");
    if (!existsSync(workDir)) mkdirSync(workDir, { recursive: true });
    return workDir;
  }

  // ─── Helpers ───

  private syncFile(src: string, dest: string, opts?: { mode?: number }): void {
    if (!existsSync(src)) return;
    if (!existsSync(dest) || isNewer(src, dest)) {
      cpSync(src, dest);
      if (opts?.mode) chmodSync(dest, opts.mode);
    }
  }

  private syncModels(src: string, dest: string): void {
    if (!existsSync(src)) return;
    const content = readFileSync(src, "utf-8");
    const transformed = content.replace(/http:\/\/localhost:/g, `http://${HOST_GATEWAY}:`);
    writeFileSync(dest, transformed);
  }
}

// ─── Utilities ───

function isNewer(a: string, b: string): boolean {
  try {
    return statSync(a).mtimeMs > statSync(b).mtimeMs;
  } catch {
    return false;
  }
}

function realpath(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

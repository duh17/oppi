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
 * Host layout per workspace:
 *   <sandboxBaseDir>/<workspaceId>/
 *   ├── workspace/          # Shared working directory
 *   ├── skills/             # Shared skills (workspace-level)
 *   └── sessions/<sessionId>/
 *       ├── agent/          # auth.json, models.json, extensions/
 *       │   └── skills → ../../../skills  (symlink)
 *       ├── bin/            # Shim binaries on $PATH
 *       └── system-prompt.md
 *
 * Extracted modules:
 *   sandbox-skills.ts  — skill sync, shims, fetch allowlist, session profile
 *   sandbox-prompt.ts  — system prompt generation
 */

import { spawn, execSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, cpSync, readFileSync, writeFileSync, rmSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { syncFile, resolvePath as realpath } from "./sync.js";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import type { Workspace } from "./types.js";
import type { SkillRegistry } from "./skills.js";
import type { AuthProxy } from "./auth-proxy.js";
import {
  extensionInstallName,
  resolveWorkspaceExtensions,
} from "./extension-loader.js";

// Extracted modules
import {
  syncSkills,
  linkSessionSkills,
  createSkillShims,
  writeSessionProfile,
  writeFetchAllowlist,
} from "./sandbox-skills.js";
import { generateSystemPrompt } from "./sandbox-prompt.js";
import { LoopbackBridgeManager } from "./loopback-bridge.js";

// ─── Constants ───

const IMAGE_NAME = "oppi-server:local";
const WORKSPACE_CONTAINER_PREFIX = "oppi-server-ws-";
const CONTAINER_WORK = "/work";
const CONTAINER_UV_CACHE = "/uv-cache";
const CONTAINER_WORKSPACE_ROOT = "/oppi-server-workspace";
const CONTAINER_MEMORY_DIR = "/home/pi/.config/dotfiles/shared/memory";

// Container network — NAT mode with internet access.
// Containers need outbound internet for:
//   - pip/npm/cargo installs (agent tool use)
//   - Web fetches (search, scraping tasks)
//   - API calls routed through auth proxy (credentials stay on host)
// Security: containers only get stub tokens (sk-ant-oat01-proxy-*, fake JWTs).
// Real credentials are injected by the auth proxy on the host side.
const CONTAINER_NETWORK_NAME = "oppi-server";
const CONTAINER_NETWORK_SUBNET = "10.201.0.0/24";
const HOST_GATEWAY = "10.201.0.1"; // NAT network gateway → host

// Paths relative to this file
const __dirname = dirname(fileURLToPath(import.meta.url));
const SANDBOX_DIR = join(__dirname, "..", "sandbox");
const EXTENSION_SRC = join(__dirname, "..", "extensions", "permission-gate");

/** Fallback skills when no workspace is configured. */
const DEFAULT_SKILLS = ["search", "fetch", "web-browser"];

// ─── Types ───

export interface SandboxConfig {
  /** Base dir for all sandbox data. Default: ~/.config/oppi/sandboxes */
  sandboxBaseDir: string;
  /** Shared uv cache. Default: ~/.config/oppi/uv-cache */
  uvCacheDir: string;
  /** Container image name. Default: oppi-server:local */
  image: string;
  /** CPUs per container */
  cpus: number;
  /** Memory per container (MB) */
  memoryMb: number;
}

export interface SpawnOptions {
  sessionId: string;
  
  workspaceId: string;
  userName?: string;
  model?: string;
  /** Workspace configuration for this session. */
  workspace?: Workspace;
  /** Gate TCP port on host (extension connects to host-gateway:port) */
  gatePort?: number;
  /** Extra env vars to pass to the container */
  env?: Record<string, string>;
}

const DEFAULTS: SandboxConfig = {
  sandboxBaseDir: join(homedir(), ".config", "oppi", "sandboxes"),
  uvCacheDir: join(homedir(), ".config", "oppi", "uv-cache"),
  image: IMAGE_NAME,
  cpus: 4,
  memoryMb: 2048,
};

// ─── SandboxManager ───

export class SandboxManager {
  readonly config: SandboxConfig;
  private skillRegistry: SkillRegistry | null = null;
  private authProxy: AuthProxy | null = null;
  private loopbackBridges = new LoopbackBridgeManager();
  /** Running workspace containers keyed by workspaceId (single-user mode). */
  private running: Map<string, { containerId: string }> = new Map();

  constructor(config?: Partial<SandboxConfig>) {
    this.config = { ...DEFAULTS, ...config };
  }

  /** Wire up the skill registry for workspace-driven skill selection. */
  setSkillRegistry(registry: SkillRegistry): void {
    this.skillRegistry = registry;
  }

  /** Wire up the auth proxy for credential isolation. */
  setAuthProxy(proxy: AuthProxy): void {
    this.authProxy = proxy;
  }

  /** Expose base dir for trace file reading. */
  getBaseDir(): string {
    return this.config.sandboxBaseDir;
  }

  private workspaceKey(workspaceId: string): string {
    return workspaceId;
  }

  private workspaceContainerId(workspaceId: string): string {
    return `${WORKSPACE_CONTAINER_PREFIX}${workspaceId}`;
  }

  // ─── Image Management ───

  imageExists(): boolean {
    try {
      const out = execSync("container image list", { encoding: "utf-8" });
      const name = this.config.image.split(":")[0];
      const tag = this.config.image.split(":")[1] || "latest";
      return out.split("\n").some((line) => {
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
      const proc = spawn(
        "container",
        ["build", "-t", this.config.image, "-f", containerfile, SANDBOX_DIR],
        { stdio: "inherit" },
      );

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

  /** Check whether the `container` CLI is available on this machine. */
  containerRuntimeAvailable(): boolean {
    try {
      execSync("which container", { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  }

  async ensureImage(): Promise<void> {
    if (!this.containerRuntimeAvailable()) {
      console.log("[sandbox] Container runtime not available — host-only mode");
      return;
    }
    if (!this.imageExists()) {
      await this.buildImage();
    }
  }

  /**
   * Ensure the container network exists.
   * NAT network = internet access + host-gateway for auth proxy.
   * Idempotent — safe to call on every server start.
   */
  ensureNetwork(): void {
    if (!this.containerRuntimeAvailable()) return;
    try {
      execSync(
        `container network create --subnet ${CONTAINER_NETWORK_SUBNET} ${CONTAINER_NETWORK_NAME}`,
        { stdio: "ignore" },
      );
      console.log(
        `[sandbox] Created NAT network ${CONTAINER_NETWORK_NAME} (${CONTAINER_NETWORK_SUBNET})`,
      );
    } catch {
      // Already exists — expected on subsequent starts
    }
  }

  /**
   * Start host loopback bridges for any provider baseUrls bound to localhost.
   *
   * Container sessions cannot reach host loopback directly. We expose ephemeral
   * bridge ports on 0.0.0.0 and rewrite localhost provider URLs to host-gateway.
   */
  async prepareLoopbackBridges(): Promise<void> {
    if (!this.containerRuntimeAvailable()) return;
    const modelsPath = join(homedir(), ".pi", "agent", "models.json");
    if (!existsSync(modelsPath)) {
      return;
    }

    let parsed: { providers?: Record<string, unknown> };

    try {
      parsed = JSON.parse(readFileSync(modelsPath, "utf-8")) as { providers?: Record<string, unknown> };
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`[sandbox] Failed to parse ${modelsPath}: ${message}`);
      return;
    }

    const baseUrls: string[] = [];

    if (parsed.providers && typeof parsed.providers === "object") {
      for (const provider of Object.values(parsed.providers)) {
        if (!provider || typeof provider !== "object") {
          continue;
        }

        const baseUrl = (provider as Record<string, unknown>).baseUrl;
        if (typeof baseUrl === "string" && baseUrl.length > 0) {
          baseUrls.push(baseUrl);
        }
      }
    }

    if (baseUrls.length === 0) {
      return;
    }

    await this.loopbackBridges.ensureForBaseUrls(baseUrls);

    const logged = new Set<string>();
    for (const baseUrl of baseUrls) {
      const rewritten = this.loopbackBridges.rewriteForHostGateway(baseUrl, HOST_GATEWAY);
      if (rewritten === baseUrl || logged.has(rewritten)) {
        continue;
      }

      logged.add(rewritten);
      console.log(`[sandbox] Loopback bridge enabled: ${baseUrl} -> ${rewritten}`);
    }
  }

  async shutdownLoopbackBridges(): Promise<void> {
    await this.loopbackBridges.shutdown();
  }

  // ─── Directory Layout ───

  getWorkspaceDir(workspaceId: string): string {
    return join(this.config.sandboxBaseDir, workspaceId);
  }

  getSessionRootDir(workspaceId: string, sessionId: string): string {
    return join(this.getWorkspaceDir(workspaceId), "sessions", sessionId);
  }

  // ─── Session Init ───

  /**
   * Initialize sandbox directories and sync host config. Idempotent.
   *
   * Host layout (workspace-scoped):
   *   <sandboxBaseDir>/<workspaceId>/
   *   ├── workspace/                    # Shared working directory
   *   ├── skills/                       # Shared skills (workspace-level)
   *   └── sessions/<sessionId>/
   *       ├── agent/                    # auth.json, models.json, extensions/
   *       │   └── skills → ../../../skills  (symlink to workspace skills)
   *       ├── bin/                      # Shim binaries on $PATH
   *       ├── .config/fetch/            # Fetch skill allowlist
   *       └── system-prompt.md          # Generated system prompt
   */
  initSession(
    workspaceId: string,
    sessionId: string,
    opts?: { userName?: string; model?: string; workspace?: Workspace },
  ): { piDir: string; workDir: string } {
    const workspaceRoot = this.getWorkspaceDir(workspaceId);
    const piDir = this.getSessionRootDir(workspaceId, sessionId);
    const agentDir = join(piDir, "agent");
    const workDir = join(workspaceRoot, "workspace");

    for (const dir of [agentDir, workDir]) {
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
      }
    }

    // Ensure uv cache dir exists
    if (!existsSync(this.config.uvCacheDir)) {
      mkdirSync(this.config.uvCacheDir, { recursive: true });
    }

    // Auth isolation
    this.writeSessionAuth(agentDir, sessionId);

    // Sync models.json — rewrite localhost → host-gateway, inject proxy baseUrls
    this.syncModels(join(homedir(), ".pi", "agent", "models.json"), join(agentDir, "models.json"));

    // Sync settings.json
    syncFile(join(homedir(), ".pi", "agent", "settings.json"), join(agentDir, "settings.json"));

    // Install extensions
    const extensionsDir = join(agentDir, "extensions");
    mkdirSync(extensionsDir, { recursive: true });

    if (existsSync(EXTENSION_SRC)) {
      const dest = join(extensionsDir, "permission-gate");
      if (existsSync(dest)) rmSync(dest, { recursive: true });
      cpSync(EXTENSION_SRC, dest, { recursive: true });
    }

    const extensionSelection = resolveWorkspaceExtensions(opts?.workspace?.extensions);

    for (const warning of extensionSelection.warnings) {
      console.warn(`[sandbox] extension: ${warning}`);
    }

    for (const extension of extensionSelection.extensions) {
      const dest = join(extensionsDir, extensionInstallName(extension));
      if (existsSync(dest)) {
        rmSync(dest, { recursive: true, force: true });
      }

      if (extension.kind === "directory") {
        cpSync(extension.path, dest, { recursive: true });
      } else {
        syncFile(extension.path, dest);
      }
    }

    // Sync skills (workspace-level, shared across sessions)
    const requestedSkills = opts?.workspace?.skills ?? DEFAULT_SKILLS;
    const workspaceSkillsDir = join(workspaceRoot, "skills");
    const installedSkills = syncSkills(workspaceSkillsDir, requestedSkills, this.skillRegistry);
    linkSessionSkills(agentDir, workspaceSkillsDir);

    // Create shim binaries (bin/ on $PATH inside container)
    createSkillShims(piDir, agentDir, workspaceSkillsDir, installedSkills);

    // Write .profile so login shells preserve our PATH
    writeSessionProfile(piDir, sessionId, CONTAINER_WORKSPACE_ROOT);

    // Write default fetch allowlist
    if (installedSkills.includes("fetch")) {
      writeFetchAllowlist(piDir);
    }

    // Generate session system prompt
    generateSystemPrompt(piDir, installedSkills, HOST_GATEWAY, {
      userName: opts?.userName,
      model: opts?.model,
      workspace: opts?.workspace,
      skillRegistry: this.skillRegistry,
    });

    return { piDir, workDir };
  }

  // ─── Live Skill Re-sync ───

  /**
   * Re-sync skills for a specific workspace. Called when:
   * - Workspace skills list is changed (PUT /workspaces/:id)
   * - A skill's files change on disk (FSWatcher event)
   *
   * Updates the workspace-level skills/ directory and rebuilds shims for
   * any existing sessions. Active sessions won't be disrupted (pi already
   * loaded the skill into context), but the updated files will be available
   * on the next `read` of SKILL.md or on the next session.
   *
   * Only applies to container-mode workspaces (host mode reads from host
   * filesystem directly).
   *
   * Returns the list of skills that were installed.
   */
  resyncWorkspaceSkills(
    workspaceId: string,
    requestedSkills: string[],
  ): string[] {
    const workspaceRoot = this.getWorkspaceDir(workspaceId);
    const workspaceSkillsDir = join(workspaceRoot, "skills");

    // Only sync if workspace dir exists (was ever initialized)
    if (!existsSync(workspaceRoot)) return [];

    const installedSkills = syncSkills(workspaceSkillsDir, requestedSkills, this.skillRegistry, {
      force: true,
    });
    console.log(
      `[sandbox] Re-synced skills for workspace ${workspaceId}: ${installedSkills.join(", ")}`,
    );
    return installedSkills;
  }

  /**
   * Handle skill registry changes — re-sync affected workspaces.
   *
   * Called when the FSWatcher detects skill files changed on disk.
   * For each container workspace that uses any of the changed skills,
   * re-sync those skills into the workspace sandbox.
   */
  handleSkillsChanged(
    changedSkillNames: string[],
    getContainerWorkspaces: () => Workspace[],
  ): void {
    if (changedSkillNames.length === 0) return;

    const changedSet = new Set(changedSkillNames);

    for (const workspace of getContainerWorkspaces()) {
      if (workspace.runtime !== "container") continue;
      const overlap = workspace.skills.filter((s) => changedSet.has(s));
      if (overlap.length === 0) continue;

      console.log(
        `[sandbox] Skills changed: ${overlap.join(", ")} → re-syncing workspace ${workspace.id}`,
      );
      this.resyncWorkspaceSkills(workspace.id, workspace.skills);
    }
  }

  // ─── Container Lifecycle ───

  /**
   * Spawn pi process inside a workspace-owned container.
   */
  spawnPi(opts: SpawnOptions): ChildProcess {
    const {
      sessionId,
      workspaceId,
      userName,
      model,
      workspace,
      gatePort,
      env: extraEnv,
    } = opts;
    const { piDir, workDir } = this.initSession(workspaceId, sessionId, {
      userName,
      model,
      workspace,
    });

    // Resolve mounts
    const workspaceRootMount = realpath(this.getWorkspaceDir(workspaceId));
    const workMount = workspace?.hostMount
      ? realpath(resolveHomePath(workspace.hostMount))
      : realpath(workDir);

    // Ensure the workspace container is running
    const containerId = this.ensureWorkspaceContainer(
      workspaceId,
      workMount,
      workspaceRootMount,
      workspace,
    );

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

    const systemPromptPath = join(piDir, "system-prompt.md");
    const containerSessionRoot = `${CONTAINER_WORKSPACE_ROOT}/sessions/${sessionId}`;
    const containerAgentDir = `${containerSessionRoot}/agent`;
    const containerBinDir = `${containerSessionRoot}/bin`;

    if (existsSync(systemPromptPath)) {
      piArgs.push("--append-system-prompt", `${containerSessionRoot}/system-prompt.md`);
    }

    const execArgs = [
      "exec",
      "-i",
      "-w",
      CONTAINER_WORK,
      "-e",
      `PI_CODING_AGENT_DIR=${containerAgentDir}`,
      "-e",
      `HOME=${containerSessionRoot}`,
      "-e",
      `PATH=${containerBinDir}:/home/pi/.pi/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`,
      "-e",
      "PI_SANDBOX=1",
      "-e",
      `OPPI_SESSION=${sessionId}`,
      "-e",
      `OPPI_WORKSPACE=${workspaceId}`,
      "-e",
      `OPPI_USER=owner`,
    ];

    if (gatePort) {
      execArgs.push("-e", `OPPI_GATE_HOST=${HOST_GATEWAY}`);
      execArgs.push("-e", `OPPI_GATE_PORT=${gatePort}`);
    }

    if (extraEnv) {
      for (const [k, v] of Object.entries(extraEnv)) {
        execArgs.push("-e", `${k}=${v}`);
      }
    }

    execArgs.push(containerId, "pi", ...piArgs);

    return spawn("container", execArgs, {
      stdio: ["pipe", "pipe", "pipe"],
    });
  }

  private ensureWorkspaceContainer(
    workspaceId: string,
    workMount: string,
    workspaceRootMount: string,
    workspace?: Workspace,
  ): string {
    const key = this.workspaceKey(workspaceId);
    const tracked = this.running.get(key);

    if (tracked && this.isContainerRunning(tracked.containerId)) {
      return tracked.containerId;
    }

    const containerId = this.workspaceContainerId(workspaceId);

    // Reuse existing running canonical container after server restart.
    if (this.isContainerRunning(containerId)) {
      this.running.set(key, { containerId });
      return containerId;
    }

    const memoryMount = this.resolveMemoryMount(workspace);
    const lmstudioBridgePort = this.loopbackBridges.bridgePortForTarget(1234) ?? 1234;

    const args = [
      "run",
      "--rm",
      "-d",
      "--name",
      containerId,
      "--network",
      CONTAINER_NETWORK_NAME,
      "-c",
      String(this.config.cpus),
      "-m",
      `${this.config.memoryMb}M`,
      "-v",
      `${workMount}:${CONTAINER_WORK}`,
      "-v",
      `${workspaceRootMount}:${CONTAINER_WORKSPACE_ROOT}`,
      "-v",
      `${realpath(this.config.uvCacheDir)}:${CONTAINER_UV_CACHE}`,
      "-w",
      CONTAINER_WORK,
      "-e",
      `SEARXNG_URL=http://${HOST_GATEWAY}:8888`,
      "-e",
      `LMSTUDIO_URL=http://${HOST_GATEWAY}:${lmstudioBridgePort}`,
      "-e",
      `UV_CACHE_DIR=${CONTAINER_UV_CACHE}`,
      "-e",
      "PI_SANDBOX=1",
      "-e",
      `OPPI_WORKSPACE=${workspaceId}`,
      "-e",
      `OPPI_USER=owner`,
    ];

    if (memoryMount) {
      args.push("-v", `${realpath(memoryMount.hostDir)}:${CONTAINER_MEMORY_DIR}`);
      args.push("-e", `OPPI_MEMORY_NAMESPACE=${memoryMount.namespace}`);
    }

    args.push(
      "--entrypoint",
      "sh",
      this.config.image,
      "-lc",
      "trap 'exit 0' TERM INT; while true; do sleep 3600; done",
    );

    execSync(`container ${args.map(escapeShellArg).join(" ")}`, { stdio: "ignore" });

    this.running.set(key, { containerId });
    console.log(`[sandbox] Started workspace container ${containerId}`);
    return containerId;
  }

  async stopWorkspaceContainer(workspaceId: string): Promise<void> {
    const key = this.workspaceKey(workspaceId);
    const tracked = this.running.get(key);

    if (tracked) {
      this.stopContainerById(tracked.containerId);
      this.running.delete(key);
      return;
    }

    const containerId = this.workspaceContainerId(workspaceId);
    this.stopContainerById(containerId);
    this.running.delete(key);
  }

  async stopAll(): Promise<void> {
    for (const [key, entry] of this.running) {
      this.stopContainerById(entry.containerId);
      this.running.delete(key);
    }
  }

  async cleanupOrphanedContainers(): Promise<void> {
    if (!this.containerRuntimeAvailable()) return;
    const tracked = new Set(Array.from(this.running.values()).map((entry) => entry.containerId));
    const candidates = this.listRunningManagedContainerIds();
    const orphaned = candidates.filter((containerId) => !tracked.has(containerId));

    if (orphaned.length === 0) return;

    console.log(`[sandbox] Cleaning up ${orphaned.length} orphan container(s)`);
    for (const containerId of orphaned) {
      this.stopContainerById(containerId);
      console.log(`[sandbox] Stopped orphan ${containerId}`);
    }
  }

  isRunningWorkspace(workspaceId: string): boolean {
    return this.running.has(this.workspaceKey(workspaceId));
  }

  private listRunningManagedContainerIds(): string[] {
    try {
      const output = execSync("container list", {
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      const ids: string[] = [];

      for (const line of output.split("\n").slice(1)) {
        const trimmed = line.trim();
        if (!trimmed) continue;

        const containerId = trimmed.split(/\s+/)[0];
        if (containerId.startsWith(WORKSPACE_CONTAINER_PREFIX)) {
          ids.push(containerId);
        }
      }

      return ids;
    } catch {
      return [];
    }
  }

  private isContainerRunning(containerId: string): boolean {
    try {
      const output = execSync("container list", {
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      return output.split("\n").some((line) => line.trim().startsWith(`${containerId} `));
    } catch {
      return false;
    }
  }

  private stopContainerById(containerId: string): void {
    try {
      execSync(`container stop ${containerId}`, { timeout: 5000, stdio: "ignore" });
      return;
    } catch {
      // stop failed, try kill
    }

    try {
      execSync(`container kill ${containerId}`, { stdio: "ignore" });
    } catch {
      // container already stopped
    }
  }

  // ─── Convenience Getters ───

  getWorkDir(workspaceId: string): string {
    const workDir = join(this.config.sandboxBaseDir, workspaceId, "workspace");
    if (!existsSync(workDir)) mkdirSync(workDir, { recursive: true });
    return workDir;
  }

  // ─── Session Validation ───

  validateSession(
    sessionId: string,
    opts?: { memoryEnabled?: boolean; workspaceId?: string },
  ): { errors: string[]; warnings: string[] } {
    const workspaceId = opts?.workspaceId || sessionId;

    const agentDir = join(
      this.getWorkspaceDir(workspaceId),
      "sessions",
      sessionId,
      "agent",
    );

    const errors: string[] = [];
    const warnings: string[] = [];

    // Permission gate extension
    const gateDir = join(agentDir, "extensions", "permission-gate");
    if (!existsSync(gateDir)) {
      errors.push("Permission gate extension directory missing");
    } else {
      if (!existsSync(join(gateDir, "index.ts"))) {
        errors.push("Permission gate extension: index.ts not found");
      }
      if (!existsSync(join(gateDir, "package.json"))) {
        errors.push("Permission gate extension: package.json missing");
      }
    }

    // Memory extension
    if (opts?.memoryEnabled) {
      const memExt = join(agentDir, "extensions", "memory.ts");
      if (!existsSync(memExt)) {
        warnings.push("Memory extension not available (workspace has memoryEnabled=true)");
      }
    }

    // Auth config
    if (!existsSync(join(agentDir, "auth.json"))) {
      warnings.push("auth.json not synced — API authentication may fail");
    }

    return { errors, warnings };
  }

  // ─── Helpers ───

  private resolveMemoryMount(
    workspace?: Workspace,
  ): { hostDir: string; namespace: string } | null {
    if (!workspace?.memoryEnabled) return null;

    const namespace = sanitizeMemoryNamespace(workspace.memoryNamespace || `ws-${workspace.id}`);
    const hostDir = join(this.config.sandboxBaseDir, "_memory", namespace);
    const journalDir = join(hostDir, "journal");

    mkdirSync(journalDir, { recursive: true, mode: 0o700 });

    const memoryFile = join(hostDir, "MEMORY.md");
    if (!existsSync(memoryFile)) {
      writeFileSync(
        memoryFile,
        "# Memory\n\n## Rules\n\n- Never store secrets, credentials, API keys, or passwords via `remember`\n",
      );
    }

    return { hostDir, namespace };
  }

  /**
   * Write session auth.json with credential isolation.
   *
   * Auth proxy builds stub credentials per provider — real creds never enter
   * the container. Falls back to copying host auth.json if no proxy.
   */
  private writeSessionAuth(agentDir: string, sessionId: string): void {
    const destPath = join(agentDir, "auth.json");

    if (!this.authProxy) {
      syncFile(join(homedir(), ".pi", "agent", "auth.json"), destPath, { mode: 0o600 });
      return;
    }

    const stubAuth = this.authProxy.buildStubAuth(sessionId);
    writeFileSync(destPath, JSON.stringify(stubAuth, null, 2), { mode: 0o600 });
  }

  /**
   * Sync models.json from host with transforms:
   * 1. Rewrite localhost providers to host-gateway (optionally via bridge)
   * 2. Inject proxy baseUrl for remote providers
   */
  private syncModels(src: string, dest: string): void {
    if (!existsSync(src)) return;
    const content = readFileSync(src, "utf-8");

    let parsed: { providers?: Record<string, unknown> };

    try {
      parsed = JSON.parse(content) as { providers?: Record<string, unknown> };
    } catch {
      // Preserve backward-compatible behavior even if models.json is malformed.
      const fallback = content.replace(
        /http:\/\/(localhost|127\.0\.0\.1):/g,
        `http://${HOST_GATEWAY}:`,
      );
      writeFileSync(dest, fallback);
      return;
    }

    parsed.providers ??= {};

    // Rewrite loopback provider URLs to host-gateway. When a loopback bridge
    // exists for the target port, use that bridge port; otherwise keep original
    // port and rely on direct host-gateway access.
    for (const [providerKey, providerValue] of Object.entries(parsed.providers)) {
      if (!providerValue || typeof providerValue !== "object") {
        continue;
      }

      const provider = providerValue as Record<string, unknown>;
      const baseUrl = provider.baseUrl;
      if (typeof baseUrl !== "string" || baseUrl.length === 0) {
        continue;
      }

      provider.baseUrl = this.loopbackBridges.rewriteForHostGateway(baseUrl, HOST_GATEWAY);
      parsed.providers[providerKey] = provider;
    }

    // Inject proxy baseUrl overrides
    if (this.authProxy) {
      const proxiedProviders = this.authProxy.getProxiedProviders();
      if (proxiedProviders.length > 0) {
        for (const authKey of proxiedProviders) {
          const proxyUrl = this.authProxy.getProviderProxyUrl(authKey, HOST_GATEWAY);
          if (proxyUrl) {
            const existing = parsed.providers[authKey];
            parsed.providers[authKey] = {
              ...(existing && typeof existing === "object" ? (existing as Record<string, unknown>) : {}),
              baseUrl: proxyUrl,
            };
          }
        }
      }
    }

    writeFileSync(dest, JSON.stringify(parsed, null, 2));
  }
}

// ─── Utilities ───

function escapeShellArg(value: string): string {
  if (/^[A-Za-z0-9_./:-]+$/.test(value)) return value;
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function sanitizeMemoryNamespace(value: string): string {
  const trimmed = value.trim().toLowerCase();
  if (!trimmed) return "default";

  const cleaned = trimmed
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");

  return cleaned ? cleaned.slice(0, 64) : "default";
}

function resolveHomePath(p: string): string {
  if (p.startsWith("~/")) return join(homedir(), p.slice(2));
  if (p === "~") return homedir();
  return p;
}

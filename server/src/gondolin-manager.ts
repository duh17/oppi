/**
 * Gondolin micro-VM lifecycle manager.
 *
 * One VM per workspace, shared across all sessions in that workspace.
 * VMs are lazily created on first access and stopped after 15 minutes
 * with no busy session, or on workspace teardown / server shutdown.
 */

import { chmodSync, lstatSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, posix } from "node:path";
import {
  createShadowPathPredicate,
  type CreateHttpHooksOptions,
  type CreateHttpHooksResult,
} from "@earendil-works/gondolin";
import type { Workspace } from "./types.js";
import { GUEST_WORKSPACE, type GondolinVm } from "./gondolin-ops.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";

/** Stop an idle sandbox workspace VM after 15 minutes with no busy session. */
export const WORKSPACE_VM_IDLE_TEARDOWN_MS = 15 * 60 * 1000;

export interface IdleTeardownHandle {
  cancel(): void;
}

export type IdleTeardownScheduler = (
  callback: () => void | Promise<void>,
  delayMs: number,
) => IdleTeardownHandle;

export interface GondolinManagerOptions {
  idleTeardownMs?: number;
  scheduleIdleTeardown?: IdleTeardownScheduler;
}

/**
 * Factory function that creates a Gondolin VM.
 *
 * Injected at construction so tests can substitute a mock without
 * importing the real gondolin SDK.
 */
export type VmFactory = (
  options: VmFactoryOptions,
) => Promise<GondolinVm & { close(): Promise<void> }>;

export interface ReadonlyMount {
  hostPath: string;
  guestPath: string;
}

export type ReadonlyMountSpec = string | ReadonlyMount;

const DEFAULT_SHADOW_PATHS = [
  "/.env",
  "/.env.local",
  "/.env.development",
  "/.env.production",
  "/.envrc",
  "/.npmrc",
  "/.pypirc",
  "/.netrc",
  "/.aws",
  "/.azure",
  "/.config/gcloud",
  "/.gnupg",
  "/.ssh",
  "/.pi",
  "/.git-credentials",
  "/.kube",
  "/.docker/config.json",
  "/.pgpass",
];

const DEFAULT_SHADOW_FILE_NAMES = new Set([
  ".env",
  ".envrc",
  ".npmrc",
  ".pypirc",
  ".netrc",
  ".git-credentials",
  ".pgpass",
]);
const DEFAULT_SHADOW_DIR_NAMES = new Set([".aws", ".azure", ".gnupg", ".ssh", ".pi", ".kube"]);

// Prefix-closed at the mount root via Gondolin; basename/segment rules still
// hide the same names anywhere under the mount. Case is folded first so
// `/.CONFIG/gcloud/...` and `/.SSH` match the path list, not only exact case.
const matchesShadowedPath = createShadowPathPredicate(DEFAULT_SHADOW_PATHS);

/** Guest path where Pi discovers selected skills. Must stay under workspace `.pi/skills`. */
function sandboxPiOverlayGuestPath(guestWorkspacePath: string): string {
  return posix.join(guestWorkspacePath, ".pi");
}

/** `$TMPDIR/oppi-sandbox-pi-overlay` is well-known; refuse planted symlinks or foreign owners. */
function ensureOwnerOnlyRealDirectory(path: string, errorMessage: string): void {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stat = lstatSync(path);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error(errorMessage);
  }
  const uid = process.getuid?.();
  if (uid !== undefined && stat.uid !== uid) {
    throw new Error(`${errorMessage}: owned by uid ${stat.uid}`);
  }
  chmodSync(path, 0o700);
}

/** Empty host `.pi/skills` tree so Gondolin can traverse to per-skill mounts. */
function sandboxPiOverlayHostDir(): string {
  const dir = join(tmpdir(), "oppi-sandbox-pi-overlay");
  ensureOwnerOnlyRealDirectory(
    dir,
    `Sandbox .pi overlay must be a real owner-only directory: ${dir}`,
  );
  ensureOwnerOnlyRealDirectory(
    join(dir, "skills"),
    `Sandbox .pi overlay skills dir must be a real owner-only directory: ${join(dir, "skills")}`,
  );
  return dir;
}

/**
 * Workspace ShadowProvider hides every `.pi` path. Skill mounts live under
 * `/workspace/<slug>/.pi/skills/<name>`, so guest bind-setup cannot traverse
 * `.pi` unless that exact prefix is a separate mount.
 */
export function withSandboxPiOverlayMounts(
  guestWorkspacePath: string,
  readonlyMounts: ReadonlyMountSpec[] | undefined,
): ReadonlyMountSpec[] {
  if (!readonlyMounts?.length) return readonlyMounts ?? [];

  const piGuestPath = sandboxPiOverlayGuestPath(guestWorkspacePath);
  const needsOverlay = readonlyMounts.some((mount) => {
    const guestPath = typeof mount === "string" ? mount : mount.guestPath;
    return guestPath === piGuestPath || guestPath.startsWith(`${piGuestPath}/`);
  });
  if (!needsOverlay) return readonlyMounts;

  const hasOverlay = readonlyMounts.some((mount) => {
    const guestPath = typeof mount === "string" ? mount : mount.guestPath;
    return guestPath === piGuestPath;
  });
  if (hasOverlay) return readonlyMounts;

  return [{ hostPath: sandboxPiOverlayHostDir(), guestPath: piGuestPath }, ...readonlyMounts];
}

export function shouldShadowSandboxWorkspacePath(ctx: { op: string; path: string }): boolean {
  const normalized = posix
    .normalize(ctx.path.startsWith("/") ? ctx.path : `/${ctx.path}`)
    .toLowerCase();
  if (matchesShadowedPath({ ...ctx, path: normalized })) return true;
  if (normalized.endsWith("/.docker/config.json")) return true;

  const segments = normalized.split("/").filter(Boolean);
  if (segments.some((segment) => DEFAULT_SHADOW_DIR_NAMES.has(segment))) return true;

  const name = posix.basename(normalized);
  return (
    DEFAULT_SHADOW_FILE_NAMES.has(name) ||
    name.startsWith(".env.") ||
    name.endsWith(".pem") ||
    name.endsWith(".key") ||
    name.endsWith(".p12") ||
    name.endsWith(".pfx")
  );
}

export interface VmSecretDefinition {
  value: string;
  /** Explicit non-wildcard hosts this secret may be injected to. */
  hosts: string[];
}

export interface VmFactoryOptions {
  hostCwd: string;
  /** Guest path where hostCwd is mounted. Defaults to /workspace. */
  guestWorkspacePath?: string;
  allowedHosts?: string[];
  /** Secret definitions for host-mediated HTTP injection. Keys are env var names. */
  secrets?: Record<string, VmSecretDefinition>;
  /** Additional host paths to mount read-only. Strings mount at the same guest path. */
  readonlyMounts?: ReadonlyMountSpec[];
  /** Non-secret guest env such as PATH or LANG. Do not put provider credentials here. */
  extraEnv?: Record<string, string>;
  /** Shown by `gondolin list`. Prefer the workspace id. */
  sessionLabel?: string;
}

interface WorkspaceVmEntry {
  vm: GondolinVm & { close(): Promise<void> };
  fingerprint: string;
}

/** Canonical VM identity so workspace cwd/host/env changes recycle a stale VM. */
export function workspaceVmFingerprint(options: {
  hostCwd: string;
  guestWorkspacePath?: string;
  allowedHosts?: string[];
  extraEnv?: Record<string, string>;
}): string {
  const extraEnv = Object.fromEntries(
    Object.entries(options.extraEnv ?? {}).sort(([left], [right]) => left.localeCompare(right)),
  );

  return JSON.stringify({
    hostCwd: options.hostCwd,
    guestWorkspacePath: options.guestWorkspacePath ?? GUEST_WORKSPACE,
    allowedHosts: options.allowedHosts ?? null,
    extraEnv,
  });
}

function isExplicitNonWildcardHostList(hosts: string[] | undefined): hosts is string[] {
  if (!Array.isArray(hosts) || hosts.length === 0) return false;
  // Gondolin trims/lowercases hosts; " * " must not become allow-all.
  return hosts.every((host) => {
    const normalized = host.trim().toLowerCase();
    return normalized.length > 0 && !normalized.includes("*");
  });
}

function gondolinSecretsFrom(
  secrets: Record<string, VmSecretDefinition> | undefined,
): Record<string, { hosts: string[]; value: string }> | undefined {
  // Do not invent hosts from allowedHosts or ["*"]. Empty {} stays empty.
  if (!secrets) return undefined;

  return Object.fromEntries(
    Object.entries(secrets).map(([name, secret]) => {
      if (!isExplicitNonWildcardHostList(secret.hosts)) {
        throw new Error(`sandbox secret "${name}" requires an explicit non-wildcard host list`);
      }
      return [name, { hosts: secret.hosts, value: secret.value }];
    }),
  );
}

export function buildVmHttpHooks(
  createHttpHooks: (options?: CreateHttpHooksOptions) => CreateHttpHooksResult,
  options: Pick<VmFactoryOptions, "allowedHosts" | "secrets">,
): Pick<CreateHttpHooksResult, "httpHooks" | "env"> {
  const gondolinSecrets = gondolinSecretsFrom(options.secrets);

  const { httpHooks: baseHttpHooks, env } = createHttpHooks({
    allowedHosts: options.allowedHosts,
    secrets: gondolinSecrets,
  });

  // Keep the workspace contract explicit: [] means deny all network egress,
  // while undefined is never passed through as Gondolin's allow-all default.
  if (options.allowedHosts?.length === 0) {
    return {
      httpHooks: {
        ...baseHttpHooks,
        isIpAllowed: async () => false,
      },
      env,
    };
  }

  return { httpHooks: baseHttpHooks, env };
}

/**
 * Default factory using the real Gondolin SDK.
 *
 * Dynamically imports `@earendil-works/gondolin` so the module is
 * only required at runtime when sandbox mode is actually used.
 */
export async function defaultVmFactory(
  options: VmFactoryOptions,
): Promise<GondolinVm & { close(): Promise<void> }> {
  // Dynamic import — only loaded when sandbox mode is used.
  const { VM, RealFSProvider, ReadonlyProvider, ShadowProvider, createHttpHooks } =
    await import("@earendil-works/gondolin");

  const { httpHooks, env } = buildVmHttpHooks(createHttpHooks, options);

  // Build VFS mounts: workspace + any read-only paths (skills, agent config)
  const workspaceGuestPath = options.guestWorkspacePath ?? GUEST_WORKSPACE;
  const workspaceProvider = new ShadowProvider(new RealFSProvider(options.hostCwd), {
    shouldShadow: shouldShadowSandboxWorkspacePath,
    writeMode: "deny",
  });

  const mounts: Record<
    string,
    | InstanceType<typeof RealFSProvider>
    | InstanceType<typeof ReadonlyProvider>
    | InstanceType<typeof ShadowProvider>
  > = {
    [workspaceGuestPath]: workspaceProvider,
  };
  const readonlyMounts = withSandboxPiOverlayMounts(workspaceGuestPath, options.readonlyMounts);
  for (const mount of readonlyMounts) {
    const hostPath = typeof mount === "string" ? mount : mount.hostPath;
    const guestPath = typeof mount === "string" ? mount : mount.guestPath;
    mounts[guestPath] = new ReadonlyProvider(new RealFSProvider(hostPath));
  }

  // Merge httpHooks env (secret placeholders) with workspace-level extra env.
  const mergedEnv = options.extraEnv ? { ...env, ...options.extraEnv } : env;

  // Gondolin defaults (64 MiB). Set explicitly so guest HTTP bodies stay capped.
  const guestMaxHttpBodyBytes = 64 * 1024 * 1024;

  const vm = await VM.create({
    vfs: { mounts },
    httpHooks,
    env: mergedEnv,
    allowWebSockets: false,
    maxHttpBodyBytes: guestMaxHttpBodyBytes,
    maxHttpResponseBodyBytes: guestMaxHttpBodyBytes,
    ...(options.sessionLabel ? { sessionLabel: options.sessionLabel } : {}),
  });

  const shellProbe = await vm.exec(["/bin/sh", "-lc", "command -v bash || true"]);
  const shellPath = shellProbe.stdout.trim() || "/bin/sh";

  return Object.assign(vm, { shellPath });
}

const log = createLogger({ base: { component: "gondolin_manager" } });

function defaultIdleTeardownScheduler(
  callback: () => void | Promise<void>,
  delayMs: number,
): IdleTeardownHandle {
  const timer = setTimeout(() => {
    void callback();
  }, delayMs);
  return {
    cancel: () => clearTimeout(timer),
  };
}

export class GondolinManager {
  /** workspaceId → running VM plus the config fingerprint it was booted with */
  private vms = new Map<string, WorkspaceVmEntry>();
  /** workspaceId → in-flight startup promise (prevents double-start) */
  private starting = new Map<string, Promise<GondolinVm & { close(): Promise<void> }>>();
  /** workspaceId → session IDs currently in a busy turn */
  private busySessions = new Map<string, Set<string>>();
  /** workspaceId → pending idle stop */
  private idleTimers = new Map<string, IdleTeardownHandle>();
  private readonly factory: VmFactory;
  private readonly idleTeardownMs: number;
  private readonly scheduleIdleTeardown: IdleTeardownScheduler;

  constructor(factory: VmFactory = defaultVmFactory, options: GondolinManagerOptions = {}) {
    this.factory = factory;
    this.idleTeardownMs = options.idleTeardownMs ?? WORKSPACE_VM_IDLE_TEARDOWN_MS;
    this.scheduleIdleTeardown = options.scheduleIdleTeardown ?? defaultIdleTeardownScheduler;
  }

  /**
   * Return an existing VM for this workspace, or create one.
   *
   * Concurrent calls for the same workspace coalesce onto a single
   * startup promise to avoid spinning up duplicate VMs. A later call with a
   * different workspace cwd/host/env fingerprint closes the old VM and boots a new one.
   * Per-session readonly skill mounts are not part of that identity.
   */
  async ensureWorkspaceVm(
    workspace: Workspace,
    hostCwd: string,
    secrets?: Record<string, VmSecretDefinition>,
    readonlyMounts?: ReadonlyMountSpec[],
    extraEnv?: Record<string, string>,
    guestWorkspacePath?: string,
  ): Promise<GondolinVm> {
    const id = workspace.id;
    const fingerprint = workspaceVmFingerprint({
      hostCwd,
      guestWorkspacePath,
      allowedHosts: workspace.sandboxConfig?.allowedHosts,
      extraEnv,
    });

    // Already starting — coalesce even if this call wants a different fingerprint.
    const inflight = this.starting.get(id);
    if (inflight) return inflight;

    const existing = this.vms.get(id);
    if (existing) {
      if (existing.fingerprint === fingerprint) return existing.vm;
      await this.stopWorkspaceVm(id);
    }

    const inflightAfterStop = this.starting.get(id);
    if (inflightAfterStop) return inflightAfterStop;

    const promise = this.startVm(
      workspace,
      hostCwd,
      secrets,
      readonlyMounts,
      extraEnv,
      guestWorkspacePath,
    );
    this.starting.set(id, promise);

    try {
      const vm = await promise;
      this.vms.set(id, { vm, fingerprint });
      return vm;
    } finally {
      this.starting.delete(id);
    }
  }

  /**
   * A busy sandbox session in this workspace cancels idle teardown.
   * Called from the session-status path; this module does not import sessions.ts.
   */
  noteWorkspaceBusy(workspaceId: string, sessionId: string): void {
    let sessions = this.busySessions.get(workspaceId);
    if (!sessions) {
      sessions = new Set();
      this.busySessions.set(workspaceId, sessions);
    }
    sessions.add(sessionId);
    this.clearIdleTimer(workspaceId);
  }

  /**
   * When this session has stopped, start the 15-minute idle timer if no other
   * session in the workspace still holds the VM.
   */
  noteWorkspaceIdle(workspaceId: string, sessionId: string): void {
    const sessions = this.busySessions.get(workspaceId);
    sessions?.delete(sessionId);
    if (sessions && sessions.size === 0) this.busySessions.delete(workspaceId);
    if (this.hasBusySession(workspaceId)) return;
    this.armIdleTimer(workspaceId);
  }

  async stopWorkspaceVm(workspaceId: string): Promise<void> {
    this.clearIdleTimer(workspaceId);
    const existing = this.vms.get(workspaceId);
    if (!existing) return;

    this.vms.delete(workspaceId);
    log.info("gondolin.vm_stopping", { workspaceId });

    try {
      await existing.vm.close();
    } catch (err) {
      log.error("gondolin.vm_stop.failed", {
        workspaceId,
        error: safeErrorMessage(err),
      });
    }
  }

  async stopAll(): Promise<void> {
    const ids = [...this.vms.keys()];
    await Promise.allSettled(ids.map((id) => this.stopWorkspaceVm(id)));
  }

  isRunning(workspaceId: string): boolean {
    return this.vms.has(workspaceId);
  }

  getVm(workspaceId: string): GondolinVm | undefined {
    return this.vms.get(workspaceId)?.vm;
  }

  private hasBusySession(workspaceId: string): boolean {
    return (this.busySessions.get(workspaceId)?.size ?? 0) > 0;
  }

  private armIdleTimer(workspaceId: string): void {
    if (this.idleTimers.has(workspaceId)) return;
    if (!this.vms.has(workspaceId) && !this.starting.has(workspaceId)) return;
    const handle = this.scheduleIdleTeardown(
      () => this.onIdleTeardown(workspaceId),
      this.idleTeardownMs,
    );
    this.idleTimers.set(workspaceId, handle);
  }

  private clearIdleTimer(workspaceId: string): void {
    const handle = this.idleTimers.get(workspaceId);
    if (!handle) return;
    handle.cancel();
    this.idleTimers.delete(workspaceId);
  }

  private async onIdleTeardown(workspaceId: string): Promise<void> {
    this.idleTimers.delete(workspaceId);
    // Do not stop mid-turn if a session became busy after the timer was queued.
    if (this.hasBusySession(workspaceId)) return;
    await this.stopWorkspaceVm(workspaceId);
  }

  private async startVm(
    workspace: Workspace,
    hostCwd: string,
    secrets?: Record<string, VmSecretDefinition>,
    readonlyMounts?: ReadonlyMountSpec[],
    extraEnv?: Record<string, string>,
    guestWorkspacePath?: string,
  ): Promise<GondolinVm & { close(): Promise<void> }> {
    const allowedHosts = workspace.sandboxConfig?.allowedHosts;
    log.info("gondolin.vm_starting", {
      workspaceId: workspace.id,
      cwd: hostCwd,
      allowedHosts,
      roMounts: readonlyMounts?.length ?? 0,
    });

    const vm = await this.factory({
      hostCwd,
      guestWorkspacePath,
      allowedHosts,
      secrets,
      readonlyMounts,
      extraEnv,
      sessionLabel: workspace.id,
    });

    log.info("gondolin.vm_ready", { workspaceId: workspace.id });
    return vm;
  }
}

/**
 * Check whether QEMU is available on the host.
 * Returns true if `qemu-system-aarch64` (or `qemu-system-x86_64` on Intel) is found in PATH.
 */
export async function isQemuAvailable(): Promise<boolean> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execFileAsync = promisify(execFile);

  // Try aarch64 first (Apple Silicon), fall back to x86_64
  for (const arch of ["aarch64", "x86_64"]) {
    try {
      await execFileAsync(`qemu-system-${arch}`, ["--version"]);
      return true;
    } catch {
      // Not found, try next
    }
  }
  return false;
}

/**
 * Gondolin micro-VM lifecycle manager.
 *
 * One VM per workspace, shared across all sessions in that workspace.
 * VMs are lazily created on first access and stopped on workspace
 * teardown or server shutdown.
 */

import { posix } from "node:path";
import type { CreateHttpHooksOptions, CreateHttpHooksResult } from "@earendil-works/gondolin";
import type { Workspace } from "./types.js";
import { GUEST_WORKSPACE, type GondolinVm } from "./gondolin-ops.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";

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
];

const DEFAULT_SHADOW_FILE_NAMES = new Set([".env", ".envrc", ".npmrc", ".pypirc", ".netrc"]);
const DEFAULT_SHADOW_DIR_NAMES = new Set([".aws", ".azure", ".gnupg", ".ssh"]);

export function shouldShadowSandboxWorkspacePath(ctx: { op: string; path: string }): boolean {
  const normalized = posix.normalize(ctx.path.startsWith("/") ? ctx.path : `/${ctx.path}`);
  if (DEFAULT_SHADOW_PATHS.includes(normalized)) return true;

  const segments = normalized
    .split("/")
    .filter(Boolean)
    .map((segment) => segment.toLowerCase());
  if (segments.some((segment) => DEFAULT_SHADOW_DIR_NAMES.has(segment))) return true;

  const name = posix.basename(normalized).toLowerCase();
  return (
    DEFAULT_SHADOW_FILE_NAMES.has(name) ||
    name.startsWith(".env.") ||
    name.endsWith(".pem") ||
    name.endsWith(".key")
  );
}

export interface VmFactoryOptions {
  hostCwd: string;
  /** Guest path where hostCwd is mounted. Defaults to /workspace. */
  guestWorkspacePath?: string;
  allowedHosts?: string[];
  /** Secret definitions for host-mediated HTTP injection. Keys are env var names. */
  secrets?: Record<string, { value: string; headerName?: string }>;
  /** Additional host paths to mount read-only. Strings mount at the same guest path. */
  readonlyMounts?: ReadonlyMountSpec[];
  /** Extra environment variables for the guest VM. */
  extraEnv?: Record<string, string>;
}

/**
 * Default factory using the real Gondolin SDK.
 *
 * Dynamically imports `@earendil-works/gondolin` so the module is
 * only required at runtime when sandbox mode is actually used.
 */
export function buildVmHttpHooks(
  createHttpHooks: (options?: CreateHttpHooksOptions) => CreateHttpHooksResult,
  options: Pick<VmFactoryOptions, "allowedHosts" | "secrets">,
): Pick<CreateHttpHooksResult, "httpHooks" | "env"> {
  // Transform secrets to Gondolin SDK format (hosts + value per key)
  const gondolinSecrets = options.secrets
    ? Object.fromEntries(
        Object.entries(options.secrets).map(([key, { value }]) => [
          key,
          { hosts: options.allowedHosts ?? ["*"], value },
        ]),
      )
    : undefined;

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
  if (options.readonlyMounts) {
    for (const mount of options.readonlyMounts) {
      const hostPath = typeof mount === "string" ? mount : mount.hostPath;
      const guestPath = typeof mount === "string" ? mount : mount.guestPath;
      mounts[guestPath] = new ReadonlyProvider(new RealFSProvider(hostPath));
    }
  }

  // Merge httpHooks env (secret placeholders) with workspace-level extra env.
  const mergedEnv = options.extraEnv ? { ...env, ...options.extraEnv } : env;

  const vm = await VM.create({
    vfs: { mounts },
    httpHooks,
    env: mergedEnv,
  });

  const shellProbe = await vm.exec(["/bin/sh", "-lc", "command -v bash || true"]);
  const shellPath = shellProbe.stdout.trim() || "/bin/sh";

  return Object.assign(vm, { shellPath });
}

const log = createLogger({ base: { component: "gondolin_manager" } });

export class GondolinManager {
  /** workspaceId → running VM */
  private vms = new Map<string, GondolinVm & { close(): Promise<void> }>();
  /** workspaceId → in-flight startup promise (prevents double-start) */
  private starting = new Map<string, Promise<GondolinVm & { close(): Promise<void> }>>();
  private readonly factory: VmFactory;

  constructor(factory: VmFactory = defaultVmFactory) {
    this.factory = factory;
  }

  /**
   * Return an existing VM for this workspace, or create one.
   *
   * Concurrent calls for the same workspace coalesce onto a single
   * startup promise to avoid spinning up duplicate VMs.
   */
  async ensureWorkspaceVm(
    workspace: Workspace,
    hostCwd: string,
    secrets?: Record<string, { value: string; headerName?: string }>,
    readonlyMounts?: ReadonlyMountSpec[],
    extraEnv?: Record<string, string>,
    guestWorkspacePath?: string,
  ): Promise<GondolinVm> {
    const id = workspace.id;

    // Already running
    const existing = this.vms.get(id);
    if (existing) return existing;

    // Already starting — coalesce
    const inflight = this.starting.get(id);
    if (inflight) return inflight;

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
      this.vms.set(id, vm);
      return vm;
    } finally {
      this.starting.delete(id);
    }
  }

  async stopWorkspaceVm(workspaceId: string): Promise<void> {
    const vm = this.vms.get(workspaceId);
    if (!vm) return;

    this.vms.delete(workspaceId);
    log.info("gondolin.vm_stopping", { workspaceId });

    try {
      await vm.close();
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
    return this.vms.get(workspaceId);
  }

  private async startVm(
    workspace: Workspace,
    hostCwd: string,
    secrets?: Record<string, { value: string; headerName?: string }>,
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

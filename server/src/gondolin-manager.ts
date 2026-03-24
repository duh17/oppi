/**
 * Gondolin micro-VM lifecycle manager.
 *
 * One VM per workspace, shared across all sessions in that workspace.
 * VMs are lazily created on first access and stopped on workspace
 * teardown or server shutdown.
 */

import type { Workspace } from "./types.js";
import type { GondolinVm } from "./gondolin-ops.js";
import { ts } from "./log-utils.js";

/**
 * Factory function that creates a Gondolin VM.
 *
 * Injected at construction so tests can substitute a mock without
 * importing the real gondolin SDK.
 */
export type VmFactory = (
  options: VmFactoryOptions,
) => Promise<GondolinVm & { close(): Promise<void> }>;

export interface VmFactoryOptions {
  hostCwd: string;
  allowedHosts: string[];
  /** Secret definitions for host-mediated HTTP injection. Keys are env var names. */
  secrets?: Record<string, { value: string; headerName?: string }>;
  /** Additional host paths to mount read-only at the same path inside the VM. */
  readonlyMounts?: string[];
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
  const { VM, RealFSProvider, ReadonlyProvider, createHttpHooks } =
    await import("@earendil-works/gondolin");

  // Transform secrets to Gondolin SDK format (hosts + value per key)
  const gondolinSecrets = options.secrets
    ? Object.fromEntries(
        Object.entries(options.secrets).map(([key, { value }]) => [
          key,
          { hosts: options.allowedHosts, value },
        ]),
      )
    : undefined;

  const { httpHooks, env } = createHttpHooks({
    allowedHosts: options.allowedHosts,
    secrets: gondolinSecrets,
  });

  // Build VFS mounts: workspace + any read-only paths (skills, agent config)
  const mounts: Record<
    string,
    InstanceType<typeof RealFSProvider> | InstanceType<typeof ReadonlyProvider>
  > = {
    "/workspace": new RealFSProvider(options.hostCwd),
  };
  if (options.readonlyMounts) {
    for (const hostPath of options.readonlyMounts) {
      // Mount at the same absolute path inside the VM so system prompt
      // references (e.g. /Users/chenda/.pi/agent/skills/...) resolve.
      mounts[hostPath] = new ReadonlyProvider(new RealFSProvider(hostPath));
    }
  }

  const vm = await VM.create({
    vfs: { mounts },
    httpHooks,
    env,
  });

  return vm;
}

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
    readonlyMounts?: string[],
  ): Promise<GondolinVm> {
    const id = workspace.id;

    // Already running
    const existing = this.vms.get(id);
    if (existing) return existing;

    // Already starting — coalesce
    const inflight = this.starting.get(id);
    if (inflight) return inflight;

    const promise = this.startVm(workspace, hostCwd, secrets, readonlyMounts);
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
    console.log("[gondolin] stopping VM", { workspaceId, ts: ts() });

    try {
      await vm.close();
    } catch (err) {
      console.error("[gondolin] error stopping VM", { workspaceId, err, ts: ts() });
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
    readonlyMounts?: string[],
  ): Promise<GondolinVm & { close(): Promise<void> }> {
    const allowedHosts = workspace.sandboxConfig?.allowedHosts ?? ["*"];
    console.log("[gondolin] starting VM", {
      workspaceId: workspace.id,
      cwd: hostCwd,
      allowedHosts,
      roMounts: readonlyMounts?.length ?? 0,
      ts: ts(),
    });

    const vm = await this.factory({ hostCwd, allowedHosts, secrets, readonlyMounts });

    console.log("[gondolin] VM ready", { workspaceId: workspace.id, ts: ts() });
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

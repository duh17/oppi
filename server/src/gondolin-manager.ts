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
export type VmFactory = (options: VmFactoryOptions) => Promise<GondolinVm & { close(): Promise<void> }>;

export interface VmFactoryOptions {
  hostCwd: string;
  allowedHosts: string[];
}

/**
 * Default factory using the real Gondolin SDK.
 *
 * Dynamically imports `@earendil-works/gondolin` so the module is
 * only required at runtime when sandbox mode is actually used.
 */
export async function defaultVmFactory(options: VmFactoryOptions): Promise<GondolinVm & { close(): Promise<void> }> {
  // Dynamic import — only loaded when sandbox mode is used.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { VM, RealFSProvider, createHttpHooks } = await import("@earendil-works/gondolin");

  const { httpHooks } = createHttpHooks({
    allowedHosts: options.allowedHosts,
  });

  const vm = await VM.create({
    vfs: {
      mounts: {
        "/workspace": new RealFSProvider(options.hostCwd),
      },
    },
    httpHooks,
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
  async ensureWorkspaceVm(workspace: WorkspaceWithSandbox, hostCwd: string): Promise<GondolinVm> {
    const id = workspace.id;

    // Already running
    const existing = this.vms.get(id);
    if (existing) return existing;

    // Already starting — coalesce
    const inflight = this.starting.get(id);
    if (inflight) return inflight;

    const promise = this.startVm(workspace, hostCwd);
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
    console.log(`[${ts()}] gondolin: stopping VM for workspace ${workspaceId}`);

    try {
      await vm.close();
    } catch (err) {
      console.error(`[${ts()}] gondolin: error stopping VM for workspace ${workspaceId}:`, err);
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
    workspace: WorkspaceWithSandbox,
    hostCwd: string,
  ): Promise<GondolinVm & { close(): Promise<void> }> {
    const allowedHosts = workspace.sandboxConfig?.allowedHosts ?? ["*"];
    console.log(
      `[${ts()}] gondolin: starting VM for workspace ${workspace.id} (cwd=${hostCwd}, allowedHosts=${JSON.stringify(allowedHosts)})`,
    );

    const vm = await this.factory({ hostCwd, allowedHosts });

    console.log(`[${ts()}] gondolin: VM ready for workspace ${workspace.id}`);
    return vm;
  }
}

// ─── Workspace extension ───

/**
 * Workspace with optional sandbox fields.
 * The canonical Workspace type in types.ts is being extended by another agent —
 * this local type captures the fields we depend on without modifying the
 * shared type definition.
 */
export interface WorkspaceWithSandbox extends Workspace {
  runtime?: "host" | "sandbox";
  sandboxConfig?: {
    allowedHosts?: string[];
  };
}

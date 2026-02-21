/**
 * Workspace runtime — concurrency primitives and slot tracking for
 * workspace-scoped session management.
 *
 * This module does NOT own process lifecycle. That stays in sessions.ts.
 * This module provides:
 *
 * 1. **Mutexes** — per-workspace and per-session locks to serialize
 *    lifecycle transitions and prevent concurrent spawn races.
 *
 * 2. **Slot tracking** — count active sessions per workspace and
 *    globally, enforce configurable limits.
 *
 * 3. **Config** — runtime limits (timeouts, max sessions) extracted
 *    from ServerConfig.
 */

import type { ServerConfig } from "./types.js";

// ─── Mutex ───

/**
 * Simple async mutex. Serializes access to a critical section.
 *
 * Usage:
 *   const release = await mutex.acquire();
 *   try { ... } finally { release(); }
 *
 * Or:
 *   await mutex.withLock(async () => { ... });
 */
export class Mutex {
  private queue: Array<() => void> = [];
  private locked = false;

  async acquire(): Promise<() => void> {
    if (!this.locked) {
      this.locked = true;
      return () => this.release();
    }

    return new Promise((resolve) => {
      this.queue.push(() => {
        resolve(() => this.release());
      });
    });
  }

  async withLock<T>(fn: () => Promise<T>): Promise<T> {
    const release = await this.acquire();
    try {
      return await fn();
    } finally {
      release();
    }
  }

  get isLocked(): boolean {
    return this.locked;
  }

  get queueLength(): number {
    return this.queue.length;
  }

  private release(): void {
    const next = this.queue.shift();
    if (next) {
      next();
    } else {
      this.locked = false;
    }
  }
}

// ─── Runtime Limits ───

export interface RuntimeLimits {
  maxSessionsPerWorkspace: number;
  maxSessionsGlobal: number;
  sessionIdleTimeoutMs: number;
  workspaceIdleTimeoutMs: number;
}

const DEFAULTS: RuntimeLimits = {
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
  sessionIdleTimeoutMs: 10 * 60_000, // 10 min
  workspaceIdleTimeoutMs: 30 * 60_000, // 30 min
};

/** Extract runtime limits from ServerConfig, applying defaults. */
export function resolveRuntimeLimits(config: ServerConfig): RuntimeLimits {
  return {
    maxSessionsPerWorkspace: config.maxSessionsPerWorkspace ?? DEFAULTS.maxSessionsPerWorkspace,
    maxSessionsGlobal: config.maxSessionsGlobal ?? DEFAULTS.maxSessionsGlobal,
    sessionIdleTimeoutMs: config.sessionIdleTimeoutMs ?? DEFAULTS.sessionIdleTimeoutMs,
    workspaceIdleTimeoutMs: config.workspaceIdleTimeoutMs ?? DEFAULTS.workspaceIdleTimeoutMs,
  };
}

// ─── Session Identity ───

/** Identifies a session within its workspace. */
export interface WorkspaceSessionIdentity {
  workspaceId: string;
  sessionId: string;
}

// ─── Errors ───

export class WorkspaceRuntimeError extends Error {
  constructor(
    message: string,
    public readonly code:
      | "SESSION_LIMIT_WORKSPACE"
      | "SESSION_LIMIT_GLOBAL"
      | "SESSION_ALREADY_RESERVED",
  ) {
    super(message);
    this.name = "WorkspaceRuntimeError";
  }
}

// ─── Workspace Runtime ───

/**
 * Concurrency manager for workspace-scoped sessions.
 *
 * Provides per-workspace and per-session mutexes, session slot
 * tracking, and limit enforcement. Does not own process lifecycle —
 * that remains in sessions.ts.
 *
 * Slot lifecycle:
 *   reserveSessionStart() → claim slot (count++)
 *   markSessionReady()    → confirm (noop currently, reserved for metrics)
 *   releaseSession()      → release slot (count--)
 */
export class WorkspaceRuntime {
  private limits: RuntimeLimits;

  /** Per-workspace mutexes (keyed by workspaceId). */
  private workspaceMutexes: Map<string, Mutex> = new Map();

  /** Per-session mutexes (keyed by sessionId). */
  private sessionMutexes: Map<string, Mutex> = new Map();

  /**
   * Active (reserved + ready) session count per workspace.
   * Keyed by workspaceId.
   */
  private workspaceSlots: Map<string, Set<string>> = new Map();

  constructor(limits?: Partial<RuntimeLimits>) {
    this.limits = { ...DEFAULTS, ...limits };
  }

  // ─── Config ───

  getLimits(): Readonly<RuntimeLimits> {
    return this.limits;
  }

  // ─── Locks ───

  /**
   * Execute fn under the per-session mutex.
   * Prevents concurrent start/stop/resume on the same session.
   */
  async withSessionLock<T>(sessionId: string, fn: () => Promise<T>): Promise<T> {
    const key = sessionId;
    let mutex = this.sessionMutexes.get(key);
    if (!mutex) {
      mutex = new Mutex();
      this.sessionMutexes.set(key, mutex);
    }
    return mutex.withLock(fn);
  }

  /**
   * Execute fn under the per-workspace mutex.
   * Serializes workspace-level operations that should not race.
   */
  async withWorkspaceLock<T>(workspaceId: string, fn: () => Promise<T>): Promise<T> {
    const key = workspaceId;
    let mutex = this.workspaceMutexes.get(key);
    if (!mutex) {
      mutex = new Mutex();
      this.workspaceMutexes.set(key, mutex);
    }
    return mutex.withLock(fn);
  }

  // ─── Slot Tracking ───

  /**
   * Reserve a session slot. Checks limits and throws if exceeded.
   * Must be called inside withWorkspaceLock.
   *
   * @throws WorkspaceRuntimeError if limits are exceeded or session already reserved.
   */
  reserveSessionStart(identity: WorkspaceSessionIdentity): void {
    const wsKey = identity.workspaceId;

    // Check if already reserved (shouldn't happen in normal flow)
    const slots = this.workspaceSlots.get(wsKey);
    if (slots?.has(identity.sessionId)) {
      throw new WorkspaceRuntimeError(
        `Session ${identity.sessionId} already reserved in workspace ${identity.workspaceId}`,
        "SESSION_ALREADY_RESERVED",
      );
    }

    // Check workspace limit
    const wsCount = slots?.size ?? 0;
    if (wsCount >= this.limits.maxSessionsPerWorkspace) {
      throw new WorkspaceRuntimeError(
        `Workspace session limit reached (${this.limits.maxSessionsPerWorkspace})`,
        "SESSION_LIMIT_WORKSPACE",
      );
    }

    // Check global limit
    const globalCount = this.globalSessionCount;
    if (globalCount >= this.limits.maxSessionsGlobal) {
      throw new WorkspaceRuntimeError(
        `Global session limit reached (${this.limits.maxSessionsGlobal})`,
        "SESSION_LIMIT_GLOBAL",
      );
    }

    // Reserve the slot
    if (!slots) {
      this.workspaceSlots.set(wsKey, new Set([identity.sessionId]));
    } else {
      slots.add(identity.sessionId);
    }
  }

  /**
   * Mark a reserved session as ready.
   * Currently a noop — reserved for future metrics/state transitions.
   */
  markSessionReady(_identity: WorkspaceSessionIdentity): void {
    // Slot was already counted in reserveSessionStart.
    // Future: track reserved→ready transition for diagnostics.
  }

  /**
   * Release a session slot. Safe to call multiple times.
   * Must be called when a session stops, errors, or fails to start.
   */
  releaseSession(identity: WorkspaceSessionIdentity): void {
    const wsKey = identity.workspaceId;
    const slots = this.workspaceSlots.get(wsKey);
    if (slots) {
      slots.delete(identity.sessionId);
      if (slots.size === 0) {
        this.workspaceSlots.delete(wsKey);
      }
    }
  }

  // ─── Queries ───

  /** Count active sessions in a specific workspace. */
  getWorkspaceSessionCount(workspaceId: string): number {
    return this.workspaceSlots.get(workspaceId)?.size ?? 0;
  }

  /** Count all active sessions across all workspaces. */
  get globalSessionCount(): number {
    let count = 0;
    for (const slots of this.workspaceSlots.values()) {
      count += slots.size;
    }
    return count;
  }

  /** Method alias for globalSessionCount (used by session-limits tests). */
  getGlobalSessionCount(): number {
    return this.globalSessionCount;
  }
}

import { randomUUID } from "node:crypto";

import {
  type ProviderAuthFlowSnapshot,
  type ProviderAuthFlowStatus,
  type ProviderAuthFlowType,
  type ProviderAuthInfo,
  type ProviderAuthLaunchMode,
  type ProviderAuthPrompt,
  isTerminalProviderAuthStatus,
} from "./types.js";

export interface Deferred<T> {
  readonly promise: Promise<T>;
  readonly resolve: (value: T | PromiseLike<T>) => void;
  readonly reject: (reason?: unknown) => void;
  readonly isSettled: () => boolean;
}

export function createDeferred<T>(): Deferred<T> {
  let settled = false;
  let resolveFn: ((value: T | PromiseLike<T>) => void) | undefined;
  let rejectFn: ((reason?: unknown) => void) | undefined;

  const promise = new Promise<T>((resolve, reject) => {
    resolveFn = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    rejectFn = (reason) => {
      if (settled) return;
      settled = true;
      reject(reason);
    };
  });

  return {
    promise,
    resolve(value) {
      resolveFn?.(value);
    },
    reject(reason) {
      rejectFn?.(reason);
    },
    isSettled() {
      return settled;
    },
  };
}

export interface ProviderAuthFlowRecord {
  readonly flowId: string;
  readonly providerId: string;
  readonly abortController: AbortController;
  readonly flowType: ProviderAuthFlowType;
  readonly launchMode: ProviderAuthLaunchMode;
  /** Server-browser launch state for `server_browser` flows. */
  browserLaunch: "none" | "launching" | "opened";
  promptWaiter?: Deferred<string>;
  manualCodeWaiter?: Deferred<string>;
  expiryTimer?: NodeJS.Timeout;
  snapshot: ProviderAuthFlowSnapshot;
}

export interface ProviderAuthFlowStoreOptions {
  ttlMs?: number;
  terminalRetentionMs?: number;
  now?: () => number;
}

const DEFAULT_TTL_MS = 10 * 60 * 1000;
const DEFAULT_TERMINAL_RETENTION_MS = 5 * 60 * 1000;

function cloneSnapshot(snapshot: ProviderAuthFlowSnapshot): ProviderAuthFlowSnapshot {
  return {
    ...snapshot,
    auth: snapshot.auth ? { ...snapshot.auth } : undefined,
    prompt: snapshot.prompt ? { ...snapshot.prompt } : undefined,
  };
}

export class ProviderAuthFlowStore {
  private readonly now: () => number;
  private readonly ttlMs: number;
  private readonly terminalRetentionMs: number;
  private readonly flows = new Map<string, ProviderAuthFlowRecord>();

  constructor(options: ProviderAuthFlowStoreOptions = {}) {
    this.ttlMs = options.ttlMs ?? DEFAULT_TTL_MS;
    this.terminalRetentionMs = options.terminalRetentionMs ?? DEFAULT_TERMINAL_RETENTION_MS;
    this.now = options.now ?? (() => Date.now());
  }

  create(
    providerId: string,
    flowType: ProviderAuthFlowType,
    launchMode: ProviderAuthLaunchMode,
  ): ProviderAuthFlowRecord {
    this.prune();

    const now = this.now();
    const flowId = `pa_${randomUUID().replace(/-/g, "")}`;

    const snapshot: ProviderAuthFlowSnapshot = {
      flowId,
      providerId,
      flowType,
      launchMode,
      status: "pending",
      createdAt: now,
      updatedAt: now,
      expiresAt: now + this.ttlMs,
    };

    const record: ProviderAuthFlowRecord = {
      flowId,
      providerId,
      flowType,
      launchMode,
      abortController: new AbortController(),
      browserLaunch: "none",
      snapshot,
    };

    this.flows.set(flowId, record);
    record.expiryTimer = setTimeout(() => {
      this.settleTerminal(record, "expired", "Flow expired");
    }, this.ttlMs);
    record.expiryTimer.unref();
    return record;
  }

  get(flowId: string): ProviderAuthFlowRecord | undefined {
    this.prune();
    return this.flows.get(flowId);
  }

  getSnapshot(flowId: string): ProviderAuthFlowSnapshot | undefined {
    const record = this.get(flowId);
    return record ? cloneSnapshot(record.snapshot) : undefined;
  }

  findActiveByProvider(providerId: string): ProviderAuthFlowRecord | undefined {
    this.prune();
    for (const record of this.flows.values()) {
      if (record.providerId !== providerId) continue;
      if (isTerminalProviderAuthStatus(record.snapshot.status)) continue;
      return record;
    }
    return undefined;
  }

  update(
    flowId: string,
    updater: (record: ProviderAuthFlowRecord) => void,
  ): ProviderAuthFlowSnapshot | undefined {
    const record = this.get(flowId);
    if (!record) return undefined;

    updater(record);
    record.snapshot.updatedAt = this.now();
    return cloneSnapshot(record.snapshot);
  }

  setAuthInfo(flowId: string, auth: ProviderAuthInfo): ProviderAuthFlowSnapshot | undefined {
    return this.update(flowId, (record) => {
      if (isTerminalProviderAuthStatus(record.snapshot.status)) return;
      record.snapshot.auth = { ...auth };
      if (record.snapshot.status !== "awaiting_prompt") {
        record.snapshot.status = "awaiting_external";
      }
    });
  }

  setPromptWaiter(
    flowId: string,
    prompt: ProviderAuthPrompt,
    waiter: Deferred<string>,
  ): ProviderAuthFlowSnapshot | undefined {
    return this.update(flowId, (record) => {
      if (isTerminalProviderAuthStatus(record.snapshot.status)) return;
      record.promptWaiter = waiter;
      record.snapshot.prompt = { ...prompt };
      record.snapshot.status = "awaiting_prompt";
    });
  }

  clearPromptWaiter(flowId: string): ProviderAuthFlowSnapshot | undefined {
    return this.update(flowId, (record) => {
      record.promptWaiter = undefined;
      record.snapshot.prompt = undefined;
      if (!isTerminalProviderAuthStatus(record.snapshot.status)) {
        record.snapshot.status = "awaiting_external";
      }
    });
  }

  setManualCodeWaiter(
    flowId: string,
    waiter: Deferred<string>,
  ): ProviderAuthFlowSnapshot | undefined {
    return this.update(flowId, (record) => {
      if (isTerminalProviderAuthStatus(record.snapshot.status)) return;
      record.manualCodeWaiter = waiter;
      record.snapshot.status = "awaiting_manual_code";
    });
  }

  clearManualCodeWaiter(flowId: string): ProviderAuthFlowSnapshot | undefined {
    return this.update(flowId, (record) => {
      record.manualCodeWaiter = undefined;
      if (!isTerminalProviderAuthStatus(record.snapshot.status)) {
        record.snapshot.status = "awaiting_external";
      }
    });
  }

  setProgress(flowId: string, message: string): ProviderAuthFlowSnapshot | undefined {
    return this.update(flowId, (record) => {
      if (isTerminalProviderAuthStatus(record.snapshot.status)) return;
      record.snapshot.lastProgress = message;
    });
  }

  markCompleted(flowId: string): ProviderAuthFlowSnapshot | undefined {
    return this.markTerminal(flowId, "completed");
  }

  markFailed(flowId: string, error: string): ProviderAuthFlowSnapshot | undefined {
    return this.markTerminal(flowId, "failed", error);
  }

  markCancelled(flowId: string, reason = "Login cancelled"): ProviderAuthFlowSnapshot | undefined {
    return this.markTerminal(flowId, "cancelled", reason);
  }

  prune(): void {
    const now = this.now();

    for (const [flowId, record] of this.flows.entries()) {
      const ageMs = now - record.snapshot.updatedAt;
      if (
        isTerminalProviderAuthStatus(record.snapshot.status) &&
        ageMs > this.terminalRetentionMs
      ) {
        this.flows.delete(flowId);
        continue;
      }

      if (
        !isTerminalProviderAuthStatus(record.snapshot.status) &&
        record.snapshot.expiresAt <= now
      ) {
        // Mutate the record directly. Going through get()/update() would call
        // prune() again before the status is terminal and recurse forever.
        this.settleTerminal(record, "expired", "Flow expired");
      }
    }
  }

  private markTerminal(
    flowId: string,
    status: ProviderAuthFlowStatus,
    error?: string,
  ): ProviderAuthFlowSnapshot | undefined {
    const record = this.get(flowId);
    if (!record) return undefined;

    this.settleTerminal(record, status, error);
    return cloneSnapshot(record.snapshot);
  }

  /**
   * Moves a live record to a terminal status without re-entering get() or prune().
   * The status is set before waiters reject and the abort signal fires, because
   * abort listeners call back into the store synchronously and must see a
   * terminal record.
   */
  private settleTerminal(
    record: ProviderAuthFlowRecord,
    status: ProviderAuthFlowStatus,
    error?: string,
  ): void {
    if (isTerminalProviderAuthStatus(record.snapshot.status)) return;

    clearTimeout(record.expiryTimer);
    record.expiryTimer = undefined;
    record.snapshot.status = status;
    record.snapshot.error = error;
    record.snapshot.prompt = undefined;
    record.snapshot.lastProgress = undefined;
    record.snapshot.updatedAt = this.now();

    this.rejectWaiters(record, error ?? "Flow terminated");
    if (status !== "completed") {
      record.abortController.abort();
    }
  }

  private rejectWaiters(record: ProviderAuthFlowRecord, message: string): void {
    if (record.promptWaiter && !record.promptWaiter.isSettled()) {
      record.promptWaiter.reject(new Error(message));
    }
    if (record.manualCodeWaiter && !record.manualCodeWaiter.isSettled()) {
      record.manualCodeWaiter.reject(new Error(message));
    }
    record.promptWaiter = undefined;
    record.manualCodeWaiter = undefined;
  }
}

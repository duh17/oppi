/**
 * Per-backend runtime transaction.
 *
 * Shared permits cover model-turn admission only: caller-visible projection and
 * Pi preflight acceptance happen while lifecycle replacement is excluded.
 * Exclusive permits serialize managed model mutations, reload, session-file
 * replacement, queue CAS, abort/stop, and dispose. Waiting exclusive work
 * blocks later shared permits so reload/stop cannot be starved by new turns.
 */

export type SessionRuntimeTransactionMode = "shared" | "exclusive";

export interface SessionRuntimeTransactionPermit {
  readonly mode: SessionRuntimeTransactionMode;
}

type Waiter = {
  mode: SessionRuntimeTransactionMode;
  resolve: (permit: SessionRuntimeTransactionPermit) => void;
  reject: (error: Error) => void;
};

export class SessionRuntimeTransaction {
  private activeShared = 0;
  private activeExclusive = false;
  private readonly waiters: Waiter[] = [];
  private activePermits = new WeakMap<object, SessionRuntimeTransactionMode>();
  private poisonError: Error | undefined;
  private resolvePoison!: (error: Error) => void;
  private readonly poisonCompletion = new Promise<Error>((resolve) => {
    this.resolvePoison = resolve;
  });

  get isExclusiveActive(): boolean {
    return this.activeExclusive;
  }

  get hasActivePermits(): boolean {
    return this.activeExclusive || this.activeShared > 0;
  }

  /**
   * Invalidate every active/queued permit after the runtime has been detached.
   * Late owners may still settle, but their stale permits can no longer retain
   * or re-enter the disposed runtime transaction.
   */
  poison(error: Error): void {
    if (this.poisonError) return;
    this.poisonError = error;
    this.activeShared = 0;
    this.activeExclusive = false;
    this.activePermits = new WeakMap();
    const waiters = this.waiters.splice(0);
    for (const waiter of waiters) waiter.reject(error);
    this.resolvePoison(error);
  }

  async withShared<T>(
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T> {
    const permit = await this.acquire("shared");
    try {
      return await this.runActiveOperation(permit, operation);
    } finally {
      this.release(permit);
    }
  }

  async withExclusive<T>(
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T> {
    const permit = await this.acquire("exclusive");
    try {
      return await this.runActiveOperation(permit, operation);
    } finally {
      this.release(permit);
    }
  }

  async tryWithShared<T>(
    unavailableMessage: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T> {
    if (this.poisonError) throw this.poisonError;
    const permit = this.tryAcquireShared();
    if (!permit) throw new Error(unavailableMessage);
    try {
      return await this.runActiveOperation(permit, operation);
    } finally {
      this.release(permit);
    }
  }

  private async runActiveOperation<T>(
    permit: SessionRuntimeTransactionPermit,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T> {
    let operationOutcome: Promise<{ kind: "value"; value: T } | { kind: "error"; error: unknown }>;
    try {
      operationOutcome = operation(permit).then(
        (value) => ({ kind: "value" as const, value }),
        (error: unknown) => ({ kind: "error" as const, error }),
      );
    } catch (error: unknown) {
      operationOutcome = Promise.resolve({ kind: "error" as const, error });
    }
    const outcome = await Promise.race([
      operationOutcome,
      this.poisonCompletion.then((error) => ({ kind: "poison" as const, error })),
    ]);
    if (outcome.kind === "value") return outcome.value;
    throw outcome.error;
  }

  assertPermit(
    permit: SessionRuntimeTransactionPermit,
    requiredMode: SessionRuntimeTransactionMode,
  ): void {
    const mode = this.activePermits.get(permit as object);
    if (!mode || (requiredMode === "exclusive" && mode !== "exclusive")) {
      throw new Error(`Invalid ${requiredMode} session runtime transaction permit`);
    }
  }

  private acquire(mode: SessionRuntimeTransactionMode): Promise<SessionRuntimeTransactionPermit> {
    if (this.poisonError) return Promise.reject(this.poisonError);
    if (mode === "shared") {
      const permit = this.tryAcquireShared();
      if (permit) return Promise.resolve(permit);
    } else if (!this.activeExclusive && this.activeShared === 0 && this.waiters.length === 0) {
      return Promise.resolve(this.activate("exclusive"));
    }

    return new Promise((resolve, reject) => {
      this.waiters.push({ mode, resolve, reject });
    });
  }

  private tryAcquireShared(): SessionRuntimeTransactionPermit | null {
    if (this.activeExclusive || this.waiters.length > 0) return null;
    return this.activate("shared");
  }

  private activate(mode: SessionRuntimeTransactionMode): SessionRuntimeTransactionPermit {
    const permit = Object.freeze({ mode });
    this.activePermits.set(permit, mode);
    if (mode === "exclusive") this.activeExclusive = true;
    else this.activeShared += 1;
    return permit;
  }

  private release(permit: SessionRuntimeTransactionPermit): void {
    const mode = this.activePermits.get(permit as object);
    if (!mode) {
      if (this.poisonError) return;
      throw new Error("Session runtime transaction permit was already released");
    }
    this.activePermits.delete(permit as object);
    if (mode === "exclusive") this.activeExclusive = false;
    else this.activeShared = Math.max(0, this.activeShared - 1);
    this.drain();
  }

  private drain(): void {
    if (this.activeExclusive || this.activeShared > 0) return;
    const first = this.waiters[0];
    if (!first) return;

    if (first.mode === "exclusive") {
      this.waiters.shift();
      first.resolve(this.activate("exclusive"));
      return;
    }

    while (this.waiters[0]?.mode === "shared") {
      const waiter = this.waiters.shift();
      waiter?.resolve(this.activate("shared"));
    }
  }
}

import { describe, expect, it, vi } from "vitest";
import { EventRing } from "../src/event-ring.js";
import { QUEUE_RECONCILIATION_REQUIRED_ERROR, SdkBackend } from "../src/sdk-backend.js";
import { SdkUiBridge } from "../src/sdk-ui-bridge.js";
import { SessionManager } from "../src/sessions.js";
import {
  SessionRuntimeTransaction,
  type SessionRuntimeTransactionPermit,
} from "../src/session-runtime-transaction.js";
import type { SessionStopTimers } from "../src/session-stop.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { Storage } from "../src/storage.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";
import type { WorkspaceRuntime } from "../src/workspace-runtime.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-server-tests",
  sessionIdleTimeoutMs: 600_000,
  workspaceIdleTimeoutMs: 1_800_000,
  maxSessionsPerWorkspace: 3,
  maxSessionsGlobal: 5,
};

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (error: unknown) => void;
} {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function flushMicrotasks(turns = 6): Promise<void> {
  for (let turn = 0; turn < turns; turn += 1) await Promise.resolve();
}

function installRuntimeTransactionHarness(
  sdkBackend: ReturnType<typeof makeSdkBackendStub>["sdkBackend"],
  abort: ReturnType<typeof vi.fn>,
  dispose: ReturnType<typeof vi.fn>,
): SessionRuntimeTransaction {
  const transaction = new SessionRuntimeTransaction();
  sdkBackend.withRuntimeLifecycleTransaction = vi.fn(
    (_name: string, operation: (permit: SessionRuntimeTransactionPermit) => Promise<unknown>) =>
      transaction.withExclusive(operation),
  );
  sdkBackend.abort = vi.fn((permit?: SessionRuntimeTransactionPermit) => {
    if (permit) {
      transaction.assertPermit(permit, "exclusive");
      return abort();
    }
    return transaction.withExclusive(() => abort());
  });
  sdkBackend.dispose = vi.fn((permit?: SessionRuntimeTransactionPermit) => {
    if (permit) {
      transaction.assertPermit(permit, "exclusive");
      return dispose();
    }
    return transaction.withExclusive(() => dispose());
  });
  Object.defineProperty(sdkBackend, "isRuntimeLifecycleTransactionExclusive", {
    configurable: true,
    get: () => transaction.isExclusiveActive,
  });
  return transaction;
}

class ManualStopTimers implements SessionStopTimers {
  private readonly scheduled: Array<{
    callback: () => void;
    timeoutMs: number;
    handle: NodeJS.Timeout;
  }> = [];

  setTimeout(callback: () => void, timeoutMs: number): NodeJS.Timeout {
    const handle = {} as NodeJS.Timeout;
    this.scheduled.push({ callback, timeoutMs, handle });
    return handle;
  }

  clearTimeout(handle: NodeJS.Timeout): void {
    const index = this.scheduled.findIndex((timer) => timer.handle === handle);
    if (index !== -1) this.scheduled.splice(index, 1);
  }

  fire(timeoutMs: number): void {
    const index = this.scheduled.findIndex((timer) => timer.timeoutMs === timeoutMs);
    if (index === -1) throw new Error(`No ${timeoutMs}ms stop timer is scheduled`);
    const [timer] = this.scheduled.splice(index, 1);
    timer?.callback();
  }
}

function makeNeverResolvingShutdownBackend(): {
  backend: SdkBackend;
  runtimeDispose: ReturnType<typeof vi.fn>;
  forceDispose: ReturnType<typeof vi.fn>;
} {
  const backend = Object.create(SdkBackend.prototype) as SdkBackend;
  const forceDispose = vi.fn();
  const runtimeDispose = vi.fn(() => new Promise<void>(() => {}));
  Object.assign(backend as unknown as Record<string, unknown>, {
    disposed: false,
    oppiSessionId: "s1",
    runtime: {
      dispose: runtimeDispose,
      session: {
        sessionId: "pi-session-1",
        dispose: forceDispose,
        abortBash: vi.fn(),
      },
    },
    uiBridge: { dispose: vi.fn() },
    unsub: vi.fn(),
    shutdownCleanupPromise: null,
  });
  return { backend, runtimeDispose, forceDispose };
}

function makeNeverResolvingReloadBackend(): {
  backend: SdkBackend;
  finishShutdown: () => void;
  forceDispose: ReturnType<typeof vi.fn>;
  lateReloadFinished: Promise<void>;
  reload: ReturnType<typeof vi.fn>;
  runtimeDispose: ReturnType<typeof vi.fn>;
  zombieRuntimeIsActive: () => boolean;
} {
  const backend = Object.create(SdkBackend.prototype) as SdkBackend;
  const shutdown = deferred<void>();
  const lateReload = deferred<void>();
  let zombieRuntimeActive = false;
  const forceDispose = vi.fn(() => {
    zombieRuntimeActive = false;
  });
  const reload = vi.fn(async () => {
    await shutdown.promise;
    // Pi rebuilds extension resources after session_shutdown settles. A late
    // continuation must be detached from Oppi state and disposed again.
    zombieRuntimeActive = true;
    lateReload.resolve();
  });
  const runtimeDispose = vi.fn(async () => undefined);
  Object.assign(backend as unknown as Record<string, unknown>, {
    disposed: false,
    oppiSessionId: "s1",
    runtime: {
      dispose: runtimeDispose,
      session: {
        sessionId: "pi-session-1",
        isStreaming: false,
        isCompacting: false,
        reload,
        dispose: forceDispose,
        abortBash: vi.fn(),
        extensionRunner: { getAllRegisteredTools: () => [] },
      },
    },
    uiBridge: { dispose: vi.fn() },
    unsub: vi.fn(),
    shutdownCleanupPromise: null,
  });
  return {
    backend,
    finishShutdown: () => shutdown.resolve(),
    forceDispose,
    lateReloadFinished: lateReload.promise,
    reload,
    runtimeDispose,
    zombieRuntimeIsActive: () => zombieRuntimeActive,
  };
}

function makeNeverResolvingReplacementBackend(method: "newSession" | "fork"): {
  backend: SdkBackend;
  finishShutdown: () => void;
  oldSessionDispose: ReturnType<typeof vi.fn>;
  replacementSessionDispose: ReturnType<typeof vi.fn>;
  replacementSettled: Promise<void>;
} {
  const backend = Object.create(SdkBackend.prototype) as SdkBackend;
  const shutdown = deferred<void>();
  const replacementFinished = deferred<void>();
  const makeRuntimeSession = (dispose: ReturnType<typeof vi.fn>) => ({
    sessionFile: "/tmp/current.jsonl",
    isStreaming: false,
    isCompacting: false,
    dispose,
    abortBash: vi.fn(),
    abort: vi.fn(async () => undefined),
    subscribe: vi.fn(() => vi.fn()),
    bindExtensions: vi.fn(async () => undefined),
    extensionRunner: { getAllRegisteredTools: () => [] },
  });
  const oldSessionDispose = vi.fn();
  const replacementSessionDispose = vi.fn();
  const oldSession = makeRuntimeSession(oldSessionDispose);
  const replacementSession = makeRuntimeSession(replacementSessionDispose);
  const runtime = {
    session: oldSession,
    dispose: vi.fn(async () => undefined),
    newSession: vi.fn(async () => {
      await shutdown.promise;
      runtime.session = replacementSession;
      replacementFinished.resolve();
      return { cancelled: false };
    }),
    fork: vi.fn(async () => {
      await shutdown.promise;
      runtime.session = replacementSession;
      replacementFinished.resolve();
      return { cancelled: false, selectedText: "forked" };
    }),
  };
  Object.assign(backend as unknown as Record<string, unknown>, {
    disposed: false,
    oppiSessionId: "s1",
    runtime,
    emitEvent: vi.fn(),
    uiBridge: { createContext: vi.fn(() => ({})), dispose: vi.fn() },
    unsub: vi.fn(),
    shutdownCleanupPromise: null,
  });

  const selectedRuntimeCall = runtime[method];
  if (!selectedRuntimeCall) throw new Error(`Missing runtime replacement method: ${method}`);

  return {
    backend,
    finishShutdown: () => shutdown.resolve(),
    oldSessionDispose,
    replacementSessionDispose,
    replacementSettled: replacementFinished.promise,
  };
}

function makeNeverResolvingPreflightBackend(): {
  backend: SdkBackend;
  acceptPreflight: () => void;
  forceDispose: ReturnType<typeof vi.fn>;
  promptEntered: Promise<void>;
} {
  const backend = Object.create(SdkBackend.prototype) as SdkBackend;
  const preflight = deferred<void>();
  const entered = deferred<void>();
  const forceDispose = vi.fn();
  const prompt = vi.fn(
    async (
      _message: string,
      options?: { preflightResult?: (success: boolean) => void },
    ): Promise<void> => {
      entered.resolve();
      await preflight.promise;
      options?.preflightResult?.(true);
    },
  );
  Object.assign(backend as unknown as Record<string, unknown>, {
    disposed: false,
    oppiSessionId: "s1",
    emitEvent: vi.fn(),
    runtime: {
      dispose: vi.fn(async () => undefined),
      session: {
        sessionId: "pi-session-1",
        sessionFile: "/tmp/current.jsonl",
        isStreaming: false,
        isCompacting: false,
        prompt,
        dispose: forceDispose,
        abortBash: vi.fn(),
        extensionRunner: { getAllRegisteredTools: () => [] },
      },
    },
    uiBridge: { dispose: vi.fn() },
    unsub: vi.fn(),
    shutdownCleanupPromise: null,
  });
  return {
    backend,
    acceptPreflight: () => preflight.resolve(),
    forceDispose,
    promptEntered: entered.promise,
  };
}

function makeSession(status: Session["status"] = "busy"): Session {
  const now = Date.now();
  return {
    id: "s1",
    workspaceId: "w1",
    status,
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeManagerHarness(status: Session["status"] = "busy", stopTimers?: SessionStopTimers) {
  const saveSession = vi.fn();
  const storage = {
    getConfig: () => TEST_CONFIG,
    getDataDir: vi.fn(() => TEST_CONFIG.dataDir),
    saveSession,
    getWorkspace: vi.fn(() => undefined),
  } as unknown as Storage;

  const manager = new SessionManager(storage, undefined, stopTimers);

  (manager as { resetIdleTimer: (key: string) => void }).resetIdleTimer = () => {};

  const { sdkBackend, abort, dispose, prompt } = makeSdkBackendStub();
  const session = makeSession(status);

  const active = {
    session,
    sdkBackend,
    workspaceId: "w1",
    subscribers: new Set<(msg: ServerMessage) => void>(),
    pendingUIRequests: new Map(),
    partialResults: new Map(),
    streamedAssistantText: "",
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    seq: 0,
    eventRing: new EventRing(),
  };

  const key = session.id;
  (manager as unknown as { active: Map<string, unknown> }).active.set(key, active);

  const events: ServerMessage[] = [];
  manager.subscribe(session.id, (msg) => {
    events.push(msg);
  });

  return { manager, active, events, session, sdkBackend, abort, dispose, prompt, saveSession };
}

describe("stop lifecycle", () => {
  it("confirms stop immediately when session is already idle", async () => {
    const { manager, events, abort, session } = makeManagerHarness("ready");

    await manager.sendAbort("s1");

    expect(abort).not.toHaveBeenCalled();
    expect(session.status).toBe("ready");

    const confirmed = events.find(
      (event): event is Extract<ServerMessage, { type: "stop_confirmed" }> =>
        event.type === "stop_confirmed",
    );
    expect(confirmed?.source).toBe("user");
    expect(confirmed?.reason).toBe("Session already idle");
    expect(events.some((event) => event.type === "stop_failed")).toBe(false);
  });

  it("rechecks idle state after waiting for the runtime lifecycle transaction", async () => {
    const { manager, events, abort, session, sdkBackend } = makeManagerHarness("busy");
    let releaseTransaction!: () => void;
    const transactionGate = new Promise<void>((resolve) => {
      releaseTransaction = resolve;
    });
    sdkBackend.withRuntimeLifecycleTransaction = vi.fn(
      async (_name: string, operation: (permit: { mode: "exclusive" }) => Promise<unknown>) => {
        await transactionGate;
        return operation({ mode: "exclusive" });
      },
    );

    const stop = manager.sendAbort("s1");
    await Promise.resolve();
    session.status = "ready";
    releaseTransaction();
    await stop;

    expect(abort).not.toHaveBeenCalled();
    expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(0);
    expect(events.filter((event) => event.type === "stop_confirmed")).toEqual([
      expect.objectContaining({ source: "user", reason: "Session already idle" }),
    ]);
  });

  it("dedupes duplicate stop taps while graceful stop is pending", async () => {
    const { manager, events, abort, session } = makeManagerHarness("busy");
    const active = { session };

    await manager.sendAbort("s1");
    await manager.sendAbort("s1");

    expect(abort).toHaveBeenCalledTimes(1);
    const stopRequested = events.filter((event) => event.type === "stop_requested");
    expect(stopRequested).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);
    expect(active.session.status).toBe("stopping");
  });

  it("settles backend abort rejection without an orphan timeout and permits a later abort", async () => {
    vi.useFakeTimers();
    try {
      const { manager, active, events, abort, session } = makeManagerHarness("busy");
      abort.mockRejectedValueOnce(new Error("backend abort rejected"));

      await expect(manager.sendAbort("s1")).rejects.toThrow("backend abort rejected");

      expect(active.pendingStop).toBeUndefined();
      expect(session.status).toBe("busy");
      expect(abort).toHaveBeenCalledOnce();
      expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(1);
      expect(events.filter((event) => event.type === "stop_failed")).toEqual([
        expect.objectContaining({
          source: "server",
          reason: "Abort failed: backend abort rejected",
        }),
      ]);
      expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);

      vi.runAllTimers();
      await Promise.resolve();
      expect(abort).toHaveBeenCalledOnce();
      expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);

      await manager.sendAbort("s1");
      await manager.sendAbort("s1");
      expect(abort).toHaveBeenCalledTimes(2);
      expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);

      (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
        "s1",
        { type: "agent_end" },
      );
      expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(1);
      expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("supervises a never-resolving abort without retaining the runtime permit forever", async () => {
    const timers = new ManualStopTimers();
    const { manager, active, events, sdkBackend, abort, dispose, session } = makeManagerHarness(
      "busy",
      timers,
    );
    const abortCompletion = deferred<void>();
    abort.mockImplementation(() => abortCompletion.promise);
    const transaction = installRuntimeTransactionHarness(sdkBackend, abort, dispose);

    let settled = false;
    const stop = manager.sendAbort("s1").finally(() => {
      settled = true;
    });
    await flushMicrotasks();

    expect(transaction.isExclusiveActive).toBe(true);
    expect(abort).toHaveBeenCalledOnce();

    timers.fire((manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs);
    timers.fire(
      (manager as unknown as { stopAbortRetryTimeoutMs: number }).stopAbortRetryTimeoutMs,
    );
    await flushMicrotasks(20);

    expect(settled).toBe(true);
    expect(transaction.isExclusiveActive).toBe(false);
    expect(active.pendingStop).toBeUndefined();
    expect(session.status).toBe("busy");
    expect(abort).toHaveBeenCalledOnce();
    expect(dispose).not.toHaveBeenCalled();
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);
    await stop;

    abortCompletion.reject(new Error("late abort rejection"));
    await flushMicrotasks();
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);
  });

  it("restores acknowledged steering and follow-up intent when abort rejects", async () => {
    const { manager, active, events, abort, session } = makeManagerHarness("busy");
    await manager.sendSteer("s1", "keep steering", { clientTurnId: "steer-1" });
    await manager.sendFollowUp("s1", "keep follow-up", { clientTurnId: "follow-1" });
    const before = manager.getMessageQueue("s1");
    abort.mockRejectedValueOnce(new Error("abort submission rejected"));

    await expect(manager.sendAbort("s1")).rejects.toThrow("abort submission rejected");

    expect(active.pendingStop).toBeUndefined();
    expect(session.status).toBe("busy");
    expect(manager.getMessageQueue("s1")).toMatchObject({
      steering: before.steering,
      followUp: before.followUp,
    });
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);
  });

  it("gates all admissions after abort rollback failure until CAS recovery completes", async () => {
    const { manager, active, events, session, sdkBackend, abort, prompt } =
      makeManagerHarness("busy");
    await manager.sendSteer("s1", "recover steering", { clientTurnId: "steer-recover" });
    await manager.sendFollowUp("s1", "recover follow-up", { clientTurnId: "follow-recover" });
    const before = manager.getMessageQueue("s1");
    const replaceQueue = vi.mocked(sdkBackend.replaceQueuedModelTurns);
    const replayQueue = replaceQueue.getMockImplementation();
    if (!replayQueue) throw new Error("Expected queue replay test implementation");
    abort.mockRejectedValueOnce(new Error("abort rejected"));
    replaceQueue.mockRejectedValueOnce(new Error("abort queue rollback rejected"));

    await expect(manager.sendAbort("s1")).rejects.toThrow("abort rejected");

    expect(() => manager.getMessageQueue("s1")).toThrow(QUEUE_RECONCILIATION_REQUIRED_ERROR);
    const restoredState = events
      .filter(
        (event): event is Extract<ServerMessage, { type: "queue_state" }> =>
          event.type === "queue_state",
      )
      .at(-1);
    expect(restoredState).toMatchObject({
      queue: {
        steering: before.steering,
        followUp: before.followUp,
      },
    });
    const recoveryVersion = restoredState?.queue.version;
    if (recoveryVersion === undefined) throw new Error("Expected preserved recovery version");
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);

    prompt.mockClear();
    session.status = "ready";
    (sdkBackend as unknown as { isStreaming: boolean }).isStreaming = false;
    await expect(
      manager.sendPrompt("s1", "blocked prompt", { clientTurnId: "blocked-prompt" }),
    ).rejects.toThrow(QUEUE_RECONCILIATION_REQUIRED_ERROR);

    session.status = "busy";
    (sdkBackend as unknown as { isStreaming: boolean }).isStreaming = true;
    const blockedStreamingAdmissions = [
      () =>
        manager.sendPrompt("s1", "blocked prompt steer", {
          streamingBehavior: "steer",
          clientTurnId: "blocked-prompt-steer",
        }),
      () =>
        manager.sendPrompt("s1", "blocked prompt follow-up", {
          streamingBehavior: "followUp",
          clientTurnId: "blocked-prompt-follow",
        }),
      () => manager.sendSteer("s1", "blocked steer", { clientTurnId: "blocked-steer" }),
      () => manager.sendFollowUp("s1", "blocked follow-up", { clientTurnId: "blocked-follow" }),
    ];
    for (const admission of blockedStreamingAdmissions) {
      await expect(admission()).rejects.toThrow(QUEUE_RECONCILIATION_REQUIRED_ERROR);
    }

    expect(prompt).not.toHaveBeenCalled();
    expect(session.messages).toBeUndefined();
    expect(session.messageCount).toBe(0);
    for (const clientTurnId of [
      "blocked-prompt",
      "blocked-prompt-steer",
      "blocked-prompt-follow",
      "blocked-steer",
      "blocked-follow",
    ]) {
      expect(active.turnCache.get(clientTurnId)).toBeNull();
    }
    expect(replaceQueue).toHaveBeenCalledOnce();

    await expect(
      manager.setMessageQueue("s1", {
        baseVersion: recoveryVersion - 1,
        steering: before.steering,
        followUp: before.followUp,
      }),
    ).rejects.toThrow(`Queue version mismatch: expected ${recoveryVersion}`);
    expect(replaceQueue).toHaveBeenCalledOnce();

    const recoveryEntered = deferred<void>();
    const releaseRecovery = deferred<void>();
    replaceQueue.mockImplementationOnce(async (...args) => {
      recoveryEntered.resolve();
      await releaseRecovery.promise;
      return replayQueue(...args);
    });
    const recovery = manager.setMessageQueue("s1", {
      baseVersion: recoveryVersion,
      steering: before.steering,
      followUp: before.followUp,
    });
    await recoveryEntered.promise;

    await expect(
      manager.sendSteer("s1", "racing steer", { clientTurnId: "blocked-racing-steer" }),
    ).rejects.toThrow(QUEUE_RECONCILIATION_REQUIRED_ERROR);
    expect(active.turnCache.get("blocked-racing-steer")).toBeNull();
    expect(prompt).not.toHaveBeenCalled();

    releaseRecovery.resolve();
    await expect(recovery).resolves.toMatchObject({
      version: recoveryVersion + 1,
      steering: before.steering,
      followUp: before.followUp,
    });
    expect(sdkBackend.session.getSteeringMessages()).toEqual(["recover steering"]);
    expect(sdkBackend.session.getFollowUpMessages()).toEqual(["recover follow-up"]);
    expect(manager.getMessageQueue("s1")).toMatchObject({
      version: recoveryVersion + 1,
      steering: before.steering,
      followUp: before.followUp,
    });

    session.status = "ready";
    (sdkBackend as unknown as { isStreaming: boolean }).isStreaming = false;
    await expect(
      manager.sendPrompt("s1", "admitted after recovery", { clientTurnId: "after-recovery" }),
    ).resolves.toBeUndefined();
    expect(prompt).toHaveBeenCalledOnce();
    expect(active.turnCache.get("after-recovery")?.stage).toBe("dispatched");
  });

  it("coalesces duplicate rejected aborts and allows one later retry", async () => {
    const { manager, active, events, abort } = makeManagerHarness("busy");
    const rejection = deferred<void>();
    abort.mockImplementationOnce(() => rejection.promise);

    const first = manager.sendAbort("s1");
    await flushMicrotasks();
    const duplicate = manager.sendAbort("s1");
    rejection.reject(new Error("abort rejected once"));

    await expect(first).rejects.toThrow("abort rejected once");
    await expect(duplicate).rejects.toThrow("abort rejected once");
    expect(abort).toHaveBeenCalledOnce();
    expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    expect(active.pendingStop).toBeUndefined();

    await manager.sendAbort("s1");
    expect(abort).toHaveBeenCalledTimes(2);
    expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(2);
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
  });

  it("escalates abort timeout without starting a concurrent Pi abort", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, abort, session } = makeManagerHarness("busy");

      await manager.sendAbort("s1");

      // Phase 1 retries the process interrupt without starting another Pi
      // operation while the accepted abort is still pending.
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs,
      );

      expect(abort).toHaveBeenCalledTimes(1);

      // Should broadcast a stop_requested from server about the interrupt
      const interruptRequested = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_requested" }> =>
          event.type === "stop_requested" && event.source === "server",
      );
      expect(interruptRequested).toBeTruthy();

      // Session should still be alive
      expect(manager.isActive("s1")).toBe(true);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);

      // Phase 2: after stopAbortRetryTimeoutMs, gives up but keeps session alive
      await vi.advanceTimersByTimeAsync(
        (manager as unknown as { stopAbortRetryTimeoutMs: number }).stopAbortRetryTimeoutMs,
      );

      const failed = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_failed" }> =>
          event.type === "stop_failed",
      );
      expect(failed).toBeTruthy();

      // Session stays alive — user can send another message or stop session explicitly
      expect(manager.isActive("s1")).toBe(true);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);
      expect(session.status).toBe("busy"); // restored from "stopping"
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("abort succeeds after interrupt escalation before second timeout", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, abort } = makeManagerHarness("busy");
      const key = "s1";

      await manager.sendAbort("s1");

      // Phase 1 timeout retries only the process interrupt.
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs,
      );
      expect(abort).toHaveBeenCalledTimes(1);

      // Agent responds with agent_end after abort interrupts the tool
      (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
        key,
        { type: "agent_end" },
      );

      const confirmed = events.filter((event) => event.type === "stop_confirmed");
      expect(confirmed).toHaveLength(1);
      expect(manager.isActive("s1")).toBe(true);

      // Phase 2 timeout should be a no-op since abort already succeeded
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortRetryTimeoutMs: number }).stopAbortRetryTimeoutMs,
      );

      expect(events.some((event) => event.type === "stop_failed")).toBe(false);
      expect(events.some((event) => event.type === "session_ended")).toBe(false);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("abort also kills running bash processes", async () => {
    const { manager, sdkBackend } = makeManagerHarness("busy");

    await manager.sendAbort("s1");

    expect(sdkBackend.session.abortBash).toHaveBeenCalledTimes(1);
  });

  it("abort escalation retries abortBash alongside abort", async () => {
    vi.useFakeTimers();
    try {
      const { manager, sdkBackend } = makeManagerHarness("busy");

      await manager.sendAbort("s1");
      expect(sdkBackend.session.abortBash).toHaveBeenCalledTimes(1);

      // Phase 1 timeout: escalation should call abortBash again
      vi.advanceTimersByTime(
        (manager as unknown as { stopAbortTimeoutMs: number }).stopAbortTimeoutMs,
      );
      expect(sdkBackend.session.abortBash).toHaveBeenCalledTimes(2);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("confirms graceful stop after tool loop drains to agent_end", async () => {
    const { manager, events, session } = makeManagerHarness("busy");
    const key = "s1";

    await manager.sendAbort("s1");

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      {
        type: "tool_execution_start",
        toolName: "bash",
        args: { command: "echo test" },
        toolCallId: "tc-1",
      },
    );

    expect(session.status).toBe("stopping");

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "agent_end" },
    );

    const confirmed = events.filter((event) => event.type === "stop_confirmed");
    expect(confirmed).toHaveLength(1);
    expect(session.status).toBe("stopping");

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "agent_settled" },
    );

    expect(session.status).toBe("ready");
    expect(events.some((event) => event.type === "stop_failed")).toBe(false);
  });

  it("stopSession waits for agent_end and aborts bash before terminating", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, sdkBackend, abort, dispose } = makeManagerHarness("busy");
      const key = "s1";

      const stopPromise = manager.stopSession("s1");
      await Promise.resolve();
      await Promise.resolve();

      (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
        key,
        { type: "agent_end" },
      );

      await Promise.resolve();
      await stopPromise;

      expect(abort).toHaveBeenCalledTimes(1);
      expect(sdkBackend.session.abortBash).toHaveBeenCalledTimes(1);
      expect(dispose).toHaveBeenCalledTimes(1);
      expect(manager.isActive("s1")).toBe(false);
      expect(events.some((event) => event.type === "session_ended")).toBe(true);

      vi.advanceTimersByTime(
        (manager as unknown as { stopSessionGraceMs: number }).stopSessionGraceMs,
      );
      expect(dispose).toHaveBeenCalledTimes(1);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("clears the terminate deadline as soon as agent_end starts disposal", async () => {
    const timers = new ManualStopTimers();
    const { manager, dispose } = makeManagerHarness("busy", timers);
    const disposal = deferred<{ disposal: "graceful" }>();
    dispose.mockImplementation(() => disposal.promise);

    const stop = manager.stopSession("s1");
    await flushMicrotasks();
    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      "s1",
      { type: "agent_end" },
    );
    await flushMicrotasks();

    expect(dispose).toHaveBeenCalledOnce();
    expect(() =>
      timers.fire((manager as unknown as { stopSessionGraceMs: number }).stopSessionGraceMs),
    ).toThrow("No 1000ms stop timer is scheduled");

    disposal.resolve({ disposal: "graceful" });
    await stop;
    expect(manager.isActive("s1")).toBe(false);
  });

  it("coalesces duplicate terminate requests behind one active stop", async () => {
    const { manager, events, sdkBackend, abort, dispose } = makeManagerHarness("busy");
    const key = "s1";

    const firstStop = manager.stopSession(key);
    for (let turn = 0; turn < 8; turn += 1) await Promise.resolve();
    const duplicateStop = manager.stopSession(key);

    expect(abort).toHaveBeenCalledOnce();
    expect(sdkBackend.session.abortBash).toHaveBeenCalledOnce();

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "agent_end" },
    );
    await Promise.all([firstStop, duplicateStop]);

    expect(dispose).toHaveBeenCalledOnce();
    expect(manager.isActive(key)).toBe(false);
    expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "session_ended")).toHaveLength(1);
  });

  it("coalesces duplicate terminate rejection and permits one later retry", async () => {
    const { manager, active, events, abort, dispose } = makeManagerHarness("busy");
    const rejection = deferred<void>();
    abort.mockImplementationOnce(() => rejection.promise);

    const first = manager.stopSession("s1");
    await flushMicrotasks();
    const duplicate = manager.stopSession("s1");
    rejection.reject(new Error("terminate abort rejected"));

    await expect(first).rejects.toThrow("terminate abort rejected");
    await expect(duplicate).rejects.toThrow("terminate abort rejected");
    expect(abort).toHaveBeenCalledOnce();
    expect(dispose).not.toHaveBeenCalled();
    expect(active.pendingStop).toBeUndefined();
    expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);

    const retry = manager.stopSession("s1");
    await flushMicrotasks();
    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      "s1",
      { type: "agent_end" },
    );
    await retry;

    expect(abort).toHaveBeenCalledTimes(2);
    expect(dispose).toHaveBeenCalledOnce();
    expect(events.filter((event) => event.type === "stop_requested")).toHaveLength(2);
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(1);
  });

  it("ignores late runtime events after stop wins against a subsequent prompt", async () => {
    const { manager, events, session, prompt, saveSession } = makeManagerHarness("busy");
    const key = "s1";

    const stop = manager.stopSession(key);
    await Promise.resolve();
    await Promise.resolve();
    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "agent_end" },
    );
    await stop;

    const persistedAfterStop = saveSession.mock.calls.length;
    const eventsAfterStop = events.length;
    await expect(manager.sendPrompt(key, "too late")).rejects.toThrow("Session not active: s1");

    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "agent_start" },
    );
    (manager as unknown as { handlePiEvent: (key: string, data: unknown) => void }).handlePiEvent(
      key,
      { type: "message_end", message: { role: "assistant", content: "late output" } },
    );

    expect(prompt).not.toHaveBeenCalled();
    expect(manager.isActive(key)).toBe(false);
    expect(session.status).toBe("stopped");
    expect(saveSession).toHaveBeenCalledTimes(persistedAfterStop);
    expect(events).toHaveLength(eventsAfterStop);
  });

  it("releases all ownership and reports failure when normal stop persistence fails", async () => {
    const { manager, active, events, sdkBackend, abort, dispose, saveSession } =
      makeManagerHarness("ready");
    const transaction = installRuntimeTransactionHarness(sdkBackend, abort, dispose);
    const runtimeManager = (
      manager as unknown as {
        stopFlowCoordinator: { deps: { runtimeManager: WorkspaceRuntime } };
      }
    ).stopFlowCoordinator.deps.runtimeManager;
    runtimeManager.reserveSessionStart({ workspaceId: "w1", sessionId: "s1" });
    const persistedStatuses: Session["status"][] = [];
    saveSession.mockImplementation((session: Session) => {
      if (session.status === "stopped") throw new Error("final stop persistence failed");
      persistedStatuses.push(session.status);
    });
    const disposal = deferred<{ disposal: "graceful" }>();
    dispose.mockImplementation(async () => {
      const result = await disposal.promise;
      (sdkBackend as unknown as { isDisposed: boolean }).isDisposed = true;
      return result;
    });

    const firstStop = manager.stopSession("s1");
    await flushMicrotasks();
    const duplicateStop = manager.stopSession("s1");
    expect(dispose).toHaveBeenCalledOnce();
    disposal.resolve({ disposal: "graceful" });
    await Promise.all([firstStop, duplicateStop]);

    let runtimeLockReleased = false;
    await transaction.withExclusive(async () => {
      runtimeLockReleased = true;
    });
    let sessionLockReleased = false;
    await runtimeManager.withSessionLock("s1", async () => {
      sessionLockReleased = true;
    });
    let workspaceLockReleased = false;
    await runtimeManager.withWorkspaceLock("w1", async () => {
      workspaceLockReleased = true;
    });

    expect(dispose).toHaveBeenCalledOnce();
    expect(active.session.status).toBe("stopped");
    expect(persistedStatuses).toEqual(["stopping"]);
    expect(manager.isActive("s1")).toBe(false);
    expect(runtimeManager.getWorkspaceSessionCount("w1")).toBe(0);
    expect({ runtimeLockReleased, sessionLockReleased, workspaceLockReleased }).toEqual({
      runtimeLockReleased: true,
      sessionLockReleased: true,
      workspaceLockReleased: true,
    });
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(0);
    expect(events.filter((event) => event.type === "stop_failed")).toEqual([
      expect.objectContaining({
        source: "server",
        reason: "Failed to persist stopped session: final stop persistence failed",
      }),
    ]);
    expect(events.filter((event) => event.type === "session_ended")).toHaveLength(1);

    const persistedAfterStop = saveSession.mock.calls.length;
    const eventsAfterStop = events.length;
    await manager.stopSession("s1");
    await flushMicrotasks();
    expect(saveSession).toHaveBeenCalledTimes(persistedAfterStop);
    expect(events).toHaveLength(eventsAfterStop);
  });

  it("force-disposes a never-resolving terminate abort with the owned permit", async () => {
    const timers = new ManualStopTimers();
    const { manager, events, sdkBackend, abort, dispose } = makeManagerHarness("busy", timers);
    const abortCompletion = deferred<void>();
    abort.mockImplementation(() => abortCompletion.promise);
    const transaction = installRuntimeTransactionHarness(sdkBackend, abort, dispose);

    let settled = false;
    const stop = manager.stopSession("s1").finally(() => {
      settled = true;
    });
    await flushMicrotasks();
    expect(transaction.isExclusiveActive).toBe(true);
    expect(abort).toHaveBeenCalledOnce();

    timers.fire((manager as unknown as { stopSessionGraceMs: number }).stopSessionGraceMs);
    await flushMicrotasks(40);

    expect(dispose).toHaveBeenCalledOnce();
    expect(settled).toBe(true);
    expect(transaction.isExclusiveActive).toBe(false);
    expect(manager.isActive("s1")).toBe(false);
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "session_ended")).toHaveLength(1);
    await stop;

    abortCompletion.reject(new Error("late terminate abort rejection"));
    await flushMicrotasks();
    expect(events.filter((event) => event.type === "stop_confirmed")).toHaveLength(1);
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(0);
  });

  it("stopSession force terminates after timeout when agent_end never arrives", async () => {
    vi.useFakeTimers();
    try {
      const { manager, events, sdkBackend, abort, dispose } = makeManagerHarness("busy");

      const stopPromise = manager.stopSession("s1");
      await Promise.resolve();
      await Promise.resolve();

      vi.advanceTimersByTime(
        (manager as unknown as { stopSessionGraceMs: number }).stopSessionGraceMs,
      );
      await stopPromise;

      expect(abort).toHaveBeenCalledTimes(1);
      expect(sdkBackend.session.abortBash).toHaveBeenCalledTimes(1);
      expect(dispose).toHaveBeenCalledTimes(1);
      expect(manager.isActive("s1")).toBe(false);

      const confirmed = events.find(
        (event): event is Extract<ServerMessage, { type: "stop_confirmed" }> =>
          event.type === "stop_confirmed",
      );
      expect(confirmed?.reason).toContain("timed out");
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("bounds stop queued behind a reload whose extension shutdown never resolves", async () => {
    vi.useFakeTimers();
    try {
      const { manager, active, events, saveSession } = makeManagerHarness("ready");
      const {
        backend,
        finishShutdown,
        forceDispose,
        lateReloadFinished,
        reload: piReload,
        runtimeDispose,
        zombieRuntimeIsActive,
      } = makeNeverResolvingReloadBackend();
      active.sdkBackend = backend;
      const runtimeManager = (
        manager as unknown as {
          stopFlowCoordinator: { deps: { runtimeManager: WorkspaceRuntime } };
        }
      ).stopFlowCoordinator.deps.runtimeManager;

      const reloadOutcome = backend.reloadResources().then(
        () => ({ status: "fulfilled" as const }),
        (error: unknown) => ({ status: "rejected" as const, error }),
      );
      await flushMicrotasks(10);
      expect(piReload).toHaveBeenCalledOnce();
      expect(backend.isRuntimeLifecycleTransactionExclusive).toBe(true);

      let stopSettled = false;
      const stop = manager.stopSession("s1").then(() => {
        stopSettled = true;
      });
      await flushMicrotasks(10);

      let runtimePermitReleased = false;
      const runtimePermitProbe = backend
        .withRuntimeLifecycleTransaction("probe", async () => undefined)
        .then(
          () => {
            throw new Error("Disposed backend unexpectedly admitted runtime work");
          },
          (error: unknown) => {
            expect(error).toEqual(
              expect.objectContaining({ message: "Session backend is disposed" }),
            );
            runtimePermitReleased = true;
          },
        );
      let sessionLockReleased = false;
      const sessionLockProbe = runtimeManager.withSessionLock("s1", async () => {
        sessionLockReleased = true;
      });
      let workspaceLockReleased = false;
      const workspaceLockProbe = runtimeManager.withWorkspaceLock("w1", async () => {
        workspaceLockReleased = true;
      });

      await vi.advanceTimersByTimeAsync(5_000);
      await flushMicrotasks(20);

      const boundedStopSettled = stopSettled;
      const boundedActiveState = manager.isActive("s1");
      const boundedTerminalOutcomes = events.filter(
        (event) => event.type === "stop_confirmed" || event.type === "stop_failed",
      ).length;
      const boundedForceDisposals = forceDispose.mock.calls.length;
      const boundedRuntimePermitReleased = runtimePermitReleased;
      const boundedSessionLockReleased = sessionLockReleased;
      const boundedWorkspaceLockReleased = workspaceLockReleased;

      // Always release the synthetic extension so the pre-fix red run can
      // cleanly settle after recording whether the documented bound held.
      finishShutdown();
      await lateReloadFinished;
      await Promise.all([stop, runtimePermitProbe, sessionLockProbe, workspaceLockProbe]);
      const reloadResult = await reloadOutcome;

      expect(boundedStopSettled).toBe(true);
      expect(boundedActiveState).toBe(false);
      expect(boundedTerminalOutcomes).toBe(1);
      expect(boundedForceDisposals).toBe(1);
      expect(boundedRuntimePermitReleased).toBe(true);
      expect(boundedSessionLockReleased).toBe(true);
      expect(boundedWorkspaceLockReleased).toBe(true);
      expect(reloadResult).toEqual({
        status: "rejected",
        error: expect.objectContaining({
          message: "reload timed out after 5000ms; session backend was disposed",
        }),
      });
      expect(runtimeDispose).not.toHaveBeenCalled();
      expect(runtimePermitReleased).toBe(true);
      expect(sessionLockReleased).toBe(true);
      expect(workspaceLockReleased).toBe(true);
      expect(backend.isRuntimeLifecycleTransactionExclusive).toBe(false);
      expect(manager.isActive("s1")).toBe(false);
      expect(active.session.status).toBe("stopped");
      expect(events.filter((event) => event.type === "stop_confirmed")).toEqual([
        expect.objectContaining({
          reason: "Pi reload timed out after 5000ms; forced local session disposal",
        }),
      ]);
      expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(0);
      expect(events.filter((event) => event.type === "session_ended")).toHaveLength(1);

      const persistedAfterStop = saveSession.mock.calls.length;
      const eventsAfterStop = events.length;
      await flushMicrotasks(10);
      expect(zombieRuntimeIsActive()).toBe(false);
      expect(forceDispose).toHaveBeenCalledTimes(2);
      expect(saveSession).toHaveBeenCalledTimes(persistedAfterStop);
      expect(events).toHaveLength(eventsAfterStop);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it.each(["new_session", "fork"] as const)(
    "rejects in-wrapper %s without starting replacement teardown",
    async (type) => {
      const { manager, active, events } = makeManagerHarness("ready");
      const { backend } = makeNeverResolvingReplacementBackend(
        type === "new_session" ? "newSession" : "fork",
      );
      active.sdkBackend = backend;

      await manager.forwardClientCommand(
        "s1",
        type === "new_session" ? { type: "new_session" } : { type: "fork", entryId: "entry-1" },
        `request-${type}`,
      );

      expect(backend.isRuntimeLifecycleTransactionExclusive).toBe(false);
      const result = events.find((event) => event.type === "command_result");
      expect(result).toMatchObject({ success: false, command: type });
      expect((result as Extract<ServerMessage, { type: "command_result" }>).error).toMatch(
        /Oppi lifecycle|not allowed|distinct canonical/i,
      );
    },
  );

  it.each(["input", "before_agent_start"] as const)(
    "bounds stopAll behind managed %s preflight and ignores its late acceptance",
    async () => {
      vi.useFakeTimers();
      try {
        const { manager, active, events, saveSession } = makeManagerHarness("ready");
        const { backend, acceptPreflight, forceDispose, promptEntered } =
          makeNeverResolvingPreflightBackend();
        active.sdkBackend = backend;
        const runtimeManager = (
          manager as unknown as {
            stopFlowCoordinator: { deps: { runtimeManager: WorkspaceRuntime } };
          }
        ).stopFlowCoordinator.deps.runtimeManager;

        const promptOutcome = manager
          .sendPrompt("s1", "never accepted", {
            clientTurnId: "hung-preflight",
            timestamp: 10,
          })
          .then(
            () => ({ status: "fulfilled" as const }),
            (error: unknown) => ({ status: "rejected" as const, error }),
          );
        await promptEntered;

        let stopAllSettled = false;
        const stopAll = manager.stopAll().then(() => {
          stopAllSettled = true;
        });
        await flushMicrotasks(10);

        let runtimeLockReleased = false;
        const runtimeProbe = backend
          .withRuntimeLifecycleTransaction("probe", async () => undefined)
          .then(
            () => {
              throw new Error("Disposed backend unexpectedly admitted runtime work");
            },
            () => {
              runtimeLockReleased = true;
            },
          );
        let sessionLockReleased = false;
        const sessionProbe = runtimeManager.withSessionLock("s1", async () => {
          sessionLockReleased = true;
        });
        let workspaceLockReleased = false;
        const workspaceProbe = runtimeManager.withWorkspaceLock("w1", async () => {
          workspaceLockReleased = true;
        });

        await vi.advanceTimersByTimeAsync(6_000);
        await flushMicrotasks(20);

        const bounded = {
          stopAllSettled,
          active: manager.isActive("s1"),
          terminalOutcomes: events.filter(
            (event) => event.type === "stop_confirmed" || event.type === "stop_failed",
          ).length,
          forceDisposals: forceDispose.mock.calls.length,
          runtimeLockReleased,
          sessionLockReleased,
          workspaceLockReleased,
        };
        const persistedAtBound = saveSession.mock.calls.length;
        const eventsAtBound = events.length;

        // Release the synthetic Pi hook so the pre-fix red run exits cleanly.
        acceptPreflight();
        const latePrompt = await promptOutcome;
        await Promise.all([stopAll, runtimeProbe, sessionProbe, workspaceProbe]);
        await flushMicrotasks(10);

        expect(bounded).toEqual({
          stopAllSettled: true,
          active: false,
          terminalOutcomes: 1,
          forceDisposals: 1,
          runtimeLockReleased: true,
          sessionLockReleased: true,
          workspaceLockReleased: true,
        });
        expect(latePrompt).toEqual({
          status: "rejected",
          error: expect.objectContaining({
            message: expect.stringMatching(/session backend is disposed/i),
          }),
        });
        expect(active.turnCache.get("hung-preflight")).toBeNull();
        expect(active.session.messages).toBeUndefined();
        expect(active.session.messageCount).toBe(0);
        expect(saveSession).toHaveBeenCalledTimes(persistedAtBound);
        expect(events).toHaveLength(eventsAtBound);
      } finally {
        vi.clearAllTimers();
        vi.useRealTimers();
      }
    },
  );

  it("releases all ownership and reports failure when emergency stop persistence fails", async () => {
    vi.useFakeTimers();
    try {
      const { manager, active, events, saveSession } = makeManagerHarness("ready");
      const { backend, acceptPreflight, forceDispose, promptEntered } =
        makeNeverResolvingPreflightBackend();
      active.sdkBackend = backend;
      const runtimeManager = (
        manager as unknown as {
          stopFlowCoordinator: { deps: { runtimeManager: WorkspaceRuntime } };
        }
      ).stopFlowCoordinator.deps.runtimeManager;
      runtimeManager.reserveSessionStart({ workspaceId: "w1", sessionId: "s1" });
      const persistedStatuses: Session["status"][] = [];
      saveSession.mockImplementation((session: Session) => {
        if (session.status === "stopped") throw new Error("emergency stop persistence failed");
        persistedStatuses.push(session.status);
      });

      const promptOutcome = manager
        .sendPrompt("s1", "hold the runtime permit", { clientTurnId: "persist-failure-stop" })
        .then(
          () => ({ status: "fulfilled" as const }),
          (error: unknown) => ({ status: "rejected" as const, error }),
        );
      await promptEntered;

      let stopSettled = false;
      const stop = manager.stopSession("s1").then(() => {
        stopSettled = true;
      });
      await flushMicrotasks(10);

      let runtimeLockReleased = false;
      const runtimeLockProbe = backend
        .withRuntimeLifecycleTransaction("probe", async () => undefined)
        .then(
          () => {
            throw new Error("Disposed backend unexpectedly admitted runtime work");
          },
          () => {
            runtimeLockReleased = true;
          },
        );
      let sessionLockReleased = false;
      const sessionLockProbe = runtimeManager.withSessionLock("s1", async () => {
        sessionLockReleased = true;
      });
      let workspaceLockReleased = false;
      const workspaceLockProbe = runtimeManager.withWorkspaceLock("w1", async () => {
        workspaceLockReleased = true;
      });

      await vi.advanceTimersByTimeAsync(6_000);
      await flushMicrotasks(20);

      const bounded = {
        stopSettled,
        active: manager.isActive("s1"),
        workspaceSlots: runtimeManager.getWorkspaceSessionCount("w1"),
        terminalOutcomes: events.filter(
          (event) => event.type === "stop_confirmed" || event.type === "stop_failed",
        ),
        sessionEnded: events.filter((event) => event.type === "session_ended").length,
        forceDisposals: forceDispose.mock.calls.length,
        persistedStatuses: [...persistedStatuses],
        runtimeLockReleased,
        sessionLockReleased,
        workspaceLockReleased,
      };
      const persistedAtBound = saveSession.mock.calls.length;
      const eventsAtBound = events.length;

      acceptPreflight();
      const latePrompt = await promptOutcome;
      await Promise.all([stop, runtimeLockProbe, sessionLockProbe, workspaceLockProbe]);
      await flushMicrotasks(10);

      expect(bounded).toEqual({
        stopSettled: true,
        active: false,
        workspaceSlots: 0,
        terminalOutcomes: [
          expect.objectContaining({
            type: "stop_failed",
            source: "server",
            reason: "Failed to persist stopped session: emergency stop persistence failed",
          }),
        ],
        sessionEnded: 1,
        forceDisposals: 1,
        persistedStatuses: ["stopping"],
        runtimeLockReleased: true,
        sessionLockReleased: true,
        workspaceLockReleased: true,
      });
      expect(latePrompt).toEqual({
        status: "rejected",
        error: expect.objectContaining({
          message: expect.stringMatching(/session backend is disposed/i),
        }),
      });
      expect(saveSession).toHaveBeenCalledTimes(persistedAtBound);
      expect(events).toHaveLength(eventsAtBound);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("completes emergency deadline cleanup when one extension widget disposer throws", async () => {
    vi.useFakeTimers();
    try {
      const { manager, active, events } = makeManagerHarness("ready");
      const { backend, acceptPreflight, forceDispose, promptEntered } =
        makeNeverResolvingPreflightBackend();
      active.sdkBackend = backend;
      const runtimeManager = (
        manager as unknown as {
          stopFlowCoordinator: { deps: { runtimeManager: WorkspaceRuntime } };
        }
      ).stopFlowCoordinator.deps.runtimeManager;
      const widgetDisposals: string[] = [];
      const bridge = new SdkUiBridge(vi.fn(), () => backend.isDisposed);
      const ui = bridge.createContext();
      ui.setWidget("throwing-widget", () => ({
        render: () => ["throwing"],
        dispose: () => {
          widgetDisposals.push("throwing-widget");
          throw new Error("widget dispose failed");
        },
      }));
      ui.setWidget("remaining-widget", () => ({
        render: () => ["remaining"],
        dispose: () => {
          widgetDisposals.push("remaining-widget");
        },
      }));
      const pendingInput = ui.input("Pending", "cancel during disposal");
      const unsubscribe = vi.fn();
      const mutableBackend = backend as unknown as {
        runtime: {
          session: {
            sessionId: string;
            sessionFile?: string;
            isStreaming: boolean;
            isCompacting: boolean;
            prompt: ReturnType<typeof vi.fn>;
            dispose: ReturnType<typeof vi.fn>;
            abortBash: ReturnType<typeof vi.fn>;
            extensionRunner: { getAllRegisteredTools: () => unknown[] };
          };
        };
        uiBridge: SdkUiBridge;
        unsub: ReturnType<typeof vi.fn>;
      };
      mutableBackend.uiBridge = bridge;
      mutableBackend.unsub = unsubscribe;

      const promptOutcome = manager
        .sendPrompt("s1", "hold the runtime permit", { clientTurnId: "throwing-widget-stop" })
        .then(
          () => ({ status: "fulfilled" as const }),
          (error: unknown) => ({ status: "rejected" as const, error }),
        );
      await promptEntered;

      let stopSettled = false;
      const stop = manager.stopSession("s1").then(() => {
        stopSettled = true;
      });
      await flushMicrotasks(10);

      // The emergency callback captured the original session before waiting.
      // Replace the current session to prove both detached instances are disposed.
      const capturedSession = mutableBackend.runtime.session;
      const currentSessionDispose = vi.fn();
      mutableBackend.runtime.session = {
        ...capturedSession,
        sessionId: "pi-session-current",
        dispose: currentSessionDispose,
      };

      let runtimePermitReleased = false;
      const runtimePermitProbe = backend
        .withRuntimeLifecycleTransaction("probe", async () => undefined)
        .then(
          () => {
            throw new Error("Disposed backend unexpectedly admitted runtime work");
          },
          () => {
            runtimePermitReleased = true;
          },
        );
      let sessionLockReleased = false;
      const sessionLockProbe = runtimeManager.withSessionLock("s1", async () => {
        sessionLockReleased = true;
      });
      let workspaceLockReleased = false;
      const workspaceLockProbe = runtimeManager.withWorkspaceLock("w1", async () => {
        workspaceLockReleased = true;
      });

      await vi.advanceTimersByTimeAsync(6_000);
      await flushMicrotasks(20);

      const bounded = {
        stopSettled,
        active: manager.isActive("s1"),
        terminalOutcomes: events.filter(
          (event) => event.type === "stop_confirmed" || event.type === "stop_failed",
        ).length,
        capturedSessionDisposals: forceDispose.mock.calls.length,
        currentSessionDisposals: currentSessionDispose.mock.calls.length,
        widgetDisposals: [...widgetDisposals],
        unsubscribed: unsubscribe.mock.calls.length,
        runtimePermitReleased,
        sessionLockReleased,
        workspaceLockReleased,
      };

      // Release the synthetic Pi hook so the pre-fix red run exits cleanly.
      acceptPreflight();
      await Promise.all([
        stop,
        promptOutcome,
        runtimePermitProbe,
        sessionLockProbe,
        workspaceLockProbe,
      ]);

      await expect(pendingInput).resolves.toBeUndefined();
      expect(bounded).toEqual({
        stopSettled: true,
        active: false,
        terminalOutcomes: 1,
        capturedSessionDisposals: 1,
        currentSessionDisposals: 1,
        widgetDisposals: ["throwing-widget", "remaining-widget"],
        unsubscribed: 1,
        runtimePermitReleased: true,
        sessionLockReleased: true,
        workspaceLockReleased: true,
      });
      expect(events.filter((event) => event.type === "stop_confirmed")).toEqual([
        expect.objectContaining({
          reason: expect.stringMatching(/Stop lifecycle timed out.*widget dispose failed/),
        }),
      ]);
      expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(0);
      expect(events.filter((event) => event.type === "session_ended")).toHaveLength(1);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("bounds never-resolving extension shutdown and releases every stop lifecycle permit", async () => {
    vi.useFakeTimers();
    try {
      const { manager, active, events, abort } = makeManagerHarness("ready");
      const { backend, runtimeDispose, forceDispose } = makeNeverResolvingShutdownBackend();
      active.sdkBackend = backend;
      const runtimeManager = (
        manager as unknown as {
          stopFlowCoordinator: { deps: { runtimeManager: WorkspaceRuntime } };
        }
      ).stopFlowCoordinator.deps.runtimeManager;

      let stopSettled = false;
      const stop = manager.stopSession("s1").then(() => {
        stopSettled = true;
      });
      await flushMicrotasks(10);

      expect(runtimeDispose).toHaveBeenCalledOnce();
      expect(backend.isRuntimeLifecycleTransactionExclusive).toBe(true);

      let runtimePermitReleased = false;
      const runtimePermitProbe = backend
        .withRuntimeLifecycleTransaction("probe", async () => undefined)
        .then(
          () => {
            throw new Error("Disposed backend unexpectedly admitted runtime work");
          },
          (error: unknown) => {
            expect(error).toEqual(
              expect.objectContaining({ message: "Session backend is disposed" }),
            );
            runtimePermitReleased = true;
          },
        );
      let sessionLockReleased = false;
      const sessionLockProbe = runtimeManager.withSessionLock("s1", async () => {
        sessionLockReleased = true;
      });
      let workspaceLockReleased = false;
      const workspaceLockProbe = runtimeManager.withWorkspaceLock("w1", async () => {
        workspaceLockReleased = true;
      });

      await vi.advanceTimersByTimeAsync(5_000);
      await flushMicrotasks(20);

      expect(stopSettled).toBe(true);
      await Promise.all([stop, runtimePermitProbe, sessionLockProbe, workspaceLockProbe]);
      expect(runtimePermitReleased).toBe(true);
      expect(sessionLockReleased).toBe(true);
      expect(workspaceLockReleased).toBe(true);
      expect(backend.isRuntimeLifecycleTransactionExclusive).toBe(false);
      expect(forceDispose).toHaveBeenCalledOnce();
      expect(abort).not.toHaveBeenCalled();
      expect(manager.isActive("s1")).toBe(false);
      expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(0);
      expect(events.filter((event) => event.type === "stop_confirmed")).toEqual([
        expect.objectContaining({
          reason: expect.stringContaining("Pi extension shutdown timed out after 5000ms"),
        }),
      ]);
      expect(events.filter((event) => event.type === "session_ended")).toHaveLength(1);
    } finally {
      vi.clearAllTimers();
      vi.useRealTimers();
    }
  });

  it("reports runtime disposal failure when local Pi cleanup succeeds", async () => {
    const { manager, events, dispose } = makeManagerHarness("ready");
    dispose.mockResolvedValueOnce({
      disposal: "forced",
      cause: "runtime_dispose_error",
    });

    await manager.stopSession("s1");

    expect(events.filter((event) => event.type === "stop_confirmed")).toEqual([
      expect.objectContaining({
        reason: "Pi runtime disposal failed; forced local session disposal",
      }),
    ]);
    expect(events.filter((event) => event.type === "stop_failed")).toHaveLength(0);
  });

  it("stopSession terminates an idle session immediately", async () => {
    const { manager, events, abort, dispose } = makeManagerHarness("ready");

    await manager.stopSession("s1");

    expect(abort).not.toHaveBeenCalled();
    expect(dispose).toHaveBeenCalledTimes(1);
    expect(manager.isActive("s1")).toBe(false);
    expect(events.some((event) => event.type === "session_ended")).toBe(true);
  });
});

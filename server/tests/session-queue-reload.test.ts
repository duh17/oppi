import { afterEach, describe, expect, it, vi } from "vitest";

import { QUEUE_RECONCILIATION_REQUIRED_ERROR, SdkBackend } from "../src/sdk-backend.js";
import {
  SessionMessageQueueCoordinator,
  type SessionMessageQueueState,
  type SessionMessageQueueStore,
} from "../src/session-queue.js";
import type { Session } from "../src/types.js";

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

function makeSession(): Session {
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function makeHarness(options: {
  isStreaming: boolean;
  steering?: string[];
  followUp?: string[];
  queue?: SessionMessageQueueStore;
}) {
  const steering = [...(options.steering ?? [])];
  const followUp = [...(options.followUp ?? [])];
  const emitQueueUpdate = (): void => {
    const mutable = backend as unknown as { queueAuthorityGeneration?: number };
    mutable.queueAuthorityGeneration = (mutable.queueAuthorityGeneration ?? 0) + 1;
  };
  const reloadGate = deferred<void>();
  const prompt = vi.fn(async () => undefined);
  const steer = vi.fn(async (message: string) => {
    steering.push(message);
    emitQueueUpdate();
  });
  const followUpCall = vi.fn(async (message: string) => {
    followUp.push(message);
    emitQueueUpdate();
  });
  const piSession = {
    isStreaming: options.isStreaming,
    reload: vi.fn(() => reloadGate.promise),
    prompt,
    steer,
    followUp: followUpCall,
    clearQueue: vi.fn(() => {
      steering.length = 0;
      followUp.length = 0;
      emitQueueUpdate();
    }),
    getSteeringMessages: vi.fn(() => [...steering]),
    getFollowUpMessages: vi.fn(() => [...followUp]),
    extensionRunner: { getAllRegisteredTools: () => [] },
  };
  const backend = Object.create(SdkBackend.prototype) as SdkBackend;
  Object.assign(backend as unknown as Record<string, unknown>, {
    disposed: false,
    emitEvent: vi.fn(),
    runtime: { session: piSession },
  });
  const active: SessionMessageQueueState = {
    session: makeSession(),
    sdkBackend: backend,
    messageQueue: options.queue ?? { version: 0, steering: [], followUp: [] },
  };
  const broadcast = vi.fn();
  const coordinator = new SessionMessageQueueCoordinator({
    getActiveSession: () => active,
    broadcast,
  });

  const consumeSteering = (message: string): void => {
    const index = steering.indexOf(message);
    if (index === -1) throw new Error(`Missing steering message: ${message}`);
    steering.splice(index, 1);
    emitQueueUpdate();
    coordinator.markQueuedMessageStarted("s1", {
      role: "user",
      content: [{ type: "text", text: message }],
    });
  };

  return {
    active,
    backend,
    broadcast,
    consumeSteering,
    coordinator,
    followUp: followUpCall,
    piSession,
    prompt,
    reloadGate,
    steer,
  };
}

afterEach(() => {
  vi.useRealTimers();
});

async function flushMicrotasks(turns = 3): Promise<void> {
  for (let index = 0; index < turns; index += 1) await Promise.resolve();
}

describe("SessionMessageQueueCoordinator reload quiescing", () => {
  it.each([
    { type: "prompt", streamingBehavior: undefined },
    { type: "steer", streamingBehavior: "steer" as const },
    { type: "follow_up", streamingBehavior: "followUp" as const },
  ])("rejects a direct $type entry while the backend reload barrier is active", async (entry) => {
    const harness = makeHarness({ isStreaming: false });
    const reload = harness.backend.reloadResources();

    await expect(
      harness.backend.prompt("overlap", { streamingBehavior: entry.streamingBehavior }),
    ).rejects.toThrow(`${entry.type} cannot start while reload is rebuilding the session`);
    expect(harness.prompt).not.toHaveBeenCalled();

    harness.reloadGate.resolve();
    await reload;
  });

  it("defers the delayed post-compaction prompt and queue replay until reload completes", async () => {
    vi.useFakeTimers();
    const queue: SessionMessageQueueStore = {
      version: 3,
      steering: [
        { id: "steer-1", message: "first", sdkMessage: "first", createdAt: 1 },
        { id: "steer-2", message: "second", sdkMessage: "second", createdAt: 2 },
      ],
      followUp: [{ id: "follow-1", message: "third", sdkMessage: "third", createdAt: 3 }],
    };
    const harness = makeHarness({
      isStreaming: false,
      steering: ["first", "second"],
      followUp: ["third"],
      queue,
    });
    const flushSpy = vi.spyOn(harness.coordinator, "flushIdleQueuedMessages");

    const reload = harness.backend.reloadResources();
    await Promise.resolve();
    expect(harness.piSession.reload).toHaveBeenCalledOnce();
    harness.coordinator.schedulePostCompactionQueueFlush("s1");
    await vi.advanceTimersByTimeAsync(250);

    expect(flushSpy).toHaveBeenCalledOnce();
    expect(harness.prompt).not.toHaveBeenCalled();
    expect(harness.steer).not.toHaveBeenCalled();
    expect(harness.followUp).not.toHaveBeenCalled();

    harness.reloadGate.resolve();
    await reload;
    const flush = flushSpy.mock.results[0]?.value;
    await expect(flush).resolves.toBe(true);

    expect(harness.prompt).toHaveBeenCalledWith(
      "first",
      expect.objectContaining({ images: undefined, streamingBehavior: undefined }),
    );
    expect(harness.steer).toHaveBeenCalledWith("second", undefined);
    expect(harness.followUp).toHaveBeenCalledWith("third", undefined);
  });

  it("captures the reload snapshot only after an entered queue replacement finishes", async () => {
    const harness = makeHarness({ isStreaming: false });
    const steerGate = deferred<void>();
    harness.steer.mockImplementationOnce(() => steerGate.promise);
    const snapshotReadEntered = deferred<void>();
    const snapshotRead = vi.fn(() => {
      snapshotReadEntered.resolve();
      return { enabled: true, revision: 2 };
    });
    Object.assign(harness.backend as unknown as Record<string, unknown>, {
      mobileOutputGuideSettingsHolder: {
        snapshot: { enabled: false, revision: 1 },
      },
      getMobileOutputGuideSettings: snapshotRead,
    });

    const replacement = harness.backend.replaceQueuedModelTurns({
      steering: [{ message: "entered before reload" }],
      followUp: [],
    });
    await Promise.resolve();
    expect(harness.steer).toHaveBeenCalledOnce();

    const reload = harness.backend.reloadResources();
    await Promise.resolve();
    expect(snapshotRead).not.toHaveBeenCalled();
    expect(harness.piSession.reload).not.toHaveBeenCalled();

    steerGate.resolve();
    await replacement;
    await snapshotReadEntered.promise;
    expect(snapshotRead).toHaveBeenCalledOnce();
    expect(harness.piSession.reload).toHaveBeenCalledOnce();

    harness.reloadGate.resolve();
    await expect(reload).resolves.toEqual({ success: true });
  });
});

describe("SessionMessageQueueCoordinator replacement transactions", () => {
  it("rejects managed enqueue, dequeue, reconciliation, and flush at exhaustion before projection mutation", async () => {
    const maxVersion = Number.MAX_SAFE_INTEGER;
    const expectedError = `Queue version exhausted at ${maxVersion}; start a new session to reset the queue counter`;

    const enqueueHarness = makeHarness({
      isStreaming: true,
      steering: ["at max"],
      queue: {
        version: maxVersion,
        steering: [{ id: "at-max", message: "at max", sdkMessage: "at max", createdAt: 1 }],
        followUp: [],
      },
    });
    expect(() =>
      enqueueHarness.coordinator.enqueueQueuedMessage("s1", "steer", "must not enqueue"),
    ).toThrow(expectedError);
    expect(() =>
      enqueueHarness.coordinator.markQueuedMessageStarted("s1", {
        role: "user",
        content: [{ type: "text", text: "at max" }],
      }),
    ).toThrow(expectedError);
    expect(() => enqueueHarness.coordinator.assertModelTurnAdmissionAllowed("s1")).toThrow(
      expectedError,
    );
    expect(enqueueHarness.active.messageQueue).toMatchObject({
      version: maxVersion,
      steering: [{ id: "at-max", message: "at max" }],
    });
    expect(enqueueHarness.broadcast).not.toHaveBeenCalled();

    const reconciliationHarness = makeHarness({
      isStreaming: true,
      steering: ["runtime changed"],
      queue: {
        version: maxVersion,
        steering: [{ id: "trusted", message: "trusted", sdkMessage: "trusted", createdAt: 1 }],
        followUp: [],
      },
    });
    expect(() => reconciliationHarness.coordinator.getQueue("s1")).toThrow(expectedError);
    expect(reconciliationHarness.active.messageQueue).toMatchObject({
      version: maxVersion,
      steering: [{ id: "trusted", message: "trusted" }],
    });

    const flushHarness = makeHarness({
      isStreaming: false,
      steering: ["at max"],
      queue: {
        version: maxVersion,
        steering: [{ id: "at-max", message: "at max", sdkMessage: "at max", createdAt: 1 }],
        followUp: [],
      },
    });
    await expect(flushHarness.coordinator.flushIdleQueuedMessages("s1")).rejects.toThrow(
      expectedError,
    );
    expect(flushHarness.piSession.clearQueue).not.toHaveBeenCalled();
    expect(flushHarness.prompt).not.toHaveBeenCalled();
    expect(flushHarness.active.messageQueue).toMatchObject({
      version: maxVersion,
      steering: [{ id: "at-max", message: "at max" }],
    });
  });

  it("reserves abort rollback capacity before clearing a managed queue", async () => {
    const maxVersion = Number.MAX_SAFE_INTEGER;
    const harness = makeHarness({
      isStreaming: true,
      steering: ["preserved"],
      queue: {
        version: maxVersion - 1,
        steering: [
          { id: "preserved", message: "preserved", sdkMessage: "preserved", createdAt: 1 },
        ],
        followUp: [],
      },
    });

    await expect(
      harness.backend.withRuntimeLifecycleTransaction("abort clear test", (permit) =>
        harness.coordinator.clearQueueOnAbort("s1", permit),
      ),
    ).rejects.toThrow(
      `Queue version exhausted at ${maxVersion}; start a new session to reset the queue counter`,
    );
    expect(harness.piSession.clearQueue).not.toHaveBeenCalled();
    expect(harness.piSession.getSteeringMessages()).toEqual(["preserved"]);
    expect(harness.active.messageQueue).toMatchObject({
      version: maxVersion - 1,
      steering: [{ id: "preserved", message: "preserved" }],
    });
    expect(harness.broadcast).not.toHaveBeenCalled();
  });

  it("rejects reads and delayed flush before mutation when only the backend needs reconciliation", async () => {
    const queue: SessionMessageQueueStore = {
      version: 8,
      steering: [{ id: "preserved", message: "preserved", sdkMessage: "preserved", createdAt: 1 }],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: false, steering: ["preserved"], queue });
    Object.assign(harness.backend as unknown as Record<string, unknown>, {
      queueReconciliationRequired: true,
    });

    expect(() => harness.coordinator.getQueue("s1")).toThrow(QUEUE_RECONCILIATION_REQUIRED_ERROR);
    await expect(harness.coordinator.flushIdleQueuedMessages("s1")).rejects.toThrow(
      QUEUE_RECONCILIATION_REQUIRED_ERROR,
    );

    expect(harness.piSession.clearQueue).not.toHaveBeenCalled();
    expect(harness.prompt).not.toHaveBeenCalled();
    expect(harness.steer).not.toHaveBeenCalled();
    expect(harness.followUp).not.toHaveBeenCalled();
    expect(harness.active.messageQueue).toMatchObject({
      version: 8,
      steering: [{ id: "preserved", message: "preserved" }],
    });
  });

  it("does not remove or emit a delayed item until Pi accepts its prompt", async () => {
    const queue: SessionMessageQueueStore = {
      version: 2,
      steering: [{ id: "first", message: "first", sdkMessage: "first", createdAt: 1 }],
      followUp: [{ id: "second", message: "second", sdkMessage: "second", createdAt: 2 }],
    };
    const harness = makeHarness({
      isStreaming: false,
      steering: ["first"],
      followUp: ["second"],
      queue,
    });
    const acceptPrompt = deferred<void>();
    harness.prompt.mockImplementation(
      async (_message: string, options?: { preflightResult?: (success: boolean) => void }) => {
        await acceptPrompt.promise;
        options?.preflightResult?.(true);
      },
    );

    const flush = harness.coordinator.flushIdleQueuedMessages("s1");
    await flushMicrotasks();

    expect(harness.active.messageQueue).toMatchObject({
      version: 2,
      steering: [{ id: "first" }],
      followUp: [{ id: "second" }],
    });
    expect(harness.broadcast).not.toHaveBeenCalledWith(
      "s1",
      expect.objectContaining({ type: "queue_item_started" }),
    );

    acceptPrompt.resolve();
    await expect(flush).resolves.toBe(true);
    expect(harness.active.messageQueue).toMatchObject({
      version: 3,
      steering: [],
      followUp: [{ id: "second" }],
    });
    expect(harness.broadcast).toHaveBeenCalledWith(
      "s1",
      expect.objectContaining({
        type: "queue_item_started",
        item: expect.objectContaining({ id: "first" }),
      }),
    );
  });

  it("preserves delayed intent when Pi rejects prompt acceptance", async () => {
    const queue: SessionMessageQueueStore = {
      version: 9,
      steering: [{ id: "first", message: "first", sdkMessage: "first", createdAt: 1 }],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: false, steering: ["first"], queue });
    harness.prompt.mockImplementation(
      async (_message: string, options?: { preflightResult?: (success: boolean) => void }) => {
        options?.preflightResult?.(false);
        throw new Error("prompt rejected");
      },
    );

    await expect(harness.coordinator.flushIdleQueuedMessages("s1")).rejects.toThrow(
      "prompt rejected",
    );
    expect(harness.active.messageQueue).toMatchObject({
      version: 9,
      steering: [{ id: "first", message: "first" }],
    });
    expect(harness.piSession.getSteeringMessages()).toEqual(["first"]);
    expect(harness.broadcast).not.toHaveBeenCalledWith(
      "s1",
      expect.objectContaining({ type: "queue_item_started" }),
    );
  });
});

describe("SdkBackend lifecycle replacement transactions", () => {
  it.each([
    { type: "prompt", streamingBehavior: undefined },
    { type: "steer", streamingBehavior: "steer" as const },
    { type: "follow_up", streamingBehavior: "followUp" as const },
  ])("notifies $type acceptance only when Pi preflight succeeds", async (entry) => {
    const harness = makeHarness({ isStreaming: false });
    const onPreflightAccepted = vi.fn();
    harness.prompt.mockImplementationOnce(
      async (_message: string, options?: { preflightResult?: (success: boolean) => void }) => {
        options?.preflightResult?.(false);
        throw new Error(`${entry.type} rejected`);
      },
    );

    await expect(
      harness.backend.prompt("rejected first", {
        streamingBehavior: entry.streamingBehavior,
        onPreflightAccepted,
      }),
    ).rejects.toThrow(`${entry.type} rejected`);
    expect(onPreflightAccepted).not.toHaveBeenCalled();

    harness.prompt.mockImplementationOnce(
      async (_message: string, options?: { preflightResult?: (success: boolean) => void }) => {
        options?.preflightResult?.(true);
      },
    );
    await expect(
      harness.backend.prompt("accepted retry", {
        streamingBehavior: entry.streamingBehavior,
        onPreflightAccepted,
      }),
    ).resolves.toBeUndefined();
    expect(onPreflightAccepted).toHaveBeenCalledOnce();
  });

  it("holds model-turn admission through Pi prompt preflight acceptance", async () => {
    const harness = makeHarness({ isStreaming: false });
    const promptEntered = deferred<void>();
    const acceptPrompt = deferred<void>();
    harness.prompt.mockImplementation(
      async (_message: string, options?: { preflightResult?: (success: boolean) => void }) => {
        promptEntered.resolve();
        await acceptPrompt.promise;
        options?.preflightResult?.(true);
      },
    );

    const prompt = harness.backend.prompt("accepted first");
    await promptEntered.promise;
    const reload = harness.backend.reloadResources();
    await flushMicrotasks();
    expect(harness.piSession.reload).not.toHaveBeenCalled();

    acceptPrompt.resolve();
    await prompt;
    await flushMicrotasks();
    expect(harness.piSession.reload).toHaveBeenCalledOnce();
    harness.reloadGate.resolve();
    await reload;
  });

  it.each(["newSession", "fork"] as const)(
    "rejects in-wrapper %s instead of replacing the live runtime",
    async (method) => {
      const runtimeCall = vi.fn(async () => ({ cancelled: true }));
      const backend = Object.create(SdkBackend.prototype) as SdkBackend;
      Object.assign(backend as unknown as Record<string, unknown>, {
        disposed: false,
        runtime: {
          newSession: runtimeCall,
          fork: runtimeCall,
        },
      });

      await expect(
        method === "newSession" ? backend.newSession() : backend.fork("entry-1"),
      ).rejects.toThrow(/Oppi lifecycle|not allowed|distinct canonical/i);
      expect(runtimeCall).not.toHaveBeenCalled();
    },
  );

  it("serializes dispose behind reload teardown and rejects later queue work", async () => {
    const reloadGate = deferred<void>();
    const piSession = {
      isStreaming: false,
      isCompacting: false,
      reload: vi.fn(() => reloadGate.promise),
      abort: vi.fn(async () => undefined),
      clearQueue: vi.fn(),
      steer: vi.fn(async () => undefined),
      followUp: vi.fn(async () => undefined),
      getSteeringMessages: vi.fn(() => []),
      getFollowUpMessages: vi.fn(() => []),
      extensionRunner: { getAllRegisteredTools: () => [] },
    };
    const runtime = {
      session: piSession,
      dispose: vi.fn(async () => undefined),
    };
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;
    Object.assign(backend as unknown as Record<string, unknown>, {
      disposed: false,
      runtime,
      uiBridge: { dispose: vi.fn() },
      unsub: vi.fn(),
      shutdownCleanupPromise: null,
    });

    const reload = backend.reloadResources();
    await flushMicrotasks();
    const dispose = backend.dispose();
    const lateQueue = backend.replaceQueuedModelTurns({
      steering: [{ message: "late" }],
      followUp: [],
    });
    const lateQueueResult = Promise.allSettled([lateQueue]);
    await flushMicrotasks();
    expect(runtime.dispose).not.toHaveBeenCalled();
    expect(piSession.steer).not.toHaveBeenCalled();

    reloadGate.resolve();
    await reload;
    await dispose;
    expect(runtime.dispose).toHaveBeenCalledOnce();
    expect(await lateQueueResult).toEqual([
      expect.objectContaining({
        status: "rejected",
        reason: expect.objectContaining({ message: "Session backend is disposed" }),
      }),
    ]);
  });
});

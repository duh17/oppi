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

  it("unblocks queue replacement after reload failure without dropping replacement intent", async () => {
    const queue: SessionMessageQueueStore = {
      version: 4,
      steering: [{ id: "old", message: "old", sdkMessage: "old", createdAt: 1 }],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: false, steering: ["old"], queue });
    const reload = harness.backend.reloadResources();
    await flushMicrotasks();
    expect(harness.piSession.reload).toHaveBeenCalledOnce();
    harness.piSession.isStreaming = true;

    const replacement = harness.coordinator.setQueue("s1", {
      baseVersion: 4,
      steering: [{ id: "new-steer", message: "new steer" }],
      followUp: [{ id: "new-follow", message: "new follow" }],
    });
    await Promise.resolve();

    expect(harness.steer).not.toHaveBeenCalled();
    expect(harness.followUp).not.toHaveBeenCalled();

    harness.reloadGate.reject(new Error("reload failed"));
    await expect(reload).rejects.toThrow("reload failed");
    await expect(replacement).resolves.toMatchObject({
      steering: [{ id: "new-steer", message: "new steer" }],
      followUp: [{ id: "new-follow", message: "new follow" }],
    });

    expect(harness.steer).toHaveBeenCalledWith("new steer", undefined);
    expect(harness.followUp).toHaveBeenCalledWith("new follow", undefined);
  });
});

describe("SessionMessageQueueCoordinator replacement transactions", () => {
  it("records Pi queue authority before forwarding queue_update events", () => {
    const backend = Object.create(SdkBackend.prototype) as SdkBackend;
    let listener:
      | ((event: { type: string; steering?: string[]; followUp?: string[] }) => void)
      | undefined;
    const observedGenerations: number[] = [];
    Object.assign(backend as unknown as Record<string, unknown>, {
      queueAuthorityGeneration: 0,
      unsub: null,
      runtime: {
        session: {
          subscribe: vi.fn((next: typeof listener) => {
            listener = next;
            return vi.fn();
          }),
        },
      },
      emitEvent: vi.fn(() => {
        observedGenerations.push(
          (backend as unknown as { queueAuthorityGeneration: number }).queueAuthorityGeneration,
        );
      }),
    });

    (
      backend as unknown as {
        subscribeToCurrentSession: () => void;
      }
    ).subscribeToCurrentSession();
    listener?.({ type: "queue_update", steering: [], followUp: [] });

    expect(observedGenerations).toEqual([1]);
  });

  it("serializes same-base CAS replacements so exactly one becomes stale", async () => {
    const harness = makeHarness({ isStreaming: false });
    const reload = harness.backend.reloadResources();
    await flushMicrotasks();
    expect(harness.piSession.reload).toHaveBeenCalledOnce();
    harness.piSession.isStreaming = true;

    // Both requests are submitted from the same visible base while reload owns
    // the lifecycle transaction. Validation must happen only after each waiter enters.
    const first = harness.coordinator.setQueue("s1", {
      baseVersion: 0,
      steering: [{ id: "first", message: "first replacement" }],
      followUp: [],
    });
    const second = harness.coordinator.setQueue("s1", {
      baseVersion: 0,
      steering: [{ id: "second", message: "second replacement" }],
      followUp: [],
    });
    const resultsPromise = Promise.allSettled([first, second]);
    await flushMicrotasks();
    harness.reloadGate.resolve();
    await reload;

    const results = await resultsPromise;
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    const stale = results.find((result) => result.status === "rejected");
    expect(stale).toMatchObject({
      status: "rejected",
      reason: expect.objectContaining({ message: "Queue version mismatch: expected 1, got 0" }),
    });
    expect(harness.coordinator.getQueue("s1").steering).toEqual([
      expect.objectContaining({ id: "first", message: "first replacement" }),
    ]);
  });

  it("exhausts safely at MAX_SAFE_INTEGER without mutating Pi or weakening stale CAS", async () => {
    const maxVersion = Number.MAX_SAFE_INTEGER;
    const queue: SessionMessageQueueStore = {
      version: maxVersion - 1,
      steering: [{ id: "old", message: "old", sdkMessage: "old", createdAt: 1 }],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: true, steering: ["old"], queue });

    await expect(
      harness.coordinator.setQueue("s1", {
        baseVersion: maxVersion - 1,
        steering: [{ id: "at-max", message: "at max" }],
        followUp: [],
      }),
    ).resolves.toMatchObject({
      version: maxVersion,
      steering: [{ id: "at-max", message: "at max" }],
    });

    const clearCallsAtMax = harness.piSession.clearQueue.mock.calls.length;
    const steerCallsAtMax = harness.steer.mock.calls.length;
    await expect(
      harness.coordinator.setQueue("s1", {
        baseVersion: maxVersion - 1,
        steering: [{ id: "stale", message: "stale" }],
        followUp: [],
      }),
    ).rejects.toThrow(`Queue version mismatch: expected ${maxVersion}, got ${maxVersion - 1}`);

    for (const id of ["exhausted", "exhausted-retry"]) {
      await expect(
        harness.coordinator.setQueue("s1", {
          baseVersion: maxVersion,
          steering: [{ id, message: id }],
          followUp: [],
        }),
      ).rejects.toThrow(
        `Queue version exhausted at ${maxVersion}; start a new session to reset the queue counter`,
      );
    }

    expect(harness.piSession.clearQueue).toHaveBeenCalledTimes(clearCallsAtMax);
    expect(harness.steer).toHaveBeenCalledTimes(steerCallsAtMax);
    expect(harness.piSession.getSteeringMessages()).toEqual(["at max"]);
    expect(harness.coordinator.getQueue("s1")).toMatchObject({
      version: maxVersion,
      steering: [{ id: "at-max", message: "at max" }],
    });
  });

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

  it("rejects stale replacement when Pi consumes the validated item during materialization", async () => {
    const queue: SessionMessageQueueStore = {
      version: 7,
      steering: [
        {
          id: "item-a",
          message: "A",
          sdkMessage: "A",
          createdAt: 1,
          attachments: [
            {
              type: "attachment",
              id: "delayed-attachment-a",
              source: "workspace",
              name: "a.txt",
              mimeType: "text/plain",
              sizeBytes: 1,
              workspacePath: "a.txt",
            },
          ],
        },
      ],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: true, steering: ["A"], queue });
    const materializationEntered = deferred<void>();
    const releaseMaterialization = deferred<void>();
    (
      harness.coordinator as unknown as {
        materializeQueueItemForSdk: (
          active: SessionMessageQueueState,
          item: {
            id: string;
            message: string;
            createdAt: number;
            attachments?: Array<{ id: string }>;
          },
        ) => Promise<{
          id: string;
          message: string;
          sdkMessage: string;
          createdAt: number;
          attachments?: Array<{ id: string }>;
        }>;
      }
    ).materializeQueueItemForSdk = async (_active, item) => {
      materializationEntered.resolve();
      await releaseMaterialization.promise;
      return { ...item, sdkMessage: item.message };
    };

    const replacement = harness.coordinator.setQueue("s1", {
      baseVersion: 7,
      steering: [
        {
          id: "item-a",
          message: "A",
          createdAt: 1,
          attachments: [
            {
              type: "attachment",
              id: "delayed-attachment-a",
              source: "workspace",
              name: "a.txt",
              mimeType: "text/plain",
              sizeBytes: 1,
              workspacePath: "a.txt",
            },
          ],
        },
      ],
      followUp: [],
    });
    await materializationEntered.promise;

    harness.consumeSteering("A");
    releaseMaterialization.resolve();

    await expect(replacement).rejects.toThrow("Queue version mismatch: expected 8, got 7");
    expect(harness.steer).not.toHaveBeenCalled();
    expect(harness.piSession.getSteeringMessages()).toEqual([]);
    expect(harness.coordinator.getQueue("s1")).toEqual({
      version: 8,
      steering: [],
      followUp: [],
    });
    expect(harness.broadcast.mock.calls.map(([, message]) => message.type)).toEqual([
      "queue_item_started",
      "queue_state",
    ]);
  });

  it("reconciles and rejects when Pi consumes an item during replay without replaying it twice", async () => {
    const queue: SessionMessageQueueStore = {
      version: 7,
      steering: [
        { id: "item-a", message: "A", sdkMessage: "A", createdAt: 1 },
        { id: "item-b", message: "B", sdkMessage: "B", createdAt: 2 },
      ],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: true, steering: ["A", "B"], queue });
    (
      harness.coordinator as unknown as {
        materializeQueueItemForSdk: (
          active: SessionMessageQueueState,
          item: {
            id: string;
            message: string;
            createdAt: number;
            attachments?: Array<{ id: string }>;
          },
        ) => Promise<{
          id: string;
          message: string;
          sdkMessage: string;
          createdAt: number;
          attachments?: Array<{ id: string }>;
          sdkImages?: Array<{ type: "image"; data: string; mimeType: string }>;
        }>;
      }
    ).materializeQueueItemForSdk = async (_active, item) => ({
      ...item,
      sdkMessage: item.message,
      ...(item.id === "item-b"
        ? {
            sdkImages: [{ type: "image" as const, data: "image-b", mimeType: "image/png" }],
          }
        : {}),
    });
    const replayedA = deferred<void>();
    const releaseReplay = deferred<void>();
    const replaySteer = harness.steer.getMockImplementation();
    harness.steer.mockImplementation(async (message: string) => {
      await replaySteer?.(message);
      if (message === "A") {
        replayedA.resolve();
        await releaseReplay.promise;
      }
    });

    const replacement = harness.coordinator.setQueue("s1", {
      baseVersion: 7,
      steering: [
        { id: "item-a", message: "A", createdAt: 1 },
        {
          id: "item-b",
          message: "B",
          createdAt: 2,
          attachments: [
            {
              type: "attachment",
              id: "attachment-b",
              source: "workspace",
              name: "b.png",
              mimeType: "image/png",
              sizeBytes: 1,
              workspacePath: "b.txt",
            },
          ],
        },
      ],
      followUp: [],
    });
    await replayedA.promise;

    harness.consumeSteering("A");
    releaseReplay.resolve();

    await expect(replacement).rejects.toThrow("Queue version mismatch: expected 8, got 7");
    expect(harness.steer.mock.calls.filter(([message]) => message === "A")).toHaveLength(1);
    expect(harness.piSession.getSteeringMessages()).toEqual(["B"]);
    expect(harness.coordinator.getQueue("s1")).toMatchObject({
      version: 8,
      steering: [
        {
          id: "item-b",
          message: "B",
          attachments: [expect.objectContaining({ id: "attachment-b" })],
        },
      ],
      followUp: [],
    });
    expect(harness.active.messageQueue?.steering[0]).toMatchObject({
      id: "item-b",
      sdkImages: [{ type: "image", data: "image-b", mimeType: "image/png" }],
    });
    expect(harness.broadcast.mock.calls.map(([, message]) => message.type)).toEqual([
      "queue_item_started",
      "queue_state",
    ]);
  });

  it("checks replay authority again before committing the Oppi queue", async () => {
    const queue: SessionMessageQueueStore = {
      version: 7,
      steering: [{ id: "item-a", message: "A", sdkMessage: "A", createdAt: 1 }],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: true, steering: ["A"], queue });
    const replace = harness.backend.replaceQueuedModelTurns.bind(harness.backend);
    vi.spyOn(harness.backend, "replaceQueuedModelTurns").mockImplementation(async (...args) => {
      const authority = await replace(...args);
      harness.consumeSteering("A");
      return authority;
    });

    const replacement = harness.coordinator.setQueue("s1", {
      baseVersion: 7,
      steering: [{ id: "item-a", message: "A", createdAt: 1 }],
      followUp: [],
    });

    await expect(replacement).rejects.toThrow("Queue version mismatch: expected 8, got 7");
    expect(harness.steer.mock.calls.filter(([message]) => message === "A")).toHaveLength(1);
    expect(harness.piSession.getSteeringMessages()).toEqual([]);
    expect(harness.coordinator.getQueue("s1")).toEqual({
      version: 8,
      steering: [],
      followUp: [],
    });
  });

  it("keeps reads on the prior queue snapshot until replacement commits", async () => {
    const queue: SessionMessageQueueStore = {
      version: 7,
      steering: [{ id: "old", message: "old", sdkMessage: "old", createdAt: 1 }],
      followUp: [],
    };
    const harness = makeHarness({ isStreaming: true, steering: ["old"], queue });
    const replayEntered = deferred<void>();
    const releaseReplay = deferred<void>();
    const replaySteer = harness.steer.getMockImplementation();
    harness.steer.mockImplementation(async (message: string) => {
      await replaySteer?.(message);
      if (message === "new one") replayEntered.resolve();
      await releaseReplay.promise;
    });

    const replacement = harness.coordinator.setQueue("s1", {
      baseVersion: 7,
      steering: [
        { id: "new-1", message: "new one" },
        { id: "new-2", message: "new two" },
      ],
      followUp: [],
    });
    await replayEntered.promise;

    expect(harness.coordinator.getQueue("s1")).toMatchObject({
      version: 7,
      steering: [{ id: "old", message: "old" }],
    });

    releaseReplay.resolve();
    await replacement;
    expect(harness.coordinator.getQueue("s1").steering.map((item) => item.message)).toEqual([
      "new one",
      "new two",
    ]);
  });

  it("restores the prior SDK queue and leaves Oppi state uncommitted on replay failure", async () => {
    const queue: SessionMessageQueueStore = {
      version: 5,
      steering: [{ id: "old-steer", message: "old steer", sdkMessage: "old steer", createdAt: 1 }],
      followUp: [
        { id: "old-follow", message: "old follow", sdkMessage: "old follow", createdAt: 2 },
      ],
    };
    const harness = makeHarness({
      isStreaming: true,
      steering: ["old steer"],
      followUp: ["old follow"],
      queue,
    });
    const replaySteer = harness.steer.getMockImplementation();
    harness.steer.mockImplementation(async (message: string) => {
      if (message === "/registered-command") throw new Error("cannot queue extension command");
      await replaySteer?.(message);
    });

    await expect(
      harness.coordinator.setQueue("s1", {
        baseVersion: 5,
        steering: [
          { id: "new-1", message: "new steer" },
          { id: "new-2", message: "/registered-command" },
        ],
        followUp: [{ id: "new-follow", message: "new follow" }],
      }),
    ).rejects.toThrow("cannot queue extension command");

    expect(harness.piSession.getSteeringMessages()).toEqual(["old steer"]);
    expect(harness.piSession.getFollowUpMessages()).toEqual(["old follow"]);
    expect(harness.coordinator.getQueue("s1")).toMatchObject({
      version: 5,
      steering: [{ id: "old-steer", message: "old steer" }],
      followUp: [{ id: "old-follow", message: "old follow" }],
    });
    expect(harness.broadcast).not.toHaveBeenCalled();
  });

  it("enters explicit reconciliation when replacement and rollback replay both fail", async () => {
    const queue: SessionMessageQueueStore = {
      version: 5,
      steering: [{ id: "old-steer", message: "old steer", sdkMessage: "old steer", createdAt: 1 }],
      followUp: [
        { id: "old-follow", message: "old follow", sdkMessage: "old follow", createdAt: 2 },
      ],
    };
    const harness = makeHarness({
      isStreaming: true,
      steering: ["old steer"],
      followUp: ["old follow"],
      queue,
    });
    const replaySteer = harness.steer.getMockImplementation();
    let rejectRollback = true;
    harness.steer.mockImplementation(async (message: string) => {
      if (message === "replacement rejected") throw new Error("replacement replay failed");
      if (message === "old steer" && rejectRollback) throw new Error("rollback replay failed");
      await replaySteer?.(message);
    });

    await expect(
      harness.coordinator.setQueue("s1", {
        baseVersion: 5,
        steering: [
          { id: "new-1", message: "new steer" },
          { id: "new-2", message: "replacement rejected" },
        ],
        followUp: [{ id: "new-follow", message: "new follow" }],
      }),
    ).rejects.toThrow(
      "Queue reconciliation required: replacement replay failed and rollback replay failed; retry setQueue from the last acknowledged queue version",
    );

    expect(harness.active.messageQueue).toMatchObject({
      version: 5,
      steering: [{ id: "old-steer", message: "old steer" }],
      followUp: [{ id: "old-follow", message: "old follow" }],
    });
    expect(() => harness.coordinator.getQueue("s1")).toThrow(
      "Queue reconciliation required: retry setQueue from the last acknowledged queue version",
    );
    await expect(harness.coordinator.flushIdleQueuedMessages("s1")).rejects.toThrow(
      "Queue reconciliation required: retry setQueue from the last acknowledged queue version",
    );
    expect(harness.prompt).not.toHaveBeenCalled();

    const clearCallsBeforeRecovery = harness.piSession.clearQueue.mock.calls.length;
    await expect(
      harness.coordinator.setQueue("s1", {
        baseVersion: 4,
        steering: [{ id: "stale", message: "stale recovery" }],
        followUp: [],
      }),
    ).rejects.toThrow("Queue version mismatch: expected 5, got 4");
    expect(harness.piSession.clearQueue).toHaveBeenCalledTimes(clearCallsBeforeRecovery);

    rejectRollback = false;
    const recoveryEntered = deferred<void>();
    const releaseRecovery = deferred<void>();
    harness.steer.mockImplementation(async (message: string) => {
      // Match Pi: queue mutation and queue_update are synchronous before the
      // returned promise settles.
      await replaySteer?.(message);
      if (message === "recovered intent") {
        recoveryEntered.resolve();
        await releaseRecovery.promise;
      }
    });
    const recovery = harness.coordinator.setQueue("s1", {
      baseVersion: 5,
      steering: [{ id: "recovered", message: "recovered intent" }],
      followUp: [{ id: "recovered-follow", message: "recovered follow-up" }],
    });
    await recoveryEntered.promise;

    await expect(harness.backend.prompt("racing admission")).rejects.toThrow(
      QUEUE_RECONCILIATION_REQUIRED_ERROR,
    );
    expect(harness.prompt).not.toHaveBeenCalled();

    releaseRecovery.resolve();
    await expect(recovery).resolves.toMatchObject({
      version: 6,
      steering: [{ id: "recovered", message: "recovered intent" }],
      followUp: [{ id: "recovered-follow", message: "recovered follow-up" }],
    });
    expect(harness.piSession.getSteeringMessages()).toEqual(["recovered intent"]);
    expect(harness.piSession.getFollowUpMessages()).toEqual(["recovered follow-up"]);
    expect(harness.coordinator.getQueue("s1")).toMatchObject({
      version: 6,
      steering: [{ id: "recovered", message: "recovered intent" }],
      followUp: [{ id: "recovered-follow", message: "recovered follow-up" }],
    });

    await expect(harness.backend.prompt("admitted after recovery")).resolves.toBeUndefined();
    expect(harness.prompt).toHaveBeenCalledOnce();
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

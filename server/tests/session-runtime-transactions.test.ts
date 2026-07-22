import { describe, expect, it, vi } from "vitest";

import type { SessionInputSessionState } from "../src/session-input.js";
import { SessionInputCoordinator } from "../src/session-input.js";
import { SessionTurnCoordinator } from "../src/session-turns.js";
import { SessionRuntimeTransaction } from "../src/session-runtime-transaction.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { ServerConfig, ServerMessage, Session } from "../src/types.js";

const TEST_CONFIG: ServerConfig = {
  port: 7749,
  host: "127.0.0.1",
  dataDir: "/tmp/oppi-runtime-transaction-tests",
  defaultModel: "anthropic/claude-sonnet-4-0",
};

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
} {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
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

async function flushMicrotasks(turns = 3): Promise<void> {
  for (let index = 0; index < turns; index += 1) await Promise.resolve();
}

describe("SessionRuntimeTransaction", () => {
  it("allows shared admissions together and gives a waiting exclusive operation priority", async () => {
    const transaction = new SessionRuntimeTransaction();
    const releaseShared = deferred();
    const firstEntered = deferred();
    const secondEntered = deferred();
    const exclusiveEntered = deferred();
    const releaseExclusive = deferred();
    const lateSharedEntered = deferred();

    const first = transaction.withShared(async () => {
      firstEntered.resolve();
      await releaseShared.promise;
    });
    const second = transaction.withShared(async () => {
      secondEntered.resolve();
      await releaseShared.promise;
    });
    await Promise.all([firstEntered.promise, secondEntered.promise]);

    const exclusive = transaction.withExclusive(async () => {
      exclusiveEntered.resolve();
      await releaseExclusive.promise;
    });
    const lateShared = transaction.withShared(async () => {
      lateSharedEntered.resolve();
    });
    await flushMicrotasks();
    expect(transaction.isExclusiveActive).toBe(false);

    releaseShared.resolve();
    await exclusiveEntered.promise;
    expect(transaction.isExclusiveActive).toBe(true);
    let lateSharedStarted = false;
    void lateSharedEntered.promise.then(() => {
      lateSharedStarted = true;
    });
    await flushMicrotasks();
    expect(lateSharedStarted).toBe(false);

    releaseExclusive.resolve();
    await Promise.all([first, second, exclusive, lateShared]);
    expect(lateSharedStarted).toBe(true);
  });

  it("poisons active permits and rejects queued and future work without waiting for owners", async () => {
    const transaction = new SessionRuntimeTransaction();
    const releaseShared = deferred();
    const sharedEntered = deferred();
    let lateOwnerFinished = false;
    const shared = transaction.withShared(async () => {
      sharedEntered.resolve();
      await releaseShared.promise;
      lateOwnerFinished = true;
    });
    await sharedEntered.promise;

    const queued = transaction.withExclusive(async () => undefined);
    const poisonError = new Error("runtime disposed");
    transaction.poison(poisonError);

    expect(transaction.hasActivePermits).toBe(false);
    await expect(shared).rejects.toBe(poisonError);
    await expect(queued).rejects.toBe(poisonError);
    await expect(transaction.withExclusive(async () => undefined)).rejects.toBe(poisonError);

    releaseShared.resolve();
    await flushMicrotasks();
    expect(lateOwnerFinished).toBe(true);
    expect(transaction.hasActivePermits).toBe(false);
  });

  it("rejects non-waiting admission while exclusive lifecycle work is active", async () => {
    const transaction = new SessionRuntimeTransaction();
    const exclusiveEntered = deferred();
    const releaseExclusive = deferred();
    const exclusive = transaction.withExclusive(async () => {
      exclusiveEntered.resolve();
      await releaseExclusive.promise;
    });
    await exclusiveEntered.promise;

    await expect(transaction.tryWithShared("reload active", async () => undefined)).rejects.toThrow(
      "reload active",
    );

    releaseExclusive.resolve();
    await exclusive;
  });
});

describe("SessionInputCoordinator runtime admission", () => {
  it("rejects before prompt projection and allows the same clientTurnId after reload", async () => {
    const session = makeSession();
    const active: SessionInputSessionState = {
      session,
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: { isStreaming: false, isCompacting: false },
    };
    const broadcasts: ServerMessage[] = [];
    const turnCoordinator = new SessionTurnCoordinator({
      broadcast: (_key, message) => broadcasts.push(message),
    });
    const admissionGate = deferred();
    let rejectAdmission = true;
    const withModelTurnAdmission = vi.fn(
      async (_command: string, operation: (permit: object) => Promise<unknown>) => {
        await admissionGate.promise;
        if (rejectAdmission) {
          throw new Error("prompt cannot start while reload is rebuilding the session");
        }
        return operation({});
      },
    );
    Object.assign(active.sdkBackend ?? {}, { withModelTurnAdmission });
    const sendCommand = vi.fn(async () => undefined);
    const onFirstMessage = vi.fn();
    const coordinator = new SessionInputCoordinator({
      config: TEST_CONFIG,
      getActiveSession: () => active,
      turnCoordinator,
      sendCommand,
      onFirstMessage,
    });

    const rejected = coordinator.sendPrompt("s1", "transactional prompt", {
      clientTurnId: "turn-retry",
      timestamp: 10,
    });
    await flushMicrotasks();

    expect(session.firstMessage).toBeUndefined();
    expect(session.messages).toBeUndefined();
    expect(active.turnCache.get("turn-retry")).toBeNull();
    expect(broadcasts).toEqual([]);
    expect(sendCommand).not.toHaveBeenCalled();

    admissionGate.resolve();
    await expect(rejected).rejects.toThrow(
      "prompt cannot start while reload is rebuilding the session",
    );
    expect(session.firstMessage).toBeUndefined();
    expect(active.turnCache.get("turn-retry")).toBeNull();
    expect(onFirstMessage).not.toHaveBeenCalled();

    rejectAdmission = false;
    await expect(
      coordinator.sendPrompt("s1", "transactional prompt", {
        clientTurnId: "turn-retry",
        timestamp: 11,
      }),
    ).resolves.toEqual({ duplicate: false });

    expect(withModelTurnAdmission).toHaveBeenCalledTimes(2);
    expect(sendCommand).toHaveBeenCalledOnce();
    expect(session.firstMessage).toBe("transactional prompt");
    expect(onFirstMessage).toHaveBeenCalledOnce();
    expect(active.turnCache.get("turn-retry")?.stage).toBe("dispatched");
    expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([
      expect.objectContaining({ stage: "accepted", clientTurnId: "turn-retry" }),
      expect.objectContaining({ stage: "dispatched", clientTurnId: "turn-retry" }),
    ]);
  });

  it("commits prompt projection and turn acknowledgement only after Pi preflight accepts", async () => {
    const session = makeSession();
    const active: SessionInputSessionState = {
      session,
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: { isStreaming: false, isCompacting: false },
    };
    const broadcasts: ServerMessage[] = [];
    const turnCoordinator = new SessionTurnCoordinator({
      broadcast: (_key, message) => broadcasts.push(message),
    });
    let rejectPreflight = true;
    const sendCommand = vi.fn(
      async (
        _key: string,
        _command: Record<string, unknown>,
        _permit?: object,
        onPreflightAccepted?: () => void,
      ) => {
        if (rejectPreflight) throw new Error("Pi prompt preflight rejected");
        onPreflightAccepted?.();
      },
    );
    const onFirstMessage = vi.fn();
    const coordinator = new SessionInputCoordinator({
      config: TEST_CONFIG,
      getActiveSession: () => active,
      turnCoordinator,
      sendCommand,
      onFirstMessage,
    });

    await expect(
      coordinator.sendPrompt("s1", "preflight prompt", {
        clientTurnId: "turn-preflight-retry",
        timestamp: 10,
      }),
    ).rejects.toThrow("Pi prompt preflight rejected");

    expect(session.messages).toBeUndefined();
    expect(session.firstMessage).toBeUndefined();
    expect(session.messageCount).toBe(0);
    expect(onFirstMessage).not.toHaveBeenCalled();
    expect(active.turnCache.get("turn-preflight-retry")).toBeNull();
    expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([]);

    rejectPreflight = false;
    await expect(
      coordinator.sendPrompt("s1", "preflight prompt", {
        clientTurnId: "turn-preflight-retry",
        timestamp: 11,
      }),
    ).resolves.toEqual({ duplicate: false });

    expect(sendCommand).toHaveBeenCalledTimes(2);
    expect(session.firstMessage).toBe("preflight prompt");
    expect(session.messageCount).toBe(1);
    expect(onFirstMessage).toHaveBeenCalledOnce();
    expect(active.turnCache.get("turn-preflight-retry")?.stage).toBe("dispatched");
    expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([
      expect.objectContaining({ stage: "accepted", clientTurnId: "turn-preflight-retry" }),
      expect.objectContaining({ stage: "dispatched", clientTurnId: "turn-preflight-retry" }),
    ]);
  });

  it("dispatches the accepted turn before Pi can synchronously emit agent_start", async () => {
    const session = makeSession();
    const active: SessionInputSessionState = {
      session,
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: { isStreaming: false, isCompacting: false },
    };
    const broadcasts: ServerMessage[] = [];
    const turnCoordinator = new SessionTurnCoordinator({
      broadcast: (_key, message) => broadcasts.push(message),
    });
    const sendCommand = vi.fn(
      async (
        _key: string,
        _command: Record<string, unknown>,
        _permit?: object,
        onPreflightAccepted?: () => void,
      ) => {
        onPreflightAccepted?.();
        turnCoordinator.markNextTurnStarted("s1", active);
      },
    );
    const coordinator = new SessionInputCoordinator({
      config: TEST_CONFIG,
      getActiveSession: () => active,
      turnCoordinator,
      sendCommand,
    });

    await coordinator.sendPrompt("s1", "ordered prompt", {
      clientTurnId: "turn-ordered",
      requestId: "request-ordered",
    });

    expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([
      expect.objectContaining({ stage: "accepted", clientTurnId: "turn-ordered" }),
      expect.objectContaining({ stage: "dispatched", clientTurnId: "turn-ordered" }),
      expect.objectContaining({ stage: "started", clientTurnId: "turn-ordered" }),
    ]);
  });

  it("serializes concurrent retries so one accepted preflight owns the clientTurnId", async () => {
    const session = makeSession();
    const active: SessionInputSessionState = {
      session,
      turnCache: new TurnDedupeCache(),
      pendingTurnStarts: [],
      sdkBackend: { isStreaming: false, isCompacting: false },
    };
    const broadcasts: ServerMessage[] = [];
    const turnCoordinator = new SessionTurnCoordinator({
      broadcast: (_key, message) => broadcasts.push(message),
    });
    const commandEntered = deferred();
    const acceptCommand = deferred();
    const sendCommand = vi.fn(
      async (
        _key: string,
        _command: Record<string, unknown>,
        _permit?: object,
        onPreflightAccepted?: () => void,
      ) => {
        commandEntered.resolve();
        await acceptCommand.promise;
        onPreflightAccepted?.();
      },
    );
    const coordinator = new SessionInputCoordinator({
      config: TEST_CONFIG,
      getActiveSession: () => active,
      turnCoordinator,
      sendCommand,
    });

    const first = coordinator.sendPrompt("s1", "same prompt", {
      clientTurnId: "turn-concurrent",
      requestId: "request-first",
    });
    await commandEntered.promise;
    const retry = coordinator.sendPrompt("s1", "same prompt", {
      clientTurnId: "turn-concurrent",
      requestId: "request-retry",
    });
    await flushMicrotasks();
    expect(sendCommand).toHaveBeenCalledOnce();

    acceptCommand.resolve();
    await expect(first).resolves.toEqual({ duplicate: false });
    await expect(retry).resolves.toEqual({ duplicate: true });

    expect(sendCommand).toHaveBeenCalledOnce();
    expect(session.messageCount).toBe(1);
    expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([
      expect.objectContaining({ stage: "accepted", requestId: "request-first" }),
      expect.objectContaining({ stage: "dispatched", requestId: "request-first" }),
      expect.objectContaining({
        stage: "dispatched",
        requestId: "request-retry",
        duplicate: true,
      }),
    ]);
  });

  it.each(["steer", "follow_up"] as const)(
    "does not acknowledge or consume %s input when Pi preflight rejects",
    async (kind) => {
      const session = { ...makeSession(), status: "busy" as const };
      const active: SessionInputSessionState = {
        session,
        turnCache: new TurnDedupeCache(),
        pendingTurnStarts: [],
        sdkBackend: { isStreaming: true, isCompacting: false },
      };
      const broadcasts: ServerMessage[] = [];
      const turnCoordinator = new SessionTurnCoordinator({
        broadcast: (_key, message) => broadcasts.push(message),
      });
      let rejectPreflight = true;
      const sendCommand = vi.fn(
        async (
          _key: string,
          _command: Record<string, unknown>,
          _permit?: object,
          onPreflightAccepted?: () => void,
        ) => {
          if (rejectPreflight) throw new Error(`Pi ${kind} preflight rejected`);
          onPreflightAccepted?.();
        },
      );
      const enqueueQueuedMessage = vi.fn();
      const coordinator = new SessionInputCoordinator({
        config: TEST_CONFIG,
        getActiveSession: () => active,
        turnCoordinator,
        sendCommand,
        enqueueQueuedMessage,
      });
      const clientTurnId = `turn-${kind}-retry`;
      const send = () =>
        kind === "steer"
          ? coordinator.sendSteer("s1", "streaming input", { clientTurnId })
          : coordinator.sendFollowUp("s1", "streaming input", { clientTurnId });

      await expect(send()).rejects.toThrow(`Pi ${kind} preflight rejected`);
      expect(active.turnCache.get(clientTurnId)).toBeNull();
      expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([]);
      expect(enqueueQueuedMessage).not.toHaveBeenCalled();

      rejectPreflight = false;
      await expect(send()).resolves.toBeUndefined();

      expect(sendCommand).toHaveBeenCalledTimes(2);
      expect(active.turnCache.get(clientTurnId)?.stage).toBe("dispatched");
      expect(enqueueQueuedMessage).toHaveBeenCalledOnce();
      expect(broadcasts.filter((message) => message.type === "turn_ack")).toEqual([
        expect.objectContaining({ stage: "accepted", clientTurnId }),
        expect.objectContaining({ stage: "dispatched", clientTurnId }),
      ]);
    },
  );
});
